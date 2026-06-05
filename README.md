# Golden AMI — CodePipeline Implementation

AWS-native pipeline replacing GitHub Actions.
Flow: **GitHub → CodePipeline → CodeBuild (Packer) → Inspector v2 → Tag approved**

---

## What changed from the GitHub Actions POC

| | GitHub Actions POC | This (CodePipeline) |
|---|---|---|
| Pipeline trigger | GitHub Actions runner | CodePipeline + EventBridge |
| Build execution | GitHub-hosted runner | CodeBuild (your AWS account) |
| AWS auth | OIDC assume-role | CodeBuild service role (no OIDC needed) |
| Scheduled rebuild | `schedule:` in workflow | EventBridge rule |
| Stage handoff | GitHub Actions outputs | S3 artefact (`ami-id.txt`) |
| Logs | GitHub Actions UI | CloudWatch Logs |
| Packer scripts | unchanged | unchanged |
| Packer template | unchanged | unchanged |

---

## Repository structure

```
golden-ami-poc/
├── cfn/
│   ├── pipeline.cfn.yml       ← Main CloudFormation stack
│   └── parameters.json        ← Parameter values for deployment
├── codebuild/
│   ├── buildspec-packer.yml   ← Stage 2: Packer build
│   ├── buildspec-inspector.yml← Stage 3: Inspector scan gate
│   └── buildspec-promote.yml  ← Stage 4: Promote & share
├── packer/
│   ├── golden-ami.pkr.hcl     ← Unchanged from POC
│   └── variables.pkrvars.hcl
└── scripts/
    ├── 01-os-update.sh        ← All scripts unchanged from POC
    ├── 02-cis-hardening.sh
    ├── 03-aws-agents.sh
    ├── 04-app-runtimes.sh
    ├── 05-cleanup.sh
    └── 06-validate.sh
```

---

## Setup steps

### Step 1: Create the GitHub CodeStar Connection

This is a one-time manual step in the console — it cannot be automated.

1. Go to **Developer Tools → Connections** in your CICD AWS account
2. Click **Create connection → GitHub**
3. Authenticate with GitHub and authorise the connection
4. Wait for status to show **Available**
5. Copy the connection ARN — you need it in Step 3

### Step 2: Enable Inspector v2

```bash
aws inspector2 enable --resource-types EC2 --region ap-southeast-2
```

### Step 3: Update parameters.json

Edit `cfn/parameters.json` and fill in:

| Parameter | What to put |
|-----------|-------------|
| `GitHubConnectionArn` | The ARN from Step 1 |
| `GitHubOwner` | Your GitHub org or username |
| `BuildSubnetId` | A subnet in your CICD account with internet access |
| `BuildVpcId` | The VPC containing that subnet |
| `TargetAccountIds` | Comma-separated workload account IDs, or leave empty |

### Step 4: Deploy the CloudFormation stack

```bash
aws cloudformation deploy \
  --template-file cfn/pipeline.cfn.yml \
  --stack-name golden-ami-pipeline \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides file://cfn/parameters.json \
  --region ap-southeast-2
```

### Step 5: Push to master to trigger the first run

```bash
git add .
git commit -m "initial codepipeline setup"
git push origin master
```

The pipeline will appear in **CodePipeline → Pipelines** in the console.

---

## Pipeline stages

```
Source → BuildAMI → InspectorScanGate → Promote
```

| Stage | CodeBuild project | Timeout | What it does |
|-------|-------------------|---------|--------------|
| Source | — | — | Pulls code from GitHub via CodeStar connection |
| BuildAMI | golden-ami-packer-build | 60 min | Installs Packer, runs all 6 scripts, creates AMI, writes AMI ID to S3 |
| InspectorScanGate | golden-ami-inspector-gate | 40 min | Launches temp instance, polls Inspector v2, fails if CRITICAL > 0 or HIGH > 5 |
| Promote | golden-ami-promote | 15 min | Tags AMI as approved, shares cross-account, deprecates old versions |

---

## AMI ID handoff between stages

CodeBuild stages pass data via S3 artefacts, not environment variables.

- **BuildAMI** writes `ami-id.txt` → uploaded as `BuildOutput` artefact
- **InspectorScanGate** reads `ami-id.txt` from `BuildOutput`, passes it as `InspectorOutput`
- **Promote** reads `ami-id.txt` from `InspectorOutput`

---

## Scheduled weekly rebuild

An EventBridge rule fires every Monday at 02:00 UTC and starts the pipeline regardless of code changes. This ensures the AMI picks up OS security patches weekly.

To change the schedule, update the `WeeklyRebuildSchedule` parameter (standard cron syntax):

```
cron(0 2 ? * MON *)   # Monday 02:00 UTC
cron(0 3 ? * SUN *)   # Sunday 03:00 UTC
```

---

## Viewing logs

Each CodeBuild stage writes to CloudWatch Logs:

```
/aws/codebuild/golden-ami-packer-build
/aws/codebuild/golden-ami-inspector-gate
/aws/codebuild/golden-ami-promote
```

Packer's full output is also saved to S3:
```
s3://ARTIFACT_BUCKET_NAME/logs/BUILD_ID/packer-output.log
```
Use the `ArtifactBucketName` stack output for `ARTIFACT_BUCKET_NAME`.

---

## Cross-account AMI sharing

Set `TargetAccountIds` to a comma-separated list of workload account IDs. The promote stage will:
1. Share the AMI with each account
2. Share the underlying EBS snapshot with each account

Target accounts can then launch instances using the AMI ID or set up their own AMI copy.

---

## Differences from the BRS uploaded template

The uploaded `p005-rams-doe-dev-common-packer-iam-role.txt` covered only the EC2 instance profile. This implementation covers the full pipeline. Key differences:

- **No `tr-permission-boundary`** — removed as agreed; add back if deploying into TR-managed accounts
- **No `a205257-ec2-cloudwatch-logging`** — replaced with AWS-managed `CloudWatchAgentServerPolicy`
- **No hardcoded S3 bucket names** — CloudFormation generates the artifact bucket name and exposes it as an output
- **Added** CodePipeline role, CodeBuild role, EventBridge role
- **Added** Inspector v2 permissions on the CodeBuild role
- **TR tags removed** — add back (`tr:application-asset-insight-id`, `tr:resource-owner`, `tr:environment-type`) if required
