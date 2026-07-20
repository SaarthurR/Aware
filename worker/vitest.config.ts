import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

// Public, test-only keys. Production secrets are installed with `wrangler secret put`.
const phoneKey = "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY";
const phoneNextKey = "ZmVkY2JhOTg3NjU0MzIxMGZlZGNiYTk4NzY1NDMyMTBmZWQ";
const hostKey = "YWJjZGVmMDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODk";

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.toml" },
      miniflare: {
        bindings: {
          AWARE_HMAC_KEYS: JSON.stringify({ "phone-v1": phoneKey, "phone-v2": phoneNextKey, "host-v1": hostKey }),
          AWARE_PHONE_KIDS: "phone-v1,phone-v2",
        },
      },
    }),
  ],
  test: {
    globals: false,
  },
});
