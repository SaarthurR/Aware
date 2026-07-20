import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { signedRequest } from "./helpers";

function hostStatus(overrides: Record<string, unknown> = {}) {
  return {
    state: "battery_sentinel",
    power_source: "battery",
    battery_percent: 80,
    thermal_state: "nominal",
    sentinel_drain_percent_per_hour: null,
    estimated_ready_until: "2026-07-20T18:00:00.000Z",
    readiness_estimate_quality: "calibrated",
    apps_started: [],
    last_seen: new Date().toISOString(),
    failure_reason: null,
    ...overrides,
  };
}

async function operationState(operationID: string): Promise<string> {
  const response = await SELF.fetch(await signedRequest(`/v1/operation/${operationID}`));
  return String((await response.json() as { state: string }).state);
}

async function operationRecord(operationID: string): Promise<Record<string, unknown>> {
  const response = await SELF.fetch(await signedRequest(`/v1/operation/${operationID}`));
  return await response.json() as Record<string, unknown>;
}

async function operationSequence(operationID: string): Promise<number> {
  return Number((await operationRecord(operationID)).sequence);
}

function matchingMessage(socket: WebSocket, predicate: (value: Record<string, unknown>) => boolean): Promise<Record<string, unknown>> {
  return new Promise((resolve) => {
    const listener = (event: MessageEvent) => {
      const value = JSON.parse(String(event.data)) as Record<string, unknown>;
      if (!predicate(value)) return;
      socket.removeEventListener("message", listener);
      resolve(value);
    };
    socket.addEventListener("message", listener);
  });
}

function expectNoMatchingMessage(socket: WebSocket, predicate: (value: Record<string, unknown>) => boolean): Promise<void> {
  return new Promise((resolve, reject) => {
    const listener = (event: MessageEvent) => {
      const value = JSON.parse(String(event.data)) as Record<string, unknown>;
      if (!predicate(value)) return;
      clearTimeout(timeout);
      socket.removeEventListener("message", listener);
      reject(new Error(`unexpected message: ${JSON.stringify(value)}`));
    };
    const timeout = setTimeout(() => {
      socket.removeEventListener("message", listener);
      resolve();
    }, 25);
    socket.addEventListener("message", listener);
  });
}

function collectOperations(socket: WebSocket, operationIDs: Set<string>): Promise<Record<string, unknown>[]> {
  return new Promise((resolve) => {
    const values: Record<string, unknown>[] = [];
    const listener = (event: MessageEvent) => {
      const value = JSON.parse(String(event.data)) as Record<string, unknown>;
      if (!operationIDs.has(String(value.operation_id))) return;
      values.push(value);
      if (values.length !== operationIDs.size) return;
      socket.removeEventListener("message", listener);
      resolve(values);
    };
    socket.addEventListener("message", listener);
  });
}

describe("Aware Worker authentication and validation", () => {
  it("rejects unauthenticated requests", async () => {
    const response = await SELF.fetch("https://aware.test/v1/host");
    expect(response.status).toBe(401);
  });

  it("uses null last_seen only for the never-connected public host snapshot", async () => {
    const response = await SELF.fetch(await signedRequest("/v1/host"));
    expect(response.status).toBe(200);
    expect(await response.json()).toMatchObject({
      state: "offline",
      last_seen: null,
      readiness_estimate_quality: "best_effort",
      failure_reason: "host_has_never_connected",
    });
  });

  it("accepts and persists a safety control before any wake operation exists", async () => {
    const operationID = `first_control_${crypto.randomUUID().replace(/-/g, "")}`;
    const response = await SELF.fetch(
      await signedRequest("/v1/disarm", { method: "POST", body: { operation_id: operationID } }),
    );
    expect(response.status).toBe(202);
    expect(await response.json()).toMatchObject({
      operation_id: operationID,
      target_request_id: null,
      state: "disarm_pending",
    });
    expect(await operationState(operationID)).toBe("disarm_pending");
  });

  it("accepts an allowlisted wake request and exposes its status", async () => {
    const requestId = `req_${crypto.randomUUID().replace(/-/g, "")}`;
    const response = await SELF.fetch(
      await signedRequest("/v1/wake", {
        method: "POST",
        body: { operation_id: requestId, apps: ["chatgpt", "claude"], duration_minutes: 120 },
      }),
    );
    expect(response.status).toBe(202);
    expect(await response.json()).toMatchObject({ operation_id: requestId, state: "queued" });

    const status = await SELF.fetch(await signedRequest(`/v1/operation/${requestId}`));
    expect(status.status).toBe(200);
    expect(await status.json()).toMatchObject({
      operation_id: requestId,
      apps: ["chatgpt", "claude"],
      duration_minutes: 120,
      state: "queued",
    });
  });

  it("rejects replayed nonces", async () => {
    const nonce = crypto.randomUUID().replace(/-/g, "");
    const first = await SELF.fetch(await signedRequest("/v1/host", { nonce }));
    const replay = await SELF.fetch(await signedRequest("/v1/host", { nonce }));
    expect(first.status).toBe(200);
    expect(replay.status).toBe(409);
    expect(await replay.json()).toEqual({ error: "replayed_nonce" });
  });

  it("rejects stale signatures", async () => {
    const response = await SELF.fetch(
      await signedRequest("/v1/host", { timestamp: Math.floor(Date.now() / 1000) - 301 }),
    );
    expect(response.status).toBe(401);
  });

  it("accepts both allowlisted phone keys during additive key rotation", async () => {
    const current = await SELF.fetch(await signedRequest("/v1/host", { kid: "phone-v1" }));
    const next = await SELF.fetch(await signedRequest("/v1/host", { kid: "phone-v2" }));
    expect(current.status).toBe(200);
    expect(next.status).toBe(200);
  });

  it("rejects oversized unauthenticated bodies before authentication", async () => {
    const response = await SELF.fetch("https://aware.test/v1/wake", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: "x".repeat(16_385),
    });
    expect(response.status).toBe(413);
    expect(await response.json()).toEqual({ error: "request_body_too_large" });
  });

  it("rejects an oversized declared Content-Length on the early header path", async () => {
    const request = new Request("https://aware.test/v1/wake", {
      method: "POST",
      headers: { "Content-Length": "16385" },
      body: "{}",
    });
    const response = await SELF.fetch(request);
    expect(response.status).toBe(413);
    expect(await response.json()).toEqual({ error: "request_body_too_large" });
  });

  it("rejects arbitrary apps, durations, and extra fields", async () => {
    const cases = [
      { operation_id: "request_bad_app", apps: ["terminal"], duration_minutes: 120 },
      { operation_id: "request_bad_duration", apps: ["cursor"], duration_minutes: 999 },
      { operation_id: "request_extra_key", apps: ["cursor"], duration_minutes: 30, command: "whoami" },
    ];
    for (const body of cases) {
      const response = await SELF.fetch(await signedRequest("/v1/wake", { method: "POST", body }));
      expect(response.status).toBe(400);
      expect(await response.json()).toEqual({ error: "invalid_wake_request" });
    }
  });

  it("does not let phone clients forge Worker delivery timestamps", async () => {
    const requestId = `forge_${crypto.randomUUID().replace(/-/g, "")}`;
    const response = await SELF.fetch(
      await signedRequest("/v1/disarm", {
        method: "POST",
        body: { operation_id: requestId, delivered_at: new Date().toISOString() },
      }),
    );
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: "invalid_disarm_request" });
  });

  it("makes same-key control retries idempotent and rejects conflicting reuse", async () => {
    const operationID = `prewake_${crypto.randomUUID().replace(/-/g, "")}`;
    const first = await SELF.fetch(
      await signedRequest("/v1/sentinel", { method: "POST", body: { operation_id: operationID } }),
    );
    expect(await first.json()).toMatchObject({ operation_id: operationID, state: "sentinel_pending" });
    const beforeRetry = await SELF.fetch(await signedRequest(`/v1/operation/${operationID}`));
    const original = await beforeRetry.json() as { created_at: string };

    const retry = await SELF.fetch(
      await signedRequest("/v1/sentinel", { method: "POST", body: { operation_id: operationID } }),
    );
    expect(retry.status).toBe(202);
    expect(await retry.json()).toMatchObject({ operation_id: operationID, state: "sentinel_pending" });
    const afterRetry = await SELF.fetch(await signedRequest(`/v1/operation/${operationID}`));
    expect(await afterRetry.json()).toMatchObject({ created_at: original.created_at });

    const conflict = await SELF.fetch(
      await signedRequest("/v1/disarm", { method: "POST", body: { operation_id: operationID } }),
    );
    expect(conflict.status).toBe(409);
    expect(await conflict.json()).toEqual({ error: "operation_id_conflict" });
  });

  it("stores extend and reserve as unique operations targeting one session", async () => {
    const sessionID = `session_${crypto.randomUUID().replace(/-/g, "")}`;
    const extendID = `extend_${crypto.randomUUID().replace(/-/g, "")}`;
    const reserveID = `reserve_${crypto.randomUUID().replace(/-/g, "")}`;
    for (const [operationID, duration] of [[extendID, 120], [reserveID, "reserve"]] as const) {
      const response = await SELF.fetch(
        await signedRequest("/v1/wake", {
          method: "POST",
          body: {
            operation_id: operationID,
            target_request_id: sessionID,
            apps: ["chatgpt", "claude"],
            duration_minutes: duration,
          },
        }),
      );
      expect(response.status).toBe(202);
      expect(await response.json()).toMatchObject({
        operation_id: operationID,
        target_request_id: sessionID,
        duration_minutes: duration,
      });
    }
    expect(extendID).not.toBe(reserveID);
  });

  it("requires the host key for the WebSocket route", async () => {
    const response = await SELF.fetch(await signedRequest("/v1/host/socket", { upgrade: true }));
    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ error: "unknown key id" });
  });
});

describe("Aware host WebSocket integration", () => {
  it("sentinel creates a host-wide barrier across older overlapping wake chains", async () => {
    const sessionID = `order_session_${crypto.randomUUID().replace(/-/g, "")}`;
    const extendID = `order_extend_${crypto.randomUUID().replace(/-/g, "")}`;
    const unrelatedID = `order_other_${crypto.randomUUID().replace(/-/g, "")}`;
    for (const body of [
      { operation_id: sessionID, apps: ["chatgpt"], duration_minutes: 120 },
      { operation_id: extendID, target_request_id: sessionID, apps: ["chatgpt"], duration_minutes: 120 },
      { operation_id: unrelatedID, apps: ["claude"], duration_minutes: 30 },
    ]) {
      expect((await SELF.fetch(await signedRequest("/v1/wake", { method: "POST", body }))).status).toBe(202);
    }
    const sentinelID = `order_sentinel_${crypto.randomUUID().replace(/-/g, "")}`;
    await SELF.fetch(await signedRequest("/v1/sentinel", {
      method: "POST",
      body: { operation_id: sentinelID, target_request_id: sessionID },
    }));
    expect(await operationState(sessionID)).toBe("cancelled");
    expect(await operationState(extendID)).toBe("cancelled");
    expect(await operationState(unrelatedID)).toBe("cancelled");
  });

  it("targeted disarm is still host-global across phones and preserves only later wakes", async () => {
    const firstWake = `phone_a_wake_${crypto.randomUUID().replace(/-/g, "")}`;
    const secondWake = `phone_b_wake_${crypto.randomUUID().replace(/-/g, "")}`;
    for (const operationID of [firstWake, secondWake]) {
      await SELF.fetch(await signedRequest("/v1/wake", {
        method: "POST",
        body: { operation_id: operationID, apps: ["cursor"], duration_minutes: 30 },
      }));
    }
    const firstExtend = `phone_a_extend_${crypto.randomUUID().replace(/-/g, "")}`;
    const secondExtend = `phone_b_extend_${crypto.randomUUID().replace(/-/g, "")}`;
    for (const [operationID, targetRequestID] of [[firstExtend, firstWake], [secondExtend, secondWake]]) {
      await SELF.fetch(await signedRequest("/v1/wake", {
        method: "POST",
        body: {
          operation_id: operationID,
          target_request_id: targetRequestID,
          apps: ["cursor"],
          duration_minutes: 120,
        },
      }));
    }
    const disarmID = `global_disarm_${crypto.randomUUID().replace(/-/g, "")}`;
    await SELF.fetch(await signedRequest("/v1/disarm", {
      method: "POST",
      body: { operation_id: disarmID, target_request_id: firstWake },
    }));
    expect(await operationState(firstWake)).toBe("cancelled");
    expect(await operationState(secondWake)).toBe("cancelled");
    expect(await operationState(firstExtend)).toBe("cancelled");
    expect(await operationState(secondExtend)).toBe("cancelled");

    const laterWake = `global_later_${crypto.randomUUID().replace(/-/g, "")}`;
    await SELF.fetch(await signedRequest("/v1/wake", {
      method: "POST",
      body: { operation_id: laterWake, apps: ["chatgpt"], duration_minutes: 30 },
    }));
    expect(await operationState(laterWake)).toBe("queued");
    const disarmRecord = await operationRecord(disarmID);
    const laterRecord = await operationRecord(laterWake);
    expect(Number(laterRecord.sequence)).toBeGreaterThan(Number(disarmRecord.sequence));

    const upgrade = await SELF.fetch(await signedRequest("/v1/host/socket", { kid: "host-v1", upgrade: true }));
    const socket = upgrade.webSocket!;
    socket.accept();
    const cancelledStaySilent = Promise.all([
      expectNoMatchingMessage(socket, (value) => value.type === "wake" && value.operation_id === firstWake),
      expectNoMatchingMessage(socket, (value) => value.type === "wake" && value.operation_id === secondWake),
      expectNoMatchingMessage(socket, (value) => value.type === "wake" && value.operation_id === firstExtend),
      expectNoMatchingMessage(socket, (value) => value.type === "wake" && value.operation_id === secondExtend),
    ]);
    const laterDelivery = matchingMessage(socket, (value) => value.type === "wake" && value.operation_id === laterWake);
    socket.send(JSON.stringify({ type: "hello", status: hostStatus() }));
    expect(await laterDelivery).toMatchObject({ type: "wake", operation_id: laterWake });
    await cancelledStaySilent;
    socket.close(1000, "done");
  });

  it("merges queued controls and power-ups into one ascending sequence stream", async () => {
    const sentinelID = `sorted_sentinel_${crypto.randomUUID().replace(/-/g, "")}`;
    const disarmID = `sorted_disarm_${crypto.randomUUID().replace(/-/g, "")}`;
    const wakeID = `sorted_wake_${crypto.randomUUID().replace(/-/g, "")}`;
    await SELF.fetch(await signedRequest("/v1/sentinel", { method: "POST", body: { operation_id: sentinelID } }));
    await SELF.fetch(await signedRequest("/v1/disarm", { method: "POST", body: { operation_id: disarmID } }));
    await SELF.fetch(await signedRequest("/v1/wake", {
      method: "POST",
      body: { operation_id: wakeID, apps: ["chatgpt"], duration_minutes: 30 },
    }));

    const upgrade = await SELF.fetch(await signedRequest("/v1/host/socket", { kid: "host-v1", upgrade: true }));
    const socket = upgrade.webSocket!;
    socket.accept();
    const delivered = collectOperations(socket, new Set([sentinelID, disarmID, wakeID]));
    socket.send(JSON.stringify({ type: "hello", status: hostStatus() }));
    const messages = await delivered;
    expect(messages.map((value) => value.operation_id)).toEqual([sentinelID, disarmID, wakeID]);
    const sequences = messages.map((value) => Number(value.sequence));
    expect(sequences).toEqual([...sequences].sort((left, right) => left - right));
    expect(sequences).toEqual([
      await operationSequence(sentinelID),
      await operationSequence(disarmID),
      await operationSequence(wakeID),
    ]);
    socket.close(1000, "done");
  });

  it("enforces the inbound message limit by UTF-8 bytes rather than UTF-16 length", async () => {
    const upgrade = await SELF.fetch(
      await signedRequest("/v1/host/socket", { kid: "host-v1", upgrade: true }),
    );
    const socket = upgrade.webSocket!;
    socket.accept();
    const closed = new Promise<CloseEvent>((resolve) => {
      socket.addEventListener("close", (event) => resolve(event), { once: true });
    });
    const message = "é".repeat(20_000);
    expect(message.length).toBeLessThan(32_768);
    expect(new TextEncoder().encode(message).byteLength).toBeGreaterThan(32_768);
    socket.send(message);
    expect((await closed).code).toBe(1009);
  });

  it("rejects operation progress carrying the wrong durable sequence", async () => {
    const upgrade = await SELF.fetch(await signedRequest("/v1/host/socket", { kid: "host-v1", upgrade: true }));
    const socket = upgrade.webSocket!;
    socket.accept();
    const operationID = `wrong_sequence_${crypto.randomUUID().replace(/-/g, "")}`;
    const delivered = matchingMessage(socket, (value) => value.type === "wake" && value.operation_id === operationID);
    await SELF.fetch(await signedRequest("/v1/wake", {
      method: "POST",
      body: { operation_id: operationID, apps: ["cursor"], duration_minutes: 30 },
    }));
    const command = await delivered;
    const closed = new Promise<CloseEvent>((resolve) => socket.addEventListener("close", resolve, { once: true }));
    socket.send(JSON.stringify({
      type: "operation_status",
      operation_id: operationID,
      sequence: Number(command.sequence) + 1,
      state: "remote_ready",
      status: hostStatus({ state: "battery_active", apps_started: ["cursor"] }),
    }));
    expect((await closed).code).toBe(1007);
    expect(await operationState(operationID)).toBe("socket_observed");
  });

  it("delivers a wake command over the single host socket", async () => {
    const upgrade = await SELF.fetch(
      await signedRequest("/v1/host/socket", { kid: "host-v1", upgrade: true }),
    );
    expect(upgrade.status).toBe(101);
    const socket = upgrade.webSocket;
    expect(socket).toBeDefined();
    socket!.accept();

    const readyMessage = new Promise<unknown>((resolve) => {
      socket!.addEventListener("message", (event) => resolve(event.data), { once: true });
    });
    const requestId = `socket_${crypto.randomUUID().replace(/-/g, "")}`;
    const wake = await SELF.fetch(
      await signedRequest("/v1/wake", {
        method: "POST",
        body: { operation_id: requestId, apps: ["amphetamine"], duration_minutes: 30 },
      }),
    );
    expect(wake.status).toBe(202);
    expect(await wake.json()).toMatchObject({ state: "socket_observed" });
    const delivered = await readyMessage;
    expect(typeof delivered).toBe("string");
    expect(JSON.parse(delivered as string)).toMatchObject({
      type: "wake",
      operation_id: requestId,
      apps: ["amphetamine"],
      duration_minutes: 30,
    });
    socket!.close(1000, "done");
  });

  it("redelivers an unacknowledged wake after a host reconnect", async () => {
    const firstUpgrade = await SELF.fetch(
      await signedRequest("/v1/host/socket", { kid: "host-v1", upgrade: true }),
    );
    const firstSocket = firstUpgrade.webSocket!;
    firstSocket.accept();
    const firstMessage = new Promise<string>((resolve) => {
      firstSocket.addEventListener("message", (event) => resolve(String(event.data)), { once: true });
    });
    const requestId = `retry_${crypto.randomUUID().replace(/-/g, "")}`;
    await SELF.fetch(
      await signedRequest("/v1/wake", {
        method: "POST",
        body: { operation_id: requestId, apps: ["chatgpt"], duration_minutes: 120 },
      }),
    );
    expect(JSON.parse(await firstMessage)).toMatchObject({ type: "wake", operation_id: requestId });
    firstSocket.close(1000, "simulate disconnect");

    const retryUpgrade = await SELF.fetch(
      await signedRequest("/v1/host/socket", { kid: "host-v1", upgrade: true }),
    );
    const retrySocket = retryUpgrade.webSocket!;
    retrySocket.accept();
    const retryMessage = matchingMessage(retrySocket, (value) =>
      value.type === "wake" &&
      value.operation_id === requestId,
    );
    retrySocket.send(JSON.stringify({ type: "hello", status: hostStatus() }));
    expect(await retryMessage).toMatchObject({ type: "wake", operation_id: requestId });

    retrySocket.send(JSON.stringify({
      type: "operation_status",
      operation_id: requestId,
      sequence: await operationSequence(requestId),
      state: "remote_ready",
      status: hostStatus({ state: "battery_active", apps_started: ["chatgpt"] }),
    }));
    await expect.poll(() => operationState(requestId)).toBe("remote_ready");
    retrySocket.close(1000, "done");

    const terminalUpgrade = await SELF.fetch(
      await signedRequest("/v1/host/socket", { kid: "host-v1", upgrade: true }),
    );
    const terminalSocket = terminalUpgrade.webSocket!;
    terminalSocket.accept();
    const noRedelivery = expectNoMatchingMessage(terminalSocket, (value) =>
      value.type === "wake" &&
      value.operation_id === requestId,
    );
    terminalSocket.send(JSON.stringify({ type: "hello", status: hostStatus() }));
    await noRedelivery;
    terminalSocket.close(1000, "done");
  });

  it("persists an offline disarm as pending until Guardian explicitly acknowledges it", async () => {
    const requestId = `disarm_${crypto.randomUUID().replace(/-/g, "")}`;
    const requestedTimestamp = Math.floor(Date.now() / 1000) - 300;
    const disarm = await SELF.fetch(
      await signedRequest("/v1/disarm", {
        method: "POST",
        timestamp: requestedTimestamp,
        body: { operation_id: requestId },
      }),
    );
    expect(await disarm.json()).toEqual({
      operation_id: requestId,
      target_request_id: null,
      state: "disarm_pending",
      delivered: false,
      confirmed: false,
      failure_reason: "host_offline_command_queued",
    });
    expect(await operationState(requestId)).toBe("disarm_pending");

    const upgrade = await SELF.fetch(
      await signedRequest("/v1/host/socket", { kid: "host-v1", upgrade: true }),
    );
    const socket = upgrade.webSocket!;
    socket.accept();
    const message = matchingMessage(socket, (value) => value.type === "disarm" && value.operation_id === requestId);
    socket.send(JSON.stringify({ type: "hello", status: hostStatus() }));
    const firstDelivery = await message;
    expect(firstDelivery).toEqual(expect.objectContaining({
      type: "disarm",
      operation_id: requestId,
      sequence: await operationSequence(requestId),
      requested_at: new Date(requestedTimestamp * 1000).toISOString(),
      delivered_at: expect.any(String),
    }));
    expect(firstDelivery).not.toHaveProperty("created_at");
    expect(Date.parse(String(firstDelivery.delivered_at)) - Date.parse(String(firstDelivery.requested_at))).toBeGreaterThanOrEqual(300_000);
    expect(await operationState(requestId)).toBe("disarm_pending");
    socket.close(1000, "disconnect before acknowledgement");
    await new Promise((resolve) => setTimeout(resolve, 2));

    const retryUpgrade = await SELF.fetch(
      await signedRequest("/v1/host/socket", { kid: "host-v1", upgrade: true }),
    );
    const retrySocket = retryUpgrade.webSocket!;
    retrySocket.accept();
    const redelivery = matchingMessage(retrySocket, (value) =>
      value.type === "disarm" && value.operation_id === requestId,
    );
    retrySocket.send(JSON.stringify({ type: "hello", status: hostStatus() }));
    const secondDelivery = await redelivery;
    expect(secondDelivery).toMatchObject({
      type: "disarm",
      operation_id: requestId,
      sequence: firstDelivery.sequence,
      requested_at: firstDelivery.requested_at,
      delivered_at: expect.any(String),
    });
    expect(Date.parse(String(secondDelivery.delivered_at))).toBeGreaterThan(Date.parse(String(firstDelivery.delivered_at)));
    retrySocket.send(JSON.stringify({
      type: "operation_status",
      operation_id: requestId,
      sequence: await operationSequence(requestId),
      state: "disarmed",
      status: hostStatus({ state: "offline", failure_reason: null }),
    }));
    await expect.poll(() => operationState(requestId)).toBe("disarmed");
    retrySocket.close(1000, "done");
  });

  it("queues return-to-sentinel separately from full disarm and waits for confirmation", async () => {
    const upgrade = await SELF.fetch(
      await signedRequest("/v1/host/socket", { kid: "host-v1", upgrade: true }),
    );
    const socket = upgrade.webSocket!;
    socket.accept();
    const wakeMessage = new Promise<string>((resolve) => {
      socket.addEventListener("message", (event) => resolve(String(event.data)), { once: true });
    });
    const wakeOperationID = `wake_${crypto.randomUUID().replace(/-/g, "")}`;
    const requestId = `sentinel_${crypto.randomUUID().replace(/-/g, "")}`;
    await SELF.fetch(
      await signedRequest("/v1/wake", {
        method: "POST",
        body: { operation_id: wakeOperationID, apps: ["claude"], duration_minutes: 120 },
      }),
    );
    await wakeMessage;
    socket.send(JSON.stringify({
      type: "operation_status",
      operation_id: wakeOperationID,
      sequence: await operationSequence(wakeOperationID),
      state: "remote_ready",
      status: hostStatus({ state: "battery_active", apps_started: ["claude"] }),
    }));
    await expect.poll(() => operationState(wakeOperationID)).toBe("remote_ready");

    const controlMessage = new Promise<string>((resolve) => {
      socket.addEventListener("message", (event) => resolve(String(event.data)), { once: true });
    });
    const response = await SELF.fetch(
      await signedRequest("/v1/sentinel", { method: "POST", body: { operation_id: requestId, target_request_id: wakeOperationID } }),
    );
    expect(await response.json()).toMatchObject({
      operation_id: requestId,
      target_request_id: wakeOperationID,
      state: "sentinel_pending",
      delivered: true,
      confirmed: false,
    });
    expect(JSON.parse(await controlMessage)).toMatchObject({
      type: "return_to_sentinel",
      operation_id: requestId,
      target_request_id: wakeOperationID,
      requested_at: expect.any(String),
      delivered_at: expect.any(String),
    });
    expect(await operationState(requestId)).toBe("sentinel_pending");

    socket.send(JSON.stringify({
      type: "operation_status",
      operation_id: requestId,
      sequence: await operationSequence(requestId),
      state: "returned_to_sentinel",
      status: hostStatus(),
    }));
    await expect.poll(() => operationState(requestId)).toBe("returned_to_sentinel");

    const disarmOperationID = `disarm_${crypto.randomUUID().replace(/-/g, "")}`;
    const repeatedControl = matchingMessage(socket, (value) => value.type === "disarm" && value.operation_id === disarmOperationID);
    const disarm = await SELF.fetch(
      await signedRequest("/v1/disarm", {
        method: "POST",
        body: { operation_id: disarmOperationID, target_request_id: wakeOperationID },
      }),
    );
    expect(await disarm.json()).toMatchObject({
      operation_id: disarmOperationID,
      target_request_id: wakeOperationID,
      state: "disarm_pending",
    });
    expect(await repeatedControl).toMatchObject({
      type: "disarm",
      operation_id: disarmOperationID,
      target_request_id: wakeOperationID,
    });
    socket.send(JSON.stringify({
      type: "operation_status",
      operation_id: disarmOperationID,
      sequence: await operationSequence(disarmOperationID),
      state: "disarmed",
      status: hostStatus({ state: "offline" }),
    }));
    await expect.poll(() => operationState(disarmOperationID)).toBe("disarmed");
    expect(await operationState(requestId)).toBe("returned_to_sentinel");
    socket.close(1000, "done");
  });

  it("keeps sentinel cleanup retryable, then makes terminal acknowledgement replay idempotent", async () => {
    const upgrade = await SELF.fetch(
      await signedRequest("/v1/host/socket", { kid: "host-v1", upgrade: true }),
    );
    const socket = upgrade.webSocket!;
    socket.accept();
    const operationID = `cleanup_${crypto.randomUUID().replace(/-/g, "")}`;
    const firstDelivery = matchingMessage(socket, (value) => value.type === "return_to_sentinel" && value.operation_id === operationID);
    await SELF.fetch(await signedRequest("/v1/sentinel", { method: "POST", body: { operation_id: operationID } }));
    const first = await firstDelivery;

    socket.send(JSON.stringify({
      type: "operation_status",
      operation_id: operationID,
      sequence: await operationSequence(operationID),
      state: "sentinel_cleanup_pending",
      status: hostStatus({ failure_reason: "one exact-owned process is still exiting" }),
      failure_reason: "one exact-owned process is still exiting",
    }));
    await expect.poll(() => operationState(operationID)).toBe("sentinel_cleanup_pending");

    const retryDelivery = matchingMessage(socket, (value) => value.type === "return_to_sentinel" && value.operation_id === operationID);
    const retry = await SELF.fetch(await signedRequest("/v1/sentinel", { method: "POST", body: { operation_id: operationID } }));
    expect(retry.status).toBe(202);
    expect(await retry.json()).toMatchObject({ operation_id: operationID, state: "sentinel_cleanup_pending", confirmed: false });
    const second = await retryDelivery;
    expect(second).toMatchObject({
      operation_id: operationID,
      sequence: first.sequence,
      requested_at: first.requested_at,
    });
    expect(Date.parse(String(second.delivered_at))).toBeGreaterThanOrEqual(Date.parse(String(first.delivered_at)));

    socket.send(JSON.stringify({
      type: "operation_status",
      operation_id: operationID,
      sequence: await operationSequence(operationID),
      state: "returned_to_sentinel",
      status: hostStatus(),
    }));
    await expect.poll(() => operationState(operationID)).toBe("returned_to_sentinel");
    const terminal = await operationRecord(operationID);
    socket.send(JSON.stringify({
      type: "operation_status",
      operation_id: operationID,
      sequence: await operationSequence(operationID),
      state: "sentinel_cleanup_pending",
      status: hostStatus({ failure_reason: "stale replay" }),
    }));
    await new Promise((resolve) => setTimeout(resolve, 5));
    expect(await operationRecord(operationID)).toMatchObject({
      state: "returned_to_sentinel",
      updated_at: terminal.updated_at,
    });

    const failedID = `cleanup_failed_${crypto.randomUUID().replace(/-/g, "")}`;
    const failedDelivery = matchingMessage(socket, (value) => value.type === "return_to_sentinel" && value.operation_id === failedID);
    await SELF.fetch(await signedRequest("/v1/sentinel", { method: "POST", body: { operation_id: failedID } }));
    await failedDelivery;
    socket.send(JSON.stringify({
      type: "operation_status",
      operation_id: failedID,
      sequence: await operationSequence(failedID),
      state: "failed",
      status: hostStatus({ failure_reason: "cleanup cannot safely continue" }),
      failure_reason: "cleanup cannot safely continue",
    }));
    await expect.poll(() => operationState(failedID)).toBe("failed");
    const noFailureLoop = expectNoMatchingMessage(socket, (value) => value.type === "return_to_sentinel" && value.operation_id === failedID);
    const failedRetry = await SELF.fetch(await signedRequest("/v1/sentinel", { method: "POST", body: { operation_id: failedID } }));
    expect(failedRetry.status).toBe(200);
    expect(await failedRetry.json()).toMatchObject({ operation_id: failedID, state: "failed", delivered: false });
    await noFailureLoop;
    socket.close(1000, "done");
  });

  it("clears an older cleanup retry when Guardian reports sequence supersession", async () => {
    const upgrade = await SELF.fetch(await signedRequest("/v1/host/socket", { kid: "host-v1", upgrade: true }));
    const socket = upgrade.webSocket!;
    socket.accept();
    const sentinelID = `superseded_sentinel_${crypto.randomUUID().replace(/-/g, "")}`;
    const sentinelDelivery = matchingMessage(socket, (value) => value.type === "return_to_sentinel" && value.operation_id === sentinelID);
    await SELF.fetch(await signedRequest("/v1/sentinel", { method: "POST", body: { operation_id: sentinelID } }));
    const sentinel = await sentinelDelivery;
    socket.send(JSON.stringify({
      type: "operation_status",
      operation_id: sentinelID,
      sequence: sentinel.sequence,
      state: "sentinel_cleanup_pending",
      status: hostStatus({ failure_reason: "cleanup still pending" }),
      failure_reason: "cleanup still pending",
    }));
    await expect.poll(() => operationState(sentinelID)).toBe("sentinel_cleanup_pending");

    const newerWakeID = `superseding_wake_${crypto.randomUUID().replace(/-/g, "")}`;
    await SELF.fetch(await signedRequest("/v1/wake", {
      method: "POST",
      body: { operation_id: newerWakeID, apps: ["chatgpt"], duration_minutes: 30 },
    }));
    expect(await operationSequence(newerWakeID)).toBeGreaterThan(Number(sentinel.sequence));
    socket.send(JSON.stringify({
      type: "operation_status",
      operation_id: sentinelID,
      sequence: sentinel.sequence,
      state: "cancelled",
      status: hostStatus({ failure_reason: "superseded by newer operation sequence" }),
      failure_reason: "superseded by newer operation sequence",
    }));
    await expect.poll(() => operationState(sentinelID)).toBe("cancelled");

    const noRetry = expectNoMatchingMessage(socket, (value) => value.type === "return_to_sentinel" && value.operation_id === sentinelID);
    const retry = await SELF.fetch(await signedRequest("/v1/sentinel", { method: "POST", body: { operation_id: sentinelID } }));
    expect(retry.status).toBe(200);
    expect(await retry.json()).toMatchObject({ operation_id: sentinelID, state: "cancelled", delivered: false });
    await noRetry;
    socket.close(1000, "done");

    const reconnect = await SELF.fetch(await signedRequest("/v1/host/socket", { kid: "host-v1", upgrade: true }));
    const reconnectSocket = reconnect.webSocket!;
    reconnectSocket.accept();
    const noReconnectRetry = expectNoMatchingMessage(reconnectSocket, (value) => value.type === "return_to_sentinel" && value.operation_id === sentinelID);
    reconnectSocket.send(JSON.stringify({ type: "hello", status: hostStatus() }));
    await noReconnectRetry;
    reconnectSocket.close(1000, "done");
  });
});
