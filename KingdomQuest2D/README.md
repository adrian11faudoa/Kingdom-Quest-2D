# Kingdom Quest 2D

A production-grade 2D top-down action RPG built with **Godot 4** and backed by a
full **AWS cloud infrastructure**. Inspired by classic Zelda-like games.

---

## Project Structure

```
KingdomQuest2D/
├── godot_project/          # Godot 4 game (GDScript)
│   ├── scripts/
│   │   ├── autoloads/      # Singletons: EventBus, GameManager, SaveManager,
│   │   │                   #             DataManager, AudioManager, AWSClient
│   │   ├── player/         # Player FSM, LevelSystem, SkillTree
│   │   ├── enemies/        # EnemyBase, archetypes, BossBase, NPCController
│   │   ├── combat/         # HitboxComponent, HurtboxComponent, Projectile
│   │   ├── systems/        # Inventory, Quest, Dialogue, Crafting,
│   │   │                   # DayNight, WorldStreamer, Faction, Companion,
│   │   │                   # Fishing, Farming, Mount, WorldEvents
│   │   ├── ui/             # HUD, Inventory, Journal, Dialogue, Shop,
│   │   │                   # SkillTree, WorldMap, Minimap, Leaderboard
│   │   └── utils/          # Utils, CameraController
│   └── assets/
│       ├── data/           # JSON: items, enemies, quests, skills, recipes
│       ├── art/            # Sprites, tilesets, UI
│       ├── audio/          # Music, SFX, ambient
│       └── shaders/        # GLSL shaders
│
├── aws/
│   ├── terraform/          # Infrastructure as Code
│   │   ├── main.tf         # Root module — orchestrates everything
│   │   ├── variables.tf    # All variable definitions
│   │   ├── modules/
│   │   │   ├── vpc/        # Networking: subnets, NAT, flow logs
│   │   │   ├── s3/         # Assets, builds, saves, pipeline buckets
│   │   │   ├── cloudfront/ # CDN with OAC, WASM headers, cache policies
│   │   │   ├── ecs/        # Fargate cluster, ALB, ECR, autoscaling
│   │   │   ├── rds/        # PostgreSQL 16 Multi-AZ
│   │   │   ├── elasticache/# Redis 7 TLS cluster
│   │   │   ├── cognito/    # User pool, identity pool, IAM roles
│   │   │   ├── lambda/     # Leaderboard, daily reset, save backup
│   │   │   └── monitoring/ # CloudWatch alarms, dashboard, SNS
│   │   └── environments/
│   │       ├── dev/        # dev.tfvars
│   │       ├── staging/    # staging.tfvars
│   │       └── prod/       # prod.tfvars
│   ├── docker/
│   │   ├── Dockerfile.api  # Multi-stage Node.js API image
│   │   ├── package.json
│   │   └── src/
│   │       ├── server.js   # Express API: auth, saves, leaderboards, analytics
│   │       └── schema.sql  # PostgreSQL schema + seed data
│   ├── lambda_src/
│   │   ├── leaderboard_update/ # Redis sorted set updates
│   │   ├── daily_reset/        # Challenge rotation, shop refresh
│   │   └── save_backup/        # S3 save integrity + versioned copies
│   ├── scripts/
│   │   └── deploy.sh       # One-command build + deploy script
│   └── docs/
│       └── AWS_ARCHITECTURE.md
│
├── docs/
│   └── IMPLEMENTATION_GUIDE.md
│
└── .github/
    └── workflows/
        └── deploy.yml      # GitHub Actions CI/CD pipeline
```

---

## Quick Start

### 1. Run the game locally (no AWS needed)

```bash
# Open the project in Godot 4
godot4 --path godot_project/

# Or open Godot Editor → Import → godot_project/project.godot
```

The game runs fully offline. AWS features (cloud saves, leaderboards) are
gracefully skipped when `AWSClient.is_logged_in` is `false`.

### 2. Deploy AWS infrastructure (dev environment)

```bash
# Prerequisites: AWS CLI configured, Terraform ≥ 1.6, Docker, jq

# Bootstrap S3 state backend (once only)
aws s3 mb s3://kingdom-quest-2d-tfstate --region us-east-1

# Set DB password
export TF_VAR_db_password="$(openssl rand -base64 24)"

# Deploy dev infrastructure (~10 minutes)
cd aws/terraform
terraform init
terraform apply -var-file="environments/dev/dev.tfvars"

# Get your endpoints
terraform output api_load_balancer_dns
terraform output cdn_url
terraform output cognito_client_id
```

### 3. Build and deploy everything at once

```bash
./aws/scripts/deploy.sh dev
```

---

## AWS Backend Features

| Feature | Implementation |
|---|---|
| **Player Auth** | Cognito USER_PASSWORD_AUTH → JWT tokens |
| **Cloud Saves** | Presigned S3 URLs (client uploads directly) |
| **Leaderboards** | Redis Sorted Sets, refreshed by Lambda |
| **Daily Challenges** | Lambda cron rotates at midnight UTC |
| **Save Backups** | Lambda verifies & versions every 6 hours |
| **CDN** | CloudFront with OAC, Brotli, WASM MIME fix |
| **Auto-scaling** | ECS 2→20 tasks on CPU/memory thresholds |
| **Analytics** | Game events → PostgreSQL → CloudWatch metrics |
| **Monitoring** | 8 CloudWatch alarms → SNS → email |
| **Zero-downtime** | ECS rolling deploy with circuit breaker |

---

## Godot ↔ AWS Connection Points

```gdscript
# autoloads/AWSClient.gd — add to project.godot autoloads
# Handles: login, signup, profile, saves, leaderboards, analytics

# Login
await AWSClient.login("player@email.com", "password")

# Cloud save (slot 1)
await AWSClient.upload_save(1, SaveManager's data dict)

# Download save
var data = await AWSClient.download_save(1)

# Leaderboard
var entries = await AWSClient.get_leaderboard("level")

# Analytics
AWSClient.track_event("boss_defeated", { "boss": "cave_troll" })
```

---

## Key Design Decisions

**Why Fargate over EC2?**
No servers to manage. Pay per task-second. Auto-scaling built in.
Ideal for game backends with variable load.

**Why presigned S3 URLs for saves?**
Client uploads directly to S3 — the API never touches the file bytes.
This removes a major bandwidth bottleneck and reduces API costs.

**Why Redis for leaderboards?**
Sorted Sets give O(log n) score updates and O(log n + k) range queries.
Perfect for "top 100 players" with instant refresh.

**Why Cognito instead of custom auth?**
Auth is solved infrastructure. Cognito handles password hashing,
brute-force protection, email verification, social login,
and JWT rotation — all free at game scale.

**Why Lambda for cron jobs?**
Daily reset and save backup run infrequently. Paying per invocation
instead of keeping a container warm saves ~$30/month.

---

## Contributing

See [docs/IMPLEMENTATION_GUIDE.md](docs/IMPLEMENTATION_GUIDE.md) for the full
implementation roadmap, scene setup instructions, and optimisation recommendations.
