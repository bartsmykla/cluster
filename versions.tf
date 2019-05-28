terraform {
  required_version = ">= 0.12"

  backend "s3" {
    skip_requesting_account_id  = true
    skip_credentials_validation = true
    skip_get_ec2_platforms      = true
    skip_metadata_api_check     = true
    region                      = "us-east-1"
  }
}
