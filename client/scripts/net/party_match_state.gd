extends RefCounted
class_name PartyMatchState

## The client's party-matching state (round 714, lane C2): what the retail
## client keeps for the matching window -- the list it was last sent, the
## player's own registration (0x97b950), the join request in flight and the
## auto-match queue -- and the replies it applies. It never touches a window,
## so it runs headless in the tests. Everything READ (docs/protocol/
## party_protocol.md "Party matching", party_gui.md §3-§5) unless marked.

## The list or the registration changed: redraw the window.
signal changed
## A new page arrived (before `changed`).
signal paged
## A line for the system message window: the UIIT key, the error code (0
## when none), and the type (4, the PARTY filter, for the client's own
## lines; 0 for a server code, which 0x778190 always shows -- round 711).
signal notice(key: String, code: int, type: int)
## A line for the warning banner (0x77b580, GDR_WARNING_WND).
signal banner(key: String)
## The register / modify dialog should close (0xb069 / 0xb06a OK, 0x73f300).
signal register_done
## The leader's join request to show (S->C 0x706d).
signal join_request(request: PartyMatchNet.JoinRequest)
## The joining progress window should close (end of 0xb06d, c:0x884a0c ->
## 0x7390b0(0), the 0 READ: `push ebx` at 0x884a01, ebx the null the window
## pointer is tested against at 0x8849b8).
signal join_finished
## A record left the list on a 0xb06b for another number: the window's
## displayed (filtered) list drops it too (0x73a700).
signal removed(number: int)
## Party matching's lock on the party window's Set: true on the 0xb069 OK
## (0x884040); false on the 0xb06b of the player's own entry (0x880268, which
## the window qualifies: out of a party, the window closed).
signal settings_lock(on: bool)

## Sends a message: Callable(opcode: int, payload: PackedByteArray). The
## world binds NetClient's sender; the tests capture.
var send: Callable
## The name a page's first row is compared with to find the player's own
## registration: the leader's name in a party, the player's own otherwise
## (c:0x8841f0: 0x987070 in party ? the leader's name 0x9921e0 : the
## character's name +0x110).
var registration_key: Callable
## The echo's registration (0x97c530, READ): race from the player's own
## model (+0x9c), members 1 out of a party else the party's count. Each
## Callable() -> int; unset gives 0 and 1.
var own_race: Callable
var party_size: Callable

## The rows of the last page, the player's own registration taken out.
var rows: Array[PartyMatchNet.Row] = []
var page_count := 0
var page_index := 0
## The player's own registration (row 0 of a page whose name is the key, or
## the 0xb069 / 0xb06a echo), or null.
var registration: PartyMatchNet.Row = null
## The registration's entry as last echoed (number, flags, purpose, levels,
## title), kept for Change entry.
var registration_entry: PartyMatchNet.Entry = null
## A join request is in flight (the progress window's lifetime).
var joining := false
## The auto-match queue (0x110f80c + 0x64c): entry numbers still to try, and
## whether a run is going.
var auto_queue: Array[int] = []
var auto_running := false
## The deleted entry was the player's own because the party filled
## (DAT_00eeb8c8): the delete line is DELETE_COMPLETE2.
var deleted_for_full := false

func _send(opcode: int, payload: PackedByteArray) -> void:
	if send.is_valid():
		send.call(opcode, payload)

## Wires this state to NetClient's dispatcher (round 711's hook).
func register_with(net: Node) -> void:
	for op in PartyMatchNet.SERVER_OPCODES:
		net.register_handler(op, handle.bind(op))

# --- Requests ----------------------------------------------------------------

func request_page(page: int) -> void:
	_send(PartyMatchNet.OP_PAGE, PartyMatchNet.encode_page(page))

func register(e: PartyMatchNet.Entry) -> void:
	_send(PartyMatchNet.OP_REGISTER, PartyMatchNet.encode_entry(e))

func modify(e: PartyMatchNet.Entry) -> void:
	_send(PartyMatchNet.OP_MODIFY, PartyMatchNet.encode_entry(e))

func delete_entry(number: int, for_full: bool = false) -> void:
	deleted_for_full = for_full
	_send(PartyMatchNet.OP_DELETE, PartyMatchNet.encode_delete(number))

## Join party (0x739500): the request; the progress window opens beside it.
func join(number: int) -> void:
	joining = true
	_send(PartyMatchNet.OP_JOIN, PartyMatchNet.encode_join(number))

## The leader's answer (0x81d210): Confirm 1, Cancel 0, the popup's 10 s
## timer 2.
func answer(q: PartyMatchNet.JoinRequest, answer_code: int) -> void:
	_send(PartyMatchNet.OP_JOIN_ANSWER, PartyMatchNet.encode_answer(q.job_id, q.requester_jid, answer_code))

## Auto match (0x73ebc0 -> 0x786e70): queue up to 10 candidates and send the
## first. False when there is none.
const AUTO_MAX := 10

func start_auto(candidates: Array[int]) -> bool:
	auto_queue = candidates.slice(0, AUTO_MAX)
	auto_running = not auto_queue.is_empty()
	if auto_running:
		_auto_next()
	return auto_running

## 0x786e70: the next queued entry, or the end of the run.
func _auto_next() -> bool:
	if not auto_running or auto_queue.is_empty():
		auto_running = false
		auto_queue.clear()
		return false
	join(auto_queue.pop_front())
	return true

func stop_auto() -> void:
	auto_running = false
	auto_queue.clear()

# --- Replies -----------------------------------------------------------------

func handle(data: PackedByteArray, opcode: int) -> void:
	match opcode:
		PartyMatchNet.OP_PAGE_ACK:
			var p := PartyMatchNet.decode_page(data)
			if p != null:
				apply_page(p)
		PartyMatchNet.OP_REGISTER_ACK, PartyMatchNet.OP_MODIFY_ACK:
			var res := PartyMatchNet.decode_entry_result(data)
			if res != null:
				_on_entry_result(res, opcode == PartyMatchNet.OP_REGISTER_ACK)
		PartyMatchNet.OP_DELETE_ACK:
			var res := PartyMatchNet.decode_delete_result(data)
			if res != null:
				_on_delete_result(res)
		PartyMatchNet.OP_JOIN:
			var q := PartyMatchNet.decode_join_request(data)
			if q != null:
				join_request.emit(q)
		PartyMatchNet.OP_JOIN_ACK:
			var res := PartyMatchNet.decode_join_result(data)
			if res != null:
				_on_join_result(res)

## 0xb06c (c:0x8841f0): row 0 whose name is the key is the player's own
## registration; later rows with that name are skipped (the server sends the
## entry again in its numbered place, round 713). Every other row is listed.
func apply_page(p: PartyMatchNet.Page) -> void:
	if not p.ok:
		notice.emit(PartyNet.ERROR_KEYS.get(p.code, ""), p.code, 0)
		return
	page_count = p.page_count
	page_index = p.page_index
	rows.clear()
	# A page with no rows clears the registration: 0x8841f0 builds no page
	# object for n == 0, and 0x97ddf0's tail then zeroes it (0x97de79 ->
	# 0x97c3b0). A page whose row 0 is someone else's leaves it.
	if p.rows.is_empty():
		registration = null
		registration_entry = null
	paged.emit()
	var key: String = registration_key.call() if registration_key.is_valid() else ""
	var own_found := false
	for i in p.rows.size():
		var row := p.rows[i]
		if i == 0 and key != "" and row.leader_name == key:
			registration = row
			own_found = true
			continue
		if own_found and row.leader_name == key:
			continue
		rows.append(row)
	changed.emit()

func _on_entry_result(res: PartyMatchNet.Result, is_register: bool) -> void:
	if not res.ok:
		notice.emit(PartyNet.ERROR_KEYS.get(res.code, ""), res.code, 0)
		return
	registration_entry = res.entry
	# 0x97c530 rewrites every field from the echo and the player (READ): time
	# 0, race the player's model's, members 1 or the party's count, the name
	# the player object's.
	var row := registration if registration != null else PartyMatchNet.Row.new()
	row.number = res.entry.number
	row.time = 0
	row.race = int(own_race.call()) if own_race.is_valid() else 0
	row.members = int(party_size.call()) if party_size.is_valid() else 1
	row.flags = res.entry.flags
	row.purpose = res.entry.purpose
	row.min_level = res.entry.min_level
	row.max_level = res.entry.max_level
	row.title = res.entry.title
	row.leader_name = registration_key.call() if registration_key.is_valid() else ""
	registration = row
	register_done.emit()
	settings_lock.emit(true)
	banner.emit("UIIT_MSG_PARTYMATCH_RECORD_COMPLETE" if is_register else "UIIT_MSG_PARTYMATCH_MODIFY_COMPLETE")
	changed.emit()

## 0xb06b (c:0x8801e0): the player's own number clears the registration;
## another number leaves the list (and the window asks for the page again
## when it is gone). The line is DELETE_COMPLETE, or DELETE_COMPLETE2 when
## the client deleted it because the party filled.
func _on_delete_result(res: PartyMatchNet.Result) -> void:
	if not res.ok:
		notice.emit(PartyNet.ERROR_KEYS.get(res.code, ""), res.code, 0)
		return
	if registration != null and registration.number == res.number:
		registration = null
		registration_entry = null
		settings_lock.emit(false)
	else:
		for i in rows.size():
			if rows[i].number == res.number:
				rows.remove_at(i)
				break
		removed.emit(res.number)
	banner.emit("UIIT_MSG_PARTYMATCH_DELETE_COMPLETE2" if deleted_for_full else "UIIT_MSG_PARTYMATCH_DELETE_COMPLETE")
	deleted_for_full = false
	changed.emit()

## The party events that move the registration (round 718), as
## UI_PARTY::FUN_00886b10 (the 0x3864 handler) applies them. Every clear is
## 0x97c960(0) -> 0x97c3b0, the 0 READ (`xor ebp,ebp` at 0x886b64; ebp is
## pushed unchanged at 0x886ea4 and 0x88719f, 0 pushed at 0x886f6f):
## - kind 1, dissolved: the registration is cleared (0x8871a7); a cleared
##   number leaves the window's list and the window redraws (0x73a700,
##   0x73a770);
## - kind 3, the player left: cleared (0x886eaa);
## - kind 3, someone else left: with a registration, the player out of a party
##   clears it and drops it from the list (0x886f76, 0x73a700, 0x73a770);
##   still in one, the registration's member count becomes the party's
##   (`+9` <- 0x986f50()+0x10, the source 0x97c530 fills the count from) and
##   its row redraws (0x73a980);
## - kind 2, someone joined: the same count update (0x886cf0..).
## Those list steps run when the window exists (0x799680 = child 0x82); the
## original builds it with the interface, so they always run there, and here
## this state exists only once the window has been built. Party matching's
## Set lock (0x6d5ab0) is not touched on any of these paths (no call to it
## from 0x886b10), so it stays as it was.
func on_party_event(kind: int, self_left: bool, in_party: bool, party_count: int) -> void:
	match kind:
		PartyNet.EVENT_DISSOLVED:
			_clear_registration()
		PartyNet.EVENT_LEFT:
			if self_left:
				_clear_registration()
			elif registration != null:
				if not in_party:
					_clear_registration()
				else:
					registration.members = party_count
					changed.emit()
		PartyNet.EVENT_JOINED:
			if registration != null and in_party:
				registration.members = party_count
				changed.emit()

func _clear_registration() -> void:
	if registration == null and registration_entry == null:
		return
	var number := registration.number if registration != null else 0
	registration = null
	registration_entry = null
	if number != 0:
		removed.emit(number)
	changed.emit()

## 0xb06d (c:0x8847d0): joined -> the banner and the auto run ends; refused
## or no reply -> a type-4 line and the next auto candidate; an error code
## -> its line and the next auto candidate. A run that runs out says
## AUTO_FAILURE, one that goes on AUTO_PROGRESS. Then the progress window
## closes (c:0x884a0c).
func _on_join_result(res: PartyMatchNet.Result) -> void:
	joining = false
	var try_next := false
	if res.ok:
		match res.outcome:
			PartyMatchNet.OUTCOME_JOINED:
				banner.emit("UIIT_MSG_PARTYMATCH_JOIN_COMPLETE_MASTER")
				stop_auto()
			PartyMatchNet.OUTCOME_REFUSED:
				notice.emit("UIIT_MSG_PARTYERR_CREATE_PARTY_REFUSED", 0, 4)
				try_next = true
			PartyMatchNet.OUTCOME_NOREPLY:
				notice.emit("UIIT_MSG_PARTYMATCH_JOIN_NOREPLY", 0, 4)
				try_next = true
	else:
		notice.emit(PartyNet.ERROR_KEYS.get(res.code, ""), res.code, 0)
		try_next = true
	if try_next and auto_running:
		if _auto_next():
			notice.emit("UIIT_MSG_PARTYMATCH_AUTO_PROGRESS", 0, 4)
		else:
			notice.emit("UIIT_MSG_PARTYMATCH_AUTO_FAILURE", 0, 4)
	join_finished.emit()
