extends SceneTree

## Dev/QA tool (round 789, OURS): which layer of the archive set serves a
## path -- custom/, a pack (by file name) or a base archive -- and which
## layers under it hold the same path. The set is the one the game would
## open from this environment (AssetArchives.current(): the source mode, the
## OPENSRO_*_PK2_PATH archives, OPENSRO_PACK_DIR, OPENSRO_CUSTOM_DIR).
##
## Usage (on the render box, docs/DEBUG_TOOLS.md):
##   OPENSRO_PK2_PATH=/opt/sro-files/client/Data.pk2 ... OPENSRO_PACK_DIR=/var/tmp/k789/packs \
##   godot --headless --path client --script res://tools/which_layer.gd -- \
##     "prim\\mtrl\\foo.ddj" "textdata\\itemdata.txt"
## Prints the set's own load lines, then one `WHICH <path> -> <layer> (<file>);
## also in ...` line a path. A game run answers the same with
## OPENSRO_QA_WHICH="path;path".

func _init() -> void:
	var paths := OS.get_cmdline_user_args()
	if paths.is_empty():
		printerr("usage: --script res://tools/which_layer.gd -- <path> [<path> ...]")
		quit(2)
		return
	var s := AssetArchives.current()
	for line in s.describe():
		print("SET " + line)
	for p in paths:
		print("WHICH " + AssetArchives.describe_which(s.which(p)))
	quit(0)
