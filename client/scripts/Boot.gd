extends Node

# Entry point. Nothing is bundled with the client -- players point it at
# their own legally-owned pk2 files (not needed yet for the login/character
# select flow, only once real asset rendering exists). See Pk2Config for
# how those files are found: a real "pk2" folder next to the executable,
# or the SRREVAMP_*_PK2_PATH environment variables for development.

func _ready() -> void:
	print("SRRevamp boot: no bundled game data -- put your own *.pk2 files in the 'pk2' folder next to this executable.")
	# Deferred: calling change_scene_to_file directly from _ready() fights
	# the scene tree's own in-progress node-addition for this node,
	# producing "Parent node is busy adding/removing children" errors.
	get_tree().change_scene_to_file.call_deferred("res://scenes/Login.tscn")
