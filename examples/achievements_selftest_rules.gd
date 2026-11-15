extends "res://examples/achievements_selftest_sql.gd"

## The rules, catalogue and store sections of achievements_selftest.gd, and the catalogue and
## tracker it builds them on; achievements_selftest.gd extends this.


func _test_rules() -> void:
	_section("rules")

	var at_least := DotAchievementRule.make(&"kills", 100.0)
	_check(at_least.satisfied(100.0), "at_least is satisfied exactly on the threshold")
	_check(at_least.satisfied(101.0), "and above it")
	_check(not at_least.satisfied(99.0), "and not below")

	var at_most := DotAchievementRule.make(
		&"deaths", 0.0, DotAchievementRule.Op.AT_MOST
	)
	_check(at_most.satisfied(0.0), "at_most is satisfied at zero")
	_check(not at_most.satisfied(1.0), "and not at one")

	# A value summed a thousand times is not bit-identical to the same value summed a
	# thousand times in another order, and an achievement that will not unlock on
	# exactly 100 after the hundredth kill is a bug report nobody can reproduce.
	_check(
		at_least.satisfied(99.99995),
		"a float within an epsilon of the threshold counts"
	)

	_check(is_equal_approx(at_least.progress(40.0), 0.4), "progress is a fraction")
	_check(is_equal_approx(at_least.progress(400.0), 1.0), "clamped at one")
	_check(
		is_equal_approx(at_most.progress(1.0), 0.0),
		"an at_most rule is never 90% done: it is done or it is not"
	)
	_check(at_least.has_progress(), "at_least can draw a bar")
	_check(not at_most.has_progress(), "at_most cannot")

	var sum := DotAchievementRule.make(&"k", 1.0, DotAchievementRule.Op.AT_LEAST,
		DotAchievementRule.Merge.SUM)
	_check(is_equal_approx(sum.merge_value(5.0, 3.0), 8.0), "SUM adds")

	var highest := DotAchievementRule.make(&"speed", 1.0,
		DotAchievementRule.Op.AT_LEAST, DotAchievementRule.Merge.HIGHEST)
	_check(is_equal_approx(highest.merge_value(9.0, 3.0), 9.0), "HIGHEST keeps the larger")

	var lowest := DotAchievementRule.make(&"time", 1.0,
		DotAchievementRule.Op.AT_MOST, DotAchievementRule.Merge.LOWEST)
	_check(is_equal_approx(lowest.merge_value(9.0, 3.0), 3.0), "LOWEST keeps the smaller")

	# The bug that makes every player's best time zero on the day the feature ships.
	_check(
		is_equal_approx(lowest.merge_value(0.0, 12.0, false), 12.0),
		"a first reading on a LOWEST stat is that reading, not min(reading, 0)"
	)

	var all_merges := true
	for value in DotAchievementRule.Merge.values():
		var probe := DotAchievementRule.make(&"s", 1.0,
			DotAchievementRule.Op.AT_LEAST, value)
		if DotAchievementRule.merge_from_name(probe.merge_name()) != value:
			all_merges = false
	_check(all_merges, "every Merge round-trips through its name")

	var all_ops := true
	for value in DotAchievementRule.Op.values():
		var probe := DotAchievementRule.make(&"s", 1.0, value)
		if DotAchievementRule.op_from_name(probe.op_name()) != value:
			all_ops = false
	_check(all_ops, "every Op round-trips through its name")

	var round_trip := DotAchievementRule.from_dictionary(lowest.to_dictionary())
	_check(round_trip.ok, "a rule round-trips through its dictionary")
	_check(
		(round_trip.value as DotAchievementRule).merge == DotAchievementRule.Merge.LOWEST,
		"keeping its merge, which is the one thing every party has to agree on"
	)

	_check(
		not DotAchievementRule.from_dictionary({"stat": "k", "merge": "average"}).ok,
		"an unknown merge name is refused rather than defaulted to SUM"
	)
	_check(
		not DotAchievementRule.make(&"", 1.0).validate().ok,
		"a rule with no stat is refused"
	)


func _test_catalogue() -> void:
	_section("catalogue")

	var catalogue := _catalogue()
	var valid := catalogue.validate()
	_check(valid.ok, "a catalogue validates")
	var site := catalogue.to_site_defs()
	_check(site["format"] == "dot-achievement-defs" and site["version"] == 1, "the site document names its format and version")
	_check(not site.has("game") and catalogue.to_site_defs(7)["game"] == 7, "the app id is left out unless asked for")
	var first: Dictionary = (site["achievements"] as Array)[0]
	_check(first.has("key") and first.has("requireAll") and (first["rules"] as Array).size() > 0, "an exported achievement carries its key and rules")

	_check(catalogue.find(&"k100") != null, "achievements are found by id")
	_check(catalogue.find(&"nope") == null, "and a missing one is null")

	var watched := catalogue.watched_stats()
	_check(watched.size() == 5, "it knows every stat it reads")
	_check(
		watched[0] == &"attended" and watched[watched.size() - 1] == &"secret_deed",
		"sorted by string, not by StringName pointer order"
	)

	var affected := catalogue.affected_by(&"kills")
	_check(affected.size() == 3, "and which achievements a stat could have moved")
	_check(catalogue.affected_by(&"unwatched").is_empty(), "and which none did")

	_check(
		catalogue.merge_for(&"best_time") == int(DotAchievementRule.Merge.LOWEST),
		"the merge for a stat comes out of the rules that read it"
	)
	_check(catalogue.merge_for(&"unwatched") < 0, "and is -1 for one nothing reads")

	_check(catalogue.in_series(&"kills").size() == 2, "a series comes out")
	_check(
		(catalogue.in_series(&"kills")[0] as DotAchievement).tier == 1,
		"in tier order"
	)
	_check(catalogue.total_points() > 0, "points total")

	var duplicated := DotAchievementCatalogue.of([
		DotAchievement.counter(&"same", "One", &"a", 1.0),
		DotAchievement.counter(&"same", "Two", &"b", 1.0),
	] as Array[DotAchievement])
	_check(
		not duplicated.validate().ok,
		"two achievements sharing an id are refused: the store is keyed by it"
	)

	# One number cannot be both a running total and a personal best. Caught at boot,
	# because the symptom otherwise is one of the two achievements never unlocking.
	var disagreeing := DotAchievementCatalogue.of([
		DotAchievement.make(&"a", "A", [
			DotAchievementRule.make(&"speed", 10.0, DotAchievementRule.Op.AT_LEAST,
				DotAchievementRule.Merge.SUM),
		] as Array[DotAchievementRule]),
		DotAchievement.make(&"b", "B", [
			DotAchievementRule.make(&"speed", 20.0, DotAchievementRule.Op.AT_LEAST,
				DotAchievementRule.Merge.HIGHEST),
		] as Array[DotAchievementRule]),
	] as Array[DotAchievement])
	_check(
		not disagreeing.validate().ok,
		"one stat read with two different merges is refused"
	)

	var json := catalogue.to_dictionary()
	var reloaded := DotAchievementCatalogue.from_dictionary(json)
	_check(reloaded.ok, "a catalogue round-trips through JSON")
	_check(
		(reloaded.value as DotAchievementCatalogue).size() == catalogue.size(),
		"whole"
	)

	_check(
		not DotAchievementCatalogue.from_dictionary({"achievements": "no"}).ok,
		"and something that is not one is refused"
	)


func _test_progress() -> void:
	_section("progress")

	var progress := DotAchievementProgress.new()
	_check(not progress.dirty, "a fresh progress is clean")

	progress.set_value(&"kills", 5.0)
	_check(progress.dirty, "a write marks it dirty")
	_check(is_equal_approx(progress.value_of(&"kills"), 5.0), "and holds the value")
	_check(not progress.has_value(&"deaths"), "and knows what it has never seen")

	_check(progress.mark_unlocked(&"k100", 1000, 25), "an unlock takes")
	_check(not progress.mark_unlocked(&"k100", 2000, 25), "and only once")
	_check(progress.points == 25, "points accumulate once")

	var dict := progress.to_dictionary()
	(dict["values"] as Dictionary)[&"kills"] = 999.0
	_check(
		is_equal_approx(progress.value_of(&"kills"), 5.0),
		"to_dictionary hands out a copy, not the live dictionary"
	)

	var back := DotAchievementProgress.from_dictionary(progress.to_dictionary())
	_check(back.ok, "progress round-trips")
	var restored: DotAchievementProgress = back.value
	_check(restored.is_unlocked(&"k100"), "with its unlocks")
	_check(restored.unlocked_at(&"k100") == 1000, "and when they happened")
	_check(not restored.dirty, "and comes back clean")

	# The stored total is a cache, and a catalogue whose values changed since the file
	# was written makes it wrong.
	restored.points = 9999
	restored.recount(_catalogue())
	_check(restored.points == 25, "points are recounted from the catalogue, not trusted")

	restored.revoke(&"k100", 25)
	_check(not restored.is_unlocked(&"k100"), "an unlock can be revoked")
	_check(restored.points == 0, "and takes its points with it")


func _test_stores() -> void:
	_section("stores")

	var memory := DotAchievementStoreMemory.new()
	var fresh: DotResult = await memory.load_progress("nobody")
	_check(fresh.ok, "an unknown player loads")
	_check(
		(fresh.value as DotAchievementProgress).unlocked_count() == 0,
		"as a fresh progress rather than as a failure"
	)

	var progress := DotAchievementProgress.new()
	progress.mark_unlocked(&"k100", 5, 25)
	await memory.save_progress("ada", progress)

	var read: DotResult = await memory.load_progress("ada")
	_check((read.value as DotAchievementProgress).is_unlocked(&"k100"), "a save reads back")

	var second: DotResult = await memory.load_progress("ada")
	(second.value as DotAchievementProgress).mark_unlocked(&"other", 6, 5)
	var third: DotResult = await memory.load_progress("ada")
	_check(
		not (third.value as DotAchievementProgress).is_unlocked(&"other"),
		"a store hands out copies: two callers holding one object is two writers"
	)

	var directory := "user://dot_achievements_selftest"
	# From nothing, every run: "a player with no file is a fresh player" and every
	# save-then-load below mean nothing against a directory the last run left full.
	DotPaths.remove_tree(directory)
	var file := DotAchievementStoreFile.new(directory)

	# Two keys that slugify identically. dot-timer shipped exactly this: surf_kitsune2
	# and surf_kitsune3 both became surf_kitsune_ and shared one records file.
	var a := file.path_for("player one!")
	var b := file.path_for("player one?")
	_check(a != b, "two keys that slugify the same still get different files")

	_check(
		not file.path_for("../../etc/passwd").contains(".."),
		"a key cannot walk out of the directory it is stored in"
	)

	await file.save_progress("ada", progress)
	var from_disk: DotResult = await file.load_progress("ada")
	_check(from_disk.ok, "a file store saves and loads")
	_check(
		(from_disk.value as DotAchievementProgress).is_unlocked(&"k100"),
		"with the unlocks in it"
	)

	var missing: DotResult = await file.load_progress("never-seen")
	_check(
		missing.ok and (missing.value as DotAchievementProgress).unlocked_count() == 0,
		"a player with no file is a fresh player, not an error"
	)

	DotPaths.write_text(file.path_for("broken"), "{ this is not json")
	var corrupt: DotResult = await file.load_progress("broken")
	_check(
		not corrupt.ok,
		"a file that exists and cannot be read fails, so it is not overwritten with "
		+ "a blank one on the next save"
	)


func _catalogue() -> DotAchievementCatalogue:
	var k10 := DotAchievement.counter(&"k10", "First Blood", &"kills", 10.0)
	k10.series = &"kills"
	k10.tier = 1
	k10.points = 10

	var k100 := DotAchievement.counter(&"k100", "Centurion", &"kills", 100.0)
	k100.series = &"kills"
	k100.tier = 2
	k100.points = 25

	var flawless := DotAchievement.make(&"flawless", "Flawless", [
		DotAchievementRule.make(&"kills", 5.0),
		DotAchievementRule.make(&"deaths", 0.0, DotAchievementRule.Op.AT_MOST),
	] as Array[DotAchievementRule])

	var fast := DotAchievement.make(&"fast", "Quick", [
		DotAchievementRule.make(
			&"best_time", 10.0, DotAchievementRule.Op.AT_MOST,
			DotAchievementRule.Merge.LOWEST
		),
	] as Array[DotAchievementRule])

	var hidden := DotAchievement.counter(&"hidden_one", "Curious", &"secret_deed", 1.0)
	hidden.hidden = true

	var manual := DotAchievement.counter(&"opening_day", "Day One", &"attended", 1.0)

	return DotAchievementCatalogue.of([
		k10, k100, flawless, fast, hidden, manual
	] as Array[DotAchievement])


func _test_default_store() -> void:
	_section("default store")
	var dir := "user://dot_achievements_default_selftest"
	DotPaths.remove_tree(dir)
	var tracker := DotAchievementTracker.new()
	tracker.register_as = &""
	tracker.catalogue = _catalogue()
	tracker.store_directory = dir
	tracker.autosave_interval = 0.0
	add_child(tracker)
	_check(tracker.start().ok, "a tracker with no store starts")
	_check(
		tracker.store is DotAchievementStoreFile,
		"the default store is a file store, not memory"
	)
	var f := tracker.store as DotAchievementStoreFile
	DotPaths.write_text(f.path_for("bad"), "{ nope")
	var bad: DotResult = await f.load_progress("bad")
	_check(not bad.ok, "the default store refuses a corrupt file instead of reading it empty")
	tracker.queue_free()
	DotPaths.remove_tree(dir)


func _tracker() -> DotAchievementTracker:
	var tracker := DotAchievementTracker.new()
	tracker.register_as = &""
	tracker.catalogue = _catalogue()
	tracker.store = DotAchievementStoreMemory.new()
	tracker.autosave_interval = 0.0
	add_child(tracker)
	return tracker
