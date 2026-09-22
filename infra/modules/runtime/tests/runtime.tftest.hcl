mock_provider "google" {}

override_data {
  target = data.google_iam_policy.worker
  values = {
    policy_data = "{\"bindings\":[{\"role\":\"roles/run.invoker\",\"members\":[\"serviceAccount:reader-test-tasks@reader-test-12345.iam.gserviceaccount.com\"]}]}"
  }
}

variables {
  environment                     = "test"
  project_id                      = "reader-test-12345"
  region                          = "us-east1"
  image                           = "us-east1-docker.pkg.dev/reader-test-12345/reader-backend/backend@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  illustrations_bucket            = "reader-test-12345-illustrations"
  api_service_account             = "reader-test-api@reader-test-12345.iam.gserviceaccount.com"
  worker_service_account          = "reader-test-worker@reader-test-12345.iam.gserviceaccount.com"
  task_service_account            = "reader-test-tasks@reader-test-12345.iam.gserviceaccount.com"
  task_queue                      = "reader-illustrations"
  openai_secret_id                = "reader-openai-api-key"
  fingerprint_secret_id           = "reader-fingerprint-secret"
  notification_channel            = "projects/reader-test-12345/notificationChannels/123"
  illustrations_enabled           = false
  pilot_credits                   = 100
  openai_scene_model              = "scene-model"
  openai_image_orchestrator_model = "orchestrator-model"
  openai_image_model              = "image-model"
}

run "runtime_keeps_worker_private_and_injects_only_secret_references" {
  command = plan

  assert {
    condition     = google_cloud_run_v2_service_iam_member.public_api.member == "allUsers"
    error_message = "The API must be publicly invokable before application-level Auth and App Check."
  }

  assert {
    condition     = one(data.google_iam_policy.worker.binding).members == toset(["serviceAccount:${var.task_service_account}"])
    error_message = "Only the Cloud Tasks identity should receive worker invocation permission."
  }

  assert {
    condition     = google_cloud_run_v2_service.worker.template[0].max_instance_request_concurrency == 1 && google_cloud_run_v2_service.worker.template[0].scaling[0].max_instance_count == 3
    error_message = "The worker must serialize generation and cap scale at three instances."
  }

  assert {
    condition     = google_cloud_run_v2_service.api.template[0].scaling[0].max_instance_count == 10
    error_message = "The public API must retain its ten-instance ceiling."
  }

  assert {
    condition = one([
      for env in google_cloud_run_v2_service.worker.template[0].containers[0].env : env.value_source[0].secret_key_ref[0].secret
      if env.name == "OPENAI_API_KEY"
    ]) == var.openai_secret_id
    error_message = "The worker must reference the OpenAI Secret Manager secret."
  }

  assert {
    condition = one([
      for env in google_cloud_run_v2_service.api.template[0].containers[0].env : env.value_source[0].secret_key_ref[0].secret
      if env.name == "FINGERPRINT_SECRET"
    ]) == var.fingerprint_secret_id
    error_message = "The API must reference the fingerprint Secret Manager secret."
  }

  assert {
    condition = alltrue([
      for required in ["GOOGLE_CLOUD_PROJECT", "ILLUSTRATION_BUCKET", "TASK_LOCATION", "TASK_QUEUE", "TASK_SERVICE_ACCOUNT", "WORKER_URL", "PILOT_CREDITS", "ILLUSTRATIONS_ENABLED", "SERVICE_ROLE", "OPENAI_SCENE_MODEL", "OPENAI_IMAGE_ORCHESTRATOR_MODEL", "OPENAI_IMAGE_MODEL"] :
      contains([for env in google_cloud_run_v2_service.api.template[0].containers[0].env : env.name], required)
    ])
    error_message = "The API service is missing a required declarative environment variable."
  }
}
