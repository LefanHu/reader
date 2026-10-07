provider "google" {
  project = var.project_id
}

provider "google-beta" {
  project = var.project_id
}

# User ADC requires an explicit consumer project for client-based APIs. Keep
# project/API creation on default providers so first-time projects can bootstrap.
provider "google" {
  alias                 = "quota"
  project               = var.project_id
  billing_project       = var.project_id
  user_project_override = true
}
provider "google-beta" {
  alias                 = "quota"
  project               = var.project_id
  billing_project       = var.project_id
  user_project_override = true
}

provider "time" {}

module "foundation" {
  source = "../modules/foundation"

  providers = {
    google            = google
    google-beta       = google-beta
    google.quota      = google.quota
    google-beta.quota = google-beta.quota
    time              = time
  }

  environment                  = var.environment
  project_id                   = var.project_id
  project_name                 = var.project_name
  billing_account              = var.billing_account
  firestore_location           = var.firestore_location
  apple_bundle_id              = var.apple_bundle_id
  apple_macos_bundle_id        = var.apple_macos_bundle_id
  apple_team_id                = var.apple_team_id
  google_client_id             = var.google_client_id
  google_client_secret         = var.google_client_secret
  retain_legacy_apple_provider = var.retain_legacy_apple_provider
  apple_client_id              = var.apple_client_id
  apple_client_secret          = var.apple_client_secret
  budget_currency              = var.budget_currency
  budget_amount_usd            = var.budget_amount_usd
  alert_email                  = var.alert_email
  firestore_rules              = file("${path.root}/../../backend/firestore.rules")
}
