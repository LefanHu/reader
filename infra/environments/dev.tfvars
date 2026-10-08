environment          = "dev"
project_id           = "reader-35ca1"
project_name         = "Reader Development"
billing_account      = "01168C-DD20CF-C0EE3D"
firestore_location   = "nam5"
runtime_region       = "us-east1"
apple_bundle_id      = "com.leafmealone.reader"
apple_team_id        = "2X6DR5784V"
illustrations_bucket = "reader-35ca1-illustrations"
budget_amount_usd    = 25
budget_currency      = "CAD"
alert_email          = "lefanhu1@gmail.com"
state_bucket         = "reader-iac-35ca1-tfstate"
# Dev-only generation smoke testing; native rollout checks remain required for production.
illustrations_enabled   = true
narration_enabled       = true
enable_existing_imports = true

# Supply the Google web OAuth client privately through TF_VAR_google_client_id
# and TF_VAR_google_client_secret. Interactive deployment hides secret input;
# credentials must never be committed here. Native bundle/team IDs remain
# necessary for Firebase Apple-platform registration and App Attest.
