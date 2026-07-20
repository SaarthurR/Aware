// Pure controller helpers shared by Scriptable and the portable Node test suite.

const ALLOWED_APPS = ["chatgpt", "claude", "cursor", "amphetamine"];
const WAKE_TERMINAL_STATES = ["remote_ready", "reserve_sleep", "failed", "cancelled", "disarmed", "returned_to_sentinel"];

function validateWake(input) {
  const apps = input.apps || ALLOWED_APPS;
  if (!Array.isArray(apps) || apps.length === 0 || new Set(apps).size !== apps.length || apps.some((app) => !ALLOWED_APPS.includes(app))) {
    throw new Error("Invalid app selection");
  }
  if (![30, 120, "reserve"].includes(input.duration_minutes)) throw new Error("Invalid duration");
  return { apps: apps.slice(), duration_minutes: input.duration_minutes };
}

function postReadyAction(choice) {
  return [
    { kind: "open", url: "chatgpt://" },
    { kind: "open", url: "claude://" },
    { kind: "wake", duration_minutes: 120 },
    { kind: "wake", duration_minutes: "reserve" },
    { kind: "sentinel" },
  ][choice] || { kind: "done" };
}

function wakePayload(operationID, targetRequestID, input) {
  return {
    operation_id: operationID,
    ...(targetRequestID ? { target_request_id: targetRequestID } : {}),
    ...validateWake(input),
  };
}

function controlPayload(operationID, targetRequestID) {
  return {
    operation_id: operationID,
    ...(targetRequestID ? { target_request_id: targetRequestID } : {}),
  };
}

function statusMessage(result) {
  const host = result.host || result;
  const battery = host.battery_percent == null ? "unknown" : `${host.battery_percent}%`;
  const readyUntil = host.estimated_ready_until
    ? new Date(host.estimated_ready_until).toLocaleString()
    : "unknown";
  const quality = host.readiness_estimate_quality === "calibrated"
    ? "calibrated"
    : "best-effort; uncalibrated";
  const pending = result.state === "sentinel_cleanup_pending"
    ? "Sentinel cleanup is still pending; Aware will retry this operation"
    : result.state === "cancelled"
      ? "This operation was superseded by a newer host command"
    : "";
  const failure = result.failure_reason || host.failure_reason || pending;
  return `${result.state || host.state}\nBattery: ${battery}\nEstimated ready until: ${readyUntil} (${quality})${failure ? `\n${failure}` : ""}`;
}

function unconfirmedControl(operationID, targetRequestID, action, lastOperation, host) {
  return {
    operation_id: operationID,
    target_request_id: targetRequestID || null,
    state: "control_unconfirmed",
    requested_action: action,
    command_state: lastOperation && lastOperation.state,
    host,
    failure_reason: host && host.state === "offline"
      ? `${action} is safely queued, but the Mac is offline and has not confirmed it`
      : `${action} was delivered or queued, but Guardian has not confirmed it`,
  };
}

function parseConfigBlob(text) {
  let parsed;
  try {
    parsed = JSON.parse(text);
  } catch (caught) {
    throw new Error("Clipboard is not valid Aware config JSON");
  }
  if (!parsed || typeof parsed !== "object") throw new Error("Clipboard is not valid Aware config JSON");
  const endpoint = String(parsed.endpoint || "").trim().replace(/\/$/, "");
  const kid = String(parsed.kid || parsed.key_id || "").trim();
  const secret = String(parsed.secret || "").trim();
  if (!/^https:\/\//.test(endpoint)) throw new Error("Config endpoint must use HTTPS");
  if (!/^[A-Za-z0-9._-]{1,64}$/.test(kid)) throw new Error("Config key ID is invalid");
  if (secret.length < 43) throw new Error("Config secret must be a 32-byte base64url value");
  return { endpoint, kid, secret };
}

module.exports = {
  ALLOWED_APPS,
  WAKE_TERMINAL_STATES,
  controlPayload,
  parseConfigBlob,
  postReadyAction,
  statusMessage,
  unconfirmedControl,
  validateWake,
  wakePayload,
};
