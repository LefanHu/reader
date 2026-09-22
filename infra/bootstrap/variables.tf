variable "state_project_id" {
  description = "Dedicated project that owns Terraform state."
  type        = string
}

variable "state_bucket_name" {
  description = "Globally unique GCS bucket containing Terraform state."
  type        = string
}

variable "billing_account" {
  description = "Billing account attached to the state project."
  type        = string
}

variable "state_location" {
  description = "Location for the Terraform state bucket."
  type        = string
  default     = "US-EAST1"
}

