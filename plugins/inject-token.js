// inject-token.js
//
// Reads the active provider's OAuth bearer token from disk per request and
// injects it into the outbound Authorization header. Pairs with
// code-router-refresh-token, which writes tokens/<provider>.txt every ~30 min
// for every "warm" provider in the active set.
//
// Goal: the single CCR daemon serves multiple providers concurrently. Each
// request carries `provider.name` (set by CCR's router based on the incoming
// `model = "name,model"` field), and we look up tokens/<name>.txt for that
// provider. Touching used/<name> on every call signals the timer that this
// provider is still in use, so its token keeps getting refreshed.
//
// 5s in-process cache per provider so we don't hit the filesystem on every
// single request, while still picking up rotated tokens promptly.
//
// Auto-prime: if no token file exists for a provider, we call the local
// /__admin/prime endpoint to mint one before proceeding.

const fs = require("fs");
const path = require("path");
const os = require("os");

const ROOT = path.join(os.homedir(), ".claude-code-router");
const TOKENS_DIR = path.join(ROOT, "tokens");
const USED_DIR = path.join(ROOT, "used");
const CACHE_TTL_MS = 5000;
const PRIME_URL = "http://127.0.0.1:3456/__admin/prime";

// keyed by provider.name -> { token, readAt }
const cache = new Map();

// Track in-flight prime requests to avoid duplicate calls
const primeInFlight = new Map();

async function primeProvider(name) {
  // Check if already priming this provider
  if (primeInFlight.has(name)) {
    return primeInFlight.get(name);
  }

  const promise = (async () => {
    try {
      const res = await fetch(PRIME_URL, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ provider: name }),
      });
      if (!res.ok) {
        const text = await res.text();
        console.error(`[inject-token] prime failed for ${name}: ${res.status} ${text}`);
        return null;
      }
      // Token file should now exist; read it
      const t = fs.readFileSync(path.join(TOKENS_DIR, `${name}.txt`), "utf8").trim();
      if (t) {
        cache.set(name, { token: t, readAt: Date.now() });
        return t;
      }
    } catch (e) {
      console.error(`[inject-token] prime error for ${name}:`, e.message);
    }
    return null;
  })();

  primeInFlight.set(name, promise);
  try {
    return await promise;
  } finally {
    primeInFlight.delete(name);
  }
}

function readTokenSync(name) {
  try {
    const t = fs.readFileSync(path.join(TOKENS_DIR, `${name}.txt`), "utf8").trim();
    if (t) {
      cache.set(name, { token: t, readAt: Date.now() });
      return t;
    }
  } catch (_) {}
  return null;
}

async function readToken(name) {
  const now = Date.now();
  const hit = cache.get(name);
  if (hit && now - hit.readAt < CACHE_TTL_MS) return hit.token;

  // Try reading from disk
  const t = readTokenSync(name);
  if (t) return t;

  // No token file - auto-prime
  const primed = await primeProvider(name);
  if (primed) return primed;

  // Fall back to cached value if any
  return hit ? hit.token : "";
}

function touchUsed(name) {
  const p = path.join(USED_DIR, name);
  try {
    const now = new Date();
    fs.utimesSync(p, now, now);
  } catch (_) {
    // Marker missing -- create it.
    try {
      fs.mkdirSync(USED_DIR, { recursive: true });
      fs.closeSync(fs.openSync(p, "a"));
    } catch (_) {
      // Read-only FS or perms issue. Not fatal; the worst case is that the
      // timer doesn't see this provider as warm and lets its token expire.
    }
  }
}

class InjectToken {
  name = "inject-token";

  async transformRequestIn(request, provider) {
    const pname = provider && provider.name ? provider.name : "";
    const token = pname ? await readToken(pname) : "";
    if (pname) touchUsed(pname);
    return {
      body: request,
      config: {
        headers: {
          Authorization: token ? `Bearer ${token}` : undefined,
          "Content-Type": "application/json",
        },
      },
    };
  }
}

module.exports = InjectToken;
