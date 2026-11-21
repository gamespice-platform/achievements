class_name GSAchievementStoreMemory
extends GSAchievementStore

## Progress held in memory and lost on exit.
##
## The default, and the right one for a game that has not decided where progress
## lives yet — an achievement system that refuses to run without a database is one
## nobody tries. It is also what every test uses.
##
## [b]The tracker does not default to a file store.[/b] Writing a file per player
## under [code]user://[/code] on a dedicated server is a decision an operator should
## make on purpose, and a default that silently starts writing to disk is the kind
## nobody notices until the disk is full.

var _rows: Dictionary = {}


func _load_progress(player: String) -> GSResult:
	if not _rows.has(player):
		return GSResult.success(GSAchievementProgress.new())

	# Round-tripped rather than handed back. Two callers holding one progress object
	# is two callers writing to it, and the second save wins silently.
	return GSAchievementProgress.from_dictionary(
		(_rows[player] as Dictionary).duplicate(true)
	)


func _save_progress(player: String, progress: GSAchievementProgress) -> GSResult:
	_rows[player] = progress.to_dictionary()
	return GSResult.success(1)


func size() -> int:
	return _rows.size()


func clear() -> void:
	_rows.clear()
