provider "google" { project = var.project_id }
provider "google-beta" { project = var.project_id }

# User ADC requires an explicit consumer project for client-based APIs such as
# Firebase Rules; resource creation stays on the default providers.
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
provider "random" {}

# Reading core state establishes the dependency without duplicating its resources.
data "terraform_remote_state" "foundation" {
  backend = "gcs"
  config  = { bucket = var.state_bucket, prefix = "reader/${var.environment}/foundation" }
}
module "illustrations" {
  source = "../modules/illustrations"
  providers = {
    google            = google
    google-beta       = google-beta
    google.quota      = google.quota
    google-beta.quota = google-beta.quota
    random            = random
  }
  project_id             = data.terraform_remote_state.foundation.outputs.project_id
  environment            = var.environment
  runtime_region         = var.runtime_region
  illustrations_bucket   = var.illustrations_bucket
  firestore_indexes_json = file("${path.root}/../../backend/firestore.indexes.json")
  storage_rules          = file("${path.root}/../../backend/storage.rules")
}

# Narration shares the feature stack and core|illustrations|all lifecycle, even
# while either rollout flag is disabled. Existing resource addresses stay intact.
module "narration" {
  source     = "../modules/narration"
  project_id = data.terraform_remote_state.foundation.outputs.project_id
  region     = var.runtime_region
  depends_on = [module.illustrations]
}
