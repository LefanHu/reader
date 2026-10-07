# Core owns shared identity/data resources; feature stacks consume its outputs.
locals {
  required_services = toset([
    "apikeys.googleapis.com",
    "billingbudgets.googleapis.com",
    "cloudbilling.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "firebase.googleapis.com",
    "firebaseappcheck.googleapis.com",
    "firebaserules.googleapis.com",
    "firestore.googleapis.com",
    "iam.googleapis.com",
    "identitytoolkit.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "serviceusage.googleapis.com",
  ])

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

# App Check may not observe a new Apple app immediately after registration.
# Preserve this ordering delay so first-time core deployments remain reliable.
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

# Apple platform registrations share one Firebase project, Auth and database.
resource "google_firebase_apple_app" "macos" {
  provider        = google-beta
  project         = google_project.environment.project_id
  display_name    = "Reader macOS ${title(var.environment)}"
  bundle_id       = var.apple_macos_bundle_id
  team_id         = var.apple_team_id
  deletion_policy = "PREVENT"
  depends_on      = [google_firebase_project.environment]
}
resource "time_sleep" "macos_app_propagation" {
  create_duration = "30s"
  depends_on      = [google_firebase_apple_app.macos]
}
resource "google_firebase_app_check_app_attest_config" "macos" {
  provider  = google-beta
  project   = google_project.environment.project_id
  app_id    = google_firebase_apple_app.macos.app_id
  token_ttl = "3600s"
  lifecycle {
    prevent_destroy = true
    precondition {
      condition     = google_firebase_apple_app.macos.team_id != ""
      error_message = "macOS App Attest requires an Apple Developer Team ID."
    }
  }
  depends_on = [time_sleep.macos_app_propagation]
}
data "google_firebase_apple_app_config" "macos" {
  provider = google-beta
  project  = google_project.environment.project_id
  app_id   = google_firebase_apple_app.macos.app_id
}
