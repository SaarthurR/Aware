// Install this file, AwareRemoteCore.js, and AwareSigning.js in Scriptable's iCloud Drive directory.
const { sign } = importModule("AwareSigning");
const RemoteCore = importModule("AwareRemoteCore");

const ENDPOINT_KEY = "aware.endpoint";
const KID_KEY = "aware.phone.kid";
const SECRET_KEY = "aware.phone.secret";
const LAST_SESSION_KEY = "aware.last.session";

async function setup() {
  const alert = new Alert();
  alert.title = "Configure Aware";
  alert.message = "Use the Worker URL and the phone key installed in Cloudflare.";
  alert.addTextField("https://aware-worker.example.workers.dev", Keychain.contains(ENDPOINT_KEY) ? Keychain.get(ENDPOINT_KEY) : "");
  alert.addTextField("Key ID", Keychain.contains(KID_KEY) ? Keychain.get(KID_KEY) : "phone-v1");
  alert.addSecureTextField("Base64url secret", "");
  alert.addAction("Save");
  alert.addCancelAction("Cancel");
  if (await alert.presentAlert() === -1) throw new Error("Setup cancelled");
  const endpoint = alert.textFieldValue(0).replace(/\/$/, "");
  if (!/^https:\/\//.test(endpoint)) throw new Error("Aware endpoint must use HTTPS");
  const secret = alert.textFieldValue(2).trim();
  if (secret.length < 43) throw new Error("Use a random 32-byte base64url secret");
  Keychain.set(ENDPOINT_KEY, endpoint);
  Keychain.set(KID_KEY, alert.textFieldValue(1).trim());
  Keychain.set(SECRET_KEY, secret);
}

function uuid() {
  return UUID.string().replace(/-/g, "").toLowerCase();
}

async function signedFetch(path, method = "GET", payload = null) {
  if (![ENDPOINT_KEY, KID_KEY, SECRET_KEY].every((key) => Keychain.contains(key))) await setup();
  const timestamp = Math.floor(Date.now() / 1000);
  const nonce = uuid();
  const completePayload = payload ? { ...payload, timestamp, nonce } : null;
  const body = completePayload ? JSON.stringify(completePayload) : "";
  const request = new Request(Keychain.get(ENDPOINT_KEY) + path);
  request.method = method;
  request.headers = {
    "Content-Type": "application/json",
    "X-Aware-Key-Id": Keychain.get(KID_KEY),
    "X-Aware-Timestamp": String(timestamp),
    "X-Aware-Nonce": nonce,
    "X-Aware-Signature": sign(method, path, timestamp, nonce, body, Keychain.get(SECRET_KEY)),
  };
  if (body) request.body = body;
  const data = await request.loadJSON();
  if (!request.response || request.response.statusCode < 200 || request.response.statusCode >= 300) {
    throw new Error(data && data.error ? data.error : `Aware returned HTTP ${request.response && request.response.statusCode}`);
  }
  return data;
}

async function chooseWake() {
  const alert = new Alert();
  alert.title = "Aware Remote";
  alert.message = "Launch all remote apps for:";
  alert.addAction("Two hours");
  alert.addAction("30 minutes");
  alert.addAction("Until battery reserve");
  alert.addCancelAction("Cancel");
  const choice = await alert.presentSheet();
  if (choice === -1) throw new Error("Cancelled");
  return { action: "wake", apps: RemoteCore.ALLOWED_APPS, duration_minutes: [120, 30, "reserve"][choice] };
}

function parseInput() {
  if (!args.shortcutParameter) return null;
  if (typeof args.shortcutParameter === "string") return JSON.parse(args.shortcutParameter);
  return args.shortcutParameter;
}

async function poll(operationID, terminalStates, timeoutMilliseconds = 45_000) {
  const deadline = Date.now() + timeoutMilliseconds;
  let lastRequest = null;
  while (Date.now() < deadline) {
    lastRequest = await signedFetch(`/v1/operation/${encodeURIComponent(operationID)}`);
    if (terminalStates.includes(lastRequest.state)) return { completed: true, result: lastRequest };
    await new Promise((resolve) => Timer.schedule(2, false, resolve));
  }
  return {
    completed: false,
    lastRequest,
    host: await signedFetch("/v1/host"),
  };
}

async function wake(input) {
  const operationID = `ios_${uuid()}`;
  const targetRequestID = input.target_request_id || null;
  Keychain.set(LAST_SESSION_KEY, operationID);
  await signedFetch("/v1/wake", "POST", RemoteCore.wakePayload(operationID, targetRequestID, input));
  const outcome = await poll(operationID, RemoteCore.WAKE_TERMINAL_STATES);
  if (outcome.completed) return outcome.result;
  return { operation_id: operationID, state: "timeout", host: outcome.host, failure_reason: "The wake operation remains queued and can still complete" };
}

function targetRequestID(input) {
  return input.target_request_id || (Keychain.contains(LAST_SESSION_KEY) ? Keychain.get(LAST_SESSION_KEY) : null);
}

async function control(input, action, path, terminalState) {
  const operationID = `ios_${uuid()}`;
  const target = targetRequestID(input);
  const accepted = await signedFetch(path, "POST", RemoteCore.controlPayload(operationID, target));
  if (accepted.state === terminalState) return accepted;
  const observableStates = action === "return_to_sentinel"
    ? [terminalState, "sentinel_cleanup_pending", "cancelled", "failed"]
    : [terminalState, "cancelled", "failed"];
  const outcome = await poll(operationID, observableStates);
  if (outcome.completed) return outcome.result;
  return RemoteCore.unconfirmedControl(operationID, target, action, outcome.lastRequest, outcome.host);
}

async function disarm(input) {
  return control(input, "disarm", "/v1/disarm", "disarmed");
}

async function returnToSentinel(input) {
  return control(input, "return_to_sentinel", "/v1/sentinel", "returned_to_sentinel");
}

async function main() {
  let input = parseInput();
  if (!input && config.runsInApp) {
    const menu = new Alert();
    menu.title = "Aware Remote";
    menu.addAction("Wake remote apps");
    menu.addAction("Return to battery sentinel");
    menu.addDestructiveAction("Disarm & restore sleep");
    menu.addAction("Show host status");
    menu.addDestructiveAction("Reconfigure");
    menu.addCancelAction("Cancel");
    const choice = await menu.presentSheet();
    if (choice === 0) input = await chooseWake();
    else if (choice === 1) input = { action: "sentinel" };
    else if (choice === 2) input = { action: "disarm" };
    else if (choice === 3) input = { action: "status" };
    else if (choice === 4) { await setup(); return { state: "configured" }; }
    else throw new Error("Cancelled");
  }
  input = input || { action: "wake", apps: RemoteCore.ALLOWED_APPS, duration_minutes: 120 };
  if (input.action === "wake") return wake(input);
  if (input.action === "sentinel") return returnToSentinel(input);
  if (input.action === "disarm") return disarm(input);
  if (input.action === "status") return signedFetch("/v1/host");
  if (input.action === "setup") { await setup(); return { state: "configured" }; }
  throw new Error("Unsupported action");
}

async function presentResult(result, offerPostReadyControls = true) {
  const alert = new Alert();
  alert.title = result.state === "remote_ready" ? "Aware is ready" : "Aware status";
  alert.message = RemoteCore.statusMessage(result);
  if (result.state === "remote_ready" && offerPostReadyControls) {
    alert.addAction("Open ChatGPT");
    alert.addAction("Open Claude");
    alert.addAction("Extend two hours");
    alert.addAction("Run until reserve");
    alert.addAction("Return to sentinel");
    alert.addCancelAction("Done");
    const action = RemoteCore.postReadyAction(await alert.presentSheet());
    if (action.kind === "open") Safari.open(action.url);
    if (action.kind === "wake") {
      const extended = await wake({
        apps: result.apps || RemoteCore.ALLOWED_APPS,
        duration_minutes: action.duration_minutes,
        target_request_id: result.operation_id,
      });
      return presentResult(extended, false);
    }
    if (action.kind === "sentinel") {
      const sentinel = await returnToSentinel({ target_request_id: result.operation_id });
      return presentResult(sentinel, false);
    }
    return result;
  }
  alert.addAction("OK");
  await alert.presentAlert();
  return result;
}

try {
  let result = await main();
  if (config.runsInApp) result = await presentResult(result);
  Script.setShortcutOutput(JSON.stringify(result));
} catch (caught) {
  const failure = { state: "error", failure_reason: String(caught.message || caught) };
  Script.setShortcutOutput(JSON.stringify(failure));
  if (config.runsInApp) {
    const alert = new Alert(); alert.title = "Aware failed"; alert.message = failure.failure_reason; alert.addAction("OK"); await alert.presentAlert();
  }
}
Script.complete();
