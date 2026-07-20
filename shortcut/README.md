# Aware on iPhone

The phone companion uses [Scriptable](https://scriptable.app/) because Apple Shortcuts does not have a native HMAC-SHA256 action. `AwareSigning.js` is a small, audited pure-JavaScript signer, `AwareRemoteCore.js` contains testable controller rules, and `AwareRemote.js` provides setup, wake, polling, status, return-to-sentinel, and disarm actions. The secret stays in Scriptable's Keychain and is never placed in the Shortcut itself.

## Install

1. Install Scriptable from the App Store and enable its iCloud Drive folder.
2. In Scriptable, create a script named **AwareSigning** and paste the complete contents of `AwareSigning.js`.
3. Create **AwareRemoteCore** from `AwareRemoteCore.js`, then create **AwareRemote** from `AwareRemote.js`.
4. Run **AwareRemote** once inside Scriptable, select **Reconfigure**, and enter:
   - the HTTPS Worker URL printed by `wrangler deploy`;
   - `phone-v1` (or the currently deployed phone key ID);
   - the matching 32-byte base64url phone secret.
5. Run **Show host status**. An authenticated `offline` response is expected until Guardian connects; an authentication error means the URL, ID, device clock, or secret differs from the Worker.

Scriptable synchronizes script source through iCloud if enabled. It stores Keychain values separately; configure the secret on each phone rather than embedding it in the source.

## Add Apple Shortcuts

Create a Shortcut and add Scriptable's **Run Script** action. Select `AwareRemote` and enable **Run in App** if you want its result menu. Pass one of these dictionaries as the Shortcut Parameter:

```json
{"action":"wake","apps":["chatgpt","claude","cursor","amphetamine"],"duration_minutes":120}
```

```json
{"action":"wake","apps":["chatgpt","claude"],"duration_minutes":30}
```

```json
{"action":"wake","apps":["chatgpt","claude","cursor","amphetamine"],"duration_minutes":"reserve"}
```

For separate home-screen buttons, duplicate the Shortcut with these parameters:

- Status: `{"action":"status"}`
- Return to the battery sentinel without restoring normal sleep: `{"action":"sentinel"}`
- Disarm and restore normal sleep: `{"action":"disarm"}`

If the Scriptable action receives no parameter, it defaults to all four apps for two hours. After `remote_ready`, the interactive result menu displays battery, `estimated_ready_until`, and whether the estimate is calibrated or **best-effort; uncalibrated**. It offers **Open ChatGPT**, **Open Claude**, **Extend two hours**, **Run until reserve**, and **Return to sentinel**. The result is also returned as JSON to the Shortcut, so a Shortcut can branch on `state` and show its own notification.

## Result states

- `remote_ready`: Guardian confirmed the selected apps started.
- `reserve_sleep`: the Mac reached its power or thermal reserve.
- `failed`: Guardian rejected or failed the launch; inspect `failure_reason`.
- `returned_to_sentinel`: Guardian confirmed that Aware-launched apps were closed while the sentinel stayed armed.
- `sentinel_cleanup_pending`: Guardian is still waiting for exact Aware-owned processes to exit; the operation remains queued for safe retry.
- `cancelled`: a later sentinel or disarm safely superseded this pending wake/extend/reserve before it ran.
- `disarmed`: Guardian confirmed normal sleep was restored.
- `control_unconfirmed`: return-to-sentinel or disarm is still safely queued, but Guardian did not confirm it before the 45-second phone timeout. Inspect `host.state`; an offline Mac will receive the command when it reconnects.
- `timeout`: no final response arrived within 45 seconds. The returned host snapshot indicates whether the Mac is still online; the request remains queryable.
- `error`: local validation, networking, clock skew, or authentication failed.

Every Wake, Extend, Run until reserve, Return to sentinel, and Disarm action generates a fresh `operation_id`. Post-ready actions include the current session as `target_request_id`, but that target is context rather than identity. Sentinel and disarm also work without a prior wake and simply omit the target. Both safety actions establish a host-wide ordering barrier: no older pending wake from another phone or session can run afterward. Sentinel closes only the exact app instances launched by Aware and retains closed-lid availability. Disarm fully ends Aware's active and sentinel modes and directs the native helper to restore normal macOS sleep. Neither action starts or ends Amphetamine sessions. The phone polls `/v1/operation/{operation_id}` until Guardian explicitly acknowledges that exact operation; a successful HTTP delivery alone is never displayed as success. After confirmed disarm, a closed, unplugged Mac may become unreachable until someone physically opens it or restores a supported wake condition.

## Security notes

- Do not paste the phone secret into screenshots, Shortcut text actions, URLs, or query strings.
- Keep **Set Automatically** enabled under iPhone Date & Time; requests tolerate at most five minutes of clock skew.
- If the phone is lost, remove its key ID from `AWARE_PHONE_KIDS` and `AWARE_HMAC_KEYS`, deploy, then create a new key.
- The phone API cannot send shell commands, paths, app bundle IDs, or apps outside the four fixed IDs.

Run the portable signer tests from the repository root with:

```sh
node --test shortcut/*.test.mjs
```
