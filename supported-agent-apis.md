# Supported agent APIs

The Subconscious API Gateway exposes OpenAI- and Anthropic-shaped HTTP APIs for
coding agents and other OpenAI-compatible clients. All inference paths share the
same authentication, model access policy, limits, metering, retries, and
provider routing.

Your public origin is the dashboard/API hostname you configured at deploy time
(for example `https://gateway.example.com`). Create an org API key in the
dashboard and send it on every request.

## Endpoints

| Method | Path | Typical clients |
| --- | --- | --- |
| `GET` | `/v1/models` | Any OpenAI-compatible SDK |
| `POST` | `/v1/chat/completions` | OpenAI Chat Completions clients |
| `POST` | `/v1/responses` | OpenAI Codex (`wire_api = "responses"`) |
| `POST` | `/v1/messages` | Anthropic Messages / Claude Code |

Streaming and non-streaming are supported on the chat, Responses, and Messages
paths.

### Authentication

- OpenAI-shaped endpoints (`/v1/models`, `/v1/chat/completions`, `/v1/responses`):
  `Authorization: Bearer <gateway-api-key>`
- Anthropic Messages (`/v1/messages`): `x-api-key: <gateway-api-key>`, or the
  same Bearer header as above

`GET /v1/models` returns only models available to the authenticated key. An
explicit key `model_ids` restriction takes precedence over organization model
access.

Optional request correlation: send `x-request-id`. The gateway preserves it
through routing and usage events and returns it on responses. If omitted, it
generates a `req_...` ID.

## Conversations (automatic agent correlation)

The dashboard **Conversations** view groups related coding-agent requests when
the client already sends native session or trace headers. No custom gateway
header configuration is required for Claude Code, Codex, OpenCode, Pi, Portkey,
or LiteLLM.

| Client | Native signal used for grouping |
| --- | --- |
| Claude Code | `x-claude-code-session-id` (Messages `metadata.user_id` session fallback) |
| Codex | `thread-id` / session metadata / `prompt_cache_key` |
| OpenCode | `x-session-affinity` + `x-session-id` (+ `x-parent-session-id` for parent link). For reliable detection, set `headers["x-subconscious-client"]: "opencode"` in your provider config. |
| Pi | Requires `compat.sendSessionAffinityHeaders: true` in `models.json` (Pi sends no session headers by default). Use `sessionAffinityFormat: "openai-nosession"` to send `x-session-affinity` without the underscore `session_id` header. For reliable detection, set `headers["x-subconscious-client"]: "pi"` in your provider config. |
| Portkey / LiteLLM | `x-portkey-trace-id` / `x-litellm-trace-id` / `x-litellm-session-id` |
| Cursor | Install the hook via [`coding-agents/cursor/`](coding-agents/cursor/). One `POST /v1/agent-hooks` per prompt; the gateway chains the rest of the conversation onto it. |
| GitHub Copilot (VS Code) | Install the hook via [`coding-agents/copilot/`](coding-agents/copilot/). Same one-call-per-prompt contract as Cursor, plus `x-subconscious-client: copilot` on model requests. |

Bare SDK traffic without those signals stays on **Requests** only.

Cursor and Copilot hooks do not modify model HTTP — neither editor can stamp a
conversation onto an inference request. Instead each announces a prompt once,
and the gateway links every later turn of that conversation by matching the
assistant turn its history ends with. That covers multi-turn tool loops and
subagents without any further hook events. See
[`coding-agents/cursor/README.md`](coding-agents/cursor/README.md) and
[`coding-agents/copilot/README.md`](coding-agents/copilot/README.md).

For correlated traffic, the gateway’s OpenTelemetry / Datadog `trace_id` is the
conversation UUID as 32 lowercase hex characters (no dashes). Filter on that
value in Datadog APM to see the full agent run. Uncorrelated requests keep a
per-request `trace_id`.

### Gateway Conversations vs Datadog Agent Observability Sessions

**Gateway Conversations** (this product) groups coding-agent HTTP turns in the
dashboard and stores usage/savings. **Datadog Agent Observability Sessions** are
a separate Datadog product for instrumenting the agent runtime (Agent → Tool →
LLM trees, often with prompts/completions). The gateway is an inference proxy
and does not replace Datadog Sessions.

When LLM Observability export is enabled (`observability.llmObs` / 
`SUBCONSCIOUS_GATEWAY_LLM_OBS_ENABLED` with an OTLP endpoint), correlated
inferences emit a metadata-only GenAI LLM span with
`gen_ai.conversation.id` set to the gateway conversation UUID. Datadog maps
that attribute to `session_id`, so gateway LLM spans can **join** a Datadog
session that your agent instrumentation also tags with the same id. Spans stay
metadata-only (no prompts or completions).

Advanced optional overrides (not required for Conversations):

- `x-subconscious-trace-id` — manual grouping key
- `x-subconscious-client` — force `claude_code` / `codex` / `opencode` / `pi` / `cursor`

Do not reuse one static `x-subconscious-trace-id` across unrelated processes.

## Error contract

JSON errors and streaming SSE error events use the same envelope:

```json
{
  "error": {
    "message": "provider is busy",
    "type": "rate_limit_error",
    "param": null,
    "code": "rate_limited",
    "request_id": "req_...",
    "details": {
      "retry_after_seconds": 17
    }
  }
}
```

`type` and `param` follow the OpenAI shape. `code`, `request_id`, and `details`
are gateway extensions. A non-null `retry_after_seconds` is also emitted as the
HTTP `Retry-After` header. The gateway accepts both downstream Retry-After
forms: delay seconds and an HTTP date.

An error received before a streaming response begins is returned with its real
HTTP status and this JSON envelope. Once an SSE body has begun, HTTP status is
already committed; a terminal error is sent as one normalized SSE event
followed by `[DONE]` (OpenAI chat) or the protocol-native terminal event
(Responses / Anthropic).

Anthropic Messages maps gateway errors into Anthropic-shaped error objects for
Claude Code clients while preserving the same underlying status and retry
semantics.

## `subconscious` response extension

Successful non-streaming OpenAI chat completions add one top-level object:

```json
{
  "subconscious": {
    "request_id": "req_...",
    "logical_model": "glm-5.2",
    "trace_id": "..."
  }
}
```

This object is additive: standard OpenAI response fields are unchanged, and
clients must ignore unknown fields. Streaming chunks remain provider-shaped and
do not receive this top-level object; use `x-request-id` for correlation.

When usage contains gateway-specific cache data:

```json
{
  "usage": {
    "prompt_tokens": 10,
    "completion_tokens": 4,
    "total_tokens": 14,
    "subconscious": {
      "prefix_cache_hit_tokens": 3,
      "suffix_cache_hit_tokens": 0,
      "pruned_tokens": 0
    }
  }
}
```

Ignore extension fields you do not understand. Internal routing headers such as
`x-subconscious-target-model` are not customer API fields.

## Codex — `POST /v1/responses`

`POST /v1/responses` is a stateless compatibility adapter for Codex. It
translates Responses request items into the gateway chat pipeline, so policy and
metering match `/v1/chat/completions`. Streaming chat chunks are returned as
typed Responses SSE events ending in `response.completed`; the Chat Completions
`[DONE]` marker is not exposed.

Supported:

- instructions and user, developer, system, and assistant text messages
- input images on routes whose underlying model supports vision
- replayed plaintext reasoning summaries and `reasoning.effort`
- function calls and function outputs across Codex agent turns
- Codex custom/freeform tools such as `apply_patch` (bridged as a function with
  a string `input` argument)
- Responses `local_shell` (bridged as a function with a shell action argument)
- `max_output_tokens`, `parallel_tool_calls`, and JSON-schema text format
- streaming and non-streaming Responses-shaped usage

Not supported (rejected with `invalid_request_error`):

- opaque encrypted reasoning
- `store: true`, `previous_response_id`

Hosted tools (`web_search`, `code_interpreter`, `mcp`, `file_search`,
`computer_use_preview`, `image_generation`) are silently skipped at any level —
Codex sends `web_search` by default, so rejecting it would block the entire
request. Unknown tool types are still rejected.

Codex `namespace` tool wrappers are flattened into ordinary function tools
(hosted tools nested inside a namespace are also skipped). Harmless Codex controls
with no chat equivalent (`include`, `service_tier`, and Responses stream
options) are accepted but not forwarded. `prompt_cache_key` is accepted and may
be used as a Codex session fallback for Conversations correlation; it is not
forwarded upstream.

Configure Codex in `~/.codex/config.toml` (provider settings must be user-level).
Codex also needs a model catalog JSON file to suppress the "model metadata not
found" warning — without it, Codex uses degraded defaults:

```toml
model = "gw-glm-5.2"
model_provider = "subconscious"
model_catalog_json = "~/.codex/model-catalog.json"

[model_providers.subconscious]
name = "Subconscious Gateway"
base_url = "https://gateway.example.com/v1"
wire_api = "responses"
env_key = "SUBCONSCIOUS_API_KEY"
stream_idle_timeout_ms = 300000
```

```json title="~/.codex/model-catalog.json"
{
  "models": [
    {
      "slug": "gw-glm-5.2",
      "display_name": "Subconscious GLM 5.2",
      "description": "Subconscious API Gateway GLM 5.2",
      "context_window": 200000,
      "max_context_window": 200000,
      "auto_compact_token_limit": 180000,
      "effective_context_window_percent": 95,
      "supported_reasoning_levels": [],
      "shell_type": "shell_command",
      "visibility": "list",
      "supported_in_api": true,
      "priority": 0,
      "availability_nux": null,
      "upgrade": null,
      "base_instructions": "You are Codex, a coding agent.",
      "supports_reasoning_summaries": false,
      "support_verbosity": false,
      "default_verbosity": null,
      "apply_patch_tool_type": "freeform",
      "truncation_policy": { "mode": "tokens", "limit": 10000 },
      "supports_parallel_tool_calls": true,
      "experimental_supported_tools": []
    }
  ]
}
```

```sh
export SUBCONSCIOUS_API_KEY="sk-gw-..."
codex
```

Replace `base_url` with your deployed gateway origin plus `/v1`. The
`model_catalog_json` key must be at the root level of `config.toml`, not
nested under `[model_providers.*]`.

## Claude Code — `POST /v1/messages`

`POST /v1/messages` is an Anthropic Messages compatibility adapter for Claude
Code. Requests are translated into the same internal chat pipeline as
`/v1/chat/completions`, so auth, model access, limits, metering, and retries are
identical. Streaming responses are emitted as Anthropic SSE events.

Point Claude Code (or any Anthropic Messages client) at your gateway origin and
authenticate with your gateway API key via `x-api-key` (or Bearer). Use model
names from `GET /v1/models` / the dashboard for your org.

## Timeouts and retries

The gateway applies independent connect, response-header, idle-body, and total
deadlines. Retries use jittered exponential backoff and a process-local retry
budget. Only failures with safe replay evidence are retried:

- connection establishment failed before a connection was usable; or
- downstream explicitly returned 408, 429, 502, 503, or 504

A response-header timeout is not replayed (the provider may already be
generating). A streaming request is never retried after the first downstream
response body bytes are exposed to the client. Every replay carries the same
`Idempotency-Key` and `x-request-id`.

Operators can tune total and per-phase deadlines and max attempts via gateway
configuration (`SUBCONSCIOUS_GATEWAY_REQUEST_TIMEOUT_SECONDS`,
`SUBCONSCIOUS_GATEWAY_DOWNSTREAM_*_TIMEOUT_SECONDS`,
`SUBCONSCIOUS_GATEWAY_PROVIDER_RETRY_MAX_ATTEMPTS`). Defaults ship with the
chart; you normally do not need to change them.

## Context length and tokenizers

Every model route has a `context_length`. Staff can set an optional
`tokenizer_model` on the endpoint in the dashboard after registering that name
with the route’s SGL Model Gateway `/v1/tokenize` endpoint. The gateway then
uses the returned token count plus requested output tokens for context
validation and token-limit reservation. An explicitly configured tokenizer that
cannot be reached fails closed with 503.

Routes without `tokenizer_model` use a local heuristic fallback. Leaving the
field empty avoids applying the wrong tokenizer to arbitrary provider routes.

## API-key rotation grace

The dashboard **Rotate key** action keeps the key prefix stable, replaces the
stored current secret, and retains only the previous secret hash until
`rotation_grace_until` (default 300 seconds). Update clients during that window,
then treat the old secret as expired. Auth caches are invalidated at rotation so
TTL cannot extend the grace period across gateway replicas.
