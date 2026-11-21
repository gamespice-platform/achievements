class_name GSAchievementStoreFile
extends GSAchievementStore

## One JSON file per player, under a directory.
##
## For a single-player game, a listen server, or a small community that would rather
## have files it can read than a database it has to run.
##
## [b]The filename is derived, never the player key.[/b] A key arrives from a login
## and can be anything at all; a store that used it directly is one
## [code]../../[/code] away from writing outside its directory. [GSPaths.slugify]
## plus a hash of the whole key is what makes the name both safe and unique — the
## slug alone is not, because two different keys can slugify to the same string, and
## GameSpice Timer shipped exactly that: [code]surf_kitsune2[/code] and
## [code]surf_kitsune3[/code] both became [code]surf_kitsune_[/code] and shared one
## records file.

## Where the files go.
var directory: String = "user://gs_achievements"

## Written atomically, by [GSSaveStoreFile] (GameSpice Save), which also flushes a browser's IndexedDB. A crash mid-write leaves the old file or the new one and never
## half of one — which for a progress file is indistinguishable from a player losing
## everything.
var atomic: bool = true

var _files: GSSaveStoreFile


func _init(p_directory: String = "user://gs_achievements") -> void:
	directory = p_directory


## The file name, without its folder or ending, a player's progress lives in.
func key_for(player: String) -> String:
	var slug := GSPaths.slugify(player, 40)
	if slug == "":
		slug = "player"

	# The hash is what makes it unique; the slug is what makes it readable. Both
	# matter — an operator looking for one player's file should be able to find it,
	# and two players must never share one.
	var digest := GSHash.sha256_text(player).substr(0, 16)

	return "%s-%s" % [slug, digest]


## The file a player's progress lives in.
func path_for(player: String) -> String:
	return files().path_for(key_for(player))


## The file store under this one: the folder, the [code].json[/code] ending, and the atomic switch as they stand now. The key is derived above, so nothing is checked on it.
func files() -> GSSaveStoreFile:
	if _files == null:
		_files = GSSaveStoreFile.new()
		_files.suffix = ".json"
		_files.key_check = func(key: String) -> bool: return not key.is_empty()
	_files.directory = directory
	_files.atomic = atomic
	return _files


func _load_progress(player: String) -> GSResult:
	var path := path_for(player)

	if not FileAccess.file_exists(path):
		return GSResult.success(GSAchievementProgress.new())

	var read := GSPaths.read_json(path)
	if not read.ok:
		# Deliberately a failure and not a fresh player. A file that exists and cannot
		# be read is a file that must not be overwritten with an empty one, which is
		# what handing back a blank progress would cause on the next save.
		return read.wrap("Could not read achievement progress.")

	var data: Variant = read.value
	if typeof(data) != TYPE_DICTIONARY:
		return GSResult.fail(
			GSError.CODE_PARSE, "Achievement progress is an object.", path
		)

	return GSAchievementProgress.from_dictionary(data as Dictionary)


func _save_progress(player: String, progress: GSAchievementProgress) -> GSResult:
	var written := files().write(key_for(player), JSON.stringify(progress.to_dictionary(), "\t"))

	if not written.ok:
		return written.wrap("Could not save achievement progress.")

	# The browser's IndexedDB flush is done by the file store.
	return GSResult.success(1)
