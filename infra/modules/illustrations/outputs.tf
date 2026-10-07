output "illustrations_bucket" {
  description = "Private asset bucket used by the API and worker."
  value       = google_storage_bucket.illustrations.name
}

output "artifact_registry_repository" {
  description = "Docker repository used to publish the shared backend image."
  value       = google_artifact_registry_repository.backend.name
}

output "api_service_account" {
  description = "Runtime API identity for authenticated data and asset operations."
  value       = google_service_account.api.email
}

output "worker_service_account" {
  description = "Runtime worker identity for generation and private asset writes."
  value       = google_service_account.worker.email
}

output "task_service_account" {
  description = "OIDC dispatch identity allowed to invoke the private worker."
  value       = google_service_account.task.email
}

output "build_service_account" {
  description = "Dedicated build identity used to publish images and write build logs."
  value       = google_service_account.build.email
}

output "task_queue" {
  description = "Queue name used by the API to schedule illustration jobs."
  value       = google_cloud_tasks_queue.illustrations.name
}

output "openai_secret_id" {
  description = "Secret Manager container ID referenced by the worker; contains no key value."
  value       = google_secret_manager_secret.openai.secret_id
}

output "fingerprint_secret_id" {
  description = "Secret Manager container ID referenced by the API; contains no secret value."
  value       = google_secret_manager_secret.fingerprint.secret_id
}
