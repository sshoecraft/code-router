// Localhost-only admin endpoints used by the `icode` launcher to ask the
// running daemon to mint a token for a configured icode provider and to
// look up that provider's configured model. Together with the per-provider
// token files written here, this lets icode never touch credentials
// directly: the daemon (running as user code-router in system mode, or as
// the invoking user in per-user mode) is the only thing that ever reads
// /etc/icode/config.json or holds an OAuth client_secret.
//
// POST /__admin/prime
//   body: { "provider": "name" }
//   side effects: mints OAuth client_credentials token for `name`,
//     atomically writes ${CCR_DIR}/tokens/<name>.txt, touches
//     ${CCR_DIR}/used/<name> so the timer-driven refresh keeps it warm.
//   returns: { status, provider, type, expires_in }
//
// GET /__admin/model?provider=name
//   returns: text/plain body containing the provider's `model` field
//   from /etc/icode/config.json (or $ICODE_CFG).
//
// Both endpoints reject non-loopback callers with 403.

import * as fs from "fs";
import * as path from "path";
import * as os from "os";
import {
  FastifyInstance,
  FastifyReply,
  FastifyRequest,
} from "fastify";
import { createApiError } from "@/api/middleware";

interface IcodeProvider {
  name: string;
  type?: "openai" | "anthropic";
  client_id: string;
  client_secret: string;
  token_url: string;
  token_scope?: string;
  base_url: string;
  deployment_name?: string;
  api_version?: string;
  model: string;
}

function paths() {
  const icodeCfg =
    process.env.ICODE_CFG ||
    path.join(os.homedir(), ".config", "icode", "config.json");
  const ccrDir =
    process.env.CODE_ROUTER_DIR ||
    path.join(os.homedir(), ".claude-code-router");
  return {
    icodeCfg,
    icodeCfgDir: path.dirname(icodeCfg),
    tokensDir: path.join(ccrDir, "tokens"),
    usedDir: path.join(ccrDir, "used"),
  };
}

// Canonical TOML is `provider = "NAME"`, but accept bare and single-quoted
// forms too so a hand-edited file doesn't trip on missing quotes.
const DEFAULT_RE = /^\s*provider\s*=\s*(.+?)\s*(?:#.*)?$/m;

function readDefaultProvider(): string | null {
  const { icodeCfgDir } = paths();
  const file = path.join(icodeCfgDir, "default.toml");
  let text: string;
  try {
    text = fs.readFileSync(file, "utf8");
  } catch (e: any) {
    if (e?.code === "ENOENT") return null;
    throw new Error(`${file}: ${e.message}`);
  }
  const m = text.match(DEFAULT_RE);
  if (!m) {
    throw new Error(`${file}: expected a line \`provider = "NAME"\``);
  }
  let name = m[1].trim();
  if (
    name.length >= 2 &&
    name[0] === name[name.length - 1] &&
    (name[0] === '"' || name[0] === "'")
  ) {
    name = name.slice(1, -1);
  }
  return name;
}

function loadProviders(): IcodeProvider[] {
  const { icodeCfg } = paths();
  let raw: string;
  try {
    raw = fs.readFileSync(icodeCfg, "utf8");
  } catch (e: any) {
    throw new Error(`${icodeCfg}: ${e.message}`);
  }
  let parsed: any;
  try {
    parsed = JSON.parse(raw);
  } catch (e: any) {
    throw new Error(`${icodeCfg}: invalid JSON: ${e.message}`);
  }
  if (!Array.isArray(parsed.providers) || parsed.providers.length === 0) {
    throw new Error(`${icodeCfg}: 'providers' array missing or empty`);
  }
  return parsed.providers as IcodeProvider[];
}

async function mintToken(
  p: IcodeProvider
): Promise<{ token: string; expiresIn: any }> {
  const body = new URLSearchParams({
    grant_type: "client_credentials",
    scope: p.token_scope || "",
  });
  const creds = Buffer.from(`${p.client_id}:${p.client_secret}`).toString(
    "base64"
  );
  const res = await fetch(p.token_url, {
    method: "POST",
    headers: {
      Authorization: `Basic ${creds}`,
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: body.toString(),
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`HTTP ${res.status}: ${text}`);
  }
  const json = (await res.json()) as any;
  const token: string | undefined = json?.access_token;
  if (!token) {
    throw new Error(`no access_token in response: ${JSON.stringify(json)}`);
  }
  return { token, expiresIn: json.expires_in ?? "?" };
}

function atomicWrite(filepath: string, content: string, mode = 0o600): void {
  const dir = path.dirname(filepath);
  fs.mkdirSync(dir, { recursive: true });
  const tmp = path.join(
    dir,
    `.${path.basename(filepath)}.${process.pid}.${Date.now()}`
  );
  try {
    fs.writeFileSync(tmp, content, { mode });
    fs.renameSync(tmp, filepath);
  } catch (e) {
    try {
      fs.unlinkSync(tmp);
    } catch {}
    throw e;
  }
}

function writeToken(name: string, token: string): void {
  const { tokensDir } = paths();
  atomicWrite(path.join(tokensDir, `${name}.txt`), token + "\n");
}

function touchUsed(name: string): void {
  const { usedDir } = paths();
  fs.mkdirSync(usedDir, { recursive: true });
  const p = path.join(usedDir, name);
  try {
    const now = new Date();
    fs.utimesSync(p, now, now);
  } catch {
    fs.closeSync(fs.openSync(p, "a"));
    try {
      fs.chmodSync(p, 0o600);
    } catch {}
  }
}

function isLoopback(req: FastifyRequest): boolean {
  const ip = req.ip;
  return (
    ip === "127.0.0.1" ||
    ip === "::1" ||
    ip === "::ffff:127.0.0.1"
  );
}

function requireLocalhost(req: FastifyRequest): void {
  if (!isLoopback(req)) {
    throw createApiError(
      "admin endpoints are localhost-only",
      403,
      "forbidden"
    );
  }
}

function findProvider(
  providers: IcodeProvider[],
  name: string
): IcodeProvider {
  const p = providers.find((x) => x.name === name);
  if (!p) {
    throw createApiError(
      `provider '${name}' not found in ICODE_CFG`,
      404,
      "provider_not_found"
    );
  }
  return p;
}

// Reusable prime: mint a fresh token for `name`, atomically write
// tokens/<name>.txt, touch used/<name>. Used by both the /__admin/prime
// route and the in-process 401-retry path in the request handler.
export async function primeProviderByName(
  name: string
): Promise<{ token: string; expiresIn: any }> {
  const providers = loadProviders();
  const p = findProvider(providers, name);
  const result = await mintToken(p);
  writeToken(p.name, result.token);
  touchUsed(p.name);
  return result;
}

export async function registerAdminRoutes(fastify: FastifyInstance) {
  fastify.post<{ Body: { provider: string } }>(
    "/__admin/prime",
    {
      schema: {
        body: {
          type: "object",
          properties: { provider: { type: "string" } },
          required: ["provider"],
        },
      },
    },
    async (req, _reply) => {
      requireLocalhost(req);
      let result;
      try {
        result = await primeProviderByName(req.body.provider);
      } catch (e: any) {
        if (e?.statusCode) throw e; // already shaped by createApiError
        throw createApiError(
          `mint failed for '${req.body.provider}': ${e.message}`,
          502,
          "mint_failed"
        );
      }
      const providers = loadProviders();
      const p = findProvider(providers, req.body.provider);
      return {
        status: "ok",
        provider: p.name,
        type: p.type ?? "openai",
        expires_in: result.expiresIn,
      };
    }
  );

  fastify.get<{ Querystring: { provider: string } }>(
    "/__admin/model",
    {
      schema: {
        querystring: {
          type: "object",
          properties: { provider: { type: "string" } },
          required: ["provider"],
        },
      },
    },
    async (req, reply) => {
      requireLocalhost(req);
      let providers: IcodeProvider[];
      try {
        providers = loadProviders();
      } catch (e: any) {
        throw createApiError(e.message, 500, "config_error");
      }
      const p = findProvider(providers, req.query.provider);
      reply.type("text/plain");
      return p.model;
    }
  );

  fastify.get("/__admin/providers", async (req, _reply) => {
    requireLocalhost(req);
    let providers: IcodeProvider[];
    try {
      providers = loadProviders();
    } catch (e: any) {
      throw createApiError(e.message, 500, "config_error");
    }
    return {
      providers: providers.map((p) => ({
        name: p.name,
        type: p.type ?? "openai",
        model: p.model,
      })),
    };
  });

  // Return the daemon's configured APIKEY (or empty string if none). icode
  // uses this to set ANTHROPIC_AUTH_TOKEN before exec'ing claude, so local
  // sessions keep working after the operator sets APIKEY for network access.
  // Loopback-only — remote callers can't exfiltrate the key.
  fastify.get("/__admin/apikey", async (req: any, reply) => {
    requireLocalhost(req);
    const apiKey = req.server.configService?.get<string>("APIKEY") ?? "";
    reply.type("text/plain");
    return apiKey;
  });

  // Return the default-provider name from <ICODE_CFG_DIR>/default.toml as
  // plaintext, or 404 if no default file exists. icode uses this instead of
  // reading the file directly, so an unprivileged caller never needs to
  // traverse /etc/icode/.
  fastify.get("/__admin/default", async (req, reply) => {
    requireLocalhost(req);
    let name: string | null;
    try {
      name = readDefaultProvider();
    } catch (e: any) {
      throw createApiError(e.message, 500, "config_error");
    }
    if (!name) {
      throw createApiError(
        "no default provider configured",
        404,
        "no_default"
      );
    }
    reply.type("text/plain");
    return name;
  });
}
