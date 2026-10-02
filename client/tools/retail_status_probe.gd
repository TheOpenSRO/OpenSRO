extends SceneTree

## Round 681: asks one gateway for its status the way the server list does
## for a `type: legacy` entry, with the content id and version read from the
## player's own Media.pk2 (RetailClientInfo), and prints them and the answer.
##
##   client/tools/remote_godot.sh script res://tools/retail_status_probe.gd -- --gateway=127.0.0.1:15779 [--media=/path/Media.pk2] [--repeat=N]
##
## Without --gateway it only prints what Media.pk2 says (the 0x6100 values).
## Point it only at a server you run or may test (the user's rule: no
## third-party servers from the project's machines).

func _initialize() -> void:
	await process_frame
	var gateway := ""
	var repeat := 1
	var path := Pk2Config.media_path()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--gateway="):
			gateway = a.trim_prefix("--gateway=")
		elif a.begins_with("--media="):
			path = a.trim_prefix("--media=")
		elif a.begins_with("--repeat="):
			repeat = clampi(a.trim_prefix("--repeat=").to_int(), 1, 1000)
	var media: Pk2Reader = Pk2Reader.open(path) if path != "" else null
	var info := RetailClientInfo.from_media(media)
	print("RETAIL: Media.pk2 %s -> %s" % [path if path != "" else "(not found)", info])
	if gateway == "" or not info.has("content_id"):
		quit(0 if info.has("content_id") else 1)
		return
	var parts := gateway.rsplit(":", true, 1)
	var entry := ClientConfig.ServerEntry.new()
	entry.name = "probe"
	entry.type = ServerStatus.TYPE_LEGACY
	entry.gateway_host = parts[0]
	entry.gateway_port = int(parts[1]) if parts.size() > 1 else ClientConfig.DEFAULT_PORT
	var answered := 0
	for run in range(repeat):
		var q := ServerStatus.new()
		root.add_child(q)
		var done := {"why": "", "done": false}
		q.finished.connect(func(_s, why: String) -> void:
			done["why"] = why
			done["done"] = true)
		q.start_for(entry, info)
		while not done["done"]:
			await process_frame
		var t := ServerStatus.thresholds(null)
		if q.answered_ok:
			answered += 1
			if run == 0:
				for s in q.shards:
					print("RETAIL: shard %d '%s' %d/%d state %d farm %d -> %s" % [s["id"], s["name"], s["current"], s["capacity"], s["state"], s["farm"],
						ServerStatus.band_text(ServerStatus.shard_band(s, t), null)])
		if run == 0 or not q.answered_ok:
			print("RETAIL: %s after %d attempt(s) -- %s" % ["answered" if q.answered_ok else "Closed", q.attempts, done["why"]])
		q.queue_free()
	print("RETAIL: %d of %d queries answered" % [answered, repeat])
	quit(0 if answered == repeat else 1)
