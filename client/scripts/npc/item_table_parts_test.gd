extends SceneTree

## Round 741: the item table reads every part the archive's own index
## (`textdata\itemdata.txt`) names, in its order, once per archive -- not the
## seven paths it had hard-coded, which left item 62607 (itemdata_45000.txt)
## with no name, icon or model. Synthetic archives only (never real game data):
##   godot4 --headless --path client --script res://scripts/npc/item_table_parts_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## One itemdata row: Service 1, id, code, name, a model and an icon.
func _row(id: int, code: String, model: String) -> String:
	var cols := PackedStringArray()
	cols.resize(160)
	cols.fill("0")
	cols[0] = "1"
	cols[ItemTableReader.COL_ID] = str(id)
	cols[ItemTableReader.COL_CODE_NAME] = code
	cols[ItemTableReader.COL_NAME] = code.to_lower()
	cols[ItemTableReader.COL_NAME_STRID] = "SN_" + code
	cols[ItemTableReader.COL_MODEL] = model
	cols[54] = model.replace(".bsr", ".ddj")
	return "\t".join(cols)

## One text-table row in the retail shape: Service 1, the key, a Korean column,
## five zeros, the English text twice, six zeros.
func _text_row(key: String, english: String) -> String:
	return "\t".join(PackedStringArray(["1", key, "kor", "0", "0", "0", "0", "0", english, english, "0", "0", "0", "0", "0", "0"]))

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
	var path := "user://opensro_item_parts_test.pk2"
	# The index names 1000 then 45000 (as the real one runs 1000..63000); 5000
	# is a part the old list read that this index does not name, 55500 a part
	# the archive holds and no index names (MEASURED shape of the retail one).
	_archive(path, {
		"itemdata.txt": _utf16("ItemData_1000.txt\r\nItemData_45000.txt\r\n"),
		"itemdata_1000.txt": _utf16(_row(101, "ITEM_CH_SWORD_01_A", "item\\china\\weapon\\sword_01.bsr") + "\r\n"
			+ _row(500, "ITEM_DUP_OLD", "item\\old.bsr") + "\r\n"),
		"itemdata_45000.txt": _utf16(_row(62607, "ITEM_CH_SPEAR_11_A_RARE_ACTIVE", "item\\china\\weapon\\spear_11.bsr") + "\r\n"
			+ _row(500, "ITEM_DUP_NEW", "item\\new.bsr") + "\r\n"),
		"itemdata_5000.txt": _utf16(_row(777, "ITEM_ONLY_LEGACY", "item\\legacy.bsr") + "\r\n"),
		"itemdata_55500.txt": _utf16(_row(888, "ITEM_UNINDEXED", "item\\x.bsr") + "\r\n"),
	})
	ItemTableReader.clear_shared()
	var media := Pk2Reader.open(path)
	_check(media != null, "the synthetic archive opens")
	var paths := ItemTableReader.table_paths(media)
	_check(paths == PackedStringArray(["server_dep\\silkroad\\textdata\\ItemData_1000.txt",
		"server_dep\\silkroad\\textdata\\ItemData_45000.txt"]), "table_paths is the index's list, in order (got %s)" % str(paths))
	var rows := ItemTableReader.load_all(media)
	_check(rows.has(62607), "62607, defined only in itemdata_45000.txt, loads")
	var spear: ItemTableReader.Item = rows.get(62607)
	if spear != null:
		_check(spear.code_name == "ITEM_CH_SPEAR_11_A_RARE_ACTIVE" and spear.model_path == "item\\china\\weapon\\spear_11.bsr"
			and spear.icon_path == "icon\\item\\china\\weapon\\spear_11.ddj" and spear.name_strid == "SN_ITEM_CH_SPEAR_11_A_RARE_ACTIVE",
			"62607's code, model, icon and name key resolve (%s, %s, %s)" % [spear.code_name, spear.model_path, spear.icon_path])
	_check(rows.has(101), "the first part's rows load")
	_check(not rows.has(777), "a part the index does not name is not read (the legacy list is only a fallback)")
	_check(not rows.has(888), "itemdata_55500.txt, named by no index line, is not read")
	_check(rows.has(500) and (rows[500] as ItemTableReader.Item).code_name == "ITEM_DUP_NEW",
		"an id defined twice takes the later part's row, in the index's order")
	_check(ItemTableReader.last_load_parts == 2, "two parts read (got %d)" % ItemTableReader.last_load_parts)

	# Shared per archive: a second handle on the same file gets the same rows.
	var again := Pk2Reader.open(path)
	_check(is_same(ItemTableReader.load_all(again), rows), "a second handle on the same archive shares the parsed rows")

	# The worker preload gives the same rows, and load_all waits for it.
	ItemTableReader.clear_shared()
	ItemTableReader.preload_async(media)
	var pre := ItemTableReader.load_all(media)
	_check(pre.size() == rows.size() and pre.has(62607), "preload_async then load_all: the same %d rows (got %d)" % [rows.size(), pre.size()])
	ItemTableReader.preload_async(media)
	_check(is_same(ItemTableReader.load_all(media), pre), "a preload of an archive already shared is a no-op")
	media.close()
	again.close()
	DirAccess.remove_absolute(path)

	# No index file: the legacy list is the fallback.
	var legacy_path := "user://opensro_item_parts_legacy_test.pk2"
	_archive(legacy_path, {
		"itemdata_5000.txt": _utf16(_row(777, "ITEM_ONLY_LEGACY", "item\\legacy.bsr") + "\r\n"),
	})
	ItemTableReader.clear_shared()
	var lm := Pk2Reader.open(legacy_path)
	_check(ItemTableReader.table_paths(lm) == PackedStringArray(ItemTableReader.LEGACY_TABLE_PATHS),
		"without an index, table_paths is the legacy list")
	_check(ItemTableReader.load_all(lm).has(777), "and its parts load")
	lm.close()
	DirAccess.remove_absolute(legacy_path)
	ItemTableReader.clear_shared()

	# Round 789: the name tables are the files textdataname.txt lists, so a
	# pack adds one by listing it (the retail list names two).
	var names_path := "user://opensro_item_names_list_test.pk2"
	_archive(names_path, {
		"textdataname.txt": _utf16("TextData_Equip&Skill.txt\r\nTextData_Object.txt\r\nTextData_Extra.txt\r\n"),
		"textdata_equip&skill.txt": _utf16(_text_row("SN_ITEM_EQUIP", "Equip Name") + "\r\n"),
		"textdata_object.txt": _utf16(_text_row("SN_ITEM_OBJECT", "Object Name") + "\r\n"),
		"textdata_extra.txt": _utf16(_text_row("SN_ITEM_EXTRA", "Extra Name") + "\r\n"),
	})
	var nm := Pk2Reader.open(names_path)
	_check(ItemTableReader.object_name_paths(nm) == PackedStringArray(["server_dep\\silkroad\\textdata\\TextData_Equip&Skill.txt",
		"server_dep\\silkroad\\textdata\\TextData_Object.txt", "server_dep\\silkroad\\textdata\\TextData_Extra.txt"]),
		"object_name_paths is textdataname.txt's list, in order (got %s)" % str(ItemTableReader.object_name_paths(nm)))
	var names := ItemTableReader.load_object_names(nm)
	_check(names != null and names.get_text("SN_ITEM_EQUIP") == "Equip Name" and names.get_text("SN_ITEM_OBJECT") == "Object Name"
		and names.get_text("SN_ITEM_EXTRA") == "Extra Name", "a name from every listed table, the added one too")
	nm.close()
	DirAccess.remove_absolute(names_path)
	# No list file: the two retail tables by name.
	var nolist_path := "user://opensro_item_names_nolist_test.pk2"
	_archive(nolist_path, {
		"textdata_object.txt": _utf16(_text_row("SN_ITEM_OBJECT", "Object Name") + "\r\n"),
		"textdata_extra.txt": _utf16(_text_row("SN_ITEM_EXTRA", "Extra Name") + "\r\n"),
	})
	var nl := Pk2Reader.open(nolist_path)
	var nl_names := ItemTableReader.load_object_names(nl)
	_check(ItemTableReader.object_name_paths(nl) == PackedStringArray(ItemTableReader.OBJECT_NAME_PATHS)
		and nl_names != null and nl_names.get_text("SN_ITEM_OBJECT") == "Object Name" and not nl_names.has("SN_ITEM_EXTRA"),
		"without textdataname.txt the fallback pair is read and nothing else")
	nl.close()
	DirAccess.remove_absolute(nolist_path)

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
