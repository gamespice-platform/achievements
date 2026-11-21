class_name GSPointsReporterConfig
extends GSConfig

## Settings for [GSPointsReporter]. Layers, weakest first: defaults < a JSON file <
## `DOT_POINTS_*` < `--points-<key>=`. The private key itself is never read from the
## environment or the command line; point [member private_key_path] at a file instead.

## The Gamespice app id the events are credited under. Required.
@export var app_id: int = 0

## This server's id on the site; the registered points key belongs to it. Required.
@export var server_id: int = 0

## A file holding the server's RSA private key (PEM, at least 2048 bits).
@export var private_key_path: String = ""

## The private key PEM itself, for a host that loads it from a secret store.
## Sensitive: refused from the environment and the command line, redacted in dumps.
@export var private_key_pem: String = ""

## Seconds between automatic flushes. 0 runs no timer: the game calls flush() itself.
@export var flush_interval_secs: float = 10.0

## Events per signed request. 0 = unlimited, everything pending in one request.
## Keep it at or under the site's appPoints.maxEventsPerBatch, or the site answers 413.
@export var max_batch_events: int = 100

## Events held while the site cannot be reached. 0 = unlimited. Past it report() fails
## loudly rather than dropping anything.
@export var max_pending_events: int = 0

## Keep unsent events in a journal file, so a crash or restart does not lose earned
## points: the next configure() with the same file resends them (the same eventIds and,
## for a sealed batch, the same signed bytes, so the site never pays twice).
@export var persist_queue: bool = true

## The journal file. Empty = user://dot_points/queue-<app_id>-<server_id>.jsonl, so two
## servers on one host never share one. Give each server process its own file.
@export var queue_path: String = ""


## The journal file this config writes, or "" when [member persist_queue] is off.
func resolved_queue_path() -> String:
	if not persist_queue:
		return ""
	if queue_path.strip_edges() != "":
		return queue_path.strip_edges()
	return "user://dot_points/queue-%d-%d.jsonl" % [app_id, server_id]


func env_prefix() -> String:
	return "DOT_POINTS_"


func cli_prefix() -> String:
	return "--points-"


func sensitive_keys() -> PackedStringArray:
	return PackedStringArray(["private_key_pem"])


func validate() -> GSResult:
	var problems := PackedStringArray()
	if app_id <= 0:
		problems.append("app_id must be a positive app id (is %d)" % app_id)
	if server_id <= 0:
		problems.append("server_id must be a positive server id (is %d)" % server_id)
	var has_path := private_key_path.strip_edges() != ""
	var has_pem := private_key_pem.strip_edges() != ""
	if not has_path and not has_pem:
		problems.append("set private_key_path or private_key_pem")
	if has_path and has_pem:
		problems.append("set only one of private_key_path and private_key_pem")
	if is_nan(flush_interval_secs) or is_inf(flush_interval_secs) or flush_interval_secs < 0.0:
		problems.append("flush_interval_secs must be 0 (no timer) or more (is %s)" % flush_interval_secs)
	if max_batch_events < 0:
		problems.append("max_batch_events must be 0 (unlimited) or more (is %d)" % max_batch_events)
	if persist_queue and queue_path.strip_edges().ends_with("/"):
		problems.append("queue_path must name a file, not a folder (is %s)" % queue_path)
	if max_pending_events < 0:
		problems.append("max_pending_events must be 0 (unlimited) or more (is %d)" % max_pending_events)
	if not problems.is_empty():
		return GSResult.fail(
			GSError.CODE_INVALID, "The points reporter config is invalid.", "; ".join(problems)
		)
	return GSResult.success(null)
