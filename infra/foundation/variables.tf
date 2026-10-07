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

variable "runtime_region" {
  description = "Region for Cloud Run, Artifact Registry, and Cloud Tasks."
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

variable "apple_client_id" {
  description = "Sign in with Apple Services ID configured in Firebase Authentication."
  type        = string
  sensitive   = true
}

variable "apple_client_secret" {
  description = "Rotating Sign in with Apple OAuth client secret; retained only in protected state."
  type        = string
  sensitive   = true
}

variable "illustrations_bucket" {
  description = "Globally unique private bucket for generated illustration assets."
  type        = string
}

variable "budget_amount_usd" {
  description = "Monthly Google Cloud budget in USD."
  type        = number
}

variable "alert_email" {
  description = "Email address receiving budget and operational alerts."
  type        = string
}

variable "enable_existing_imports" {
  description = "Imports the pre-Terraform development project resources during initial adoption."
  type        = bool
  default     = false
}

variable "state_bucket" {
  description = "Shared environment setting consumed by the runtime stack; accepted for the shared environment tfvars file."
  type        = string
}

variable "illustrations_enabled" {
  description = "Runtime rollout flag; accepted for the shared environment tfvars file."
  type        = bool
  default     = false
}

variable "apple_macos_bundle_id" {
  description = "Separate macOS Firebase app in the same environment project and Auth service."
  type        = string
  default     = "com.leafmealone.reader.macos"
}

variable "narration_enabled" {
  description = "Independent narration rollout; remains off until signed-device and listening checks pass."
  type        = bool
  default     = false
}
variable "narration_monthly_characters" {
  description = "Per-user UTC-month UTF-16 input allowance, including provider retries."
  type        = number
  default     = 500000
  validation {
    condition     = var.narration_monthly_characters >= 0 && floor(var.narration_monthly_characters) == var.narration_monthly_characters
    error_message = "Narration allowance must be a nonnegative integer."
  }
}
variable "narration_daily_characters" {
  description = "Environment-wide daily UTF-16 input cap."
  type        = number
  default     = 200000
  validation {
    condition     = var.narration_daily_characters >= 0 && floor(var.narration_daily_characters) == var.narration_daily_characters
    error_message = "Narration allowance must be a nonnegative integer."
  }
}
