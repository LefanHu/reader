output "project_id" {
  description = "Environment Google Cloud project ID."
  value       = google_project.environment.project_id
}

output "project_number" {
  description = "Environment Google Cloud project number."
  value       = google_project.environment.number
}

output "firebase_app_id" {
  description = "Firebase-assigned Apple app identifier."
  value       = google_firebase_apple_app.reader.app_id
}

output "firebase_config" {
  description = "Base64-encoded GoogleService-Info.plist used to generate local Dart defines."
  sensitive   = true
  value       = data.google_firebase_apple_app_config.reader.config_file_contents
}

output "illustrations_bucket" {
  description = "Private Firebase-associated illustration bucket."
  value       = google_storage_bucket.illustrations.name
}

output "artifact_registry_repository" {
  description = "Artifact Registry repository resource name."
  value       = google_artifact_registry_repository.backend.name
}

output "api_service_account" {
  value = google_service_account.api.email
}

output "worker_service_account" {
  value = google_service_account.worker.email
}

output "task_service_account" {
  value = google_service_account.task.email
}

output "build_service_account" {
  value = google_service_account.build.email
}

output "task_queue" {
  value = google_cloud_tasks_queue.illustrations.name
}

output "openai_secret_id" {
  value = google_secret_manager_secret.openai.secret_id
}

output "fingerprint_secret_id" {
  value = google_secret_manager_secret.fingerprint.secret_id
}

output "notification_channel" {
  description = "Monitoring email channel shared by runtime alert policies."
  value       = google_monitoring_notification_channel.email.name
}
