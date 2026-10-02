extends SceneTree

## Dev tool (round 693): write or read a renderer choice with RendererChoice,
## the code the game itself uses, to a given override.cfg -- so a box run can
## show that the file it writes is one Godot obeys (start a project with that
## file beside it, no renderer flag, and read the engine's banner).
##
##   godot4 --headless --path client --script res://tools/renderer_choice_cli.gd -- \
##     --path=/var/tmp/x/override.cfg [--choose=gl_compatibility|forward_plus]

func _initialize() -> void:
	var path := ""
	var choose := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--path="):
			path = a.substr(7)
		elif a.begins_with("--choose="):
			choose = a.substr(9)
	if path == "":
		printerr("need --path=<override.cfg>")
		quit(2)
		return
	if choose != "":
		var err := RendererChoice.choose(RendererChoice.normalise(choose), path)
		print("RENDERER CHOICE: choose %s -> %s (error %d)" % [choose, path, err])
	print("RENDERER CHOICE: %s holds '%s'" % [path, RendererChoice.chosen(path)])
	quit(0)
