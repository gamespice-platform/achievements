class_name GSPointsReporter
extends Node

## Reports a game server's points events to Gamespice, signed with the server's own key.
##
## The site's contract (website-city docs/app-points.md):
##
## [codeblock]
## POST /api/integration/v1/points/events                (POINTS_WRITE)
##   { "batch": "<JSON text, signed byte for byte>", "sig": "<base64>" }
##   batch = { "v": 1, "app": <id>, "server": <id>,
##             "events": [ { "eventId", "eventKey", "player", "at",
##                           "count"?, "meta"?: { "humans"?, "vsBot"? } }, ... ] }
##   -> { "ok": true, "accepted": n, "duplicate": n, "refused": n,
##        "results": [ { "eventId", "status", "amount"?, "ledgerId"?, "code"? }, ... ] }
## [/codeblock]
##
## [b]A game says what happened, never what it is worth.[/b] The owner sets the amounts
## on the site, so nothing here carries one, and [method report] refuses a meta key it
## does not know rather than passing an "amount" along.
##
## Every event gets its eventId when it is reported, and each batch is signed once and
## resent byte-identical until the site answers, so a retry is never a second payment:
## the site deduplicates on (app, server, eventId). Signing goes through GameSpice Cloud's
## [code]GSCloudSignature.sign[/code] (RSA-SHA256), reached by name so this addon still
## loads without GameSpice Cloud; [member signer] replaces it.
##
## Unsent events survive a crash: with [member GSPointsReporterConfig.persist_queue] on
## (the default) every event, sealed batch and answer is appended to a journal file, and
## the next [method configure] on the same file queues what was never answered again.

signal events_settled(results: Array)
signal batch_dropped(event_ids: PackedStringArray, error: String)

const CHANNEL := "achievements.points"
const SCOPE_WRITE := "POINTS_WRITE"
const EVENTS_PATH := "points/events"
const VERSION := 1
const ACCOUNT_PREFIX := "backbone:"
const SIGNER_CLASS := &"GSCloudSignature"
const MAX_COUNT := 2147483647
const META_KEYS := ["humans", "vsBot"]

## The backbone client: any object with [code]post_integration(String, Dictionary)[/code],
## GameSpice Auth's GSBackboneClient in practice. Found under [member client_service] if unset.
var client: Object = null
var client_service: StringName = &"dot_backbone_client"

## [code]func(bytes: PackedByteArray, private_key_pem: String) -> GSResult[/code] whose
## value is the base64 signature. Empty uses GSCloudSignature.sign.
var signer: Callable = Callable()

var config: GSPointsReporterConfig = null

var reported: int = 0
var accepted: int = 0
var duplicate: int = 0
var refused: int = 0
var dropped: int = 0
var failures: int = 0
var last_error: String = ""
## Events read back from the journal of an earlier run and queued again.
var replayed: int = 0
## The last time the journal could not be written; "" while it is fine.
var journal_error: String = ""

var _key_pem: String = ""
var _boot_id: String = ""
var _seq: int = 0
var _queue: Array[Dictionary] = []
# Sealed batches: {batch, sig, ids}. Kept exactly as signed, so a resend is the same bytes.
var _outbox: Array[Dictionary] = []
var _flushing: bool = false
var _timer: Timer = null
# The journal file ("" = not persisting) and whether it was read in this process.
var _journal_path: String = ""
var _journal_loaded: String = ""

var _id_re := RegEx.create_from_string("^[A-Za-z0-9_.:-]{1,128}$")
var _key_re := RegEx.create_from_string("^[a-z0-9_.:-]{1,64}$")

# Edge state for the log: a lasting condition is said when it starts and when it ends.
var _failing: bool = false
var _warned_full: bool = false
var _warned_no_client: bool = false
var _refusal_codes_seen: Dictionary = {}


func _init() -> void:
	var rng := Crypto.new().generate_random_bytes(6)
	_boot_id = "%d-%s" % [int(Time.get_unix_time_from_system()), rng.hex_encode()]


## Validates [param p_config], reads the key and test-signs with it, so a bad key fails
## at boot and not on the first kill. Starts the flush timer when the interval is above 0.
func configure(p_config: GSPointsReporterConfig) -> GSResult:
	if p_config == null:
		return GSResult.fail(GSError.CODE_INVALID, "No points reporter config.")
	var valid := p_config.validate()
	if not valid.ok:
		GSLog.result(CHANNEL, "points reporter not configured", valid, GSLog.Level.ERROR)
		return valid

	var pem := p_config.private_key_pem
	if p_config.private_key_path.strip_edges() != "":
		var f := FileAccess.open(p_config.private_key_path, FileAccess.READ)
		if f == null:
			var e := GSResult.fail(
				GSError.CODE_IO, "Could not read the points signing key.",
				"%s: %s" % [p_config.private_key_path, error_string(FileAccess.get_open_error())]
			)
			GSLog.result(CHANNEL, "points reporter not configured", e, GSLog.Level.ERROR)
			return e
		pem = f.get_as_text()

	var probe := _sign("probe".to_utf8_buffer(), pem)
	if not probe.ok:
		GSLog.result(CHANNEL, "the points signing key cannot sign", probe, GSLog.Level.ERROR)
		return probe.wrap("The points signing key cannot sign.")

	config = p_config
	_key_pem = pem
	_journal_path = "" if GSPlatform.is_web() else config.resolved_queue_path()
	if _journal_path != "" and _journal_loaded != _journal_path:
		_journal_loaded = _journal_path
		_replay_journal()
	_restart_timer()
	GSLog.info(CHANNEL, "points reporter configured", {
		"app": config.app_id, "server": config.server_id,
		"flush_interval_secs": config.flush_interval_secs,
		"max_batch_events": config.max_batch_events,
		"max_pending_events": config.max_pending_events,
		"queue_path": _journal_path, "replayed": replayed,
	})
	return GSResult.success(null)


func is_configured() -> bool:
	return config != null and _key_pem != ""


func _ready() -> void:
	_restart_timer()


func _restart_timer() -> void:
	if _timer != null:
		_timer.queue_free()
		_timer = null
	if config == null or config.flush_interval_secs <= 0.0 or not is_inside_tree():
		return
	_timer = Timer.new()
	_timer.wait_time = config.flush_interval_secs
	_timer.timeout.connect(_on_timer)
	add_child(_timer)
	_timer.start()


func _on_timer() -> void:
	await flush()


## Whether this process may report: a server, never a web build or a client.
func is_server_side() -> bool:
	if GSPlatform.is_web():
		return false
	if is_inside_tree() and multiplayer.has_multiplayer_peer() and not multiplayer.is_server():
		return false
	return true


static func is_player_key(candidate: String) -> bool:
	if candidate.begins_with(ACCOUNT_PREFIX):
		return false
	return RegEx.create_from_string("^[A-Za-z0-9._:-]{1,64}$").search(candidate) != null


## Queues one event. [param player] is the player's scoped key, never an account id.
## [param meta] takes only [code]humans[/code] (int) and [code]vsBot[/code] (bool).
## [param event_id] defaults to a new unique id; pass your own (e.g. match:round:seq) to
## make reporting the same moment twice harmless. [param at] defaults to now (unix s).
## The value is the eventId.
func report(
	player: String, event_key: String, count: int = 1, meta: Dictionary = {},
	event_id: String = "", at: int = 0
) -> GSResult:
	if not is_server_side():
		return _refuse(GSError.CODE_FORBIDDEN, "Points events are reported by the server only.", "")
	if not is_configured():
		return _refuse(GSError.CODE_STATE, "The points reporter is not configured.", "")
	if not is_player_key(player):
		return _refuse(GSError.CODE_INVALID, "A player must be a scoped player key.", player.substr(0, 16))
	if _key_re.search(event_key) == null:
		return _refuse(GSError.CODE_INVALID, "An event key is 1-64 of a-z 0-9 _ . : -.", event_key.substr(0, 64))
	if count < 1 or count > MAX_COUNT:
		return _refuse(GSError.CODE_INVALID, "count must be 1 to %d." % MAX_COUNT, str(count))
	var clean_meta := {}
	for k in meta:
		var name := str(k)
		if not META_KEYS.has(name):
			return _refuse(GSError.CODE_INVALID, "Unknown meta key; only humans and vsBot are sent.", name)
	if meta.has("humans"):
		if typeof(meta["humans"]) != TYPE_INT or int(meta["humans"]) < 0:
			return _refuse(GSError.CODE_INVALID, "meta.humans must be an int of 0 or more.", str(meta["humans"]))
		clean_meta["humans"] = int(meta["humans"])
	if meta.has("vsBot"):
		if typeof(meta["vsBot"]) != TYPE_BOOL:
			return _refuse(GSError.CODE_INVALID, "meta.vsBot must be a bool.", str(meta["vsBot"]))
		clean_meta["vsBot"] = bool(meta["vsBot"])

	var id := event_id
	if id == "":
		_seq += 1
		id = "%s:%d" % [_boot_id, _seq]
	if _id_re.search(id) == null:
		return _refuse(GSError.CODE_INVALID, "An eventId is 1-128 of A-Z a-z 0-9 _ . : -.", id.substr(0, 128))

	var when := at if at != 0 else int(Time.get_unix_time_from_system())
	if when <= 0:
		return _refuse(GSError.CODE_INVALID, "at must be a positive unix time.", str(when))

	if config.max_pending_events > 0 and pending() >= config.max_pending_events:
		# Loud, not lossy: the caller learns the event was not taken.
		if not _warned_full:
			_warned_full = true
			GSLog.error(CHANNEL, "points events are being refused: max_pending_events reached", {
				"max_pending_events": config.max_pending_events, "last_error": last_error,
			})
		return GSResult.fail(
			GSError.CODE_STATE, "Too many points events are waiting to be sent.",
			"max_pending_events=%d" % config.max_pending_events
		)

	var ev := {"eventId": id, "eventKey": event_key, "player": player, "at": when}
	if count != 1:
		ev["count"] = count
	if not clean_meta.is_empty():
		ev["meta"] = clean_meta
	_queue.append(ev)
	reported += 1
	_journal_append({"e": ev})
	return GSResult.success(id)


func _refuse(code: String, message: String, detail: String) -> GSResult:
	var res := GSResult.fail(code, message, detail)
	GSLog.result(CHANNEL, "points event refused", res, GSLog.Level.WARN)
	return res


## Signs what is queued into batches and sends every batch waiting, oldest first.
## The value is the number of events the site answered for.
func flush() -> GSResult:
	if _flushing:
		return GSResult.success(0)
	if _queue.is_empty() and _outbox.is_empty():
		return GSResult.success(0)
	if not is_configured():
		return GSResult.fail(GSError.CODE_STATE, "The points reporter is not configured.")
	var backbone := _client()
	if backbone == null:
		if not _warned_no_client:
			_warned_no_client = true
			GSLog.warn(CHANNEL, "points events are waiting and there is no backbone client", {
				"service": String(client_service), "pending": pending(),
			})
		return GSResult.fail(GSError.CODE_STATE, "No backbone client is available.")

	_flushing = true
	var sealed := _seal()
	if not sealed.ok:
		_flushing = false
		return sealed

	var answered := 0
	while not _outbox.is_empty():
		var entry: Dictionary = _outbox[0]
		var res: GSResult = await backbone.call(
			"post_integration", EVENTS_PATH, {"batch": entry["batch"], "sig": entry["sig"]}
		)
		if not res.ok:
			failures += 1
			last_error = str(res.error)
			if _should_retry(res.error):
				if not _failing:
					GSLog.warn(CHANNEL, "points reporting is failing; the signed batch will be resent", {
						"pending": pending(), "error": last_error,
					})
				_failing = true
			else:
				_outbox.pop_front()
				var ids: PackedStringArray = entry["ids"]
				_journal_append({"d": Array(ids)})
				dropped += ids.size()
				GSLog.error(CHANNEL, "the site refused a points batch; it was dropped", {
					"dropped": ids.size(), "error": last_error, "scope": SCOPE_WRITE,
				})
				batch_dropped.emit(ids, last_error)
			_flushing = false
			return res.wrap("Could not report points events.")

		_outbox.pop_front()
		_journal_append({"d": Array(entry["ids"] as PackedStringArray)})
		var results: Array = []
		if res.value is Dictionary and (res.value as Dictionary).get("results") is Array:
			results = (res.value as Dictionary)["results"]
		_tally(results)
		answered += (entry["ids"] as PackedStringArray).size()
		events_settled.emit(results)

	if _failing:
		_failing = false
		GSLog.info(CHANNEL, "points reporting recovered", {"answered": answered})
	_warned_full = false
	_warned_no_client = false
	_flushing = false
	if pending() == 0:
		_journal_rewrite()
	return GSResult.success(answered)


func _seal() -> GSResult:
	while not _queue.is_empty():
		var take := _queue.size()
		if config.max_batch_events > 0:
			take = mini(take, config.max_batch_events)
		var events: Array = []
		for i in take:
			events.append(_queue[i])
		var text := JSON.stringify({
			"v": VERSION, "app": config.app_id, "server": config.server_id, "events": events,
		})
		var sig := _sign(text.to_utf8_buffer(), _key_pem)
		if not sig.ok:
			last_error = str(sig.error)
			GSLog.result(CHANNEL, "could not sign a points batch; events stay queued", sig, GSLog.Level.ERROR)
			return sig.wrap("Could not sign points events.")
		var ids := PackedStringArray()
		for ev in events:
			ids.append(str(ev["eventId"]))
		_outbox.append({"batch": text, "sig": str(sig.value), "ids": ids})
		_journal_append({"b": {"batch": text, "sig": str(sig.value), "ids": Array(ids)}})
		for i in take:
			_queue.pop_front()
	return GSResult.success(null)


# Resending the same bytes only helps when the site never judged them: a network fault,
# a 5xx or a 429. Any other 4xx (bad_batch, 413, 401, 403) would fail the same forever.
func _should_retry(error: GSError) -> bool:
	if error == null or not error.is_retryable():
		return false
	var status := error.http_status
	return status == 0 or status == 408 or status == 429 or status >= 500


func _tally(results: Array) -> void:
	for r in results:
		if not r is Dictionary:
			continue
		match str(r.get("status", "")):
			"accepted":
				accepted += 1
			"duplicate":
				duplicate += 1
			"refused":
				refused += 1
				var code := str(r.get("code", ""))
				# Once per code: a bot match refused every round is policy, not news.
				if not _refusal_codes_seen.has(code):
					_refusal_codes_seen[code] = true
					GSLog.warn(CHANNEL, "the site refused points events", {
						"code": code, "detail": str(r.get("detail", "")),
					})


func _sign(bytes: PackedByteArray, pem: String) -> GSResult:
	if signer.is_valid():
		return signer.call(bytes, pem)
	var path := ""
	for entry in ProjectSettings.get_global_class_list():
		if StringName(entry.get("class", "")) == SIGNER_CLASS:
			path = str(entry.get("path", ""))
			break
	if path == "":
		return GSResult.fail(
			GSError.CODE_UNSUPPORTED,
			"No signer: install dot-cloud (GSCloudSignature) or set signer."
		)
	var script: Script = load(path)
	return script.call("sign", bytes, pem)


# One JSON line each: {"e": event} queued, {"b": {batch, sig, ids}} sealed, {"d": [ids]}
# answered or dropped. Appending keeps report() cheap however long the site is away;
# the file is rewritten whole only at load and once nothing is pending.
func _journal_append(entry: Dictionary) -> void:
	if _journal_path == "":
		return
	var f: FileAccess = null
	if FileAccess.file_exists(_journal_path):
		f = FileAccess.open(_journal_path, FileAccess.READ_WRITE)
		if f != null:
			f.seek_end()
	else:
		DirAccess.make_dir_recursive_absolute(_journal_path.get_base_dir())
		f = FileAccess.open(_journal_path, FileAccess.WRITE)
	if f == null:
		_journal_failed(error_string(FileAccess.get_open_error()))
		return
	f.store_line(JSON.stringify(entry))
	f.close()
	_journal_ok()


# Writes what is pending now as a fresh journal (temp file, then rename), or removes the
# file when nothing is.
func _journal_rewrite() -> void:
	if _journal_path == "":
		return
	if pending() == 0:
		if FileAccess.file_exists(_journal_path):
			var err := DirAccess.remove_absolute(_journal_path)
			if err != OK:
				_journal_failed("remove: %s" % error_string(err))
				return
		_journal_ok()
		return
	DirAccess.make_dir_recursive_absolute(_journal_path.get_base_dir())
	var tmp := _journal_path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		_journal_failed(error_string(FileAccess.get_open_error()))
		return
	for entry in _outbox:
		f.store_line(JSON.stringify({"b": {
			"batch": entry["batch"], "sig": entry["sig"], "ids": Array(entry["ids"] as PackedStringArray),
		}}))
	for ev in _queue:
		f.store_line(JSON.stringify({"e": ev}))
	f.close()
	var moved := DirAccess.rename_absolute(tmp, _journal_path)
	if moved != OK:
		_journal_failed("rename: %s" % error_string(moved))
		return
	_journal_ok()


func _journal_failed(why: String) -> void:
	# Loud once per outage: events are still held in memory and sent, but a crash now
	# would lose them.
	if journal_error == "":
		GSLog.error(CHANNEL, "cannot write the points journal; unsent events would not survive a crash", {
			"queue_path": _journal_path, "error": why,
		})
	journal_error = why


func _journal_ok() -> void:
	if journal_error != "":
		GSLog.info(CHANNEL, "the points journal is being written again", {"queue_path": _journal_path})
	journal_error = ""


# Reads the journal an earlier run left and queues its unanswered events ahead of
# anything reported in this run. A torn last line (a crash mid-write) is skipped.
func _replay_journal() -> void:
	if not FileAccess.file_exists(_journal_path):
		return
	var f := FileAccess.open(_journal_path, FileAccess.READ)
	if f == null:
		_journal_failed("read: %s" % error_string(FileAccess.get_open_error()))
		return
	var events := {}  # eventId -> event, in report order
	var batches: Array[Dictionary] = []
	var done := {}
	var torn := 0
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line == "":
			continue
		var json := JSON.new()
		var parsed: Variant = json.data if json.parse(line) == OK else null
		if not parsed is Dictionary:
			torn += 1
			continue
		var d: Dictionary = parsed
		if d.get("e") is Dictionary:
			var ev := _event_from_json(d["e"])
			var eid := str(ev.get("eventId", ""))
			if eid != "":
				events[eid] = ev
		elif d.get("b") is Dictionary:
			var b: Dictionary = d["b"]
			var ids := PackedStringArray()
			for x in b.get("ids", []):
				ids.append(str(x))
				events.erase(str(x))
			if ids.size() > 0 and str(b.get("batch", "")) != "":
				batches.append({"batch": str(b["batch"]), "sig": str(b.get("sig", "")), "ids": ids})
		elif d.get("d") is Array:
			for x in d["d"]:
				done[str(x)] = true
				events.erase(str(x))
	f.close()

	var known := {}
	for entry in _outbox:
		for x in entry["ids"]:
			known[x] = true
	for ev in _queue:
		known[str(ev["eventId"])] = true
	var old_outbox: Array[Dictionary] = []
	var old_queue: Array[Dictionary] = []
	for b in batches:
		var ids: PackedStringArray = b["ids"]
		if done.has(ids[0]) or known.has(ids[0]):
			continue
		old_outbox.append(b)
		replayed += ids.size()
	for eid in events:
		if known.has(eid):
			continue
		old_queue.append(events[eid])
		replayed += 1
	var old_batches := old_outbox.size()
	old_outbox.append_array(_outbox)
	_outbox = old_outbox
	old_queue.append_array(_queue)
	_queue = old_queue
	if torn > 0:
		GSLog.warn(CHANNEL, "skipped unreadable lines in the points journal", {
			"queue_path": _journal_path, "lines": torn,
		})
	if replayed > 0:
		GSLog.info(CHANNEL, "resending points events an earlier run did not get answered", {
			"queue_path": _journal_path, "events": replayed, "batches": old_batches,
		})
	_journal_rewrite()


# JSON reads every number back as a float; the site's event fields are integers.
static func _event_from_json(raw: Dictionary) -> Dictionary:
	var ev := raw.duplicate(true)
	for k in ["at", "count"]:
		if ev.has(k):
			ev[k] = int(ev[k])
	if ev.get("meta") is Dictionary and (ev["meta"] as Dictionary).has("humans"):
		ev["meta"]["humans"] = int(ev["meta"]["humans"])
	return ev


func _client() -> Object:
	if client != null and is_instance_valid(client):
		return client
	var found := GSRegistry.get_service(client_service)
	if found != null and found.has_method("post_integration"):
		return found
	return null


func is_available() -> bool:
	return _client() != null


## Events not yet answered for: queued plus sealed and waiting to be resent.
func pending() -> int:
	var n := _queue.size()
	for entry in _outbox:
		n += (entry["ids"] as PackedStringArray).size()
	return n


func describe() -> Dictionary:
	return {
		"configured": is_configured(),
		"available": is_available(),
		"app": config.app_id if config != null else 0,
		"server": config.server_id if config != null else 0,
		"pending": pending(),
		"batches_waiting": _outbox.size(),
		"reported": reported,
		"accepted": accepted,
		"duplicate": duplicate,
		"refused": refused,
		"dropped": dropped,
		"failures": failures,
		"last_error": last_error,
		"queue_path": _journal_path,
		"replayed": replayed,
		"journal_error": journal_error,
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("points reporter: %d pending, %d accepted, %d duplicate, %d refused, %d dropped, %d failures" % [
		pending(), accepted, duplicate, refused, dropped, failures
	])
	if not is_configured():
		out.append("  not configured; nothing is being reported")
	elif not is_available():
		out.append("  no backbone client; events are waiting")
	if last_error != "":
		out.append("  last error: %s" % last_error)
	if journal_error != "":
		out.append("  journal not written (a crash would lose pending events): %s" % journal_error)
	return out
