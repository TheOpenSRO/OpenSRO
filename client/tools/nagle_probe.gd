extends SceneTree

## Round 786 (MEASURED): what Nagle's algorithm costs this client's requests.
## The client writes every packet as its own put_data (NetClient._send), and a
## request that follows one the server does not answer -- the stop report
## (OpMove with the stop flag, which goes to the watchers, not the mover)
## followed by the attack (World3D._release_pending_attack) -- is held by the
## OS until the first is acknowledged, which a receiver with delayed ACKs
## (Linux 40 ms, macOS 100 ms, Windows 200 ms) sends late.
##
## Against a listener that answers an 'R' frame at once and an 'S' frame never
## (the scratch tool `naglesrv`, round 786 in docs/WORLD_ISSUES.md), each
## iteration writes S then R in one go, as the client does, and times R's
## answer; then waits `--gap` ms. Prints per-mode p50 / p95 / max:
##
##   remote_godot.sh script res://tools/nagle_probe.gd -- --host=H --port=17900 --n=200 --gap=150
##
## Both modes run in one boot: `no_delay=false` (StreamPeerTCP's default, what
## the client had before round 786) and `no_delay=true`.

func _arg(name: String, fallback: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--" + name + "="):
			return a.substr(name.length() + 3)
	return fallback

func _frame(kind: String) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(16)
	b[0] = kind.unicode_at(0)
	return b

func _run(host: String, port: int, no_delay: bool, n: int, gap_ms: int) -> Array:
	var peer := StreamPeerTCP.new()
	if peer.connect_to_host(host, port) != OK:
		push_error("nagle_probe: connect failed")
		return []
	var t0 := Time.get_ticks_msec()
	while peer.get_status() == StreamPeerTCP.STATUS_CONNECTING and Time.get_ticks_msec() - t0 < 5000:
		peer.poll()
		OS.delay_usec(1000)
	if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		push_error("nagle_probe: not connected")
		return []
	if no_delay:
		peer.set_no_delay(true)
	var rtts: Array = []
	for i in n:
		var sent := Time.get_ticks_usec()
		peer.put_data(_frame("S"))
		peer.put_data(_frame("R"))
		while true:
			peer.poll()
			if peer.get_available_bytes() > 0:
				peer.get_data(peer.get_available_bytes())
				break
			if Time.get_ticks_usec() - sent > 3000000:
				break
			OS.delay_usec(200)
		rtts.append((Time.get_ticks_usec() - sent) / 1000.0)
		OS.delay_msec(gap_ms)
	peer.disconnect_from_host()
	return rtts

func _initialize() -> void:
	var host := _arg("host", "127.0.0.1")
	var port := int(_arg("port", "17900"))
	var n := int(_arg("n", "200"))
	var gap := int(_arg("gap", "150"))
	for no_delay in [false, true]:
		var rtts := _run(host, port, no_delay, n, gap)
		if rtts.is_empty():
			continue
		rtts.sort()
		var over := 0
		for r in rtts:
			if float(r) >= 20.0:
				over += 1
		print("NAGLE no_delay=%s n=%d S+R answer p50 %.1f ms p95 %.1f ms max %.1f ms, %d of %d at 20 ms or more" % [
			no_delay, rtts.size(), rtts[rtts.size() / 2], rtts[int(rtts.size() * 0.95)], rtts[rtts.size() - 1], over, rtts.size()])
	quit()
