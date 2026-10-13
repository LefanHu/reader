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
    random = {
      source  = "hashicorp/random"
      version = "3.7.2"
    }
  }
}
