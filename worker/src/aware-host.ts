import { AuthError, authenticate } from "./auth";
import {
  APPS,
  DURATIONS,
  type AppId,
  type AuthContext,
  type DurationMinutes,
  type Env,
  type HostStatus,
  type HostStatusResponse,
  type OperationRecord,
  type OperationState,
} from "./types";

const ID_PATTERN = /^[A-Za-z0-9_-]{8,128}$/;
const ISO_DATE_PATTERN = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{3})?Z$/;
const MAX_BODY_BYTES = 16_384;
const HOST_STATUS_KEYS = new Set([
  "state",
  "power_source",
  "battery_percent",
  "thermal_state",
  "sentinel_drain_percent_per_hour",
  "estimated_ready_until",
  "readiness_estimate_quality",
  "apps_started",
  "last_seen",
  "failure_reason",
]);
const PROGRESS_STATES = new Set<OperationState>([
  "power_armed",
  "apps_started",
  "remote_ready",
  "reserve_sleep",
  "failed",
  "cancelled",
  "sentinel_cleanup_pending",
  "disarmed",
  "returned_to_sentinel",
]);
const TERMINAL_OPERATION_STATES = new Set<OperationState>([
  "remote_ready",
  "reserve_sleep",
  "failed",
  "cancelled",
  "disarmed",
  "returned_to_sentinel",
]);
const WAKE_REDELIVERY_STATES = new Set<OperationState>([
  "queued",
  "socket_observed",
  "power_armed",
  "apps_started",
]);

type ControlType = "disarm" | "return_to_sentinel";

interface PendingControl {
  type: ControlType;
  operation_id: string;
  sequence: number;
  target_request_id?: string;
  requested_at?: string;
  /** Compatibility with controls queued by the pre-delivery-timestamp release. */
  created_at?: string;
}

interface DeliveredControl {
  type: ControlType;
  operation_id: string;
  sequence: number;
  target_request_id?: string;
  requested_at: string;
  delivered_at: string;
}

class BodyReadError extends Error {
  constructor(
    message: string,
    readonly status: number,
  ) {
    super(message);
  }
}

function error(message: string, status = 400): Response {
  return Response.json({ error: message }, { status });
}

function isPlainRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasRequiredAndOptionalKeys(value: Record<string, unknown>, required: readonly string[], optional: readonly string[]): boolean {
  const keys = Object.keys(value);
  return required.every((key) => keys.includes(key)) && keys.every((key) => required.includes(key) || optional.includes(key));
}

function validAppArray(value: unknown): value is AppId[] {
  return (
    Array.isArray(value) &&
    value.length > 0 &&
    value.length <= APPS.length &&
    value.every((app) => typeof app === "string" && (APPS as readonly string[]).includes(app)) &&
    new Set(value).size === value.length
  );
}

function validDuration(value: unknown): value is DurationMinutes {
  return (DURATIONS as readonly unknown[]).includes(value);
}

function validNullableNumber(value: unknown, minimum = 0, maximum = Number.MAX_SAFE_INTEGER): boolean {
  return value === null || (typeof value === "number" && Number.isFinite(value) && value >= minimum && value <= maximum);
}

function validHostStatus(value: unknown): value is HostStatus {
  if (!isPlainRecord(value) || Object.keys(value).some((key) => !HOST_STATUS_KEYS.has(key)) || Object.keys(value).length !== HOST_STATUS_KEYS.size) return false;
  return (
    ["ac_ready", "battery_sentinel", "battery_active", "reserve_sleep", "offline"].includes(String(value.state)) &&
    ["ac", "battery", "unknown"].includes(String(value.power_source)) &&
    validNullableNumber(value.battery_percent, 0, 100) &&
    ["nominal", "fair", "serious", "critical", "unknown"].includes(String(value.thermal_state)) &&
    validNullableNumber(value.sentinel_drain_percent_per_hour) &&
    (value.estimated_ready_until === null || (typeof value.estimated_ready_until === "string" && ISO_DATE_PATTERN.test(value.estimated_ready_until))) &&
    ["calibrated", "best_effort"].includes(String(value.readiness_estimate_quality)) &&
    Array.isArray(value.apps_started) &&
    value.apps_started.every((app) => typeof app === "string" && (APPS as readonly string[]).includes(app)) &&
    typeof value.last_seen === "string" && ISO_DATE_PATTERN.test(value.last_seen) &&
    (value.failure_reason === null || (typeof value.failure_reason === "string" && value.failure_reason.length <= 500))
  );
}

function deliverableControl(pending: PendingControl): DeliveredControl {
  return {
    type: pending.type,
    operation_id: pending.operation_id,
    sequence: pending.sequence,
    ...(pending.target_request_id ? { target_request_id: pending.target_request_id } : {}),
    requested_at: pending.requested_at ?? pending.created_at ?? new Date().toISOString(),
    delivered_at: new Date().toISOString(),
  };
}

async function jsonBody(body: ArrayBuffer): Promise<unknown> {
  if (body.byteLength === 0) throw new Error("invalid JSON body");
  return JSON.parse(new TextDecoder().decode(body)) as unknown;
}

async function readBoundedBody(request: Request): Promise<ArrayBuffer> {
  if (request.method === "GET" || request.body === null) return new ArrayBuffer(0);
  const contentLength = request.headers.get("Content-Length");
  if (contentLength !== null) {
    if (!/^\d+$/.test(contentLength)) throw new BodyReadError("invalid_content_length", 400);
    if (Number(contentLength) > MAX_BODY_BYTES) throw new BodyReadError("request_body_too_large", 413);
  }

  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > MAX_BODY_BYTES) {
      await reader.cancel("request body too large");
      throw new BodyReadError("request_body_too_large", 413);
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return bytes.buffer;
}

export class AwareHost implements DurableObject {
  constructor(
    private readonly state: DurableObjectState,
    private readonly env: Env,
  ) {}

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    let body: ArrayBuffer;
    try {
      body = await readBoundedBody(request);
    } catch (caught) {
      if (caught instanceof BodyReadError) return error(caught.message, caught.status);
      return error("invalid_request_body");
    }
    const role = url.pathname === "/v1/host/socket" ? "host" : "phone";
    let auth: AuthContext;
    try {
      auth = await authenticate(request, body, this.env, role);
      const replayed = await this.state.storage.transaction(async (transaction) => {
        const key = `nonce:${auth.kid}:${auth.nonce}`;
        if (await transaction.get(key)) return true;
        await transaction.put(key, auth.timestamp);
        return false;
      });
      if (replayed) return error("replayed_nonce", 409);
      this.state.waitUntil(this.cleanupNonces());
    } catch (caught) {
      if (caught instanceof AuthError) return error(caught.message, caught.status);
      return error("authentication_failed", 401);
    }

    if (request.method === "POST" && url.pathname === "/v1/wake") return this.wake(body, auth.timestamp, auth.nonce);
    if (request.method === "POST" && url.pathname === "/v1/disarm") return this.disarm(body, auth.timestamp, auth.nonce);
    if (request.method === "POST" && url.pathname === "/v1/sentinel") return this.returnToSentinel(body, auth.timestamp, auth.nonce);
    if (request.method === "GET" && url.pathname === "/v1/host") return this.hostStatus();
    if (request.method === "GET" && url.pathname === "/v1/host/socket") return this.upgrade(request);
    if (request.method === "GET" && url.pathname.startsWith("/v1/operation/")) {
      return this.operationStatus(decodeURIComponent(url.pathname.slice("/v1/operation/".length)));
    }
    return error("not_found", 404);
  }

  private async cleanupNonces(): Promise<void> {
    const cutoff = Math.floor(Date.now() / 1000) - 600;
    const entries = await this.state.storage.list<number>({ prefix: "nonce:" });
    const expired = [...entries.entries()].filter(([, timestamp]) => timestamp < cutoff).map(([key]) => key);
    if (expired.length > 0) await this.state.storage.delete(expired);
  }

  private async nextSequence(): Promise<number> {
    return this.state.storage.transaction(async (transaction) => {
      const current = (await transaction.get<number>("operation-sequence")) ?? 0;
      const next = current + 1;
      await transaction.put("operation-sequence", next);
      return next;
    });
  }

  private async wake(body: ArrayBuffer, timestamp: number, nonce: string): Promise<Response> {
    let value: unknown;
    try {
      value = await jsonBody(body);
    } catch {
      return error("invalid_json");
    }
    if (
      !isPlainRecord(value) ||
      !hasRequiredAndOptionalKeys(value, ["operation_id", "timestamp", "nonce", "apps", "duration_minutes"], ["target_request_id"]) ||
      typeof value.operation_id !== "string" ||
      !ID_PATTERN.test(value.operation_id) ||
      (value.target_request_id !== undefined && (typeof value.target_request_id !== "string" || !ID_PATTERN.test(value.target_request_id) || value.target_request_id === value.operation_id)) ||
      value.timestamp !== timestamp ||
      value.nonce !== nonce ||
      !validAppArray(value.apps) ||
      !validDuration(value.duration_minutes)
    ) {
      return error("invalid_wake_request");
    }

    const storageKey = `operation:${value.operation_id}`;
    const existing = await this.state.storage.get<OperationRecord>(storageKey);
    if (existing) {
      const sameOperation =
        existing.kind === "wake" &&
        existing.target_request_id === (typeof value.target_request_id === "string" ? value.target_request_id : null) &&
        existing.duration_minutes === value.duration_minutes &&
        JSON.stringify(existing.apps) === JSON.stringify(value.apps);
      if (!sameOperation) return error("operation_id_conflict", 409);
      await this.deliverWake(existing);
      return Response.json(existing, { status: 202 });
    }
    const now = new Date().toISOString();
    const sequence = await this.nextSequence();
    const record: OperationRecord = {
      operation_id: value.operation_id,
      target_request_id: typeof value.target_request_id === "string" ? value.target_request_id : null,
      kind: "wake",
      sequence,
      apps: value.apps,
      duration_minutes: value.duration_minutes,
      state: "queued",
      created_at: now,
      updated_at: now,
      failure_reason: null,
      host: (await this.state.storage.get<HostStatus>("host-status")) ?? null,
    };
    await this.state.storage.put(storageKey, record);

    await this.deliverWake(record);
    return Response.json(record, { status: 202 });
  }

  private async deliverWake(record: OperationRecord, socket?: WebSocket): Promise<void> {
    if (record.kind !== "wake" || !WAKE_REDELIVERY_STATES.has(record.state) || record.duration_minutes === null) return;
    const message = {
      type: "wake",
      operation_id: record.operation_id,
      sequence: record.sequence,
      ...(record.target_request_id ? { target_request_id: record.target_request_id } : {}),
      apps: record.apps,
      duration_minutes: record.duration_minutes,
      created_at: record.created_at,
    };
    const sockets = socket ? [socket] : this.state.getWebSockets("host").slice(0, 1);
    for (const activeSocket of sockets) {
      try {
        activeSocket.send(JSON.stringify(message));
        if (record.state === "queued") {
          record.state = "socket_observed";
          record.updated_at = new Date().toISOString();
          await this.state.storage.put(`operation:${record.operation_id}`, record);
        }
      } catch {
        // The operation remains durable and will be redelivered on hello.
      }
    }
  }

  private async disarm(body: ArrayBuffer, timestamp: number, nonce: string): Promise<Response> {
    return this.queueControl("disarm", body, timestamp, nonce);
  }

  private async returnToSentinel(body: ArrayBuffer, timestamp: number, nonce: string): Promise<Response> {
    return this.queueControl("return_to_sentinel", body, timestamp, nonce);
  }

  private async queueControl(type: ControlType, body: ArrayBuffer, timestamp: number, nonce: string): Promise<Response> {
    let value: unknown;
    try {
      value = await jsonBody(body);
    } catch {
      return error("invalid_json");
    }
    if (
      !isPlainRecord(value) ||
      !hasRequiredAndOptionalKeys(value, ["operation_id", "timestamp", "nonce"], ["target_request_id"]) ||
      typeof value.operation_id !== "string" ||
      !ID_PATTERN.test(value.operation_id) ||
      (value.target_request_id !== undefined && (typeof value.target_request_id !== "string" || !ID_PATTERN.test(value.target_request_id) || value.target_request_id === value.operation_id)) ||
      value.timestamp !== timestamp ||
      value.nonce !== nonce
    ) {
      return error(type === "disarm" ? "invalid_disarm_request" : "invalid_sentinel_request");
    }

    const operationKey = `operation:${value.operation_id}`;
    const targetRequestID = typeof value.target_request_id === "string" ? value.target_request_id : null;
    let record = await this.state.storage.get<OperationRecord>(operationKey);
    if (record) {
      if (record.kind !== type || record.target_request_id !== targetRequestID) return error("operation_id_conflict", 409);
      const confirmed = record.state === "disarmed" || record.state === "returned_to_sentinel";
      const terminal = TERMINAL_OPERATION_STATES.has(record.state);
      let delivered = false;
      if (!terminal) {
        await this.cancelSupersededPowerUps(record);
        const pending = await this.state.storage.get<PendingControl>(`pending-control:${value.operation_id}`);
        if (pending) {
          delivered = await this.deliverControl(pending);
          await this.schedulePendingRetry();
        }
      }
      return Response.json({
        operation_id: value.operation_id,
        target_request_id: record.target_request_id,
        state: record.state,
        delivered,
        confirmed,
        failure_reason: terminal ? record.failure_reason : (delivered ? null : "host_offline_command_queued"),
      }, { status: terminal ? 200 : 202 });
    }

    const now = new Date().toISOString();
    const sequence = await this.nextSequence();
    const message: PendingControl = {
      type,
      operation_id: value.operation_id,
      sequence,
      ...(targetRequestID ? { target_request_id: targetRequestID } : {}),
      requested_at: new Date(timestamp * 1000).toISOString(),
    };
    record = {
      operation_id: value.operation_id,
      target_request_id: targetRequestID,
      kind: type,
      sequence,
      apps: [],
      duration_minutes: null,
      state: type === "disarm" ? "disarm_pending" : "sentinel_pending",
      created_at: now,
      updated_at: now,
      failure_reason: null,
      host: (await this.state.storage.get<HostStatus>("host-status")) ?? null,
    };
    await this.state.storage.put({
      [`pending-control:${value.operation_id}`]: message,
      [operationKey]: record,
    });
    await this.cancelSupersededPowerUps(record);
    await this.schedulePendingRetry();

    const delivered = await this.deliverControl(message);
    return Response.json({
      operation_id: value.operation_id,
      target_request_id: record.target_request_id,
      state: record.state,
      delivered,
      confirmed: false,
      failure_reason: delivered ? null : "host_offline_command_queued",
    }, { status: 202 });
  }

  private async cancelSupersededPowerUps(control: OperationRecord): Promise<void> {
    const records = await this.state.storage.list<OperationRecord>({ prefix: "operation:" });
    const updates: Record<string, OperationRecord> = {};
    for (const [key, candidate] of records) {
      if (
        candidate.kind !== "wake" ||
        candidate.sequence >= control.sequence ||
        !WAKE_REDELIVERY_STATES.has(candidate.state)
      ) continue;
      // Both safety controls establish a host-wide state barrier. The optional
      // target remains correlation/audit context and never narrows supersession.
      candidate.state = "cancelled";
      candidate.updated_at = new Date().toISOString();
      candidate.failure_reason = `superseded_by_${control.kind}`;
      updates[key] = candidate;
    }
    if (Object.keys(updates).length > 0) await this.state.storage.put(updates);
  }

  private async deliverControl(message: PendingControl, socket?: WebSocket): Promise<boolean> {
    let delivered = false;
    const sockets = socket ? [socket] : this.state.getWebSockets("host");
    for (const activeSocket of sockets) {
      try {
        activeSocket.send(JSON.stringify(deliverableControl(message)));
        delivered = true;
      } catch {
        // A stale hibernated socket will be removed by the runtime.
      }
    }
    return delivered;
  }

  private async schedulePendingRetry(): Promise<void> {
    const retryAt = Date.now() + 30_000;
    const current = await this.state.storage.getAlarm();
    if (current === null || current > retryAt) await this.state.storage.setAlarm(retryAt);
  }

  async alarm(): Promise<void> {
    const pendingControls = await this.state.storage.list<PendingControl>({ prefix: "pending-control:" });
    const active: PendingControl[] = [];
    for (const [key, message] of pendingControls) {
      const record = await this.state.storage.get<OperationRecord>(`operation:${message.operation_id}`);
      if (!record || TERMINAL_OPERATION_STATES.has(record.state)) {
        await this.state.storage.delete(key);
      } else {
        active.push(message);
      }
    }
    const ordered = active.sort((left, right) => left.sequence - right.sequence);
    for (const message of ordered) await this.deliverControl(message);
    if (ordered.length > 0) await this.state.storage.setAlarm(Date.now() + 30_000);
  }

  private async operationStatus(operationID: string): Promise<Response> {
    if (!ID_PATTERN.test(operationID)) return error("invalid_operation_id");
    const record = await this.state.storage.get<OperationRecord>(`operation:${operationID}`);
    return record ? Response.json(record) : error("operation_not_found", 404);
  }

  private async hostStatus(): Promise<Response> {
    const stored = await this.state.storage.get<HostStatus>("host-status");
    if (!stored) {
      const neverConnected: HostStatusResponse = {
        state: "offline",
        power_source: "unknown",
        battery_percent: null,
        thermal_state: "unknown",
        sentinel_drain_percent_per_hour: null,
        estimated_ready_until: null,
        readiness_estimate_quality: "best_effort",
        apps_started: [],
        last_seen: null,
        failure_reason: "host_has_never_connected",
      };
      return Response.json(neverConnected);
    }
    const offlineSeconds = Number(this.env.AWARE_HOST_OFFLINE_SECONDS ?? "90");
    if (Date.now() - Date.parse(stored.last_seen) > offlineSeconds * 1000) {
      return Response.json({ ...stored, state: "offline", failure_reason: "host_heartbeat_stale" });
    }
    return Response.json(stored);
  }

  private async upgrade(request: Request): Promise<Response> {
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") return error("websocket_upgrade_required", 426);
    // Cloudflare hibernation API: acceptWebSocket plus webSocketMessage/webSocketClose handlers.
    // https://developers.cloudflare.com/durable-objects/best-practices/websockets/
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair) as [WebSocket, WebSocket];
    for (const existing of this.state.getWebSockets("host")) existing.close(4001, "replaced by a newer host connection");
    this.state.acceptWebSocket(server, ["host"]);
    return new Response(null, { status: 101, webSocket: client });
  }

  async webSocketMessage(socket: WebSocket, message: string | ArrayBuffer): Promise<void> {
    if (typeof message !== "string") {
      socket.close(1003, "text JSON required");
      return;
    }
    if (new TextEncoder().encode(message).byteLength > 32_768) {
      socket.close(1009, "message too large");
      return;
    }
    let value: unknown;
    try {
      value = JSON.parse(message) as unknown;
    } catch {
      socket.close(1007, "invalid JSON");
      return;
    }
    if (!isPlainRecord(value) || typeof value.type !== "string") {
      socket.close(1007, "invalid message");
      return;
    }

    if ((value.type === "hello" || value.type === "status") && validHostStatus(value.status)) {
      await this.state.storage.put("host-status", value.status);
      if (value.type === "hello") await this.deliverQueued(socket);
      return;
    }
    if (
      value.type === "operation_status" &&
      typeof value.operation_id === "string" &&
      ID_PATTERN.test(value.operation_id) &&
      typeof value.sequence === "number" &&
      Number.isSafeInteger(value.sequence) &&
      value.sequence > 0 &&
      typeof value.state === "string" &&
      PROGRESS_STATES.has(value.state as OperationState) &&
      validHostStatus(value.status) &&
      (value.failure_reason === undefined || value.failure_reason === null || (typeof value.failure_reason === "string" && value.failure_reason.length <= 500))
    ) {
      const key = `operation:${value.operation_id}`;
      const record = await this.state.storage.get<OperationRecord>(key);
      if (!record) return;
      if (value.sequence !== record.sequence) {
        socket.close(1007, "operation sequence mismatch");
        return;
      }
      if (TERMINAL_OPERATION_STATES.has(record.state)) {
        await this.state.storage.put("host-status", value.status);
        return;
      }
      const pendingControl = await this.state.storage.get<PendingControl>(`pending-control:${value.operation_id}`);
      const acknowledgedControl =
        (pendingControl?.type === "disarm" && value.state === "disarmed") ||
        (pendingControl?.type === "return_to_sentinel" && value.state === "returned_to_sentinel");
      const retryableSentinelCleanup =
        pendingControl?.type === "return_to_sentinel" && value.state === "sentinel_cleanup_pending";
      const terminalStop = pendingControl !== undefined && (value.state === "failed" || value.state === "cancelled");

      // Terminal operation replay is idempotent and can never regress a completed
      // or superseded operation, regardless of how old the replay is.
      if (!pendingControl || acknowledgedControl || retryableSentinelCleanup || terminalStop) {
        record.state = value.state as OperationState;
      }
      record.failure_reason = typeof value.failure_reason === "string" ? value.failure_reason : value.status.failure_reason;
      record.host = value.status;
      record.updated_at = new Date().toISOString();
      await this.state.storage.put({ [key]: record, "host-status": value.status });
      if (acknowledgedControl || terminalStop) await this.state.storage.delete(`pending-control:${value.operation_id}`);
      if (retryableSentinelCleanup) await this.schedulePendingRetry();
      return;
    }
    socket.close(1007, "unsupported message");
  }

  private async deliverQueued(socket: WebSocket): Promise<void> {
    const pendingControls = await this.state.storage.list<PendingControl>({ prefix: "pending-control:" });
    const activeControls: PendingControl[] = [];
    for (const [key, message] of pendingControls) {
      const control = await this.state.storage.get<OperationRecord>(`operation:${message.operation_id}`);
      if (!control || TERMINAL_OPERATION_STATES.has(control.state)) {
        await this.state.storage.delete(key);
        continue;
      }
      await this.cancelSupersededPowerUps(control);
      activeControls.push(message);
    }
    const records = await this.state.storage.list<OperationRecord>({ prefix: "operation:" });
    const queued: Array<{ sequence: number; deliver: () => Promise<unknown> }> = [];
    for (const message of activeControls) {
      queued.push({ sequence: message.sequence, deliver: () => this.deliverControl(message, socket) });
    }
    for (const record of records.values()) {
      if (record.kind === "wake" && WAKE_REDELIVERY_STATES.has(record.state)) {
        queued.push({ sequence: record.sequence, deliver: () => this.deliverWake(record, socket) });
      }
    }
    queued.sort((left, right) => left.sequence - right.sequence);
    for (const command of queued) await command.deliver();
  }

  async webSocketClose(socket: WebSocket, code: number, reason: string, wasClean: boolean): Promise<void> {
    socket.close(code, reason);
  }
}
