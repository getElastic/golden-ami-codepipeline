# Setup Guide (for first-time users)

This guide walks you through deploying this repository from scratch, assuming
you've never seen it before. It explains *what* each thing is, not just
*how* to run it.

---

## 1. What this repo actually does

It builds a "Golden AMI" — a pre-configured, hardened Amazon Linux 2023
machine image that other teams launch EC2 instances from, instead of
starting from a bare AWS image every time.

The pipeline runs automatically and does this:

```
GitHub push  ──▶  CodePipeline  ──▶  CodeBuild #1: Packer build
                                          │
                                          ▼
                                  CodeBuild #2: Inspector security scan
                                  (fails the pipeline if too many
                                   vulnerabilities are found)
                                          │
                                          ▼
                                  CodeBuild #3: Promote
                                  (tags AMI "approved", shares it with
                                   other AWS accounts)
```

It also runs automatically every Monday at 02:00 UTC, so the image picks up
the latest OS security patches even if nobody changes any code.

### Key terms you'll see

| Term | What it means here |
|---|---|
| **Packer** | A HashiCorp tool that automates "build a VM image". Config lives in `packer/golden-ami.pkr.hcl`. |
| **AMI** | Amazon Machine Image — the output. A reusable EC2 "template". |
| **CodePipeline / CodeBuild** | AWS's CI/CD services. CodeBuild runs the actual commands; CodePipeline chains the stages together. |
| **CloudFormation (CFN)** | Describes all the AWS resources (IAM roles, S3 bucket, CodeBuild projects, the pipeline itself) as one YAML file: `cfn/pipeline.cfn.yml`. You deploy this once, and AWS creates everything for you. |
| **Inspector v2** | AWS's vulnerability scanner. The pipeline launches a temporary EC2 instance from the new AMI, scans it, and fails the build if there are too many CRITICAL/HIGH findings. |
| **CMK** | Customer-Managed KMS Key — your own encryption key (vs. AWS's shared default key), used to encrypt the AMI's disk. |
| **IMDSv2** | A more secure way for EC2 instances to fetch their metadata, required to reduce SSRF risk. |

---

## 2. Prerequisites

You'll need:

1. **An AWS account** (or a sandbox/CICD account) where you have admin-level
   access, or at least permission to create IAM roles, S3 buckets,
   CodeBuild/CodePipeline projects, and KMS keys.
2. **AWS CLI** installed and configured (`aws configure`) with credentials
   for that account.
   - Check it works: `aws sts get-caller-identity`
3. **A GitHub account** with this repository pushed to it (or forked).
4. **Inspector v2 enabled** in the target region (one command, shown below).
5. A **VPC + subnet** in that account with internet access (NAT gateway or
   public subnet) — Packer needs the build instance to reach the internet to
   install packages.
6. **A KMS Customer-Managed Key (CMK)** for encrypting the AMI. If you don't
   have one yet, you'll create it in Step 3 below — this is **required**, the
   pipeline will not build without it.

You do **not** need Packer installed locally — CodeBuild installs it
automatically during the pipeline run. (You only need it locally if you want
to test/validate the template on your own machine.)

---

## 3. One-time AWS setup

### 3.1 Create a KMS key for AMI encryption

This key encrypts the golden AMI's disk and snapshots. Create one (or reuse
an existing CMK your security team manages):

```bash
aws kms create-key \
  --description "Golden AMI encryption key" \
  --region ap-southeast-2
```

Note the `KeyId` from the output, then get its full ARN:

```bash
aws kms describe-key --key-id <KeyId> --region ap-southeast-2 --query "KeyMetadata.Arn" --output text
```

You'll paste this ARN into `packer/variables.pkrvars.hcl` in Step 5.

> Why is this required? A blank KMS key falls back to AWS's shared default
> key, which most compliance/security reviews (e.g. for a bank) will flag.
> This repo intentionally **fails the build** if a real CMK ARN isn't set —
> see `packer/variables.pkrvars.hcl`.

### 3.2 Enable Inspector v2

```bash
aws inspector2 enable --resource-types EC2 --region ap-southeast-2
```

This is a one-time, account-wide setting. If it's already enabled, this
command is harmless to re-run.

### 3.3 Create a GitHub connection (CodeStar/CodeConnections)

CodePipeline needs permission to read your GitHub repo. This step **cannot
be automated** — it requires a one-time manual authorization in the AWS
console:

1. Go to **AWS Console → Developer Tools → Connections → Create connection**
2. Choose **GitHub**, give it a name, and click **Connect to GitHub**
3. Authorize AWS to access your GitHub account/org and select this
   repository
4. Wait until the connection status shows **Available**
5. Copy the **connection ARN** — you'll need it in the next step. It looks
   like:
   `arn:aws:codeconnections:ap-southeast-2:123456789012:connection/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`

### 3.4 Find your VPC and subnet IDs

The pipeline launches its temporary build instance into a VPC/subnet you
choose. If you don't already know which to use:

```bash
aws ec2 describe-vpcs --region ap-southeast-2 --query "Vpcs[*].{VpcId:VpcId,IsDefault:IsDefault}"
aws ec2 describe-subnets --region ap-southeast-2 --query "Subnets[*].{SubnetId:SubnetId,VpcId:VpcId,MapPublicIpOnLaunch:MapPublicIpOnLaunch}"
```

Pick a subnet that has internet access (either `MapPublicIpOnLaunch: true`,
or routes out via a NAT gateway).

---

## 4. Configure the pipeline parameters

Open `cfn/parameters.json` and fill in the values you gathered above:

| Parameter | Value |
|---|---|
| `GitHubConnectionArn` | The ARN from step 3.3 |
| `GitHubOwner` | Your GitHub username or org name |
| `GitHubRepo` | Should already say `golden-ami-codepipeline` — change if you renamed your fork |
| `BuildSubnetId` | The subnet ID from step 3.4 |
| `BuildVpcId` | The VPC ID from step 3.4 |
| `TargetAccountIds` | Leave as `""` unless you want to share the finished AMI with other AWS accounts (comma-separated 12-digit account IDs) |
| `AwsRegion` | The region you're deploying into (default `ap-southeast-2`) |

> ⚠️ The placeholder values (`REPLACE_WITH_...`, `ACCOUNT_ID`, `CONNECTION_ID`)
> must all be replaced with your own values before deploying — the stack will
> fail to deploy or build against the wrong VPC/subnet otherwise.

---

## 5. Configure the Packer build

Open `packer/variables.pkrvars.hcl`:

1. Replace the placeholder `kms_key_id` with the real CMK ARN from step 3.1:
   ```hcl
   kms_key_id = "arn:aws:kms:ap-southeast-2:<your-account-id>:key/<your-key-id>"
   ```
2. Everything else (`java_version`, `node_version`, `python_version`,
   `instance_type`, etc.) has sensible defaults — leave as-is unless you have
   a reason to change them.
3. `subnet_id` / `vpc_id` here can stay empty — the pipeline passes the real
   values in via CodeBuild environment variables (from `parameters.json`).

If you have a specific security group the build instance must use (some
accounts enforce this via tag policies / Control Tower), set
`security_group_id` in `packer/golden-ami.pkr.hcl`'s variable block — it
defaults to empty (AWS picks the VPC's default SG).

---

## 6. Deploy the CloudFormation stack

This single command creates **everything**: S3 bucket, IAM roles, CodeBuild
projects, the CodePipeline itself, CloudWatch log groups, and the weekly
EventBridge schedule.

```bash
aws cloudformation deploy \
  --template-file cfn/pipeline.cfn.yml \
  --stack-name golden-ami-pipeline \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameter-overrides file://cfn/parameters.json \
  --region ap-southeast-2
```

This takes a few minutes. You can watch progress in **AWS Console →
CloudFormation → Stacks → golden-ami-pipeline**.

If it fails, the error message in the CloudFormation console (under the
**Events** tab) will tell you which resource failed and why — usually a typo
in `parameters.json` or a permissions issue with your AWS CLI credentials.

---

## 7. Push the code to trigger the first run

```bash
git add .
git commit -m "initial setup"
git push origin master
```

Within a minute or two, a new pipeline execution should appear in
**AWS Console → CodePipeline → Pipelines → golden-ami-pipeline**.

### What to expect on the first run

- **Source** — pulls the code from GitHub (fast, ~10 seconds)
- **BuildAMI** — installs Packer, launches a temporary EC2 instance, runs the
  hardening/setup scripts, creates the AMI (~15-25 minutes)
- **InspectorScanGate** — launches another temporary instance from the new
  AMI, waits for Inspector v2 to scan it, and fails the pipeline if there are
  any CRITICAL findings or more than 5 HIGH findings (~5-20 minutes)
- **Promote** — tags the AMI as `approved`, shares it with any
  `TargetAccountIds`, and deprecates older approved AMIs beyond the 3 most
  recent (~1 minute)

> **Important first-run check:** this pipeline's IAM permissions are scoped
> using resource tags (`ManagedBy=packer` / `ManagedBy=codepipeline`). If the
> **BuildAMI** or **InspectorScanGate** stage fails with an `AccessDenied`
> error on an EC2 API call, check the CloudWatch logs for that stage and see
> the "IAM scoping for the CodeBuild role" section in `README.md` — it
> explains which tags each action expects.

---

## 8. Where to look when something goes wrong

| Symptom | Where to look |
|---|---|
| Pipeline stage fails | Click the failed stage in CodePipeline → "Details" → opens the CodeBuild log |
| `packer validate` fails on KMS key | You haven't set a real CMK ARN in `packer/variables.pkrvars.hcl` (Step 5) — this is intentional |
| `AccessDenied` on an `ec2:*` call | See "IAM scoping for the CodeBuild role" in `README.md` |
| Inspector gate times out / never finds results | The temp instance may not have internet/SSM access — check `BuildSubnetId` has a route to the internet |
| Build succeeds but no AMI shows up | Check `s3://<ArtifactBucketName>/logs/<build-id>/manifest.json` and `packer-output.log` (bucket name is a CloudFormation stack output) |

To find the artifact bucket name:

```bash
aws cloudformation describe-stacks \
  --stack-name golden-ami-pipeline \
  --region ap-southeast-2 \
  --query "Stacks[0].Outputs"
```

---

## 9. Making changes after the initial setup

- **Change OS/runtime versions** (Java, Node, Python): edit
  `packer/variables.pkrvars.hcl`, push to `master`.
- **Change hardening/setup steps**: edit the scripts in `scripts/`
  (`01-os-update.sh` through `06-validate.sh`), push to `master`.
- **Change the pipeline itself** (new stages, IAM permissions, schedule):
  edit `cfn/pipeline.cfn.yml`, then re-run the `aws cloudformation deploy`
  command from Step 6 — CloudFormation will update the existing stack
  in-place.
- **Change the rebuild schedule**: edit `WeeklyRebuildSchedule` in
  `cfn/parameters.json` (cron syntax), then redeploy via Step 6.

For a deeper explanation of the pipeline stages, IAM design, and AMI
hand-off mechanism, see `README.md`.
