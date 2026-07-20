import assert from "node:assert/strict";
import { createHmac, createHash, randomBytes } from "node:crypto";
import { createRequire } from "node:module";
import test from "node:test";

const require = createRequire(import.meta.url);
const signing = require("./AwareSigning.js");

test("SHA-256 matches Node", () => {
  assert.equal(signing.hex(signing.sha256(signing.utf8("Aware closed-lid sentinel"))), createHash("sha256").update("Aware closed-lid sentinel").digest("hex"));
});

test("HMAC request signature matches Web/Node crypto", () => {
  const key = randomBytes(32);
  const secret = key.toString("base64url");
  const body = JSON.stringify({ operation_id: "ios_12345678", apps: ["chatgpt"], duration_minutes: 30, timestamp: 1784520000, nonce: "abcdefghijklmnop" });
  const canonical = ["POST", "/v1/wake", "1784520000", "abcdefghijklmnop", createHash("sha256").update(body).digest("hex")].join("\n");
  const expected = createHmac("sha256", key).update(canonical).digest("base64url");
  assert.equal(signing.sign("POST", "/v1/wake", 1784520000, "abcdefghijklmnop", body, secret), expected);
});

test("query parameters are sorted canonically", () => {
  assert.equal(signing.canonicalPath("/v1/host?z=2&a=hello%20world&a=first"), "/v1/host?a=first&a=hello%20world&z=2");
});
