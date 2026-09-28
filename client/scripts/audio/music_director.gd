extends Node
class_name MusicDirector

## The zone music and the ambient beds (round 612): the node that turns
## ZoneMusic's and AmbientBeds' decisions into players. It lives under the
## "Audio" autoload as its child "Music" (`Audio.music`), so the world and
## the front-end screens reach it the same way:
##
##   Audio.music.set_area_at(region_x, region_y, local_x, local_z)
##       the player's position, every few ticks (World3D) -- resolves the zone
##       name in the English regioninfo.txt (RECT first, then ALL) and calls
##   Audio.music.set_area(zone_name)          SetArea (vslot_026)
##   Audio.music.enter_loading(reason)        the loading screen: silence
##   Audio.music.play_intro()                 the title screen's IntroBGM
##   Audio.music.push_bgm(name, level) / pop_bgm(all, level)
##       the override levels: ZoneMusic.LEVEL_SIEGE (1) is fortress war's
##       fortress_war.ogg (Siege_OnStructAllInfo 0x89624d pushes it, READ),
##       ZoneMusic.LEVEL_SCRIPT (3) a script's S_SetBGM (Process_S_SetBGM,
##       FUN_00509950, READ). Nothing in this client calls them yet; they are
##       the hooks for the siege and scene systems.
##   Audio.music.set_game_hour(h)
##       THE CLOCK: this client has no game clock (docs/protocol/game_clock.md:
##       the server's 0x34be time sync is neither sent nor read here), so the
##       hour is unknown and the DAY list always plays -- recorded, not
##       guessed. Retail reads its clock as hours (FUN_008b01b0) and picks the
##       night list for h < 4 or h > 20 at each zone change (READ).
##
## Every music change logs one line, `AUDIO bgm: <zone> -> <file>`, and every
## ambient start `AUDIO ambient: <zone> <day|night>: beds [...], <n> one-shots`;
## ZoneMusic and AmbientBeds say what is READ and what is ours.

## The English region table (65 sections, MEASURED) -- Data.pk2's root copy,
## md5-identical to Media.pk2's server_dep one; the Shader\ copy the zone
## label reads names only 15 Korean zones.
const REGIONINFO_PATH := RegioninfoReader.ENGLISH_PATH

var music := ZoneMusic.new()
var ambient := AmbientBeds.new()
## The area SetArea last took ("" = none).
var area := ""
## Game hour, or -1 for "no clock" (day).
var game_hour := -1.0

var _bgm_player: AudioStreamPlayer
var _bed_players: Array = []
## Normalised path -> Array of one-shot players.
var _shot_players: Dictionary = {}
var _env_table: Dictionary = {}
var _env_loaded := false
var _regioninfo: RegioninfoReader.ParsedTable = null
var _regioninfo_loaded := false
var _rng := RandomNumberGenerator.new()
var _intro_bgm := ""
var _intro_loaded := false
var _clock_logged := false
## Seconds until the one-line playing report after a start (-1 = none due).
var _report_in := -1.0
## Decodes running on a WorkerThreadPool task (review follow-up): each
## {id, label, t0}. A zone's track, beds and one-shots decode there, so no
## large file decodes on a gameplay frame; what waits for them is below.
var _tasks: Array = []
var _dirs_warmed := false
## Data.pk2 folders the first effect sounds come from (effectsound's folders,
## MEASURED: player, monster, ui and env hold most rows).
const WARM_DIRS := ["ui", "player", "monster", "env", "skill", "common"]
## A track whose start order came before its decode finished.
var _waiting_track := ""
## The current list's beds wait for their decode.
var _beds_waiting := false

func _ready() -> void:
	_rng.randomize()
	_bgm_player = AudioStreamPlayer.new()
	_bgm_player.name = "BGM"
	_bgm_player.bus = AudioOptions.BUS_BGM
	add_child(_bgm_player)

func _process(delta: float) -> void:
	_poll_tasks()
	music.advance(delta)
	_drain_commands()
	var options := _options()
	_bgm_player.volume_db = music.fade_offset_db(AudioOptions.slider_db(options.bgm) if options != null else 0.0)
	if _report_in >= 0.0:
		_report_in -= delta
		if _report_in < 0.0:
			print("AUDIO bgm: %s playing=%s at %.2f s of %.2f s (player volume %.1f dB on the BGM bus)" % [
				music.sounding, str(_bgm_player.playing), _bgm_player.get_playback_position(),
				_bgm_player.stream.get_length() if _bgm_player.stream != null else 0.0, _bgm_player.volume_db])
	if options != null and options.env_muted:
		return
	for s in ambient.advance(delta, func(): return _rng.randi()):
		var shot: AmbientBeds.Shot = s
		_play_shot(shot.file)
		if not shot.played:
			shot.played = true
			print("AUDIO ambient: %s one-shot %s first play, next in %d s" % [area, shot.file, shot.countdown])

# --- the zone -----------------------------------------------------------------

## The zone at a region-local position, from the English regioninfo.txt,
## or "" when no row claims it.
func zone_at(region_x: int, region_y: int, local_x: float, local_z: float) -> String:
	var table := _region_table()
	if table == null:
		return ""
	return table.zone_name_for_position(region_x, region_y, local_x, local_z)

func set_area_at(region_x: int, region_y: int, local_x: float, local_z: float) -> void:
	set_area(zone_at(region_x, region_y, local_x, local_z))

## SetArea (vslot_026, READ): nothing when unchanged; else stop the ambient,
## take the zone's record, play its music (ZoneMusic decides) and start the
## day or night list.
func set_area(zone_name: String) -> void:
	if zone_name == area:
		return
	var previous := area
	area = zone_name
	_stop_ambient()
	var zone: EnvSoundTable.Zone = env_table().get(zone_name) if zone_name != "" else null
	var night := AmbientBeds.is_night(game_hour)
	if zone != null:
		_prefetch_zone(zone, night)
	var track_before := music.track
	var outcome := music.enter_area(zone != null, zone.bgm if zone != null else "")
	_drain_commands()
	match outcome:
		"start", "fade":
			print("AUDIO bgm: %s -> %s (%s)" % [zone_name, zone.bgm, "start" if outcome == "start" else "fade out %s over %.1f s, then start" % [track_before, ZoneMusic.FADE_STEPS * ZoneMusic.FADE_STEP_SECONDS]])
		"same":
			print("AUDIO area: %s -> %s: same track %s keeps playing" % [previous if previous != "" else "-", zone_name, zone.bgm])
		"held":
			print("AUDIO area: %s: its track %s waits (%s)" % [zone_name, zone.bgm, "BGM muted" if music.muted else "override level %d playing" % music.active_level])
		"unknown":
			print("AUDIO area: %s has no sound record -- the music keeps playing%s" % [
				zone_name if zone_name != "" else "(none)", (" (%s)" % music.sounding) if music.sounding != "" else ""])
	if zone == null:
		return
	if not _clock_logged:
		_clock_logged = true
		if game_hour < 0.0:
			print("AUDIO clock: this client has no game clock -- the day ambient list plays (retail: night is hour < 4 or > 20)")
	var beds := ambient.start(zone.list_for(night))
	print("AUDIO ambient: %s %s: beds %s, %d one-shots%s" % [zone_name, "night" if night else "day", str(Array(beds)),
		ambient.shots.size(), " (decoding)" if _beds_waiting else ""])
	if not _beds_waiting:
		_start_beds()

## The loading screen (FUN_0084ab20, READ): music and ambient stop, the area
## is cleared, every override level is popped.
func enter_loading(reason: String = "") -> void:
	_preload_tables()
	_waiting_track = ""
	var was := music.sounding
	music.enter_loading()
	_stop_ambient()
	area = ""
	_drain_commands()
	if was != "":
		print("AUDIO bgm: loading (%s) -- %s stops, the loading screen is silent" % [reason, was])

## Leaving the world for the front end: the ambient stops and the area is
## forgotten; the music keeps playing until the title screen pushes its own
## (OURS: retail's world -> title path goes through CPSQuit, not read here).
func leave_world() -> void:
	_stop_ambient()
	area = ""

## CPSTitle::OnCreate pushes option.txt's IntroBGM at level 0 (0x86be78,
## READ); server select, character select and character create touch
## nothing, so it keeps playing through them (INFERRED from the absence of
## any other caller).
func play_intro() -> void:
	var name := intro_bgm()
	if name == "":
		return
	var before := music.sounding
	music.push(name, ZoneMusic.LEVEL_TITLE)
	_drain_commands()
	if music.sounding != before:
		print("AUDIO bgm: title -> %s" % name)

func intro_bgm() -> String:
	if not _intro_loaded:
		_intro_loaded = true
		var bytes := AudioBank.read_table("media", EnvSoundTable.OPTION_PATH)
		if not bytes.is_empty():
			_intro_bgm = EnvSoundTable.parse_intro_bgm(bytes)
			if _intro_bgm == "":
				print("AUDIO: %s names no IntroBGM -- the title is silent" % EnvSoundTable.OPTION_PATH)
	return _intro_bgm

func push_bgm(name: String, level: int) -> void:
	music.push(name, level)
	_drain_commands()
	print("AUDIO bgm: override level %d -> %s" % [level, name])

func pop_bgm(all_levels: bool, level: int = 0) -> void:
	music.pop(all_levels, level)
	_drain_commands()
	print("AUDIO bgm: override %s popped -> %s" % ["every level" if all_levels else "level %d" % level, music.track if music.track != "" else "silence"])

func set_game_hour(hour: float) -> void:
	game_hour = hour

## The mutes, from AudioService.set_options: BGM mute stops the track and
## un-mute restarts it from the top (READ); Env mute stops the ambient and
## un-mute restarts the beds (OURS: retail's un-mute leaves the bed silent
## until the next zone change, a bug read at 0xa6e36c and not copied).
func apply_mutes(options: AudioOptions) -> void:
	music.set_muted(options.bgm_muted)
	_drain_commands()
	if options.env_muted:
		_stop_env_players()
	elif _bed_players.is_empty() and not ambient.beds.is_empty():
		_start_beds()

# --- tables -------------------------------------------------------------------

func env_table() -> Dictionary:
	if not _env_loaded:
		_env_loaded = true
		var bytes := AudioBank.read_table("media", EnvSoundTable.PATH)
		if not bytes.is_empty():
			_env_table = EnvSoundTable.parse(bytes)
			print("AUDIO: effectenvsnd %d zones" % _env_table.size())
	return _env_table

## Test seam.
func set_env_table(table: Dictionary) -> void:
	_env_table = table
	_env_loaded = true

func _region_table() -> RegioninfoReader.ParsedTable:
	if not _regioninfo_loaded:
		_regioninfo_loaded = true
		var bytes := AudioBank.read_table("data", REGIONINFO_PATH)
		if not bytes.is_empty():
			_regioninfo = RegioninfoReader.parse(bytes)
			if _regioninfo != null:
				print("AUDIO: %s %d zones" % [REGIONINFO_PATH, _regioninfo.zones.size()])
	return _regioninfo

## Test seam.
func set_region_table(table: RegioninfoReader.ParsedTable) -> void:
	_regioninfo = table
	_regioninfo_loaded = true

# --- players ------------------------------------------------------------------

func _drain_commands() -> void:
	if _bgm_player == null:
		return
	while not music.commands.is_empty():
		var cmd: Array = music.commands.pop_front()
		if cmd[0] == "stop":
			_bgm_player.stop()
			_bgm_player.stream = null
			_report_in = -1.0
		else:
			if not AudioBank.is_cached(cmd[1], true):
				# Not decoded yet: stop the old track (its fade is over) and
				# start this one when its worker decode finishes.
				_bgm_player.stop()
				_bgm_player.stream = null
				_waiting_track = cmd[1]
				if _tasks.is_empty(): # else _poll_tasks queues it if a running task lacks it
					_add_task(AudioBank.prefetch([cmd[1]], []), cmd[1])
				continue
			_waiting_track = ""
			var stream := AudioBank.looping(cmd[1])
			if stream == null:
				print("AUDIO bgm: %s is not in Music.pk2 -- silence (retail's streamer goes idle the same way)" % cmd[1])
				_bgm_player.stop()
				_bgm_player.stream = null
				continue
			_bgm_player.stream = stream
			_bgm_player.volume_db = 0.0
			if is_inside_tree():
				_bgm_player.play()
			_report_in = 1.0

func _start_beds() -> void:
	var options := _options()
	if options != null and options.env_muted:
		return
	for file in ambient.beds:
		var stream := AudioBank.looping(EnvSoundTable.ENV_PREFIX + file)
		if stream == null:
			continue
		var p := AudioStreamPlayer.new()
		p.bus = AudioOptions.BUS_ENV
		p.stream = stream
		p.name = "Bed%d" % _bed_players.size()
		add_child(p)
		if is_inside_tree():
			p.play()
		_bed_players.append(p)

func _play_shot(file: String) -> void:
	var path := AudioBank.normalise(EnvSoundTable.ENV_PREFIX + file)
	var stream := AudioBank.stream(path)
	if stream == null or not is_inside_tree():
		return
	var players: Array = _shot_players.get(path, [])
	var player: AudioStreamPlayer = null
	for p in players:
		if not (p as AudioStreamPlayer).playing:
			player = p
			break
	if player == null:
		player = AudioStreamPlayer.new()
		player.bus = AudioOptions.BUS_ENV
		add_child(player)
		players.append(player)
		_shot_players[path] = players
	player.stream = stream
	player.play()

func _stop_ambient() -> void:
	ambient.stop()
	_beds_waiting = false
	_stop_env_players()

func _stop_env_players() -> void:
	for p in _bed_players:
		(p as AudioStreamPlayer).stop()
		(p as Node).queue_free()
	_bed_players.clear()
	# One-shot players go with their zone (review follow-up: they were kept
	# for ever, one set per file ever played).
	for path in _shot_players:
		for p in _shot_players[path]:
			(p as AudioStreamPlayer).stop()
			(p as Node).queue_free()
	_shot_players.clear()

## A zone's track, beds and one-shots, decoded on a worker (review
## follow-up). Before it, the first zone decoded them on the frame that
## entered it (50 ms measured at Jangan on the box).
func _prefetch_zone(zone: EnvSoundTable.Zone, night: bool) -> void:
	var looped: Array = [zone.bgm]
	var plain: Array = []
	for e in zone.list_for(night):
		var path: String = EnvSoundTable.ENV_PREFIX + e.file
		if e.a == 0:
			looped.append(path)
		else:
			plain.append(path)
	var id := AudioBank.prefetch(looped, plain)
	if id >= 0:
		_beds_waiting = true
		_add_task(id, zone.name)

func _add_task(id: int, label: String) -> void:
	if id >= 0:
		_tasks.append({"id": id, "label": label, "t0": Time.get_ticks_usec()})

## Finishes decodes that are done, then starts what waited for them.
func _poll_tasks() -> void:
	if _tasks.is_empty():
		return
	var done := false
	for t in _tasks.duplicate():
		if WorkerThreadPool.is_task_completed(t["id"]):
			WorkerThreadPool.wait_for_task_completion(t["id"])
			_tasks.erase(t)
			done = true
			print("AUDIO worker: %s ready in %d ms; cache %s" % [
				t["label"], (Time.get_ticks_usec() - int(t["t0"])) / 1000, AudioBank.cache_summary()])
	if not done or not _tasks.is_empty():
		return
	if _waiting_track != "" and not AudioBank.is_cached(_waiting_track, true):
		_add_task(AudioBank.prefetch([_waiting_track], []), _waiting_track)
		return
	if _waiting_track != "" and _waiting_track == music.sounding:
		music.commands.append(["start", _waiting_track])
		_drain_commands()
	_waiting_track = ""
	if _beds_waiting:
		_beds_waiting = false
		_start_beds()

## Blocks until every running decode is done (tests and the timing probe).
func wait_decodes() -> void:
	while not _tasks.is_empty():
		_poll_tasks()
		OS.delay_msec(1)

## The tables, read behind the loading screen (review follow-up): before, the
## first effect key paid for the effect table (140 ms on the box), the first
## sound object for characterInfo and the first zone for effectenvsnd and
## regioninfo.txt, each on a gameplay frame. Each loads once.
func _preload_tables() -> void:
	var parts: Array = []
	var t := Time.get_ticks_usec()
	var svc := get_parent() as AudioService
	if svc != null:
		parts.append_array(svc.preload_tables())
	if not _env_loaded:
		t = Time.get_ticks_usec()
		env_table()
		parts.append("effectenvsnd %d ms" % ((Time.get_ticks_usec() - t) / 1000))
	if not _regioninfo_loaded:
		t = Time.get_ticks_usec()
		_region_table()
		parts.append("regioninfo.txt %d ms" % ((Time.get_ticks_usec() - t) / 1000))
	if not _dirs_warmed:
		# Data.pk2's folder listings (185 ms measured) on a worker: the first
		# sound of a folder then does not read them on a gameplay frame.
		_dirs_warmed = true
		_add_task(WorkerThreadPool.add_task(AudioBank.warm_directories.bind(WARM_DIRS), true, "audio folders"), "Data.pk2 prim\\snd folders")
	if not parts.is_empty():
		print("AUDIO tables read behind the loading screen: %s" % ", ".join(parts))

func _options() -> AudioOptions:
	var svc := get_parent() as AudioService
	return svc.options if svc != null else null

## What is sounding, for QA lines and tests.
func bgm_player() -> AudioStreamPlayer:
	return _bgm_player

func beds_playing() -> int:
	var n := 0
	for p in _bed_players:
		if (p as AudioStreamPlayer).playing:
			n += 1
	return n
