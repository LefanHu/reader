import { createImageTestProviderApp } from "./image-test-provider.js";

/** Entry point for the separately deployed pipeline-test service (dev only). */
const port = Number(process.env.PORT ?? 8080);
createImageTestProviderApp().listen(port, () => console.log(JSON.stringify({ event: "listening", port })));
