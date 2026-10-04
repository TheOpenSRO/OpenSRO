extends RefCounted
class_name PartyState

## The client's party manager (round 711, lane C1): what the retail client
## keeps in the object at 0xeeebd8 and hands to the party window, the quick
## party board and the invite path. READ from party_gui.md §1 ("The party
## manager's state") unless marked:
##
##   +0x00 exp mode, +0x04 item mode, +0x08 anyone may invite  -> exp_share,
##        item_share, anyone_invite (the "Set" dialog edits them out of a
##        party; the 0x3065 flags overwrite them in one, 0x986f60)
##   +0x0c job-mode party (names drawn *%s, guilds hidden)      -> job_party
##   +0x0d the player leads                                     -> is_leader()
##   +0x0e in a party                                           -> in_party
##   +0x10 member count, +0x14 leader id, +0x18 own id          -> members,
##        leader_jid, own_jid
##
## It applies the decoded server messages (PartyNet) and tells the HUD what
## changed. It never touches a window itself, so it runs headless in tests.

## The party, its members or the settings changed: redraw.
signal changed
## One member's record changed in place (0x3864 kind 6: HP/MP, level,
## position, guild, masteries, name/model) and nothing else did: the views
## redraw that member only (round 715's review -- the server samples every
## member once a second, so a full rebuild per update was the costly path).
signal member_updated(jid: int)
## A 0x3864 event has been applied (kind 1 dissolved, 2 joined, 3 left, 9 new
## leader; `jid` the member it names, 0 for kind 1). Party matching keeps its
## registration in step with these (UI_PARTY::FUN_00886b10, round 718).
signal party_event(kind: int, jid: int)
## A line for the system message window, type 4 (the PARTY filter): the
## UIIT key, the "%s" argument (or ""), and the error code it came from (0
## when none). party_gui.md §6.
signal notice(key: String, arg: String, code: int)
## A party invitation to show (party_gui.md §1b): the inviter's world id,
## name, the request kind (2 form / 3 join) and the flags byte.
signal invitation(inviter_id: int, inviter_name: String, kind: int, flags: int)
## The invitation box closes without an answer from the player (the server
## timed it out: 0xb067 [2][0x2c10], c:0x880120).
signal invitation_closed
## 0x3068 (round 716): an Item Auto Share item, or gold, went to a member.
## `recipient_name` is that member's name in this party ("" when unknown).
signal item_notice(recipient_jid: int, recipient_name: String, item_id: int, amount: int, is_gold: bool)
## An answer to send: 0x3080 with this payload (the auto-decline path).
signal send_answer(payload: PackedByteArray)

# --- The settings block (+0x00..+0x08) --------------------------------------
## Exp Auto Share (1) or Free-For-All (0). Out of a party these are the
## player's own preferences; the next 0x7060 sends them (c:0x81c7f0).
## Their starting values are READ (round 711's review): the static
## initializer c:0xd75d80 constructs the manager (0x99c1c0), which calls
## c:0x99ba00 on the block (0x99c1fe, ecx = 0xeeebd8 + 0x20): exp 1, item 0,
## anyone 1. The party clear (0x998be0) never rewrites them, so they last
## the process's life. Screenshots 01 and 05 show the same three.
var exp_share := 1
var item_share := 0
var anyone_invite := 1

# --- The party ---------------------------------------------------------------
var in_party := false
var party_id := 0
var leader_jid := 0
## The player's own JID, from the 0xb060 / 0xb067 OK (`[1][own JID]`). The
## id decision (round 710) may also set it at entry; 0 until known.
var own_jid := 0
var flags := 0
## +0x0c: set from the player's own job state by 0x986f60 (`job != 4`,
## c:0x986f96) -- a job-mode party shows `*name` and no guilds.
var job_party := false
## The members in the server's order, leader first (the order 0x3065 sends
## and 0x3864 kind 2 appends; party_rules / S1 keep the leader at index 0).
var members: Array[PartyNet.Member] = []

# --- The invite path ---------------------------------------------------------
## The game option "accept party invitations" (option byte +1 of 0x4f9d00).
## OpenSRO's option window has no such row yet: on by default (OURS until the
## row is built; the retail default is not read).
var accept_invitations := true
## The invitation the box is showing (kind 2/3), or 0 when none.
var pending_kind := 0
var pending_inviter := 0

## Injected by the world: whether `world_id` is a player spawned in this
## client (c:0x88ae1c..0x88ae2b: an invitation from anyone else is dropped
## unanswered), and that player's name. Unset: nobody is spawned.
var is_spawned_player: Callable
var player_name: Callable
## Injected by the world: the player's own job state (1..4), for +0x0c.
var own_job_state: Callable

func flags_byte() -> int:
	## The create request's type byte (c:0x81c7f0..0x81c82e).
	return (exp_share & 1) | ((item_share & 1) << 1) | ((anyone_invite & 1) << 2)

func cap() -> int:
	return PartyNet.CAP_EXP_SHARED if exp_share == 1 else PartyNet.CAP_NOT_SHARED

func is_full() -> bool:
	## c:0x987050: (exp == 0 && count == 4) || (exp == 1 && count == 8).
	return in_party and members.size() >= cap()

func is_leader() -> bool:
	return in_party and own_jid != 0 and own_jid == leader_jid

func member(jid: int) -> PartyNet.Member:
	for m in members:
		if m.jid == jid:
			return m
	return null

func leader() -> PartyNet.Member:
	return member(leader_jid)

## The member a window row's button acts on: list index row + 1
## (c:0x6d5a6b `add esi,1` -> 0x992380, then +0x3c the JID). That assumes the
## leader is member 0, which this list keeps.
func member_for_row(row: int) -> PartyNet.Member:
	var i := row + 1
	return members[i] if i >= 0 and i < members.size() else null

## The members shown in the window's seven rows: everyone but the leader, in
## list order (c:0x6d6640's loop over 0x992400(i), skipping the leader).
func row_members() -> Array[PartyNet.Member]:
	var out: Array[PartyNet.Member] = []
	for m in members:
		if m.jid != leader_jid:
			out.append(m)
	return out

## The "Set" dialog's Yes (c:0x6d6470): stores the three values. No request
## is sent; the next create carries them.
func set_preferences(exp: int, item: int, anyone: int) -> void:
	exp_share = 1 if exp != 0 else 0
	item_share = 1 if item != 0 else 0
	anyone_invite = 1 if anyone != 0 else 0
	changed.emit()

func clear_party() -> void:
	in_party = false
	party_id = 0
	leader_jid = 0
	flags = 0
	job_party = false
	members.clear()
	changed.emit()

## A new connection (or a disconnect): no party, no invitation, no known JID.
## The settings block is the player's preference and stays.
func reset_connection() -> void:
	own_jid = 0
	pending_kind = 0
	pending_inviter = 0
	clear_party()

func _name_of(jid: int) -> String:
	var m := member(jid)
	return m.member_name if m != null else ""

# --- Server messages ---------------------------------------------------------

## Routes one party message. Returns false for an opcode that is not ours.
func handle(opcode: int, data: PackedByteArray) -> bool:
	match opcode:
		PartyNet.OP_CREATE_ACK:
			_on_ack(PartyNet.decode_ack(data), false)
		PartyNet.OP_INVITE_ACK:
			_on_ack(PartyNet.decode_ack(data), false)
		PartyNet.OP_JOIN_ACK:
			_on_ack(PartyNet.decode_ack(data), true)
		PartyNet.OP_PARTY_INFO:
			_on_party_info(PartyNet.decode_party_info(data))
		PartyNet.OP_REQUEST:
			_on_request(PartyNet.decode_invitation(data))
		PartyNet.OP_EVENT:
			_on_event(PartyNet.decode_event(data))
		PartyNet.OP_ITEM_NOTICE:
			var n := PartyNet.decode_item_notice(data)
			if n != null:
				item_notice.emit(n.recipient_jid, _name_of(n.recipient_jid), n.item_id, n.amount, n.is_gold)
		_:
			return false
	return true

func _on_ack(a: PartyNet.Ack, is_join_ack: bool) -> void:
	if a == null:
		return
	if a.ok:
		if a.jid != 0:
			own_jid = a.jid
		if is_join_ack:
			_close_invitation()
		return
	if is_join_ack:
		# c:0x880120: the timeout code closes the box (request kind 6) and
		# returns before the message call -- the invitee sees no line. Any
		# other code shows its message; the box is gone by then anyway.
		_close_invitation()
		if a.code == PartyNet.ERR_TIMEOUT:
			return
	notice.emit(PartyNet.error_key(a.code), "", a.code)

func _close_invitation() -> void:
	if pending_kind != 0:
		pending_kind = 0
		pending_inviter = 0
		invitation_closed.emit()

func _on_party_info(p: PartyNet.PartyInfo) -> void:
	if p == null:
		return
	# 0x986f60(exp, item, anyone): the party's flags become the block, the
	# player is in a party, and +0x0c follows the player's own job state.
	in_party = true
	party_id = p.party_id
	if p.mask & 1:
		leader_jid = p.leader_jid
		flags = p.flags
		exp_share = flags & PartyNet.FLAG_EXP_SHARE
		item_share = (flags & PartyNet.FLAG_ITEM_SHARE) >> 1
		anyone_invite = (flags & PartyNet.FLAG_ANYONE_INVITE) >> 2
	var job: int = int(own_job_state.call()) if own_job_state.is_valid() else PartyNet.JOB_NONE
	job_party = job != PartyNet.JOB_NONE
	members.clear()
	for m in p.members:
		members.append(m)
	_keep_leader_first()
	changed.emit()

func _keep_leader_first() -> void:
	for i in members.size():
		if members[i].jid == leader_jid and i != 0:
			var m := members[i]
			members.remove_at(i)
			members.insert(0, m)
			return

func _on_event(e: PartyNet.Event) -> void:
	if e == null:
		return
	_apply_event(e)
	if e.kind != PartyNet.EVENT_UPDATE:
		var who := e.member.jid if e.kind == PartyNet.EVENT_JOINED and e.member != null else e.jid
		party_event.emit(e.kind, who)

func _apply_event(e: PartyNet.Event) -> void:
	match e.kind:
		PartyNet.EVENT_DISSOLVED:
			clear_party()
			notice.emit("UIIT_MSG_PARTY_BROKEN", "", 0)
		PartyNet.EVENT_JOINED:
			if member(e.member.jid) == null:
				members.append(e.member)
			changed.emit()
			notice.emit("UIIT_MSG_PARTY_JOIN", e.member.member_name, 0)
		PartyNet.EVENT_LEFT:
			var who := _name_of(e.jid)
			var key := ""
			match e.reason:
				PartyNet.LEAVE_LOGOUT:
					key = "UIIT_MSG_PARTY_LOGOUT"
				PartyNet.LEAVE_SECEDE:
					key = "UIIT_MSG_PARTY_SECEDE"
				PartyNet.LEAVE_BOOTED:
					key = "UIIT_MSG_PARTY_BOOTED"
				# 3, server migration: silent (debug line only).
			if e.jid == own_jid and own_jid != 0:
				clear_party()
			else:
				var m := member(e.jid)
				if m != null:
					members.erase(m)
				changed.emit()
			if key != "":
				notice.emit(key, who, 0)
		PartyNet.EVENT_UPDATE:
			var m := member(e.jid)
			if m != null and e.member != null:
				m.apply(e.member)
				member_updated.emit(e.jid)
		PartyNet.EVENT_LEADER:
			leader_jid = e.jid
			_keep_leader_first()
			changed.emit()
			notice.emit("UIIT_MSG_PARTY_HOST_ROLE_DELEGATED", _name_of(e.jid), 0)

func _on_request(inv: PartyNet.Invitation) -> void:
	if inv == null:
		return
	if inv.kind != PartyNet.REQUEST_FORM and inv.kind != PartyNet.REQUEST_JOIN:
		return  # the other request kinds (1, 4..10) are not the party's
	# c:0x88ad8a: the option off auto-declines with the kind's code.
	if not accept_invitations:
		send_answer.emit(PartyNet.encode_answer(inv.kind, false))
		return
	# c:0x88ae1c / 0x88ae2b: an inviter who is not a player spawned in this
	# client is dropped unanswered; the server times out after 30 s (0x2c10).
	var spawned: bool = is_spawned_player.is_valid() and bool(is_spawned_player.call(inv.inviter_id))
	if not spawned:
		return
	pending_kind = inv.kind
	pending_inviter = inv.inviter_id
	var who: String = String(player_name.call(inv.inviter_id)) if player_name.is_valid() else ""
	invitation.emit(inv.inviter_id, who, inv.kind, inv.flags)

## The box closed by its own timer (c:0x644650's timer 10): forget the
## invitation without answering, so the state and the box agree. The
## server's own wait answers both sides (0x2c10).
func forget_invitation() -> void:
	pending_kind = 0
	pending_inviter = 0

## The player's answer from the invitation box. Returns the 0x3080 payload
## to send, or an empty array when no invitation is showing.
func answer(accept: bool) -> PackedByteArray:
	if pending_kind == 0:
		return PackedByteArray()
	var payload := PartyNet.encode_answer(pending_kind, accept)
	pending_kind = 0
	pending_inviter = 0
	return payload
