mock_provider "google" {}

override_data {
  target = data.google_iam_policy.worker
  values = {
    policy_data = "{\"bindings\":[{\"role\":\"roles/run.invoker\",\"members\":[\"serviceAccount:reader-test-tasks@reader-test-12345.iam.gserviceaccount.com\"]}]}"
  }
}

override_data {
  target = data.google_iam_policy.image_test_provider
  values = {
    policy_data = "{\"bindings\":[{\"role\":\"roles/run.invoker\",\"members\":[\"serviceAccount:reader-test-worker@reader-test-12345.iam.gserviceaccount.com\"]}]}"
  }
}

variables {
  narration_task_queue            = "reader-narration"
  environment                     = "test"
  project_id                      = "reader-test-12345"
  region                          = "us-east1"
  image                           = "us-east1-docker.pkg.dev/reader-test-12345/reader-backend/backend@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  illustrations_bucket            = "reader-test-12345-illustrations"
  api_service_account             = "reader-test-api@reader-test-12345.iam.gserviceaccount.com"
  worker_service_account          = "reader-test-worker@reader-test-12345.iam.gserviceaccount.com"
  task_service_account            = "reader-test-tasks@reader-test-12345.iam.gserviceaccount.com"
  task_queue                      = "reader-illustrations"
  book_analysis_task_queue        = "reader-book-analysis"
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
    condition     = google_cloud_run_v2_service.api.template[0].containers[0].resources[0].cpu_idle && google_cloud_run_v2_service.worker.template[0].containers[0].resources[0].cpu_idle && google_cloud_run_v2_service.api.template[0].scaling[0].min_instance_count == 0 && google_cloud_run_v2_service.worker.template[0].scaling[0].min_instance_count == 0
    error_message = "Both services must use request-based billing and allow scale to zero."
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
      for required in ["GOOGLE_CLOUD_PROJECT", "ILLUSTRATION_BUCKET", "TASK_LOCATION", "TASK_QUEUE", "BOOK_ANALYSIS_TASK_QUEUE", "TASK_SERVICE_ACCOUNT", "WORKER_URL", "PILOT_CREDITS", "ILLUSTRATIONS_ENABLED", "SERVICE_ROLE", "OPENAI_SCENE_MODEL", "OPENAI_IMAGE_ORCHESTRATOR_MODEL", "OPENAI_IMAGE_MODEL"] :
      contains([for env in google_cloud_run_v2_service.api.template[0].containers[0].env : env.name], required)
    ])
    error_message = "The API service is missing a required declarative environment variable."
  }

  assert {
    condition     = toset(keys(google_monitoring_alert_policy.runtime)) == toset(["api_5xx", "worker_5xx", "api_latency", "queue_depth"]) && alltrue([for policy in google_monitoring_alert_policy.runtime : length(policy.notification_channels) == 1 && contains(policy.notification_channels, var.notification_channel)])
    error_message = "All four runtime alerts must exist and notify the shared operations channel."
  }

  assert {
    condition     = google_monitoring_alert_policy.runtime["api_latency"].conditions[0].condition_threshold[0].aggregations[0].cross_series_reducer == null && google_monitoring_alert_policy.runtime["api_5xx"].conditions[0].condition_threshold[0].aggregations[0].cross_series_reducer == "REDUCE_SUM" && google_monitoring_alert_policy.runtime["queue_depth"].conditions[0].condition_threshold[0].threshold_value == 20
    error_message = "Alert thresholds and aggregation must keep their existing shapes."
  }
}

run "runtime_exposes_only_provisioned_image_sources_to_the_worker" {
  command = plan

  variables {
    google_image_generation_enabled = true
    image_provider_secret_ids       = { flux = "reader-bfl-api-key", xai = "reader-xai-api-key" }
  }

  assert {
    condition     = [for env in google_cloud_run_v2_service.api.template[0].containers[0].env : env.value if env.name == "IMAGE_PROVIDERS"][0] == "openai,google,flux,xai"
    error_message = "Availability must list OpenAI, enabled Google and only provisioned direct providers."
  }

  assert {
    condition = one([
      for env in google_cloud_run_v2_service.worker.template[0].containers[0].env : env.value_source[0].secret_key_ref[0].secret
      if env.name == "BFL_API_KEY"
    ]) == "reader-bfl-api-key" && length([for env in google_cloud_run_v2_service.worker.template[0].containers[0].env : env.name if env.name == "QWEN_API_KEY" || env.name == "BYTEPLUS_API_KEY"]) == 0
    error_message = "The worker must reference only provisioned keys."
  }

  assert {
    condition     = length([for env in google_cloud_run_v2_service.api.template[0].containers[0].env : env.name if contains(["BFL_API_KEY", "XAI_API_KEY", "QWEN_API_KEY", "BYTEPLUS_API_KEY"], env.name)]) == 0
    error_message = "The API must never receive direct provider keys."
  }
}

run "runtime_defaults_advertise_only_openai" {
  command = plan

  assert {
    condition     = [for env in google_cloud_run_v2_service.worker.template[0].containers[0].env : env.value if env.name == "IMAGE_PROVIDERS"][0] == "openai"
    error_message = "Without provisioning only OpenAI is advertised."
  }

  assert {
    condition     = length(google_cloud_run_v2_service.image_test_provider) == 0 && length(google_cloud_run_v2_service_iam_policy.image_test_provider) == 0
    error_message = "The pipeline-test service must not exist unless enabled."
  }
}

run "runtime_pipeline_test_provider_is_dev_only_and_worker_invoked" {
  command = plan

  variables {
    environment                 = "dev"
    image_test_provider_enabled = true
  }

  assert {
    condition     = length(google_cloud_run_v2_service.image_test_provider) == 1 && google_cloud_run_v2_service.image_test_provider[0].template[0].containers[0].command == tolist(["node", "dist/image-test-provider-server.js"])
    error_message = "The test service must run the dedicated server entry point."
  }

  assert {
    condition     = one(data.google_iam_policy.image_test_provider[0].binding).members == toset(["serviceAccount:${var.worker_service_account}"]) && one(data.google_iam_policy.image_test_provider[0].binding).role == "roles/run.invoker"
    error_message = "Only the worker identity may invoke the test service."
  }

  assert {
    condition     = endswith([for env in google_cloud_run_v2_service.worker.template[0].containers[0].env : env.value if env.name == "IMAGE_PROVIDERS"][0], ",diagnostic")
    error_message = "The diagnostic source must be advertised when the service exists."
  }

  assert {
    condition     = length([for env in google_cloud_run_v2_service.worker.template[0].containers[0].env : env.name if env.name == "IMAGE_TEST_PROVIDER_URL"]) == 1 && length([for env in google_cloud_run_v2_service.api.template[0].containers[0].env : env.name if env.name == "IMAGE_TEST_PROVIDER_URL"]) == 0
    error_message = "Only the worker receives the test service URL."
  }
}

run "runtime_rejects_pipeline_test_provider_outside_dev" {
  command = plan

  variables {
    environment                 = "prod"
    image_test_provider_enabled = true
  }

  expect_failures = [google_cloud_run_v2_service.image_test_provider]
}

run "runtime_rejects_provider_without_worker_key_variable" {
  command = plan

  variables {
    image_provider_secret_ids = { unknown = "reader-unknown-api-key" }
  }

  expect_failures = [var.image_provider_secret_ids]
}
