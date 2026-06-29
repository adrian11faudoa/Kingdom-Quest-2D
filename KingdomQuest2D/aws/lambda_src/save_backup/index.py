# =============================================================================
# Kingdom Quest 2D — Lambda: save_backup/index.py
# Runs every 6 hours via EventBridge.
# Verifies save file integrity and creates versioned backup copies.
# =============================================================================

import json
import os
import hashlib
import boto3
import psycopg2
import psycopg2.extras
import logging
from datetime import datetime, timezone

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3_client      = boto3.client("s3")
secrets_client = boto3.client("secretsmanager")

DB_SECRET_ARN  = os.environ["DB_SECRET_ARN"]


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


def compute_checksum(data: bytes) -> str:
    return hashlib.md5(data).hexdigest()


def handler(event, context):
    logger.info("Save backup starting: %s", datetime.now(timezone.utc).isoformat())

    results = {
        "verified": 0,
        "backed_up": 0,
        "corrupted": 0,
        "missing": 0,
        "errors": []
    }

    try:
        creds = get_db_credentials()
        conn  = get_db_connection(creds)

        with conn:
            with conn.cursor(cursor_factory=psycopg2.extras.DictCursor) as cur:
                # Fetch all save records updated in the last 7 hours (with overlap)
                cur.execute(
                    """
                    SELECT ps.id, ps.player_id, ps.slot, ps.s3_key,
                           ps.checksum, ps.file_size, ps.updated_at,
                           p.cognito_sub, p.username
                    FROM player_saves ps
                    JOIN players p ON ps.player_id = p.id
                    WHERE ps.updated_at > NOW() - INTERVAL '7 hours'
                    ORDER BY ps.updated_at DESC
                    LIMIT 1000
                    """
                )
                saves = cur.fetchall()
                logger.info("Processing %d save records", len(saves))

                for save in saves:
                    s3_key    = save["s3_key"]
                    save_id   = save["id"]
                    slot      = save["slot"]
                    player_id = save["player_id"]

                    # Determine which bucket from the key prefix
                    # Keys are: saves/{cognito_sub}/slot_{n}.json
                    bucket = _get_saves_bucket()

                    try:
                        # Read the save file from S3
                        resp = s3_client.get_object(Bucket=bucket, Key=s3_key)
                        data = resp["Body"].read()

                        if len(data) == 0:
                            logger.warning("Empty save file: %s", s3_key)
                            results["corrupted"] += 1
                            continue

                        # Verify JSON is parseable
                        try:
                            json.loads(data)
                        except json.JSONDecodeError:
                            logger.error("Corrupt JSON in save: %s", s3_key)
                            results["corrupted"] += 1
                            cur.execute(
                                "UPDATE player_saves SET is_corrupted = TRUE WHERE id = %s",
                                (save_id,)
                            )
                            continue

                        # Compute and store checksum
                        checksum = compute_checksum(data)
                        file_size = len(data)

                        if save["checksum"] and save["checksum"] != checksum:
                            logger.warning(
                                "Checksum mismatch for save %s (expected %s, got %s)",
                                s3_key, save["checksum"], checksum
                            )

                        # Update metadata in DB
                        cur.execute(
                            """
                            UPDATE player_saves
                            SET checksum = %s, file_size = %s
                            WHERE id = %s
                            """,
                            (checksum, file_size, save_id)
                        )
                        results["verified"] += 1

                        # Create versioned backup copy
                        timestamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
                        backup_key = f"backups/{player_id}/slot_{slot}/{timestamp}.json"

                        s3_client.copy_object(
                            Bucket=bucket,
                            CopySource={"Bucket": bucket, "Key": s3_key},
                            Key=backup_key,
                            StorageClass="STANDARD_IA",  # Cheaper for backups
                            MetadataDirective="COPY",
                        )
                        results["backed_up"] += 1

                    except s3_client.exceptions.NoSuchKey:
                        logger.warning("Save file missing in S3: %s", s3_key)
                        results["missing"] += 1

                    except Exception as e:
                        logger.exception("Error processing save %s: %s", s3_key, str(e))
                        results["errors"].append(str(e))

        conn.close()

    except Exception as e:
        logger.exception("Save backup lambda failed: %s", str(e))
        results["errors"].append(str(e))

    logger.info("Save backup complete: %s", json.dumps(results))
    return {
        "statusCode": 200 if not results["errors"] else 207,
        "body": json.dumps(results)
    }


def _get_saves_bucket() -> str:
    """Derive bucket name from environment variables set by Terraform."""
    env = os.environ.get("ENVIRONMENT", "dev")
    account_id = boto3.client("sts").get_caller_identity()["Account"]
    return f"kq2d-{env}-player-saves-{account_id}"
