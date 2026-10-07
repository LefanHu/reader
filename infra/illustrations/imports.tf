locals {
  existing_index_ids = var.enable_existing_imports ? {
    creditReservations = "CICAgJim14AK"
    illustrationJobs   = "CICAgOjXh4EK"
    illustrationScenes = "CICAgJiUpoMK"
  } : {}
}

import {
  for_each = local.existing_index_ids
  to       = module.illustrations.google_firestore_index.composite[each.key]
  id       = "projects/${var.project_id}/databases/(default)/collectionGroups/${each.key}/indexes/${each.value}"
}

