mock_provider "google" {}
mock_provider "google-beta" {}
mock_provider "time" {}

variables {
  environment         = "test"
  project_id          = "reader-test-12345"
  project_name        = "Reader Test"
  billing_account     = "000000-000000-000000"
  firestore_location  = "nam5"
  apple_bundle_id     = "com.example.reader"
  apple_team_id       = "ABCDEFGHIJ"
  apple_client_id     = "com.example.reader.auth"
  apple_client_secret = "test-secret-only"
  budget_amount_usd   = 25
  alert_email         = "reader@example.com"
  firestore_rules     = "rules_version = '2'; service cloud.firestore { match /databases/{database}/documents { match /{document=**} { allow read, write: if false; } } }"
}

run "core_protects_shared_project_and_database" {
  command = plan
  assert {
    condition     = length(google_project_service.required) == 13 && !contains(keys(google_project_service.required), "run.googleapis.com") && !contains(keys(google_project_service.required), "secretmanager.googleapis.com")
    error_message = "Core must enable only shared APIs and require no illustration runtime or secrets."
  }
  assert {
    condition     = google_identity_platform_default_supported_idp_config.apple.idp_id == "apple.com" && google_identity_platform_default_supported_idp_config.apple.enabled
    error_message = "The deployment reorganization must preserve the existing Apple provider."
  }
  assert {
    condition     = google_project.environment.deletion_policy == "PREVENT"
    error_message = "The environment project must reject accidental deletion."
  }
  assert {
    condition     = google_firestore_database.default.delete_protection_state == "DELETE_PROTECTION_ENABLED" && google_firestore_database.default.deletion_policy == "PREVENT"
    error_message = "Firestore must have API and Terraform deletion protection."
  }
}
