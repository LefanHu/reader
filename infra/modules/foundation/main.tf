locals {
  required_services = toset([
    "apikeys.googleapis.com",
    "artifactregistry.googleapis.com",
    "billingbudgets.googleapis.com",
    "cloudbilling.googleapis.com",
    "cloudbuild.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "cloudtasks.googleapis.com",
    "firebase.googleapis.com",
    "firebaseappcheck.googleapis.com",
    "firebaserules.googleapis.com",
    "firebasestorage.googleapis.com",
    "firestore.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "identitytoolkit.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "run.googleapis.com",
    "secretmanager.googleapis.com",
    "serviceusage.googleapis.com",
    "storage.googleapis.com",
  ])

  index_spec = jsondecode(var.firestore_indexes_json)
  indexes = {
    for index in local.index_spec.indexes : index.collectionGroup => index
  }
  ttl_fields = {
    for field in local.index_spec.fieldOverrides : "${field.collectionGroup}.${field.fieldPath}" => field
    if try(field.ttl, false)
  }

  labels = {
    application = "reader"
    environment = var.environment
    managed_by  = "terraform"
  }
}

resource "google_project" "environment" {
  project_id          = var.project_id
  name                = var.project_name
  billing_account     = var.billing_account
  auto_create_network = false
  deletion_policy     = "PREVENT"
  labels              = local.labels

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_project_service" "required" {
  for_each = local.required_services

  project            = google_project.environment.project_id
  service            = each.value
  disable_on_destroy = false
}

resource "google_firebase_project" "environment" {
  provider = google-beta
  project  = google_project.environment.project_id

  depends_on = [google_project_service.required]
}

resource "google_firebase_apple_app" "reader" {
  provider = google-beta

  project      = google_project.environment.project_id
  display_name = "Reader ${title(var.environment)}"
  bundle_id    = var.apple_bundle_id
  team_id      = var.apple_team_id

  deletion_policy = "PREVENT"

  depends_on = [google_firebase_project.environment]
}

# Firebase App Check can take several seconds to observe a newly registered
# Apple app, so wait before configuring App Attest on a first environment apply.
resource "time_sleep" "apple_app_propagation" {
  create_duration = "30s"
  depends_on      = [google_firebase_apple_app.reader]
}

resource "google_firebase_app_check_app_attest_config" "reader" {
  provider = google-beta

  project   = google_project.environment.project_id
  app_id    = google_firebase_apple_app.reader.app_id
  token_ttl = "3600s"

  lifecycle {
    prevent_destroy = true

    precondition {
      condition     = google_firebase_apple_app.reader.team_id != ""
      error_message = "App Attest requires an Apple Developer Team ID."
    }
  }

  depends_on = [time_sleep.apple_app_propagation]
}

data "google_firebase_apple_app_config" "reader" {
  provider = google-beta
  project  = google_project.environment.project_id
  app_id   = google_firebase_apple_app.reader.app_id
}

resource "google_identity_platform_config" "auth" {
  project = google_project.environment.project_id

  depends_on = [google_project_service.required]
}

resource "google_identity_platform_default_supported_idp_config" "apple" {
  project       = google_project.environment.project_id
  idp_id        = "apple.com"
  enabled       = true
  client_id     = var.apple_client_id
  client_secret = var.apple_client_secret

  deletion_policy = "PREVENT"
  depends_on      = [google_identity_platform_config.auth]
}

resource "google_firestore_database" "default" {
  project                 = google_project.environment.project_id
  name                    = "(default)"
  location_id             = var.firestore_location
  type                    = "FIRESTORE_NATIVE"
  delete_protection_state = "DELETE_PROTECTION_ENABLED"
  deletion_policy         = "PREVENT"

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.required]
}

resource "google_firestore_index" "composite" {
  for_each = local.indexes

  project     = google_project.environment.project_id
  database    = google_firestore_database.default.name
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

  project    = google_project.environment.project_id
  database   = google_firestore_database.default.name
  collection = each.value.collectionGroup
  field      = each.value.fieldPath

  ttl_config {}
  index_config {}
}

resource "google_firebaserules_ruleset" "firestore" {
  project = google_project.environment.project_id

  source {
    files {
      name    = "firestore.rules"
      content = var.firestore_rules
    }
  }

  depends_on = [google_project_service.required]
}

resource "google_firebaserules_release" "firestore" {
  project      = google_project.environment.project_id
  name         = "cloud.firestore"
  ruleset_name = google_firebaserules_ruleset.firestore.name

  lifecycle {
    replace_triggered_by = [google_firebaserules_ruleset.firestore]
  }
}

resource "google_storage_bucket" "illustrations" {
  project                     = google_project.environment.project_id
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
  project   = google_project.environment.project_id
  bucket_id = google_storage_bucket.illustrations.name

  depends_on = [google_firebase_project.environment]
}

resource "google_firebaserules_ruleset" "storage" {
  project = google_project.environment.project_id

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

  project      = google_project.environment.project_id
  name         = "firebase.storage/${google_storage_bucket.illustrations.name}"
  ruleset_name = google_firebaserules_ruleset.storage.name

  lifecycle {
    replace_triggered_by = [google_firebaserules_ruleset.storage]
  }

  depends_on = [google_firebase_storage_bucket.illustrations]
}

resource "google_service_account" "api" {
  project      = google_project.environment.project_id
  account_id   = "reader-${var.environment}-api"
  display_name = "Reader ${var.environment} illustration API"
}

resource "google_service_account" "worker" {
  project      = google_project.environment.project_id
  account_id   = "reader-${var.environment}-worker"
  display_name = "Reader ${var.environment} illustration worker"
}

resource "google_service_account" "task" {
  project      = google_project.environment.project_id
  account_id   = "reader-${var.environment}-tasks"
  display_name = "Reader ${var.environment} Cloud Tasks identity"
}

resource "google_service_account" "build" {
  project      = google_project.environment.project_id
  account_id   = "reader-${var.environment}-build"
  display_name = "Reader ${var.environment} backend builder"
}

resource "google_project_iam_member" "api_firestore" {
  project = google_project.environment.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.api.email}"
}

resource "google_project_iam_member" "worker_firestore" {
  project = google_project.environment.project_id
  role    = "roles/datastore.user"
  member  = "serviceAccount:${google_service_account.worker.email}"
}

resource "google_project_iam_member" "api_tasks" {
  project = google_project.environment.project_id
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
  project       = google_project.environment.project_id
  location      = var.runtime_region
  repository_id = "reader-backend"
  description   = "Immutable Reader API and worker container images"
  format        = "DOCKER"
  labels        = local.labels

  depends_on = [google_project_service.required]
}

resource "google_artifact_registry_repository_iam_member" "build_writer" {
  project    = google_project.environment.project_id
  location   = google_artifact_registry_repository.backend.location
  repository = google_artifact_registry_repository.backend.name
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.build.email}"
}

resource "google_project_iam_member" "build_logs" {
  project = google_project.environment.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.build.email}"
}

resource "google_cloud_tasks_queue" "illustrations" {
  project  = google_project.environment.project_id
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
  project             = google_project.environment.project_id
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
  project             = google_project.environment.project_id
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
  project   = google_project.environment.project_id
  secret_id = google_secret_manager_secret.fingerprint.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.api.email}"
}

resource "google_secret_manager_secret_iam_member" "worker_openai" {
  project   = google_project.environment.project_id
  secret_id = google_secret_manager_secret.openai.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.worker.email}"
}

resource "google_monitoring_notification_channel" "email" {
  project      = google_project.environment.project_id
  display_name = "Reader ${var.environment} operations"
  type         = "email"
  labels = {
    email_address = var.alert_email
  }

  depends_on = [google_project_service.required]
}

resource "google_billing_budget" "monthly" {
  billing_account = var.billing_account
  display_name    = "Reader ${var.environment} monthly budget"

  budget_filter {
    projects = ["projects/${google_project.environment.number}"]
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(var.budget_amount_usd)
    }
  }

  dynamic "threshold_rules" {
    for_each = toset([0.5, 0.8, 1.0])
    content {
      threshold_percent = threshold_rules.value
      spend_basis       = "CURRENT_SPEND"
    }
  }

  all_updates_rule {
    monitoring_notification_channels = [google_monitoring_notification_channel.email.name]
    disable_default_iam_recipients   = false
  }

  depends_on = [google_project_service.required]
}
