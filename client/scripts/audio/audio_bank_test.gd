extends SceneTree

## AudioBank's WAV decoding against synthetic RIFF buffers built here (never
## game data), run headless:
## `godot4 --headless --path client --script res://scripts/audio/audio_bank_test.gd`
##
## The script is loaded by path, not by class name, so on a checkout without
## it this suite prints FAIL lines instead of stopping at a parse error.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _u16(v: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(2)
	b.encode_u16(0, v)
	return b

func _u32(v: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_u32(0, v)
	return b

func _chunk(id: String, body: PackedByteArray) -> PackedByteArray:
	var out := id.to_ascii_buffer()
	out.append_array(_u32(body.size()))
	out.append_array(body)
	if body.size() % 2 == 1:
		out.append(0) # RIFF pads odd chunks to a word
	return out

## A RIFF WAVE file: fmt, then any `extra` chunks, then data.
func _wav(fmt_tag: int, channels: int, rate: int, bits: int, data: PackedByteArray, extra: Array = []) -> PackedByteArray:
	var fmt := PackedByteArray()
	fmt.append_array(_u16(fmt_tag))
	fmt.append_array(_u16(channels))
	fmt.append_array(_u32(rate))
	fmt.append_array(_u32(rate * channels * bits / 8))
	fmt.append_array(_u16(channels * bits / 8))
	fmt.append_array(_u16(bits))
	var body := "WAVE".to_ascii_buffer()
	body.append_array(_chunk("fmt ", fmt))
	for e in extra:
		body.append_array(e)
	body.append_array(_chunk("data", data))
	var out := "RIFF".to_ascii_buffer()
	out.append_array(_u32(body.size()))
	out.append_array(body)
	return out

func _initialize() -> void:
	var bank: GDScript = load("res://scripts/audio/audio_bank.gd")
	_check(bank != null, "scripts/audio/audio_bank.gd exists (AudioBank, the contract's stream(path))")
	if bank == null:
		_finish()
		return

	# 16-bit mono passes through untouched.
	var pcm16 := PackedByteArray([0x01, 0x02, 0x03, 0x04, 0xFF, 0x7F])
	var w16: AudioStreamWAV = bank.wav_from_bytes(_wav(1, 1, 22050, 16, pcm16), "t16")
	_check(w16 != null and w16.format == AudioStreamWAV.FORMAT_16_BITS, "16-bit PCM becomes FORMAT_16_BITS")
	_check(w16 != null and w16.data == pcm16, "16-bit samples are copied as they are")
	_check(w16 != null and w16.mix_rate == 22050 and not w16.stereo, "rate and mono come from the fmt chunk")

	# 8-bit: unsigned WAV -> signed Godot, XOR 0x80.
	var pcm8 := PackedByteArray([0x00, 0x80, 0xFF, 0x7F, 0x81])
	var w8: AudioStreamWAV = bank.wav_from_bytes(_wav(1, 1, 11025, 8, pcm8), "t8")
	_check(w8 != null and w8.format == AudioStreamWAV.FORMAT_8_BITS, "8-bit PCM becomes FORMAT_8_BITS")
	_check(w8 != null and w8.data == PackedByteArray([0x80, 0x00, 0x7F, 0xFF, 0x01]),
		"8-bit samples are flipped from unsigned to signed (XOR 0x80): silence 0x80 -> 0x00, got %s" % (w8.data.hex_encode() if w8 != null else "null"))

	# 24-bit: keep the top two bytes of each little-endian three.
	var pcm24 := PackedByteArray([0x11, 0x22, 0x33, 0xAA, 0xBB, 0xCC, 0x01, 0x00, 0x80])
	var w24: AudioStreamWAV = bank.wav_from_bytes(_wav(1, 1, 44100, 24, pcm24), "t24")
	_check(w24 != null and w24.format == AudioStreamWAV.FORMAT_16_BITS, "24-bit PCM becomes FORMAT_16_BITS")
	_check(w24 != null and w24.data == PackedByteArray([0x22, 0x33, 0xBB, 0xCC, 0x00, 0x80]),
		"24-bit samples keep their top two bytes, got %s" % (w24.data.hex_encode() if w24 != null else "null"))
	_check(bank.pcm24_to_pcm16(PackedByteArray([1, 2, 3, 4])) == PackedByteArray([2, 3]), "a trailing partial 24-bit sample is dropped")

	# Stereo, and a data chunk that is NOT at byte 44 (a LIST chunk with an
	# odd size sits in front of it).
	var pcm_st := PackedByteArray([1, 0, 2, 0, 3, 0, 4, 0])
	var list := _chunk("LIST", PackedByteArray([0x49, 0x4E, 0x46, 0x4F, 0x41]))
	var wst: AudioStreamWAV = bank.wav_from_bytes(_wav(1, 2, 44100, 16, pcm_st, [list]), "tst")
	_check(wst != null and wst.stereo, "two channels become a stereo stream")
	_check(wst != null and wst.data == pcm_st, "the data chunk is found by walking the chunks, past a padded odd-sized one")
	_check(wst != null and bank.wav_frames(wst) == 2, "8 bytes of 16-bit stereo are 2 frames")

	# What it refuses, without crashing.
	_check(bank.wav_from_bytes(_wav(2, 1, 22050, 4, PackedByteArray([1, 2])), "adpcm") == null, "non-PCM (ADPCM, tag 2) is refused")
	_check(bank.wav_from_bytes(PackedByteArray([0x52, 0x49, 0x46, 0x46]), "short") == null, "a truncated header is refused")
	_check(bank.wav_from_bytes("OggS....WAVE".to_ascii_buffer(), "notriff") == null, "a non-RIFF file is refused")
	var truncated := _wav(1, 1, 22050, 16, PackedByteArray([1, 2, 3, 4, 5, 6]))
	truncated = truncated.slice(0, truncated.size() - 2)
	var wt: AudioStreamWAV = bank.wav_from_bytes(truncated, "truncdata")
	_check(wt != null and wt.data.size() == 4, "a data chunk claiming more than the file holds keeps what is there")

	# Paths: case and slashes do not matter; a bare .ogg is Music.pk2's.
	_check(bank.normalise("Prim/Snd/UI/UIWinOpen.wav") == "prim\\snd\\ui\\uiwinopen.wav", "paths normalise to lowercase backslashes")
	_check(bank.is_music_path(bank.normalise("Jangan_Town.ogg")), "a bare .ogg name is a Music.pk2 file")
	_check(not bank.is_music_path(bank.normalise("prim\\snd\\env\\day_wind.wav")), "a prim\\snd path is a Data.pk2 file")

	# The cache and the looping copy.
	var base: AudioStreamWAV = bank.wav_from_bytes(_wav(1, 1, 22050, 16, PackedByteArray([0, 0, 0, 0, 0, 0])), "loop")
	bank.inject_for_test("prim\\snd\\test\\loop.wav", base)
	_check(bank.stream("PRIM/SND/TEST/LOOP.WAV") == base, "stream() serves the cached sound whatever the spelling")
	var looped = bank.looping("prim\\snd\\test\\loop.wav")
	_check(looped is AudioStreamWAV and looped != base and looped.loop_mode == AudioStreamWAV.LOOP_FORWARD and looped.loop_end == 3,
		"looping() is a separate looping copy spanning all 3 frames")
	_check(base.loop_mode == AudioStreamWAV.LOOP_DISABLED, "the one-shot original is left not looping")
	bank.clear()
	_finish()

func _finish() -> void:
	if _failures == 0:
		print("ALL PASS")
	else:
		print("FAILURES: %d" % _failures)
	quit(1 if _failures > 0 else 0)
