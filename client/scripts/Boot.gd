extends Node

# Entry point. Nothing is bundled with the client -- players point it at
# their own legally-owned pk2 files (not needed yet for the login/character
# select flow, only once real asset rendering exists).

func _ready() -> void:
	print("SRRevamp boot: no bundled game data. Point PK2_DATA_DIR at your own pk2 files.")
	# Deferred: calling change_scene_to_file directly from _ready() fights
	# the scene tree's own in-progress node-addition for this node,
	# producing "Parent node is busy adding/removing children" errors.
	get_tree().change_scene_to_file.call_deferred("res://scenes/Login.tscn")
