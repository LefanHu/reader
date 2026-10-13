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

variable "project_name" {
  description = "Human-readable Google Cloud project name."
  type        = string
}

variable "billing_account" {
  description = "Billing account ID attached to the environment project."
  type        = string
}

variable "firestore_location" {
  description = "Immutable Firestore database location."
  type        = string
}

variable "apple_bundle_id" {
  description = "Canonical Apple bundle identifier registered with Firebase."
  type        = string
}

variable "apple_team_id" {
  description = "Apple Developer team identifier used by App Attest."
  type        = string
}

variable "google_client_id" {
  description = "Web OAuth client ID used by the Firebase Google provider."
  type        = string
  sensitive   = true
}

variable "google_client_secret" {
  description = "Private Google OAuth client secret; retained only in protected remote state."
  type        = string
  sensitive   = true
}

variable "budget_amount" {
  description = "Monthly budget in budget_currency."
  type        = number
}

variable "budget_currency" {
  description = "ISO 4217 currency matching the linked billing account; Google rejects a different currency."
  type        = string
  default     = "USD"
  validation {
    condition     = can(regex("^[A-Z]{3}$", var.budget_currency))
    error_message = "Budget currency must be an uppercase three-letter ISO currency code."
  }
}

variable "alert_email" {
  description = "Email address receiving budget and operational alerts."
  type        = string
}

variable "apple_macos_bundle_id" {
  description = "Separate macOS Firebase app in the same environment project and Auth service."
  type        = string
  default     = "com.leafmealone.reader.macos"
}

variable "api_test_principals" {
  description = "IAM members (user:/group:) allowed to mint dev-API test identities by signing as the Firebase Admin SDK service account. Dev only."
  type        = list(string)
  default     = []
}
