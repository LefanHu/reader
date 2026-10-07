import type { CloudTasksClient, protos } from "@google-cloud/tasks";

/** Builds private worker tasks with a task name in the selected parent queue.
 * The shared API may enqueue illustration and narration work independently. */
export function workerTaskRequest(
  client: Pick<CloudTasksClient, "queuePath" | "taskPath">,
  options: {
    project: string;
    location: string;
    queue: string;
    taskId: string;
    workerUrl: string;
    serviceAccount: string;
    path: string;
    payload: Record<string, unknown>;
  },
): protos.google.cloud.tasks.v2.ICreateTaskRequest {
  const { project, location, queue, taskId } = options;
  return {
    parent: client.queuePath(project, location, queue),
    task: {
      name: client.taskPath(project, location, queue, taskId),
      httpRequest: {
        httpMethod: "POST",
        url: `${options.workerUrl}${options.path}`,
        headers: { "content-type": "application/json" },
        body: Buffer.from(JSON.stringify(options.payload)).toString("base64"),
        oidcToken: { serviceAccountEmail: options.serviceAccount },
      },
    },
  };
}
