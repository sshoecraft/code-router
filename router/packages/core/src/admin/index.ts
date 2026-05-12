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
    tokensDir: path.join(ccrDir, "tokens"),
    usedDir: path.join(ccrDir, "used"),
  };
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
      let providers: IcodeProvider[];
      try {
        providers = loadProviders();
      } catch (e: any) {
        throw createApiError(e.message, 500, "config_error");
      }
      const p = findProvider(providers, req.body.provider);
      let result;
      try {
        result = await mintToken(p);
      } catch (e: any) {
        throw createApiError(
          `mint failed for '${p.name}': ${e.message}`,
          502,
          "mint_failed"
        );
      }
      writeToken(p.name, result.token);
      touchUsed(p.name);
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
}
