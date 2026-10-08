locals {
  required_services = toset([
    "artifactregistry.googleapis.com",
    "cloudbuild.googleapis.com",
    "cloudtasks.googleapis.com",
    "firebasestorage.googleapis.com",
    "iamcredentials.googleapis.com",
    "run.googleapis.com",
    "secretmanager.googleapis.com",
    "storage.googleapis.com",
  ])
  index_spec = jsondecode(var.firestore_indexes_json)
  indexes    = { for index in local.index_spec.indexes : index.collectionGroup => index }
  ttl_fields = { for field in local.index_spec.fieldOverrides : "${field.collectionGroup}.${field.fieldPath}" => field if try(field.ttl, false) }
  labels     = { application = "reader", environment = var.environment, managed_by = "terraform" }
}

# Feature APIs are owned here; shared identity/data APIs stay in core.
resource "google_project_service" "required" {
  for_each           = local.required_services
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# The shared database must already exist in core. Only illustration query and
# temporary-prose retention policies belong to this independently applied stack.
resource "google_firestore_index" "composite" {
  for_each = local.indexes

  project     = var.project_id
  database    = "(default)"
  collection  = each.value.collectionGroup
  query_scope = each.value.queryScope

  dynamic "fields" {
    for_each = each.value.fields
    content {
      field_path   = fields.value.fieldPath
      order        = try(fields.value.order, null)
      array_config = try(fields.value.arrayConfig, null)
    }
  }

  deletion_policy = "PREVENT"
}

resource "google_firestore_field" "ttl" {
  for_each = local.ttl_fields

  project    = var.project_id
  database   = "(default)"
  collection = each.value.collectionGroup
  field      = each.value.fieldPath

  ttl_config {}
  index_config {}
}

resource "google_storage_bucket" "illustrations" {
  project                     = var.project_id
  name                        = var.illustrations_bucket
  location                    = upper(var.runtime_region)
  force_destroy               = false
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  deletion_policy             = "PREVENT"
  labels                      = local.labels

  versioning {
    enabled = false
  }

  soft_delete_policy {
    retention_duration_seconds = 0
  }

  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      age            = 30
      matches_prefix = ["users/"]
      with_state     = "LIVE"
    }
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.required]
}

resource "google_firebase_storage_bucket" "illustrations" {
  provider  = google-beta
  project   = var.project_id
  bucket_id = google_storage_bucket.illustrations.name

  depends_on = [google_project_service.required]
}

resource "google_firebaserules_ruleset" "storage" {
  project = var.project_id

  source {
    files {
      name    = "storage.rules"
      content = var.storage_rules
    }
  }

  depends_on = [google_project_service.required]
}

resource "google_firebaserules_release" "storage" {
  provider = google-beta

  project      = var.project_id
  name         = "firebase.storage/${google_storage_bucket.illustrations.name}"
  ruleset_name = google_firebaserules_ruleset.storage.name

  lifecycle {
    replace_triggered_by = [google_firebaserules_ruleset.storage]
  }

  depends_on = [google_firebase_storage_bucket.illustrations]
}

resource "google_service_account" "api" {
  project      = var.project_id
  account_id   = "reader-${var.environment}-api"
  display_name = "Reader ${var.environment} illustration API"
}

resource "google_service_account" "worker" {
  project      = var.project_id
  account_id   = "reader-${var.environment}-worker"
  display_name = "Reader ${var.environment} illustration worker"
}

resource "google_service_account" "task" {
  project      = var.project_id
  account_id   = "reader-${var.environment}-tasks"
  display_name = "Reader ${var.environment} Cloud Tasks identity"
}

resource "google_service_account" "build" {
  project      = var.project_id
  account_id   = "reader-${var.environment}-build"
  display_name = "Reader ${var.environment} backend builder"
}

resource "google_project_iam_member" "api_firestore" {
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.api.email}"
}

resource "google_project_iam_member" "worker_firestore" {
  project = var.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.worker.email}"
}

resource "google_project_iam_member" "api_tasks" {
  project = var.project_id
  role    = "roles/cloudtasks.enqueuer"
  member  = "serviceAccount:${google_service_account.api.email}"
}

resource "google_storage_bucket_iam_member" "api_objects" {
  bucket = google_storage_bucket.illustrations.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.api.email}"

  condition {
    title       = "ReaderUserObjectsOnly"
    description = "The API may manage only per-user illustration objects."
    expression  = "resource.type != 'storage.googleapis.com/Object' || resource.name.startsWith('projects/_/buckets/${google_storage_bucket.illustrations.name}/objects/users/')"
  }
}

resource "google_storage_bucket_iam_member" "worker_objects" {
  bucket = google_storage_bucket.illustrations.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.worker.email}"

  condition {
    title       = "ReaderUserObjectsOnly"
    description = "The worker may manage only per-user illustration objects."
    expression  = "resource.type != 'storage.googleapis.com/Object' || resource.name.startsWith('projects/_/buckets/${google_storage_bucket.illustrations.name}/objects/users/')"
  }
}

resource "google_service_account_iam_member" "api_task_identity" {
  service_account_id = google_service_account.task.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${google_service_account.api.email}"
}

resource "google_service_account_iam_member" "api_self_signing" {
  service_account_id = google_service_account.api.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_service_account.api.email}"
}

resource "google_artifact_registry_repository" "backend" {
  project       = var.project_id
  location      = var.runtime_region
  repository_id = "reader-backend"
  description   = "Immutable Reader API and worker container images"
  format        = "DOCKER"
  labels        = local.labels

  depends_on = [google_project_service.required]
}

resource "google_artifact_registry_repository_iam_member" "build_writer" {
  project    = var.project_id
  location   = google_artifact_registry_repository.backend.location
  repository = google_artifact_registry_repository.backend.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.build.email}"
}

resource "google_project_iam_member" "build_logs" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.build.email}"
}

# Cloud Build owns its default staging bucket; Terraform owns only this grant.
# The custom builder can read uploaded source, never reader assets or other objects.
resource "google_project_iam_member" "build_source" {
  project = var.project_id
  role    = "roles/storage.objectViewer"
  member  = "serviceAccount:${google_service_account.build.email}"

  condition {
    title       = "ReaderBuildSourceOnly"
    description = "Read only backend source archives in Cloud Build's staging prefix."
    expression  = "resource.type == 'storage.googleapis.com/Object' && resource.name.startsWith('projects/_/buckets/${var.project_id}_cloudbuild/objects/source/')"
  }
}

resource "google_cloud_tasks_queue" "illustrations" {
  project  = var.project_id
  location = var.runtime_region
  name     = "reader-illustrations"

  rate_limits {
    max_concurrent_dispatches = 3
    max_dispatches_per_second = 2
  }

  retry_config {
    max_attempts = 5
  }

  depends_on = [google_project_service.required]
}

resource "google_secret_manager_secret" "openai" {
  project             = var.project_id
  secret_id           = "reader-openai-api-key"
  labels              = local.labels
  deletion_protection = true
  deletion_policy     = "PREVENT"

  replication {
    auto {}
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.required]
}

resource "random_password" "fingerprint" {
  length  = 64
  special = false
}

resource "google_secret_manager_secret" "fingerprint" {
  project             = var.project_id
  secret_id           = "reader-fingerprint-secret"
  labels              = local.labels
  deletion_protection = true
  deletion_policy     = "PREVENT"

  replication {
    auto {}
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.required]
}

resource "google_secret_manager_secret_version" "fingerprint" {
  secret      = google_secret_manager_secret.fingerprint.id
  secret_data = random_password.fingerprint.result

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_secret_manager_secret_iam_member" "api_fingerprint" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.fingerprint.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.api.email}"
}

resource "google_secret_manager_secret_iam_member" "worker_openai" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.openai.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.worker.email}"
}
