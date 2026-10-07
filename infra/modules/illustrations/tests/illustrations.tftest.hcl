mock_provider "google" {}
mock_provider "google-beta" {}
mock_provider "random" {}

variables {
  environment          = "test"
  project_id           = "reader-test-12345"
  runtime_region       = "us-east1"
  illustrations_bucket = "reader-test-12345-illustrations"
  storage_rules        = "rules_version = '2'; service firebase.storage { match /b/{bucket}/o { match /{object=**} { allow read, write: if false; } } }"
  firestore_indexes_json = jsonencode({
    indexes = [
      for collection in ["illustrationJobs", "illustrationScenes", "creditReservations", "worldRevisions", "worldReferences"] : {
        collectionGroup = collection
        queryScope      = "COLLECTION"
        fields = [
          { fieldPath = "uid", order = "ASCENDING" },
          { fieldPath = "bookId", order = "ASCENDING" },
        ]
      }
    ]
    fieldOverrides = [{
      collectionGroup = "illustrationJobInputs"
      fieldPath       = "expiresAt"
      ttl             = true
      indexes         = []
    }]
  })
}

run "illustrations_preserves_privacy_retention_and_capacity" {
  command = plan
  assert {
    condition     = length(google_firestore_index.composite) == 5
    error_message = "All five composite indexes must come from the shared Firebase index specification."
  }
  assert {
    condition     = google_firestore_field.ttl["illustrationJobInputs.expiresAt"].collection == "illustrationJobInputs"
    error_message = "The temporary chapter input collection must retain its TTL field override."
  }
  assert {
    condition     = google_storage_bucket.illustrations.public_access_prevention == "enforced" && google_storage_bucket.illustrations.uniform_bucket_level_access && google_storage_bucket.illustrations.deletion_policy == "PREVENT"
    error_message = "The illustration bucket must remain private and uniformly permissioned."
  }
  assert {
    condition     = google_storage_bucket.illustrations.soft_delete_policy[0].retention_duration_seconds == 0
    error_message = "Soft delete must be disabled so account deletion is a real purge."
  }
  assert {
    condition     = one(google_storage_bucket.illustrations.lifecycle_rule[0].condition).age == 30 && contains(one(google_storage_bucket.illustrations.lifecycle_rule[0].condition).matches_prefix, "users/")
    error_message = "Per-user objects must expire after thirty days."
  }
  assert {
    condition     = google_cloud_tasks_queue.illustrations.rate_limits[0].max_concurrent_dispatches == 3 && google_cloud_tasks_queue.illustrations.rate_limits[0].max_dispatches_per_second == 2 && google_cloud_tasks_queue.illustrations.retry_config[0].max_attempts == 5
    error_message = "The task queue must retain its cost and retry limits."
  }
  assert {
    condition     = google_secret_manager_secret.openai.deletion_protection && google_secret_manager_secret.openai.deletion_policy == "PREVENT" && google_secret_manager_secret.fingerprint.deletion_protection
    error_message = "Secret containers must reject accidental deletion."
  }
}
