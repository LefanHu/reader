provider "google" {
  project = var.project_id
}

data "terraform_remote_state" "foundation" {
  backend = "gcs"
  config = {
    bucket = var.state_bucket
    prefix = "reader/${var.environment}/foundation"
  }
}

# Feature outputs have one owner, separate from shared project/auth/data outputs.
data "terraform_remote_state" "illustrations" {
  backend = "gcs"
  config  = { bucket = var.state_bucket, prefix = "reader/${var.environment}/illustrations" }
}

module "runtime" {
  source                       = "../modules/runtime"
  narration_enabled            = var.narration_enabled
  narration_monthly_characters = var.narration_monthly_characters
  narration_daily_characters   = var.narration_daily_characters
  narration_task_queue         = data.terraform_remote_state.illustrations.outputs.narration_task_queue

  project_id                      = var.project_id
  region                          = var.runtime_region
  environment                     = var.environment
  image                           = var.image
  illustrations_enabled           = var.illustrations_enabled
  pilot_credits                   = var.pilot_credits
  openai_scene_model              = var.openai_scene_model
  openai_image_model              = var.openai_image_model
  openai_image_orchestrator_model = var.openai_image_orchestrator_model

  illustrations_bucket   = data.terraform_remote_state.illustrations.outputs.illustrations_bucket
  api_service_account    = data.terraform_remote_state.illustrations.outputs.api_service_account
  worker_service_account = data.terraform_remote_state.illustrations.outputs.worker_service_account
  task_service_account   = data.terraform_remote_state.illustrations.outputs.task_service_account
  task_queue             = data.terraform_remote_state.illustrations.outputs.task_queue
  openai_secret_id       = data.terraform_remote_state.illustrations.outputs.openai_secret_id
  fingerprint_secret_id  = data.terraform_remote_state.illustrations.outputs.fingerprint_secret_id
  notification_channel   = data.terraform_remote_state.foundation.outputs.notification_channel
}
