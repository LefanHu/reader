variable "environment" {
  description = "Short environment name used in labels and resource names."
  type        = string
}

variable "project_id" {
  description = "Google Cloud project hosting the backend."
  type        = string
}

variable "runtime_region" {
  description = "Region for both Cloud Run services and Cloud Tasks."
  type        = string
}

variable "state_bucket" {
  description = "GCS bucket containing the foundation remote state."
  type        = string
}

variable "image" {
  description = "Immutable Artifact Registry image reference including a sha256 digest."
  type        = string

  validation {
    condition     = can(regex("@sha256:[0-9a-f]{64}$", var.image))
    error_message = "image must be an immutable Artifact Registry digest ending in @sha256:<64 hex characters>."
  }
}

variable "illustrations_enabled" {
  description = "Server-side rollout flag; keep false until authenticated smoke testing succeeds."
  type        = bool
  default     = false
}

variable "pilot_credits" {
  description = "Initial illustration credits assigned to a new user."
  type        = number
  default     = 100
}

variable "openai_scene_model" {
  description = "OpenAI model used for narrative scene analysis."
  type        = string
  default     = "gpt-5.6-luna"
}

variable "openai_image_orchestrator_model" {
  description = "OpenAI model used to orchestrate image prompt generation."
  type        = string
  default     = "gpt-5.5"
}

variable "openai_image_model" {
  description = "OpenAI image generation model."
  type        = string
  default     = "gpt-image-2.5-flare"
}

# The remaining declarations are foundation-only values intentionally accepted
# here so a single environment tfvars file can configure both stacks.
variable "project_name" {
  description = "Human-readable project name consumed by the foundation stack."
  type        = string
}

variable "billing_account" {
  description = "Billing account consumed by the foundation stack."
  type        = string
}

variable "firestore_location" {
  description = "Firestore location consumed by the foundation stack."
  type        = string
}

variable "apple_bundle_id" {
  description = "Apple bundle ID consumed by the foundation stack."
  type        = string
}

variable "apple_team_id" {
  description = "Apple team ID consumed by the foundation stack."
  type        = string
}

variable "illustrations_bucket" {
  description = "Bucket name consumed by the foundation stack and read here from remote state."
  type        = string
}

variable "budget_amount_usd" {
  description = "Budget amount consumed by the foundation stack."
  type        = number
}

variable "alert_email" {
  description = "Alert recipient consumed by the foundation stack."
  type        = string
}

variable "enable_existing_imports" {
  description = "Migration switch consumed by the foundation stack."
  type        = bool
  default     = false
}
