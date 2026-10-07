import assert from "node:assert/strict";
import test from "node:test";
import { CloudTasksClient } from "@google-cloud/tasks";
import { workerTaskRequest } from "./task-request.js";

test("private tasks belong to the selected feature queue and preserve worker authorization", () => {
  const client = new CloudTasksClient();
  for (const queue of ["reader-illustrations", "reader-narration"]) {
    const request = workerTaskRequest(client, {
      project: "reader-test",
      location: "us-central1",
      queue,
      taskId: "idempotent-job",
      workerUrl: "https://private-worker.example",
      serviceAccount: "tasks@reader-test.iam.gserviceaccount.com",
      path: "/internal/narration/job",
      payload: { retry: 1 },
    });
    const task = request.task!;
    assert.equal(client.matchQueueFromQueueName(request.parent!), queue);
    assert.equal(client.matchQueueFromTaskName(task.name!), queue);
    assert.equal(
      task.name!.slice(0, task.name!.lastIndexOf("/tasks/")),
      request.parent,
    );
    assert.equal(
      task.httpRequest!.url,
      "https://private-worker.example/internal/narration/job",
    );
    assert.equal(
      task.httpRequest!.oidcToken!.serviceAccountEmail,
      "tasks@reader-test.iam.gserviceaccount.com",
    );
    assert.deepEqual(
      JSON.parse(
        Buffer.from(task.httpRequest!.body as string, "base64").toString(),
      ),
      { retry: 1 },
    );
  }
});
