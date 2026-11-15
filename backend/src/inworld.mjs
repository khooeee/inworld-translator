// Calls to the Inworld API. This is the only module that touches the API key.

import { buildMessages, maxOutputTokens, ReplyParser } from './prompt.mjs';

export class UpstreamError extends Error {
  constructor(message, { status = 502, retryAfterSeconds } = {}) {
    super(message);
    this.status = status;
    this.retryAfterSeconds = retryAfterSeconds;
  }
}

function upstreamFailure(what, response) {
  // 429 is passed through so the app backs off; everything else is a bad gateway.
  const retryAfter = Number(response.headers.get('retry-after'));
  return new UpstreamError(`${what} failed with status ${response.status}`, {
    status: response.status === 429 ? 429 : 502,
    retryAfterSeconds: Number.isFinite(retryAfter) && retryAfter > 0 ? retryAfter : undefined,
  });
}

// Yields the JSON payload of each `data:` event in an OpenAI-style SSE body
// and returns true if the stream ended with the [DONE] sentinel.
export async function* sseEvents(body) {
  const decoder = new TextDecoder();
  let buffer = '';
  for await (const chunk of body) {
    buffer += decoder.decode(chunk, { stream: true });
    let newline;
    while ((newline = buffer.indexOf('\n')) !== -1) {
      const line = buffer.slice(0, newline).replace(/\r$/, '');
      buffer = buffer.slice(newline + 1);
      if (!line.startsWith('data:')) continue;
      const data = line.slice(5).trim();
      if (data === '[DONE]') return true;
      if (data) yield JSON.parse(data);
    }
  }
  return false;
}

export function createInworldClient(config, { fetchImpl = fetch } = {}) {
  const { apiKey, apiBase } = config;
  const headers = {
    Authorization: `Basic ${apiKey}`,
    'Content-Type': 'application/json',
  };

  // Mints a single-use token that authenticates exactly one STT connection.
  async function mintToken({ clientReferenceId }) {
    let response;
    try {
      response = await fetchImpl(`${apiBase}/auth/v1/tokens`, {
        method: 'POST',
        headers,
        body: JSON.stringify({
          single_use: true,
          ttl: `${config.tokenTTLSeconds}s`,
          client_reference_id: clientReferenceId,
        }),
        signal: AbortSignal.timeout(config.tokenTimeoutMs),
      });
    } catch (error) {
      throw new UpstreamError(`Token mint request failed: ${error.name}`);
    }
    if (!response.ok) throw upstreamFailure('Token mint', response);

    const { accessToken, expireTime } = await response.json();
    if (typeof accessToken !== 'string' || typeof expireTime !== 'string') {
      throw new UpstreamError('Token mint returned an unexpected response');
    }
    return { accessToken, expireTime };
  }

  // Streams one translation. Yields {type: 'language'|'delta'} events as text
  // arrives and returns the final {translation, language, usage, model}.
  async function* translate({ phrase, context, signal }) {
    const timeout = AbortSignal.timeout(config.translateTimeoutMs);
    const body = {
      model: config.translationModel,
      messages: buildMessages({ phrase, context }),
      stream: true,
      temperature: 0,
      max_tokens: maxOutputTokens(phrase),
    };
    if (config.translationFallbackModels.length > 0) body.models = config.translationFallbackModels;
    if (config.reasoningEffort) body.reasoning_effort = config.reasoningEffort;

    let response;
    try {
      response = await fetchImpl(`${apiBase}/v1/chat/completions`, {
        method: 'POST',
        headers,
        body: JSON.stringify(body),
        signal: signal ? AbortSignal.any([signal, timeout]) : timeout,
      });
    } catch (error) {
      throw new UpstreamError(`Translation request failed: ${error.name}`);
    }
    if (!response.ok) {
      await response.body?.cancel().catch(() => {});
      throw upstreamFailure('Translation', response);
    }

    const parser = new ReplyParser();
    let languageSent = false;
    let usage = null;
    let model = null;
    let finishReason = null;

    function* forward(text) {
      if (parser.language && !languageSent) {
        languageSent = true;
        yield { type: 'language', code: parser.language };
      }
      if (text) yield { type: 'delta', text };
    }

    const events = sseEvents(response.body);
    let completed = false;
    try {
      for (;;) {
        const next = await events.next();
        if (next.done) {
          completed = next.value === true;
          break;
        }
        const event = next.value;
        // After the first chunk the router reports failures in-band.
        if (event.error) throw new UpstreamError('Translation stream reported an error');
        if (event.usage) usage = event.usage;
        if (event.model) model = event.model;
        const choice = event.choices?.[0];
        if (choice?.finish_reason) finishReason = choice.finish_reason;
        yield* forward(parser.push(choice?.delta?.content ?? ''));
      }
    } catch (error) {
      if (error instanceof UpstreamError) throw error;
      throw new UpstreamError(`Translation stream failed: ${error.name}`);
    }
    // A stream that stops without [DONE] is a failed request.
    if (!completed) throw new UpstreamError('Translation stream ended early');
    yield* forward(parser.end());

    return {
      translation: parser.translation,
      language: parser.language,
      truncated: finishReason === 'length',
      model,
      usage: usage && {
        promptTokens: usage.prompt_tokens ?? 0,
        completionTokens: usage.completion_tokens ?? 0,
      },
    };
  }

  return { mintToken, translate };
}
