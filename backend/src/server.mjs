import { createServer } from 'node:http';

import { createApp } from './app.mjs';
import { ConfigError, loadConfig } from './config.mjs';

let config;
try {
  config = loadConfig();
} catch (error) {
  if (!(error instanceof ConfigError)) throw error;
  console.error(`Configuration error: ${error.message}`);
  console.error('Copy .env.example to .env and fill it in. See README.md.');
  process.exit(1);
}

const server = createServer(createApp(config));
server.requestTimeout = 30_000;
server.headersTimeout = 10_000;

server.listen(config.port, config.host, () => {
  console.log(
    JSON.stringify({
      time: new Date().toISOString(),
      event: 'listening',
      address: `http://${config.host}:${config.port}`,
      clients: [...config.clients.keys()],
      translationModel: config.inworld.translationModel,
    }),
  );
});

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => {
    server.close(() => process.exit(0));
    server.closeAllConnections();
  });
}
