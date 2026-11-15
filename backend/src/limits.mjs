// In-memory usage limits: token buckets for short-term rate and per-day
// counters for quota. State lives in this process, so run a single instance or
// replace this module with a shared store before scaling out.

const DAY_MS = 24 * 60 * 60 * 1000;

export class RateLimiter {
  #buckets = new Map();
  #now;

  constructor({ now = Date.now } = {}) {
    this.#now = now;
  }

  // Takes one unit from a bucket that refills `perMinute` units per minute and
  // holds at most `burst`. Returns how long to wait when the bucket is empty.
  take(key, { perMinute, burst = perMinute }) {
    const now = this.#now();
    const refillPerMs = perMinute / 60_000;
    const bucket = this.#buckets.get(key) ?? { tokens: burst, updatedAt: now };
    bucket.tokens = Math.min(burst, bucket.tokens + (now - bucket.updatedAt) * refillPerMs);
    bucket.updatedAt = now;
    this.#buckets.set(key, bucket);

    if (bucket.tokens >= 1) {
      bucket.tokens -= 1;
      return { allowed: true, retryAfterSeconds: 0 };
    }
    const retryAfterSeconds = Math.max(1, Math.ceil((1 - bucket.tokens) / refillPerMs / 1000));
    return { allowed: false, retryAfterSeconds };
  }

  // Drops buckets that have refilled completely; they carry no information.
  sweep(maxIdleMs = 10 * 60_000) {
    const cutoff = this.#now() - maxIdleMs;
    for (const [key, bucket] of this.#buckets) {
      if (bucket.updatedAt < cutoff) this.#buckets.delete(key);
    }
  }
}

export class DailyQuota {
  #day = -1;
  #used = new Map();
  #now;

  constructor({ now = Date.now } = {}) {
    this.#now = now;
  }

  #roll() {
    const day = Math.floor(this.#now() / DAY_MS);
    if (day !== this.#day) {
      this.#day = day;
      this.#used.clear();
    }
  }

  used(key) {
    this.#roll();
    return this.#used.get(key) ?? 0;
  }

  // Adds `amount` if the total stays within `limit`. The quota resets at 00:00 UTC.
  consume(key, amount, limit) {
    this.#roll();
    const next = (this.#used.get(key) ?? 0) + amount;
    if (next > limit) {
      const msLeft = DAY_MS - (this.#now() % DAY_MS);
      return { allowed: false, retryAfterSeconds: Math.max(1, Math.ceil(msLeft / 1000)) };
    }
    this.#used.set(key, next);
    return { allowed: true, retryAfterSeconds: 0 };
  }
}

export class ConcurrencyGate {
  #active = new Map();

  enter(key, limit) {
    const active = this.#active.get(key) ?? 0;
    if (active >= limit) return false;
    this.#active.set(key, active + 1);
    return true;
  }

  leave(key) {
    const active = (this.#active.get(key) ?? 1) - 1;
    if (active <= 0) this.#active.delete(key);
    else this.#active.set(key, active);
  }
}
