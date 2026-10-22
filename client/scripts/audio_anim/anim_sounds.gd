extends RefCounted
class_name AnimSounds

## The sounds an animation fires: footsteps, swings, hurt and death voices,
## the fall, idle sounds. Each character `.bsr` carries, per animation, a
## list of sound tracks -- an event name at a key time (BsrReader.SoundSet;
## docs/protocol/BSR_FORMAT.md, "Sound tracks"). As a clip plays, every
## track whose key time it passes is dispatched by name the way the client's
## `CGEffSoundBody::vslot_009` (0x00a72a70) does: through a table of 52 names
## to a handler, which builds an effect-table key and plays it
## (AnimSoundSeam.play_key).
##
## Labels, as the project requires:
## - READ: the track format, the handler table, every key shape below, the
##   material and weapon token tables, and that a no-op handler is silent.
## - INFERRED: that a key time is milliseconds of the clip (a run's
##   footsteps at 289/619 of a clip), and that the set an animation fires is
##   the one keyed by the entry it was found as (BsrReader.sound_set_for).
##   How the times scale with playback speed is OPEN: this client plays every
##   clip at its authored speed, and the times are used as written.
## - OURS: a loop that is swapped in mid-cycle fires nothing until its next
##   key; a one-shot fires from 0 and is flushed to its end when it hands
##   back to its loop; a held one-shot (a death) keeps its clock running.
##
## Who is registered: the local player, other players and monsters, all
## through advance(). NPCs are not: their sound object is `PLAYER` and no
## `PLAYER:snd_walk1:-:-:-:-` row exists, so they would be silent anyway
## (INFERRED), and the paper doll is not a body in the world.

## The client's handler table at 0x00ec6660 (52 records of {name, handler},
## stride 0x20, filled into the map at this+0x48 by the constructor
## 0x00a76540), by what each handler does. READ, with the one-line thunks
## followed (snd_walk2 0xa70230 is `jmp 0xa6ffc0`, and so on).
const FOOT := "foot"            ## 0xa6ffc0
const SWING := "swing"          ## 0xa71510
const SIMPLE := "simple"        ## <obj>:<name>:-:-:-:- -- 0xa70740, 0xa71350, 0xa71da0, 0xa71f30
const MOAN := "moan"            ## 0xa720b0
const NOOP := "noop"            ## `mov eax,1; ret 0xc`: silent in retail
const PICKUP := "pickup"        ## 0xa6fec0: `ITEM:<name>:-:-:-:-`, no position
const BLOCK := "block"          ## 0xa70280: PC only, `PLAYER:<name>:-:-:<NORMAL|CRITYCAL>:-`
## SKILL (snd_swing_s*, voc_shout*) keys by the body's current skill -- built
## in round 785, with a monster's plain swing (SWING), once the server named
## a monster's attack skill (Owner.skill_ctx). Handlers in the table that are
## not built: fired by code rather than by an animation (hits, items, UI), or
## not traced (struct).
## snd_pickup and snd_blocking are fired by animation tracks in retail (66
## and 67 type-keyed tracks in the archive's character files), so they are
## built here; code may fire snd_blocking too, but the track path is the
## one the client's own data drives.
const SKILL := "skill"
const CODE := "code"
const STRUCT := "struct"

const HANDLERS := {
	"snd_hyan": CODE, "snd_dropitem": CODE, "snd_levup": CODE, "snd_cos_summon": CODE,
	"snd_walk1": FOOT, "snd_walk2": FOOT, "snd_walk3": FOOT,
	"snd_run1": FOOT, "snd_run2": FOOT, "snd_run3": FOOT,
	"snd_blocking": BLOCK, "snd_cridmg": CODE, "snd_cridmg_obj": CODE,
	"snd_death": SIMPLE, "snd_death1": SIMPLE, "snd_death2": SIMPLE,
	"snd_dmg": CODE, "snd_dmg_obj": CODE, "snd_ddmg": CODE,
	"snd_down": NOOP,
	"snd_equip": CODE, "snd_drop": CODE, "snd_dropfly": CODE, "snd_pickup": PICKUP,
	"snd_help": NOOP, "snd_hwancridmg": NOOP, "snd_hwandmg": NOOP, "snd_hwanswing": NOOP,
	"snd_stand": SIMPLE, "snd_stand1": SIMPLE, "snd_stand2": SIMPLE, "snd_stand3": SIMPLE, "snd_stand4": SIMPLE,
	"snd_swing1": SWING, "snd_swing2": SWING, "snd_swing3": SWING, "snd_swing4": SWING,
	"snd_swing_s1": SKILL, "snd_swing_s2": SKILL, "snd_swing_s3": SKILL, "snd_swing_s4": SKILL,
	"snd_activate": CODE, "snd_deactivate": NOOP, "snd_throw": NOOP,
	"voc_avoid": SIMPLE, "voc_death": SIMPLE, "voc_emo": NOOP, "voc_moan": MOAN,
	"voc_shout1": SKILL, "voc_shout2": SKILL,
	"snd_struct1": STRUCT, "snd_struct2": STRUCT,
}

## The footstep material by id: the string table at 0x00ec6608, indexed by
## the navmesh cell's material (READ). A terrain cell's is the tile2d.ifo
## type of the .nvm tile under the body; an object's cell always answers 0,
## DIRT (0x0040ecb0 is `xor eax,eax`). The ids are TileIndexReader.TileType.
const MATERIALS: Array[String] = [
	"DIRT", "SAND", "ASHFIELD", "STONE", "METAL", "WOOD", "MUD", "WATER",
	"DEEPWATER", "SNOW", "GRASS", "LONGGRASS", "FOREST", "CLOUD",
]

## The swing's weapon token by the TypeID4 of the item in equipment slot 6:
## FUN_00a64560's weapon switch, reached through FUN_00a648d0, which answers
## `PUNCH` for an empty slot (READ). Any other TypeID4 falls to the switch's
## default, an empty string (0x00e17460), whose key no row has.
const WEAPON_TOKENS := {
	2: "SWORD", 7: "SWORD", 3: "BLADE", 4: "SPEAR", 5: "TBLADE", 6: "BOW",
	8: "TSWORD", 9: "DUELAXE", 10: "WAND", 15: "WAND", 11: "STAFF",
	12: "CROSSBOW", 13: "DAGGER", 14: "HARP", 16: "HAMMER",
}
## weapon_kind for an empty weapon slot, and for one whose item the table
## does not know.
const WEAPON_NONE := 0
const WEAPON_UNKNOWN := -1

## One AUDIO line per key (or per skipped name) per this many milliseconds.
const LOG_INTERVAL_MS := 1000

## A body that makes sounds.
class Owner:
	## For the log: "player", "player 12", "monster 7".
	var label: String = ""
	## A player character: footsteps and swings take the PLAYER key family
	## (the handlers' TypeID test, `&2`, `&0x1c == 4`, `&0x60 == 0x20`).
	var is_pc: bool = false
	## The sound object (SoundTable.sound_object): PCM_FIGHTER, MOB_MANGNYANG. "" when
	## the table has none, which silences every key built from it.
	var token: String = ""
	var parsed: BsrReader.ParsedObject = null
	## Where the sound is; its global position is passed to the core.
	var node: Node3D = null
	## TypeID4 of the weapon held, WEAPON_NONE, or WEAPON_UNKNOWN.
	var weapon_kind: int = WEAPON_NONE
	## Berserk (hwan) is on: a swing plays `PLAYER:snd_swing3:-:HWAN:<W>:-`.
	var hwan: bool = false
	## The last hit taken was a critical: voc_moan's CRITYCAL row (the
	## client reads obj+0x441 & 2, FUN_00a63560; that the bit is the last
	## hit's critical flag is INFERRED).
	var critical: bool = false
	## () -> int: the material id under the body, or -1 when it stands on no
	## navmesh cell (the client plays no footstep then: obj+0x74 is null).
	## A monster's is asked too, only for whether it has a cell; with no
	## callable the body counts as having none.
	var material: Callable = Callable()
	## () -> {"code", "group"}: the body's CURRENT skill (round 785) -- the
	## skill of its running skill action, which the handlers key a monster's
	## swing and every skill swing and shout by. READ: an animation track
	## passes skill 0 to CGEffSoundBody::vslot_009, which substitutes
	## FUN_009ce0d0(obj): the first IDecoSkill in obj+0x284 with +0xc6 set,
	## its skill id (deco+0x5c); the code is the Basic_Code (and the group the
	## Basic_Group) after following Basic_Original to its root
	## (GEffSound::FUN_00a65180). SkillAudio.context_of answers it. With no
	## callable, or no current skill, both are "-" (DAT_00d81ea0, L"-").
	var skill_ctx: Callable = Callable()

	## The current skill's {"code", "group"}, "-" for none.
	func skill_context() -> Dictionary:
		if skill_ctx.is_valid():
			var got = skill_ctx.call()
			if got is Dictionary:
				return got
		return {"code": "-", "group": "-"}

var _owners: Dictionary = {}   # skeleton instance id -> [skeleton, Owner]
var _state: Dictionary = {}    # skeleton instance id -> [anim, instance start, clip ms]
var _last_logged: Dictionary = {}  # log key -> [msec, suppressed count]
var _ticks := 0

## The clock the log is rate-limited by; a test replaces it.
var now_msec: Callable = func() -> int: return Time.get_ticks_msec()
## Print the AUDIO lines (a test turns it off and reads `lines`).
var print_lines := true
## OPENSRO_QA_AUDIO_TRACE=1: one `AUDIO clip` line each time a registered
## body starts a clip -- which entry it is tagged as, and whether that entry
## has a sound set -- so a run shows why a sound did or did not fire.
var trace := OS.get_environment("OPENSRO_QA_AUDIO_TRACE") != ""
## The last AUDIO lines, newest last (at most 200).
var lines: Array[String] = []
## Every key sent to the core, with its clip time -- [key, key_ms, label] --
## for a test; not rate-limited. At most 1000.
var fired: Array = []

func register(skeleton: Object, owner: Owner) -> void:
	if skeleton == null or owner == null:
		return
	_owners[skeleton.get_instance_id()] = [skeleton, owner]
	_state.erase(skeleton.get_instance_id())

func unregister(skeleton: Object) -> void:
	if skeleton == null:
		return
	_owners.erase(skeleton.get_instance_id())
	_state.erase(skeleton.get_instance_id())

## Round 664: a registered body that is not advanced this frame because it
## is out of hearing (MonsterCrowd.hearable). Its next advance -- whenever it
## comes back -- fires nothing for the time it was away, loop or one-shot:
## it carries on from where its clip is then.
func rest(skeleton: Object) -> void:
	if skeleton == null:
		return
	var id := skeleton.get_instance_id()
	if _state.get(id) != null or not _state.has(id):
		if _owners.has(id):
			_state[id] = null

## Round 747 (its review, F1): a rested body that comes back for a clip
## starting now -- a far body brought back to the full path for a hit, a
## death, a sit-down (World3D._crowd_wake) -- forgets its rest, so the clip's
## first advance fires from its start (a key at 0 ms included) as a body that
## was never rested does. rest() is for time a body was away; this one-shot
## begins at the moment it comes back.
func wake(skeleton: Object) -> void:
	if skeleton != null:
		_state.erase(skeleton.get_instance_id())

## Round 747 (F2): how many ms of clip time from `clip_ms` until the next
## sound track of `anim` on `skeleton` (wrapping for a loop), or INF when the
## clip has no track for this body (no owner, no tag, no sound set: every
## sitting loop and most stand sets). A far body is advanced only when its
## clock passes that time (World3D._crowd_sound_step).
func next_key_ms(skeleton: Object, anim: Object, clip_ms: float, loops: bool) -> float:
	if skeleton == null or anim == null:
		return INF
	var pair = _owners.get(skeleton.get_instance_id())
	if pair == null:
		return INF
	var owner: Owner = pair[1]
	if owner.parsed == null:
		return INF
	# The clip's sound set for this body's file, looked up once (a far crowd
	# asks at every key and every gait change).
	var per = _sets.get(anim)
	if per == null:
		per = {}
		_sets[anim] = per
	var sound_set = per.get(owner.parsed, false)
	if typeof(sound_set) == TYPE_BOOL:
		var tag = anim.get_meta(BsrReader.CLIP_META, null)
		sound_set = owner.parsed.sound_set_for(int(tag[0]), String(tag[1])) if tag != null else null
		per[owner.parsed] = sound_set
	if sound_set == null or (sound_set as BsrReader.SoundSet).tracks.is_empty():
		return INF
	var duration := float(anim.get("duration_ms"))
	var best := INF
	var first := INF
	for t in sound_set.tracks:
		var key := float((t as BsrReader.SoundTrack).key_ms)
		if loops and duration > 0.0 and key >= duration:
			continue
		first = minf(first, key)
		if key > clip_ms:
			best = minf(best, key - clip_ms)
	if best == INF and loops and first != INF and duration > 0.0:
		best = duration - clip_ms + first
	return best

## clip -> {parsed .bsr -> its SoundSet or null} (next_key_ms).
var _sets := {}

## Round 747 (F2): `skeleton` is on loop `anim` at `clip_ms` from now, with
## nothing fired: what advance() does on a loop's first frame, without its
## lookups (a far body's gait change, in a crowd's bursts).
func prime(skeleton: Object, anim: Object, start: float, clip_ms: float) -> void:
	if skeleton != null and _owners.has(skeleton.get_instance_id()):
		_state[skeleton.get_instance_id()] = [anim, start, clip_ms]

func owner_of(skeleton: Object) -> Owner:
	if skeleton == null:
		return null
	var pair = _owners.get(skeleton.get_instance_id())
	return null if pair == null else pair[1]

## Called for every body every frame, with the clip it is posed in: `start`
## identifies this play of it (the time it started, or a loop's own), and
## `clip_ms` is where in it the pose is -- wrapped into the clip for a loop,
## the time since it started for a one-shot. Fires the tracks passed since
## the last call for the same play.
func advance(skeleton: Object, anim: Object, start: float, clip_ms: float, loops: bool) -> void:
	_ticks += 1
	if _ticks % 600 == 0:
		_prune()
	if skeleton == null or anim == null:
		return
	# Round 794: the body's clip, for its worn items' own clips (WornItemFx).
	if skeleton is Node and (skeleton as Node).get_meta(WornItemFx.BODY_CLIP_META, null) != anim:
		(skeleton as Node).set_meta(WornItemFx.BODY_CLIP_META, anim)
	var id := skeleton.get_instance_id()
	var pair = _owners.get(id)
	if pair == null:
		return
	var owner: Owner = pair[1]
	var state = _state.get(id)
	var same: bool = state != null and state[0] == anim and is_equal_approx(float(state[1]), start)
	var prev: float
	if same:
		prev = float(state[2])
	elif loops or (state == null and _state.has(id)):
		# A loop's first frame, or a body back from rest(): nothing passed.
		prev = clip_ms
	else:
		prev = -1.0
	_state[id] = [anim, start, clip_ms]
	var tag = anim.get_meta(BsrReader.CLIP_META, null)
	if not same and trace:
		print("AUDIO clip %s %s %s %d ms%s" % [owner.label, "loop" if loops else "once",
			"untagged" if tag == null else "%d:%s" % [int(tag[0]), String(tag[1])], int(anim.get("duration_ms")),
			"" if owner.parsed == null or tag == null or owner.parsed.sound_set_for(int(tag[0]), String(tag[1])) != null else " (no sound set)"])
	if owner.parsed == null:
		return
	if tag == null:
		return
	# Round 809: the clip's own particle set (BodyFx): the entries whose keys
	# it passed, and whether this play of it just started (its last run's
	# effects stop). A clip met first after its start (a crowd loop's phase,
	# a body back from rest) fires nothing it skipped.
	if clip_fx.is_valid():
		var fx_entries := owner.parsed.particle_entries_for(int(tag[0]), String(tag[1]))
		if not fx_entries.is_empty():
			var fx_prev := prev
			if not same and clip_ms <= CLIP_FX_START_MS:
				fx_prev = -1.0
			var fx_dur := float(anim.get("duration_ms"))
			var hit: Array = []
			for e in fx_entries:
				if key_crossed(float((e as BsrReader.ParticleEntry).w4c), fx_prev, clip_ms, fx_dur, loops):
					hit.append(e)
			if not same or not hit.is_empty():
				clip_fx.call(owner, skeleton, "%d:%s" % [int(tag[0]), String(tag[1])], hit, not same)
	# Round 808's follow-up: a walk's or run's footstep keys (event type 2) for
	# the footprints (Footprints; the move state's event handler 0xa5a3f0).
	if footstep.is_valid() and (int(tag[0]) == WALK_TYPE or int(tag[0]) == RUN_TYPE):
		var entry := owner.parsed.animation_entry_for(int(tag[0]), String(tag[1]))
		if entry != null:
			var dur := float(anim.get("duration_ms"))
			for e in entry.events:
				var ev := e as PackedInt32Array
				if ev.size() >= 4 and ev[1] == FOOTSTEP_EVENT and key_crossed(float(ev[0]), prev, clip_ms, dur, loops):
					footstep.call(owner, skeleton, ev[3])
	var sound_set := owner.parsed.sound_set_for(int(tag[0]), String(tag[1]))
	if sound_set == null or sound_set.tracks.is_empty():
		return
	var duration := float(anim.get("duration_ms"))
	for track in crossed(sound_set.tracks, prev, clip_ms, duration, loops):
		dispatch(owner, track, "%d:%s" % [int(tag[0]), String(tag[1])])

## Round 808's follow-up: called with (owner, skeleton, the key's second
## parameter -- 0 the left foot, else the right) for each footstep key a walk
## or run passes; World3D lays the footprints (Footprints).
var footstep: Callable = Callable()
## Round 809: called with (owner, skeleton, "type:group", the particle
## entries whose keys the clip passed, whether the clip just started) for a
## clip whose body carries a particle set of its type (BodyFx).
var clip_fx: Callable = Callable()
## A clip first met this far into it (ms) or less counts as just started: its
## keys from 0 fire (READ: a key of 0 fires on the clip's first frame).
const CLIP_FX_START_MS := 100.0
const WALK_TYPE := 1
const RUN_TYPE := 7
const FOOTSTEP_EVENT := 2

## Whether one key at `key` ms is passed going from `prev` to `now` (crossed's
## rule for a single key).
static func key_crossed(key: float, prev: float, now: float, duration: float, loops: bool) -> bool:
	if loops and duration > 0.0 and key >= duration:
		return false
	if loops and now < prev:
		return key > prev or key <= now
	return key > prev and key <= now

## The tracks a clip passes going from `prev` to `now` (milliseconds): those
## with prev < key <= now, or -- for a loop that wrapped -- key > prev or
## key <= now, keys at or past the loop's length never reached. In file
## order.
static func crossed(tracks: Array, prev: float, now: float, duration: float, loops: bool) -> Array:
	var out: Array = []
	var wrapped := loops and now < prev
	for t in tracks:
		var key := float((t as BsrReader.SoundTrack).key_ms)
		if loops and duration > 0.0 and key >= duration:
			continue
		if wrapped:
			if key > prev or key <= now:
				out.append(t)
		elif key > prev and key <= now:
			out.append(t)
	return out

## Dispatches one track by its name: builds the key its handler would and
## sends it to the core, or logs why it is silent.
func dispatch(owner: Owner, track: BsrReader.SoundTrack, clip: String = "") -> void:
	var built := key_for(owner, track.name)
	var key: String = built["key"]
	if key == "":
		_log("skip:%s:%s" % [track.name, built["why"]], "AUDIO skip %s (%s) %s clip %s t=%dms" % [
			track.name, built["why"], owner.label, clip, track.key_ms])
		return
	var pos = null
	var node = null
	if bool(built.get("positional", true)) and owner.node != null and is_instance_valid(owner.node):
		node = owner.node
		if owner.node.is_inside_tree():
			pos = owner.node.global_position
	if fired.size() < 1000:
		fired.append([key, track.key_ms, owner.label])
	AnimSoundSeam.play_key(key, pos, node)
	_log(key, "AUDIO %s t=%dms clip %s %s%s" % [key, track.key_ms, clip, owner.label,
		"" if pos == null else " at %.0f,%.0f,%.0f" % [pos.x, pos.y, pos.z]])

## The effect-table key a handler builds for `handle` fired on `owner`:
## {"key": the key, or "" when it is silent, "why": the reason}. The key
## shapes are READ from the handlers named in HANDLERS; they are spelled by
## the core's SoundTable.make_key, as the table stores them.
static func key_for(owner: Owner, handle: String) -> Dictionary:
	var kind: String = HANDLERS.get(handle, "")
	match kind:
		"":
			return {"key": "", "why": "no handler"}
		NOOP:
			return {"key": "", "why": "no-op handler"}
		FOOT:
			# No cell under the body (obj+0x74 null): the handler returns at
			# once, for every object, monsters included (READ, 0xa6ffc0).
			var mat := -1
			if owner.material.is_valid():
				mat = int(owner.material.call())
			if mat < 0 or mat >= MATERIALS.size():
				return {"key": "", "why": "no navmesh cell"}
			if owner.is_pc:
				return {"key": SoundTable.make_key("PLAYER", handle, "-", "FIELD", MATERIALS[mat]), "why": ""}
			if owner.token == "":
				return {"key": "", "why": "no sound object"}
			return {"key": SoundTable.make_key(owner.token, handle), "why": ""}
		SWING:
			if not owner.is_pc:
				# Round 785 (READ, 0xa71510's non-player branch): the sound
				# object, the handle and the current skill's Basic_Code.
				if owner.token == "":
					return {"key": "", "why": "no sound object"}
				return {"key": SoundTable.make_key(owner.token, handle, _code_token(owner.skill_context(), "code")), "why": ""}
			var weapon := weapon_token(owner.weapon_kind)
			if weapon == "":
				return {"key": "", "why": "weapon kind %d has no token" % owner.weapon_kind}
			if owner.hwan:
				return {"key": SoundTable.make_key("PLAYER", "snd_swing3", "-", "HWAN", weapon), "why": ""}
			return {"key": SoundTable.make_key("PLAYER", handle, "-", weapon), "why": ""}
		PICKUP:
			# `ITEM:` + name + `:-:-:-:-`, played with no position (the
			# play-by-key call passes 0).
			return {"key": SoundTable.make_key("ITEM", handle), "why": "", "positional": false}
		BLOCK:
			if not owner.is_pc:
				return {"key": "", "why": "the blocking handler plays for a player character only"}
			return {"key": SoundTable.make_key("PLAYER", handle, "-", "-", "CRITYCAL" if owner.critical else "NORMAL"), "why": ""}
		MOAN:
			if owner.token == "":
				return {"key": "", "why": "no sound object"}
			return {"key": SoundTable.make_key(owner.token, "voc_moan", "-", "CRITYCAL" if owner.critical else "NORMAL"), "why": ""}
		SIMPLE:
			if owner.token == "":
				return {"key": "", "why": "no sound object"}
			return {"key": SoundTable.make_key(owner.token, handle), "why": ""}
		SKILL:
			# Round 785 (READ): snd_swing_s1..4 (0xa718d0; s2-s4 jump to it)
			# key a player character as PLAYER with the current skill's
			# Basic_Group, anything else by its sound object with the
			# Basic_Code; voc_shout1/2 (0xa72260; shout2 0xa72570 jumps to
			# it) key a player character by its OWN sound object with no
			# skill token, anything else by its sound object with the
			# Basic_Code.
			var ctx := owner.skill_context()
			if handle.begins_with("voc_shout"):
				if owner.token == "":
					return {"key": "", "why": "no sound object"}
				if owner.is_pc:
					return {"key": SoundTable.make_key(owner.token, handle), "why": ""}
				return {"key": SoundTable.make_key(owner.token, handle, _code_token(ctx, "code")), "why": ""}
			if owner.is_pc:
				return {"key": SoundTable.make_key("PLAYER", handle, _code_token(ctx, "group")), "why": ""}
			if owner.token == "":
				return {"key": "", "why": "no sound object"}
			return {"key": SoundTable.make_key(owner.token, handle, _code_token(ctx, "code")), "why": ""}
	return {"key": "", "why": "%s handler not built yet" % kind}

## A skill context's code or group, "-" when it has none.
static func _code_token(ctx: Dictionary, field: String) -> String:
	var v := String(ctx.get(field, "-"))
	return v if v != "" else "-"

## The footstep material id (MATERIALS) of the cell a body stands in, or
## -1 when there is none. `footing` is NavGraph.ON_TERRAIN or an object
## index: an object's (or building's) cell always answers 0, DIRT -- its
## slot 3 is `xor eax,eax` at 0x0040ecb0 (READ). A terrain cell answers the
## high 16 bits of the region's 20-unit .nvm tile word under (x, z)
## (FUN_00403940), which the load rewrites to the tile2d.ifo type (READ):
## here NvmReader.Tile.texture_id looked up in the tile table. There is no
## water-depth test.
static func material_at(region: NvmReader.ParsedRegion, x: float, z: float, footing: int,
		table: TileIndexReader.Table) -> int:
	if footing != NavGraph.ON_TERRAIN:
		return 0
	if region == null or table == null or region.tiles.size() < NvmReader.TILE_COUNT:
		return -1
	var col := int(floorf(x / NavGraph.TILE_SIZE))
	var row := int(floorf(z / NavGraph.TILE_SIZE))
	if col < 0 or row < 0 or col >= NvmReader.TILE_MAP_SIDE or row >= NvmReader.TILE_MAP_SIDE:
		return -1
	var entry := table.lookup(region.tiles[row * NvmReader.TILE_MAP_SIDE + col].texture_id)
	return -1 if entry == null else int(entry.type)

## The weapon token for a TypeID4 (WEAPON_TOKENS), `PUNCH` for an empty
## slot, "" for anything else.
static func weapon_token(weapon_kind: int) -> String:
	if weapon_kind == WEAPON_NONE:
		return "PUNCH"
	return WEAPON_TOKENS.get(weapon_kind, "")

## One AUDIO line per `rate_key` per LOG_INTERVAL_MS; the lines swallowed in
## between are counted onto the next one.
func _log(rate_key: String, line: String) -> void:
	var now: int = int(now_msec.call())
	var entry = _last_logged.get(rate_key)
	if entry != null and now - int(entry[0]) < LOG_INTERVAL_MS:
		entry[1] = int(entry[1]) + 1
		return
	var suppressed: int = 0 if entry == null else int(entry[1])
	_last_logged[rate_key] = [now, 0]
	if suppressed > 0:
		line += " (+%d since the last line)" % suppressed
	lines.append(line)
	if lines.size() > 200:
		lines.remove_at(0)
	if print_lines:
		print(line)

## Drops bodies whose skeleton has been freed (a region streamed out, a
## monster gone).
func _prune() -> void:
	for a in _sets.keys():
		if not is_instance_valid(a):
			_sets.erase(a)
	for id in _owners.keys():
		if not is_instance_valid(_owners[id][0]):
			_owners.erase(id)
			_state.erase(id)
	for id in _state.keys():
		if not _owners.has(id):
			_state.erase(id)
