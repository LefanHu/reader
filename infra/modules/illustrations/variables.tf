variable "environment" {
  description = "Short environment name."
  type        = string
}

variable "project_id" {
  description = "Globally unique environment project ID."
  type        = string
}

variable "runtime_region" {
  description = "Region shared by Cloud Run, Artifact Registry, and Cloud Tasks."
  type        = string
}

variable "illustrations_bucket" {
  description = "Private bucket for generated illustration assets."
  type        = string
}

variable "firestore_indexes_json" {
  description = "Contents of the Firebase CLI index specification."
  type        = string
}

variable "storage_rules" {
  description = "Complete deny-all Storage rules source."
  type        = string
}
