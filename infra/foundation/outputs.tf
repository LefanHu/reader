output "project_id" {
  description = "Shared environment project ID used by dependent infrastructure."
  value       = module.foundation.project_id
}

output "project_number" {
  description = "Numeric environment project identity for billing and IAM integrations."
  value       = module.foundation.project_number
}

output "firebase_app_id" {
  description = "Registered Apple app identity used by Firebase and App Check."
  value       = module.foundation.firebase_app_id
}

output "firebase_config" {
  description = "Base64 Apple Firebase configuration used to generate private local Dart defines."
  sensitive   = true
  value       = module.foundation.firebase_config
}

output "notification_channel" {
  description = "Shared operations email channel consumed by runtime alerts."
  value       = module.foundation.notification_channel
}

output "firebase_macos_config" {
  description = "Base64 macOS Firebase configuration from the shared core owner."
  sensitive   = true
  value       = module.foundation.firebase_macos_config
}

output "google_client_id" {
  description = "Web OAuth audience passed to the native sign-in client; contains no secret."
  value       = var.google_client_id
  sensitive   = true
}
