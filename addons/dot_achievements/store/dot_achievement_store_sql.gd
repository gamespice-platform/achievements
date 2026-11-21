class_name GSAchievementStoreSql
extends GSAchievementStore

## Progress in real tables, in whichever SQL a GameSpice SQL driver speaks.
##
## [codeblock]
## var store := GSAchievementStoreSql.new(GSSqlDriverSqlite.new("user://achievements.db"))
## var opened := await store.open()      # creates or migrates the tables
## tracker.store = store
## [/codeblock]
##
## For a community whose servers share one database: a player's progress is the same on
## all of them, which is what [code]GSAchievementStore[/code]'s "cross-server totals"
## note means by sharing a store. The tables are [GSAchievementSqlSchema]'s.
##
## [b]The driver is duck-typed[/b] — held untyped and asked for `query`, `batch`,
## `upsert_sql`, `dialect` and `migrate` — so GameSpice Achievements does not depend on GameSpice SQL
## and parses in a project without it.
##
## [b]A save writes the whole progress, as one batch.[/b] Every held number is upserted,
## every unlock is inserted if absent (an unlock's time never changes once earned), and
## then the rows the progress no longer holds are deleted — a revocation. Deletes last, so a
## batch cut off part-way on a driver without transactions leaves a superset, never a
## player missing what they had. A driver with transactions (the gateway has them) applies
## it all or none.
##
## [b]Saves of one player are serialised.[/b] The tracker saves on an unlock without
## waiting (deliberately: it is in the middle of a game's scoring) and the autosave saves
## the same player again, so two saves can be in flight at once — and over a network they
## can land in either order. The older snapshot landing second would put back a number the
## newer one had moved and, worse, delete an unlock the newer one had just added. So a save
## waits for the one before it, and only then takes its snapshot, so the last write is
## always the newest state.

## Emitted when a player's save finishes, for the next one waiting on it.
signal _released(player: String)

## Where statements go: a GameSpice SQL driver, or anything shaped like one.
var driver = null

## Table names, in case an operator already owns these or runs two games in one database.
var values_table: String = GSAchievementSqlSchema.DEFAULT_VALUES_TABLE
var unlocks_table: String = GSAchievementSqlSchema.DEFAULT_UNLOCKS_TABLE

## Create or migrate the tables on [method open]. Off for a deployment whose schema is
## managed elsewhere and which would rather this touched nothing.
var create_schema: bool = true

## Diagnostics.
var loads: int = 0
var saves: int = 0

## player -> true while a save of theirs is in flight.
var _saving: Dictionary = {}


func _init(p_driver = null) -> void:
	driver = p_driver


func is_available() -> bool:
	return driver != null and driver.is_open()


## Opens the driver and, unless told not to, creates or migrates the tables.
func open() -> GSResult:
	if driver == null:
		return GSResult.fail(GSError.CODE_STATE, "No SQL driver.")

	var available: GSResult = driver.is_available()
	if not available.ok:
		return available

	var opened: GSResult = await driver.open()
	if not opened.ok:
		return opened

	if not create_schema:
		return GSResult.success(true)

	# Versioned rather than "create if missing": a database from a NEWER build is refused
	# rather than read with columns that have changed meaning underneath it — which here
	# would be a player's lifetime progress, read wrong and then saved back.
	var migrated: GSResult = await driver.migrate(
		"%s:%s" % [GSAchievementSqlSchema.MIGRATION_COMPONENT, values_table],
		GSAchievementSqlSchema.migration_steps(values_table, unlocks_table)
	)

	if not migrated.ok:
		return migrated.wrap("Could not prepare the achievement tables.")

	GSLog.info(CHANNEL, "achievement tables ready", {
		"dialect": GSAchievementSqlSchema.dialect_name(int(driver.dialect())),
		"values": values_table,
		"unlocks": unlocks_table,
	})

	return GSResult.success(true)


func close() -> void:
	if driver != null:
		driver.close()


func _load_progress(player: String) -> GSResult:
	if not is_available():
		return GSResult.fail(GSError.CODE_STATE, "The database is not open.")

	var values: GSResult = await driver.query(
		GSAchievementSqlSchema.select_values(values_table), [player]
	)
	# A failure, never a fresh player: a fresh progress handed back while the database is
	# down is a blank account the next save writes over the real one.
	if not values.ok:
		return values.wrap("Could not read a player's achievement values.")

	var unlocks: GSResult = await driver.query(
		GSAchievementSqlSchema.select_unlocks(unlocks_table), [player]
	)
	if not unlocks.ok:
		return unlocks.wrap("Could not read a player's unlocks.")

	loads += 1

	# Through the same parser the file store uses. The points total is not stored: the
	# tracker recounts it from the catalogue on every load, because a stored total is a
	# cache that a catalogue edit makes wrong.
	return GSAchievementProgress.from_dictionary(
		GSAchievementSqlSchema.progress_dictionary(values.value, unlocks.value)
	)


func _save_progress(player: String, progress: GSAchievementProgress) -> GSResult:
	if not is_available():
		return GSResult.fail(GSError.CODE_STATE, "The database is not open.")

	while _saving.has(player):
		await _released

	_saving[player] = true
	var res: GSResult = await _write(player, progress)
	_saving.erase(player)
	_released.emit(player)

	return res


func _write(player: String, progress: GSAchievementProgress) -> GSResult:
	# The snapshot is taken here, after any earlier save of this player finished, so it is
	# the newest state there is. See the class note.
	var now := int(Time.get_unix_time_from_system())
	var batch: Array = []

	var value_upsert: String = driver.upsert_sql(
		values_table,
		PackedStringArray(GSAchievementSqlSchema.VALUE_COLUMNS),
		PackedStringArray(["player", "stat"])
	)
	var kept_stats: Array = []
	for stat in progress.values:
		var amount := float(progress.values[stat])
		if not is_finite(amount):
			# JSON cannot carry it and MySQL refuses it; one poisoned number must not cost
			# the player the rest of the save. Left out, and said so.
			GSLog.warn(CHANNEL, "skipping a non-finite achievement value", {
				"player": player.substr(0, 16), "stat": String(stat),
			})
			continue
		batch.append([value_upsert, [player, String(stat), amount, now]])
		kept_stats.append(String(stat))

	# Insert-or-ignore: the time an achievement was earned never changes once written, and
	# a save carrying a different one (a clock that moved) must not rewrite history.
	var unlock_insert: String = driver.upsert_sql(
		unlocks_table,
		PackedStringArray(GSAchievementSqlSchema.UNLOCK_COLUMNS),
		PackedStringArray(["player", "achievement"]),
		[]
	)
	var kept_unlocks: Array = []
	for id in progress.unlocked:
		batch.append([unlock_insert, [player, String(id), int(progress.unlocked[id])]])
		kept_unlocks.append(String(id))

	# Deletes last; see the class note.
	batch.append([
		GSAchievementSqlSchema.delete_except(unlocks_table, "achievement", kept_unlocks.size()),
		[player] + kept_unlocks,
	])
	batch.append([
		GSAchievementSqlSchema.delete_except(values_table, "stat", kept_stats.size()),
		[player] + kept_stats,
	])

	var wrote: GSResult = await driver.batch(batch)
	if not wrote.ok:
		return wrote.wrap("Could not write a player's achievement progress.")

	saves += 1
	return GSResult.success(batch.size())


func describe() -> Dictionary:
	return {
		"store": "sql/%s" % (driver.driver_name() if driver != null else "none"),
		"available": is_available(),
		"values_table": values_table,
		"unlocks_table": unlocks_table,
		"dialect": GSAchievementSqlSchema.dialect_name(int(driver.dialect()) if driver != null else -1),
		"loads": loads,
		"saves": saves,
		"saving": _saving.size(),
	}
