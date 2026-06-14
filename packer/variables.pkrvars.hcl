# variables.pkrvars.hcl
# Use this file for local overrides during development.
# In CI, variables are passed via -var flags in the GitHub Actions workflow.
# Do NOT commit sensitive values here.

aws_region          = "ap-southeast-2"
ami_version         = "1.0.0"
ami_name_prefix     = "golden-ami-al2023"
instance_type       = "t3.medium"
root_volume_size_gb = 20

java_version   = "17"
node_version   = "20"
python_version = "3.11"

# Populate these with target account IDs for cross-account sharing
# share_account_ids = ["123456789012", "987654321098"]
share_account_ids = []

# Leave empty to use default VPC during POC
# For production: use a private subnet with a NAT gateway
subnet_id = ""
vpc_id    = ""

# REQUIRED — must be a CMK ARN. A blank value silently falls back to the
# AWS-managed key, which is not acceptable for compliance-scoped builds.
# Replace ACCOUNT_ID/KEY_ID with the CMK provisioned for this account before
# running a production build.
kms_key_id = "arn:aws:kms:ap-southeast-2:ACCOUNT_ID:key/KEY_ID" # REQUIRED — must be a CMK

iam_instance_profile = "golden-ami-packer-instance-profile"
