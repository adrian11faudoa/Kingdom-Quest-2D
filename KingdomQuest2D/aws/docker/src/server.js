// =============================================================================
// Kingdom Quest 2D — Game API Server (src/server.js)
// Handles: auth validation, player data, cloud saves, leaderboards, analytics.
// Uses AWS SDK v3 (modular imports) for minimal cold-start bundle size.
// =============================================================================

'use strict';

const express       = require('express');
const cors          = require('cors');
const helmet        = require('helmet');
const compression   = require('compression');
const rateLimit     = require('express-rate-limit');
const AWSXRay       = require('aws-xray-sdk-core');
const http          = require('http');

// ── AWS SDK ───────────────────────────────────────────────────────────────────

const { SecretsManagerClient, GetSecretValueCommand } = require('@aws-sdk/client-secrets-manager');
const { S3Client, PutObjectCommand, GetObjectCommand } = require('@aws-sdk/client-s3');
const { getSignedUrl }  = require('@aws-sdk/s3-request-presigner');
const Redis             = require('ioredis');

// ── Database ──────────────────────────────────────────────────────────────────

const { Pool } = require('pg');

// ── Auth ──────────────────────────────────────────────────────────────────────

const {
  CognitoJwtVerifier
} = require('aws-jwt-verify');

// =============================================================================
// Bootstrap
// =============================================================================

const app  = express();
const PORT = process.env.PORT || 8080;

// X-Ray tracing middleware (wraps all HTTP calls)
if (process.env.NODE_ENV === 'production') {
  AWSXRay.captureHTTPsGlobal(http);
}

// ── Database Pool ─────────────────────────────────────────────────────────────

let db;
async function initDatabase() {
  const secretsClient = new SecretsManagerClient({ region: process.env.AWS_REGION });
  const secret = await secretsClient.send(
    new GetSecretValueCommand({ SecretId: process.env.DB_SECRET_ARN })
  );
  const creds = JSON.parse(secret.SecretString);

  db = new Pool({
    host:     creds.host     || process.env.DB_HOST,
    port:     creds.port     || 5432,
    database: creds.dbname   || process.env.DB_NAME,
    user:     creds.username || process.env.DB_USER,
    password: creds.password,
    max:      20,           // Max connections in pool
    idleTimeoutMillis: 30000,
    connectionTimeoutMillis: 2000,
    ssl: { rejectUnauthorized: false }
  });

  // Warm up pool
  const client = await db.connect();
  await client.query('SELECT 1');
  client.release();
  console.log('[DB] Connected to PostgreSQL');
}

// ── Redis Client ──────────────────────────────────────────────────────────────

let redis;
function initRedis() {
  redis = new Redis({
    host:              process.env.REDIS_ENDPOINT,
    port:              6379,
    tls:               {},          // ElastiCache TLS
    retryStrategy:     (times) => Math.min(times * 200, 5000),
    lazyConnect:       true,
    maxRetriesPerRequest: 3,
  });
  redis.on('ready',   () => console.log('[Redis] Connected'));
  redis.on('error',   (err) => console.error('[Redis] Error:', err.message));
  return redis.connect();
}

// ── Cognito JWT Verifier ──────────────────────────────────────────────────────

let verifier;
function initAuth() {
  verifier = CognitoJwtVerifier.create({
    userPoolId:  process.env.COGNITO_USER_POOL_ID,
    tokenUse:    'access',
    clientId:    process.env.COGNITO_CLIENT_ID,
  });
}

// ── S3 Client ─────────────────────────────────────────────────────────────────

const s3 = new S3Client({ region: process.env.AWS_REGION });

// =============================================================================
// Middleware
// =============================================================================

app.use(AWSXRay.express.openSegment('KingdomQuest2D-API'));

app.use(helmet({
  contentSecurityPolicy: false,  // Managed by CloudFront
  crossOriginEmbedderPolicy: false,
}));

app.use(compression());
app.use(express.json({ limit: '2mb' }));  // Save files won't exceed 2MB
app.use(cors({
  origin: [
    `https://${process.env.CDN_URL}`,
    'http://localhost:3000',  // Dev
    'http://localhost:6080',  // Godot editor export preview
  ],
  credentials: true,
}));

// Rate limiting — per IP
const apiLimiter = rateLimit({
  windowMs: 60 * 1000,   // 1 minute
  max:      120,          // 2 req/sec sustained burst
  standardHeaders: true,
  legacyHeaders:   false,
  message: { error: 'Too many requests, please slow down.' },
});
app.use('/api/', apiLimiter);

// Stricter limiter for auth-sensitive endpoints
const authLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,  // 15 minutes
  max:      20,
  message: { error: 'Too many auth attempts.' },
});

// ── Auth Middleware ────────────────────────────────────────────────────────────

async function requireAuth(req, res, next) {
  const authHeader = req.headers.authorization;
  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    return res.status(401).json({ error: 'Missing or invalid Authorization header' });
  }
  try {
    const token = authHeader.slice(7);
    const payload = await verifier.verify(token);
    req.playerId = payload.sub;
    req.username = payload.username || payload['cognito:username'];
    next();
  } catch (err) {
    return res.status(401).json({ error: 'Invalid or expired token' });
  }
}

// =============================================================================
// Routes
// =============================================================================

// ── Health ────────────────────────────────────────────────────────────────────

app.get('/health', async (req, res) => {
  const checks = { api: 'ok', db: 'unknown', redis: 'unknown' };
  try {
    await db.query('SELECT 1');
    checks.db = 'ok';
  } catch { checks.db = 'error'; }
  try {
    await redis.ping();
    checks.redis = 'ok';
  } catch { checks.redis = 'error'; }

  const allOk = Object.values(checks).every(v => v === 'ok');
  res.status(allOk ? 200 : 503).json({
    status: allOk ? 'healthy' : 'degraded',
    checks,
    version: process.env.npm_package_version || '0.1.0',
    uptime:  process.uptime(),
  });
});

// ── Player Profile ────────────────────────────────────────────────────────────

app.get('/api/v1/player/profile', requireAuth, async (req, res) => {
  try {
    const result = await db.query(
      `SELECT id, username, level, xp, gold, play_time_seconds,
              created_at, last_seen_at
       FROM players WHERE cognito_sub = $1`,
      [req.playerId]
    );
    if (result.rows.length === 0) {
      // First login — create profile
      const newPlayer = await db.query(
        `INSERT INTO players (cognito_sub, username)
         VALUES ($1, $2) RETURNING *`,
        [req.playerId, req.username]
      );
      return res.json({ player: newPlayer.rows[0], isNew: true });
    }
    // Update last seen
    await db.query(
      'UPDATE players SET last_seen_at = NOW() WHERE cognito_sub = $1',
      [req.playerId]
    );
    res.json({ player: result.rows[0], isNew: false });
  } catch (err) {
    console.error('[Profile] Error:', err);
    res.status(500).json({ error: 'Failed to load player profile' });
  }
});

app.put('/api/v1/player/profile', requireAuth, async (req, res) => {
  const { username } = req.body;
  if (!username || username.length < 3 || username.length > 24) {
    return res.status(400).json({ error: 'Username must be 3–24 characters' });
  }
  try {
    const result = await db.query(
      `UPDATE players SET username = $1, updated_at = NOW()
       WHERE cognito_sub = $2 RETURNING username`,
      [username.trim(), req.playerId]
    );
    res.json({ username: result.rows[0].username });
  } catch (err) {
    if (err.code === '23505') {  // Unique constraint violation
      return res.status(409).json({ error: 'Username already taken' });
    }
    res.status(500).json({ error: 'Failed to update profile' });
  }
});

// ── Cloud Saves ───────────────────────────────────────────────────────────────

// Upload save: API returns a presigned S3 PUT URL (client uploads directly)
app.post('/api/v1/player/save/upload-url', requireAuth, async (req, res) => {
  const { slot = 1 } = req.body;
  if (slot < 1 || slot > 5) {
    return res.status(400).json({ error: 'Invalid save slot (1–5)' });
  }
  const key = `saves/${req.playerId}/slot_${slot}.json`;
  try {
    const command = new PutObjectCommand({
      Bucket:      `${process.env.ASSETS_BUCKET}`,
      Key:         key,
      ContentType: 'application/json',
      Metadata:    { 'player-id': req.playerId, 'slot': String(slot) },
    });
    const url = await getSignedUrl(s3, command, { expiresIn: 300 });  // 5 min
    // Record save metadata in DB
    await db.query(
      `INSERT INTO player_saves (player_id, slot, s3_key, updated_at)
       VALUES ((SELECT id FROM players WHERE cognito_sub = $1), $2, $3, NOW())
       ON CONFLICT (player_id, slot) DO UPDATE
       SET s3_key = EXCLUDED.s3_key, updated_at = NOW()`,
      [req.playerId, slot, key]
    );
    res.json({ uploadUrl: url, key });
  } catch (err) {
    console.error('[Save] Upload URL error:', err);
    res.status(500).json({ error: 'Failed to generate upload URL' });
  }
});

// Download save: presigned GET URL
app.get('/api/v1/player/save/:slot', requireAuth, async (req, res) => {
  const slot = parseInt(req.params.slot);
  if (isNaN(slot) || slot < 1 || slot > 5) {
    return res.status(400).json({ error: 'Invalid slot' });
  }
  try {
    const result = await db.query(
      `SELECT s3_key, updated_at FROM player_saves
       WHERE player_id = (SELECT id FROM players WHERE cognito_sub = $1)
         AND slot = $2`,
      [req.playerId, slot]
    );
    if (result.rows.length === 0) {
      return res.status(404).json({ error: 'No save found for this slot' });
    }
    const { s3_key, updated_at } = result.rows[0];
    const command  = new GetObjectCommand({
      Bucket: process.env.ASSETS_BUCKET,
      Key:    s3_key,
    });
    const url = await getSignedUrl(s3, command, { expiresIn: 300 });
    res.json({ downloadUrl: url, updatedAt: updated_at });
  } catch (err) {
    console.error('[Save] Download URL error:', err);
    res.status(500).json({ error: 'Failed to generate download URL' });
  }
});

// List all save slots
app.get('/api/v1/player/saves', requireAuth, async (req, res) => {
  try {
    const result = await db.query(
      `SELECT slot, s3_key, updated_at FROM player_saves
       WHERE player_id = (SELECT id FROM players WHERE cognito_sub = $1)
       ORDER BY slot`,
      [req.playerId]
    );
    res.json({ saves: result.rows });
  } catch (err) {
    res.status(500).json({ error: 'Failed to list saves' });
  }
});

// ── Leaderboards ──────────────────────────────────────────────────────────────

app.get('/api/v1/leaderboard/:type', async (req, res) => {
  const { type } = req.params;
  const VALID_TYPES = ['level', 'kills', 'gold', 'playtime'];
  if (!VALID_TYPES.includes(type)) {
    return res.status(400).json({ error: `Invalid leaderboard type. Use: ${VALID_TYPES.join(', ')}` });
  }
  const page  = Math.max(1, parseInt(req.query.page) || 1);
  const limit = Math.min(50, parseInt(req.query.limit) || 20);
  const cacheKey = `lb:${type}:${page}:${limit}`;
  try {
    // Try cache first
    const cached = await redis.get(cacheKey);
    if (cached) {
      return res.json(JSON.parse(cached));
    }
    const result = await db.query(
      `SELECT username, ${type} as score, rank() OVER (ORDER BY ${type} DESC) as rank
       FROM players
       ORDER BY ${type} DESC
       LIMIT $1 OFFSET $2`,
      [limit, (page - 1) * limit]
    );
    const response = { type, page, limit, entries: result.rows };
    // Cache for 60 seconds
    await redis.setex(cacheKey, 60, JSON.stringify(response));
    res.json(response);
  } catch (err) {
    console.error('[Leaderboard] Error:', err);
    res.status(500).json({ error: 'Failed to fetch leaderboard' });
  }
});

// ── Game Progress Sync ────────────────────────────────────────────────────────

app.post('/api/v1/player/progress', requireAuth, async (req, res) => {
  const { level, xp, gold, kills, play_time_seconds } = req.body;
  try {
    await db.query(
      `UPDATE players SET
         level = GREATEST(level, $1),
         xp    = GREATEST(xp, $2),
         gold  = GREATEST(gold, $3),
         kills = GREATEST(kills, $4),
         play_time_seconds = GREATEST(play_time_seconds, $5),
         updated_at = NOW()
       WHERE cognito_sub = $6`,
      [level || 1, xp || 0, gold || 0, kills || 0, play_time_seconds || 0, req.playerId]
    );
    // Invalidate leaderboard cache
    const keys = await redis.keys('lb:*');
    if (keys.length > 0) await redis.del(...keys);
    res.json({ synced: true });
  } catch (err) {
    console.error('[Progress] Sync error:', err);
    res.status(500).json({ error: 'Failed to sync progress' });
  }
});

// ── Analytics / Telemetry ─────────────────────────────────────────────────────

app.post('/api/v1/analytics/event', requireAuth, async (req, res) => {
  const { event_type, properties = {} } = req.body;
  if (!event_type || typeof event_type !== 'string') {
    return res.status(400).json({ error: 'event_type required' });
  }
  try {
    await db.query(
      `INSERT INTO analytics_events (player_id, event_type, properties, created_at)
       VALUES ((SELECT id FROM players WHERE cognito_sub = $1), $2, $3, NOW())`,
      [req.playerId, event_type.slice(0, 100), JSON.stringify(properties)]
    );
    res.json({ recorded: true });
  } catch (err) {
    // Non-critical — don't fail the game over analytics
    console.warn('[Analytics] Insert error:', err.message);
    res.json({ recorded: false });
  }
});

// ── Error Handlers ────────────────────────────────────────────────────────────

app.use((req, res) => res.status(404).json({ error: 'Not found' }));

app.use((err, req, res, next) => {
  console.error('[Unhandled]', err);
  res.status(500).json({ error: 'Internal server error' });
});

app.use(AWSXRay.express.closeSegment());

// =============================================================================
// Start
// =============================================================================

async function start() {
  try {
    await initDatabase();
    await initRedis();
    initAuth();

    const server = app.listen(PORT, '0.0.0.0', () => {
      console.log(`[API] Kingdom Quest 2D API running on port ${PORT} (${process.env.NODE_ENV})`);
    });

    // Graceful shutdown
    const shutdown = async (signal) => {
      console.log(`[API] ${signal} received — shutting down gracefully`);
      server.close(async () => {
        await db.end();
        redis.disconnect();
        console.log('[API] Server closed');
        process.exit(0);
      });
      setTimeout(() => { console.error('[API] Forced shutdown'); process.exit(1); }, 10000);
    };

    process.on('SIGTERM', () => shutdown('SIGTERM'));
    process.on('SIGINT',  () => shutdown('SIGINT'));

  } catch (err) {
    console.error('[API] Failed to start:', err);
    process.exit(1);
  }
}

start();
