terraform {
  required_version = ">= 1.14.0"

  required_providers {
    google = {
      source                = "hashicorp/google"
      version               = "7.45.0"
      configuration_aliases = [google.quota]
    }
    google-beta = {
      source                = "hashicorp/google-beta"
      version               = "7.45.0"
      configuration_aliases = [google-beta.quota]
    }
    time = {
      source  = "hashicorp/time"
      version = "0.13.1"
    }
  }
}
