provider "google" {
  project = var.project_id
}

provider "google-beta" {
  project = var.project_id
}

provider "random" {}
provider "time" {}

module "foundation" {
  source = "../modules/foundation"

  providers = {
    google      = google
    google-beta = google-beta
    random      = random
    time        = time
  }

  environment            = var.environment
  project_id             = var.project_id
  project_name           = var.project_name
  billing_account        = var.billing_account
  firestore_location     = var.firestore_location
  runtime_region         = var.runtime_region
  apple_bundle_id        = var.apple_bundle_id
  apple_team_id          = var.apple_team_id
  apple_client_id        = var.apple_client_id
  apple_client_secret    = var.apple_client_secret
  illustrations_bucket   = var.illustrations_bucket
  budget_amount_usd      = var.budget_amount_usd
  alert_email            = var.alert_email
  firestore_indexes_json = file("${path.root}/../../backend/firestore.indexes.json")
  firestore_rules        = file("${path.root}/../../backend/firestore.rules")
  storage_rules          = file("${path.root}/../../backend/storage.rules")
}
