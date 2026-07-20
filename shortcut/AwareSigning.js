// Pure-JavaScript SHA-256/HMAC for Scriptable, which does not expose Web Crypto.
// This module intentionally accepts only UTF-8 strings and base64url keys.

const K = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

function utf8(value) {
  const encoded = unescape(encodeURIComponent(value));
  const output = [];
  for (let index = 0; index < encoded.length; index += 1) output.push(encoded.charCodeAt(index));
  return output;
}

function rotateRight(value, shift) {
  return (value >>> shift) | (value << (32 - shift));
}

function sha256(bytes) {
  const data = bytes.slice();
  const bitLength = data.length * 8;
  data.push(0x80);
  while (data.length % 64 !== 56) data.push(0);
  const high = Math.floor(bitLength / 0x100000000);
  const low = bitLength >>> 0;
  for (let shift = 24; shift >= 0; shift -= 8) data.push((high >>> shift) & 0xff);
  for (let shift = 24; shift >= 0; shift -= 8) data.push((low >>> shift) & 0xff);

  const hash = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
  for (let offset = 0; offset < data.length; offset += 64) {
    const words = new Array(64).fill(0);
    for (let index = 0; index < 16; index += 1) {
      const position = offset + index * 4;
      words[index] = ((data[position] << 24) | (data[position + 1] << 16) | (data[position + 2] << 8) | data[position + 3]) >>> 0;
    }
    for (let index = 16; index < 64; index += 1) {
      const s0 = rotateRight(words[index - 15], 7) ^ rotateRight(words[index - 15], 18) ^ (words[index - 15] >>> 3);
      const s1 = rotateRight(words[index - 2], 17) ^ rotateRight(words[index - 2], 19) ^ (words[index - 2] >>> 10);
      words[index] = (words[index - 16] + s0 + words[index - 7] + s1) >>> 0;
    }
    let [a, b, c, d, e, f, g, h] = hash;
    for (let index = 0; index < 64; index += 1) {
      const s1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25);
      const choice = (e & f) ^ (~e & g);
      const temp1 = (h + s1 + choice + K[index] + words[index]) >>> 0;
      const s0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22);
      const majority = (a & b) ^ (a & c) ^ (b & c);
      const temp2 = (s0 + majority) >>> 0;
      h = g; g = f; f = e; e = (d + temp1) >>> 0; d = c; c = b; b = a; a = (temp1 + temp2) >>> 0;
    }
    hash[0] = (hash[0] + a) >>> 0; hash[1] = (hash[1] + b) >>> 0;
    hash[2] = (hash[2] + c) >>> 0; hash[3] = (hash[3] + d) >>> 0;
    hash[4] = (hash[4] + e) >>> 0; hash[5] = (hash[5] + f) >>> 0;
    hash[6] = (hash[6] + g) >>> 0; hash[7] = (hash[7] + h) >>> 0;
  }
  const output = [];
  for (const word of hash) for (let shift = 24; shift >= 0; shift -= 8) output.push((word >>> shift) & 0xff);
  return output;
}

function hmacSha256(key, message) {
  let normalized = key.slice();
  if (normalized.length > 64) normalized = sha256(normalized);
  while (normalized.length < 64) normalized.push(0);
  const inner = normalized.map((byte) => byte ^ 0x36).concat(message);
  const outer = normalized.map((byte) => byte ^ 0x5c).concat(sha256(inner));
  return sha256(outer);
}

function hex(bytes) {
  return bytes.map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function base64UrlDecode(value) {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  const input = value.replace(/-/g, "+").replace(/_/g, "/").replace(/=+$/, "");
  const output = [];
  let buffer = 0;
  let bits = 0;
  for (const character of input) {
    const digit = alphabet.indexOf(character);
    if (digit < 0) throw new Error("Secret is not valid base64url");
    buffer = (buffer << 6) | digit;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      output.push((buffer >>> bits) & 0xff);
    }
  }
  return output;
}

function base64UrlEncode(bytes) {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
  let output = "";
  let buffer = 0;
  let bits = 0;
  for (const byte of bytes) {
    buffer = (buffer << 8) | byte;
    bits += 8;
    while (bits >= 6) {
      bits -= 6;
      output += alphabet[(buffer >>> bits) & 63];
    }
  }
  if (bits > 0) output += alphabet[(buffer << (6 - bits)) & 63];
  return output;
}

function canonicalPath(path) {
  const question = path.indexOf("?");
  if (question < 0) return path;
  const pathname = path.slice(0, question);
  const pairs = path.slice(question + 1).split("&").filter(Boolean).map((pair) => {
    const equal = pair.indexOf("=");
    return equal < 0 ? [decodeURIComponent(pair), ""] : [decodeURIComponent(pair.slice(0, equal)), decodeURIComponent(pair.slice(equal + 1))];
  });
  pairs.sort((left, right) => left[0] === right[0] ? left[1].localeCompare(right[1]) : left[0].localeCompare(right[0]));
  return `${pathname}?${pairs.map(([key, value]) => `${encodeURIComponent(key)}=${encodeURIComponent(value)}`).join("&")}`;
}

function sign(method, path, timestamp, nonce, body, secret) {
  const canonical = [method.toUpperCase(), canonicalPath(path), String(timestamp), nonce, hex(sha256(utf8(body)))].join("\n");
  return base64UrlEncode(hmacSha256(base64UrlDecode(secret), utf8(canonical)));
}

module.exports = { base64UrlDecode, base64UrlEncode, canonicalPath, hex, hmacSha256, sha256, sign, utf8 };
