# Spike: OpenAI Secure MCP Tunnel (Phase 5c)

Status: research only, October 5, 2026. No code depends on it. Decision: **not adopted for 0.5.0**; revisit when the blockers below change.

## What it is

OpenAI's `tunnel-client` ([openai/tunnel-client](https://github.com/openai/tunnel-client)) runs next to an MCP server and long-polls OpenAI over outbound HTTPS. ChatGPT, Codex and the Responses API send MCP requests to OpenAI, which hands them to the client. The client forwards them to a local MCP command (stdio) or URL (`--mcp-server-url`). There's no public URL and no inbound port, which is what made it interesting for Remote Access: nothing on the Mac would be reachable from the internet.

Pointed at the Remote Access port, it would look like a tunnel that rewrites `Host`:

```
tunnel-client run --mcp-server-url http://127.0.0.1:47616/r/<secret>/mcp …
```

## The plan's three questions

| Question (MCP-PLAN §22.9) | Finding | Source |
| --- | --- | --- |
| Does OAuth discovery work through it with our issuer? | Discovery documents travel through the tunnel, but the **authorization server isn't tunneled**: the user's browser must reach it directly. Our authorization server lives on the same Remote Access port, behind the same tunnel, so with `tunnel-client` alone the browser can't open `/oauth/authorize`. ChatGPT needs OAuth (it can't send custom API keys), so ChatGPT can't connect this way unless the authorization pages are also published some other way. That puts back the public exposure the tunnel was meant to avoid. | [OpenAI guide](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels) |
| Can personal (non-organization) workspaces create and use tunnels? | Not reliably. An open issue reports that a ChatGPT Pro personal workspace gets `401 tunnel_active_organization_required` on every tool call, before anything reaches the MCP server (tunnel-client 0.0.12). Tunnels also need Platform roles ("Tunnels Read + Use"), and permission changes can take about 30 minutes to apply. | [openai/tunnel-client#60](https://github.com/openai/tunnel-client/issues/60), [end-user guide](https://github.com/openai/tunnel-client/blob/master/docs/end-user-guide.md) |
| What's the `Host` header? | Not documented. An HTTP client normally derives `Host` from the upstream URL, which would be `127.0.0.1:47616`. The Remote Access `Host` allowlist already accepts that. Needs a live run to confirm. | — |

## Decision

Don't recommend or build anything for it in 0.5.0:

- The products this app most needs it for (ChatGPT) authenticate only with OAuth, and the authorization pages wouldn't be reachable through it.
- The likely user (a person with ChatGPT Plus or Pro) is the case reported broken.
- Bearer-token products (the Responses API, Codex) already work through a normal tunnel with a remote token. The tunnel docs don't say whether the Responses API's `authorization` field is passed through to a tunneled server.

A user can still try it as **Other tunnel**: point `--mcp-server-url` at the MCP URL with `127.0.0.1:<port>` as the host, then click Test. Nothing in the app prevents it.

## Revisit when

- personal workspaces can use tunnels (issue #60 closed); and
- either the tunnel can carry the authorization server's browser pages, or ChatGPT accepts a static credential for tunneled connectors.

Then: run it live against the offline harness, record the `Host` header, and add it to the tunnel picker if the pairing flow works end to end.
