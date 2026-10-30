extends RefCounted
class_name HostileData

## Round 844 (lane V): the guild's wars as the client keeps them -- the
## hostile map at CharacterDependentData +0x148 +0xa4 (count +0xa8), each
## entry 0x40 bytes (adder FUN_00999260, "!IsHostileGuild(sGuildWarDef.
## dwGuildWarID)"): +4 the war id, +8 the other guild's id, +0xc its name,
## +0x2c the victory index, +0x30 the own guild's points, +0x34 theirs, +0x38
## the wager, +0x3c the seconds left (0x7fffffff unlimited). READ in
## sro_client.exe; docs/protocol/guild_war.md has the whole of it.
##
## Fed by 0x3109 (FUN_0087fd90 -> 0x99ab20, which only adds: sent once at
## world entry, INFERRED) and 0x38F5's war types (FUN_00887330). Guild lines
## turn red by is_hostile (GuildLineColour), and a hostile guild's member is
## an enemy without Alt (IsEnemy, c:0x9de780).


var wars: Array = []
## The interface's request state (the hostile window's +0x78c): 0 none, 1
## this master proclaimed and waits, 2 this master was proclaimed on.
var pending := 0
## The end countdown runs (+0x7c8): the end button stays disabled.
var ending := false

## The list or an entry changed (the war pane, the hostile pane, the guild
## lines and the name colours redraw: 0x5af760, 0x5b3c50, 0x9a4450, 0x9dbd10).
signal changed()
## A line for the system window (0x7781b0(0, text), colour 0xffdbc99b).
signal line(key: String, args: Array)
## A GDR_WARNING_WND banner (0x77b580).
signal banner(key: String, args: Array)
## A MsgBoxSimple (GInterface 0x788270): the title's key, the text's key(s)
## with their values (texts joined by "\n").
signal box(title_key: String, keys: Array, args: Array)
## 0x1a / 0x1b: the one-minute countdown starts (0x781250(60)).
signal countdown(seconds: int)
## 0x1c: a war ended (the action against a hostile target is cancelled
## first, 0x7074 {2}).
signal war_ended(war_id: int, other_name: String)
## 0x32 sub 2 for the proclaimed-on master: the waiting box closes.
signal request_closed()

func clear() -> void:
	var had := not wars.is_empty()
	wars.clear()
	pending = 0
	ending = false
	if had:
		changed.emit()

func count() -> int:
	return wars.size()

## FUN_00992a90: whether guild_name is in the hostile map.
func is_hostile(guild_name: String) -> bool:
	if guild_name == "":
		return false
	for w in wars:
		if (w as GuildWarNet.War).name == guild_name:
			return true
	return false

func war(war_id: int) -> GuildWarNet.War:
	for w in wars:
		if (w as GuildWarNet.War).war_id == war_id:
			return w
	return null

## The adder (0x999260): own side by guild A or B; an entry naming neither,
## or one already kept, is dropped.
func _add(w: GuildWarNet.War, own_guild_id: int) -> bool:
	if w == null or w.war_id == 0 or war(w.war_id) != null:
		return false
	if w.guild_a == own_guild_id:
		w.other_id = w.guild_b
		w.own_points = w.points_a
		w.their_points = w.points_b
	elif w.guild_b == own_guild_id:
		w.other_id = w.guild_a
		w.own_points = w.points_b
		w.their_points = w.points_a
	else:
		return false
	wars.append(w)
	return true

## 0x3109: u8 n x {SGuildWarDef, str the hostile guild's name}.
func parse_list(data: PackedByteArray, own_guild_id: int) -> bool:
	var r := GuildData._Reader.new(data)
	var n := r.u8()
	for i in n:
		var w := GuildWarNet.read_def(r)
		var gname := r.s()
		if w == null or not r.ok:
			break
		w.name = gname
		_add(w, own_guild_id)
	changed.emit()
	return r.ok

## One of 0x38F5's war types, the type byte already read. `gd` is the guild.
func apply_update(kind: int, r: GuildData._Reader, gd: GuildData) -> void:
	match kind:
		GuildWarNet.UPDATE_WAR_STARTED:
			# 0x5b2a80: the entry, then GOTOWAR (own, theirs) on the banner.
			var w := GuildWarNet.read_def(r)
			if w == null:
				return
			if w.war_id != 0:
				w.name = r.s()
				if not r.ok:
					return
			if _add(w, gd.guild_id):
				banner.emit("UIIT_MSG_GUILDWAR_GOTOWAR", [gd.guild_name, w.name])
				changed.emit()
		GuildWarNet.UPDATE_WAR_ENDING, GuildWarNet.UPDATE_WAR_ENDING_B:
			var w := war(r.u32())
			if not r.ok or w == null:
				return
			ending = true
			box.emit("UIIT_STT_EVENTGUIDE", ["UIIT_CTL_GUILDWAR_ENDCOUNT"], [gd.guild_name, w.name])
			countdown.emit(60)
			changed.emit()
		GuildWarNet.UPDATE_WAR_ENDED:
			var id := r.u32()
			var winner := r.u32()
			var w := war(id)
			if not r.ok or w == null:
				return
			war_ended.emit(id, w.name)
			# 0x5b25a0: won or lost, with the hostile guild's name.
			var key := "UIIT_MSG_GUILDWAR_WINERGUILD" if winner == gd.guild_id else "UIIT_MSG_GUILDWAR_LOSEGUILD"
			box.emit("UIIT_STT_EVENTGUIDE", [key], [w.name])
			wars.erase(w)
			ending = false
			changed.emit()
		GuildWarNet.UPDATE_WAR_KILL:
			_kill(r, gd)
		GuildWarNet.UPDATE_WAR_TIME:
			var w := war(r.u32())
			var secs := r.u32()
			if r.ok and w != null:
				w.remain = secs
				changed.emit()
		GuildWarNet.UPDATE_HOSTILE_RENAMED:
			var gid := r.u32()
			var gname := r.s()
			if not r.ok:
				return
			for w in wars:
				if (w as GuildWarNet.War).other_id == gid:
					(w as GuildWarNet.War).name = gname
			changed.emit()
		GuildWarNet.UPDATE_WAR_REQUEST:
			_request_outcome(r)

## 0x1d (0x5afc70): u8 side, u32 war, u32 points, u32 the own member, str
## the enemy, and when that is empty str the owner of the COS that fell.
func _kill(r: GuildData._Reader, gd: GuildData) -> void:
	var side := r.u8()
	var w := war(r.u32())
	var pts := r.u32()
	var mid := r.u32()
	var enemy := r.s()
	if not r.ok or w == null:
		return
	if enemy == "":
		var owner := r.s()
		if not r.ok:
			return
		enemy = "*" + owner
	var m := gd.member(mid)
	if side == 1:
		w.own_points += pts
		if m != null:
			m.war_kill += 1
			m.contribution += pts
	elif side == 2:
		w.their_points += pts
		if m != null:
			m.war_killed += 1
	var who := m.member_name if m != null else ""
	banner.emit("UIIT_MSG_GUILDWAR_KILLNEWS", [who, enemy, enemy])
	changed.emit()
	gd.changed.emit()

## 0x32 (c:0x887330): sub 0 refused, 2 timed out, 3 no gold to accept.
func _request_outcome(r: GuildData._Reader) -> void:
	var sub := r.u8()
	if not r.ok:
		return
	match sub:
		GuildWarNet.REQUEST_REFUSED:
			var gname := r.s()
			if r.ok:
				pending = 0
				line.emit("UIIT_MSG_GUILDWAR_WARREFUSAL", [gname])
				banner.emit("UIIT_MSG_GUILDWAR_WARREFUSAL", [gname])
		GuildWarNet.REQUEST_TIMED_OUT:
			r.s()
			if pending == 1:
				line.emit("UIIT_MSG_GUILDWARERR_REQUISITION_TIME_OUT", [])
				banner.emit("UIIT_MSG_GUILDWARERR_REQUISITION_TIME_OUT", [])
			elif pending == 2:
				request_closed.emit()
			pending = 0
		GuildWarNet.REQUEST_NO_GOLD:
			box.emit("UIIT_STT_EVENTGUIDE", ["UIIT_MSG_GUILDWAR_SUGGESTIONS_01", "UIIT_MSG_GUILDWAR_SUGGESTIONS_02"], [])
