// Runtime configuration, read once from the environment at startup.

const DEFAULT_API_BASE = 'https://api.inworld.ai';
const STT_PATH = '/stt/v1/transcribe:streamBidirectional';
const MIN_CLIENT_SECRET_LENGTH = 24;

export class ConfigError extends Error {}

function integer(env, name, fallback, { min = 0, max = Number.MAX_SAFE_INTEGER } = {}) {
  const raw = env[name];
  if (raw === undefined || raw === '') return fallback;
  const value = Number(raw);
  if (!Number.isInteger(value) || value < min || value > max) {
    throw new ConfigError(`${name} must be an integer between ${min} and ${max}`);
  }
  return value;
}

function list(raw) {
  return (raw ?? '')
    .split(',')
    .map((item) => item.trim())
    .filter(Boolean);
}

// CLIENT_KEYS is "id:secret,id:secret". The id names the client in logs and
// keys its usage limits; the secret is what the app presents as a bearer token.
function parseClientKeys(raw) {
  const clients = new Map();
  for (const entry of list(raw)) {
    const separator = entry.indexOf(':');
    const id = separator === -1 ? '' : entry.slice(0, separator);
    const secret = separator === -1 ? '' : entry.slice(separator + 1);
    if (!/^[A-Za-z0-9._-]{1,64}$/.test(id)) {
      throw new ConfigError('CLIENT_KEYS entries must look like "client-id:secret"');
    }
    if (secret.length < MIN_CLIENT_SECRET_LENGTH) {
      throw new ConfigError(
        `CLIENT_KEYS secret for "${id}" must be at least ${MIN_CLIENT_SECRET_LENGTH} characters`,
      );
    }
    if (clients.has(id)) throw new ConfigError(`CLIENT_KEYS has a duplicate id "${id}"`);
    clients.set(id, secret);
  }
  if (clients.size === 0) throw new ConfigError('CLIENT_KEYS must list at least one client');
  return clients;
}

export function loadConfig(env = process.env) {
  const apiKey = (env.INWORLD_API_KEY ?? '').trim();
  if (!apiKey) throw new ConfigError('INWORLD_API_KEY is required');

  const apiBase = (env.INWORLD_API_BASE ?? DEFAULT_API_BASE).replace(/\/+$/, '');
  const sttWebSocketURL =
    env.INWORLD_STT_WS_URL ?? apiBase.replace(/^http/, 'ws') + STT_PATH;

  return {
    host: env.HOST ?? '127.0.0.1',
    port: integer(env, 'PORT', 8787, { max: 65535 }),
    trustProxy: env.TRUST_PROXY === '1' || env.TRUST_PROXY === 'true',

    inworld: {
      apiKey,
      apiBase,
      sttWebSocketURL,
      sttModel: env.STT_MODEL ?? 'inworld/inworld-stt-1',
      translationModel: env.TRANSLATION_MODEL ?? 'google-ai-studio/gemini-2.5-flash-lite',
      translationFallbackModels: list(env.TRANSLATION_FALLBACK_MODELS ?? 'openai/gpt-4o-mini'),
      reasoningEffort: env.TRANSLATION_REASONING_EFFORT || undefined,
      tokenTTLSeconds: integer(env, 'TOKEN_TTL_SECONDS', 120, { min: 15, max: 3600 }),
      tokenTimeoutMs: integer(env, 'TOKEN_TIMEOUT_MS', 10_000, { min: 1000 }),
      translateTimeoutMs: integer(env, 'TRANSLATE_TIMEOUT_MS', 15_000, { min: 1000 }),
    },

    clients: parseClientKeys(env.CLIENT_KEYS),

    limits: {
      // One token is one STT connection, so this caps starts and reconnects.
      tokensPerMinute: integer(env, 'LIMIT_TOKENS_PER_MINUTE', 6, { min: 1 }),
      tokensPerDay: integer(env, 'LIMIT_TOKENS_PER_DAY', 300, { min: 1 }),
      // Inworld allows 60 mints per minute per API key, shared by every client.
      globalTokensPerMinute: integer(env, 'LIMIT_GLOBAL_TOKENS_PER_MINUTE', 50, { min: 1 }),
      translationsPerMinute: integer(env, 'LIMIT_TRANSLATIONS_PER_MINUTE', 60, { min: 1 }),
      translationsPerDay: integer(env, 'LIMIT_TRANSLATIONS_PER_DAY', 5000, { min: 1 }),
      translationCharsPerDay: integer(env, 'LIMIT_TRANSLATION_CHARS_PER_DAY', 400_000, { min: 1 }),
      concurrentTranslations: integer(env, 'LIMIT_CONCURRENT_TRANSLATIONS', 4, { min: 1 }),
      failedAuthPerMinute: integer(env, 'LIMIT_FAILED_AUTH_PER_MINUTE', 20, { min: 1 }),
    },

    request: {
      maxBodyBytes: 16 * 1024,
      maxPhraseChars: 2000,
      maxContextItems: 4,
      maxContextChars: 500,
    },
  };
}
