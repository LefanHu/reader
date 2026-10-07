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

output "notification_channel" {
  description = "Monitoring email channel shared by runtime alert policies."
  value       = google_monitoring_notification_channel.email.name
}
