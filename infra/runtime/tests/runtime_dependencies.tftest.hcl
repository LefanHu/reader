mock_provider "google" {}

# Core deliberately exports no feature values: misplaced remote-state references
# must fail even when the old foundation state once contained those outputs.
override_data {
  target = data.terraform_remote_state.foundation
  values = {
    outputs = { notification_channel = "projects/reader-test/notificationChannels/123" }
  }
}

override_data {
  target = data.terraform_remote_state.illustrations
  values = {
    outputs = {
      illustrations_bucket   = "reader-test-illustrations"
      api_service_account    = "api@reader-test.iam.gserviceaccount.com"
      worker_service_account = "worker@reader-test.iam.gserviceaccount.com"
      task_service_account   = "tasks@reader-test.iam.gserviceaccount.com"
      narration_task_queue   = "reader-narration"
      task_queue             = "reader-illustrations"
      openai_secret_id       = "reader-openai-api-key"
      fingerprint_secret_id  = "reader-fingerprint-secret"
    }
  }
}

override_data {
  target = module.runtime.data.google_iam_policy.worker
  values = {
    policy_data = "{\"bindings\":[{\"role\":\"roles/run.invoker\",\"members\":[\"serviceAccount:tasks@reader-test.iam.gserviceaccount.com\"]}]}"
  }
}

variables {
  environment          = "test"
  project_id           = "reader-test"
  project_name         = "Reader Test"
  billing_account      = "000000-000000-000000"
  runtime_region       = "us-east1"
  firestore_location   = "nam5"
  state_bucket         = "reader-test-tfstate"
  illustrations_bucket = "reader-test-illustrations"
  apple_bundle_id      = "com.example.reader"
  apple_team_id        = "ABCDEFGHIJ"
  budget_amount_usd    = 25
  alert_email          = "reader@example.com"
  image                = "us-east1-docker.pkg.dev/reader-test/reader-backend/backend@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}

run "runtime_reads_feature_outputs_only_from_illustrations_state" {
  command = plan

  assert {
    condition     = output.image == var.image
    error_message = "Both services must continue using the requested immutable image."
  }
}
