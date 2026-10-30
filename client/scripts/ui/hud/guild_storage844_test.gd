extends SceneTree

## Round 844 lane H: the guild storage against the real Media.pk2 -- the
## wire (GuildStorageNet), the kept list (GuildStorageState), the talk line
## (item 0x1d, red below guild level 2) and the window (GDR_GUILDSTORAGEROOM
## through GuildStorageController): its open, list, deposit box, moves, gold
## and close.
##   godot4 --headless --path client --script res://scripts/ui/hud/guild_storage844_test.gd

const MEDIA := "/opt/sro-files/client/Media.pk2"
const PANELS_PATH := "res://scripts/ui/hud/hud_panels.gd"

var _failures := 0

class FakeNet extends RefCounted:
	var guild_storage := GuildStorageState.new()
	var sent: Array = []
	var moves: Array = []
	var current_character_name := "Aria"
	var listed := 0
	func guild_storage_move(payload: PackedByteArray) -> void: moves.append(payload)
	func list_inventory(_who: String) -> void: listed += 1
	func character_stats(_who: String) -> void: pass

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	await _run()
	print("FAILURES: %d" % _failures if _failures > 0 else "ALL PASS")
	quit(1 if _failures > 0 else 0)

func _bytes(a: Array) -> PackedByteArray:
	return PackedByteArray(a)

func _wire() -> void:
	_check(GuildStorageNet.encode_npc(0x01020304) == _bytes([4, 3, 2, 1]), "0x7250/1/2 carry the NPC's u32")
	_check(GuildStorageNet.encode_deposit(2, 7, 9) == _bytes([0x1e, 15, 7, 9, 0, 0, 0]), "type 0x1e: bag slot + 13, the storage slot, the NPC")
	_check(GuildStorageNet.encode_withdraw(7, 2, 9) == _bytes([0x1f, 7, 15, 9, 0, 0, 0]), "type 0x1f: the storage slot, bag slot + 13, the NPC")
	_check(GuildStorageNet.encode_inside(1, 4, 20, 9) == _bytes([0x1d, 1, 4, 20, 0, 9, 0, 0, 0]), "type 0x1d: src, dst, u16 count, the NPC")
	_check(GuildStorageNet.encode_gold(true, 500) == _bytes([0x20, 0xf4, 1, 0, 0, 0, 0, 0, 0]) and GuildStorageNet.encode_gold(false, 1)[0] == 0x21,
		"types 0x20 / 0x21: the u64 amount")
	var used := GuildStorageNet.decode_open_result(_bytes([2, 0x48, 0x4c, 4, 0, 65, 114, 105, 97]))
	_check(not bool(used.ok) and int(used.code) == 0x4c48 and String(used.name) == "Aria", "0xB250 0x4c48 carries the holder's name")
	_check(bool(GuildStorageNet.decode_open_result(_bytes([1])).ok), "0xB250 {1}")
	var lim := GuildStorageNet.decode_open_result(_bytes([2, 0x4a, 0x4c]))
	_check(int(lim.code) == 0x4c4a and String(lim.name) == "", "0xB250 0x4c4a, no name")
	var g := GuildStorageNet.decode_move(_bytes([1, 0x21, 200, 0, 0, 0, 0, 0, 0, 0]))
	_check(int(g.type) == 0x21 and int(g.amount) == 200, "0xB034 type 0x21: the amount")
	var m := GuildStorageNet.decode_move(_bytes([1, 0x1d, 4, 9, 20, 0]))
	_check(int(m.src) == 4 and int(m.dst) == 9 and int(m.count) == 20, "0xB034 type 0x1d: src, dst, count")
	_check(not GuildStorageNet.is_move_ack(_bytes([1, 2, 13, 0])), "a warehouse deposit (type 2) is not the guild storage's")
	_check(GuildStorageNet.deposit_fee(8, 20) == 80 and GuildStorageNet.deposit_fee(0, 5) == 1 and GuildStorageNet.deposit_fee(3, 7) == 10,
		"the deposit box's fee: (unit fee x count) / 2, at least 1 (c:0x6b111a)")

func _run() -> void:
	_wire()
	if not FileAccess.file_exists(MEDIA):
		print("SKIP (no %s)" % MEDIA)
		return
	var pk2 := Pk2Reader.open(MEDIA)
	_check(pk2 != null, "Media.pk2 opens")
	if pk2 == null:
		return
	var entry := ObjectLoader.find_file(pk2, "server_dep\\silkroad\\textdata\\textuisystem.txt")
	var table := UiTextTable.parse(pk2.read_file(entry)) if entry != null else null
	root.size = Vector2i(1280, 720)
	await process_frame
	var builder := UiBuilder.new(pk2, table)
	var panels: Control = (load(PANELS_PATH) as GDScript).new(builder)
	root.add_child(panels)
	await process_frame
	panels.call("_load_items")
	var by_code: Dictionary = panels.get("_items_by_code")
	var potion := by_code.get("ITEM_ETC_HP_POTION_01") as ItemTableReader.Item
	var sword := by_code.get("ITEM_CH_SWORD_01_A") as ItemTableReader.Item
	_check(potion != null and sword != null, "the archive's HP potion and sword rows")
	if potion == null or sword == null:
		return
	ItemInstance.types_of = func(ref: int) -> PackedInt32Array: return panels.call("item_types", ref)

	# The talk line: item 0x1d after the member's and the master's own, its
	# text the archive's, red below level 2.
	var member := NpcServiceReader.guild_services(7, false)
	var master := NpcServiceReader.guild_services(7, true)
	_check(member.size() == 2 and (member[1] as NpcServiceReader.Service).key == "guild_storage"
		and (master[1] as NpcServiceReader.Service).key == "guild_storage", "a member and the master both get the guild storage line")
	_check(NpcServiceReader.guild_services(0, false).size() == 1, "no guild: the create line alone")
	var text: String = table.get_text("UIIT_CTL_GUILD_WAREHOUSE") if table != null and table.has_method("get_text") else ""
	if text == "" and table != null:
		text = String(panels.call("_resolve_ui", "UIIT_CTL_GUILD_WAREHOUSE", ""))
	_check(text == "Use guild storage. (level 2 or above)", "the line's text, UIIT_CTL_GUILD_WAREHOUSE (got '%s')" % text)
	NpcTalkView.line_colours["guild_storage"] = NpcTalkView.COLOUR_MENU_LOW_LEVEL
	var red := NpcTalkView.coloured(PackedStringArray(["[url=guild_storage]1. x[/url]", "[url=guild_leave]2. y[/url]"]), "")
	_check(red.contains("[color=#ff4a4a]1. x") and red.contains("[color=#%s]2. y" % NpcTalkView.COLOUR_MENU.to_html(false)),
		"below level 2 the line is 0xffff4a4a, the others beige")
	NpcTalkView.line_colours.erase("guild_storage")

	# The controller over a stand-in network.
	var net := FakeNet.new()
	var sent: Array = []
	net.guild_storage.send = func(op: int, payload: PackedByteArray) -> void: sent.append([op, payload])
	net.guild_storage.npc = 0x55
	# Loaded at run time: the controller names the NetClient autoload, which
	# a --script run registers only once it has started.
	var ctl = (load("res://scripts/ui/hud/guild_storage_controller.gd") as GDScript).new(panels, net)
	panels.set("_guild_storage", ctl)
	var ended := [0]
	ctl.end_talk = func() -> void: ended[0] += 1
	var refusals: Array = []
	panels.guild_storage_refused.connect(func(c: int, n: String) -> void: refusals.append([c, n]))
	# A refusal: no window, the talk ended, the holder's name handed on.
	net.guild_storage.opened.emit({"ok": false, "code": 0x4c48, "name": "Bram"})
	_check(refusals == [[0x4c48, "Bram"]] and ended[0] == 1 and not ctl.is_open(), "0xB250 0x4c48: the refusal worded with Bram, the talk ended")
	# The open: the window, the bag beside it, the list asked.
	net.guild_storage.opened.emit({"ok": true})
	await process_frame
	var w: HudWindow = panels.get("_windows").get("guild_storage")
	_check(w != null and w.visible and ctl.is_open(), "0xB250 {1}: the window is up")
	if w == null:
		return
	_check(w.size == Vector2(254, 317), "GDR_GUILDSTORAGEROOM's 254 x 317 (got %s)" % str(w.size))
	var bar := w.get_node_or_null("TitleBar") as Label
	_check(bar != null and bar.text == "Guild storage", "titled UIIT_STT_GUILD_WAREHOUSE (got '%s')" % (bar.text if bar != null else "<none>"))
	_check(bool(panels.call("is_open", "inventory")), "the inventory opens beside it (0x79af20)")
	_check(sent.size() == 1 and int(sent[0][0]) == GuildStorageNet.OP_LIST and sent[0][1] == _bytes([0x55, 0, 0, 0]), "0x7252 {npc} sent")
	var grid := w.node("GDR_STORAGE_LAT") as Control
	_check(grid != null and grid.get_child_count() == 30, "the 6x5 lattice")

	# The list: 0x3253 {gold}, two 0x3255 pieces, 0x3254.
	var body := PackedByteArray([60, 2])
	body.append(3)
	body.append_array(_record(potion.id, 20))
	body.append(31)
	body.append_array(_record(potion.id, 5))
	net.guild_storage.begin(PackedByteArray([0xe8, 3, 0, 0, 0, 0, 0, 0]))
	net.guild_storage._body.append_array(body.slice(0, 5))
	net.guild_storage._body.append_array(body.slice(5))
	net.guild_storage.end()
	await process_frame
	_check(net.guild_storage.capacity == 60 and net.guild_storage.gold == 1000 and net.guild_storage.slots.size() == 2,
		"the list: 60 slots, 1000 gold, two stacks (%s)" % ctl.describe())
	var icon3 := grid.get_child(3).get_node_or_null("ItemIcon") as TextureRect
	var count3 := grid.get_child(3).get_node_or_null("CountLabel") as Label
	_check(icon3 != null and icon3.texture != null and count3 != null and count3.text == "20", "slot 3's potions drawn with their count")
	_check(grid.get_child(1).get_node("ItemIcon").texture == null, "page 1 shows nothing at slot 31's cell")
	var money := w.node("GDR_STORAGE_STA_MONEY")
	var money_text := ""
	if money != null:
		for c in money.find_children("*", "Label", true, false):
			money_text = (c as Label).text
		if money is Label:
			money_text = (money as Label).text
	_check(money_text == "1,000", "the gold box shows 1,000 (got '%s')" % money_text)
	_check(ctl.page_count() == 2, "60 slots: two pages")
	var c5 := (grid.get_child(5) as Control).get_global_rect().get_center()
	_check(ctl.slot_at(c5) == 5 and ctl.slot_at(Vector2(5000, 5000)) == -1, "a point maps to its cell's slot (cell 5 at %s -> %d)" % [c5, ctl.slot_at(c5)])

	# A deposit: the box (purpose 0x10) at the guild's half fee, then 0x1e.
	ctl.deposit_from_bag(4, potion.id, 10, Vector2(5000, 5000))
	await process_frame
	var box = w.get_node_or_null("DepositConfirm")
	var fee := GuildStorageNet.deposit_fee(potion.keeping_fee, 10)
	_check(box != null and box.price_text() == str(fee), "the deposit box shows the half fee %d (got '%s')" % [fee, box.price_text() if box != null else "<none>"])
	if box != null:
		box.confirmed.emit(10)
	_check(net.moves.size() == 1 and net.moves[0] == GuildStorageNet.encode_deposit(4, 0, 0x55), "OK sends type 0x1e into the first empty slot")
	net.guild_storage.on_move(GuildStorageNet.decode_move(_bytes([1, 0x1e, 17, 0])))
	await process_frame
	_check(net.guild_storage.slots.has(0) and (net.guild_storage.slots[0] as ItemInstance).count == 10, "the deposited stack is kept at slot 0 (%s)" % ctl.describe())
	_check(net.listed >= 1, "the bag is read again")
	# Inside: slot 0 onto slot 3, a merge of the 10.
	ctl.move_inside(0, 3)
	_check(net.moves[1] == GuildStorageNet.encode_inside(0, 3, 10, 0x55), "a move inside sends type 0x1d with the stack")
	net.guild_storage.on_move(GuildStorageNet.decode_move(_bytes([1, 0x1d, 0, 3, 10, 0])))
	_check(not net.guild_storage.slots.has(0) and (net.guild_storage.slots[3] as ItemInstance).count == 30, "merged: 30 at slot 3 (%s)" % ctl.describe())
	# Gold out, gold in.
	net.guild_storage.on_move(GuildStorageNet.decode_move(_bytes([1, 0x21, 200, 0, 0, 0, 0, 0, 0, 0])))
	net.guild_storage.on_move(GuildStorageNet.decode_move(_bytes([1, 0x20, 50, 0, 0, 0, 0, 0, 0, 0])))
	_check(net.guild_storage.gold == 850, "the gold follows 0x21 and 0x20 (got %d)" % net.guild_storage.gold)
	# A withdraw empties its slot.
	net.guild_storage.on_move(GuildStorageNet.decode_move(_bytes([1, 0x1f, 3, 20])))
	_check(not net.guild_storage.slots.has(3), "a withdraw empties slot 3")
	# The X: 0x7251.
	sent.clear()
	w.hide()
	_check(sent.size() == 1 and int(sent[0][0]) == GuildStorageNet.OP_CLOSE and not ctl.is_open(), "the window's close sends 0x7251")
	net.guild_storage.closed.emit({"ok": true})
	_check(ended[0] == 2, "0xB251 {1} ends the talk (0x704B)")
	ItemInstance.types_of = Callable()

## A stackable's record: rent 0, the ref id, the u16 count.
func _record(ref: int, count: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(10)
	out.encode_u32(0, 0)
	out.encode_u32(4, ref)
	out.encode_u16(8, count)
	return out
