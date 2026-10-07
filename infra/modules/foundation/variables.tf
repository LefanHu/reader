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

variable "apple_bundle_id" {
  description = "Canonical bundle ID for the Firebase Apple application."
  type        = string
}

variable "apple_team_id" {
  description = "Apple Developer Team ID used by App Attest."
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

# Used only by the staged removal of an existing protected Apple provider.
variable "retain_legacy_apple_provider" {
  description = "Temporarily retain a disabled Apple provider to persist relaxed deletion protection."
  type        = bool
  default     = false
}
variable "apple_client_id" {
  description = "Existing Apple credentials recovered privately from state during retirement."
  type        = string
  sensitive   = true
  default     = null
}
variable "apple_client_secret" {
  description = "Existing Apple secret needed only for the provider retirement transition."
  type        = string
  sensitive   = true
  default     = null
}

variable "budget_amount_usd" {
  description = "Monthly budget in budget_currency; legacy variable name retained for environment compatibility."
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
  description = "Recipient of budget and operational alerts."
  type        = string
}

variable "firestore_rules" {
  description = "Complete deny-all Firestore rules source."
  type        = string
}

variable "apple_macos_bundle_id" {
  description = "Separate macOS Firebase app in the same environment project and Auth service."
  type        = string
  default     = "com.leafmealone.reader.macos"
}
