import { AwareHost } from "./aware-host";
import type { Env } from "./types";

export { AwareHost };

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const isKnownRoute =
      (request.method === "POST" && (url.pathname === "/v1/wake" || url.pathname === "/v1/disarm" || url.pathname === "/v1/sentinel")) ||
      (request.method === "GET" &&
        (url.pathname === "/v1/host" ||
          url.pathname === "/v1/host/socket" ||
          /^\/v1\/operation\/[A-Za-z0-9_-]{8,128}$/.test(url.pathname)));
    if (!isKnownRoute) {
      return Response.json({ error: "not_found" }, { status: 404 });
    }

    const id = env.AWARE_HOST.idFromName("primary");
    return env.AWARE_HOST.get(id).fetch(request);
  },
} satisfies ExportedHandler<Env>;
