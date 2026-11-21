extends "res://examples/achievements_selftest_sql.gd"

## Exercises GSPointsReporter against a fake backbone and a real dot-cloud signature.
## Extends the SQL section's file only for its check harness.
##
## [codeblock]
## godot --headless --path . res://examples/points_selftest.tscn
## [/codeblock]

const SECTIONS := 8
const CHECKS := 58
const JOURNAL := "user://points_selftest/queue.jsonl"


## A stand-in for GameSpice Auth's GSBackboneClient. [member fail_with] fails the next posts.
class FakeBackbone extends RefCounted:
	var calls: Array[Dictionary] = []
	var fail_with: GSError = null

	func post_integration(path: String, body: Dictionary) -> GSResult:
		calls.append({"path": path, "body": body.duplicate(true)})
		if fail_with != null:
			return GSResult.failure(fail_with)
		var parsed: Variant = JSON.parse_string(str(body.get("batch", "")))
		var results: Array = []
		if parsed is Dictionary:
			for ev in (parsed as Dictionary).get("events", []):
				results.append({"eventId": ev["eventId"], "status": "accepted", "amount": 5})
		return GSResult.success({"ok": true, "results": results})


var _public_pem: String = ""
var _private_pem: String = ""


func _ready() -> void:
	GSLog.set_level(GSLog.Level.ERROR)
	await _run()


func _run() -> void:
	_line("dot-achievements points reporter self-test")

	var pair := GSCloudSignature.generate_keypair(2048)
	if not pair.ok:
		_line("ERROR: could not generate a keypair: %s" % str(pair.error))
		get_tree().quit(1)
		return
	_private_pem = str(pair.value["private"])
	_public_pem = str(pair.value["public"])

	_test_config()
	await _test_configure()
	await _test_report_refusals()
	await _test_signed_batches()
	await _test_retry()
	await _test_limits()
	await _test_timer()
	await _test_journal()

	_line("")
	_line("%d sections, %d passed, %d failed" % [_section_count, _passed, _failed])
	if _section_count != SECTIONS or _passed + _failed != CHECKS:
		_line("ERROR: %d of %d sections and %d of %d checks ran." % [
			_section_count, SECTIONS, _passed + _failed, CHECKS
		])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


func _config(batch: int = 100, pending_cap: int = 0, interval: float = 0.0) -> GSPointsReporterConfig:
	var c := GSPointsReporterConfig.new()
	c.app_id = 7
	c.server_id = 42
	c.private_key_pem = _private_pem
	c.flush_interval_secs = interval
	c.max_batch_events = batch
	c.max_pending_events = pending_cap
	c.persist_queue = false
	return c


func _reporter(c: GSPointsReporterConfig) -> Array:
	var backbone := FakeBackbone.new()
	var r := GSPointsReporter.new()
	r.client = backbone
	add_child(r)
	var res := r.configure(c)
	return [r, backbone, res]


func _test_config() -> void:
	_section("config: required values, 0 = unlimited, bad values fail rather than clamp")

	_check(not GSPointsReporterConfig.new().validate().ok, "a default config is refused: no app, server or key")
	_check(_config().validate().ok, "app, server and a key is enough")
	_check(_config(0, 0, 0.0).validate().ok, "0 batch, 0 pending and 0 interval are valid (unlimited, no timer)")
	_check(not _config(-1).validate().ok, "a negative max_batch_events fails")
	_check(not _config(1, -5).validate().ok, "a negative max_pending_events fails")
	_check(not _config(1, 0, -1.0).validate().ok, "a negative flush interval fails")
	var both := _config()
	both.private_key_path = "user://points.pem"
	_check(not both.validate().ok, "a key path and a key PEM together fail")
	_check(_config().sensitive_keys().has("private_key_pem"), "the PEM is a sensitive key")
	var shown := "\n".join(_config().describe_lines(true))
	_check(not shown.contains("PRIVATE KEY"), "and a config dump does not print it")


func _test_configure() -> void:
	_section("configure: a key that cannot sign fails at boot")

	var bad := _config()
	bad.private_key_pem = "-----BEGIN PRIVATE KEY-----\nnope\n-----END PRIVATE KEY-----\n"
	var made := _reporter(bad)
	var r: GSPointsReporter = made[0]
	_check(not (made[2] as GSResult).ok, "a PEM that is not a key is refused")
	_check(not r.is_configured(), "and the reporter stays unconfigured")
	_check(not r.report("u_ada", "kill").ok, "so report() fails instead of queueing")
	r.queue_free()

	var missing := _config()
	missing.private_key_pem = ""
	missing.private_key_path = "user://no-such-points-key.pem"
	made = _reporter(missing)
	_check((made[2] as GSResult).code() == GSError.CODE_IO, "a key file that is not there is an io failure")
	(made[0] as GSPointsReporter).queue_free()

	made = _reporter(_config())
	_check((made[2] as GSResult).ok, "a real RSA key configures")
	(made[0] as GSPointsReporter).queue_free()


func _test_report_refusals() -> void:
	_section("report: the strict event shape, refused before it leaves the process")

	var made := _reporter(_config())
	var r: GSPointsReporter = made[0]
	_check(not r.report("backbone:12345", "kill").ok, "an account id is not a player key")
	_check(not r.report("u ada", "kill").ok, "a player key with a space is refused")
	_check(not r.report("u_ada", "Kill").ok, "an event key with capitals is refused")
	_check(not r.report("u_ada", "kill", 0).ok, "a count of 0 is refused")
	_check(not r.report("u_ada", "kill", 1, {"amount": 50}).ok, "an amount in meta is refused")
	_check(not r.report("u_ada", "kill", 1, {"humans": "3"}).ok, "meta.humans must be an int")
	_check(not r.report("u_ada", "kill", 1, {}, "has space").ok, "a game event id is checked too")
	_check(r.pending() == 0, "nothing refused was queued")
	var a := r.report("u_ada", "kill")
	var b := r.report("u_ada", "kill")
	_check(a.ok and b.ok and str(a.value) != str(b.value), "each event gets its own eventId")
	var own := r.report("u_bo", "round_win", 1, {}, "m9:r3:1")
	_check(own.ok and str(own.value) == "m9:r3:1", "a game's own eventId is kept")
	r.queue_free()


func _test_signed_batches() -> void:
	_section("flush: signed batches the site can verify, with no amount anywhere")

	var made := _reporter(_config(2))
	var r: GSPointsReporter = made[0]
	var backbone: FakeBackbone = made[1]
	var settled: Array = []
	r.events_settled.connect(func(results: Array) -> void: settled.append_array(results))

	r.report("u_ada", "kill", 1, {"humans": 6, "vsBot": false})
	r.report("u_bo", "headshot", 3)
	r.report("u_cy", "match_win")
	var flushed: GSResult = await r.flush()
	_check(flushed.ok and int(flushed.value) == 3, "a flush sends every event")
	_check(backbone.calls.size() == 2, "in batches of max_batch_events (2 + 1)")
	_check(str(backbone.calls[0]["path"]) == "points/events", "to points/events")

	var body: Dictionary = backbone.calls[0]["body"]
	var text := str(body["batch"])
	var verified := GSCloudSignature.verify(text.to_utf8_buffer(), str(body["sig"]), _public_pem)
	_check(verified.ok, "the sig verifies over the batch bytes with the public key")
	_check(body.keys().size() == 2, "the body is only batch and sig")
	var batch: Dictionary = JSON.parse_string(text)
	var keys := batch.keys()
	keys.sort()
	_check(keys == ["app", "events", "server", "v"], "the batch holds only v, app, server, events")
	_check(int(batch["v"]) == 1 and int(batch["app"]) == 7 and int(batch["server"]) == 42, "with the configured ids")
	var first: Dictionary = (batch["events"] as Array)[0]
	_check(first.has("eventId") and first.has("eventKey") and first.has("player") and first.has("at"), "events carry eventId, eventKey, player, at")
	var meta: Dictionary = first["meta"]
	_check(meta.size() == 2 and int(meta["humans"]) == 6 and meta["vsBot"] == false, "and meta as given")
	var second: Dictionary = (batch["events"] as Array)[1]
	_check(int(second["count"]) == 3 and not second.has("meta"), "count only when it is not 1, meta only when given")
	_check(not text.contains("amount"), "no amount is ever sent")
	_check(settled.size() == 3 and r.accepted == 3, "the site's per-event results are counted and emitted")
	r.queue_free()


func _test_retry() -> void:
	_section("retry: the same signed bytes until answered; a refusal is dropped")

	var made := _reporter(_config())
	var r: GSPointsReporter = made[0]
	var backbone: FakeBackbone = made[1]
	r.report("u_ada", "kill")
	backbone.fail_with = GSError.from_http(503)
	var failed: GSResult = await r.flush()
	_check(not failed.ok and r.pending() == 1, "a 503 keeps the event")
	r.report("u_bo", "kill")
	backbone.fail_with = null
	await r.flush()
	_check(backbone.calls.size() == 3, "the held batch goes first, then the new one")
	var a: Dictionary = backbone.calls[0]["body"]
	var b: Dictionary = backbone.calls[1]["body"]
	_check(a["batch"] == b["batch"] and a["sig"] == b["sig"], "resent byte-identical, same eventId and sig")
	_check(r.pending() == 0 and r.accepted == 2, "and both are answered once")

	var dropped_ids: Array = []
	r.batch_dropped.connect(func(ids: PackedStringArray, _e: String) -> void: dropped_ids.append_array(ids))
	r.report("u_cy", "kill")
	backbone.fail_with = GSError.from_http(400, "bad_batch")
	await r.flush()
	_check(r.pending() == 0 and r.dropped == 1 and dropped_ids.size() == 1, "a 400 is dropped and signalled, not resent for ever")
	r.queue_free()


func _test_limits() -> void:
	_section("limits: 0 is unlimited; a full queue refuses loudly and drops nothing")

	var made := _reporter(_config(0))
	var r: GSPointsReporter = made[0]
	var backbone: FakeBackbone = made[1]
	for i in 5:
		r.report("u_%d" % i, "kill")
	await r.flush()
	_check(backbone.calls.size() == 1, "max_batch_events 0 sends everything in one request")
	r.queue_free()

	made = _reporter(_config(100, 2))
	r = made[0]
	_check(r.report("u_a", "kill").ok and r.report("u_b", "kill").ok, "up to max_pending_events is taken")
	var full := r.report("u_c", "kill")
	_check(not full.ok and full.code() == GSError.CODE_STATE, "past it report() fails")
	_check(r.pending() == 2 and r.dropped == 0, "and nothing already held is dropped")

	var used := []
	r.signer = func(bytes: PackedByteArray, _pem: String) -> GSResult:
		used.append(bytes.size())
		return GSResult.success("c2ln")
	await r.flush()
	_check(used.size() == 1, "an injected signer replaces GSCloudSignature")
	_check(r.report("u_c", "kill").ok, "and once sent, there is room again")
	r.queue_free()


func _test_timer() -> void:
	_section("timer: flush_interval_secs flushes without the game calling flush()")

	var made := _reporter(_config(100, 0, 0.2))
	var r: GSPointsReporter = made[0]
	var backbone: FakeBackbone = made[1]
	r.report("u_ada", "kill")
	await get_tree().create_timer(0.6).timeout
	_check(backbone.calls.size() == 1 and r.pending() == 0, "the timer sent the event")
	_check(r.describe()["accepted"] == 1 and r.describe_lines().size() >= 1, "describe() reports it")
	r.queue_free()


func _test_journal() -> void:
	_section("journal: unsent events survive a crash and are resent once")

	var c := _config(2)
	_check(c.persist_queue == false and GSPointsReporterConfig.new().persist_queue, "persisting is the default (off here for the other sections)")
	var plain := GSPointsReporterConfig.new()
	plain.app_id = 7
	plain.server_id = 42
	_check(plain.resolved_queue_path().contains("queue-7-42"), "the default journal is per app and server")

	DirAccess.remove_absolute(JOURNAL)
	c.persist_queue = true
	c.queue_path = JOURNAL
	var made := _reporter(c)
	var r: GSPointsReporter = made[0]
	var backbone: FakeBackbone = made[1]
	r.report("u_ada", "kill", 1, {"humans": 4})
	r.report("u_bo", "kill", 2)
	r.report("u_cy", "kill")
	backbone.fail_with = GSError.from_http(503)
	await r.flush()
	var first_try: Dictionary = backbone.calls[0]["body"]
	r.report("u_di", "kill")
	# A crash: the node goes away with four events unanswered and nothing flushed.
	r.free()
	_check(FileAccess.file_exists(JOURNAL), "the journal file holds the unsent events")

	made = _reporter(c)
	r = made[0]
	backbone = made[1]
	_check(r.replayed == 4 and r.pending() == 4, "a new reporter on the same file queues them again")
	var sent: GSResult = await r.flush()
	_check(sent.ok and backbone.calls.size() == 3, "and sends them: two sealed batches, then the one left queued")
	var again: Dictionary = backbone.calls[0]["body"]
	_check(again["batch"] == first_try["batch"] and again["sig"] == first_try["sig"], "a sealed batch is resent byte-identical")
	_check(r.pending() == 0 and not FileAccess.file_exists(JOURNAL), "once answered the journal is removed")
	r.queue_free()

	var f := FileAccess.open(JOURNAL, FileAccess.WRITE)
	f.store_line(JSON.stringify({"e": {"eventId": "m1:1", "eventKey": "kill", "player": "u_ed", "at": 1700000000, "count": 3}}))
	f.store_string("{\"e\": {\"eventId\": \"m1:2\", \"eve")
	f.close()
	made = _reporter(c)
	r = made[0]
	var ev: Dictionary = r._queue[0] if r._queue.size() == 1 else {}
	_check(r.replayed == 1 and typeof(ev.get("at")) == TYPE_INT and typeof(ev.get("count")) == TYPE_INT, "a torn last line is skipped; the rest comes back with integer fields")
	r.queue_free()
	DirAccess.remove_absolute(JOURNAL)

	made = _reporter(_config())
	r = made[0]
	r.report("u_fy", "kill")
	_check(r.describe()["queue_path"] == "" and not FileAccess.file_exists(JOURNAL), "persist_queue off writes nothing")
	r.queue_free()
