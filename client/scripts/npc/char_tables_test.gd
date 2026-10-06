extends SceneTree

## Round 746: characterdata from every part its index names (CharTables), read
## on workers, and the item preload's wait (the review's finding 5).
## Synthetic archives only (never real game data):
##   godot4 --headless --path client --script res://scripts/npc/char_tables_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## One characterdata row: Service 1, id, code, a model, walk/run speeds,
## BCRadius, DecayTime and Country.
func _row(id: int, code: String, model: String, run: int) -> String:
	var cols := PackedStringArray()
	cols.resize(60)
	cols.fill("0")
	cols[0] = "1"
	cols[NpcTableReader.COL_MODEL_ID] = str(id)
	cols[NpcTableReader.COL_CODE_NAME] = code
	cols[5] = "SN_" + code
	cols[NpcTableReader.COL_DECAY_TIME] = "5000"
	cols[NpcTableReader.COL_COUNTRY] = "0"
	cols[NpcTableReader.COL_SPEED_WALK] = "16"
	cols[NpcTableReader.COL_SPEED_RUN] = str(run)
	cols[NpcTableReader.COL_BC_RADIUS] = "6"
	cols[55] = model
	return "\t".join(cols)

func _utf16(text: String) -> PackedByteArray:
	var out := PackedByteArray([0xFF, 0xFE])
	out.append_array(text.to_utf16_buffer())
	return out

func _entry(block: PackedByteArray, i: int, kind: int, name: String, offset: int, size: int) -> void:
	var base := i * Pk2Reader.ENTRY_SIZE
	block[base] = kind
	var nb := name.to_ascii_buffer()
	for j in nb.size():
		block[base + Pk2Reader.ENTRY_OFF_NAME + j] = nb[j]
	block.encode_u32(base + Pk2Reader.ENTRY_OFF_POSITION, offset)
	block.encode_u32(base + Pk2Reader.ENTRY_OFF_SIZE, size)

## An unencrypted archive holding server_dep\silkroad\textdata\<files>.
func _archive(path: String, files: Dictionary) -> void:
	var header := PackedByteArray()
	header.resize(Pk2Reader.HEADER_SIZE)
	var magic := "JoyMax File Manager!".to_ascii_buffer()
	for i in magic.size():
		header[i] = magic[i]
	var b0 := Pk2Reader.HEADER_SIZE
	var b1 := b0 + Pk2Reader.BLOCK_SIZE
	var b2 := b1 + Pk2Reader.BLOCK_SIZE
	var b3 := b2 + Pk2Reader.BLOCK_SIZE
	var data_at := b3 + Pk2Reader.BLOCK_SIZE
	var blocks: Array[PackedByteArray] = []
	for _i in 4:
		var b := PackedByteArray()
		b.resize(Pk2Reader.BLOCK_SIZE)
		blocks.append(b)
	_entry(blocks[0], 0, Pk2Reader.ENTRY_TYPE_FOLDER, ".", b0, 0)
	_entry(blocks[0], 1, Pk2Reader.ENTRY_TYPE_FOLDER, "server_dep", b1, 0)
	_entry(blocks[1], 0, Pk2Reader.ENTRY_TYPE_FOLDER, ".", b1, 0)
	_entry(blocks[1], 1, Pk2Reader.ENTRY_TYPE_FOLDER, "silkroad", b2, 0)
	_entry(blocks[2], 0, Pk2Reader.ENTRY_TYPE_FOLDER, ".", b2, 0)
	_entry(blocks[2], 1, Pk2Reader.ENTRY_TYPE_FOLDER, "textdata", b3, 0)
	_entry(blocks[3], 0, Pk2Reader.ENTRY_TYPE_FOLDER, ".", b3, 0)
	var payload := PackedByteArray()
	var i := 1
	for name in files:
		var bytes: PackedByteArray = files[name]
		_entry(blocks[3], i, Pk2Reader.ENTRY_TYPE_FILE, name, data_at + payload.size(), bytes.size())
		payload.append_array(bytes)
		i += 1
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(header)
	for b in blocks:
		f.store_buffer(b)
	f.store_buffer(payload)
	f.close()


func _init() -> void:
	var path := "user://opensro_char_tables_test.pk2"
	_archive(path, {
		"characterdata.txt": _utf16("CharacterData_1000.txt\r\nCharacterData_45000.txt\r\n"),
		"characterdata_1000.txt": _utf16(_row(1907, "CHAR_CH_MAN_ADVENTURER", "prim\\mtrl\\man.bsr", 50) + "\r\n"),
		"characterdata_45000.txt": _utf16(_row(40001, "MOB_LATE_AREA", "prim\\mtrl\\late.bsr", 30) + "\r\n"),
		"characterdata_5000.txt": _utf16(_row(777, "MOB_LEGACY_ONLY", "prim\\mtrl\\legacy.bsr", 30) + "\r\n"),
	})
	CharTables.clear_shared()
	var media := Pk2Reader.open(path)
	_check(CharTables.table_paths(media) == PackedStringArray(["server_dep\\silkroad\\textdata\\CharacterData_1000.txt",
		"server_dep\\silkroad\\textdata\\CharacterData_45000.txt"]), "table_paths is the index's list, in order")
	CharTables.preload_async(media)
	var b := CharTables.boot(media)
	_check(b.parts == 2 and b.speeds.has("CHAR_CH_MAN_ADVENTURER") and b.decay.has("MOB_LATE_AREA") and b.bc_radius.has("MOB_LATE_AREA"),
		"boot: speeds, DecayTime and BCRadius from both indexed parts (%d parts)" % b.parts)
	_check(not b.decay.has("MOB_LEGACY_ONLY"), "a part the index does not name is not read")
	var e := CharTables.entry(media)
	_check(e.mob_models_by_code.get("MOB_LATE_AREA", "") == "prim\\mtrl\\late.bsr",
		"entry: a monster defined only in characterdata_45000.txt has its model (the 670 MOB_ codes the old list missed)")
	_check(is_same(CharTables.entry(media), e) and is_same(CharTables.boot(media), b), "the tables are shared, read once")
	# A world leaving before it asked (World3D._exit_tree): the tasks are
	# waited for and their tables kept.
	CharTables.clear_shared()
	CharTables.preload_async(media)
	CharTables.wait_pending()
	_check(CharTables._boot != null and CharTables._entry != null, "wait_pending keeps what the tasks read")
	_check(CharTables.boot(media).parts == 2, "and boot() then returns it")
	media.close()
	DirAccess.remove_absolute(path)

	# No index: the legacy list.
	var lpath := "user://opensro_char_tables_legacy_test.pk2"
	_archive(lpath, {"characterdata_5000.txt": _utf16(_row(777, "MOB_LEGACY_ONLY", "prim\\mtrl\\legacy.bsr", 30) + "\r\n")})
	CharTables.clear_shared()
	var lm := Pk2Reader.open(lpath)
	_check(CharTables.table_paths(lm) == PackedStringArray(NpcTableReader.LEGACY_MODEL_TABLE_PATHS), "without an index, the legacy list")
	_check(CharTables.boot(lm).decay.has("MOB_LEGACY_ONLY"), "and its parts are read")
	lm.close()
	DirAccess.remove_absolute(lpath)
	CharTables.clear_shared()

	# The item preload, waited for on a world's early exit (the review's
	# finding 5): wait_pending keeps its rows as the shared ones.
	var ipath := "user://opensro_char_tables_items_test.pk2"
	_archive(ipath, {"itemdata.txt": _utf16("ItemData_1000.txt\r\n"),
		"itemdata_1000.txt": _utf16(_item_row(101, "ITEM_CH_SWORD_01_A") + "\r\n")})
	ItemTableReader.clear_shared()
	var im := Pk2Reader.open(ipath)
	ItemTableReader.preload_async(im)
	ItemTableReader.wait_pending()
	var rows := ItemTableReader.load_all(im)
	_check(rows.has(101) and ItemTableReader.last_source == "shared", "items: wait_pending keeps the preload's rows; load_all then reports them shared (%s)" % ItemTableReader.last_source)
	ItemTableReader.clear_shared()
	ItemTableReader.preload_async(im)
	ItemTableReader.load_all(im)
	_check(ItemTableReader.last_source == "preload", "items: a load_all that waited reports \"preload\"")
	ItemTableReader.clear_shared()
	_check(ItemTableReader.load_all(im).has(101) and ItemTableReader.last_source == "parsed", "items: a load_all with no preload reports \"parsed\"")
	im.close()
	DirAccess.remove_absolute(ipath)
	ItemTableReader.clear_shared()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

func _item_row(id: int, code: String) -> String:
	var cols := PackedStringArray()
	cols.resize(160)
	cols.fill("0")
	cols[0] = "1"
	cols[ItemTableReader.COL_ID] = str(id)
	cols[ItemTableReader.COL_CODE_NAME] = code
	cols[ItemTableReader.COL_NAME] = code.to_lower()
	cols[54] = "item\\x.ddj"
	return "\t".join(cols)
