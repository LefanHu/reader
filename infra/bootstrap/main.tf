provider "google" {
  project = var.state_project_id
}

resource "google_project" "state" {
  project_id          = var.state_project_id
  name                = "Reader Terraform State"
  billing_account     = var.billing_account
  auto_create_network = false
  deletion_policy     = "PREVENT"

  labels = {
    application = "reader"
    purpose     = "terraform-state"
    managed_by  = "terraform"
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_project_service" "storage" {
  project            = google_project.state.project_id
  service            = "storage.googleapis.com"
  disable_on_destroy = false
}

resource "google_storage_bucket" "state" {
  name                        = var.state_bucket_name
  project                     = google_project.state.project_id
  location                    = var.state_location
  force_destroy               = false
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  deletion_policy             = "PREVENT"

  versioning {
    enabled = true
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.storage]
}
