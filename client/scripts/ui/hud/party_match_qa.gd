extends RefCounted
class_name PartyMatchQa

## OPENSRO_QA_PARTY's party-matching steps (round 714, lane C2; QA only).
## World3D's `_qa_party_do` hands any verb it does not know here; every step
## goes through the window's own controls, as a player's click would:
##
##   match                     open the Party Matching window (page 0)
##   page:<n>                  ask for page n (the spin set to n)
##   spin:right|left           a real mouse click on the page spin's arrow
##                             (Input.parse_input_event at its centre), with
##                             the controls under that point (round 752)
##   click:<control>           the same real click on any control of it
##   pagestate                 print the page held and the spin (`QA MATCH PAGE`)
##   form                      press Form party (the dialog stays up)
##   register:<purpose>,<min>,<max>[,<title>]   Form party, fill, OK
##   change:<purpose>,<min>,<max>[,<title>]     Change entry, fill, OK
##   delete                    Delete entry, then Yes
##   select:<leader name>      click that party's row
##   join:<leader name>        select it and press Join party
##   search:<name>|<purpose>|<lo>|<hi>          fill the search row, Search
##   auto:<purpose>,<race>     Auto match with those radios, OK
##   req:confirm|cancel|wait   answer the next leader popup (wait: let its
##                             10 s timer answer)
##
## `QA MATCH` lines report what each step saw.

static var _req_answer := ""

static func do(panels: HudPanels, verb: String, arg: String) -> bool:
	if panels == null:
		return false
	var w := panels._ensure_party_match()
	match verb:
		"match":
			panels.open("partymatch")
		"page":
			# The spin set to n, then its handler (round 752: the label now
			# follows only the spin, as the original's does).
			var page_spin := w.node("GDR_PARTYMATCH_SPIN_PAGE")
			if page_spin != null:
				page_spin.set_meta("value", int(arg))
				UiBuilder._spin_refresh(page_spin)
			w.on_spin(int(arg))
		"form":
			panels.open("partymatch")
			w.press_form()
			print("QA MATCH: form -> dialog %s" % (w.register_box != null and is_instance_valid(w.register_box)))
		"register", "change":
			panels.open("partymatch")
			if verb == "register":
				w.press_form()
			else:
				w.press_change()
			var box := w.register_box
			if box == null or not is_instance_valid(box):
				print("QA MATCH: no register dialog (%s refused)" % verb)
				return true
			var v := arg.split(",")
			if v.size() >= 3:
				box.choose("object", int(v[0]))
				(box.node("GDR_PARTYMATCH_REGISTER_LEVEL_MIN_EDIT") as LineEdit).text = v[1]
				(box.node("GDR_PARTYMATCH_REGISTER_LEVEL_MAX_EDIT") as LineEdit).text = v[2]
				if v.size() >= 4:
					(box.node("GDR_PARTYMATCH_REGISTER_MSG_EDIT") as LineEdit).text = v[3]
			print("QA MATCH: %s purpose %d levels %d..%d title '%s'" % [verb, box.entry().purpose, box.entry().min_level, box.entry().max_level, box.entry().title])
			box.press_ok()
		"delete":
			panels.open("partymatch")
			w.press_delete()
			if w.confirm_box != null and is_instance_valid(w.confirm_box):
				w.confirm_box.confirmed.emit()
				w.confirm_box.close()
		"select", "join":
			panels.open("partymatch")
			var rows := w.shown_rows()
			var found := false
			for i in rows.size():
				if (rows[i] as PartyMatchNet.Row).leader_name == arg:
					w.select_slot(i)
					found = true
			print("QA MATCH: %s %s -> %s (selected %d)" % [verb, arg, "found" if found else "not listed", w.selected_number])
			for i in PartyMatchWindow.ROWS:
				var slot := w.node("GDR_PARTYMATCH_SLOTLIST_SLOT_%02d" % i)
				var bar := slot.get_node_or_null("MatchSlot/SelectBar") as Control if slot != null else null
				if bar != null and bar.visible:
					print("QA MATCH: row %d's select bar at %s size %s, %d piece(s), index %d of %d" % [i, bar.global_position, bar.size,
						bar.get_child_count(), bar.get_index(), slot.get_child_count()])
				elif slot != null and i == 0:
					print("QA MATCH: row 0 has %s select bar; children %s" % ["a hidden" if bar != null else "no", slot.get_node("MatchSlot").get_children().map(func(c: Node) -> String: return c.name)])
			if found and verb == "join":
				print("QA MATCH: Join party enabled %s" % w.enabled(PartyMatchWindow.BTN_JOIN))
				w.press_join()
		"search":
			panels.open("partymatch")
			var f := arg.split("|")
			var names := ["GDR_PARTYMATCH_SEARCH_NAME_EDIT", "", "GDR_PARTYMATCH_SEARCH_MIN_LEVEL_EDIT", "GDR_PARTYMATCH_SEARCH_MAX_LEVEL_EDIT"]
			for i in mini(f.size(), 4):
				if i == 1:
					if w._combo != null:
						w._combo.select(int(f[1]))
						w._update_combo_text()
					continue
				var e := w.node(names[i]) as LineEdit
				if e != null:
					e.text = f[i]
			w.press_search()
			print("QA MATCH: search -> %d record(s)" % w.records().size())
		"auto":
			panels.open("partymatch")
			w.press_auto()
			var box := w.auto_box
			if box == null or not is_instance_valid(box):
				print("QA MATCH: no auto-match dialog")
				return true
			var v := arg.split(",")
			if v.size() >= 2:
				box.choose("object", int(v[0]))
				box.choose("race", int(v[1]))
			box.press_ok()
		"spin":
			# Round 752: a real left click on the page spin's arrow (arg
			# "right" or "left"), pushed through Input at the arrow's centre
			# as a player's mouse would, so whatever covers the arrow takes it.
			panels.open("partymatch")
			var spin := w.node("GDR_PARTYMATCH_SPIN_PAGE")
			var arrow := spin.get_node_or_null("Right" if arg != "left" else "Left") as Control if spin != null else null
			if arrow == null:
				print("QA MATCH: no page spin arrow")
				return true
			var at := arrow.get_global_rect().get_center()
			_report_under(panels.get_tree().root, at)
			if not arrow.has_meta("qa_probe"):
				arrow.set_meta("qa_probe", true)
				(arrow as BaseButton).pressed.connect(func() -> void: print("QA MATCH ARROW PRESSED"))
			_click(at)
			print("QA MATCH: clicked the spin's %s arrow at %s" % [arg, at])
		"click":
			# Round 752's control: the same real click on any control of the
			# window, by name.
			panels.open("partymatch")
			var c := w.node(arg)
			if c == null:
				print("QA MATCH: no control %s" % arg)
				return true
			var p := c.get_global_rect().get_center()
			_click(p)
			print("QA MATCH: clicked %s at %s" % [arg, p])
		"pagestate":
			_page_state(w)
		"req":
			_req_answer = arg
			tick(panels)
		"dump":
			dump(panels)
		_:
			return false
	return true

## Answers a leader popup the run asked for, once one is up.
static func tick(panels: HudPanels) -> void:
	if _req_answer == "" or panels == null or panels.party_match == null:
		return
	var box := panels.party_match.req_join_box
	if box == null or not is_instance_valid(box):
		return
	print("QA MATCH: leader popup for %s (level %s), answering %s" % [box.request.member.member_name if box.request.member != null else "?",
		box.request.member.level if box.request.member != null else "?", _req_answer])
	match _req_answer:
		"confirm":
			box.press_confirm()
		"cancel":
			box.press_cancel()
	_req_answer = ""

## A left press and release at `at`, through Input as a mouse's are.
static func _click(at: Vector2) -> void:
	for down in [true, false]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = down
		ev.position = at
		ev.global_position = at
		Input.parse_input_event(ev)

## Every visible control whose rect holds `at` and that takes the mouse, in
## tree order (`QA MATCH UNDER`), so a click that lands elsewhere names what
## took it.
static func _report_under(n: Node, at: Vector2) -> void:
	if n is CanvasItem and not (n as CanvasItem).is_visible_in_tree():
		return
	if n is Control:
		var c := n as Control
		if c.mouse_filter != Control.MOUSE_FILTER_IGNORE and c.get_global_rect().has_point(at):
			print("QA MATCH UNDER: %s (%s) filter %d rect %s" % [c.get_path(), c.get_class(), c.mouse_filter, c.get_global_rect()])
	for ch in n.get_children():
		_report_under(ch, at)

## The page spin and the page the state holds (`QA MATCH PAGE`, round 752).
static func _page_state(w: PartyMatchWindow) -> void:
	var spin := w.node("GDR_PARTYMATCH_SPIN_PAGE")
	var label := spin.get_node_or_null("Value") as Label if spin != null else null
	var rows := w.shown_rows()
	print("QA MATCH PAGE: refresh lock %d ms" % w.refresh_locked_ms)
	print("QA MATCH PAGE: state %d of %d, %d row(s) (first %s); spin value %s range %s..%s label '%s'" % [
		w.state.page_index, w.state.page_count, w.state.rows.size(),
		str((rows[0] as PartyMatchNet.Row).number) if not rows.is_empty() else "-",
		str(spin.get_meta("value", "?")) if spin != null else "-", str(spin.get_meta("min", "?")) if spin != null else "-",
		str(spin.get_meta("max", "?")) if spin != null else "-", label.text if label != null else "-"])

## Prints the window's rows (`QA MATCH ROW`), for the measurements.
static func dump(panels: HudPanels) -> void:
	if panels == null or panels.party_match == null:
		return
	var w := panels.party_match
	for r in w.shown_rows():
		var row := r as PartyMatchNet.Row
		print("QA MATCH ROW: %d %s race %d %d/%d purpose %d %d~%d '%s'%s" % [row.number, PartyMatchNet.shown_name(row), row.race,
			row.members, row.cap(), row.purpose, row.min_level, row.max_level, row.title, " (own)" if row == w.state.registration else ""])
