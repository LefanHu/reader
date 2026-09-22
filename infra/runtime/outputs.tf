output "api_url" {
  description = "Public URL used by the mobile client."
  value       = module.runtime.api_url
}

output "worker_url" {
  description = "Private worker URL targeted by Cloud Tasks."
  value       = module.runtime.worker_url
}

output "image" {
  description = "Immutable image digest deployed to both services."
  value       = var.image
}

