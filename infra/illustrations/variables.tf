# Declare only what this stack uses. tool/stack_tfvars.py passes each stack just
# the shared environment tfvars values it declares and rejects values that no
# environment stack declares.
variable "environment" {
  description = "Short environment name used in labels and resource names."
  type        = string
}

variable "project_id" {
  description = "Globally unique Firebase and Google Cloud project ID."
  type        = string
}

variable "runtime_region" {
  description = "Region for Cloud Run, Artifact Registry, and Cloud Tasks."
  type        = string
}

variable "illustrations_bucket" {
  description = "Globally unique private bucket for generated illustration assets."
  type        = string
}

variable "state_bucket" {
  description = "GCS bucket containing core and illustration remote state."
  type        = string
}
