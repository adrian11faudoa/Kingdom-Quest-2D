-- =============================================================================
-- Kingdom Quest 2D — PostgreSQL Schema
-- Run once on a fresh database:
--   psql -h <endpoint> -U kq2d_admin -d kingdom_quest -f schema.sql
-- =============================================================================

-- ── Extensions ────────────────────────────────────────────────────────────────

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";    -- UUID generation
CREATE EXTENSION IF NOT EXISTS "pg_stat_statements"; -- Query monitoring

-- ── Players ───────────────────────────────────────────────────────────────────

CREATE TABLE players (
  id                  UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  cognito_sub         TEXT UNIQUE NOT NULL,          -- Cognito user sub (immutable)
  username            TEXT UNIQUE,                   -- Display name (mutable)

  -- Core progression
  level               INT  NOT NULL DEFAULT 1 CHECK (level BETWEEN 1 AND 50),
  xp                  INT  NOT NULL DEFAULT 0 CHECK (xp >= 0),
  skill_points        INT  NOT NULL DEFAULT 0 CHECK (skill_points >= 0),
  gold                INT  NOT NULL DEFAULT 0 CHECK (gold >= 0),

  -- Stats for leaderboards
  kills               INT  NOT NULL DEFAULT 0,
  deaths              INT  NOT NULL DEFAULT 0,
  quests_completed    INT  NOT NULL DEFAULT 0,
  bosses_defeated     INT  NOT NULL DEFAULT 0,
  play_time_seconds   BIGINT NOT NULL DEFAULT 0,

  -- Metadata
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_seen_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  is_banned           BOOLEAN NOT NULL DEFAULT FALSE,
  ban_reason          TEXT
);

CREATE INDEX idx_players_cognito_sub ON players (cognito_sub);
CREATE INDEX idx_players_level       ON players (level DESC);
CREATE INDEX idx_players_kills       ON players (kills DESC);
CREATE INDEX idx_players_gold        ON players (gold DESC);
CREATE INDEX idx_players_playtime    ON players (play_time_seconds DESC);

-- ── Player Cloud Saves ────────────────────────────────────────────────────────

CREATE TABLE player_saves (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  player_id    UUID NOT NULL REFERENCES players(id) ON DELETE CASCADE,
  slot         INT  NOT NULL CHECK (slot BETWEEN 1 AND 5),
  s3_key       TEXT NOT NULL,
  file_size    INT,
  checksum     TEXT,    -- MD5 for integrity verification
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  UNIQUE (player_id, slot)
);

CREATE INDEX idx_player_saves_player_id ON player_saves (player_id);

-- ── Achievements ──────────────────────────────────────────────────────────────

CREATE TABLE achievements (
  id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  key         TEXT UNIQUE NOT NULL,   -- e.g. "first_boss_kill"
  name        TEXT NOT NULL,
  description TEXT,
  icon_url    TEXT,
  xp_reward   INT NOT NULL DEFAULT 0,
  is_hidden   BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE player_achievements (
  player_id     UUID NOT NULL REFERENCES players(id) ON DELETE CASCADE,
  achievement_id UUID NOT NULL REFERENCES achievements(id),
  unlocked_at   TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  PRIMARY KEY (player_id, achievement_id)
);

-- ── Faction Reputations ───────────────────────────────────────────────────────

CREATE TABLE player_factions (
  player_id   UUID NOT NULL REFERENCES players(id) ON DELETE CASCADE,
  faction_id  TEXT NOT NULL,
  reputation  INT  NOT NULL DEFAULT 0 CHECK (reputation BETWEEN -1000 AND 1000),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT NOW(),

  PRIMARY KEY (player_id, faction_id)
);

-- ── Discovered World Map Regions ──────────────────────────────────────────────

CREATE TABLE player_map_discovery (
  player_id    UUID NOT NULL REFERENCES players(id) ON DELETE CASCADE,
  region_id    TEXT NOT NULL,
  discovered_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  fast_travel_unlocked BOOLEAN NOT NULL DEFAULT FALSE,

  PRIMARY KEY (player_id, region_id)
);

-- ── Analytics Events ──────────────────────────────────────────────────────────

CREATE TABLE analytics_events (
  id           UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  player_id    UUID REFERENCES players(id) ON DELETE SET NULL,
  event_type   TEXT NOT NULL,
  properties   JSONB DEFAULT '{}',
  created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
) PARTITION BY RANGE (created_at);  -- Partition by month for retention management

-- Create initial partitions
CREATE TABLE analytics_events_2024_01 PARTITION OF analytics_events
  FOR VALUES FROM ('2024-01-01') TO ('2024-02-01');
-- Add future partitions via a scheduled job or add them manually monthly

CREATE INDEX idx_analytics_events_type       ON analytics_events (event_type);
CREATE INDEX idx_analytics_events_player_id  ON analytics_events (player_id);
CREATE INDEX idx_analytics_events_created_at ON analytics_events (created_at);

-- ── Daily Challenges ──────────────────────────────────────────────────────────

CREATE TABLE daily_challenges (
  id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  challenge_key TEXT NOT NULL,
  description   TEXT NOT NULL,
  target_value  INT NOT NULL,
  xp_reward     INT NOT NULL DEFAULT 0,
  gold_reward   INT NOT NULL DEFAULT 0,
  active_date   DATE NOT NULL DEFAULT CURRENT_DATE,
  is_active     BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE player_challenge_progress (
  player_id     UUID NOT NULL REFERENCES players(id) ON DELETE CASCADE,
  challenge_id  UUID NOT NULL REFERENCES daily_challenges(id),
  progress      INT NOT NULL DEFAULT 0,
  completed     BOOLEAN NOT NULL DEFAULT FALSE,
  completed_at  TIMESTAMPTZ,
  date          DATE NOT NULL DEFAULT CURRENT_DATE,

  PRIMARY KEY (player_id, challenge_id, date)
);

-- ── Functions ─────────────────────────────────────────────────────────────────

-- Auto-update updated_at timestamps
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_players_updated_at
  BEFORE UPDATE ON players
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER trg_player_saves_updated_at
  BEFORE UPDATE ON player_saves
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- ── Seed Data ─────────────────────────────────────────────────────────────────

INSERT INTO achievements (key, name, description, xp_reward, is_hidden) VALUES
  ('first_kill',      'First Blood',        'Defeat your first enemy',              50,  FALSE),
  ('level_10',        'Rising Hero',         'Reach level 10',                      200, FALSE),
  ('level_50',        'Legend',              'Reach the maximum level',             1000, FALSE),
  ('first_boss',      'Boss Slayer',         'Defeat your first dungeon boss',       300, FALSE),
  ('all_bosses',      'Champion of Aether',  'Defeat every boss in the game',       2000, FALSE),
  ('fisherman',       'Patient Angler',      'Catch 50 fish',                        150, FALSE),
  ('legendary_fish',  'The Big One',         'Catch a Legendary fish',              500, TRUE),
  ('first_craft',     'Craftsman',           'Craft your first item',                100, FALSE),
  ('fully_upgraded',  'Master Smith',        'Fully upgrade any weapon',            500, FALSE),
  ('explorer',        'World Walker',        'Discover all regions of the world',   800, FALSE),
  ('secret_finder',   'Treasure Hunter',     'Find 10 hidden secrets',              400, TRUE),
  ('no_death_boss',   'Untouchable',         'Defeat a boss without taking damage', 1000, TRUE);
