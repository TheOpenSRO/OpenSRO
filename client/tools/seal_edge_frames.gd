extends SceneTree

## Dev tool: the seal star (ItemSealEdge) on a real seal item's icon, drawn by
## the real Control under a real renderer, for a human to compare with the
## original. Writes, under --out (a scratch directory on the box; game art,
## never committed -- docs/LEGAL.md):
##   - cells.png: the slot at each of the 32 counters, 8 to a row, x4;
##   - live_NNN.png: the slot as it runs in real time, one frame per 20 ms
##     for --seconds, x4 (convert to a GIF on the box to watch it);
## and prints each real-time step's interval ("step at N ms"), the timer's
## 40 ms measured in the live loop.
##
##   tools/xwl_run.sh -s 320x320 godot --path client --script res://tools/seal_edge_frames.gd -- \
##     --pk2=/opt/sro-files/client/Media.pk2 --code=ITEM_CH_SWORD_01_A_RARE --out=/var/tmp/sealfx

const SCALE := 4

func _arg(flag: String, fallback: String = "") -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(flag + "="):
			return a.substr(flag.length() + 1)
	return fallback

func _initialize() -> void:
	var out := _arg("--out", "/var/tmp/sealfx")
	DirAccess.make_dir_recursive_absolute(out)
	var archive := Pk2Reader.open(_arg("--pk2"))
	if archive == null:
		printerr("could not open --pk2"); quit(1); return
	var builder := UiBuilder.new(archive)
	var code := _arg("--code", "ITEM_CH_SWORD_01_A_RARE")
	var item: ItemTableReader.Item = null
	for it in ItemTableReader.load_all(archive).values():
		if (it as ItemTableReader.Item).code_name == code:
			item = it
	if item == null:
		printerr("no item ", code); quit(1); return
	print("item %s id %d rarity %d seal %s icon %s" % [code, item.id, item.rarity,
		ItemTooltipLines.is_seal(item), item.icon_path])

	root.size = Vector2i(32 * SCALE, 32 * SCALE)
	var holder := Control.new()
	holder.scale = Vector2(SCALE, SCALE)
	holder.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	root.add_child(holder)
	var icon := TextureRect.new()
	icon.name = "ItemIcon"
	icon.size = Vector2(32, 32)
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.texture = builder.load_texture(item.icon_path)
	holder.add_child(icon)
	ItemSealEdge.show_on(icon, builder, ItemTooltipLines.is_seal(item), item.id)
	var edge := icon.get_node_or_null(ItemSealEdge.NODE_NAME) as ItemSealEdge
	if edge == null:
		printerr("no edge on a seal item"); quit(1); return

	# Every cell, by counter 32 (cell 0) down to 1 (cell 31).
	edge.set_process(false)
	var cell := 32 * SCALE
	var sheet := Image.create(cell * 8, cell * 4, false, Image.FORMAT_RGBA8)
	for i in range(32):
		edge.counter = 32 - i
		edge.queue_redraw()
		await process_frame
		await process_frame
		var shot := root.get_texture().get_image()
		shot.convert(Image.FORMAT_RGBA8)
		sheet.blit_rect(shot, Rect2i(0, 0, cell, cell), Vector2i((i % 8) * cell, (i >> 3) * cell))
	sheet.save_png(out.path_join("cells.png"))
	print("wrote ", out.path_join("cells.png"))

	# Real time: the node's own _process and timer.
	edge.set_process(true)
	var seconds := float(_arg("--seconds", "1.4"))
	var start := Time.get_ticks_msec()
	var last_step := start
	var last_counter := edge.counter
	var n := 0
	var next_shot := start
	while Time.get_ticks_msec() - start < int(seconds * 1000.0):
		await process_frame
		var now := Time.get_ticks_msec()
		if edge.counter != last_counter:
			print("step at %d ms (+%d) counter %d" % [now - start, now - last_step, edge.counter])
			last_step = now
			last_counter = edge.counter
		if now >= next_shot:
			root.get_texture().get_image().save_png(out.path_join("live_%03d.png" % n))
			n += 1
			next_shot += 20
	print("wrote %d live frame(s)" % n)
	quit(0)
