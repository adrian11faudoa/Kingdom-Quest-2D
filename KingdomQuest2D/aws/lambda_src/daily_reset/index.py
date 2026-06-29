# =============================================================================
# Kingdom Quest 2D — Lambda: daily_reset/index.py
# Runs at midnight UTC via EventBridge cron.
# Resets: daily challenges, rotating shop stock, daily login rewards.
# =============================================================================

import json
import os
import boto3
import psycopg2
import psycopg2.extras
import redis
import logging
import random
from datetime import date, datetime, timezone

logger = logging.getLogger()
logger.setLevel(logging.INFO)

secrets_client = boto3.client("secretsmanager")
sns_client     = boto3.client("sns")

REDIS_ENDPOINT = os.environ["REDIS_ENDPOINT"]
DB_SECRET_ARN  = os.environ["DB_SECRET_ARN"]
SNS_TOPIC_ARN  = os.environ.get("SNS_TOPIC_ARN", "")

# ── Daily Challenge Pool ───────────────────────────────────────────────────────
# A subset of these is selected each day
CHALLENGE_POOL = [
    { "key": "kill_enemies",     "description": "Defeat 20 enemies",          "target": 20, "xp": 100, "gold": 30  },
    { "key": "kill_goblins",     "description": "Defeat 10 Goblins",          "target": 10, "xp": 75,  "gold": 20  },
    { "key": "collect_items",    "description": "Collect 15 items",           "target": 15, "xp": 80,  "gold": 25  },
    { "key": "craft_items",      "description": "Craft 3 items",              "target": 3,  "xp": 120, "gold": 40  },
    { "key": "open_chests",      "description": "Open 5 treasure chests",     "target": 5,  "xp": 90,  "gold": 35  },
    { "key": "catch_fish",       "description": "Catch 5 fish",               "target": 5,  "xp": 60,  "gold": 15  },
    { "key": "harvest_crops",    "description": "Harvest 10 crops",           "target": 10, "xp": 70,  "gold": 20  },
    { "key": "complete_quests",  "description": "Complete 2 quests",          "target": 2,  "xp": 200, "gold": 80  },
    { "key": "kill_boss",        "description": "Defeat a dungeon boss",      "target": 1,  "xp": 300, "gold": 100 },
    { "key": "explore_regions",  "description": "Visit 3 different regions",  "target": 3,  "xp": 110, "gold": 45  },
    { "key": "earn_gold",        "description": "Earn 200 gold",              "target": 200,"xp": 80,  "gold": 0   },
    { "key": "dodge_attacks",    "description": "Dodge 30 attacks",           "target": 30, "xp": 90,  "gold": 25  },
]

DAILY_CHALLENGE_COUNT = 3  # Show 3 challenges per day


def get_db_credentials():
    resp = secrets_client.get_secret_value(SecretId=DB_SECRET_ARN)
    return json.loads(resp["SecretString"])


def get_db_connection(creds):
    return psycopg2.connect(
        host=creds["host"],
        port=creds.get("port", 5432),
        dbname=creds["dbname"],
        user=creds["username"],
        password=creds["password"],
        sslmode="require",
        connect_timeout=5,
    )


def get_redis_client():
    return redis.Redis(
        host=REDIS_ENDPOINT,
        port=6379,
        ssl=True,
        decode_responses=True,
        socket_connect_timeout=3,
    )


def handler(event, context):
    logger.info("Daily reset starting: %s", datetime.now(timezone.utc).isoformat())
    today = date.today().isoformat()

    results = {}

    try:
        creds = get_db_credentials()
        conn  = get_db_connection(creds)
        r     = get_redis_client()

        with conn:
            with conn.cursor(cursor_factory=psycopg2.extras.DictCursor) as cur:
                # 1. Deactivate yesterday's challenges
                cur.execute(
                    "UPDATE daily_challenges SET is_active = FALSE WHERE active_date < %s",
                    (today,)
                )
                deactivated = cur.rowcount
                logger.info("Deactivated %d old challenges", deactivated)

                # 2. Select today's challenge set (seeded by date for consistency)
                random.seed(today)
                todays_challenges = random.sample(CHALLENGE_POOL, DAILY_CHALLENGE_COUNT)

                # 3. Insert new challenges
                new_challenge_ids = []
                for challenge in todays_challenges:
                    cur.execute(
                        """
                        INSERT INTO daily_challenges
                            (challenge_key, description, target_value, xp_reward, gold_reward, active_date, is_active)
                        VALUES (%s, %s, %s, %s, %s, %s, TRUE)
                        ON CONFLICT DO NOTHING
                        RETURNING id
                        """,
                        (challenge["key"], challenge["description"],
                         challenge["target"], challenge["xp"], challenge["gold"], today)
                    )
                    row = cur.fetchone()
                    if row:
                        new_challenge_ids.append(str(row["id"]))

                results["new_challenges"] = len(new_challenge_ids)
                logger.info("Created %d new daily challenges for %s", len(new_challenge_ids), today)

                # 4. Reset daily streaks for players who didn't log in yesterday
                cur.execute(
                    """
                    UPDATE players
                    SET login_streak = 0
                    WHERE last_seen_at < NOW() - INTERVAL '1 day 6 hours'
                      AND login_streak > 0
                    """
                )
                results["streaks_reset"] = cur.rowcount

        conn.close()

        # 5. Clear Redis caches that depend on daily state
        keys_to_clear = [
            "daily:challenges",
            "daily:shop:stock",
            "lb:daily:*",
        ]
        for pattern in keys_to_clear:
            if "*" in pattern:
                matching = r.keys(pattern)
                if matching:
                    r.delete(*matching)
            else:
                r.delete(pattern)

        # 6. Cache today's challenges in Redis for fast API response
        r.setex(
            "daily:challenges",
            86400,  # 24h TTL
            json.dumps({"date": today, "challenges": todays_challenges})
        )

        # 7. Generate rotating shop stock (seeded by date)
        shop_stock = _generate_shop_stock(today)
        r.setex("daily:shop:stock", 86400, json.dumps(shop_stock))
        results["shop_items"] = len(shop_stock)

        # 8. Publish reset event to SNS for other services
        if SNS_TOPIC_ARN:
            sns_client.publish(
                TopicArn=SNS_TOPIC_ARN,
                Subject="DailyReset",
                Message=json.dumps({
                    "event":   "daily_reset",
                    "date":    today,
                    "results": results
                })
            )

        logger.info("Daily reset complete: %s", json.dumps(results))
        return {"statusCode": 200, "body": json.dumps(results)}

    except Exception as e:
        logger.exception("Daily reset failed: %s", str(e))
        return {"statusCode": 500, "body": json.dumps({"error": str(e)})}


def _generate_shop_stock(date_str: str) -> list:
    """Generate rotating merchant stock seeded by date for consistency."""
    random.seed(date_str + "shop")

    ALL_ITEMS = [
        {"id": "health_potion",   "price": 18,  "qty": 10},
        {"id": "mana_potion",     "price": 18,  "qty": 10},
        {"id": "strength_elixir", "price": 60,  "qty": 3},
        {"id": "iron_ingot",      "price": 8,   "qty": 20},
        {"id": "steel_ingot",     "price": 25,  "qty": 10},
        {"id": "moonstone",       "price": 180, "qty": 2},
        {"id": "sharpening_stone","price": 6,   "qty": 15},
        {"id": "iron_sword",      "price": 75,  "qty": 1},
        {"id": "leather_armor",   "price": 55,  "qty": 1},
        {"id": "chainmail",       "price": 150, "qty": 1},
        {"id": "stamina_herb",    "price": 10,  "qty": 8},
        {"id": "wheat_seed",      "price": 4,   "qty": 20},
    ]

    # Always stock potions; randomly rotate the rest
    always = ALL_ITEMS[:3]
    rotating = random.sample(ALL_ITEMS[3:], k=5)
    return always + rotating
