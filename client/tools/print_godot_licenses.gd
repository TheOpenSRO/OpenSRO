extends SceneTree

## Prints Godot Engine's own licence, the copyright of every third-party part
## built into it, and the full text of each licence those parts use, from the
## engine itself (Engine.get_license_text / get_copyright_info /
## get_license_info). release.yml appends this to each zip's
## THIRD_PARTY_NOTICES.txt (round 668's review, L9): the exported game is the
## Godot 4.2.2 export template, which is MIT-licensed and asks that its notice
## travel with every copy. The editor that runs this is the same 4.2.2 build,
## so the list matches the engine shipped. It can list a few editor-only
## parts the template leaves out, which over-attributes and never under-attributes.
##
##   godot --headless --path client --script res://tools/print_godot_licenses.gd -- --out=/abs/godot_licenses.txt

func _init() -> void:
	var out := PackedStringArray()
	out.append("GODOT ENGINE %s" % Engine.get_version_info().string)
	out.append("")
	out.append(Engine.get_license_text())
	out.append("")
	out.append("Third-party components in Godot Engine:")
	for component in Engine.get_copyright_info():
		out.append("")
		out.append("- %s" % component["name"])
		for part in component["parts"]:
			for c in part["copyright"]:
				out.append("    Copyright %s" % c)
			out.append("    License: %s" % part["license"])
	var licenses: Dictionary = Engine.get_license_info()
	var names := licenses.keys()
	names.sort()
	for name in names:
		out.append("")
		out.append("------------------------------------------------------------------------")
		out.append("License: %s" % name)
		out.append("")
		out.append(licenses[name])
	var path := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="):
			path = arg.substr(6)
	var f := FileAccess.open(path, FileAccess.WRITE) if path != "" else null
	if f == null:
		printerr("print_godot_licenses: give --out=<absolute path>")
		quit(1)
		return
	f.store_string("\n".join(out) + "\n")
	f.close()
	print("wrote %s (%d lines)" % [path, out.size()])
	quit()
