extends Node

# Entry point. Prompts the player to point at their own legally-owned
# Media.pk2 / Data.pk2 files; nothing is bundled with the client.

func _ready() -> void:
	print("SRRevamp boot: no bundled game data. Point PK2_DATA_DIR at your own pk2 files.")
