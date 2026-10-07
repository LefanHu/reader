# These conditional imports adopt the resources that predate Terraform in the
# development project. After the first successful apply, set
# enable_existing_imports=false; the objects remain in state.
import {
  for_each = var.enable_existing_imports ? toset([var.project_id]) : toset([])
  to       = module.foundation.google_project.environment
  id       = each.value
}

import {
  for_each = var.enable_existing_imports ? toset([var.project_id]) : toset([])
  to       = module.foundation.google_firebase_project.environment
  id       = each.value
}

import {
  for_each = var.enable_existing_imports ? toset([var.project_id]) : toset([])
  to       = module.foundation.google_firestore_database.default
  id       = "projects/${each.value}/databases/(default)"
}

import {
  for_each = var.enable_existing_imports ? toset([var.project_id]) : toset([])
  to       = module.foundation.google_firebaserules_release.firestore
  id       = "projects/${each.value}/releases/cloud.firestore"
}

