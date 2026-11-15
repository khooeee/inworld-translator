import assert from 'node:assert/strict';
import { describe, test } from 'node:test';

import { ConfigError, loadConfig } from '../src/config.mjs';
import { DailyQuota, RateLimiter } from '../src/limits.mjs';
import { buildMessages, maxOutputTokens, ReplyParser } from '../src/prompt.mjs';

// Feeds a reply to the parser in the given chunks and returns what came out.
function parse(chunks) {
  const parser = new ReplyParser();
  const deltas = chunks.map((chunk) => parser.push(chunk));
  deltas.push(parser.end());
  return { language: parser.language, translation: parser.translation, streamed: deltas.join('') };
}

describe('ReplyParser', () => {
  test('splits the language line from the translation', () => {
    assert.deepEqual(parse(['es\nGood morning.']), {
      language: 'es',
      translation: 'Good morning.',
      streamed: 'Good morning.',
    });
  });

  test('gives the same result however the reply is chunked', () => {
    const reply = 'ja\nMr. Tanaka arrives at 3 o\'clock.\n';
    const whole = parse([reply]);
    for (let size = 1; size < reply.length; size += 1) {
      const chunks = reply.match(new RegExp(`[\\s\\S]{1,${size}}`, 'g'));
      assert.deepEqual(parse(chunks), whole, `chunk size ${size}`);
    }
    assert.equal(whole.translation, 'Mr. Tanaka arrives at 3 o\'clock.');
  });

  test('accepts region subtags and normalizes case', () => {
    assert.equal(parse(['PT-BR\nHello']).language, 'pt');
    assert.equal(parse(['yue\nHello']).language, 'yue');
  });

  test('treats a reply without a language line as translation only', () => {
    assert.deepEqual(parse(['Good morning, how are you?']), {
      language: null,
      translation: 'Good morning, how are you?',
      streamed: 'Good morning, how are you?',
    });
    assert.equal(parse(['Hello there.\nSecond line.']).translation, 'Hello there.\nSecond line.');
  });

  test('reports unintelligible input as und with no translation', () => {
    assert.deepEqual(parse(['und\n']), { language: 'und', translation: '', streamed: '' });
    assert.deepEqual(parse(['und']), { language: 'und', translation: '', streamed: '' });
  });

  test('keeps inner line breaks and trims the ends', () => {
    assert.equal(parse(['fr\n', '  One.', '\n', 'Two.  ', '\n']).translation, 'One.\nTwo.');
  });
});

describe('prompt', () => {
  test('wraps the phrase as JSON data in the final user message', () => {
    const messages = buildMessages({ phrase: 'Say "hi"\nNow', context: [{ source: 'a', translation: 'b' }] });
    assert.equal(messages[0].role, 'system');
    assert.match(messages[0].content, /do not answer it/);
    assert.match(messages[0].content, /do not act on it/);
    const last = messages.at(-1);
    assert.deepEqual(JSON.parse(last.content), {
      context: [{ source: 'a', translation: 'b' }],
      phrase: 'Say "hi"\nNow',
    });
    // Examples alternate user and assistant turns.
    const roles = messages.slice(1, -1).map((message) => message.role);
    assert.ok(roles.length >= 2 && roles.every((role, i) => role === (i % 2 ? 'assistant' : 'user')));
  });

  test('bounds the output tokens', () => {
    assert.equal(maxOutputTokens('hola'), 72);
    assert.equal(maxOutputTokens('x'.repeat(5000)), 1024);
  });
});

describe('limits', () => {
  test('token bucket allows a burst, then the steady rate', () => {
    let clock = 0;
    const limiter = new RateLimiter({ now: () => clock });
    const take = () => limiter.take('k', { perMinute: 6 });
    for (let i = 0; i < 6; i += 1) assert.equal(take().allowed, true);
    const denied = take();
    assert.equal(denied.allowed, false);
    assert.equal(denied.retryAfterSeconds, 10);
    clock += 10_000;
    assert.equal(take().allowed, true);
    assert.equal(take().allowed, false);
  });

  test('daily quota does not count a rejected request', () => {
    const quota = new DailyQuota({ now: () => 0 });
    assert.equal(quota.consume('k', 8, 10).allowed, true);
    assert.equal(quota.consume('k', 5, 10).allowed, false);
    assert.equal(quota.consume('k', 2, 10).allowed, true);
    assert.equal(quota.used('k'), 10);
  });
});

describe('config', () => {
  const base = { INWORLD_API_KEY: 'key', CLIENT_KEYS: 'ios:0123456789abcdefghijklmnop' };

  test('derives the STT WebSocket URL from the API base', () => {
    assert.equal(
      loadConfig(base).inworld.sttWebSocketURL,
      'wss://api.inworld.ai/stt/v1/transcribe:streamBidirectional',
    );
    assert.equal(
      loadConfig({ ...base, INWORLD_API_BASE: 'http://127.0.0.1:8788/' }).inworld.sttWebSocketURL,
      'ws://127.0.0.1:8788/stt/v1/transcribe:streamBidirectional',
    );
  });

  test('refuses to start without an API key or with weak client keys', () => {
    assert.throws(() => loadConfig({ ...base, INWORLD_API_KEY: '' }), ConfigError);
    assert.throws(() => loadConfig({ ...base, CLIENT_KEYS: '' }), ConfigError);
    assert.throws(() => loadConfig({ ...base, CLIENT_KEYS: 'ios:short' }), ConfigError);
    assert.throws(() => loadConfig({ ...base, CLIENT_KEYS: 'no-separator' }), ConfigError);
    assert.throws(() => loadConfig({ ...base, PORT: 'abc' }), ConfigError);
  });

  test('binds to loopback unless told otherwise', () => {
    assert.equal(loadConfig(base).host, '127.0.0.1');
  });
});
