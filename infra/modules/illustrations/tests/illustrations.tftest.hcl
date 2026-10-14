mock_provider "google" {}
mock_provider "google" { alias = "quota" }
mock_provider "google-beta" {}
mock_provider "google-beta" { alias = "quota" }
mock_provider "random" {}

variables {
  environment          = "test"
  project_id           = "reader-test-12345"
  runtime_region       = "us-east1"
  illustrations_bucket = "reader-test-12345-illustrations"
  storage_rules        = "rules_version = '2'; service firebase.storage { match /b/{bucket}/o { match /{object=**} { allow read, write: if false; } } }"
  firestore_indexes_json = jsonencode({
    indexes = [
      for collection in ["illustrationJobs", "illustrationScenes", "creditReservations"] : {
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
    condition     = length(google_firestore_index.composite) == 3
    error_message = "All three composite indexes must come from the shared Firebase index specification."
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
    condition     = google_cloud_tasks_queue.illustrations.rate_limits[0].max_concurrent_dispatches == 3 && google_cloud_tasks_queue.illustrations.rate_limits[0].max_dispatches_per_second == 2 && google_cloud_tasks_queue.illustrations.retry_config[0].max_attempts == 10 && google_cloud_tasks_queue.illustrations.retry_config[0].min_backoff == "60s"
    error_message = "The task queue must retain its cost and retry limits."
  }
  assert {
    condition     = google_cloud_tasks_queue.book_analysis.name == "reader-book-analysis" && google_cloud_tasks_queue.book_analysis.rate_limits[0].max_concurrent_dispatches == 3 && google_cloud_tasks_queue.book_analysis.retry_config[0].max_attempts == 10 && google_cloud_tasks_queue.book_analysis.retry_config[0].min_backoff == "60s"
    error_message = "Book preprocessing must use its own bounded queue with lease-spanning retries."
  }
  assert {
    condition     = alltrue([for secret in google_secret_manager_secret.container : secret.deletion_protection && secret.deletion_policy == "PREVENT"]) && google_secret_manager_secret.container["openai"].secret_id == "reader-openai-api-key" && google_secret_manager_secret.container["fingerprint"].secret_id == "reader-fingerprint-secret"
    error_message = "Secret containers must keep their names and reject accidental deletion."
  }
  assert {
    condition     = strcontains(google_storage_bucket_iam_member.api_objects.condition[0].expression, "/objects/users/") && strcontains(google_storage_bucket_iam_member.api_objects.condition[0].expression, "/objects/works/") && !strcontains(google_storage_bucket_iam_member.worker_objects.condition[0].expression, "/objects/works/")
    error_message = "The API manages per-user objects and the shared catalog works; the worker only per-user objects."
  }
  assert {
    condition     = google_project_iam_member.build_source.role == "roles/storage.objectViewer" && google_project_iam_member.build_source.condition[0].expression == "resource.type == 'storage.googleapis.com/Object' && resource.name.startsWith('projects/_/buckets/reader-test-12345_cloudbuild/objects/source/')"
    error_message = "The custom builder may read only source archives, not reader assets or unrelated storage."
  }
  assert {
    condition     = toset(keys(google_secret_manager_secret.container)) == toset(["openai", "fingerprint", "seedream", "qwen", "xai", "flux"]) && google_secret_manager_secret.container["seedream"].secret_id == "reader-byteplus-api-key" && google_secret_manager_secret.container["qwen"].secret_id == "reader-qwen-api-key" && google_secret_manager_secret.container["xai"].secret_id == "reader-xai-api-key" && google_secret_manager_secret.container["flux"].secret_id == "reader-bfl-api-key"
    error_message = "Each direct provider needs exactly its named secret container."
  }
  assert {
    condition     = toset(keys(google_secret_manager_secret_iam_member.worker)) == toset(["openai", "seedream", "qwen", "xai", "flux"]) && alltrue([for grant in google_secret_manager_secret_iam_member.worker : grant.role == "roles/secretmanager.secretAccessor"]) && google_secret_manager_secret_iam_member.api_fingerprint.secret_id == "reader-fingerprint-secret"
    error_message = "The worker reads OpenAI and the four provider keys but never the fingerprint; the API reads only the fingerprint."
  }
  assert {
    condition     = output.image_provider_secret_ids == { seedream = "reader-byteplus-api-key", qwen = "reader-qwen-api-key", xai = "reader-xai-api-key", flux = "reader-bfl-api-key" }
    error_message = "Deployment tooling reads provider containers only from this output, so it must list exactly the direct providers."
  }
  assert {
    condition     = google_project_iam_member.worker_vertex.role == "roles/aiplatform.user" && contains(local.required_services, "aiplatform.googleapis.com")
    error_message = "The worker receives Vertex AI use and the API must be enabled."
  }
}
