# Native macOS components

`AwareGuardian` runs in the logged-in user's launchd domain. It maintains the authenticated outbound WebSocket, evaluates battery/thermal policy, and launches only the four compiled-in application bundle identifiers. It never unlocks the session or accepts shell commands, paths, AppleScript, or arbitrary bundle identifiers.

`AwarePowerHelper` runs as root and accepts exactly `arm`, `heartbeat`, `disarm`, and `status` as one-line JSON messages. Its Unix socket is owned by the configured GUI UID, mode `0600`, and every connection is independently checked with `getpeereid(3)`. It invokes only `/usr/bin/pmset -a disablesleep 0|1` with fixed arguments. The daemon measures its lease with a monotonic clock and checks it four times per second; it restores normal sleep at startup, no later than the 120-second lease ceiling after the last heartbeat, on disarm, and during orderly termination.

Guardian atomically persists the original Battery Day deadline plus the active lease, requested apps, and owned PID/bundle/process-start identities. On Guardian restart it persists disarmed intent, restores normal sleep, and cleans up only those exact surviving processes; it never resumes the old lease or re-arms without a fresh authenticated wake. Calibrated drain is an upper bound on both the persisted deadline and `estimated_ready_until`; an uncalibrated estimate is explicitly reported as `best_effort`. Telemetry grace is measured with monotonic time, and unknown thermal telemetry fails closed. If only the helper restarts while Guardian continues running with durable armed intent, the next heartbeat safely re-arms it. A remote disarm or safety shutdown permanently changes that intent before restoration.

Every app launch is a serialized two-phase durable transaction. Guardian first records the operation/lease and exact pre-launch PID/start-time set, requests a distinct instance, and accepts ownership only from the `NSWorkspace` completion-returned application when it is provably distinct. Set deltas are never provenance. A restart retains an unresolved pending operation for diagnosis and refuses to infer ownership, terminate ambiguous processes, or re-arm. Any pre/post persistence failure stops heartbeats, gracefully cleans exact in-memory ownership, clears local lease intent, and requests helper disarm; it never reports `remote_ready`.

`return_to_sentinel` is acknowledged only after every exact Aware-owned process exits. A refusal is reported as failed/pending and ownership remains durable for retry. Disarm and safety restoration may restore normal sleep immediately, but surviving exact ownership remains persisted and is retried rather than discarded.

The state file also records desired helper intent. Auto-arm applies only to first initialization; restart always writes disarmed intent and restores normal sleep until a fresh authenticated wake. Launches time out after 15 seconds and carry a cancellation generation. Safety/disarm preempts an active launch, persists disarmed intent, stops heartbeat authority, and calls helper disarm before application cleanup. Monitor emergency checks run even while the launch gate is active.

Return-to-sentinel first clears and persists lease/requested-app run intent, then awaits cleanup. Survivors or an unresolved late launch produce retryable `sentinel_cleanup_pending`; redelivery of the same operation retries cleanup and only zero survivors produce `returned_to_sentinel`. Cached terminal results are replayed before transport-age rejection.

Return-to-sentinel is also an explicit sentinel arm request. Guardian first validates live battery/thermal telemetry, durably records armed sentinel intent, and verifies the helper before cleanup. It acknowledges success only while the helper remains verified armed and no exactly-owned app survives. WebSocket reception admits at most eight concurrent handlers, allowing disarm or sentinel safety commands to enter Guardian while an app launch is suspended without unbounded buffering.

Wake freshness remains tied to immutable `created_at`, so reconnects cannot extend a lease. Each command has an immutable `operation_id` and positive Worker `sequence`; optional `target_request_id` is correlation only. Guardian durably persists the highest accepted sequence before effects, so concurrent handler arrival cannot let an older safety or power-up command overwrite newer intent. Cached operation replay uses its persisted original sequence. Durable controls retain authenticated `requested_at` for audit but validate Worker-generated `delivered_at`.

Cached terminal results replay only for the exact original operation sequence. Cached nonterminal work may continue only while it is still the highest accepted sequence; otherwise Guardian reports terminal `cancelled`. A safety-cleanup gate makes newer wakes wait until older exact cleanup releases, while every reentrant safety step rechecks sequence authority. Thus an older sentinel/disarm can clean its own resources but cannot resume and overwrite a newer wake.

Safety cleanup uses a set keyed by operation ID and sequence, not a single slot. A wake waits for every older cleanup entry, so overlapping disarm and thermal/sentinel cleanup cannot outlive the barrier and later terminate the newer wake's processes.

Amphetamine is treated only as one of the four launchable UIs. Guardian never starts or ends its sessions; PowerHelper is the sole sleep authority.

## Build and verify

```zsh
swift build
swift test
swift run AwareCoreChecks
```

The explicit `AwareCoreChecks` runner exists because some Command Line Tools-only installations discover Swift Testing tests but do not execute them. It uses a fake power controller and never invokes `pmset`.

## Install

Deploy the Worker first. Use a dedicated host key for the Mac and a different phone key for Scriptable, then run. The installer prompts for the host secret with terminal echo disabled; the secret is never placed in shell history, an environment variable, or a process argument.

```zsh
sudo Resources/scripts/install.sh 'wss://YOUR-WORKER/v1/host/socket' 'host-v1'
```

Installation intentionally requires a logged-in GUI user. It builds as that user, installs the two binaries, creates restrictive configuration, and invokes the installed Guardian's stdin-only setup mode so Keychain creation and later reads have the same executable identity. Keychain reads/updates use an `LAContext` with `interactionNotAllowed`: no background prompt is assumed, and an ACL mismatch is a hard error. It does not rely on a separately signed helper or put the secret in argv/environment. The script is not run as part of builds or tests.

Upgrade ordering is fixed: boot out old jobs, restore sleep, invoke the old Guardian's noninteractive delete mode, abort on failure, replace binaries, then collect/recreate the secret with the new Guardian. The old executable is never overwritten before its Keychain migration succeeds.

The iMessage adapter remains hard-disabled (`imessage_adapter_enabled` must be `false`) until the separate 19/20 closed-lid trial gate is met. Low Power Mode is likewise not changed until the planned compatibility and drain tests pass.

`auto_arm` is the v1 Arm Battery Day mode. On battery, its sentinel is bounded by `battery_sentinel_hours` (installed as 24); when the deadline passes without an active lease, Guardian gracefully closes its apps and restores normal sleep.
