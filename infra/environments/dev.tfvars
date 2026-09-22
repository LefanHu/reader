environment             = "dev"
project_id              = "reader-35ca1"
project_name            = "Reader Development"
billing_account         = "01168C-DD20CF-C0EE3D"
firestore_location      = "nam5"
runtime_region          = "us-east1"
apple_bundle_id         = "com.leafmealone.reader"
apple_team_id           = "2X6DR5784V"
illustrations_bucket    = "reader-35ca1-illustrations"
budget_amount_usd       = 25
alert_email             = "lefanhu1@gmail.com"
state_bucket            = "reader-iac-35ca1-tfstate"
illustrations_enabled   = false
enable_existing_imports = true

# Supply Apple credentials through TF_VAR_apple_client_id and
# TF_VAR_apple_client_secret. The deployment script prompts without echo if
# either value is absent; credentials must never be committed here.
