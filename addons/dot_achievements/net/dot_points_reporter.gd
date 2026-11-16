class_name DotPointsReporter
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
## the site deduplicates on (app, server, eventId). Signing goes through dot-cloud's
## [code]DotCloudSignature.sign[/code] (RSA-SHA256), reached by name so this addon still
## loads without dot-cloud; [member signer] replaces it.

signal events_settled(results: Array)
signal batch_dropped(event_ids: PackedStringArray, error: String)

const CHANNEL := "achievements.points"
const SCOPE_WRITE := "POINTS_WRITE"
const EVENTS_PATH := "points/events"
const VERSION := 1
const ACCOUNT_PREFIX := "backbone:"
const SIGNER_CLASS := &"DotCloudSignature"
const MAX_COUNT := 2147483647
const META_KEYS := ["humans", "vsBot"]

## The backbone client: any object with [code]post_integration(String, Dictionary)[/code],
## dot-auth's DotBackboneClient in practice. Found under [member client_service] if unset.
var client: Object = null
var client_service: StringName = &"dot_backbone_client"

## [code]func(bytes: PackedByteArray, private_key_pem: String) -> DotResult[/code] whose
## value is the base64 signature. Empty uses DotCloudSignature.sign.
var signer: Callable = Callable()

var config: DotPointsReporterConfig = null

var reported: int = 0
var accepted: int = 0
var duplicate: int = 0
var refused: int = 0
var dropped: int = 0
var failures: int = 0
var last_error: String = ""

var _key_pem: String = ""
var _boot_id: String = ""
var _seq: int = 0
var _queue: Array[Dictionary] = []
# Sealed batches: {batch, sig, ids}. Kept exactly as signed, so a resend is the same bytes.
var _outbox: Array[Dictionary] = []
var _flushing: bool = false
var _timer: Timer = null

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
func configure(p_config: DotPointsReporterConfig) -> DotResult:
	if p_config == null:
		return DotResult.fail(DotError.CODE_INVALID, "No points reporter config.")
	var valid := p_config.validate()
	if not valid.ok:
		DotLog.result(CHANNEL, "points reporter not configured", valid, DotLog.Level.ERROR)
		return valid

	var pem := p_config.private_key_pem
	if p_config.private_key_path.strip_edges() != "":
		var f := FileAccess.open(p_config.private_key_path, FileAccess.READ)
		if f == null:
			var e := DotResult.fail(
				DotError.CODE_IO, "Could not read the points signing key.",
				"%s: %s" % [p_config.private_key_path, error_string(FileAccess.get_open_error())]
			)
			DotLog.result(CHANNEL, "points reporter not configured", e, DotLog.Level.ERROR)
			return e
		pem = f.get_as_text()

	var probe := _sign("probe".to_utf8_buffer(), pem)
	if not probe.ok:
		DotLog.result(CHANNEL, "the points signing key cannot sign", probe, DotLog.Level.ERROR)
		return probe.wrap("The points signing key cannot sign.")

	config = p_config
	_key_pem = pem
	_restart_timer()
	DotLog.info(CHANNEL, "points reporter configured", {
		"app": config.app_id, "server": config.server_id,
		"flush_interval_secs": config.flush_interval_secs,
		"max_batch_events": config.max_batch_events,
		"max_pending_events": config.max_pending_events,
	})
	return DotResult.success(null)


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
	if DotPlatform.is_web():
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
) -> DotResult:
	if not is_server_side():
		return _refuse(DotError.CODE_FORBIDDEN, "Points events are reported by the server only.", "")
	if not is_configured():
		return _refuse(DotError.CODE_STATE, "The points reporter is not configured.", "")
	if not is_player_key(player):
		return _refuse(DotError.CODE_INVALID, "A player must be a scoped player key.", player.substr(0, 16))
	if _key_re.search(event_key) == null:
		return _refuse(DotError.CODE_INVALID, "An event key is 1-64 of a-z 0-9 _ . : -.", event_key.substr(0, 64))
	if count < 1 or count > MAX_COUNT:
		return _refuse(DotError.CODE_INVALID, "count must be 1 to %d." % MAX_COUNT, str(count))
	var clean_meta := {}
	for k in meta:
		var name := str(k)
		if not META_KEYS.has(name):
			return _refuse(DotError.CODE_INVALID, "Unknown meta key; only humans and vsBot are sent.", name)
	if meta.has("humans"):
		if typeof(meta["humans"]) != TYPE_INT or int(meta["humans"]) < 0:
			return _refuse(DotError.CODE_INVALID, "meta.humans must be an int of 0 or more.", str(meta["humans"]))
		clean_meta["humans"] = int(meta["humans"])
	if meta.has("vsBot"):
		if typeof(meta["vsBot"]) != TYPE_BOOL:
			return _refuse(DotError.CODE_INVALID, "meta.vsBot must be a bool.", str(meta["vsBot"]))
		clean_meta["vsBot"] = bool(meta["vsBot"])

	var id := event_id
	if id == "":
		_seq += 1
		id = "%s:%d" % [_boot_id, _seq]
	if _id_re.search(id) == null:
		return _refuse(DotError.CODE_INVALID, "An eventId is 1-128 of A-Z a-z 0-9 _ . : -.", id.substr(0, 128))

	var when := at if at != 0 else int(Time.get_unix_time_from_system())
	if when <= 0:
		return _refuse(DotError.CODE_INVALID, "at must be a positive unix time.", str(when))

	if config.max_pending_events > 0 and pending() >= config.max_pending_events:
		# Loud, not lossy: the caller learns the event was not taken.
		if not _warned_full:
			_warned_full = true
			DotLog.error(CHANNEL, "points events are being refused: max_pending_events reached", {
				"max_pending_events": config.max_pending_events, "last_error": last_error,
			})
		return DotResult.fail(
			DotError.CODE_STATE, "Too many points events are waiting to be sent.",
			"max_pending_events=%d" % config.max_pending_events
		)

	var ev := {"eventId": id, "eventKey": event_key, "player": player, "at": when}
	if count != 1:
		ev["count"] = count
	if not clean_meta.is_empty():
		ev["meta"] = clean_meta
	_queue.append(ev)
	reported += 1
	return DotResult.success(id)


func _refuse(code: String, message: String, detail: String) -> DotResult:
	var res := DotResult.fail(code, message, detail)
	DotLog.result(CHANNEL, "points event refused", res, DotLog.Level.WARN)
	return res


## Signs what is queued into batches and sends every batch waiting, oldest first.
## The value is the number of events the site answered for.
func flush() -> DotResult:
	if _flushing:
		return DotResult.success(0)
	if _queue.is_empty() and _outbox.is_empty():
		return DotResult.success(0)
	if not is_configured():
		return DotResult.fail(DotError.CODE_STATE, "The points reporter is not configured.")
	var backbone := _client()
	if backbone == null:
		if not _warned_no_client:
			_warned_no_client = true
			DotLog.warn(CHANNEL, "points events are waiting and there is no backbone client", {
				"service": String(client_service), "pending": pending(),
			})
		return DotResult.fail(DotError.CODE_STATE, "No backbone client is available.")

	_flushing = true
	var sealed := _seal()
	if not sealed.ok:
		_flushing = false
		return sealed

	var answered := 0
	while not _outbox.is_empty():
		var entry: Dictionary = _outbox[0]
		var res: DotResult = await backbone.call(
			"post_integration", EVENTS_PATH, {"batch": entry["batch"], "sig": entry["sig"]}
		)
		if not res.ok:
			failures += 1
			last_error = str(res.error)
			if _should_retry(res.error):
				if not _failing:
					DotLog.warn(CHANNEL, "points reporting is failing; the signed batch will be resent", {
						"pending": pending(), "error": last_error,
					})
				_failing = true
			else:
				_outbox.pop_front()
				var ids: PackedStringArray = entry["ids"]
				dropped += ids.size()
				DotLog.error(CHANNEL, "the site refused a points batch; it was dropped", {
					"dropped": ids.size(), "error": last_error, "scope": SCOPE_WRITE,
				})
				batch_dropped.emit(ids, last_error)
			_flushing = false
			return res.wrap("Could not report points events.")

		_outbox.pop_front()
		var results: Array = []
		if res.value is Dictionary and (res.value as Dictionary).get("results") is Array:
			results = (res.value as Dictionary)["results"]
		_tally(results)
		answered += (entry["ids"] as PackedStringArray).size()
		events_settled.emit(results)

	if _failing:
		_failing = false
		DotLog.info(CHANNEL, "points reporting recovered", {"answered": answered})
	_warned_full = false
	_warned_no_client = false
	_flushing = false
	return DotResult.success(answered)


func _seal() -> DotResult:
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
			DotLog.result(CHANNEL, "could not sign a points batch; events stay queued", sig, DotLog.Level.ERROR)
			return sig.wrap("Could not sign points events.")
		var ids := PackedStringArray()
		for ev in events:
			ids.append(str(ev["eventId"]))
		_outbox.append({"batch": text, "sig": str(sig.value), "ids": ids})
		for i in take:
			_queue.pop_front()
	return DotResult.success(null)


# Resending the same bytes only helps when the site never judged them: a network fault,
# a 5xx or a 429. Any other 4xx (bad_batch, 413, 401, 403) would fail the same forever.
func _should_retry(error: DotError) -> bool:
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
					DotLog.warn(CHANNEL, "the site refused points events", {
						"code": code, "detail": str(r.get("detail", "")),
					})


func _sign(bytes: PackedByteArray, pem: String) -> DotResult:
	if signer.is_valid():
		return signer.call(bytes, pem)
	var path := ""
	for entry in ProjectSettings.get_global_class_list():
		if StringName(entry.get("class", "")) == SIGNER_CLASS:
			path = str(entry.get("path", ""))
			break
	if path == "":
		return DotResult.fail(
			DotError.CODE_UNSUPPORTED,
			"No signer: install dot-cloud (DotCloudSignature) or set signer."
		)
	var script: Script = load(path)
	return script.call("sign", bytes, pem)


func _client() -> Object:
	if client != null and is_instance_valid(client):
		return client
	var found := DotRegistry.get_service(client_service)
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
	return out
