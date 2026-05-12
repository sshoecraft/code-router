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

const fs = require("fs");
const path = require("path");
const os = require("os");

const ROOT = path.join(os.homedir(), ".claude-code-router");
const TOKENS_DIR = path.join(ROOT, "tokens");
const USED_DIR = path.join(ROOT, "used");
const CACHE_TTL_MS = 5000;

// keyed by provider.name -> { token, readAt }
const cache = new Map();

function readToken(name) {
  const now = Date.now();
  const hit = cache.get(name);
  if (hit && now - hit.readAt < CACHE_TTL_MS) return hit.token;
  try {
    const t = fs.readFileSync(path.join(TOKENS_DIR, `${name}.txt`), "utf8").trim();
    if (t) {
      cache.set(name, { token: t, readAt: now });
      return t;
    }
  } catch (_) {
    // Token file missing or unreadable -- fall through to whatever we have
    // cached (possibly nothing). Empty header lets the upstream 401, which is
    // a clearer signal than silently sending stale or no auth.
  }
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
    const token = pname ? readToken(pname) : "";
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
