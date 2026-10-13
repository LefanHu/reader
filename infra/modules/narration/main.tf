# Shared API enablement, identities, secrets and private audio storage belong to
# the existing feature owner. This module owns only narration-specific resources.
resource "google_cloud_tasks_queue" "narration" {
  project  = var.project_id
  location = var.region
  name     = "reader-narration"
  rate_limits {
    max_concurrent_dispatches = 2
    max_dispatches_per_second = 1
  }
  # Narration's own lease is shorter; the shared backoff still outlasts it.
  retry_config {
    max_attempts  = 10
    min_backoff   = "60s"
    max_backoff   = "600s"
    max_doublings = 4
  }
}

resource "google_firestore_field" "input_ttl" {
  project    = var.project_id
  database   = "(default)"
  collection = "narrationInputs"
  field      = "expiresAt"
  ttl_config {}
  index_config {}
}

resource "google_firestore_index" "jobs" {
  project     = var.project_id
  database    = "(default)"
  collection  = "narrationJobs"
  query_scope = "COLLECTION"
  fields {
    field_path = "uid"
    order      = "ASCENDING"
  }
  fields {
    field_path = "bookId"
    order      = "ASCENDING"
  }
  deletion_policy = "PREVENT"
}

# Bounded allowance reads reclaim stale pre-submission reservations after input TTL.
resource "google_firestore_index" "abandoned" {
  project     = var.project_id
  database    = "(default)"
  collection  = "narrationJobs"
  query_scope = "COLLECTION"
  fields {
    field_path = "uid"
    order      = "ASCENDING"
  }
  fields {
    field_path = "reserved"
    order      = "ASCENDING"
  }
  fields {
    field_path = "submitted"
    order      = "ASCENDING"
  }
  fields {
    field_path = "createdAt"
    order      = "ASCENDING"
  }
  deletion_policy = "PREVENT"
}
