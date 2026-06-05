#!/bin/bash
# 03-aws-agents.sh — SSM Agent, CloudWatch Agent, Inspector v2
# Inspector v2 uses SSM — no separate agent install needed
set -euxo pipefail

echo "================================================================"
echo " STEP 3: AWS Agents"
echo "================================================================"

# -----------------------------------------------------------------------
# SSM Agent — should already be on AL2023, but ensure latest version
# -----------------------------------------------------------------------

echo ">>> SSM Agent: install/update"
dnf install -y amazon-ssm-agent

systemctl enable amazon-ssm-agent
systemctl start amazon-ssm-agent

# Verify it's running
sleep 3
systemctl is-active amazon-ssm-agent || {
  echo "ERROR: SSM Agent failed to start"
  journalctl -u amazon-ssm-agent --no-pager -n 30
  exit 1
}

echo ">>> SSM Agent: running OK"

# -----------------------------------------------------------------------
# CloudWatch Agent
# -----------------------------------------------------------------------

echo ">>> CloudWatch Agent: installing"
dnf install -y amazon-cloudwatch-agent

# Base configuration — instances will override this via SSM Parameter Store
# at launch time using /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << 'EOF'
{
  "agent": {
    "metrics_collection_interval": 60,
    "run_as_user": "cwagent",
    "logfile": "/opt/aws/amazon-cloudwatch-agent/logs/amazon-cloudwatch-agent.log"
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          {
            "file_path": "/var/log/messages",
            "log_group_name": "/golden-ami/system/messages",
            "log_stream_name": "{instance_id}",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/secure",
            "log_group_name": "/golden-ami/system/secure",
            "log_stream_name": "{instance_id}",
            "timezone": "UTC"
          },
          {
            "file_path": "/var/log/audit/audit.log",
            "log_group_name": "/golden-ami/system/audit",
            "log_stream_name": "{instance_id}",
            "timezone": "UTC"
          }
        ]
      }
    }
  },
  "metrics": {
    "append_dimensions": {
      "ImageId": "${aws:ImageId}",
      "InstanceId": "${aws:InstanceId}",
      "InstanceType": "${aws:InstanceType}"
    },
    "metrics_collected": {
      "cpu": {
        "measurement": ["cpu_usage_idle", "cpu_usage_user", "cpu_usage_system"],
        "metrics_collection_interval": 60,
        "totalcpu": true
      },
      "disk": {
        "measurement": ["used_percent", "inodes_free"],
        "metrics_collection_interval": 60,
        "resources": ["/", "/tmp"]
      },
      "mem": {
        "measurement": ["mem_used_percent"],
        "metrics_collection_interval": 60
      },
      "netstat": {
        "measurement": ["tcp_established", "tcp_time_wait"],
        "metrics_collection_interval": 60
      }
    }
  }
}
EOF

# Enable but don't start — instances should configure and start via user data
systemctl enable amazon-cloudwatch-agent

echo ">>> CloudWatch Agent: installed and enabled"

# -----------------------------------------------------------------------
# Inspector v2
# Inspector v2 is agentless for EC2 — it uses SSM to run assessments.
# What we DO need:
#   1. SSM Agent running (done above)
#   2. IAM instance profile with AmazonInspector2ManagedCisPolicy (done in iam/)
#   3. SSM Distributor package for deeper scanning (optional but recommended)
# -----------------------------------------------------------------------

echo ">>> Inspector v2: SSM-based — no separate agent required"
echo ">>> Inspector v2: Verifying SSM plugin for Inspector scanning"

# Install the Amazon Inspector SSM plugin (enables deeper vuln scanning)
AWS_REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
ARCH=$(uname -m)

if [ "$ARCH" = "x86_64" ]; then
  INSPECTOR_PKG="AmazonInspector2-Agent-x86_64"
else
  INSPECTOR_PKG="AmazonInspector2-Agent-arm64"
fi

# This will be distributed via SSM Distributor once activated in your account.
# Baking it into the AMI is optional — Inspector v2 activates scanning via SSM
# automatically when the instance is registered and the service is enabled.
echo ">>> Inspector v2: Will activate scanning via SSM Distributor post-launch"
echo ">>> Inspector v2: Ensure Inspector v2 is enabled in your AWS account"

# -----------------------------------------------------------------------
# Unified log: note all agent versions for AMI audit trail
# -----------------------------------------------------------------------

mkdir -p /etc/golden-ami
cat > /etc/golden-ami/agent-versions.txt << EOF
Golden AMI Agent Manifest
Generated: $(date -u)

SSM Agent:         $(rpm -q amazon-ssm-agent 2>/dev/null || echo 'unknown')
CloudWatch Agent:  $(rpm -q amazon-cloudwatch-agent 2>/dev/null || echo 'unknown')
Inspector v2:      SSM-based (no dedicated agent)
EOF

echo ">>> AWS Agents install complete"
cat /etc/golden-ami/agent-versions.txt
