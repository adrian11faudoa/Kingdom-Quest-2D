# =============================================================================
# Kingdom Quest 2D — Lambda: leaderboard_update/index.py
# Triggered by API Gateway or SNS when a player's stats change.
# Updates Redis Sorted Sets for real-time leaderboard queries.
# =============================================================================

import json
import os
import boto3
import redis
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

REDIS_ENDPOINT = os.environ["REDIS_ENDPOINT"]
REDIS_PORT     = int(os.environ.get("REDIS_PORT", 6379))

# Leaderboard key names in Redis (Sorted Sets)
LEADERBOARD_KEYS = {
    "level":     "lb:level",
    "kills":     "lb:kills",
    "gold":      "lb:gold",
    "playtime":  "lb:playtime",
}

_redis_client = None

def get_redis():
    global _redis_client
    if _redis_client is None:
        _redis_client = redis.Redis(
            host=REDIS_ENDPOINT,
            port=REDIS_PORT,
            ssl=True,
            decode_responses=True,
            socket_connect_timeout=3,
            socket_timeout=3,
        )
    return _redis_client


def handler(event, context):
    """
    Expected event body (from API or SNS):
    {
        "player_id": "uuid",
        "username":  "PlayerName",
        "level":     15,
        "kills":     234,
        "gold":      5000,
        "playtime":  18000
    }
    """
    logger.info("Leaderboard update event: %s", json.dumps(event))

    # Support both direct invocation and SNS trigger
    records = event.get("Records", [event])
    updated = 0

    r = get_redis()
    pipe = r.pipeline(transaction=False)  # Batch updates in one round trip

    for record in records:
        body = record
        if "Sns" in record:
            body = json.loads(record["Sns"]["Message"])
        elif "body" in record:
            body = json.loads(record["body"])

        player_id = body.get("player_id")
        username  = body.get("username", "Unknown")

        if not player_id:
            logger.warning("Missing player_id in record, skipping")
            continue

        # Update each leaderboard sorted set
        # ZADD key score member — score is the stat value, member is "uuid:username"
        member = f"{player_id}:{username}"

        for stat_key, redis_key in LEADERBOARD_KEYS.items():
            score = body.get(stat_key, 0)
            if score is not None:
                pipe.zadd(redis_key, {member: float(score)}, gt=True)  # Only update if greater

        # Store player display name separately for fast lookup
        pipe.hset("players:names", player_id, username)

        # Set TTL on leaderboards to force rebuild from DB if stale (24h)
        pipe.expire("lb:level",    86400)
        pipe.expire("lb:kills",    86400)
        pipe.expire("lb:gold",     86400)
        pipe.expire("lb:playtime", 86400)

        updated += 1

    pipe.execute()
    logger.info("Updated %d player leaderboard entries", updated)

    return {
        "statusCode": 200,
        "body": json.dumps({"updated": updated})
    }
