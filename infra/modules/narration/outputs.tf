output "task_queue" {
  description = "Dedicated narration queue consumed by the existing API/worker runtime."
  value       = google_cloud_tasks_queue.narration.name
}
