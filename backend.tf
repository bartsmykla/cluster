terraform {
  backend "s3" {
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    region                      = "us-east-1"
  }
}