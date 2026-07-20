import type { AuthContext, Env } from "./types";

const MAX_SKEW_SECONDS = 300;
const NONCE_PATTERN = /^[A-Za-z0-9_-]{16,128}$/;

export class AuthError extends Error {
  constructor(
    message: string,
    readonly status = 401,
  ) {
    super(message);
  }
}

function base64UrlDecode(value: string): Uint8Array {
  if (!/^[A-Za-z0-9_-]+$/.test(value)) throw new AuthError("invalid key encoding", 500);
  const base64 = value.replace(/-/g, "+").replace(/_/g, "/");
  const padded = base64.padEnd(Math.ceil(base64.length / 4) * 4, "=");
  const binary = atob(padded);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

function base64UrlEncode(value: ArrayBuffer): string {
  const bytes = new Uint8Array(value);
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function canonicalQuery(url: URL): string {
  const entries: Array<[string, string]> = [];
  url.searchParams.forEach((value, key) => entries.push([key, value]));
  entries.sort(([ak, av], [bk, bv]) =>
    ak === bk ? av.localeCompare(bv) : ak.localeCompare(bk),
  );
  if (entries.length === 0) return url.pathname;
  const query = entries
    .map(([key, value]) => `${encodeURIComponent(key)}=${encodeURIComponent(value)}`)
    .join("&");
  return `${url.pathname}?${query}`;
}

async function hexSha256(body: ArrayBuffer): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", body));
  return [...digest].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

export async function canonicalRequest(
  request: Request,
  timestamp: string,
  nonce: string,
  body: ArrayBuffer,
): Promise<string> {
  const url = new URL(request.url);
  return [request.method.toUpperCase(), canonicalQuery(url), timestamp, nonce, await hexSha256(body)].join("\n");
}

function configuredKids(value: string): Set<string> {
  return new Set(value.split(",").map((kid) => kid.trim()).filter(Boolean));
}

export async function authenticate(
  request: Request,
  body: ArrayBuffer,
  env: Env,
  role: "phone" | "host",
  nowSeconds = Math.floor(Date.now() / 1000),
): Promise<AuthContext> {
  const kid = request.headers.get("X-Aware-Key-Id") ?? "";
  const timestampText = request.headers.get("X-Aware-Timestamp") ?? "";
  const nonce = request.headers.get("X-Aware-Nonce") ?? "";
  const suppliedSignature = request.headers.get("X-Aware-Signature") ?? "";
  const allowedKids = configuredKids(role === "phone" ? env.AWARE_PHONE_KIDS : env.AWARE_HOST_KIDS);

  if (!allowedKids.has(kid)) throw new AuthError("unknown key id");
  if (!NONCE_PATTERN.test(nonce)) throw new AuthError("invalid nonce");
  if (!/^\d{10}$/.test(timestampText)) throw new AuthError("invalid timestamp");
  const timestamp = Number(timestampText);
  if (Math.abs(nowSeconds - timestamp) > MAX_SKEW_SECONDS) throw new AuthError("timestamp outside allowed window");

  let keys: Record<string, string>;
  try {
    keys = JSON.parse(env.AWARE_HMAC_KEYS) as Record<string, string>;
  } catch {
    throw new AuthError("server key configuration is invalid", 500);
  }
  const encodedKey = keys[kid];
  if (!encodedKey) throw new AuthError("key unavailable", 500);
  const rawKey = base64UrlDecode(encodedKey);
  if (rawKey.byteLength < 32) throw new AuthError("configured key is too short", 500);

  const rawKeyBuffer = rawKey.buffer.slice(rawKey.byteOffset, rawKey.byteOffset + rawKey.byteLength) as ArrayBuffer;
  const key = await crypto.subtle.importKey("raw", rawKeyBuffer, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const canonical = await canonicalRequest(request, timestampText, nonce, body);
  const expected = base64UrlEncode(
    await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(canonical)),
  );
  if (expected.length !== suppliedSignature.length) throw new AuthError("invalid signature");
  let mismatch = 0;
  for (let index = 0; index < expected.length; index += 1) {
    mismatch |= expected.charCodeAt(index) ^ suppliedSignature.charCodeAt(index);
  }
  if (mismatch !== 0) throw new AuthError("invalid signature");
  return { kid, timestamp, nonce };
}
