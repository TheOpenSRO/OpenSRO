extends SceneTree

## Dev tool: for one layout, reports how much of each section's own control
## area is covered by every other section's controls.
##
## This answers "which of a window's sections are drawn together?", which a
## layout does not say and which cannot be guessed at. `ifguild.txt` has ten
## sections and `ifskill.txt` has three; `HudWindow` builds "Create" plus
## whichever extras it is told to, and building an alternate mode alongside
## the normal one draws two layouts over each other.
##
## The rule the numbers give:
##
## - **0% both ways: they compose.** Two sections whose controls never
##   touch are laid out to sit together. ifguild's GuildInfo,
##   NotifySubBox, SortBtn, MemberView and Command are pairwise 0% -- they
##   tile the window top to bottom with the buttons down the right.
## - **High coverage: they are alternates.** ifguild's NotifyContents
##   covers 85% of MemberView and MemberView covers 100% of it: the notice
##   text and the member list are the same box, one at a time.
##
## Checked against a case the client itself settles: ifskill's MainSkillWnd
## and Withdrawal come out heavily overlapping, and the binary picks between
## them on `m_bySkillWndType`.
##
## Usage:
##   godot4 --headless --path client --script res://tools/sweep_section_overlap.gd -- \
##     --pk2=/path/to/Media.pk2 --file=ifguild

## Sampling step, in pixels. Coverage is measured by sampling each control's
## rect rather than by exact rectangle subtraction: the answers here are
## "nothing" or "nearly all", so a 2-pixel grid separates them with room to
## spare and stays a dozen lines instead of a hundred.
const SAMPLE_STEP := 2

func _arg(flag: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return ""

func _init() -> void:
	var pk2_path := _arg("--pk2")
	var file_name := _arg("--file")
	if pk2_path == "" or file_name == "":
		printerr("usage: --pk2=<Media.pk2> --file=<resinfo name>")
		quit(2)
		return
	var archive := Pk2Reader.open(pk2_path)
	if archive == null:
		printerr("could not open ", pk2_path)
		quit(1)
		return
	var path := "resinfo\\" + file_name + ".txt"
	var bytes := AssetSource.read_bytes(path, archive)
	if bytes.is_empty():
		printerr("not in the archive: ", path)
		quit(1)
		return

	var layout := UiLayoutParser.parse(bytes)
	var names: Array[String] = []
	var rects := {}
	for key in layout.sections:
		var sec: UiLayoutParser.SectionDef = layout.sections[key]
		var list: Array[Rect2i] = []
		for c in sec.controls:
			if c.rect.size.x > 0 and c.rect.size.y > 0:
				list.append(c.rect)
		names.append(key)
		rects[key] = list

	print("=== %s -- how much of ROW's control area sits under COLUMN's controls" % path)
	var header := "%-18s" % ""
	for n in names:
		header += "%12s" % n.substr(0, 11)
	print(header)
	for a in names:
		var row := "%-18s" % a
		for b in names:
			if a == b:
				row += "%12s" % "-"
			else:
				row += "%11d%%" % roundi(100.0 * _covered(rects[a], rects[b]))
		print(row)

	print("")
	print("sections that never touch another (candidates to build together):")
	for a in names:
		var independent := true
		for b in names:
			if a == b:
				continue
			if _covered(rects[a], rects[b]) > 0.0 or _covered(rects[b], rects[a]) > 0.0:
				independent = false
				break
		if independent:
			print("  ", a)
	quit(0)

## The fraction of `a`'s total control area that lies under any of `b`'s.
func _covered(a: Array, b: Array) -> float:
	var total := 0.0
	var covered := 0.0
	for rect in a:
		var r: Rect2i = rect
		var area := float(r.size.x * r.size.y)
		total += area
		var samples := 0
		var hits := 0
		var y := r.position.y
		while y < r.position.y + r.size.y:
			var x := r.position.x
			while x < r.position.x + r.size.x:
				samples += 1
				for other in b:
					if (other as Rect2i).has_point(Vector2i(x, y)):
						hits += 1
						break
				x += SAMPLE_STEP
			y += SAMPLE_STEP
		if samples > 0:
			covered += area * float(hits) / float(samples)
	return covered / total if total > 0.0 else 0.0
