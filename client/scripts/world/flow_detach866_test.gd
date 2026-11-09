extends SceneTree

## Round 866 (lane AX, the guardian's crash): a world-owned flow lets go of
## NetClient when its world leaves the tree. Before the fix AcademyFlow,
## UnionWorld and SpecialtyFlow connected to NetClient's stores with lambdas
## that use `self`; such a lambda holds a strong reference to its RefCounted,
## so the flow outlived its world, stayed connected and, after a re-entry,
## called the freed HUD -- in the release build a crash with no error
## (MEASURED: the guardian's 0x747E question after one re-entry). Checks:
## each flow's connections are counted on the store's signals, detach()
## takes every one back, and the flow is then freed (a weakref to it
## clears); World3D's _exit_tree detaches all three; SignalLinks cuts what it
## linked and skips a signal whose object is gone; and no RefCounted script
## connects a NetClient or `state` signal through a lambda outside
## SignalLinks (a line may say why it is safe: `# links: <reason>`).
## NEGATIVE: with AcademyFlow's `_links.link(state.window_wanted, ...)` put
## back to `state.window_wanted.connect(...)`, the academy checks fail (the
## flow is still alive after detach, one connection left).
##   godot4 --headless --path client --script res://scripts/world/flow_detach866_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## What UnionWorld and SpecialtyFlow read off their world.
class FakeWorld extends Node:
	var _hud_panels = null
	var _hud_chat = null
	func _resolve_any_text(_key: String, fallback: String) -> String:
		return fallback
	func _log_system(_text: String, _type: int = 0) -> void:
		pass
	func _on_guild_ops_notice(_key: String, _args: Array, _code: int) -> void:
		pass

static func connections(signals: Array) -> int:
	var n := 0
	for s in signals:
		n += (s as Signal).get_connections().size()
	return n

static func store_signals(store: Object) -> Array:
	var out: Array = []
	for sig in store.get_signal_list():
		out.append(Signal(store, sig["name"]))
	return out

## Builds a flow with `make`, checks it connected to `signals` and that
## detach takes every connection back; returns a weakref to it (the HUD's own
## signals still hold its lambdas until the HUD is freed, as in a world).
func _flow_case(label: String, make: Callable, signals: Array) -> WeakRef:
	var before := connections(signals)
	var flow: RefCounted = make.call()
	var during := connections(signals)
	_check(during > before, "%s: connected to the store (%d -> %d)" % [label, before, during])
	var wr: WeakRef = weakref(flow)
	flow.call("detach")
	flow = null
	_check(connections(signals) == before, "%s: detach takes every connection back (%d left of %d)" % [
		label, connections(signals) - before, during - before])
	return wr

func _initialize() -> void:
	var net := root.get_node_or_null("NetClient")
	_check(net != null, "the NetClient autoload is there")
	if net == null:
		_finish()
		return
	# Scripts naming the autoload are loaded at run time (a --script run
	# compiles its own dependencies before the autoloads exist).
	var flow_script: GDScript = load("res://scripts/world/academy_flow.gd")
	var union_script: GDScript = load("res://scripts/world/union_world.gd")
	var specialty_script: GDScript = load("res://scripts/world/specialty_flow.gd")
	var panels_script: GDScript = load("res://scripts/ui/hud/hud_panels.gd")
	var world := FakeWorld.new()
	var hud: Control = panels_script.new(null)
	world._hud_panels = hud
	var academy: Object = net.get("academy")
	var refs := {}
	refs["AcademyFlow"] = _flow_case("AcademyFlow", func() -> RefCounted: return flow_script.new(world, hud), store_signals(academy))
	var union_signals: Array = store_signals(net.get("union_ops"))
	union_signals.append_array(store_signals((net.get("guild_data") as Object).get("union")))
	refs["UnionWorld"] = _flow_case("UnionWorld", func() -> RefCounted: return union_script.new(world), union_signals)
	refs["SpecialtyFlow"] = _flow_case("SpecialtyFlow", func() -> RefCounted: return specialty_script.new(world, hud, null), store_signals(net))
	# The world goes: with its HUD freed, nothing holds a detached flow.
	hud.free()
	world.free()
	for label in refs:
		_check((refs[label] as WeakRef).get_ref() == null, "%s: freed with its world once detached" % label)
	# World3D detaches all three as it leaves the tree.
	var w3d := FileAccess.get_file_as_string("res://scripts/World3D.gd")
	var exit_at := w3d.find("func _exit_tree() -> void:")
	var exit_body := w3d.substr(exit_at, 1200) if exit_at >= 0 else ""
	_check(exit_body.contains("for flow in [_academy_flow, _union_world, _specialty_flow]:") and exit_body.contains("flow.detach()"),
		"World3D._exit_tree detaches the academy, union and specialty flows")
	_links_case()
	_lint_case()
	_finish()

func _links_case() -> void:
	var a := Node.new()
	a.add_user_signal("ping")
	var links := SignalLinks.new()
	var hits: Array = [0]
	links.link(Signal(a, "ping"), func() -> void: hits[0] += 1)
	a.emit_signal("ping")
	_check(hits[0] == 1 and links.count() == 1, "SignalLinks.link connects")
	links.cut()
	a.emit_signal("ping")
	_check(hits[0] == 1 and links.count() == 0 and Signal(a, "ping").get_connections().is_empty(), "cut disconnects")
	var b := Node.new()
	b.add_user_signal("ping")
	links.link(Signal(b, "ping"), func() -> void: pass)
	b.free()
	links.cut()
	_check(links.count() == 0, "cut skips a signal whose object is freed")
	a.free()

## A RefCounted's lambda on a NetClient or store signal, outside SignalLinks.
static func lambda_links(src: String) -> PackedInt32Array:
	var out := PackedInt32Array()
	if not src.begins_with("extends RefCounted"):
		return out
	var re := RegEx.create_from_string("(NetClient\\.[A-Za-z_.]+|\\bstate\\.[a-z_]+)\\.connect\\(func")
	var lines := src.split("\n")
	for i in range(lines.size()):
		var line: String = lines[i]
		var h := line.find("#")
		var code := line if h < 0 else line.substr(0, h)
		if re.search(code) != null and (h < 0 or line.substr(h).find("links:") < 0):
			out.append(i + 1)
	return out

func _scripts(dir: String, out: Array) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	for sub in d.get_directories():
		_scripts(dir.path_join(sub), out)
	for f in d.get_files():
		if f.ends_with(".gd") and not f.ends_with("_test.gd"):
			out.append(dir.path_join(f))

func _lint_case() -> void:
	_check(lambda_links("extends RefCounted\n\tNetClient.trade_prices.connect(func(_p) -> void: _refresh())").size() == 1,
		"lint flags a RefCounted's NetClient lambda")
	_check(lambda_links("extends RefCounted\n\tstate.banner.connect(func(k) -> void: banner.emit(k))").size() == 1,
		"lint flags a RefCounted's store lambda")
	_check(lambda_links("extends RefCounted\n\t_links.link(state.banner, func(k) -> void: x(k))").is_empty(), "lint allows SignalLinks")
	_check(lambda_links("extends Node\n\tNetClient.trade_prices.connect(func(_p) -> void: _refresh())").is_empty(),
		"lint allows a Node (its connections go with it)")
	_check(lambda_links("extends RefCounted\n\tstate.banner.connect(func(k) -> void: banner.emit(k))  # links: dispose cuts it").is_empty(),
		"lint allows a line that says why")
	var files: Array = []
	_scripts("res://scripts", files)
	var bad := 0
	for path in files:
		for ln in lambda_links(FileAccess.get_file_as_string(path)):
			print("  a RefCounted's lambda on a long-lived signal: %s:%d" % [path, ln])
			bad += 1
	_check(files.size() > 300, "scanned %d scripts" % files.size())
	_check(bad == 0, "no RefCounted lambda on NetClient's or a store's signal outside SignalLinks (%d found)" % bad)

func _finish() -> void:
	print("FAILURES: %d" % _failures if _failures > 0 else "ALL PASS")
	quit(1 if _failures > 0 else 0)
