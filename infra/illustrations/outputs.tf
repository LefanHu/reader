output "illustrations_bucket" {
  description = "Private asset bucket used by the API and worker."
  value       = module.illustrations.illustrations_bucket
}

output "artifact_registry_repository" {
  description = "Docker repository used to publish the shared backend image."
  value       = module.illustrations.artifact_registry_repository
}

output "api_service_account" {
  description = "Runtime API identity for authenticated data and asset operations."
  value       = module.illustrations.api_service_account
}

output "worker_service_account" {
  description = "Runtime worker identity for generation and private asset writes."
  value       = module.illustrations.worker_service_account
}

output "task_service_account" {
  description = "OIDC dispatch identity allowed to invoke the private worker."
  value       = module.illustrations.task_service_account
}

output "build_service_account" {
  description = "Dedicated build identity used to publish images and write build logs."
  value       = module.illustrations.build_service_account
}

output "task_queue" {
  description = "Queue name used by the API to schedule illustration jobs."
  value       = module.illustrations.task_queue
}

output "openai_secret_id" {
  description = "Secret Manager container ID referenced by the worker; contains no key value."
  value       = module.illustrations.openai_secret_id
}

output "fingerprint_secret_id" {
  description = "Secret Manager container ID referenced by the API; contains no secret value."
  value       = module.illustrations.fingerprint_secret_id
}
