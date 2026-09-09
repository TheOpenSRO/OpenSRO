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

## How much overlap still counts as "these sit side by side".
##
## The real answers cluster at either end -- ifguild's five composing
## sections are pairwise 0% and its alternates are 78-100% -- so anything
## in between is a header row sitting on the list it labels, which is
## composition. ifpartymatch's SlotListButton over SlotList is 8%.
const INDEPENDENT_THRESHOLD := 0.15

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
	# **Ignore "Create".** It holds the window's own frame, which spans the
	# whole window, so every other section is nearly 100% "under" it by
	# construction -- containment, not conflict. What separates a part of
	# the window from an alternate view is whether it overlaps the *other*
	# extras.
	#
	# And the question is not "does this section overlap anything", because
	# a part of the window is overlapped by every dialog that opens over it
	# -- ifguild's MemberView is 85% under NotifyContents and 95% under
	# GrantPower, and is still part of the window. It is "what is the
	# largest set of extras that are pairwise clear of each other", which
	# is one composed window; everything left out is a mode or a dialog.
	var extras: Array[String] = []
	for n in names:
		if n != "Create":
			extras.append(n)
	var compatible := {}
	for a in extras:
		for b in extras:
			if a == b:
				continue
			var both: float = maxf(_covered(rects[a], rects[b]), _covered(rects[b], rects[a]))
			compatible[a + "|" + b] = both <= INDEPENDENT_THRESHOLD

	var best: Array[String] = []
	_largest_clique(extras, [], compatible, 0, best)
	print("the largest set of extras that are pairwise clear of each other:")
	if best.is_empty():
		print("  (none -- every extra overlaps every other, so they are all modes)")
	for n in best:
		print("  ", n)
	if extras.size() < 2:
		print("  (one extra, so there is nothing to compare it against -- this says")
		print("   nothing about whether it is part of the window. ifinventory's")
		print("   ConfirmBuy is its only extra and is a dialog: CItemMallConfirmBuy.)")
	var left_out: Array[String] = []
	for n in extras:
		if not (n in best):
			left_out.append(n)
	if not left_out.is_empty():
		print("left out (modes or dialogs over the window): %s" % ", ".join(left_out))
	quit(0)

## Brute-force largest pairwise-compatible set. A layout has at most ten
## sections, so there is nothing to be clever about.
func _largest_clique(pool: Array[String], chosen: Array[String], compatible: Dictionary,
		start: int, best: Array[String]) -> void:
	if chosen.size() > best.size():
		best.assign(chosen)
	for i in range(start, pool.size()):
		var candidate := pool[i]
		var fits := true
		for already in chosen:
			if not compatible.get(candidate + "|" + already, false):
				fits = false
				break
		if not fits:
			continue
		var next: Array[String] = chosen.duplicate()
		next.append(candidate)
		_largest_clique(pool, next, compatible, i + 1, best)

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
