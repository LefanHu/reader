locals {
  api_name    = "reader-${var.environment}-api"
  worker_name = "reader-${var.environment}-worker"
  labels = {
    application = "reader"
    environment = var.environment
    managed_by  = "terraform"
  }
  common_environment = {
    GOOGLE_CLOUD_PROJECT            = var.project_id
    ILLUSTRATION_BUCKET             = var.illustrations_bucket
    TASK_LOCATION                   = var.region
    TASK_QUEUE                      = var.task_queue
    TASK_SERVICE_ACCOUNT            = var.task_service_account
    PILOT_CREDITS                   = tostring(var.pilot_credits)
    ILLUSTRATIONS_ENABLED           = tostring(var.illustrations_enabled)
    OPENAI_SCENE_MODEL              = var.openai_scene_model
    OPENAI_IMAGE_ORCHESTRATOR_MODEL = var.openai_image_orchestrator_model
    OPENAI_IMAGE_MODEL              = var.openai_image_model
  }
}

resource "google_cloud_run_v2_service" "worker" {
  project             = var.project_id
  name                = local.worker_name
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = true
  labels              = local.labels

  template {
    service_account                  = var.worker_service_account
    timeout                          = "900s"
    max_instance_request_concurrency = 1

    scaling {
      min_instance_count = 0
      max_instance_count = 3
    }

    containers {
      image = var.image

      resources {
        limits = {
          cpu    = "1"
          memory = "1Gi"
        }
      }

      ports {
        container_port = 8080
      }

      dynamic "env" {
        for_each = merge(local.common_environment, {
          SERVICE_ROLE = "worker"
          WORKER_URL   = ""
        })
        content {
          name  = env.key
          value = env.value
        }
      }

      env {
        name = "OPENAI_API_KEY"
        value_source {
          secret_key_ref {
            secret  = var.openai_secret_id
            version = "latest"
          }
        }
      }
    }
  }

  lifecycle {
    precondition {
      condition     = can(regex("@sha256:[0-9a-f]{64}$", var.image))
      error_message = "Cloud Run deployments must use an immutable image digest."
    }
  }
}

data "google_iam_policy" "worker" {
  binding {
    role    = "roles/run.invoker"
    members = ["serviceAccount:${var.task_service_account}"]
  }
}

# The worker policy is authoritative so an accidental user/API invoker grant is
# removed on the next apply instead of silently expanding the trust boundary.
resource "google_cloud_run_v2_service_iam_policy" "worker" {
  project     = var.project_id
  location    = google_cloud_run_v2_service.worker.location
  name        = google_cloud_run_v2_service.worker.name
  policy_data = data.google_iam_policy.worker.policy_data
}

resource "google_cloud_run_v2_service" "api" {
  project             = var.project_id
  name                = local.api_name
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = true
  labels              = local.labels

  template {
    service_account                  = var.api_service_account
    timeout                          = "60s"
    max_instance_request_concurrency = 80

    scaling {
      min_instance_count = 0
      max_instance_count = 10
    }

    containers {
      image = var.image

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
      }

      ports {
        container_port = 8080
      }

      dynamic "env" {
        for_each = merge(local.common_environment, {
          SERVICE_ROLE = "api"
          WORKER_URL   = google_cloud_run_v2_service.worker.uri
        })
        content {
          name  = env.key
          value = env.value
        }
      }

      env {
        name = "FINGERPRINT_SECRET"
        value_source {
          secret_key_ref {
            secret  = var.fingerprint_secret_id
            version = "latest"
          }
        }
      }
    }
  }
}

resource "google_cloud_run_v2_service_iam_member" "public_api" {
  project  = var.project_id
  location = google_cloud_run_v2_service.api.location
  name     = google_cloud_run_v2_service.api.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

resource "google_monitoring_alert_policy" "api_5xx" {
  project               = var.project_id
  display_name          = "Reader ${var.environment} API 5xx responses"
  combiner              = "OR"
  enabled               = true
  notification_channels = [var.notification_channel]

  conditions {
    display_name = "More than five API 5xx responses in five minutes"
    condition_threshold {
      filter          = "resource.type = \"cloud_run_revision\" AND resource.label.service_name = \"${local.api_name}\" AND metric.type = \"run.googleapis.com/request_count\" AND metric.label.response_code_class = \"5xx\""
      comparison      = "COMPARISON_GT"
      threshold_value = 5
      duration        = "0s"

      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_SUM"
        cross_series_reducer = "REDUCE_SUM"
      }
    }
  }
}

resource "google_monitoring_alert_policy" "worker_5xx" {
  project               = var.project_id
  display_name          = "Reader ${var.environment} worker 5xx responses"
  combiner              = "OR"
  enabled               = true
  notification_channels = [var.notification_channel]

  conditions {
    display_name = "More than three worker 5xx responses in fifteen minutes"
    condition_threshold {
      filter          = "resource.type = \"cloud_run_revision\" AND resource.label.service_name = \"${local.worker_name}\" AND metric.type = \"run.googleapis.com/request_count\" AND metric.label.response_code_class = \"5xx\""
      comparison      = "COMPARISON_GT"
      threshold_value = 3
      duration        = "0s"

      aggregations {
        alignment_period     = "900s"
        per_series_aligner   = "ALIGN_SUM"
        cross_series_reducer = "REDUCE_SUM"
      }
    }
  }
}

resource "google_monitoring_alert_policy" "api_latency" {
  project               = var.project_id
  display_name          = "Reader ${var.environment} API p95 latency"
  combiner              = "OR"
  enabled               = true
  notification_channels = [var.notification_channel]

  conditions {
    display_name = "API p95 latency above five seconds for ten minutes"
    condition_threshold {
      filter          = "resource.type = \"cloud_run_revision\" AND resource.label.service_name = \"${local.api_name}\" AND metric.type = \"run.googleapis.com/request_latencies\""
      comparison      = "COMPARISON_GT"
      threshold_value = 5000
      duration        = "600s"

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_PERCENTILE_95"
      }
    }
  }
}

resource "google_monitoring_alert_policy" "queue_depth" {
  project               = var.project_id
  display_name          = "Reader ${var.environment} task queue depth"
  combiner              = "OR"
  enabled               = true
  notification_channels = [var.notification_channel]

  conditions {
    display_name = "Queue depth above twenty for fifteen minutes"
    condition_threshold {
      filter          = "resource.type = \"cloud_tasks_queue\" AND resource.label.queue_id = \"${var.task_queue}\" AND resource.label.location = \"${var.region}\" AND metric.type = \"cloudtasks.googleapis.com/queue/depth\""
      comparison      = "COMPARISON_GT"
      threshold_value = 20
      duration        = "900s"

      aggregations {
        alignment_period   = "60s"
        per_series_aligner = "ALIGN_MAX"
      }
    }
  }
}
