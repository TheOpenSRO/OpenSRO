extends RefCounted
class_name QaSignIn

## Signs a QA run in to a real server before the world builds.
##
## `qa_shot.sh` boots `World3D.tscn` directly, which skips Login and
## CharacterSelect -- so every render so far has been of a client with no
## server behind it. That is fine for looking at terrain and scenery, and
## useless for anything the server owns: the character renders bare because
## no equipment is reported, the HP bar is blank because no vitals arrive,
## the inventory is empty because there is nothing in it, and the monsters
## are whatever the client invented locally.
##
## With `OPENSRO_QA_SERVER` set this runs the same sequence a player's
## client does -- connect, register (or not, if the account exists), log in,
## pick or create a character, enter the world -- and then hands over to
## World3D, which reads `NetClient.last_enter_world_result` exactly as it
## does after a real character select.
##
##   OPENSRO_QA_SERVER=host[:port]   the server to sign in to
##   OPENSRO_QA_ACCOUNT=user:pass    defaults to ACCOUNT_DEFAULT
##   OPENSRO_QA_CHARACTER=name       defaults to CHARACTER_DEFAULT
##   OPENSRO_QA_GENDER=china_woman   the gender a character created by
##                                    this run is given (default: the
##                                    server's own default, a China man)
##   OPENSRO_QA_CREATE=ref:scale:chest:legs:feet:weapon
##                                    create the character with these
##                                    retail create fields instead (round
##                                    689; the scale as decimal or 0x..)
##   OPENSRO_QA_KIT=body,chest,legs,feet,weapon
##                                    creates the character with exactly
##                                    these ids instead (round 691: a Europe
##                                    body, 14875, with a Europe weapon -- the
##                                    gender kit has only China's; the server
##                                    checks them against -chargen-csv)
##
## Every step is bounded by STEP_TIMEOUT, so a server that is down or slow
## costs one timeout rather than a render that never finishes.

const DEFAULT_PORT := 15779
const ACCOUNT_DEFAULT := "qa:qa-password"
const CHARACTER_DEFAULT := "QaTester"
const STEP_TIMEOUT := 10.0

## Runs the sequence if OPENSRO_QA_SERVER is set. Returns true when the
## character is in the world, false when the hook is unset (the ordinary
## case) or when any step failed -- in which case the caller carries on
## offline, which is what every render did before this existed.
static func run(tree: SceneTree) -> bool:
	var target := OS.get_environment("OPENSRO_QA_SERVER")
	if target == "":
		return false

	var host := target
	var port := DEFAULT_PORT
	var colon := target.rfind(":")
	if colon > 0:
		host = target.substr(0, colon)
		var port_text := target.substr(colon + 1)
		if port_text.is_valid_int():
			port = port_text.to_int()

	var credentials := account_credentials()
	var user := credentials[0]
	var password := credentials[1]
	var who := character_name()

	# Round 789 (lane U): the server's packs first, as Login does -- World3D
	# asks for them at the top of its _ready (sync_packs), before it opens an
	# archive; this covers any other caller.
	if not await sync_packs(tree):
		return false

	print("QA sign-in: connecting to %s:%d as %s / %s" % [host, port, user, who])
	NetClient.connect_to_server(host, port)
	var reached: Array = await _first_of(tree, [NetClient.connected, NetClient.connection_failed])
	if reached.is_empty() or reached[0] != 0:
		printerr("QA sign-in: could not reach %s:%d -- rendering offline" % [host, port])
		return false

	# Registering an account that already exists is the expected case on
	# every run after the first, so its failure is not an error here.
	NetClient.register_account(user, password)
	await _first_of(tree, [NetClient.register_result])

	NetClient.login(user, password)
	var logged_in: Array = await _first_of(tree, [NetClient.login_result])
	if logged_in.is_empty() or not logged_in[1]:
		printerr("QA sign-in: login refused (%s) -- rendering offline" % _reason(logged_in, 2))
		return false

	NetClient.list_characters()
	var listed: Array = await _first_of(tree, [NetClient.character_list_result])
	if listed.is_empty():
		printerr("QA sign-in: no answer to the character list -- rendering offline")
		return false
	# The list carries LobbyNet.Character objects (CharacterNet.Summary
	# before round 682), not names: `who in
	# listed[1]` was always false, so every run after a server's first tried
	# to create the character again and stopped at "name already taken" --
	# unseen while each in-memory QA server was fresh, found by round 558's
	# reconnect, whose second sign-in reached the same server.
	var names: Array = []
	for summary in listed[1]:
		names.append(summary.char_name)
	if not (who in names):
		# OPENSRO_QA_CREATE (round 689): the retail create's own fields, so a
		# run can make any Figure -- a Europe body included -- with its scale
		# byte and kit, as the customize screen sends them.
		var full := create_fields(OS.get_environment("OPENSRO_QA_CREATE"))
		var kit := OS.get_environment("OPENSRO_QA_KIT").split(",", false)
		if not full.is_empty():
			NetClient.create_character_full(who, full[0], full[1], full[2], full[3], full[4], full[5])
		elif kit.size() == 5:
			NetClient.create_character_full(who, int(kit[0]), CharacterNet.DEFAULT_SCALE,
				int(kit[1]), int(kit[2]), int(kit[3]), int(kit[4]))
		else:
			NetClient.create_character(who, OS.get_environment("OPENSRO_QA_GENDER"))
		var created: Array = await _first_of(tree, [NetClient.character_create_result])
		if created.is_empty() or not created[1]:
			printerr("QA sign-in: could not create %s (%s) -- rendering offline" % [who, _reason(created, 2)])
			return false

	NetClient.enter_world(who)
	var entered: Array = await _first_of(tree, [NetClient.enter_world_result])
	if entered.is_empty() or entered[1] == null or not entered[1].ok:
		printerr("QA sign-in: entering the world failed -- rendering offline")
		return false

	NetClient.current_character_name = who
	print("QA sign-in: %s is in the world at %s" % [who, entered[1].zone])

	# Says something, so a render can show the chat window carrying a real
	# message that went to the server and came back rather than a line the
	# client wrote to itself.
	var say := OS.get_environment("OPENSRO_QA_SAY")
	if say != "":
		NetClient.say(say)
	return true

## The server's packs (round 789, lane U; PackSync), fetched, verified and
## layered for OPENSRO_QA_SERVER as Login does for a player, once a run.
## World3D calls it first thing in _ready, before it opens any archive, so the
## world reads the server's packs; run() calls it too. False when the server
## named packs this run could not get (the render then goes offline).
static var _packs_done := ""

static func sync_packs(tree: SceneTree) -> bool:
	var target := OS.get_environment("OPENSRO_QA_SERVER")
	if target == "" or _packs_done == target:
		return true
	var host := target
	var port := DEFAULT_PORT
	var colon := target.rfind(":")
	if colon > 0:
		host = target.substr(0, colon)
		if target.substr(colon + 1).is_valid_int():
			port = target.substr(colon + 1).to_int()
	# Deferred: World3D calls this inside its _ready, while the root is still
	# adding its children.
	var sync := PackSync.new()
	sync.name = "QaPackSync"
	tree.root.add_child.call_deferred(sync)
	await sync.ready
	sync.start(host, port)
	if not sync.done:
		await sync.finished
	var ok := sync.ok
	var why := sync.why
	sync.queue_free()
	if not ok:
		printerr("QA sign-in: the server's packs: %s -- rendering offline" % why)
		return false
	_packs_done = target
	return true

## The QA account as [user, password], from OPENSRO_QA_ACCOUNT ("user:pass")
## or ACCOUNT_DEFAULT. Shared with the front-end screens: a reconnect run
## routed through Login (OPENSRO_QA_RECONNECT_VIA_LOGIN, round 558) signs
## back in with the same account this sequence used.
static func account_credentials() -> PackedStringArray:
	var account := OS.get_environment("OPENSRO_QA_ACCOUNT")
	if account == "":
		account = ACCOUNT_DEFAULT
	var split := account.find(":")
	var user := account if split < 0 else account.substr(0, split)
	var password := "" if split < 0 else account.substr(split + 1)
	return PackedStringArray([user, password])

## OPENSRO_QA_CREATE's six fields as ints, [] when unset or malformed.
static func create_fields(spec: String) -> Array:
	if spec == "":
		return []
	var out: Array = []
	for part in spec.split(":"):
		var t := String(part).strip_edges()
		if t.begins_with("0x"):
			out.append(t.substr(2).hex_to_int())
		elif t.is_valid_int():
			out.append(int(t))
		else:
			printerr("QA sign-in: OPENSRO_QA_CREATE field '%s' is not a number -- ignored" % t)
			return []
	if out.size() != 6:
		printerr("QA sign-in: OPENSRO_QA_CREATE wants ref:scale:chest:legs:feet:weapon -- ignored")
		return []
	return out

## The QA character's name, from OPENSRO_QA_CHARACTER or CHARACTER_DEFAULT.
static func character_name() -> String:
	var who := OS.get_environment("OPENSRO_QA_CHARACTER")
	if who == "":
		who = CHARACTER_DEFAULT
	return who

static func _reason(result: Array, index: int) -> String:
	return str(result[index]) if result.size() > index else "no reason given"

## Waits for whichever of `signals` fires first, or STEP_TIMEOUT.
##
## Returns `[index_of_the_signal_that_fired, ...its arguments]`, or an empty
## array on timeout. Godot's `await` takes one signal, and several of these
## steps have a failure signal alongside the success one.
static func _first_of(tree: SceneTree, signals: Array) -> Array:
	var box := {"done": false, "out": []}
	var handlers: Array[Callable] = []
	for i in range(signals.size()):
		var index := i
		var handler := func(a = null, b = null, c = null) -> void:
			if box["done"]:
				return
			box["done"] = true
			var out: Array = [index]
			# Signals here carry 0, 1 or 2 arguments; the unused ones stay
			# null and the caller reads only what it knows is there.
			out.append(a)
			out.append(b)
			out.append(c)
			box["out"] = out
		handlers.append(handler)
		(signals[index] as Signal).connect(handler, Object.CONNECT_ONE_SHOT)

	var waited := 0.0
	while not box["done"] and waited < STEP_TIMEOUT:
		await tree.process_frame
		waited += tree.root.get_process_delta_time()

	for i in range(signals.size()):
		var sig := signals[i] as Signal
		if sig.is_connected(handlers[i]):
			sig.disconnect(handlers[i])
	return box["out"]
