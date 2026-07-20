# Aware Worker

Cloudflare Worker and SQLite-backed Durable Object for Aware's authenticated phone-to-Mac control plane. It exposes only wake, return-to-sentinel, disarm, request status, host status, and one guardian WebSocket. There is no shell, path, AppleScript, or arbitrary application interface.

## Deploy

Prerequisites: a Cloudflare account and Node.js 20 or newer.

```sh
npm install
npm test
npm run typecheck
npx wrangler login
```

Generate two **different** 32-byte secrets. Keep the printed values in a password manager; the phone secret is entered into Scriptable and the host secret into the native Guardian configuration.

```sh
openssl rand -base64 32 | tr '+/' '-_' | tr -d '='
openssl rand -base64 32 | tr '+/' '-_' | tr -d '='
```

Create a one-line JSON value with those secrets:

```json
{"phone-v1":"PHONE_BASE64URL_SECRET","host-v1":"HOST_BASE64URL_SECRET"}
```

Install it without placing production secrets in `wrangler.toml`:

```sh
npx wrangler secret put AWARE_HMAC_KEYS
npx wrangler deploy
```

Copy the resulting HTTPS Worker URL into `AwareRemote.js` setup. Do not configure a custom route that is accessible over plain HTTP.

For local development, copy `.dev.vars.example` to `.dev.vars`, replace both values, and run `npm run dev`. `.dev.vars` is ignored by Git.

## Authentication contract

Every request includes:

- `X-Aware-Key-Id`: an ID allowed for that role (`AWARE_PHONE_KIDS` or `AWARE_HOST_KIDS`).
- `X-Aware-Timestamp`: ten-digit Unix time in seconds, within ±300 seconds.
- `X-Aware-Nonce`: 16–128 URL-safe characters, never reused with that key ID.
- `X-Aware-Signature`: unpadded base64url HMAC-SHA256.

The signing key is the decoded base64url secret. The signed UTF-8 string is:

```text
UPPERCASE_METHOD
/pathname?canonically-sorted=query
TIMESTAMP
NONCE
lowercase_hex_sha256_of_exact_body_bytes
```

The pathname has no query suffix when the query is empty. Query pairs are sorted by decoded key, then decoded value, and re-encoded with `encodeURIComponent`. POST bodies are signed exactly as transmitted. GET bodies are empty. A nonce is committed atomically in Durable Object storage after signature verification, so concurrent replays are rejected with HTTP 409.

Key rotation is additive:

1. Add `phone-v2` or `host-v2` and its secret to `AWARE_HMAC_KEYS`.
2. Add the new ID to the matching comma-separated `AWARE_*_KIDS` variable and deploy.
3. Move the client to the new ID and secret.
4. After all old clients are gone, remove the old ID from both places and deploy again.

Never reuse a phone key as a host key. Requests to `/v1/host/socket` accept host IDs only; every other endpoint accepts phone IDs only.

POST bodies are limited to 16 KiB. The Worker rejects an oversized declared `Content-Length` before reading the body and enforces the same bound while streaming bodies without a declared length; this happens before HMAC authentication so an unauthenticated client cannot force an unbounded allocation.

## HTTP API

`POST /v1/wake` accepts exactly:

```json
{
  "operation_id": "ios_a_url_safe_unique_operation",
  "timestamp": 1784520000,
  "nonce": "a_url_safe_single_use_nonce",
  "apps": ["chatgpt", "claude", "cursor", "amphetamine"],
  "duration_minutes": 120
}
```

`apps` must be a non-empty, duplicate-free subset of that fixed list. `duration_minutes` is `30`, `120`, or the string `"reserve"`. An initial wake omits `target_request_id`; Extend two hours and Run until reserve include the current session operation as an optional `target_request_id`, but always use a fresh `operation_id`. `timestamp` and `nonce` must exactly match the authentication headers. Unknown fields are rejected.

`POST /v1/sentinel` accepts `operation_id`, optional `target_request_id`, `timestamp`, and `nonce`. It gracefully closes apps launched by Aware while retaining the battery sentinel and sends the fixed `return_to_sentinel` command. It is intentionally distinct from full disarm.

`POST /v1/disarm` accepts the same exact shape. It fully ends Aware-managed sessions and asks the native helper to restore normal macOS sleep.

Every user action has a fresh `operation_id`; `target_request_id` is context only and may be omitted, so safety controls are accepted even before a wake exists. Retrying the identical action with the same `operation_id` is idempotent; reusing it with different kind, target, apps, or duration returns HTTP 409.

The Durable Object assigns every operation an increasing durable `sequence`. The immutable sequence is included in every host command and matching `operation_status`; acknowledgement is accepted only when its `operation_id` and sequence match the durable record. Before delivering disarm, the Worker marks every older nonterminal wake/extend/reserve as terminal `cancelled`, even when the phone supplies `target_request_id`; disarm is always host-global and the target is audit/context only. Return-to-sentinel establishes the same host-wide barrier, because an older unrelated wake delivered immediately afterward would undo the requested sentinel state. Cancellation is re-applied during retry and reconnect recovery before any queued wake is delivered. A wake created after the safety control has a higher sequence and remains valid.

Both control endpoints return HTTP 202 with `sentinel_pending` or `disarm_pending`, `confirmed: false`, and whether a socket delivery was attempted. Delivery is not confirmation. The command remains persisted and is redelivered after reconnect until Guardian explicitly reports `returned_to_sentinel` or `disarmed` for that `operation_id`. Poll `GET /v1/operation/{operation_id}` for the exact terminal acknowledgement. An offline response includes `failure_reason: "host_offline_command_queued"` rather than claiming the requested transition occurred.

`GET /v1/operation/{operation_id}` returns the persisted operation. `GET /v1/host` returns:

```json
{
  "state": "battery_sentinel",
  "power_source": "battery",
  "battery_percent": 84,
  "thermal_state": "nominal",
  "sentinel_drain_percent_per_hour": 1.9,
  "estimated_ready_until": "2026-07-20T18:00:00.000Z",
  "readiness_estimate_quality": "calibrated",
  "apps_started": [],
  "last_seen": "2026-07-19T22:00:00.000Z",
  "failure_reason": null
}
```

`readiness_estimate_quality` is `best_effort` until three-run battery calibration is configured; clients must label that case as uncalibrated rather than presenting it as guaranteed readiness.

A stored heartbeat older than `AWARE_HOST_OFFLINE_SECONDS` is returned as `offline` without overwriting the Guardian's last report.
Before Guardian has ever connected, `last_seen` is `null`; every Guardian-supplied status must contain a valid ISO-8601 `last_seen` string.

## Guardian WebSocket

Connect `GET /v1/host/socket` with the host key and `Upgrade: websocket`. This uses Cloudflare's [Durable Object WebSocket hibernation API](https://developers.cloudflare.com/durable-objects/best-practices/websockets/). A new authenticated connection closes the old one; there is one authoritative host.

Server messages:

```json
{"type":"wake","operation_id":"op_wake","sequence":41,"apps":["chatgpt"],"duration_minutes":120,"created_at":"2026-07-19T22:00:00.000Z"}
{"type":"wake","operation_id":"op_extend","sequence":42,"target_request_id":"op_wake","apps":["chatgpt"],"duration_minutes":120,"created_at":"2026-07-19T22:05:00.000Z"}
{"type":"return_to_sentinel","operation_id":"op_sentinel","sequence":43,"target_request_id":"op_wake","requested_at":"2026-07-19T22:08:00.000Z","delivered_at":"2026-07-19T22:20:00.000Z"}
{"type":"disarm","operation_id":"op_disarm","sequence":44,"requested_at":"2026-07-19T22:10:00.000Z","delivered_at":"2026-07-19T22:20:00.000Z"}
```

For fixed safety controls, `requested_at` is the immutable authenticated phone-request time retained for audit. `delivered_at` is generated by the Worker for every socket send and is refreshed on reconnect; it is never accepted from the phone API. Guardian applies freshness validation to `delivered_at` and request-id idempotency to the operation, so a command queued while the Mac is offline remains safe and actionable after five minutes. Wake retains its immutable `created_at` and normal expiry behavior.

Guardian messages:

```json
{"type":"hello","status":HOST_STATUS}
{"type":"status","status":HOST_STATUS}
{"type":"operation_status","operation_id":"...","sequence":41,"state":"power_armed","status":HOST_STATUS,"failure_reason":null}
```

`operation_status.state` is `power_armed`, `apps_started`, `remote_ready`, `reserve_sleep`, `sentinel_cleanup_pending`, `cancelled`, `failed`, `returned_to_sentinel`, or `disarmed`. All frames in both directions are UTF-8 text JSON. On hello, the Worker first reapplies safety cancellation, then merges every deliverable pending control and power-up into one ascending sequence stream before sending. Alarm batches use the same ordering; reconnect and same-operation retry preserve the original sequence. Only a terminal Guardian report for the same `operation_id` and sequence stops wake redelivery. The Worker uses `cancelled` when its durable safety barrier supersedes queued power-ups; Guardian also reports `cancelled` when a previously retryable lower-sequence operation is superseded by its persisted admission barrier. For pending controls, `cancelled` is terminal and deletes all retry state. `sentinel_cleanup_pending` retains the pending control for reconnect, idempotent phone retry, and a 30-second Durable Object alarm retry, each with fresh `delivered_at`; exact `returned_to_sentinel` clears it. `failed` is terminal, clears any pending control, and is not redelivered. Terminal progress replay never regresses or rewrites the stored operation. Guardian command handling is idempotent by `operation_id`; `target_request_id` never supplies command identity. Invalid or binary messages close the socket; the 32 KiB inbound limit is measured from the exact UTF-8 byte encoding.

## Operations

- Use `npm test` for Worker-runtime tests. They run locally in workerd and cover Durable Object storage and real WebSocket delivery.
- Use `npm run typecheck` before deployment.
- Cloudflare logs must not print headers or bodies; the implementation currently emits no request logging.
- If the Worker secret is suspected to be exposed, rotate it before changing clients. Removing the compromised `kid` immediately invalidates it.
- A Worker outage leaves the Mac in the native helper's bounded heartbeat/lease fail-safe; this service does not control the root power helper directly.
