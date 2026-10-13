locals {
  required_services = toset([
    "aiplatform.googleapis.com",
    "artifactregistry.googleapis.com",
    "cloudbuild.googleapis.com",
    "cloudtasks.googleapis.com",
    "firebasestorage.googleapis.com",
    "iamcredentials.googleapis.com",
    "run.googleapis.com",
    "secretmanager.googleapis.com",
    "storage.googleapis.com",
  ])
  # Single source of truth for direct image-provider containers: provider key ->
  # Secret Manager container ID. The image_provider_secret_ids output publishes it
  # to tool/infra_common.sh, which provisions and discovers versions from it.
  image_provider_secrets = {
    seedream = "reader-byteplus-api-key"
    qwen     = "reader-qwen-api-key"
    xai      = "reader-xai-api-key"
    flux     = "reader-bfl-api-key"
  }
  # Every protected secret container this stack owns, keyed by stable role. Keys
  # are state addresses (see the moved blocks below), so never rename one.
  secret_containers = merge({
    openai      = "reader-openai-api-key"
    fingerprint = "reader-fingerprint-secret"
  }, local.image_provider_secrets)
  # The worker reads the OpenAI key and every direct provider key; the API reads
  # only the fingerprint secret and never receives a generation credential.
  worker_secrets = setsubtract(keys(local.secret_containers), ["fingerprint"])
  index_spec     = jsondecode(var.firestore_indexes_json)
  # Existing single-index collections keep their historic address; collections with
  # several indexes add their field list so no resource is renamed or collapsed.
  indexes = {
    for index in local.index_spec.indexes :
    (length([for other in local.index_spec.indexes : other if other.collectionGroup == index.collectionGroup]) == 1
      ? index.collectionGroup
    : "${index.collectionGroup}.${join(".", [for field in index.fields : field.fieldPath])}") => index
  }
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
  provider  = google-beta.quota
  project   = var.project_id
  bucket_id = google_storage_bucket.illustrations.name

  depends_on = [google_project_service.required]
}

resource "google_firebaserules_ruleset" "storage" {
  provider = google.quota
  project  = var.project_id

  source {
    files {
      name    = "storage.rules"
      content = var.storage_rules
    }
  }

  depends_on = [google_project_service.required]
}

resource "google_firebaserules_release" "storage" {
  provider = google-beta.quota

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

  # Retries must outlast a crashed worker's claim lease (WORKER_LEASE_MS in
  # backend/src/fences.ts, 16 minutes): a busy lease answers 409, and backoff of
  # 60 s doubling to 600 s keeps retrying until the lease lapses (~65 min total).
  retry_config {
    max_attempts  = 10
    min_backoff   = "60s"
    max_backoff   = "600s"
    max_doublings = 4
  }

  depends_on = [google_project_service.required]
}

# Background preprocessing of whole libraries must not delay illustrations a
# reader is waiting for, so it has its own queue and dispatch limits.
resource "google_cloud_tasks_queue" "book_analysis" {
  project  = var.project_id
  location = var.runtime_region
  name     = "reader-book-analysis"

  rate_limits {
    max_concurrent_dispatches = 3
    max_dispatches_per_second = 2
  }

  # Retries must outlast a crashed worker's claim lease (WORKER_LEASE_MS in
  # backend/src/fences.ts, 16 minutes): a busy lease answers 409, and backoff of
  # 60 s doubling to 600 s keeps retrying until the lease lapses (~65 min total).
  retry_config {
    max_attempts  = 10
    min_backoff   = "60s"
    max_backoff   = "600s"
    max_doublings = 4
  }

  depends_on = [google_project_service.required]
}

resource "random_password" "fingerprint" {
  length  = 64
  special = false
}

# Containers only, except the generated fingerprint below: the OpenAI and direct
# provider values are provisioned out of band by tool/deploy_backend and never
# enter Terraform state, variables or plans.
resource "google_secret_manager_secret" "container" {
  for_each = local.secret_containers

  project             = var.project_id
  secret_id           = each.value
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

# The containers were separate resources before they shared one for_each block;
# these moves keep every protected secret in place instead of recreating it.
moved {
  from = google_secret_manager_secret.openai
  to   = google_secret_manager_secret.container["openai"]
}

moved {
  from = google_secret_manager_secret.fingerprint
  to   = google_secret_manager_secret.container["fingerprint"]
}

moved {
  from = google_secret_manager_secret.image_provider["seedream"]
  to   = google_secret_manager_secret.container["seedream"]
}

moved {
  from = google_secret_manager_secret.image_provider["qwen"]
  to   = google_secret_manager_secret.container["qwen"]
}

moved {
  from = google_secret_manager_secret.image_provider["xai"]
  to   = google_secret_manager_secret.container["xai"]
}

moved {
  from = google_secret_manager_secret.image_provider["flux"]
  to   = google_secret_manager_secret.container["flux"]
}

resource "google_secret_manager_secret_version" "fingerprint" {
  secret      = google_secret_manager_secret.container["fingerprint"].id
  secret_data = random_password.fingerprint.result

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_secret_manager_secret_iam_member" "api_fingerprint" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.container["fingerprint"].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.api.email}"
}

resource "google_secret_manager_secret_iam_member" "worker" {
  for_each = local.worker_secrets

  project   = var.project_id
  secret_id = google_secret_manager_secret.container[each.key].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.worker.email}"
}

moved {
  from = google_secret_manager_secret_iam_member.worker_openai
  to   = google_secret_manager_secret_iam_member.worker["openai"]
}

moved {
  from = google_secret_manager_secret_iam_member.worker_image_provider["seedream"]
  to   = google_secret_manager_secret_iam_member.worker["seedream"]
}

moved {
  from = google_secret_manager_secret_iam_member.worker_image_provider["qwen"]
  to   = google_secret_manager_secret_iam_member.worker["qwen"]
}

moved {
  from = google_secret_manager_secret_iam_member.worker_image_provider["xai"]
  to   = google_secret_manager_secret_iam_member.worker["xai"]
}

moved {
  from = google_secret_manager_secret_iam_member.worker_image_provider["flux"]
  to   = google_secret_manager_secret_iam_member.worker["flux"]
}

# Google images use Vertex AI through the worker's own service-account identity.
resource "google_project_iam_member" "worker_vertex" {
  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_service_account.worker.email}"
}
