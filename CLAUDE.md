# GameSpice Achievements

Achievements as rules over per-player lifetime numbers: declared once, checkable without loading art, stored behind a pluggable store (memory, file, SQL), reported to the backbone in batches.

Read the family [CLAUDE.md](../../CLAUDE.md) first; this file is only what is specific to achievements.

**The distributable is `addons/dot_achievements/`.** It requires [GameSpice Core](../dot-core) and nothing else. dot-sql and dot-cloud are linked into `addons/` (gitignored) only for the suites; the addon reaches a SQL driver untyped and `DotCloudSignature` by class name.

```bash
ln -s ../../dot-core/addons/dot_core addons/dot_core
ln -s ../../dot-sql/addons/dot_sql addons/dot_sql   # the suites only
ln -s ../../dot-cloud/addons/dot_cloud addons/dot_cloud   # the suites only
```

## Read before

| Read | Before |
| --- | --- |
| [docs/design.md](docs/design.md) | anything: what this is, the shared merge, the stats bridge, loading before recording, the index, the details that look arbitrary, the SQL store, the reporter, what is not here |
| [docs/history.md](docs/history.md) | the reporter nothing called, and the cross-repo stories behind two rules |

## Layout

| Path | What |
| --- | --- |
| `core/` | `DotAchievementRule` (one condition; `Merge`, `merge_value`), `DotAchievement` (rules, tiers, `to_player_dictionary`), `DotAchievementCatalogue` (`validate()` and the stat index), `DotAchievementProgress` |
| `runtime/dot_achievement_tracker.gd` | `DotAchievementTracker`: load, record, evaluate, save, `listing()`, drives the reporter |
| `runtime/dot_achievement_stats_link.gd` | `DotAchievementStatsLink`: GameSpice Stats session totals to lifetime deltas |
| `store/` | `DotAchievementStore` (the seam), `...StoreMemory` (the default), `...StoreFile`, `...StoreSql` and `DotAchievementSqlSchema` |
| `net/dot_achievement_reporter.gd` | `DotAchievementReporter`: define, unlock, player routes on the backbone |
| `net/dot_points_reporter.gd`, `net/dot_points_reporter_config.gd` | `DotPointsReporter`, `DotPointsReporterConfig`: signed points events to Gamespice app points |
| `examples/achievements_selftest.tscn` | the suite; offline, non-zero on failure |
| `examples/points_selftest.tscn` | the points reporter suite; offline, needs GameSpice Cloud linked |
| `examples/achievements_sql_live.tscn` | the SQL store against real databases |

Paths except `examples/` are in `addons/dot_achievements/`.

## Running and testing

The family's two steps ([family CLAUDE.md](../../CLAUDE.md#validating-anything)), then `godot --headless --path . res://examples/achievements_selftest.tscn` and `res://examples/points_selftest.tscn`. The SQL store against real databases, through dot-sql's gateway (SQLite always; Postgres and MySQL/MariaDB when `GS_SQL_PG_DSN` / `GS_SQL_MYSQL_DSN` are set): `../dot-sql/tools/test_live.sh . res://examples/achievements_sql_live.tscn`.

The suite prints six `ERR achievements …` lines on every green run (five `could not be read`, one refused unlock batch), two of them in its SQL section. They are the point: a store never opened and a read failure, each asserted to be reported as a failed load rather than a blank player.

The points suite prints four `ERR achievements.points` lines (a PEM that is not a key, a missing key file, a 400 batch dropped, a full queue) and one engine `Error parsing key` line for that PEM, each asserted.

## Rules that bite

- Nothing here counts; the game or GameSpice Stats counts. Never import GameSpice Stats or use `DotStatsValues`. [design](docs/design.md#what-this-is-and-what-it-is-not)
- `DotAchievementRule.Merge` must keep matching `DotStatsDef.Kind` and website-city's `PlayerStatMerge`; change all three together. [design](docs/design.md#the-merge-borrowed-on-purpose)
- GameSpice Stats readings go through `DotAchievementStatsLink`, never straight into `record()`. [design](docs/design.md#the-bridge-is-a-class-not-one-connect)
- `record` refuses a player not loaded (`CODE_STATE`); a store that cannot read fails, never returns a fresh player; a failed save leaves the dirty flag set. [design](docs/design.md#a-player-must-be-begun)
- The catalogue's `validate()` builds the stat index and refuses duplicate ids, one stat with two merges, orphan tiers. [design](docs/design.md#the-index-and-why-the-catalogue-is-a-class)
- Hidden and secret are stripped in `to_player_dictionary`, never only in a UI. [design](docs/design.md#details-that-look-arbitrary-and-are-not)
- `merge_value` takes `has_current`; comparisons carry an epsilon; points are recounted on load. [design](docs/design.md#details-that-look-arbitrary-and-are-not)
- File store names are slug plus hash of the whole key; the tracker defaults to memory; file writes call `DotWeb.sync_filesystem()`. [design](docs/design.md#details-that-look-arbitrary-and-are-not)
- The SQL store names no GameSpice SQL class, saves the whole progress as one batch with deletes last, and serialises saves per player. [design](docs/design.md#sql-storage-through-dot-sql)
- Never send a `backbone:` account id as a player key. [design](docs/design.md#the-backbone-reporter)
- The define and unlock bodies are website-city's `~/types/integration/achievements.ts` schemas; change both sides together and re-check them side by side. [design](docs/design.md#the-backbone-reporter)

- The points reporter never sends an amount, signs each batch once and resends it byte-identical, and resends only on a network fault, 5xx or 429. Its body is website-city's `docs/app-points.md`; change both sides together. Unsent events are journalled (`persist_queue`, default on) and replayed by the next `configure()` on the same file; never drop that journal on a restart. [design](docs/design.md#the-points-reporter) [design](docs/design.md#the-points-reporter)

Deliberately not here: art and toasts, counting, tier implication, cross-server totals beyond a shared store, anti-cheat. [design](docs/design.md#deliberately-not-here)
