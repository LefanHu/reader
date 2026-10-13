import { once } from "node:events";
import type { Server } from "node:http";
import type { AddressInfo } from "node:net";
import type express from "express";
import { httpErrorHandler } from "../http.js";

/** A loopback test server and its base URL; `close` waits for the listener to stop. */
export type TestServer = { server: Server; baseUrl: string; close(): Promise<void> };

/**
 * Starts `app` on an ephemeral 127.0.0.1 port. By default it first appends the
 * production error translator (`httpErrorHandler`, silenced), so tests observe
 * exactly the status and `{error}` body clients receive, including the fixed
 * 500 "Request failed." for unexpected errors. Pass `productionErrors: false`
 * for standalone apps that own their final error handling.
 */
export async function startTestServer(app: express.Express, options: { productionErrors?: boolean } = {}): Promise<TestServer> {
  if (options.productionErrors ?? true) app.use(httpErrorHandler(() => {}));
  const server = app.listen(0, "127.0.0.1");
  await once(server, "listening");
  const { port } = server.address() as AddressInfo;
  return {
    server,
    baseUrl: `http://127.0.0.1:${port}`,
    close: () => new Promise<void>((resolve, reject) => server.close(error => error ? reject(error) : resolve())),
  };
}

/** Test-only identity middleware standing in for verified Firebase authentication. */
export function assignUid(uid: (req: express.Request) => string): express.RequestHandler {
  return (req, _res, next) => { (req as express.Request & { uid: string }).uid = uid(req); next(); };
}
