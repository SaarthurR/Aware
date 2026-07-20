export const APPS = ["chatgpt", "claude", "cursor", "amphetamine"] as const;
export type AppId = (typeof APPS)[number];

export const DURATIONS = [30, 120, "reserve"] as const;
export type DurationMinutes = (typeof DURATIONS)[number];

export type HostState =
  | "ac_ready"
  | "battery_sentinel"
  | "battery_active"
  | "reserve_sleep"
  | "offline";

export interface HostStatus {
  state: HostState;
  power_source: "ac" | "battery" | "unknown";
  battery_percent: number | null;
  thermal_state: "nominal" | "fair" | "serious" | "critical" | "unknown";
  sentinel_drain_percent_per_hour: number | null;
  estimated_ready_until: string | null;
  readiness_estimate_quality: "calibrated" | "best_effort";
  apps_started: AppId[];
  last_seen: string;
  failure_reason: string | null;
}

/** Public status returned before Guardian has ever supplied a heartbeat. */
export interface NeverConnectedHostStatus extends Omit<HostStatus, "last_seen"> {
  state: "offline";
  last_seen: null;
}

export type HostStatusResponse = HostStatus | NeverConnectedHostStatus;

export type OperationState =
  | "queued"
  | "socket_observed"
  | "power_armed"
  | "apps_started"
  | "remote_ready"
  | "reserve_sleep"
  | "failed"
  | "cancelled"
  | "sentinel_cleanup_pending"
  | "disarm_pending"
  | "sentinel_pending"
  | "disarmed"
  | "returned_to_sentinel";

export interface WakeOperation {
  operation_id: string;
  target_request_id?: string;
  timestamp: number;
  nonce: string;
  apps: AppId[];
  duration_minutes: DurationMinutes;
}

export interface OperationRecord {
  operation_id: string;
  target_request_id: string | null;
  kind: "wake" | "disarm" | "return_to_sentinel";
  sequence: number;
  apps: AppId[];
  duration_minutes: DurationMinutes | null;
  state: OperationState;
  created_at: string;
  updated_at: string;
  failure_reason: string | null;
  host: HostStatus | null;
}

export interface Env {
  AWARE_HOST: DurableObjectNamespace;
  AWARE_HMAC_KEYS: string;
  AWARE_PHONE_KIDS: string;
  AWARE_HOST_KIDS: string;
  AWARE_HOST_OFFLINE_SECONDS?: string;
}

export interface AuthContext {
  kid: string;
  timestamp: number;
  nonce: string;
}
