extends SceneTree

## TeleportNet (scripts/net/teleport.gd, round 576) against hand-built bytes:
## the layout server/internal/session/teleport.go's TeleportResult.Encode
## writes -- TestTeleportWireShapes builds the same success fixture in Go --
## so the decoder is tested against the wire, not against itself. Then the
## receipt line and the refusal line against a SYNTHETIC UI text table (every
## string made up, so a pass proves the text came from the table), and the
## World3D wiring. No line printed on a pass may contain the letters F-A-I-L:
## remote_godot.sh's grep reads them as a failing suite, and the refusal keys
## all contain them.

const UiTextTable = preload("res://scripts/ui/ui_text_table.gd")
const ErrorText = preload("res://scripts/net/error_text.gd")

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _str(s: String) -> PackedByteArray:
	var bytes := s.to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, bytes.size())
	out.append_array(bytes)
	return out

## One TeleportResult payload, byte by byte: u8 ok, u16 code, u8 waiver, u64
## fee, then the destination and the reason as u16-prefixed strings.
func _result_bytes(ok: bool, code: int, waiver: int, fee: int, destination: String, reason: String) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(12)
	out.encode_u8(0, 1 if ok else 0)
	out.encode_u16(1, code)
	out.encode_u8(3, waiver)
	out.encode_u64(4, fee)
	out.append_array(_str(destination))
	out.append_array(_str(reason))
	return out

## One textuisystem-shaped row: token at 1, "0" filler, English at 8.
func _row(token: String, english: String) -> String:
	return "1\t%s\t0\t0\t0\t0\t0\t0\t%s\t0" % [token, english]

func _table(rows: PackedStringArray) -> UiTextTable:
	return UiTextTable.parse(("\n".join(rows)).to_utf16_buffer())

func _init() -> void:
	# The request: two u16 LE teleportdata ids, what DecodeTeleportUseRequest
	# reads (TestTeleportWireShapes decodes these exact four bytes).
	var req := TeleportNet.encode_use(1, 2)
	_check(req == PackedByteArray([1, 0, 2, 0]), "encode_use(1, 2) is 01 00 02 00 (got %s)" % str(req))
	_check(TeleportNet.OP_USE == 0x00F3 and TeleportNet.OP_RESULT == 0x00F4, "the pair is 0x00F3 / 0x00F4, as teleport.go pins it")

	# The success fixture -- the same bytes TestTeleportWireShapes expects
	# from Encode: ok, code 0, waiver 3 (the testing flag), 5000 as a u64,
	# SN_ZONE_22002, an empty reason.
	var full := _result_bytes(true, 0, TeleportNet.WAIVER_FLAG, 5000, "SN_ZONE_22002", "")
	var expected := PackedByteArray([1, 0, 0, 3, 0x88, 0x13, 0, 0, 0, 0, 0, 0, 13, 0])
	expected.append_array("SN_ZONE_22002".to_utf8_buffer())
	expected.append_array(PackedByteArray([0, 0]))
	_check(full == expected, "the hand-built fixture is Go's Encode output byte for byte")
	var r := TeleportNet.decode_result(full)
	_check(r != null, "a whole result decodes")
	if r != null:
		_check(r.ok and r.code == 0, "ok, code 0")
		_check(r.waiver == TeleportNet.WAIVER_FLAG, "waiver 3, the testing flag (got %d)" % r.waiver)
		_check(r.fee == 5000, "fee 5000 (got %d)" % r.fee)
		_check(r.destination == "SN_ZONE_22002", "destination SN_ZONE_22002 (got %s)" % r.destination)
		_check(r.reason == "", "no reason on a success")

	var refused := TeleportNet.decode_result(_result_bytes(false, 0x1c15, 0, 0, "", "level range"))
	_check(refused != null and not refused.ok and refused.code == 0x1c15 and refused.reason == "level range",
		"a refusal decodes to its code and reason")

	# NEGATIVE: a payload cut short at ANY byte is null, never a half-filled
	# result (a decoder that reads the fixed head and stops passes a result
	# with an empty destination for every cut past byte 12).
	var halves := 0
	for n in range(full.size()):
		if TeleportNet.decode_result(full.slice(0, n)) != null:
			halves += 1
	_check(halves == 0, "every truncation of the result decodes to null (%d did not)" % halves)

	# The receipt, in the archive's format: the gold format when gold was
	# charged, the free one when none was (UI_TELEPORT::FUN_006fd3e0's choice).
	var ui := _table(PackedStringArray([
		_row("UIIT_CTL_TELEPORT_RESULT", "Fixture to [%s] for [%d] coins."),
		_row("UIIT_CTL_TELEPORT_FREE_RESULT", "Fixture to [%s] free."),
	]))
	var paid := TeleportNet.receipt_line("Donwhang", 5000, ui)
	_check(paid == "Fixture to [Donwhang] for [5000] coins.", "a charged teleport fills the table's gold format (got %s)" % paid)
	var free_line := TeleportNet.receipt_line("Donwhang", 0, ui)
	_check(free_line == "Fixture to [Donwhang] free.", "a free teleport fills the table's free format (got %s)" % free_line)
	# The retail file's second row shape, "[%s]area. [%d]gold", fills too.
	var second := TeleportNet.receipt_line("Hotan", 5000, _table(PackedStringArray([_row("UIIT_CTL_TELEPORT_RESULT", "Fixture to [%s]area. [%d]coins")])))
	_check(second == "Fixture to [Hotan]area. [5000]coins", "the second row shape fills (got %s)" % second)
	# A template that does not hold exactly its placeholders is not filled.
	var odd := TeleportNet.receipt_line("Donwhang", 5000, _table(PackedStringArray([_row("UIIT_CTL_TELEPORT_RESULT", "Fixture %s %s %d")])))
	_check(odd == "Teleporting to Donwhang for 5000 gold.", "a template with an extra placeholder gives our own wording (got %s)" % odd)
	var bare := TeleportNet.receipt_line("Donwhang", 0, null)
	_check(bare == "Teleporting to Donwhang at no cost.", "no table gives our own wording (got %s)" % bare)
	var nameless := TeleportNet.receipt_line("", 5000, ui)
	_check(nameless == "Teleporting for 5000 gold.", "no place name gives our own wording, never a token (got %s)" % nameless)

	# The refusal line: the archive's own message for the codes category 0xd
	# maps (0x1c10 and 0x1c15 are round 576's rows), our own for 2, and the
	# server's words for its own refusals.
	var errors := _table(PackedStringArray([
		_row("UIIT_MSG_INTERACTION_FAIL_OUT_OF_REQUIRED_LEVEL_FOR_TELEPORT", "Fixture wrong level"),
		_row("UIIT_MSG_INTERACTION_FAIL_CANT_USE_TELEPORT_WITH_TRADECART", "Fixture cart"),
		_row("UIIT_MSG_INTERACTION_FAIL_NOT_ENOUGH_MONEY", "Fixture no gold"),
	]))
	var level_line := ErrorText.teleport_line(0x1c15, errors, "server words")
	_check(level_line == "Fixture wrong level", "0x1c15 shows the table's level text (got %s)" % level_line)
	var cart_line := ErrorText.teleport_line(0x1c10, errors, "server words")
	_check(cart_line == "Fixture cart", "0x1c10 shows the table's cart text (got %s)" % cart_line)
	var gold_line := ErrorText.teleport_line(0x1c07, errors, "server words")
	_check(gold_line == "Fixture no gold", "0x1c07 shows the table's gold text (got %s)" % gold_line)
	var no_link := ErrorText.teleport_line(TeleportNet.ERR_NO_LINK, errors, "no such destination")
	_check(no_link == "No such destination.", "2 keeps our own wording (got %s)" % no_link)
	var dead := ErrorText.teleport_line(0, errors, "you are dead")
	_check(dead == "you are dead", "code 0 shows the server's words (got %s)" % dead)
	# Round 642's review: the interaction range's 4 and 3. Category 0xd shows
	# 4 as UIIT_MSG_INTERACTION_FAIL_TOO_FAR and nothing for 3.
	var far_table := _table(PackedStringArray([_row("UIIT_MSG_INTERACTION_FAIL_TOO_FAR", "Fixture too far")]))
	var far_line := ErrorText.teleport_line(4, far_table, "you are too far away")
	_check(far_line == "Fixture too far", "4 shows the table's too-far text (got %s)" % far_line)
	var far_own := ErrorText.teleport_line(4, errors, "you are too far away")
	_check(far_own == "You are too far away.", "4 without the row gives our own wording (got %s)" % far_own)
	var not_near := ErrorText.teleport_line(3, far_table, "you are not near that gate")
	_check(not_near == "You are not near that gate.", "3 keeps our own wording (got %s)" % not_near)
	var level_fallback := ErrorText.teleport_line(0x1c15, null, "server words")
	_check(level_fallback == "Your level does not allow that destination.", "0x1c15 without a table gives our own wording (got %s)" % level_fallback)

## World3D's wiring, in _initialize: World3D names the NetClient autoload,
## which a --script suite registers only after _init (error_text_test.gd's
## note). Reached through call(), so a World3D without the handler FAILS here
## rather than failing to parse.
func _initialize() -> void:
	var world_script := load("res://scripts/World3D.gd") as GDScript
	var world_ok := world_script != null and world_script.can_instantiate()
	_check(world_ok, "World3D compiles in _initialize")
	if world_ok:
		var world: Node = world_script.new()
		world.set("_ui_text_table", _table(PackedStringArray([
			_row("UIIT_CTL_TELEPORT_RESULT", "Fixture to [%s] for [%d] coins."),
			_row("UIIT_MSG_INTERACTION_FAIL_NOT_ENOUGH_MONEY", "Fixture no gold"),
		])))
		var has_handler := world.has_method("_on_teleport_result")
		_check(has_handler, "World3D has _on_teleport_result")
		if has_handler:
			var short := TeleportNet.decode_result(_result_bytes(false, 0x1c07, 0, 0, "", "not enough gold"))
			world.call("_on_teleport_result", short)
			var said := String(world.call("log_text"))
			_check(said.find("Fixture no gold") >= 0, "a 0x1c07 refusal is a chat line in the table's words (chat: %s)" % said.strip_edges())
			_check(world.get("_teleport_arrival_pending") == false, "a refusal marks no arrival")
			var ok := TeleportNet.decode_result(_result_bytes(true, 0, TeleportNet.WAIVER_NONE, 5000, "SN_ZONE_22002", ""))
			world.call("_on_teleport_result", ok)
			_check(world.get("_teleport_arrival_pending") == true, "an accepted teleport marks the next OpChangeZoneResult as its arrival")
			# No archive here, so no textdata_object: the place has no name and
			# the line is our own wording -- never the SN_ token.
			var text := String(world.call("log_text"))
			_check(text.find("Teleporting for 5000 gold.") >= 0 and text.find("SN_ZONE") < 0,
				"the receipt names the gold and never the token (chat: %s)" % text.strip_edges())
		world.free()

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
