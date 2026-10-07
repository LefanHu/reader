mock_provider "google" {}
mock_provider "google" { alias = "quota" }
mock_provider "google-beta" {}
mock_provider "google-beta" { alias = "quota" }
mock_provider "time" {}

variables {
  environment          = "test"
  project_id           = "reader-test-12345"
  project_name         = "Reader Test"
  billing_account      = "000000-000000-000000"
  firestore_location   = "nam5"
  apple_bundle_id      = "com.example.reader"
  apple_team_id        = "ABCDEFGHIJ"
  google_client_id     = "test.apps.googleusercontent.com"
  google_client_secret = "test-secret-only"
  budget_amount_usd    = 25
  alert_email          = "reader@example.com"
  firestore_rules      = "rules_version = '2'; service cloud.firestore { match /databases/{database}/documents { match /{document=**} { allow read, write: if false; } } }"
}

run "core_protects_shared_project_and_database" {
  command = plan
  assert {
    condition     = length(google_project_service.required) == 13 && !contains(keys(google_project_service.required), "run.googleapis.com") && !contains(keys(google_project_service.required), "secretmanager.googleapis.com")
    error_message = "Core must enable only shared APIs and require no illustration runtime or secrets."
  }
  assert {
    condition     = google_identity_platform_default_supported_idp_config.google.idp_id == "google.com" && google_identity_platform_default_supported_idp_config.google.enabled && length(google_identity_platform_default_supported_idp_config.apple) == 0
    error_message = "Google must be the only configured sign-in provider after retirement."
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

run "apple_retirement_disables_before_removal" {
  command = plan
  variables {
    retain_legacy_apple_provider = true
    apple_client_id              = "legacy.example.auth"
    apple_client_secret          = "legacy-test-only"
  }
  assert {
    condition     = !google_identity_platform_default_supported_idp_config.apple[0].enabled && google_identity_platform_default_supported_idp_config.apple[0].deletion_policy == "DELETE"
    error_message = "Persist disabled Apple and relaxed deletion protection before removing its provider configuration."
  }
}

run "budget_matches_non_usd_billing_account" {
  command = plan
  variables {
    budget_currency = "CAD"
  }
  assert {
    condition     = google_billing_budget.monthly.amount[0].specified_amount[0].currency_code == "CAD" && google_billing_budget.monthly.amount[0].specified_amount[0].units == "25"
    error_message = "Budget must use the linked billing account currency rather than hardcoded USD."
  }
}
