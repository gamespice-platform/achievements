extends RefCounted

## GameSpice Achievements' API level; the bump rule is on [GSAddonApi]. LEVEL rises by one
## for anything new a game could call. OLDEST is raised to LEVEL when something a game
## could have called is removed or changes meaning.

# 1: everything before this file existed (an absent file reads as 1).
# 2: the points journal: GSPointsReporterConfig.persist_queue, queue_path, resolved_queue_path();
#    GSPointsReporter.replayed, journal_error (unsent events are resent on the next configure()).
const LEVEL := 2
const OLDEST := 1
