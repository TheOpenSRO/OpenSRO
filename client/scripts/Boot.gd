extends Node

# Entry point. Nothing is bundled with the client -- players point it at
# their own legally-owned pk2 files (not needed yet for the login/character
# select flow, only once real asset rendering exists).

func _ready() -> void:
	print("SRRevamp boot: no bundled game data. Point PK2_DATA_DIR at your own pk2 files.")
	get_tree().change_scene_to_file("res://scenes/Login.tscn")
