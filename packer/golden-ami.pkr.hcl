packer {
  required_version = ">= 1.11.0"
  required_plugins {
    amazon = {
      version = "= 1.8.0"
      source  = "github.com/hashicorp/amazon"
    }
  }
}

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------

variable "aws_region" {
  type    = string
  default = "ap-southeast-2"
}

variable "ami_version" {
  type    = string
  default = "1.0.0"
}

variable "ami_name_prefix" {
  type    = string
  default = "golden-ami-al2023"
}

variable "instance_type" {
  type    = string
  default = "t3.medium"
}

variable "root_volume_size_gb" {
  type    = number
  default = 20
}

variable "java_version" {
  type    = string
  default = "17"
  # Options: 11, 17, 21
}

variable "node_version" {
  type    = string
  default = "20"
  # LTS version
}

variable "python_version" {
  type    = string
  default = "3.11"
}

variable "share_account_ids" {
  type    = list(string)
  default = []
  # Populate via pipeline var: ["123456789012", "987654321098"]
}

variable "subnet_id" {
  type    = string
  default = ""
  # Leave empty to use default VPC; set for private subnet builds
}

variable "vpc_id" {
  type    = string
  default = ""
}

variable "security_group_id" {
  type    = string
  default = ""
  # Must be set for non-default VPC builds — SG should allow egress only
}

variable "iam_instance_profile" {
  type    = string
  default = "golden-ami-packer-instance-profile"
  # Must exist in your account — see iam/ directory
}

variable "kms_key_id" {
  type    = string
  default = ""
  # REQUIRED — must be a CMK ARN. variables.pkrvars.hcl sets this; an empty
  # value here only matters if that file is not used.
}

# ---------------------------------------------------------------------------
# Data source — always pull the latest AL2023 AMI from AWS
# ---------------------------------------------------------------------------

data "amazon-ami" "al2023" {
  region = var.aws_region
  filters = {
    name                = "al2023-ami-2023.*-kernel-6.*-x86_64"
    root-device-type    = "ebs"
    virtualization-type = "hvm"
    state               = "available"
  }
  most_recent = true
  owners      = ["amazon"]
}

# ---------------------------------------------------------------------------
# Source — EBS-backed EC2 instance
# ---------------------------------------------------------------------------

source "amazon-ebs" "golden" {
  region        = var.aws_region
  source_ami    = data.amazon-ami.al2023.id
  instance_type = var.instance_type
  ssh_username  = "ec2-user"
  imds_support  = "v2.0"

  # AMI naming — timestamp suffix ensures uniqueness across rebuilds
  ami_name        = "${var.ami_name_prefix}-${var.ami_version}-{{timestamp}}"
  ami_description = "Golden AMI | AL2023 | Hardened | v${var.ami_version} | Built by Packer"

  # Encrypt root volume
  encrypt_boot = true
  kms_key_id   = var.kms_key_id != "" ? var.kms_key_id : null

  # Root volume
  launch_block_device_mappings {
    device_name           = "/dev/xvda"
    volume_size           = var.root_volume_size_gb
    volume_type           = "gp3"
    throughput            = 125
    iops                  = 3000
    delete_on_termination = true
    encrypted             = true
    kms_key_id            = var.kms_key_id != "" ? var.kms_key_id : null
  }

  # Optional: build in a specific VPC/subnet (recommended for non-default VPCs)
  dynamic "subnet_filter" {
    for_each = var.subnet_id == "" ? [1] : []
    content {
      filters = {
        "tag:Name" = "*public*"
      }
      most_free = true
      random    = false
    }
  }

  subnet_id = var.subnet_id != "" ? var.subnet_id : null
  vpc_id    = var.vpc_id != "" ? var.vpc_id : null

  # Restrict the build instance's network access — must be set for non-default VPC builds
  security_group_id = var.security_group_id != "" ? var.security_group_id : null

  # IAM instance profile — needed for SSM, Inspector, CW
  iam_instance_profile = var.iam_instance_profile

  # Sharing — only set if account IDs provided
  ami_users = length(var.share_account_ids) > 0 ? var.share_account_ids : null

  # Tags applied to the AMI and its snapshots
  tags = {
    Name          = "${var.ami_name_prefix}-${var.ami_version}"
    Version       = var.ami_version
    BaseAMI       = data.amazon-ami.al2023.id
    BaseAMIName   = data.amazon-ami.al2023.name
    OS            = "AmazonLinux2023"
    BuildDate     = "{{timestamp}}"
    ManagedBy     = "packer"
    Environment   = "golden"
    JavaVersion   = var.java_version
    NodeVersion   = var.node_version
    PythonVersion = var.python_version
    Hardened      = "true"
    CISCompliance = "level-1"
  }

  snapshot_tags = {
    Name      = "${var.ami_name_prefix}-${var.ami_version}-snapshot"
    ManagedBy = "packer"
  }

  # Tags applied to the temporary build EC2 instance
  run_tags = {
    Name        = "packer-build-${var.ami_name_prefix}-${var.ami_version}"
    ManagedBy   = "packer"
    Environment = "build"
    Purpose     = "golden-ami-build"
  }

  # Tags applied to the ephemeral EBS volume(s) attached to the build instance
  run_volume_tags = {
    Name      = "packer-build-volume-${var.ami_name_prefix}"
    ManagedBy = "packer"
  }

  # Retry on spot interruption or transient API errors
  max_retries = 3

  # Longer timeout for hardening + runtime install
  ssh_timeout = "15m"
}

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

build {
  name    = "golden-ami"
  sources = ["source.amazon-ebs.golden"]

  # 1. OS updates — always first
  provisioner "shell" {
    script          = "../scripts/01-os-update.sh"
    execute_command = "sudo bash '{{ .Path }}'"
  }

  # 2. CIS Level 1 hardening
  provisioner "shell" {
    script          = "../scripts/02-cis-hardening.sh"
    execute_command = "sudo bash '{{ .Path }}'"
  }

  # 3. AWS agents (SSM, CloudWatch, Inspector)
  provisioner "shell" {
    script          = "../scripts/03-aws-agents.sh"
    execute_command = "sudo bash '{{ .Path }}'"
  }

  # 4. App runtimes — pass versions as env vars
  provisioner "shell" {
    script          = "../scripts/04-app-runtimes.sh"
    execute_command = "sudo bash '{{ .Path }}'"
    environment_vars = [
      "JAVA_VERSION=${var.java_version}",
      "NODE_VERSION=${var.node_version}",
      "PYTHON_VERSION=${var.python_version}"
    ]
  }

  # 5. Final cleanup — remove build artifacts, temp files, SSH host keys
  provisioner "shell" {
    script          = "../scripts/05-cleanup.sh"
    execute_command = "sudo bash '{{ .Path }}'"
  }

  # 6. Post-build validation — fail the build if anything is wrong
  provisioner "shell" {
    script          = "../scripts/06-validate.sh"
    execute_command = "sudo bash '{{ .Path }}'"
    environment_vars = [
      "JAVA_VERSION=${var.java_version}",
      "NODE_VERSION=${var.node_version}"
    ]
  }

  # Write the built AMI ID to a manifest for downstream pipeline stages —
  # avoids scraping the build log for "ami-..." patterns.
  post-processor "manifest" {
    output     = "manifest.json"
    strip_path = true
  }
}
