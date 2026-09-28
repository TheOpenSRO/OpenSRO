extends RefCounted
class_name AudioOptions

## The three volume sliders and three mute boxes of the retail Option
## window's audio page, and the buses they drive (round 611). Part of the
## audio CONTRACT (docs/protocol/SOUND_FORMAT.md):
##
##   AudioOptions { bgm, effect, env: int 0..100;
##                  bgm_muted, effect_muted, env_muted: bool } -> bus volumes
##   Buses "BGM", "Effect", "Env", each sending to "Master".
##
## READ from sro_client.exe (audio_spec section 7):
## - There is no master volume; three rows, BGM / Effect / Environment
##   (CIFOption_Audio, layout resinfo\ifoption_audio.txt).
## - Each slider is 0..100, step 1 (CIFHScroll_Option -> FUN_006ed190(0xba,
##   0, 100, 1) at 0x6ed471).
## - A slider value v becomes DirectSound volume 20*v - 2000 hundredths of a
##   dB (FUN_00835380): volume_db = v/5 - 20, so 0 -> -20 dB, 100 -> 0 dB.
## - A checked mute box sends -10000, silence; for BGM that STOPS the track,
##   and un-muting restarts it from the beginning (vslot_018, 0xa6b560).
## - Defaults (constructor at 0x848cb0): BGM 30 (-14 dB), Effect 50 (-10 dB),
##   Env 50 (-10 dB), no mutes.
## OURS: the values live in ClientSettings (user://settings.cfg, section
## [audio]) instead of retail's Setting\SROptionSet.dat, whose layout was not
## read. They are ints and bools, which ConfigFile writes as bare `bgm=30` /
## `bgm_muted=false` -- valid Variant text. A STRING value must be quoted
## there (round 583: an unquoted string breaks the whole file); none of
## these is one.

const BUS_BGM := "BGM"
const BUS_EFFECT := "Effect"
const BUS_ENV := "Env"
const BUS_MASTER := "Master"

const DEFAULT_BGM := 30
const DEFAULT_EFFECT := 50
const DEFAULT_ENV := 50

const SECTION := "audio"
const KEY_BGM := "bgm"
const KEY_EFFECT := "effect"
const KEY_ENV := "env"
const KEY_BGM_MUTED := "bgm_muted"
const KEY_EFFECT_MUTED := "effect_muted"
const KEY_ENV_MUTED := "env_muted"

var bgm: int = DEFAULT_BGM
var effect: int = DEFAULT_EFFECT
var env: int = DEFAULT_ENV
var bgm_muted := false
var effect_muted := false
var env_muted := false

## The DirectSound volume a slider value sends, in hundredths of a dB (READ).
static func slider_mb(v: int) -> int:
	return 20 * clampi(v, 0, 100) - 2000

## The same in dB: v/5 - 20.
static func slider_db(v: int) -> float:
	return float(slider_mb(v)) / 100.0

## The saved options, with the retail defaults for anything not saved.
static func load_saved() -> AudioOptions:
	var file := ConfigFile.new()
	file.load(ClientSettings.PATH) # a missing or unreadable file gives the defaults
	return from_config(file)

static func from_config(file: ConfigFile) -> AudioOptions:
	var o := AudioOptions.new()
	o.bgm = clampi(int(file.get_value(SECTION, KEY_BGM, DEFAULT_BGM)), 0, 100)
	o.effect = clampi(int(file.get_value(SECTION, KEY_EFFECT, DEFAULT_EFFECT)), 0, 100)
	o.env = clampi(int(file.get_value(SECTION, KEY_ENV, DEFAULT_ENV)), 0, 100)
	o.bgm_muted = bool(file.get_value(SECTION, KEY_BGM_MUTED, false))
	o.effect_muted = bool(file.get_value(SECTION, KEY_EFFECT_MUTED, false))
	o.env_muted = bool(file.get_value(SECTION, KEY_ENV_MUTED, false))
	return o

func write_to(file: ConfigFile) -> void:
	file.set_value(SECTION, KEY_BGM, bgm)
	file.set_value(SECTION, KEY_EFFECT, effect)
	file.set_value(SECTION, KEY_ENV, env)
	file.set_value(SECTION, KEY_BGM_MUTED, bgm_muted)
	file.set_value(SECTION, KEY_EFFECT_MUTED, effect_muted)
	file.set_value(SECTION, KEY_ENV_MUTED, env_muted)

## Writes all six values into ClientSettings' file, keeping everything else
## it holds. False when the file could not be written.
func save() -> bool:
	var file := ConfigFile.new()
	file.load(ClientSettings.PATH)
	write_to(file)
	return file.save(ClientSettings.PATH) == OK

func duplicate_options() -> AudioOptions:
	var o := AudioOptions.new()
	o.bgm = bgm
	o.effect = effect
	o.env = env
	o.bgm_muted = bgm_muted
	o.effect_muted = effect_muted
	o.env_muted = env_muted
	return o

## Creates the three buses under Master if they are not there yet.
## Idempotent. OURS: made at runtime rather than in a default_bus_layout.tres,
## so a checkout with no layout file still has them.
static func ensure_buses() -> void:
	for bus_name in [BUS_BGM, BUS_EFFECT, BUS_ENV]:
		if AudioServer.get_bus_index(bus_name) >= 0:
			continue
		var idx := AudioServer.bus_count
		AudioServer.add_bus(idx)
		AudioServer.set_bus_name(idx, bus_name)
		AudioServer.set_bus_send(idx, BUS_MASTER)

## Sets each bus's volume to its slider's dB and mutes a muted row's bus.
func apply_to_buses() -> void:
	ensure_buses()
	_apply(BUS_BGM, bgm, bgm_muted)
	_apply(BUS_EFFECT, effect, effect_muted)
	_apply(BUS_ENV, env, env_muted)

static func _apply(bus_name: String, v: int, muted: bool) -> void:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx < 0:
		return
	AudioServer.set_bus_volume_db(idx, slider_db(v))
	AudioServer.set_bus_mute(idx, muted)

func describe() -> String:
	return "BGM %d%s, Effect %d%s, Env %d%s" % [
		bgm, " (muted)" if bgm_muted else "",
		effect, " (muted)" if effect_muted else "",
		env, " (muted)" if env_muted else ""]
