terraform {
  required_version = ">= 1.14.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "7.45.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "7.45.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.7.2"
    }
    time = {
      source  = "hashicorp/time"
      version = "0.13.1"
    }
  }

  backend "gcs" {}
}
