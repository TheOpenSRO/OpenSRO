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
## With `SRREVAMP_QA_SERVER` set this runs the same sequence a player's
## client does -- connect, register (or not, if the account exists), log in,
## pick or create a character, enter the world -- and then hands over to
## World3D, which reads `NetClient.last_enter_world_result` exactly as it
## does after a real character select.
##
##   SRREVAMP_QA_SERVER=host[:port]   the server to sign in to
##   SRREVAMP_QA_ACCOUNT=user:pass    defaults to ACCOUNT_DEFAULT
##   SRREVAMP_QA_CHARACTER=name       defaults to CHARACTER_DEFAULT
##
## Every step is bounded by STEP_TIMEOUT, so a server that is down or slow
## costs one timeout rather than a render that never finishes.

const DEFAULT_PORT := 15779
const ACCOUNT_DEFAULT := "qa:qa-password"
const CHARACTER_DEFAULT := "QaTester"
const STEP_TIMEOUT := 10.0

## Runs the sequence if SRREVAMP_QA_SERVER is set. Returns true when the
## character is in the world, false when the hook is unset (the ordinary
## case) or when any step failed -- in which case the caller carries on
## offline, which is what every render did before this existed.
static func run(tree: SceneTree) -> bool:
	var target := OS.get_environment("SRREVAMP_QA_SERVER")
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

	var account := OS.get_environment("SRREVAMP_QA_ACCOUNT")
	if account == "":
		account = ACCOUNT_DEFAULT
	var split := account.find(":")
	var user := account if split < 0 else account.substr(0, split)
	var password := "" if split < 0 else account.substr(split + 1)

	var who := OS.get_environment("SRREVAMP_QA_CHARACTER")
	if who == "":
		who = CHARACTER_DEFAULT

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
	var names: Array = listed[1]
	if not (who in names):
		NetClient.create_character(who)
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
	return true

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
