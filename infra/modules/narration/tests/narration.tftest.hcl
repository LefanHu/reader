mock_provider "google" {}
variables {
  project_id = "reader-test-12345"
  region     = "us-east1"
}
run "bounded_private_narration_resources" {
  command = plan
  assert {
    condition     = google_cloud_tasks_queue.narration.rate_limits[0].max_concurrent_dispatches == 2 && google_cloud_tasks_queue.narration.retry_config[0].max_attempts == 5
    error_message = "Narration must retain bounded dispatch and retries."
  }
  assert {
    condition     = google_firestore_field.input_ttl.collection == "narrationInputs" && google_firestore_field.input_ttl.field == "expiresAt"
    error_message = "Abandoned narration input must have a cleanup TTL."
  }
}
