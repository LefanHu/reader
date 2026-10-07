variable "environment" {
  description = "Short environment name."
  type        = string
}

variable "project_id" {
  description = "Google Cloud project hosting the backend."
  type        = string
}

variable "region" {
  description = "Region shared by Cloud Run and Cloud Tasks."
  type        = string
}

variable "image" {
  description = "Immutable image digest deployed to both Cloud Run services."
  type        = string
}

variable "illustrations_bucket" {
  description = "Private bucket containing generated assets."
  type        = string
}

variable "api_service_account" {
  description = "Runtime identity for the public API."
  type        = string
}

variable "worker_service_account" {
  description = "Runtime identity for the private worker."
  type        = string
}

variable "task_service_account" {
  description = "OIDC identity used by Cloud Tasks to invoke the worker."
  type        = string
}

variable "task_queue" {
  description = "Cloud Tasks queue name."
  type        = string
}

variable "openai_secret_id" {
  description = "Secret Manager container holding the OpenAI API key."
  type        = string
}

variable "fingerprint_secret_id" {
  description = "Secret Manager container holding the stable fingerprint key."
  type        = string
}

variable "notification_channel" {
  description = "Monitoring notification channel for runtime alerts."
  type        = string
}

variable "illustrations_enabled" {
  description = "Server-side feature rollout flag."
  type        = bool
}

variable "pilot_credits" {
  description = "Credits assigned to a new illustration user."
  type        = number
}

variable "openai_scene_model" {
  description = "OpenAI narrative analysis model."
  type        = string
}

variable "openai_image_orchestrator_model" {
  description = "OpenAI image prompt orchestration model."
  type        = string
}

variable "openai_image_model" {
  description = "OpenAI image generation model."
  type        = string
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

variable "narration_task_queue" {
  description = "Dedicated queue owned by the narration feature module."
  type        = string
}
