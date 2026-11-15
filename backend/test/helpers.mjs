import { createServer } from 'node:http';

import { createApp } from '../src/app.mjs';
import { loadConfig } from '../src/config.mjs';
import { startMockInworld } from '../tools/mock-inworld.mjs';

export const CLIENT_SECRET = 'test-secret-0123456789abcdefghij';
export const OTHER_SECRET = 'other-secret-0123456789abcdefghi';

// Starts the backend against a mock Inworld, both on ephemeral ports.
export async function startStack({ env = {}, mock: mockOptions = {}, now } = {}) {
  const mock = await startMockInworld({ chunkDelayMs: 1, ...mockOptions });
  const config = loadConfig({
    INWORLD_API_KEY: mock.apiKey,
    INWORLD_API_BASE: mock.url,
    CLIENT_KEYS: `ios-test:${CLIENT_SECRET},ios-other:${OTHER_SECRET}`,
    ...env,
  });
  const logs = [];
  const server = createServer(createApp(config, { log: (entry) => logs.push(entry), now }));
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const url = `http://127.0.0.1:${server.address().port}`;

  const post = (path, body, { secret = CLIENT_SECRET, signal } = {}) =>
    fetch(url + path, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        ...(secret ? { Authorization: `Bearer ${secret}` } : {}),
      },
      body: JSON.stringify(body ?? {}),
      signal,
    });

  return {
    url,
    mock,
    config,
    logs,
    post,
    close: async () => {
      server.closeAllConnections();
      await new Promise((resolve) => server.close(resolve));
      await mock.close();
    },
  };
}

// Reads a translate response body into its list of SSE events.
export async function readEvents(response) {
  const text = await response.text();
  return text
    .split('\n')
    .filter((line) => line.startsWith('data:'))
    .map((line) => JSON.parse(line.slice(5)));
}
