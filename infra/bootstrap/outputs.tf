output "state_project_id" {
  description = "Project containing the protected Terraform state bucket."
  value       = google_project.state.project_id
}

output "state_bucket_name" {
  description = "Bucket used by all environment stack state backends."
  value       = google_storage_bucket.state.name
}

