#!/usr/bin/env bash
# =============================================================================
# Kingdom Quest 2D — CI/CD Deploy Script
# Builds the Godot web export, Docker API image, and deploys to AWS.
#
# USAGE:
#   ./aws/scripts/deploy.sh [dev|staging|prod]
#
# PREREQUISITES:
#   - AWS CLI configured (aws configure or IAM role)
#   - Docker installed and running
#   - Godot 4 CLI accessible (godot4 or Godot_v4.x)
#   - Terraform >= 1.6 installed
#   - jq installed (brew install jq / apt install jq)
# =============================================================================

set -euo pipefail
IFS=$'\n\t'

# ── Config ────────────────────────────────────────────────────────────────────

ENVIRONMENT="${1:-dev}"
AWS_REGION="${AWS_REGION:-us-east-1}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
TF_DIR="$ROOT_DIR/aws/terraform"
DOCKER_DIR="$ROOT_DIR/aws/docker"
GODOT_DIR="$ROOT_DIR/godot_project"

# Colours for output
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

log()  { echo -e "${BLUE}[$(date +%H:%M:%S)]${NC} $*"; }
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
fail() { echo -e "${RED}✗${NC} $*" >&2; exit 1; }

# ── Validate environment ───────────────────────────────────────────────────────

[[ "$ENVIRONMENT" =~ ^(dev|staging|prod)$ ]] || \
  fail "Invalid environment: '$ENVIRONMENT'. Use: dev | staging | prod"

log "Deploying Kingdom Quest 2D → ${ENVIRONMENT}"
log "AWS Region: ${AWS_REGION}"

# ── Step 1: Get Terraform outputs ─────────────────────────────────────────────

log "Fetching Terraform outputs..."
cd "$TF_DIR"

TF_VARS_FILE="environments/${ENVIRONMENT}/${ENVIRONMENT}.tfvars"
[[ -f "$TF_VARS_FILE" ]] || fail "tfvars not found: $TF_VARS_FILE"

# Initialise if needed
if [[ ! -d ".terraform" ]]; then
  log "Initialising Terraform..."
  terraform init -upgrade
fi

ECR_URL=$(terraform output -raw ecr_url 2>/dev/null || echo "")
ASSETS_BUCKET=$(terraform output -raw assets_bucket_name 2>/dev/null || echo "")
BUILDS_BUCKET=$(terraform output -raw builds_bucket_name 2>/dev/null || echo "")
CF_DIST_ID=$(terraform output -raw distribution_id 2>/dev/null || echo "")
ECS_CLUSTER=$(terraform output -raw cluster_name 2>/dev/null || echo "")
ECS_SERVICE=$(terraform output -raw api_service_name 2>/dev/null || echo "")

if [[ -z "$ECR_URL" ]]; then
  warn "Terraform outputs not available — running apply first..."
  terraform apply -var-file="$TF_VARS_FILE" -auto-approve
  ECR_URL=$(terraform output -raw ecr_url)
  ASSETS_BUCKET=$(terraform output -raw assets_bucket_name)
  BUILDS_BUCKET=$(terraform output -raw builds_bucket_name)
  CF_DIST_ID=$(terraform output -raw distribution_id)
  ECS_CLUSTER=$(terraform output -raw cluster_name)
  ECS_SERVICE=$(terraform output -raw api_service_name)
fi

ok "Terraform outputs fetched"
log "ECR: $ECR_URL"
log "Assets bucket: $ASSETS_BUCKET"
log "Builds bucket: $BUILDS_BUCKET"

# ── Step 2: Build & push Docker API image ─────────────────────────────────────

IMAGE_TAG="${ENVIRONMENT}-$(git rev-parse --short HEAD 2>/dev/null || echo 'latest')"
FULL_IMAGE="${ECR_URL}:${IMAGE_TAG}"
LATEST_IMAGE="${ECR_URL}:latest"

log "Building API Docker image: $FULL_IMAGE"
cd "$DOCKER_DIR"

# Login to ECR
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws ecr get-login-password --region "$AWS_REGION" | \
  docker login --username AWS --password-stdin \
  "${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

docker build \
  --file Dockerfile.api \
  --tag "$FULL_IMAGE" \
  --tag "$LATEST_IMAGE" \
  --build-arg BUILD_ENV="$ENVIRONMENT" \
  --cache-from "$LATEST_IMAGE" \
  .

docker push "$FULL_IMAGE"
docker push "$LATEST_IMAGE"
ok "API image pushed: $FULL_IMAGE"

# ── Step 3: Export Godot web build ────────────────────────────────────────────

log "Building Godot web export..."
GODOT_CMD="${GODOT_CMD:-godot4}"

if command -v "$GODOT_CMD" &>/dev/null; then
  BUILD_DIR="/tmp/kq2d_web_build"
  rm -rf "$BUILD_DIR" && mkdir -p "$BUILD_DIR"

  "$GODOT_CMD" \
    --headless \
    --path "$GODOT_DIR" \
    --export-release "Web" \
    "$BUILD_DIR/index.html" \
    2>&1 | tail -20

  ok "Godot web build complete"

  # Upload to S3 builds bucket
  log "Uploading web build to S3..."
  aws s3 sync \
    "$BUILD_DIR/" \
    "s3://${BUILDS_BUCKET}/builds/${ENVIRONMENT}/" \
    --region "$AWS_REGION" \
    --cache-control "public, max-age=3600" \
    --delete

  # Set correct content type for .wasm files
  aws s3 cp \
    "s3://${BUILDS_BUCKET}/builds/${ENVIRONMENT}/index.wasm" \
    "s3://${BUILDS_BUCKET}/builds/${ENVIRONMENT}/index.wasm" \
    --content-type "application/wasm" \
    --metadata-directive REPLACE \
    --region "$AWS_REGION" 2>/dev/null || true

  ok "Web build uploaded to s3://${BUILDS_BUCKET}/builds/${ENVIRONMENT}/"
else
  warn "Godot not found at '$GODOT_CMD' — skipping web build"
  warn "Set GODOT_CMD env var to your Godot 4 binary path"
fi

# ── Step 4: Upload game assets to CDN ─────────────────────────────────────────

if [[ -d "$GODOT_DIR/assets" ]]; then
  log "Syncing game assets to S3..."

  # Audio — moderate cache (may update with patches)
  aws s3 sync \
    "$GODOT_DIR/assets/audio/" \
    "s3://${ASSETS_BUCKET}/audio/" \
    --region "$AWS_REGION" \
    --cache-control "public, max-age=604800" \
    --exclude "*.import"

  # Art — long cache (versioned assets don't change)
  aws s3 sync \
    "$GODOT_DIR/assets/art/" \
    "s3://${ASSETS_BUCKET}/art/" \
    --region "$AWS_REGION" \
    --cache-control "public, max-age=31536000, immutable" \
    --exclude "*.import"

  ok "Assets synced to s3://${ASSETS_BUCKET}/"
fi

# ── Step 5: Invalidate CloudFront cache ───────────────────────────────────────

if [[ -n "$CF_DIST_ID" ]]; then
  log "Invalidating CloudFront cache..."
  INVALIDATION_ID=$(aws cloudfront create-invalidation \
    --distribution-id "$CF_DIST_ID" \
    --paths "/builds/${ENVIRONMENT}/*" "/audio/*" \
    --query "Invalidation.Id" \
    --output text)
  ok "CloudFront invalidation created: $INVALIDATION_ID"
fi

# ── Step 6: Deploy new ECS task (rolling update) ──────────────────────────────

if [[ -n "$ECS_CLUSTER" && -n "$ECS_SERVICE" ]]; then
  log "Triggering ECS rolling deployment..."

  # Update task definition image
  TASK_DEF=$(aws ecs describe-task-definition \
    --task-definition "kq2d-${ENVIRONMENT}-api" \
    --query "taskDefinition" \
    --output json)

  NEW_TASK_DEF=$(echo "$TASK_DEF" | \
    jq --arg IMAGE "$FULL_IMAGE" \
    '.containerDefinitions[0].image = $IMAGE |
     del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities, .registeredAt, .registeredBy)')

  NEW_TASK_ARN=$(aws ecs register-task-definition \
    --cli-input-json "$NEW_TASK_DEF" \
    --query "taskDefinition.taskDefinitionArn" \
    --output text)

  aws ecs update-service \
    --cluster "$ECS_CLUSTER" \
    --service  "$ECS_SERVICE" \
    --task-definition "$NEW_TASK_ARN" \
    --region "$AWS_REGION" \
    --output text > /dev/null

  ok "ECS service update triggered: $ECS_SERVICE"

  # Wait for deployment to stabilise (prod only)
  if [[ "$ENVIRONMENT" == "prod" ]]; then
    log "Waiting for ECS deployment to stabilise (this may take a few minutes)..."
    aws ecs wait services-stable \
      --cluster "$ECS_CLUSTER" \
      --services "$ECS_SERVICE" \
      --region "$AWS_REGION"
    ok "ECS deployment stable"
  fi
fi

# ── Step 7: Run DB migrations (if any) ────────────────────────────────────────

if [[ -f "$ROOT_DIR/aws/docker/src/schema.sql" && "$ENVIRONMENT" == "dev" ]]; then
  log "Note: Run schema.sql manually on first deploy:"
  log "  psql -h <rds-endpoint> -U kq2d_admin -d kingdom_quest -f aws/docker/src/schema.sql"
fi

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo -e "${GREEN}  Kingdom Quest 2D — Deploy Complete!    ${NC}"
echo -e "${GREEN}════════════════════════════════════════${NC}"
echo ""
echo "  Environment : $ENVIRONMENT"
echo "  API image   : $FULL_IMAGE"
echo "  Builds URL  : https://cdn.kingdomquest2d.com/builds/${ENVIRONMENT}/"
echo ""
echo "  CloudWatch  : https://${AWS_REGION}.console.aws.amazon.com/cloudwatch"
echo "  ECS console : https://${AWS_REGION}.console.aws.amazon.com/ecs"
echo ""
