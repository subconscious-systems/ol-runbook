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
- hosted tools such as web search, MCP/remote compaction, top-level `web_search`

Codex `namespace` tool wrappers are flattened into ordinary function tools
(hosted tools nested inside a namespace are skipped). Harmless Codex controls
with no chat equivalent (`include`, `service_tier`, `prompt_cache_key`, and
Responses stream options) are accepted but not forwarded.

Configure Codex in `~/.codex/config.toml` (provider settings must be user-level):

```toml
model = "subconscious/glm-5.2"
model_provider = "subconscious"

[model_providers.subconscious]
name = "Subconscious Gateway"
base_url = "https://gateway.example.com/v1"
wire_api = "responses"
env_key = "SUBCONSCIOUS_API_KEY"
stream_idle_timeout_ms = 300000
```

```sh
export SUBCONSCIOUS_API_KEY="sk-gw-..."
codex
```

Replace `base_url` with your deployed gateway origin plus `/v1`.

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
