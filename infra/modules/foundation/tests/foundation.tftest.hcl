mock_provider "google" {}
mock_provider "google-beta" {}
mock_provider "random" {}
mock_provider "time" {}

variables {
  environment          = "test"
  project_id           = "reader-test-12345"
  project_name         = "Reader Test"
  billing_account      = "000000-000000-000000"
  firestore_location   = "nam5"
  runtime_region       = "us-east1"
  apple_bundle_id      = "com.example.reader"
  apple_team_id        = "ABCDEFGHIJ"
  apple_client_id      = "com.example.reader.auth"
  apple_client_secret  = "test-secret-only"
  illustrations_bucket = "reader-test-12345-illustrations"
  budget_amount_usd    = 25
  alert_email          = "reader@example.com"
  firestore_rules      = "rules_version = '2'; service cloud.firestore { match /databases/{database}/documents { match /{document=**} { allow read, write: if false; } } }"
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

run "foundation_protects_data_and_matches_capacity_limits" {
  command = plan

  assert {
    condition     = google_project.environment.deletion_policy == "PREVENT"
    error_message = "The environment project must reject accidental deletion."
  }

  assert {
    condition     = google_firestore_database.default.delete_protection_state == "DELETE_PROTECTION_ENABLED" && google_firestore_database.default.deletion_policy == "PREVENT"
    error_message = "Firestore must have API and Terraform deletion protection."
  }

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
