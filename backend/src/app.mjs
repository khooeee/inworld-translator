// HTTP surface of the backend:
//
//   GET  /healthz          liveness probe, no auth
//   POST /v1/stt/token     mint a single-use Inworld token for one STT connection
//   POST /v1/translate     translate one finalized phrase into English (SSE)
//
// Both /v1 routes require a client bearer key and are subject to per-client
// usage limits. Transcript text is never logged.

import { createAuthenticator } from './auth.mjs';
import { createInworldClient, UpstreamError } from './inworld.mjs';
import { ConcurrencyGate, DailyQuota, RateLimiter } from './limits.mjs';

class HttpError extends Error {
  constructor(status, code, message, { retryAfterSeconds } = {}) {
    super(message);
    this.status = status;
    this.code = code;
    this.retryAfterSeconds = retryAfterSeconds;
  }
}

function sendJSON(res, status, payload, headers = {}) {
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Cache-Control': 'no-store',
    ...headers,
  });
  res.end(JSON.stringify(payload));
}

function sendError(res, error) {
  const headers = error.retryAfterSeconds ? { 'Retry-After': String(error.retryAfterSeconds) } : {};
  sendJSON(
    res,
    error.status,
    {
      error: {
        code: error.code,
        message: error.message,
        ...(error.retryAfterSeconds ? { retryAfterSeconds: error.retryAfterSeconds } : {}),
      },
    },
    headers,
  );
}

async function readJSON(req, maxBytes) {
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > maxBytes) throw new HttpError(413, 'payload_too_large', 'Request body is too large');
    chunks.push(chunk);
  }
  if (size === 0) return {};
  try {
    const value = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    if (value === null || typeof value !== 'object' || Array.isArray(value)) throw new Error();
    return value;
  } catch {
    throw new HttpError(400, 'invalid_request', 'Request body must be a JSON object');
  }
}

function fromUpstream(error) {
  if (error.status === 429) {
    return new HttpError(429, 'upstream_rate_limited', 'The translation service is busy', {
      retryAfterSeconds: error.retryAfterSeconds ?? 5,
    });
  }
  return new HttpError(502, 'upstream_error', 'The translation service is unavailable');
}

export function createApp(config, { inworld = createInworldClient(config.inworld), log = defaultLog, now = Date.now } = {}) {
  const authenticate = createAuthenticator(config.clients);
  const rates = new RateLimiter({ now });
  const quotas = new DailyQuota({ now });
  const gate = new ConcurrencyGate();
  const { limits, request: bounds } = config;

  const sweeper = setInterval(() => rates.sweep(), 60_000);
  sweeper.unref();

  function clientAddress(req) {
    if (config.trustProxy) {
      const forwarded = String(req.headers['x-forwarded-for'] ?? '').split(',')[0].trim();
      if (forwarded) return forwarded;
    }
    return req.socket.remoteAddress ?? 'unknown';
  }

  function requireClient(req) {
    const clientId = authenticate(req);
    if (clientId) return clientId;
    // Slow down guessing: failed attempts are limited per address.
    const attempt = rates.take(`auth-fail:${clientAddress(req)}`, { perMinute: limits.failedAuthPerMinute });
    if (!attempt.allowed) {
      throw new HttpError(429, 'rate_limited', 'Too many failed attempts', attempt);
    }
    throw new HttpError(401, 'unauthorized', 'A valid client key is required');
  }

  function enforce(result, code, message) {
    if (!result.allowed) throw new HttpError(429, code, message, result);
  }

  async function handleToken(req, res, clientId) {
    await readJSON(req, bounds.maxBodyBytes);
    enforce(
      rates.take(`token:${clientId}`, { perMinute: limits.tokensPerMinute }),
      'rate_limited',
      'Too many connection attempts. Try again shortly.',
    );
    enforce(
      quotas.consume(`token:${clientId}`, 1, limits.tokensPerDay),
      'quota_exceeded',
      'Daily session limit reached',
    );
    enforce(
      rates.take('token:global', { perMinute: limits.globalTokensPerMinute }),
      'rate_limited',
      'The service is busy. Try again shortly.',
    );

    const token = await inworld.mintToken({ clientReferenceId: clientId });
    sendJSON(res, 200, {
      accessToken: token.accessToken,
      expireTime: token.expireTime,
      websocketURL: config.inworld.sttWebSocketURL,
      modelId: config.inworld.sttModel,
    });
  }

  function parseTranslateBody(body) {
    const phrase = typeof body.text === 'string' ? body.text.trim() : '';
    if (!phrase) throw new HttpError(400, 'invalid_request', '"text" must be a non-empty string');
    if (phrase.length > bounds.maxPhraseChars) {
      throw new HttpError(400, 'invalid_request', `"text" must be at most ${bounds.maxPhraseChars} characters`);
    }

    const rawContext = body.context ?? [];
    if (!Array.isArray(rawContext)) {
      throw new HttpError(400, 'invalid_request', '"context" must be an array');
    }
    // Context is advisory, so it is trimmed to the bounds rather than rejected.
    const context = [];
    for (const item of rawContext.slice(-bounds.maxContextItems)) {
      if (item === null || typeof item !== 'object' || typeof item.source !== 'string') {
        throw new HttpError(400, 'invalid_request', '"context" items must have a "source" string');
      }
      const entry = { source: item.source.slice(0, bounds.maxContextChars) };
      if (typeof item.translation === 'string' && item.translation) {
        entry.translation = item.translation.slice(0, bounds.maxContextChars);
      }
      context.push(entry);
    }
    return { phrase, context };
  }

  async function handleTranslate(req, res, clientId) {
    const { phrase, context } = parseTranslateBody(await readJSON(req, bounds.maxBodyBytes));

    enforce(
      rates.take(`translate:${clientId}`, { perMinute: limits.translationsPerMinute }),
      'rate_limited',
      'Too many translation requests. Try again shortly.',
    );
    enforce(
      quotas.consume(`translate:${clientId}`, 1, limits.translationsPerDay),
      'quota_exceeded',
      'Daily translation limit reached',
    );
    enforce(
      quotas.consume(`translate-chars:${clientId}`, phrase.length, limits.translationCharsPerDay),
      'quota_exceeded',
      'Daily translation limit reached',
    );
    if (!gate.enter(clientId, limits.concurrentTranslations)) {
      throw new HttpError(429, 'rate_limited', 'Too many translations in progress', { retryAfterSeconds: 1 });
    }

    // Stop paying for the completion as soon as the app stops listening.
    const abort = new AbortController();
    res.on('close', () => abort.abort());

    let streaming = false;
    const send = (event) => res.write(`data: ${JSON.stringify(event)}\n\n`);
    try {
      const stream = inworld.translate({ phrase, context, signal: abort.signal });
      for (;;) {
        const next = await stream.next();
        if (!streaming) {
          // Headers wait for the first upstream event so that failures before
          // any output can still be reported with a real HTTP status.
          streaming = true;
          res.writeHead(200, {
            'Content-Type': 'text/event-stream; charset=utf-8',
            'Cache-Control': 'no-store',
            'X-Accel-Buffering': 'no',
          });
        }
        if (next.done) {
          const { translation, language, truncated, model, usage } = next.value;
          send({ type: 'done', translation, language, truncated, usage });
          res.end();
          return { model, usage, chars: phrase.length };
        }
        send(next.value);
      }
    } catch (error) {
      if (abort.signal.aborted) return { cancelled: true };
      if (!(error instanceof UpstreamError)) throw error;
      if (!streaming) throw fromUpstream(error);
      send({ type: 'error', code: 'upstream_error', message: 'The translation was interrupted' });
      res.end();
      return { failed: true };
    } finally {
      gate.leave(clientId);
    }
  }

  const routes = {
    'POST /v1/stt/token': handleToken,
    'POST /v1/translate': handleTranslate,
  };

  return async function handle(req, res) {
    const startedAt = now();
    const path = new URL(req.url, 'http://localhost').pathname;
    const route = `${req.method} ${path}`;
    let clientId = null;
    let detail = {};

    try {
      if (route === 'GET /healthz') {
        sendJSON(res, 200, { ok: true });
        return;
      }
      const handler = routes[route];
      if (!handler) {
        const known = Object.keys(routes).some((key) => key.endsWith(` ${path}`));
        throw known
          ? new HttpError(405, 'method_not_allowed', 'Method not allowed')
          : new HttpError(404, 'not_found', 'Not found');
      }
      clientId = requireClient(req);
      detail = (await handler(req, res, clientId)) ?? {};
    } catch (error) {
      const httpError =
        error instanceof HttpError
          ? error
          : error instanceof UpstreamError
            ? fromUpstream(error)
            : new HttpError(500, 'internal_error', 'Internal error');
      if (!(error instanceof HttpError) && !(error instanceof UpstreamError)) {
        detail.exception = error?.name ?? 'Error';
      } else if (error instanceof UpstreamError) {
        detail.upstream = error.message;
      }
      if (res.headersSent) res.destroy();
      else sendError(res, httpError);
    } finally {
      if (route !== 'GET /healthz') {
        log({ route, status: res.statusCode, client: clientId, ms: now() - startedAt, ...detail });
      }
    }
  };
}

function defaultLog(entry) {
  console.log(JSON.stringify({ time: new Date().toISOString(), ...entry }));
}
