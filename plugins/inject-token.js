// inject-token.js
//
// Reads a fresh OAuth bearer token from disk per request and injects it into
// the outbound `Authorization` header. Pairs with code-router-refresh-token,
// which writes the token to TOKEN_FILE every ~30 minutes.
//
// Goal: tokens rotate without restarting the CCR daemon. In-flight sessions
// keep working; concurrent sessions share the same daemon. The previous
// design (rewrite config + `ccr restart`) killed any in-flight requests.
//
// Reads are cached for 5 seconds in-process to avoid hitting the filesystem
// on every single request while still picking up rotated tokens promptly.

const fs = require("fs");
const path = require("path");
const os = require("os");

const TOKEN_FILE = path.join(os.homedir(), ".claude-code-router", "token.txt");
const CACHE_TTL_MS = 5000;

let cached = { token: "", readAt: 0 };

function getToken() {
  const now = Date.now();
  if (cached.token && now - cached.readAt < CACHE_TTL_MS) {
    return cached.token;
  }
  try {
    const t = fs.readFileSync(TOKEN_FILE, "utf8").trim();
    if (t) {
      cached = { token: t, readAt: now };
      return t;
    }
  } catch (e) {
    // Fall through to whatever we have cached; if nothing, return empty
    // and let the upstream reject with 401 -- that's a clearer signal than
    // silently sending a stale or missing token.
  }
  return cached.token;
}

class InjectToken {
  name = "inject-token";

  async transformRequestIn(request, provider) {
    const token = getToken();
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
