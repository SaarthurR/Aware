const KEYS: Record<string, string> = {
  "phone-v1": "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY",
  "phone-v2": "ZmVkY2JhOTg3NjU0MzIxMGZlZGNiYTk4NzY1NDMyMTBmZWQ",
  "host-v1": "YWJjZGVmMDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODk",
};

function decodeBase64Url(value: string): Uint8Array<ArrayBuffer> {
  const padded = value.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(value.length / 4) * 4, "=");
  return Uint8Array.from(atob(padded), (character) => character.charCodeAt(0));
}

function encodeBase64Url(value: ArrayBuffer): string {
  let binary = "";
  for (const byte of new Uint8Array(value)) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function sha256Hex(value: string): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)));
  return [...digest].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

export async function signedRequest(
  path: string,
  options: {
    method?: "GET" | "POST";
    kid?: keyof typeof KEYS;
    nonce?: string;
    timestamp?: number;
    body?: Record<string, unknown>;
    upgrade?: boolean;
  } = {},
): Promise<Request> {
  const method = options.method ?? "GET";
  const kid = options.kid ?? "phone-v1";
  const nonce = options.nonce ?? crypto.randomUUID().replace(/-/g, "");
  const timestamp = options.timestamp ?? Math.floor(Date.now() / 1000);
  const body = options.body ? JSON.stringify({ ...options.body, timestamp, nonce }) : "";
  const url = new URL(path, "https://aware.test");
  const query: Array<[string, string]> = [];
  url.searchParams.forEach((value, key) => query.push([key, value]));
  query.sort(([ak, av], [bk, bv]) => (ak === bk ? av.localeCompare(bv) : ak.localeCompare(bk)));
  const canonicalPath = query.length
    ? `${url.pathname}?${query.map(([key, value]) => `${encodeURIComponent(key)}=${encodeURIComponent(value)}`).join("&")}`
    : url.pathname;
  const canonical = [method, canonicalPath, String(timestamp), nonce, await sha256Hex(body)].join("\n");
  const key = await crypto.subtle.importKey("raw", decodeBase64Url(KEYS[kid]!), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const signature = encodeBase64Url(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(canonical)));
  const headers = new Headers({
    "X-Aware-Key-Id": kid,
    "X-Aware-Timestamp": String(timestamp),
    "X-Aware-Nonce": nonce,
    "X-Aware-Signature": signature,
  });
  if (body) headers.set("Content-Type", "application/json");
  if (options.upgrade) headers.set("Upgrade", "websocket");
  return new Request(url, { method, headers, body: body || undefined });
}
