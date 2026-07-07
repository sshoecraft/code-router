---
name: opus-503-pkix-is-gateway-cert
description: icode/opus 503 "PKIX path validation failed: validity check failed" is a McKesson gateway backend-cert problem, not a router bug. Isolate via an open…
metadata:
  type: reference
tags: [icode, opus, troubleshooting, gateway, tls, 503, anthropic]
---

When `icode`/opus returns HTTP 503 with body:

```
Error from provider(opus,mt-genai-claude-opus-4-5-...: 503):
  "HTTP POST on resource 'https://mckopenai-nonprod.appgw.mckesson.com/anthropic/v1/messages'
   failed: PKIX path validation failed: java.security.cert.CertPathValidatorException: validity check failed."
```

this is **NOT a router/icode bug**. The gateway received our request fine, then failed to validate the cert of its own `/anthropic` backend hop (`validity check failed` = expired / not-yet-valid cert on McKesson's side). Server-side outage, nothing to patch in code-router.

**Fast isolation test** (loopback, no interactive claude needed):
```bash
KEY=$(curl -s http://127.0.0.1:3456/__admin/apikey)
curl -s http://127.0.0.1:3456/v1/messages -H "x-api-key: $KEY" \
  -H "anthropic-version: 2023-06-01" -H content-type:application/json \
  -d '{"model":"gpt54","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}'
```
If an **openai** provider (gpt51/gpt54) returns a real model response through the SAME daemon while opus 503s, the gateway is up and our TLS/CA is fine — the fault is isolated to the gateway's Anthropic backend. Confirmed this way on 2026-07-07 (openai worked, anthropic 503'd). Also seen: the gateway frontend leaf cert (`mckopenai-nonprod.appgw.mckesson.com`) itself on a 1-year rotation expiring Jul 7 — so cert renewals on McKesson's side are the usual root cause; wait for them to rotate, or escalate to McKesson gateway ops.

**Routing is fine, independently verified:** model resolution correctly maps `claude-opus-4-8[1m]` (the "Opus 4.8 (1M context)" model id — note the `[1m]` suffix), plain `claude-opus-4-8`, explicit `opus,<model>`, and background `claude-haiku-4-5` all to the `opus` provider. The `[1m]` suffix does NOT break routing: exact-match on `Router.aliases` misses, but the substring fallback in `resolveModelOrError` (server.ts) catches `opus` inside the string. See [[mac-claude-code-env]] for the alias map.
