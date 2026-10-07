provider "google" { project = var.project_id }
provider "google-beta" { project = var.project_id }
provider "random" {}

# Reading core state establishes the dependency without duplicating its resources.
data "terraform_remote_state" "foundation" {
  backend = "gcs"
  config  = { bucket = var.state_bucket, prefix = "reader/${var.environment}/foundation" }
}
module "illustrations" {
  source                 = "../modules/illustrations"
  project_id             = data.terraform_remote_state.foundation.outputs.project_id
  environment            = var.environment
  runtime_region         = var.runtime_region
  illustrations_bucket   = var.illustrations_bucket
  firestore_indexes_json = file("${path.root}/../../backend/firestore.indexes.json")
  storage_rules          = file("${path.root}/../../backend/storage.rules")
}
