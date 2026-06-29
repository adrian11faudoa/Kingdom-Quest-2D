# Kingdom Quest 2D — AWS Architecture & Deployment Guide

## Table of Contents
1. [Architecture Overview](#architecture)
2. [Infrastructure Components](#components)
3. [First-Time Setup](#setup)
4. [Environment Management](#environments)
5. [Deploying Updates](#deploying)
6. [Godot ↔ AWS Integration](#godot-aws)
7. [Database Operations](#database)
8. [Cost Estimates](#costs)
9. [Security Checklist](#security)
10. [Troubleshooting](#troubleshooting)

---

## 1. Architecture Overview <a name="architecture"></a>

```
Players
  │
  ▼
CloudFront CDN ──────────────────────────────────────────────┐
  │  (assets, web builds, HTTPS, WAF)                        │
  │                                                           │
  ▼                                                          S3
Application Load Balancer                          ┌──────────────────┐
  │  (HTTPS → HTTP, health checks)                │ game-assets       │
  │                                               │ game-builds       │
  ▼                                               │ player-saves      │
ECS Fargate Cluster                               └──────────────────┘
  │  Node.js API (2–20 tasks, auto-scaling)
  │  X-Ray sidecar
  │
  ├──▶ RDS PostgreSQL (Multi-AZ in prod)
  │      Player accounts, progress, saves metadata
  │
  ├──▶ ElastiCache Redis (TLS)
  │      Sessions, leaderboards, rate limits, daily shop
  │
  ├──▶ Cognito User Pool
  │      Authentication, JWT tokens, social login
  │
  └──▶ Lambda Functions
         leaderboard_update  (on-demand via SNS)
         daily_reset         (cron: midnight UTC)
         save_backup         (cron: every 6 hours)

Monitoring: CloudWatch → SNS → Email alerts
```

### Data Flow: Player Login

```
Godot client
  → POST cognito-idp (USER_PASSWORD_AUTH)
  ← JWT tokens (access 1h, refresh 30d)
  → GET /api/v1/player/profile  [Bearer token]
  ← Player profile (or auto-created if new)
```

### Data Flow: Cloud Save Upload

```
Godot client
  → POST /api/v1/player/save/upload-url  [slot=1]
  ← { uploadUrl: "https://s3.presigned.url..." }
  → PUT https://s3.presigned.url  (JSON save data, direct to S3)
  ← 200 OK  (save is now in S3)
```

---

## 2. Infrastructure Components <a name="components"></a>

| Component | Service | Purpose |
|---|---|---|
| CDN | CloudFront | Global asset delivery, HTTPS, WAF |
| API | ECS Fargate | Stateless Node.js API containers |
| Auth | Cognito | Player auth, JWT, social login |
| Database | RDS PostgreSQL 16 | Player data, progress, achievements |
| Cache | ElastiCache Redis 7 | Leaderboards, sessions, daily state |
| Storage | S3 (3 buckets) | Assets, builds, player saves |
| Serverless | Lambda (3 fns) | Cron jobs, async event handlers |
| Monitoring | CloudWatch | Metrics, logs, alarms, dashboards |
| Secrets | Secrets Manager | DB credentials, API keys |
| Registry | ECR | Docker image storage |

---

## 3. First-Time Setup <a name="setup"></a>

### Prerequisites

```bash
# Install required tools
brew install awscli terraform jq          # macOS
apt install awscli terraform jq           # Ubuntu

# Configure AWS credentials
aws configure
# Enter: Access Key ID, Secret Access Key, Region (us-east-1), Output (json)

# Verify
aws sts get-caller-identity
```

### Step 1: Bootstrap Terraform State Backend

Terraform stores its state in S3. Create the bucket and DynamoDB lock table **once**:

```bash
# Create state bucket (name must be globally unique)
aws s3 mb s3://kingdom-quest-2d-tfstate --region us-east-1

# Enable versioning on state bucket (protects against accidents)
aws s3api put-bucket-versioning \
  --bucket kingdom-quest-2d-tfstate \
  --versioning-configuration Status=Enabled

# Enable encryption on state bucket
aws s3api put-bucket-encryption \
  --bucket kingdom-quest-2d-tfstate \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

# Block public access on state bucket
aws s3api put-public-access-block \
  --bucket kingdom-quest-2d-tfstate \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

# Create DynamoDB table for state locking
aws dynamodb create-table \
  --table-name kingdom-quest-2d-tfstate-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```

### Step 2: Set Database Password

Never put passwords in tfvars files. Use environment variables:

```bash
export TF_VAR_db_password="$(openssl rand -base64 24)"
echo "Save this password somewhere safe: $TF_VAR_db_password"

# Or use AWS Secrets Manager to generate one:
aws secretsmanager get-random-password \
  --password-length 24 \
  --exclude-punctuation \
  --query RandomPassword --output text
```

### Step 3: Deploy Dev Infrastructure

```bash
cd aws/terraform
terraform init
terraform plan -var-file="environments/dev/dev.tfvars"
terraform apply -var-file="environments/dev/dev.tfvars"
```

Expected time: **8–12 minutes** (RDS takes the longest).

### Step 4: Run Database Migrations

```bash
# Get the RDS endpoint
DB_ENDPOINT=$(terraform output -raw rds_endpoint)

# Get DB password from Secrets Manager
DB_PASS=$(aws secretsmanager get-secret-value \
  --secret-id "kq2d-dev/rds/master-credentials" \
  --query SecretString --output text | jq -r .password)

# Run schema
PGPASSWORD="$DB_PASS" psql \
  -h "$DB_ENDPOINT" \
  -U kq2d_admin \
  -d kingdom_quest \
  -f aws/docker/src/schema.sql

echo "Schema applied successfully"
```

### Step 5: Update Godot Project Config

After deploy, update `AWSClient.gd` with your real endpoints:

```bash
# Get outputs
terraform output api_load_balancer_dns
terraform output cdn_url
terraform output cognito_client_id
terraform output cognito_user_pool_id
```

Then in `godot_project/scripts/autoloads/AWSClient.gd`:
```gdscript
const API_BASE_URL      := "https://<your-alb-dns>"
const COGNITO_CLIENT_ID := "<from-terraform-output>"
const CDN_BASE_URL      := "<from-terraform-output>"
```

### Step 6: Build and Push First Docker Image

```bash
# Login to ECR
ECR_URL=$(cd aws/terraform && terraform output -raw ecr_url)
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin \
  "${ACCOUNT_ID}.dkr.ecr.us-east-1.amazonaws.com"

# Build and push
cd aws/docker
docker build -f Dockerfile.api -t "${ECR_URL}:latest" .
docker push "${ECR_URL}:latest"

# Update ECS service to use new image
cd ../terraform
aws ecs update-service \
  --cluster "kq2d-dev-cluster" \
  --service "kq2d-dev-api-service" \
  --force-new-deployment
```

---

## 4. Environment Management <a name="environments"></a>

Three environments share the same Terraform code, separated by tfvars:

| Environment | Purpose | Scaling |
|---|---|---|
| `dev` | Local development, feature testing | Minimal (1 task, t3.micro) |
| `staging` | Pre-release testing, QA | Medium (2 tasks, t3.small) |
| `prod` | Live game | Auto-scale 2–20 tasks, r6g.large |

Switching environments:

```bash
# Always use -var-file for the right environment
terraform workspace select dev    # optional workspace isolation
terraform apply -var-file="environments/prod/prod.tfvars"
```

---

## 5. Deploying Updates <a name="deploying"></a>

### Automated: use the deploy script

```bash
# Deploy to dev
./aws/scripts/deploy.sh dev

# Deploy to prod (waits for ECS to stabilise before exiting)
./aws/scripts/deploy.sh prod
```

The script handles:
1. Terraform apply (infra changes only if needed)
2. Docker build + ECR push
3. Godot web export + S3 upload
4. Game assets sync to S3
5. CloudFront cache invalidation
6. ECS rolling deployment (zero-downtime)

### Manual: ECS only (API code change, no infra change)

```bash
IMAGE_TAG="v1.2.3"
ECR_URL=$(cd aws/terraform && terraform output -raw ecr_url)

docker build -f aws/docker/Dockerfile.api \
  -t "${ECR_URL}:${IMAGE_TAG}" aws/docker/

docker push "${ECR_URL}:${IMAGE_TAG}"

aws ecs update-service \
  --cluster kq2d-prod-cluster \
  --service kq2d-prod-api-service \
  --force-new-deployment
```

### Rollback

```bash
# List recent task definitions
aws ecs list-task-definitions \
  --family-prefix kq2d-prod-api \
  --sort DESC --max-items 5

# Roll back to a previous revision
aws ecs update-service \
  --cluster kq2d-prod-cluster \
  --service kq2d-prod-api-service \
  --task-definition kq2d-prod-api:42   # use previous revision number
```

---

## 6. Godot ↔ AWS Integration <a name="godot-aws"></a>

### Autoload Registration

Add `AWSClient` to `project.godot` autoloads:

```ini
[autoload]
AWSClient="*res://scripts/autoloads/AWSClient.gd"
```

Add `CloudSaveManager` as a child of the player scene (not autoload —
it needs access to local SaveManager).

### Authentication Flow in Game

```gdscript
# In your Login UI script:
func _on_login_button_pressed() -> void:
    var email    = $EmailField.text
    var password = $PasswordField.text
    $LoadingSpinner.show()
    AWSClient.login(email, password)

func _ready() -> void:
    AWSClient.login_completed.connect(_on_login_completed)

func _on_login_completed(success: bool, error: String) -> void:
    $LoadingSpinner.hide()
    if success:
        SceneTransition.go_to("res://scenes/world/regions/StartingVillage.tscn")
    else:
        $ErrorLabel.text = error
```

### Cloud Save in SaveManager

Hook cloud saves into the existing SaveManager:

```gdscript
# In your Load Game UI:
func _on_load_slot_pressed(slot: int) -> void:
    var cloud_save := get_node("/root/CloudSaveManager")
    var success    := await cloud_save.load_from_cloud(slot)
    if success:
        SceneTransition.go_to("res://scenes/world/regions/StartingVillage.tscn")

func _on_save_slot_pressed(slot: int) -> void:
    var cloud_save := get_node("/root/CloudSaveManager")
    await cloud_save.save_to_cloud(slot)
    $SavedLabel.show()
```

### Analytics Events

```gdscript
# Track meaningful game moments:
AWSClient.track_event("quest_completed", { "quest_id": "main_01_goblin_threat" })
AWSClient.track_event("boss_defeated",   { "boss": "cave_troll", "level": 8 })
AWSClient.track_event("item_crafted",    { "item_id": "iron_sword" })
AWSClient.track_event("player_died",     { "cause": "goblin_archer", "region": "forest" })
```

---

## 7. Database Operations <a name="database"></a>

### Connect via AWS SSM (no bastion host needed)

```bash
# Start SSM port forwarding to RDS (requires SSM agent on an ECS task)
aws ssm start-session \
  --target "ecs:kq2d-prod-cluster_<task-id>_<container-id>" \
  --document-name "AWS-StartPortForwardingSessionToRemoteHost" \
  --parameters "host=<rds-endpoint>,portNumber=5432,localPortNumber=5433"

# Then connect locally
psql -h localhost -p 5433 -U kq2d_admin -d kingdom_quest
```

### Useful Queries

```sql
-- Active players last 24h
SELECT COUNT(*) FROM players WHERE last_seen_at > NOW() - INTERVAL '24 hours';

-- Top 10 players by level
SELECT username, level, xp FROM players ORDER BY level DESC, xp DESC LIMIT 10;

-- Save slot usage per player
SELECT p.username, ps.slot, ps.file_size, ps.updated_at
FROM player_saves ps JOIN players p ON ps.player_id = p.id
ORDER BY ps.updated_at DESC LIMIT 20;

-- Daily active users (last 30 days)
SELECT DATE(last_seen_at) as day, COUNT(DISTINCT id) as dau
FROM players
WHERE last_seen_at > NOW() - INTERVAL '30 days'
GROUP BY day ORDER BY day DESC;

-- Quest completion rates
SELECT event_type, COUNT(*) as count
FROM analytics_events
WHERE event_type LIKE 'quest_%'
  AND created_at > NOW() - INTERVAL '7 days'
GROUP BY event_type ORDER BY count DESC;
```

### Backup & Restore

```bash
# Manual backup (RDS auto-backups run daily, but this is for emergencies)
aws rds create-db-snapshot \
  --db-instance-identifier kq2d-prod-postgres \
  --db-snapshot-identifier "manual-$(date +%Y%m%d-%H%M%S)"

# List available snapshots
aws rds describe-db-snapshots \
  --db-instance-identifier kq2d-prod-postgres \
  --query "DBSnapshots[*].[DBSnapshotIdentifier,SnapshotCreateTime,Status]" \
  --output table

# Restore from snapshot (creates a NEW instance — doesn't overwrite)
aws rds restore-db-instance-from-db-snapshot \
  --db-instance-identifier kq2d-prod-postgres-restored \
  --db-snapshot-identifier "manual-20240615-120000"
```

---

## 8. Cost Estimates <a name="costs"></a>

### Development Environment (~$35–50/month)

| Resource | Type | Est. Cost |
|---|---|---|
| ECS Fargate | 1 task × 0.25vCPU / 0.5GB | ~$8/mo |
| RDS PostgreSQL | db.t3.micro, 20GB gp3 | ~$15/mo |
| ElastiCache Redis | cache.t3.micro | ~$12/mo |
| S3 + CloudFront | < 10GB + < 50GB transfer | ~$3/mo |
| Lambda | < 1M invocations | Free tier |
| CloudWatch | Basic metrics + logs | ~$2/mo |

### Production Environment (~$200–400/month at 1,000 DAU)

| Resource | Type | Est. Cost |
|---|---|---|
| ECS Fargate | 2–4 tasks (Spot mix) × 1vCPU/2GB | ~$60/mo |
| RDS PostgreSQL | db.r6g.large, Multi-AZ | ~$150/mo |
| ElastiCache Redis | cache.r6g.large, 1 replica | ~$80/mo |
| S3 + CloudFront | ~50GB + ~500GB transfer | ~$30/mo |
| Lambda + EventBridge | Low invocations | ~$2/mo |
| NAT Gateways (3) | 3 AZs × $32 | ~$96/mo |
| CloudWatch | Metrics + logs + alarms | ~$15/mo |

**Cost optimisation tips:**
- Use `FARGATE_SPOT` for 70% of capacity (already configured)
- Reserved Instances for RDS saves 40–60% (commit after validating load)
- ElastiCache Reserved Nodes save 30–40%
- Consider single NAT Gateway for dev/staging (costs ~$96/mo for 3 AZs)
- Set CloudWatch log retention to 14 days in dev (already configured)

---

## 9. Security Checklist <a name="security"></a>

- [x] **RDS not publicly accessible** — private subnets only
- [x] **Redis TLS in transit** — `transit_encryption_enabled = true`
- [x] **Redis encrypted at rest** — `at_rest_encryption_enabled = true`
- [x] **S3 all public access blocked** — `block_public_acls = true`
- [x] **CloudFront OAC** — modern replacement for OAI, sigv4 signed
- [x] **Secrets in Secrets Manager** — never in env vars or tfvars
- [x] **ECS tasks run as non-root** — `USER appuser` in Dockerfile
- [x] **VPC Flow Logs enabled** — all traffic logged for audit
- [x] **Cognito advanced security** — AUDIT mode detects compromised creds
- [x] **Rate limiting** — 120 req/min per IP on all API routes
- [x] **Helmet.js** — security headers on all responses
- [x] **JWT validation on every protected route** — `aws-jwt-verify`
- [x] **S3 save paths scoped to player ID** — `saves/{cognito_sub}/...`
- [x] **IAM least-privilege** — each role has only what it needs
- [x] **ECR image scanning** — `scan_on_push = true`
- [x] **HTTPS everywhere** — HTTP → HTTPS redirect on ALB
- [x] **TLS 1.2 minimum** — `ELBSecurityPolicy-TLS13-1-2-2021-06`
- [ ] **WAF** — add `aws_wafv2_web_acl` for DDoS protection (optional, ~$10/mo)
- [ ] **ACM certificate** — add custom domain TLS cert
- [ ] **GuardDuty** — threat detection service (~$4/mo for small account)

---

## 10. Troubleshooting <a name="troubleshooting"></a>

### ECS task keeps restarting

```bash
# Check task logs
aws logs tail /ecs/kq2d-prod/api --follow --since 30m

# Check stopped task reason
aws ecs describe-tasks \
  --cluster kq2d-prod-cluster \
  --tasks $(aws ecs list-tasks --cluster kq2d-prod-cluster --desired-status STOPPED \
            --query "taskArns[0]" --output text) \
  --query "tasks[0].stoppedReason"
```

Common causes:
- **Health check failing** → `curl http://localhost:8080/health` inside container
- **Can't reach RDS** → check ECS task security group allows port 5432 to RDS SG
- **Secret fetch failed** → verify task execution role has `secretsmanager:GetSecretValue`
- **OOM killed** → increase `api_memory` in tfvars

### Terraform state lock

```bash
# If terraform is stuck with "state locked"
terraform force-unlock <LOCK_ID>
# Get LOCK_ID from the error message
```

### CloudFront returning stale content

```bash
# Invalidate specific paths
aws cloudfront create-invalidation \
  --distribution-id <DIST_ID> \
  --paths "/*"
```

### Redis connection refused

```bash
# Test from inside an ECS task (requires ecs:ExecuteCommand permission)
aws ecs execute-command \
  --cluster kq2d-prod-cluster \
  --task <TASK_ARN> \
  --container api \
  --interactive \
  --command "redis-cli -h $REDIS_ENDPOINT -p 6379 --tls ping"
```

### DB connection pool exhausted

- Increase `max` in pg Pool config (currently 20)
- Add PgBouncer sidecar container for connection pooling
- Or upgrade to `db.r6g.large` which supports more connections

### Leaderboard data stale

```bash
# Manually invalidate Redis leaderboard cache
aws ecs execute-command --cluster kq2d-prod-cluster \
  --task <TASK_ARN> --container api --interactive \
  --command "redis-cli -h $REDIS_ENDPOINT --tls DEL lb:level lb:kills lb:gold lb:playtime"
```
