import assert from "node:assert/strict";
import { createRequire } from "node:module";
import test from "node:test";

const require = createRequire(import.meta.url);
const core = require("./AwareRemoteCore.js");

test("post-ready menu exposes both lease extensions and safe return to sentinel", () => {
  assert.deepEqual(core.postReadyAction(2), { kind: "wake", duration_minutes: 120 });
  assert.deepEqual(core.postReadyAction(3), { kind: "wake", duration_minutes: "reserve" });
  assert.deepEqual(core.postReadyAction(4), { kind: "sentinel" });
});

test("post-ready operations have unique identity while targeting the current session", () => {
  const currentSession = "wake_12345678";
  const extended = core.wakePayload("extend_12345678", currentSession, { apps: ["chatgpt"], duration_minutes: 120 });
  const reserve = core.wakePayload("reserve_12345678", currentSession, { apps: ["chatgpt"], duration_minutes: "reserve" });
  const sentinel = core.controlPayload("sentinel_12345678", currentSession);
  assert.equal(extended.target_request_id, currentSession);
  assert.equal(reserve.target_request_id, currentSession);
  assert.equal(sentinel.target_request_id, currentSession);
  assert.deepEqual(new Set([extended.operation_id, reserve.operation_id, sentinel.operation_id]).size, 3);
});

test("status message displays estimated readiness", () => {
  const message = core.statusMessage({
    state: "remote_ready",
    host: {
      battery_percent: 72,
      estimated_ready_until: "2026-07-20T18:00:00.000Z",
      readiness_estimate_quality: "calibrated",
      failure_reason: null,
    },
  });
  assert.match(message, /Battery: 72%/);
  assert.match(message, /Estimated ready until:/);
  assert.doesNotMatch(message, /Estimated ready until: unknown/);
});

test("uncalibrated readiness is explicitly best-effort", () => {
  const message = core.statusMessage({
    state: "battery_sentinel",
    battery_percent: 80,
    estimated_ready_until: "2026-07-20T18:00:00.000Z",
    readiness_estimate_quality: "best_effort",
  });
  assert.match(message, /best-effort; uncalibrated/);
});

test("cleanup pending is visible and cancelled wake operations stop polling", () => {
  assert.match(core.statusMessage({
    state: "sentinel_cleanup_pending",
    host: { battery_percent: 60, estimated_ready_until: null, failure_reason: null },
  }), /cleanup is still pending/i);
  assert.ok(core.WAKE_TERMINAL_STATES.includes("cancelled"));
  assert.match(core.statusMessage({
    state: "cancelled",
    host: { battery_percent: 60, estimated_ready_until: null, failure_reason: null },
  }), /superseded/i);
});

test("offline control timeout is explicitly unconfirmed", () => {
  assert.deepEqual(
    core.unconfirmedControl(
      "op_12345678",
      "wake_12345678",
      "disarm",
      { state: "disarm_pending" },
      { state: "offline", last_seen: null },
    ),
    {
      operation_id: "op_12345678",
      target_request_id: "wake_12345678",
      state: "control_unconfirmed",
      requested_action: "disarm",
      command_state: "disarm_pending",
      host: { state: "offline", last_seen: null },
      failure_reason: "disarm is safely queued, but the Mac is offline and has not confirmed it",
    },
  );
});

test("wake validation enforces a nonempty, duplicate-free fixed allowlist", () => {
  assert.deepEqual(core.validateWake({ apps: ["chatgpt", "claude"], duration_minutes: 30 }), {
    apps: ["chatgpt", "claude"],
    duration_minutes: 30,
  });
  assert.throws(() => core.validateWake({ apps: ["chatgpt", "chatgpt"], duration_minutes: 30 }), /Invalid app/);
  assert.throws(() => core.validateWake({ apps: ["terminal"], duration_minutes: 30 }), /Invalid app/);
});

test("clipboard config blob parses and normalizes valid input", () => {
  const secret = "a".repeat(43);
  assert.deepEqual(
    core.parseConfigBlob(`{"endpoint":"https://w.example.workers.dev/","kid":"phone-v1","secret":"${secret}"}`),
    { endpoint: "https://w.example.workers.dev", kid: "phone-v1", secret },
  );
  // key_id is accepted as an alias for kid.
  assert.equal(
    core.parseConfigBlob(`{"endpoint":"https://w.example.workers.dev","key_id":"phone-v2","secret":"${secret}"}`).kid,
    "phone-v2",
  );
});

test("clipboard config blob rejects unsafe or incomplete input", () => {
  const secret = "a".repeat(43);
  assert.throws(() => core.parseConfigBlob("not json"), /valid Aware config JSON/);
  assert.throws(() => core.parseConfigBlob(`{"endpoint":"http://insecure","kid":"phone-v1","secret":"${secret}"}`), /HTTPS/);
  assert.throws(() => core.parseConfigBlob(`{"endpoint":"https://w.example.workers.dev","kid":"bad kid","secret":"${secret}"}`), /key ID/);
  assert.throws(() => core.parseConfigBlob(`{"endpoint":"https://w.example.workers.dev","kid":"phone-v1","secret":"short"}`), /base64url/);
});
