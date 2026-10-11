extends RefCounted
class_name QaAlchemy

## OPENSRO_QA_ALCHEMY="<target id>:<stuff id>[:<powder id>][:<attempts>]"
## (round 768): an end-to-end run of the alchemy window against a real
## server. QA only, never real play. The QA account must be a GM (the server's
## -gm-accounts / OPENSRO_GM_ACCOUNTS), because the items come from /give:
## one target, twenty of the stuff, twenty powders. Then the window opens, the
## items go in the way Alt+click puts them in (HudPanels._alchemy_offer), the
## action is pressed, and each reply is logged as
##   QA ALCHEMY: attempt N -> ok .. success .. destroyed .. code 0x.. plus P durability D variance V options [...]
## until the attempts run out, the target is destroyed, or a reply refuses.

static func parse(spec: String) -> Dictionary:
	var parts := spec.split(":")
	if parts.size() < 2 or not parts[0].is_valid_int() or not parts[1].is_valid_int():
		return {}
	var out := {"target": int(parts[0]), "stuff": int(parts[1]), "powder": -1, "attempts": 3}
	if parts.size() >= 3 and parts[2].is_valid_int():
		out["powder"] = int(parts[2])
	if parts.size() >= 4 and parts[3].is_valid_int():
		out["attempts"] = maxi(1, int(parts[3]))
	return out

static func _slot_of(panels: HudPanels, item_id: int) -> int:
	for entry in panels.get("_bag_slots"):
		var id = panels.call("_first_field", entry, ["item_id", "id"])
		if id != null and int(id) == item_id:
			var at = panels.call("_first_field", entry, ["slot", "slot_index", "index"])
			return int(at) if at != null else -1
	return -1

static func _list(tree: SceneTree, who: String) -> void:
	NetClient.list_inventory(who)
	await NetClient.inventory_list_result
	await tree.process_frame

static func run(tree: SceneTree, panels: HudPanels, spec: String) -> void:
	var p := parse(spec)
	if p.is_empty():
		printerr("QA ALCHEMY: OPENSRO_QA_ALCHEMY '%s' is not <target>:<stuff>[:<powder>][:<attempts>]" % spec)
		return
	var who := NetClient.current_character_name
	var gives: Array = ["give %d 1" % p["target"], "give %d 20" % p["stuff"]]
	if int(p["powder"]) > 0:
		gives.append("give %d 20" % p["powder"])
	# World3D asks the GM console for its help at entry; let that reply pass
	# so each /give's own reply is the one awaited below.
	await tree.create_timer(1.0).timeout
	for line in gives:
		NetClient.gm_command(who, line, 0)
		var res: GmNet.Result = await NetClient.gm_command_result
		print("QA ALCHEMY: /%s -> %s" % [line, res.text if res != null else "?"])
	await _list(tree, who)
	var w := panels.open_alchemy()
	if w == null:
		printerr("QA ALCHEMY: the window did not open")
		return
	for attempt in int(p["attempts"]):
		var target_slot := _slot_of(panels, int(p["target"]))
		if target_slot < 0:
			print("QA ALCHEMY: no target left in the bag -- done")
			break
		for id in [p["target"], p["stuff"], p["powder"]]:
			if int(id) > 0:
				var s := _slot_of(panels, int(id))
				if s >= 0:
					panels.call("_alchemy_offer", s)
		print("QA ALCHEMY: loaded %s %s %s, action %s" % [w.loaded(0) != null, w.loaded(1) != null, w.loaded(2) != null,
			"on" if AlchemyReinforce.action_enabled([w.loaded(0), w.loaded(1), w.loaded(2)]) else "off"])
		w.press_action()
		var r: AlchemyNet.Result = await NetClient.alchemy_result
		var opts: Array = []
		if r.record != null:
			for i in r.record.option_count():
				opts.append("%d=%d" % [r.record.option_id(i), r.record.option_value(i)])
		print("QA ALCHEMY: attempt %d -> ok %s success %s destroyed %s code 0x%x plus %s durability %s variance %s options %s" % [
			attempt + 1, r.ok, r.success, r.destroyed, r.code,
			str(r.record.opt_level) if r.record != null else "-", str(r.record.durability) if r.record != null else "-",
			("%x" % r.record.variance) if r.record != null else "-", opts])
		# The outcome plays out (800 ms of effect) before the next.
		await tree.create_timer(1.0).timeout
		await _list(tree, who)
		if (not r.ok and r.code != AlchemyNet.CODE_ENCHANT_FAILED) or r.destroyed:
			break
	print("QA ALCHEMY: done")
