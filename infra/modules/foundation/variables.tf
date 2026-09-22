variable "environment" {
  description = "Short environment name."
  type        = string
}

variable "project_id" {
  description = "Globally unique environment project ID."
  type        = string
}

variable "project_name" {
  description = "Human-readable environment project name."
  type        = string
}

variable "billing_account" {
  description = "Billing account attached to the environment project."
  type        = string
}

variable "firestore_location" {
  description = "Immutable location of the default Firestore database."
  type        = string
}

variable "runtime_region" {
  description = "Region shared by Cloud Run, Artifact Registry, and Cloud Tasks."
  type        = string
}

variable "apple_bundle_id" {
  description = "Canonical bundle ID for the Firebase Apple application."
  type        = string
}

variable "apple_team_id" {
  description = "Apple Developer Team ID used by App Attest."
  type        = string
}

variable "apple_client_id" {
  description = "Sign in with Apple Services ID."
  type        = string
  sensitive   = true
}

variable "apple_client_secret" {
  description = "Rotating Sign in with Apple OAuth client secret."
  type        = string
  sensitive   = true
}

variable "illustrations_bucket" {
  description = "Private bucket for generated illustration assets."
  type        = string
}

variable "budget_amount_usd" {
  description = "Monthly budget amount in USD."
  type        = number
}

variable "alert_email" {
  description = "Recipient of budget and operational alerts."
  type        = string
}

variable "firestore_indexes_json" {
  description = "Contents of the Firebase CLI index specification."
  type        = string
}

variable "firestore_rules" {
  description = "Complete deny-all Firestore rules source."
  type        = string
}

variable "storage_rules" {
  description = "Complete deny-all Storage rules source."
  type        = string
}

