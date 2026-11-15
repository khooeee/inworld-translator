import { createHash, timingSafeEqual } from 'node:crypto';

const digest = (value) => createHash('sha256').update(value).digest();

// Resolves the bearer secret on a request to a configured client id. Every
// configured secret is compared, in constant time, so the response time does
// not reveal which client ids exist or how much of a secret matched.
export function createAuthenticator(clients) {
  const entries = [...clients].map(([id, secret]) => ({ id, digest: digest(secret) }));

  return function authenticate(req) {
    const header = req.headers.authorization ?? '';
    const match = /^Bearer\s+(\S+)$/i.exec(header);
    if (!match) return null;

    const presented = digest(match[1]);
    let clientId = null;
    for (const entry of entries) {
      if (timingSafeEqual(presented, entry.digest)) clientId = entry.id;
    }
    return clientId;
  };
}
