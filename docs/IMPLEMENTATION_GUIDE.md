# AetherQuest — Complete Implementation Guide
## Godot 4.x Action RPG Architecture

---

## TABLE OF CONTENTS

1. [Architecture Philosophy](#architecture)
2. [Folder Structure](#folder-structure)
3. [Implementation Order](#implementation-order)
4. [Scene Setup Instructions](#scene-setup)
5. [Tilemap Setup Guide](#tilemap)
6. [Placeholder Asset Guide](#assets)
7. [System Interaction Map](#system-map)
8. [Optimization Recommendations](#optimization)
9. [Future Expansion Ideas](#expansion)
10. [Troubleshooting](#troubleshooting)

---

## 1. ARCHITECTURE PHILOSOPHY <a name="architecture"></a>

### Core Principles

**Composition over Inheritance**
Rather than a deep class hierarchy (`Entity → Character → Player`), entities are
composed from interchangeable components (`StatsComponent`, `LevelSystem`, etc.).
This makes it easy to add stats to an NPC or a breakable barrel without inheriting
from a monolithic base class.

**Event Bus Pattern**
All cross-system communication flows through `EventBus.gd`. Systems emit signals
when something happens; other systems listen. No system holds a hard reference to
another unrelated system. This means:
- Removing a system never breaks others
- Adding new listeners is a 1-line change
- The event log traces every interaction for debugging

**Data-Driven Content**
Game content (items, enemies, quests, dialogues) lives in JSON files under
`assets/data/`. This means:
- Designers add content without touching GDScript
- Modders can override data files without recompiling
- Balance iteration is fast (edit JSON, restart game)

**Autoloads: Minimum Necessary**
Only 8 autoloads exist. Each is justified:
- `GameManager` – global state machine (must be universal)
- `EventBus` – signal routing (must be universally accessible)
- `SaveManager` – save/load coordination (must survive scene changes)
- `DataManager` – static data cache (loaded once, read everywhere)
- `AudioManager` – music crossfade requires persistence across scenes
- `InputManager` – unified input abstraction (used everywhere)
- `SceneTransition` – fade overlay must persist during scene loads
- `ObjectPool` – pool nodes must survive scene changes

---

## 2. FOLDER STRUCTURE <a name="folder-structure"></a>

```
AetherQuest/
└── project/
    ├── project.godot
    ├── addons/                    # Third-party plugins
    ├── assets/
    │   ├── art/
    │   │   ├── characters/
    │   │   │   ├── player/        # Player sprite sheets (32×48 recommended)
    │   │   │   ├── enemies/       # Enemy sprite sheets
    │   │   │   └── npcs/          # NPC sprites + portrait PNGs
    │   │   ├── environment/
    │   │   │   ├── tilesets/      # TileSet resources (.tres)
    │   │   │   ├── props/         # Decorative objects
    │   │   │   └── effects/       # Particle textures, VFX
    │   │   └── ui/
    │   │       ├── hud/           # Health bar sprites, frames
    │   │       ├── menus/         # Background art, logos
    │   │       └── icons/         # Item, skill, status icons (16×16 or 32×32)
    │   ├── audio/
    │   │   ├── music/             # .ogg Vorbis music tracks
    │   │   ├── sfx/               # .ogg one-shot sound effects
    │   │   └── ambient/           # .ogg looping ambient sounds
    │   ├── data/
    │   │   ├── items/             # items.json (one file or split by category)
    │   │   ├── enemies/           # enemies.json
    │   │   ├── quests/            # quests.json
    │   │   ├── dialogue/          # one JSON file per dialogue tree
    │   │   ├── skills/            # skills.json
    │   │   └── recipes/           # recipes.json
    │   ├── fonts/                 # .ttf pixel fonts
    │   └── shaders/               # .gdshader files
    ├── scenes/
    │   ├── world/
    │   │   ├── regions/           # Named region scenes (StartingVillage.tscn, etc.)
    │   │   ├── dungeons/          # Dungeon scenes
    │   │   └── chunks/            # Streamed world chunks (chunk_X_Y.tscn)
    │   ├── ui/
    │   │   ├── menus/             # MainMenu.tscn, PauseMenu.tscn, Credits.tscn
    │   │   ├── hud/               # HUD.tscn, DamageNumber.tscn, ItemSlot.tscn
    │   │   └── dialogue/          # DialogueUI.tscn, ChoiceButton.tscn
    │   ├── entities/
    │   │   ├── player/            # Player.tscn
    │   │   ├── enemies/           # Goblin.tscn, Wolf.tscn, etc.
    │   │   ├── npcs/              # ElderMira.tscn, Merchant.tscn, etc.
    │   │   ├── companions/        # FoxCompanion.tscn, etc.
    │   │   ├── projectiles/       # Arrow.tscn, MagicBolt.tscn
    │   │   └── world/             # LootDrop.tscn, Chest.tscn, FarmPlot.tscn
    │   └── systems/               # HitParticle.tscn, DamageNumber.tscn
    ├── scripts/
    │   ├── autoloads/             # 8 autoload singletons
    │   ├── player/                # Player.gd, LevelSystem.gd, SkillTree.gd
    │   ├── enemies/               # EnemyBase.gd, EnemyArchetypes.gd, BossBase.gd
    │   ├── combat/                # HitboxComponent.gd, HurtboxComponent.gd
    │   ├── systems/
    │   │   ├── inventory/         # InventorySystem.gd
    │   │   ├── quest/             # QuestSystem.gd
    │   │   ├── dialogue/          # DialogueSystem.gd
    │   │   ├── save/              # (logic in autoloads/SaveManager.gd)
    │   │   ├── crafting/          # CraftingSystem.gd
    │   │   ├── daynight/          # DayNightSystem.gd
    │   │   └── worldgen/          # WorldStreamer.gd
    │   ├── ui/                    # HUD.gd, InventoryUI.gd, QuestJournalUI.gd, etc.
    │   ├── utils/                 # Helper functions, extensions
    │   └── resources/             # StatsComponent.gd, custom Resource types
    └── locale/                    # Translation files (.csv or .po)
```

---

## 3. IMPLEMENTATION ORDER <a name="implementation-order"></a>

Follow this order to always have a runnable game at each step:

### Phase 1 — Core Loop (Week 1–2)
1. ✅ Project setup, input map, autoloads
2. ✅ `EventBus.gd` — wire up signals
3. ✅ `StatsComponent.gd` — health/mana/stamina
4. ✅ `Player.gd` — movement, state machine
5. Create `Player.tscn` with all required child nodes
6. Create placeholder region scene with a TileMap
7. ✅ `HUD.gd` — bare vitals display
8. Verify: player walks around, HUD shows health

### Phase 2 — Combat (Week 2–3)
9. `HitboxComponent.gd`, `HurtboxComponent.gd`
10. ✅ `EnemyBase.gd` with Goblin data
11. Create `Goblin.tscn`
12. ✅ `ObjectPool.gd` + Arrow/MagicBolt scenes
13. ✅ Combo attacks, dodge i-frames
14. ✅ `LootDrop.gd`, `Chest.gd`
15. Verify: full combat loop works

### Phase 3 — Data & Progression (Week 3–4)
16. ✅ `DataManager.gd` loading JSON
17. ✅ All JSON data files
18. ✅ `InventorySystem.gd`
19. ✅ `LevelSystem.gd`, `SkillTree.gd`
20. ✅ `InventoryUI.gd`, `QuestJournalUI.gd`
21. Verify: pick up items, level up, equip gear

### Phase 4 — World (Week 4–5)
22. ✅ `QuestSystem.gd`
23. ✅ `DialogueSystem.gd` + `DialogueUI.gd`
24. ✅ `NPCController.gd` — schedules + dialogue
25. ✅ `DayNightSystem.gd`
26. ✅ `WorldStreamer.gd`
27. Build 4+ world chunk scenes
28. Verify: NPCs talk, day changes, world streams

### Phase 5 — Systems (Week 5–6)
29. ✅ `CraftingSystem.gd`
30. ✅ `FishingMinigame.gd`
31. ✅ `FarmingSystem.gd`
32. ✅ `FactionSystem.gd`
33. ✅ `CompanionSystem.gd` + `CompanionAI.gd`
34. ✅ `BossBase.gd` — first boss scene
35. Verify: all systems integrated

### Phase 6 — Polish (Week 6–8)
36. ✅ `SaveManager.gd` with all systems registered
37. Settings persistence
38. Particle effects, camera shake
39. Minimap
40. World map screen
41. Sound pass — all SFX connected
42. Controller support testing

---

## 4. SCENE SETUP INSTRUCTIONS <a name="scene-setup"></a>

### Player.tscn

```
Player (CharacterBody2D)                 script: scripts/player/Player.gd
├── CollisionShape2D                     shape: CapsuleShape2D (8×14px)
├── AnimatedSprite2D      [sprite]       frames: player_frames.tres
├── StatsComponent        [Node]         script: scripts/resources/StatsComponent.gd
├── LevelSystem           [Node]         script: scripts/player/LevelSystem.gd
├── InventorySystem       [Node]         script: scripts/systems/inventory/InventorySystem.gd
│                                        groups: ["inventory"]
├── SkillTree             [Node]         script: scripts/player/SkillTree.gd
├── CompanionSystem       [Node]         script: scripts/systems/CompanionSystem.gd
├── HitboxComponent       [Area2D]       collision_layer: 6 (projectiles)
│   └── CollisionShape2D               shape: RectangleShape2D (sword arc)
├── HurtboxComponent      [Area2D]       collision_layer: 2 (player)
│   └── CollisionShape2D               shape: CapsuleShape2D
├── InteractionArea       [Area2D]       collision_mask: 4 (npcs) + 7 (interactables)
│   └── CollisionShape2D               shape: CircleShape2D radius: 32
├── ComboResetTimer       [Timer]        one_shot: true
├── DodgeCooldownTimer    [Timer]        one_shot: true
├── InvincibilityTimer    [Timer]        one_shot: true
└── CameraArm             [Node2D]
    └── Camera2D                         zoom: (2, 2) for pixel art
```

### Goblin.tscn (repeat pattern for all enemies)

```
Goblin (CharacterBody2D)                 script: scripts/enemies/EnemyBase.gd
│                                        enemy_id: "goblin"
├── CollisionShape2D
├── AnimatedSprite2D
├── StatsComponent
├── NavigationAgent2D                    max_speed: 110, path_desired_distance: 4
├── HitboxComponent       [Area2D]       sets damage meta in script
│   └── CollisionShape2D
├── HurtboxComponent      [Area2D]       collision_layer: 3 (enemies)
│   └── CollisionShape2D
├── DetectionArea         [Area2D]       collision_mask: 2 (player)
│   └── CollisionShape2D               radius: 150 (matches detect_radius)
├── AttackArea            [Area2D]       collision_mask: 2 (player)
│   └── CollisionShape2D               radius: 40
├── LootTableComponent    [Node]         script: scripts/systems/LootDrop.gd
├── StaggerTimer          [Timer]        one_shot: true
└── AttackTimer           [Timer]        one_shot: true
```

### World Region Scene (e.g., StartingVillage.tscn)

```
StartingVillage (Node2D)
├── WorldEnvironment                     environment.tres (sky, ambient light)
├── DayNightSystem        [Node]         script: systems/daynight/DayNightSystem.gd
│                                        groups: ["daynight"]
├── CanvasModulate        [CanvasModulate] referenced by DayNightSystem
├── TileMapLayer          [TileMapLayer]  ground layer, tile_set: village_tileset.tres
├── TileMapLayer          [TileMapLayer]  collision layer (walls, impassable)
├── TileMapLayer          [TileMapLayer]  detail/overlay layer
├── NavigationRegion2D                   bake navmesh after placing tiles
│   └── [all walkable area covered]
├── Entities              [Node2D]        parent for NPCs / enemies in this region
│   ├── ElderMira.tscn    (instance)
│   ├── MerchantTomlin.tscn (instance)
│   └── ...
├── Interactables         [Node2D]
│   ├── Chest.tscn        (instance)
│   └── ...
├── QuestSystem           [Node]         script: systems/quest/QuestSystem.gd
│                                        groups: ["quest_system"]
├── DialogueSystem        [Node]         script: systems/dialogue/DialogueSystem.gd
│                                        groups: ["dialogue_system"]
├── WorldStreamer         [Node]         script: systems/worldgen/WorldStreamer.gd
├── Player.tscn           (instance)     spawned at startup OR by SceneTransition
└── HUD.tscn              (CanvasLayer instance)
```

---

## 5. TILEMAP SETUP GUIDE <a name="tilemap"></a>

### Recommended Tile Sizes
- **Overworld tiles**: 16×16 px
- **Interior tiles**: 16×16 px
- **Character sprites**: 16×32 or 16×48 px (with animations)

### Creating a TileSet in Godot 4

1. Create a new `TileSet` resource (`New → TileSet`)
2. Add your tileset PNG as a source (`Add Source → Atlas`)
3. Set tile size to 16×16
4. **Physics Layers**: Add a physics layer for collision
   - Select tiles that are walls/obstacles
   - Paint collision polygons on each
5. **Navigation Layers**: Add a navigation layer
   - Paint navigation polygons on walkable tiles only
6. **Custom Data Layers**: Add `terrain_type: String` for biome-aware logic

### Collision Layers for Tiles
- Layer 1 = World (solid ground/walls) — TileMap collision
- Layer 2 = Player
- Layer 3 = Enemies
- Layer 7 = Interactables

### Navigation Mesh Setup
1. Add a `NavigationRegion2D` to your scene
2. Create a `NavigationPolygon` resource
3. Draw the walkable boundary polygon
4. Add obstacle polygons for all solid tiles
5. Bake: `NavigationRegion2D → Bake NavigationPolygon`
6. For dynamic navmesh updates (breakable walls), call `bake_navigation_polygon()` after changes

### World Chunk Size Recommendation
- Chunk = 32×32 tiles = 512×512 pixels
- Load radius = 3 chunks = renders up to 7×7 chunk area = 3584×3584 px viewport
- Adjust `WorldStreamer.chunk_size` if performance differs

---

## 6. PLACEHOLDER ASSET GUIDE <a name="assets"></a>

### Quick Placeholder Sprites (for development)

Create a single 256×256 PNG (`placeholder_sheet.png`) with:
- Row 0 (y=0): Player walk down (4 frames × 16px)
- Row 1 (y=16): Player walk up
- Row 2 (y=32): Player walk right (flip for left)
- Row 3 (y=48): Player idle
- Row 4 (y=64): Player attack

Use solid color rectangles in different hues:
- Player: blue
- Enemies: red/orange
- NPCs: green
- Items: yellow
- UI: grey tones

### AnimatedSprite2D Frame Setup
1. Select `AnimatedSprite2D`, open `frames` property
2. Create `SpriteFrames` resource
3. Add animation "idle_down", "walk_down", "attack_1", etc.
4. For each animation, add frames from your spritesheet
5. Set FPS (idle: 4, walk: 8, attack: 12)

### Required Animations Per Character
**Player**: idle_{dir}, walk_{dir}, run_{dir}, attack_1, attack_2, attack_3,
            bow_aim, cast, dodge, hurt, death
**Enemies**: idle, walk, attack, hurt, death, (charge_windup for tank)
**NPCs**: idle, walk, (talk optional)

---

## 7. SYSTEM INTERACTION MAP <a name="system-map"></a>

```
Player ─────────────────────→ EventBus ←──────────────── Enemy
  │  combat/movement events     │        killed/hurt signals  │
  │                             │                             │
  ↓                             ↓                             ↓
StatsComponent           QuestSystem              LootDrop (pooled)
LevelSystem              DialogueSystem           Chest
InventorySystem          FactionSystem            AudioManager
SkillTree                DayNightSystem
CompanionSystem          WorldStreamer
                         SaveManager ←── all systems register save/load
                         DataManager ←── all systems read item/enemy data
```

---

## 8. OPTIMIZATION RECOMMENDATIONS <a name="optimization"></a>

### Rendering
- Enable **2D Snap** in Project Settings (already done in project.godot)
- Use **CanvasGroup** to batch-render HUD elements
- Set camera limits to avoid rendering outside world bounds
- Use **Visibility Notifier2D** on distant enemies to pause processing

### Physics
- Set `NavigationAgent2D.max_neighbors` to 10 (default 10 is fine)
- Avoid per-frame `get_overlapping_bodies()` — use signal-based detection instead
- Use `call_deferred()` for physics-affecting code inside `_physics_process`

### Object Pooling
- All projectiles, damage numbers, particles, and loot drops use `ObjectPool`
- Pre-warm pool sizes in `ObjectPool.PRELOAD_CONFIG` to match max expected count
- Never `queue_free()` pooled nodes — always call `ObjectPool.release(node)`

### World Streaming
- Keep `LOAD_RADIUS = 3` and `RENDER_RADIUS = 4` as starting values
- Increase if world feels "pop-in"; decrease on low-spec targets
- Chunk scenes should not contain heavy scripts — keep entities sparse per chunk
- Bake `NavigationRegion2D` at edit-time, not runtime

### Memory
- Use `StringName` (`&"id"`) instead of `String` for all IDs — 0 allocations on comparison
- Cache `get_node()` calls in `@onready` vars
- Use typed arrays (`Array[StringName]`) where possible

### Profiling Workflow
1. Run with `--profiling` flag or use Godot's built-in profiler
2. Target: `_physics_process` < 2ms per frame at 60 fps
3. Common culprits: per-frame `get_tree().get_nodes_in_group()` → cache results
4. Use `VisibleOnScreenNotifier2D` to stop enemy AI when off-screen

---

## 9. FUTURE EXPANSION IDEAS <a name="expansion"></a>

### Content
- **Mount System**: `MountController.gd` — player rides a horse/griffin, 2× speed,
  new tilemap layer for mount-only paths
- **Procedural Dungeon Generator**: chunk-based BSP room generation,
  seeded RNG for reproducible dungeons
- **Seasonal Events**: extend `DayNightSystem` with a season enum;
  winter = snow biome spreads, summer = crop yield bonus
- **Multiplayer Co-op**: Godot 4's `MultiplayerSynchronizer` + `MultiplayerSpawner`
  — the event bus pattern already works well for state sync

### Mechanics
- **Stealth System**: visibility cone on enemies, crouch stance on player,
  shadow/light detection using `Light2D` influence
- **Alchemy Transmutation**: combine status effects (fire + ice = steam = blind)
- **Reputation Consequences**: hostile faction NPCs attack on sight,
  shops raise prices, dialogue options change
- **Dynamic Weather Events**: storms block certain paths, rain makes fire enemies
  weaker, fog reduces enemy detection radius

### Technical
- **Shader Pack**: rim lighting on characters, outline on hover,
  water ripple effect, CRT pixel filter toggle
- **Mod Loader**: scan `user://mods/` for additional JSON data directories,
  merge into DataManager caches at startup
- **Achievement System**: JSON-defined achievements, listened via EventBus,
  stored in save file
- **Localization**: Godot's built-in `tr()` + `.csv` translation tables

---

## 10. TROUBLESHOOTING <a name="troubleshooting"></a>

**Q: NavigationAgent2D not finding paths**
A: Ensure `NavigationRegion2D` is baked. Verify the agent's collision mask
   includes the navigation layer. Check that `NavigationServer2D` is enabled.

**Q: ObjectPool nodes not returning to pool**
A: Always call `ObjectPool.release(node)` — never `queue_free()` on pooled nodes.
   Check that the node has `set_meta("pooled", true)` set by the pool.

**Q: DataManager returns empty dictionaries**
A: Check file paths in `DATA_PATHS`. JSON must have an `"id"` field at root level
   or be an array of objects each with `"id"`. Run game in editor for warnings.

**Q: EventBus signal not received**
A: Verify the listener called `.connect()` before the signal was emitted.
   Use `EventBus.signal_name.connect(callable)` syntax (Godot 4).
   Check node is in scene tree when `_ready()` runs.

**Q: Save/load doesn't restore all state**
A: Ensure the system calls `SaveManager.register_system(get_save_data, apply_save_data)`
   in `_ready()`. Verify the dictionary key is unique across all systems.

**Q: Enemy pathfinding is janky**
A: Set `NavigationAgent2D.path_desired_distance` to 8–16 (not 4).
   Ensure navmesh has enough clearance for the agent's collision radius.
   Use `avoidance_enabled = true` only when needed (it's expensive).

**Q: Pixel art looks blurry**
A: In Project Settings → Rendering → Textures → Default Texture Filter: set to
   `Nearest`. Also verify `2D Snap` is enabled and camera zoom is integer (2×, 3×).
