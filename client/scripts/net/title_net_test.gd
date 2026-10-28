extends SceneTree

## Round 838: TitleNet -- retail's 0x30DF, the OURS custom title (0x01A8)
## and the Custom Title Scroll's use bytes the server's titlescroll.go reads
## (its Go tests read the same layouts), and the title's text from a
## synthetic hwanleveldata table.
##   godot4 --headless --path client --script res://scripts/net/title_net_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _hex(s: String) -> PackedByteArray:
	var out := PackedByteArray()
	for t in s.split(" ", false):
		out.append(t.hex_to_int())
	return out

func _initialize() -> void:
	# 0x30DF {uid 7, level 196}.
	var h := TitleNet.decode_hwan_level(_hex("07 00 00 00 c4"))
	_check(int(h["uid"]) == 7 and int(h["level"]) == 196, "0x30DF (got %s)" % str(h))
	_check(TitleNet.decode_hwan_level(_hex("07 00 00 00")).is_empty(), "a short 0x30DF")
	# 0x01A8 {uid 7, str "Sky Walker"}.
	var c := TitleNet.decode_custom_title(_hex("07 00 00 00 0a 00") + "Sky Walker".to_utf8_buffer())
	_check(int(c["uid"]) == 7 and String(c["text"]) == "Sky Walker", "0x01A8 (got %s)" % str(c))
	_check(TitleNet.decode_custom_title(_hex("07 00 00 00 0a 00 41")).is_empty(), "a short 0x01A8")
	# The use: the plain use, 0xC7, u16 length, the text.
	var use := UseItemNet.encode_use_custom_title("Aria", 3, "Sky")
	var plain := UseItemNet.encode_use("Aria", 3)
	_check(use == plain + _hex("c7 03 00") + "Sky".to_utf8_buffer(), "the custom title's use (got %s)" % use.hex_encode())
	# The table: tab columns level, CH key, EU key; a BOM'd or text row skipped.
	var table := TitleNet.parse_levels("﻿0\txxx\txxx\t\r\n1\tK_CH_1\tK_EU_1\t\r\n196\tK_196\tK_196\t\r\nnot\ta\trow\r\n")
	_check(table.size() == 2 and (table[1] as Array) == ["K_CH_1", "K_EU_1"], "the table (got %s)" % str(table))
	var texts := {"K_CH_1": "Ambassador", "K_EU_1": "Envoy", "K_196": "SRO Lover"}
	var lookup := func(key: String) -> String: return String(texts.get(key, ""))
	_check(TitleNet.text_for(1, "", false, table, lookup) == "Ambassador", "level 1, a Chinese body")
	_check(TitleNet.text_for(1, "", true, table, lookup) == "Envoy", "level 1, a European body: Title_EU70")
	_check(TitleNet.text_for(196, "", false, table, lookup) == "SRO Lover", "level 196")
	_check(TitleNet.text_for(0, "", false, table, lookup) == "", "level 0 draws none")
	_check(TitleNet.text_for(77, "", false, table, lookup) == "", "a level without a row draws none")
	_check(TitleNet.text_for(255, "Sky Walker", false, table, lookup) == "Sky Walker", "255: the custom text")
	_check(TitleNet.text_for(255, "", false, table, lookup) == "", "255 before its text came: none")
	# The handlers: a level, the custom text, a level 0 and a body leaving.
	var t := TitleNet.new()
	var seen: Array = []
	t.changed.connect(func(uid: int) -> void: seen.append(uid))
	var handlers := {}
	var host := _Host.new(handlers)
	t.register_with(host)
	(handlers[TitleNet.OP_CUSTOM_TITLE] as Callable).call(_hex("07 00 00 00 0a 00") + "Sky Walker".to_utf8_buffer())
	(handlers[TitleNet.OP_HWAN_LEVEL] as Callable).call(_hex("07 00 00 00 ff"))
	_check(t.level_of(7) == 255 and t.custom_of(7) == "Sky Walker" and seen == [7, 7], "uid 7's custom title (seen %s)" % str(seen))
	_check(t.title_text(7, false, table, lookup) == "Sky Walker", "uid 7's text")
	t.note_level(8, 196, false)
	_check(t.title_text(8, false, table, lookup) == "SRO Lover" and seen.size() == 2, "a spawn's level, no signal")
	(handlers[TitleNet.OP_HWAN_LEVEL] as Callable).call(_hex("08 00 00 00 00"))
	_check(t.level_of(8) == 0 and not t.levels.has(8), "level 0 forgets it")
	t.forget(7)
	_check(t.level_of(7) == 0 and t.custom_of(7) == "", "a body leaving forgets both")
	host.free()
	print("FAILURES: %d" % _failures if _failures > 0 else "ALL PASS")
	quit(1 if _failures > 0 else 0)

## Stands in for NetClient's register_handler.
class _Host:
	extends Node
	var _h: Dictionary
	func _init(h: Dictionary) -> void:
		_h = h
	func register_handler(op: int, f: Callable) -> void:
		_h[op] = f
