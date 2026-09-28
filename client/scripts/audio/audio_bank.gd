extends RefCounted
class_name AudioBank

## Loads the retail client's sounds out of the player's own archives, once
## each (round 611). Part of the audio CONTRACT that rounds 2-5 code against;
## the whole contract is written out in docs/protocol/SOUND_FORMAT.md:
##
##   AudioBank.stream(path: String) -> AudioStream
##       "prim\snd\ui\uiwinopen.wav"  -> Data.pk2, an AudioStreamWAV
##       "jangan_town.ogg"            -> Music.pk2's root, an AudioStreamOggVorbis
##     Cached per path (a miss is cached too). Returns null, silently for the
##     player and with ONE log line per missing archive or file, when the
##     archive or the file is not there. Case and slash direction do not
##     matter: pk2 lookups are case-blind (ObjectLoader.find_file) and the
##     retail tables mix `Jangan_Town.ogg` with `jangan_town.ogg`.
##   AudioBank.looping(path) -> AudioStream
##     The same sound set to loop, as its own resource (so a file used both
##     as a looping ambient bed and as a one-shot stays a one-shot there).
##
## What the formats are, and why the conversions (all MEASURED on the box's
## archives, audio_spec 1.2/1.3): every one of Data.pk2's 2,961 `Prim\Snd`
## files is RIFF PCM, format tag 1 -- 16-bit mono/stereo at 22,050, 24,000
## or 44,100 Hz, three 8-bit files and four 24-bit files. Music.pk2 holds 45
## Ogg Vorbis files at its root.
## - 8-bit: WAV 8-bit PCM is UNSIGNED (the RIFF spec, READ); Godot's
##   AudioStreamWAV FORMAT_8_BITS is signed (its mixer reads the byte as
##   int8 -- INFERRED from the engine source, not listened to), so every byte
##   is XORed with 0x80.
## - 24-bit: Godot has no 24-bit format, so each little-endian 3-byte sample
##   keeps its top two bytes and becomes 16-bit.
## - The `data` chunk is found by walking the RIFF chunks (word-aligned, odd
##   sizes padded), never assumed to start at byte 44.
## - Ogg: `AudioStreamOggVorbis.load_from_buffer` (static; present in the
##   4.2.2 export templates, MEASURED on the box).

const MUSIC_EXTENSION := ".ogg"

## Normalised path -> AudioStream, or null for a sound already found missing.
static var _cache: Dictionary = {}
## "data" / "music" / "media" -> Pk2Reader, or null once opening failed.
static var _archives: Dictionary = {}

## Normalised cache key -> decoded bytes held, for the size line (round 612
## review follow-up; the cache is never evicted, so its size is logged).
static var _sizes: Dictionary = {}
## One lock for the cache and the archive handles: prefetch() decodes on a
## WorkerThreadPool task while the main thread may read the cache. (Each
## Pk2Reader has its own lock for its file position, round 565.)
static var _lock := Mutex.new()

## THE CONTRACT. See the file's top comment.
static func stream(path: String) -> AudioStream:
	var key := normalise(path)
	if key == "":
		return null
	_lock.lock()
	var hit := _cache.has(key)
	var cached: AudioStream = _cache.get(key)
	_lock.unlock()
	if hit:
		return cached
	var result := _decode(key, false)
	_store(key, result)
	return result

## The sound at `path`, set to loop from its start to its end. Decoded as a
## looping stream of its own and cached ONCE: until the review follow-up it
## duplicated the one-shot stream, and an AudioStreamWAV keeps its own copy
## of the samples, so a bed was held twice (hellfire.wav 5.3 MB x 2). Only
## when the same file is already cached as a one-shot does it copy.
static func looping(path: String) -> AudioStream:
	var plain := normalise(path)
	var key := "loop:" + plain
	_lock.lock()
	var hit := _cache.has(key)
	var cached: AudioStream = _cache.get(key)
	var base: AudioStream = _cache.get(plain)
	_lock.unlock()
	if hit:
		return cached
	var result: AudioStream = null
	if base is AudioStreamWAV:
		result = (base as AudioStreamWAV).duplicate() as AudioStreamWAV
	elif base is AudioStreamOggVorbis:
		result = (base as AudioStreamOggVorbis).duplicate() as AudioStreamOggVorbis
	else:
		result = _decode(plain, true)
	_set_loop(result)
	_store(key, result)
	return result

## Whether stream(path) / looping(path) would answer without decoding.
## A looping request counts as cached when the one-shot is: looping() then
## only copies it, it does not decode.
static func is_cached(path: String, loop: bool = false) -> bool:
	var plain := normalise(path)
	_lock.lock()
	var hit := _cache.has("loop:" + plain) or _cache.has(plain) if loop else _cache.has(plain)
	_lock.unlock()
	return hit

## Decodes these sounds on a WorkerThreadPool task, so no large file decodes
## on a gameplay frame. Returns the task id (-1 when nothing needed it);
## poll WorkerThreadPool.is_task_completed and then wait_for_task_completion.
static func prefetch(looped: Array, plain: Array) -> int:
	var todo_loop := looped.filter(func(p): return not is_cached(p, true))
	var todo_plain := plain.filter(func(p): return not is_cached(p, false))
	if todo_loop.is_empty() and todo_plain.is_empty():
		return -1
	return WorkerThreadPool.add_task(_prefetch_task.bind(todo_loop, todo_plain), true, "audio prefetch")

static func _prefetch_task(todo_loop: Array, todo_plain: Array) -> void:
	for p in todo_loop:
		looping(p)
	for p in todo_plain:
		stream(p)

## Opens Data.pk2 and walks its directory down to prim\snd\<dir> for each
## given dir, so the first sound of a kind does not pay for the archive's
## directory reads on a gameplay frame (review follow-up). Behind a loading
## screen only.
static func warm_directories(dirs: Array) -> void:
	var archive := _archive("data")
	if archive == null:
		return
	for d in dirs:
		# A name no folder holds: the walk reads the folder's own listing
		# (1,700+ entries in player\, 60 ms measured) and finds nothing.
		ObjectLoader.find_file(archive, "prim\\snd\\" + str(d) + "\\ ")

## "<n> sounds, <x> MB" held by the cache.
static func cache_summary() -> String:
	_lock.lock()
	var total := 0
	for k in _sizes:
		total += int(_sizes[k])
	var n := _cache.size()
	_lock.unlock()
	return "%d sounds, %.1f MB" % [n, total / 1048576.0]

## Test seam: raw file bytes served in place of the archives, per path.
static var _test_bytes: Dictionary = {}

static func inject_bytes_for_test(path: String, bytes: PackedByteArray) -> void:
	_lock.lock()
	_test_bytes[normalise(path)] = bytes
	_lock.unlock()

static func _decode(key: String, _loop: bool) -> AudioStream:
	_lock.lock()
	var test_bytes: PackedByteArray = _test_bytes.get(key, PackedByteArray())
	_lock.unlock()
	if not test_bytes.is_empty():
		return wav_from_bytes(test_bytes, key)
	var which := "music" if is_music_path(key) else "data"
	var archive := _archive(which)
	if archive == null:
		return null
	var entry := ObjectLoader.find_file(archive, key)
	if entry == null or entry.is_dir:
		print("AUDIO: no %s in %s -- that sound is silent" % [key, _archive_label(which)])
		return null
	var bytes := archive.read_file(entry)
	var result: AudioStream = null
	if which == "music":
		result = AudioStreamOggVorbis.load_from_buffer(bytes)
	else:
		result = wav_from_bytes(bytes, key)
	if result == null:
		print("AUDIO: %s did not decode (%d bytes) -- that sound is silent" % [key, bytes.size()])
	return result

static func _set_loop(s: AudioStream) -> void:
	if s is AudioStreamWAV:
		var wav := s as AudioStreamWAV
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		wav.loop_end = wav_frames(wav)
	elif s is AudioStreamOggVorbis:
		(s as AudioStreamOggVorbis).loop = true

static func _store(key: String, s: AudioStream) -> void:
	var size := 0
	if s is AudioStreamWAV:
		size = (s as AudioStreamWAV).data.size()
	elif s is AudioStreamOggVorbis and (s as AudioStreamOggVorbis).packet_sequence != null:
		for page in (s as AudioStreamOggVorbis).packet_sequence.packet_data:
			for packet in page:
				size += (packet as PackedByteArray).size()
	_lock.lock()
	_cache[key] = s
	_sizes[key] = size
	_lock.unlock()

## A table file's bytes from Media.pk2 or Data.pk2 (the sound tables,
## regioninfo.txt, option.txt), or empty with one log line.
static func read_table(archive_name: String, path: String) -> PackedByteArray:
	var archive := _archive(archive_name)
	if archive == null:
		return PackedByteArray()
	var entry := ObjectLoader.find_file(archive, path)
	if entry == null or entry.is_dir:
		print("AUDIO: no %s in %s" % [path, _archive_label(archive_name)])
		return PackedByteArray()
	return archive.read_file(entry)

## Lowercase, backslashes, no leading separator: the one spelling the cache
## is keyed by.
static func normalise(path: String) -> String:
	var p := path.strip_edges().replace("/", "\\").to_lower()
	while p.begins_with("\\"):
		p = p.substr(1)
	return p

## A bare `*.ogg` name is a Music.pk2 root file; everything else is a
## Data.pk2 path.
static func is_music_path(normalised: String) -> bool:
	return normalised.ends_with(MUSIC_EXTENSION) and not normalised.contains("\\")

## Builds an AudioStreamWAV from a RIFF file's bytes, or null (and one log
## line naming `label`) when the file is not PCM this can play.
static func wav_from_bytes(bytes: PackedByteArray, label: String = "") -> AudioStreamWAV:
	if bytes.size() < 12 or bytes.slice(0, 4).get_string_from_ascii() != "RIFF" \
			or bytes.slice(8, 12).get_string_from_ascii() != "WAVE":
		print("AUDIO: %s is not a RIFF WAVE file" % label)
		return null
	var fmt_tag := -1
	var channels := 0
	var rate := 0
	var bits := 0
	var data_off := -1
	var data_len := 0
	var off := 12
	while off + 8 <= bytes.size():
		var id := bytes.slice(off, off + 4).get_string_from_ascii()
		var size := bytes.decode_u32(off + 4)
		var body := off + 8
		if id == "fmt " and body + 16 <= bytes.size():
			fmt_tag = bytes.decode_u16(body)
			channels = bytes.decode_u16(body + 2)
			rate = bytes.decode_u32(body + 4)
			bits = bytes.decode_u16(body + 14)
		elif id == "data":
			data_off = body
			# A data chunk that claims more than the file holds keeps what is there.
			data_len = mini(size, bytes.size() - body)
			break
		off = body + size + (size & 1)
	if fmt_tag != 1 or data_off < 0 or rate <= 0 or channels < 1 or channels > 2:
		print("AUDIO: %s is not 1- or 2-channel PCM (format %d, %d channels, data at %d)" % [label, fmt_tag, channels, data_off])
		return null
	var pcm := bytes.slice(data_off, data_off + data_len)
	var wav := AudioStreamWAV.new()
	wav.mix_rate = rate
	wav.stereo = channels == 2
	match bits:
		8:
			wav.format = AudioStreamWAV.FORMAT_8_BITS
			pcm = unsigned8_to_signed(pcm)
		16:
			wav.format = AudioStreamWAV.FORMAT_16_BITS
			pcm = pcm.slice(0, pcm.size() - pcm.size() % 2)
		24:
			wav.format = AudioStreamWAV.FORMAT_16_BITS
			pcm = pcm24_to_pcm16(pcm)
		_:
			print("AUDIO: %s has %d-bit samples, which this client does not play" % [label, bits])
			return null
	wav.data = pcm
	return wav

## WAV's unsigned 8-bit samples as Godot's signed ones: each byte XOR 0x80.
static func unsigned8_to_signed(pcm: PackedByteArray) -> PackedByteArray:
	var out := pcm.duplicate()
	for i in range(out.size()):
		out[i] = out[i] ^ 0x80
	return out

## Little-endian 24-bit samples to 16-bit: the top two bytes of each three.
## A trailing partial sample is dropped.
static func pcm24_to_pcm16(pcm: PackedByteArray) -> PackedByteArray:
	var samples := pcm.size() / 3
	var out := PackedByteArray()
	out.resize(samples * 2)
	for i in range(samples):
		out[i * 2] = pcm[i * 3 + 1]
		out[i * 2 + 1] = pcm[i * 3 + 2]
	return out

## Sample frames in a WAV stream (per channel).
static func wav_frames(wav: AudioStreamWAV) -> int:
	var bytes_per_sample := 1 if wav.format == AudioStreamWAV.FORMAT_8_BITS else 2
	var channels := 2 if wav.stereo else 1
	return wav.data.size() / (bytes_per_sample * channels)

## Test seam: puts a ready stream in the cache under `path`, so a headless
## test can drive the players without any game data.
static func inject_for_test(path: String, audio: AudioStream) -> void:
	_store(normalise(path), audio)

## Forgets every cached sound and archive handle (tests; a new pk2 folder).
static func clear() -> void:
	_lock.lock()
	_cache.clear()
	_sizes.clear()
	_test_bytes.clear()
	_lock.unlock()
	for archive in _archives.values():
		if archive != null:
			(archive as Pk2Reader).close()
	_archives.clear()

static func _archive(which: String) -> Pk2Reader:
	_lock.lock()
	var result := _archive_locked(which)
	_lock.unlock()
	return result

static func _archive_locked(which: String) -> Pk2Reader:
	if _archives.has(which):
		return _archives[which]
	var path := ""
	match which:
		"data": path = Pk2Config.data_path()
		"music": path = Pk2Config.music_path()
		"media": path = Pk2Config.media_path()
	var archive: Pk2Reader = null
	if path == "":
		print("AUDIO: %s not found (%s or the pk2 folder) -- its sounds are silent" % [_archive_label(which), _archive_env(which)])
	else:
		archive = Pk2Reader.open(path)
		if archive == null:
			print("AUDIO: %s at %s did not open -- its sounds are silent" % [_archive_label(which), path])
	_archives[which] = archive
	return archive

static func _archive_label(which: String) -> String:
	match which:
		"data": return Pk2Config.DATA_FILENAME
		"music": return Pk2Config.MUSIC_FILENAME
		"media": return Pk2Config.MEDIA_FILENAME
	return which

static func _archive_env(which: String) -> String:
	match which:
		"data": return "SRREVAMP_PK2_PATH"
		"music": return "SRREVAMP_MUSIC_PK2_PATH"
		"media": return "SRREVAMP_MEDIA_PK2_PATH"
	return "?"
