extends Node

## The SQL store against a real database, through GameSpice SQL's gateway.
##
## The self-test proves which statements the store sends; this proves a database accepts
## them and gives back what was saved, in all three dialects — and that a tracker using it
## keeps a player's lifetime progress across two sessions. Run by GameSpice SQL's runner, which
## starts a gateway per dialect and sets GS_SQL_URL, GS_SQL_DIALECT and GS_SQL_TOKEN_FILE:
##
## [codeblock]
## ../gs-sql/tools/test_live.sh . res://examples/achievements_sql_live.tscn
## [/codeblock]

const CHECKS := 12

const VALUES := "gs_ach_live_values"
const UNLOCKS := "gs_ach_live_unlocks"

var _passed := 0
var _failed := 0


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)

	var dialect := GSSqlDialect.from_name(OS.get_environment("GS_SQL_DIALECT"))
	var made := GSSql.from_config({
		"driver": "gateway",
		"url": OS.get_environment("GS_SQL_URL"),
		"dialect": GSSqlDialect.name_of(dialect),
		"token": FileAccess.get_file_as_string(OS.get_environment("GS_SQL_TOKEN_FILE")).strip_edges(),
	}, self)
	if not made.ok or made.value == null:
		print("set GS_SQL_URL, GS_SQL_DIALECT and GS_SQL_TOKEN_FILE; see gs-sql/tools/test_live.sh")
		get_tree().quit(2)
		return

	var driver: GSSqlDriverGateway = made.value
	print("gs-achievements live: %s" % GSSqlDialect.name_of(dialect))

	# Clean tables every run.
	await driver.open()
	await _drop(driver)

	var store := _store(driver)
	var opened: GSResult = await store.open()
	_check("the store creates its tables", opened.ok, opened)

	var fresh: GSResult = await store.load_progress("nobody")
	_check(
		"a player with no rows loads as a fresh player",
		fresh.ok and (fresh.value as GSAchievementProgress).unlocked_count() == 0
			and (fresh.value as GSAchievementProgress).values.is_empty(),
		fresh
	)

	var who := "p'1 🙃"
	var progress := GSAchievementProgress.new()
	progress.set_value(&"kills", 12.0)
	progress.set_value(&"best_time", 61.123)
	progress.mark_unlocked(&"k10", 1700000000, 5)
	var saved: GSResult = await store.save_progress(who, progress)
	_check("a progress is saved", saved.ok, saved)

	var read := await _load(store, who)
	_check(
		"and reads back: numbers, thousandths, an unlock and its time, under a key with a quote and an emoji",
		read != null and read.value_of(&"kills") == 12.0 and read.value_of(&"best_time") == 61.123
			and read.unlocked_at(&"k10") == 1700000000
	)

	# A second save moves a number and tries to move an unlock's time; the first is an
	# upsert and the second must not be.
	progress.set_value(&"kills", 15.0)
	progress.unlocked[&"k10"] = 1800000000
	progress.mark_unlocked(&"fast", 1700000100, 10)
	await store.save_progress(who, progress)
	read = await _load(store, who)
	_check(
		"saving again updates a number, adds an unlock, and never rewrites when one was earned",
		read != null and read.value_of(&"kills") == 15.0 and read.is_unlocked(&"fast")
			and read.unlocked_at(&"k10") == 1700000000
	)

	progress.revoke(&"fast", 10)
	await store.save_progress(who, progress)
	read = await _load(store, who)
	_check("a revocation reaches the table", read != null and not read.is_unlocked(&"fast") and read.is_unlocked(&"k10"))

	var someone := GSAchievementProgress.new()
	someone.set_value(&"kills", 1.0)
	await store.save_progress("p2", someone)
	read = await _load(store, who)
	var other := await _load(store, "p2")
	_check(
		"two players' rows stay their own",
		read != null and other != null and read.value_of(&"kills") == 15.0 and other.value_of(&"kills") == 1.0
			and other.unlocked_count() == 0
	)

	# Two saves of one player in flight at once, against a real database.
	var racing := GSAchievementProgress.new()
	racing.mark_unlocked(&"a", 1, 1)
	store.save_progress("p3", racing)    # not awaited, as save_on_unlock does
	racing.mark_unlocked(&"b", 2, 1)
	await store.save_progress("p3", racing)
	var raced := await _load(store, "p3")
	_check(
		"two saves in flight land in order, so the newest state is what stays",
		raced != null and raced.is_unlocked(&"a") and raced.is_unlocked(&"b")
	)

	# A tracker over the store: lifetime progress across two sessions.
	var tracker := _tracker(store)
	await tracker.begin("p4")
	for i in 3:
		tracker.record("p4", &"kills", 1.0)
	_check("a tracker over the store earns an achievement", tracker.is_unlocked("p4", &"k3"))
	var ended: GSResult = await tracker.end("p4")
	tracker.queue_free()

	var again := _tracker(store)
	var began: GSResult = await again.begin("p4")
	_check(
		"and a new session loads it back, earned",
		ended.ok and began.ok and again.is_unlocked("p4", &"k3"),
		began
	)
	again.record("p4", &"kills", 2.0)
	_check(
		"with its lifetime count to add to",
		is_equal_approx(again.progress_of("p4").value_of(&"kills"), 5.0)
	)
	again.queue_free()

	var reopen: GSResult = await _store(driver).open()
	_check("opening existing tables again is harmless", reopen.ok, reopen)

	print("%d passed, %d failed" % [_passed, _failed])
	await _drop(driver)
	get_tree().quit(1 if _failed > 0 or _passed + _failed != CHECKS else 0)


func _store(driver) -> GSAchievementStoreSql:
	var store := GSAchievementStoreSql.new(driver)
	store.values_table = VALUES
	store.unlocks_table = UNLOCKS
	return store


func _tracker(store: GSAchievementStore) -> GSAchievementTracker:
	var tracker := GSAchievementTracker.new()
	tracker.register_as = &""
	tracker.catalogue = GSAchievementCatalogue.of([
		GSAchievement.counter(&"k3", "Three", &"kills", 3.0),
	] as Array[GSAchievement])
	tracker.store = store
	tracker.autosave_interval = 0.0
	tracker.save_on_unlock = false
	add_child(tracker)
	return tracker


func _load(store: GSAchievementStoreSql, player: String) -> GSAchievementProgress:
	var got: GSResult = await store.load_progress(player)
	return got.value if got.ok else null


func _drop(driver) -> void:
	await driver.execute("DROP TABLE IF EXISTS %s" % VALUES)
	await driver.execute("DROP TABLE IF EXISTS %s" % UNLOCKS)
	await driver.execute("DELETE FROM gs_sql_migrations WHERE component = ?", ["gs_achievements:%s" % VALUES])


func _check(what: String, passed: bool, res: GSResult = null) -> void:
	if passed:
		_passed += 1
		print("  %-60s ok" % what)
		return
	_failed += 1
	var why := ""
	if res != null and not res.ok and res.error != null:
		why = " — %s (%s)" % [res.error.message, res.error.detail]
	print("  %-60s FAILED%s" % [what, why])
