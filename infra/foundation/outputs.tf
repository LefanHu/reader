output "project_id" {
  value = module.foundation.project_id
}

output "project_number" {
  value = module.foundation.project_number
}

output "firebase_app_id" {
  value = module.foundation.firebase_app_id
}

output "firebase_config" {
  sensitive = true
  value     = module.foundation.firebase_config
}

output "illustrations_bucket" {
  value = module.foundation.illustrations_bucket
}

output "artifact_registry_repository" {
  value = module.foundation.artifact_registry_repository
}

output "api_service_account" {
  value = module.foundation.api_service_account
}

output "worker_service_account" {
  value = module.foundation.worker_service_account
}

output "task_service_account" {
  value = module.foundation.task_service_account
}

output "build_service_account" {
  value = module.foundation.build_service_account
}

output "task_queue" {
  value = module.foundation.task_queue
}

output "openai_secret_id" {
  value = module.foundation.openai_secret_id
}

output "fingerprint_secret_id" {
  value = module.foundation.fingerprint_secret_id
}

output "notification_channel" {
  value = module.foundation.notification_channel
}
