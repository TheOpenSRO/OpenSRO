extends SceneTree

## Measures the audio code against the REAL archives (round 611): how many
## effectsound rows and keys parse, how many characterInfo objects, and
## whether the named sounds decode, with their format and length. Prints
## counts and formats only; nothing is extracted or kept.
##
##   SRREVAMP_PK2_PATH=... SRREVAMP_MEDIA_PK2_PATH=... SRREVAMP_MUSIC_PK2_PATH=... \
##   godot4 --headless --path client --script res://tools/probe_audio.gd -- \
##     [--sounds "prim\snd\ui\uiwinopen.wav,jangan_town.ogg"] [--keys "UI:snd_window_open:-:-:-:-"]
##
## With no --sounds it decodes the formats audio_spec 1.2 lists one of each
## of (16-bit mono and stereo, both 8-bit rates, 24-bit) and two music files.

const DEFAULT_SOUNDS := [
	"prim\\snd\\ui\\uiwinopen.wav",
	"prim\\snd\\ui\\questopen.wav",
	"prim\\snd\\env\\day_bird01.wav",
	"prim\\snd\\event\\winter_princess\\winter_princess_kiss.wav",
	"prim\\snd\\env\\hellfire.wav",
	"prim\\snd\\event\\winter_snow\\winter_snow_die.wav",
	"prim\\snd\\event\\winter_snow\\winter_snow_step.wav",
	"jangan_town.ogg",
	"Maintheme_Cut.ogg",
]
const DEFAULT_KEYS := [
	"UI:snd_window_open:-:-:-:-",
	"UI:snd_button_click:-:-:-:-",
	"PLAYER:snd_walk1:-:FIELD:DIRT:-",
]

func _initialize() -> void:
	var args := _args()
	var t0 := Time.get_ticks_msec()
	var bytes := AudioBank.read_table("media", SoundTable.EFFECTSOUND_PATH)
	var table := SoundTable.parse(bytes)
	var rows := 0
	for k in table:
		rows += (table[k] as Array).size()
	print("PROBE effectsound: %d bytes -> %d rows under %d keys in %d ms" % [bytes.size(), rows, table.size(), Time.get_ticks_msec() - t0])
	var keys: Array = DEFAULT_KEYS if not args.has("keys") else Array(str(args["keys"]).split(","))
	for key in keys:
		var list: Array = table.get(key, [])
		var files := []
		for r in list:
			files.append("%s @%.2f blank %d" % [r.path, r.volume, r.blank])
		print("PROBE key %s: %d row(s) %s" % [key, list.size(), str(files)])
	t0 = Time.get_ticks_msec()
	var ci_bytes := AudioBank.read_table("media", SoundTable.SKILLEFFECT_PATH)
	var info := SoundTable.parse_character_info(ci_bytes)
	print("PROBE characterInfo: %d bytes (BOM %s) -> %d codes in %d ms; MOB_CH_MANGNYANG -> %s" % [
		ci_bytes.size(), ci_bytes.slice(0, 2).hex_encode(), info.size(), Time.get_ticks_msec() - t0, info.get("MOB_CH_MANGNYANG", "?")])
	var sounds: Array = DEFAULT_SOUNDS if not args.has("sounds") else Array(str(args["sounds"]).split(","))
	for path in sounds:
		t0 = Time.get_ticks_msec()
		var s := AudioBank.stream(path)
		if s == null:
			print("PROBE sound %s: null" % path)
		elif s is AudioStreamWAV:
			var w := s as AudioStreamWAV
			print("PROBE sound %s: file %d-bit -> WAV format %d stereo %s rate %d, %.3f s, %d ms" % [
				path, _file_bits(path), w.format, str(w.stereo), w.mix_rate, w.get_length(), Time.get_ticks_msec() - t0])
		else:
			print("PROBE sound %s: %s %.2f s, %d ms" % [path, s.get_class(), s.get_length(), Time.get_ticks_msec() - t0])
	quit(0)

## The bits-per-sample the file's own fmt chunk states.
func _file_bits(path: String) -> int:
	var raw := AudioBank.read_table("data", path)
	var off := 12
	while off + 8 <= raw.size():
		var size := raw.decode_u32(off + 4)
		if raw.slice(off, off + 4).get_string_from_ascii() == "fmt ":
			return raw.decode_u16(off + 8 + 14)
		off += 8 + size + (size & 1)
	return -1

func _args() -> Dictionary:
	var out := {}
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--") and a.contains("="):
			var kv := a.substr(2).split("=", true, 1)
			out[kv[0]] = kv[1]
	return out
