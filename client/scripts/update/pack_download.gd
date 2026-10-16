extends RefCounted
class_name PackDownload

## One server pack fetched to disk (round 789, lane U; OURS,
## docs/protocol/asset_packs.md "Server packs"). A state machine the caller
## polls once a frame (poll() returns true when it is over), on Godot's
## HTTPClient, so nothing blocks a frame:
##
## 1. A `.partial` left by an earlier try is hashed first (in slices) and the
##    download resumes after it with `Range: bytes=<n>-`; a server that
##    answers 200 instead of 206 is read from the start again (the partial is
##    truncated). A partial longer than the pack is thrown away.
## 2. The body goes to the partial, hashed as it is written. More bytes than
##    the manifest's size stop the download and remove the partial (the size
##    is the cap). A 206 must start where the partial ends and name the
##    manifest's total.
## 3. Complete at the manifest's size: the SHA-256 must be the manifest's,
##    else the partial is removed (and, when the download was a resume, one
##    more try is made from nothing). Then it is renamed onto the pack's name
##    -- the pack appears whole or not at all.
##
## Sources are tried in order (the pack's URL, then the server's own
## listener); a connection that drops mid-body is resumed on the same source
## up to RETRIES times before the next. Redirects are followed (at most
## MAX_REDIRECTS; GitHub's release downloads redirect), each one held to the
## same rule as the manifest's URLs (PackManifest.url_allowed). Nothing is
## ever executed; the only files written are the partial and the pack, in the
## server's own folder (PackStore).

enum { S_IDLE, S_PREHASH, S_CONNECT, S_REQUEST, S_BODY, S_FINISH, S_DONE, S_FAILED }

## OURS: a source that sends nothing for this long is given up on.
const STALL_MS := 30000
const MAX_REDIRECTS := 5
## A redirect's target may be a long signed URL (GitHub's are ~700 bytes).
const MAX_REDIRECT_URL := 4096
## Resumes of a dropped connection, per source.
const RETRIES := 3
## Bytes read per poll at most (OURS: ~8 MiB a frame keeps a frame short and
## still passes 400 MB/s at 60 frames a second).
const READ_BUDGET := 8 << 20

var pack: PackManifest.Pack = null
var sources := PackedStringArray()
var gateway_host := ""
var final_path := ""
var partial_path := ""

var state := S_IDLE
var received := 0
## Where this attempt's bytes started (0 when not a resume).
var resumed_from := 0
var error := ""
## The source being read, for the log and the message line.
var source := ""
var log_lines := PackedStringArray()

var _http: HTTPClient = null
var _file: FileAccess = null
var _ctx: HashingContext = null
var _hasher: PackStore.FileHasher = null
var _src_i := 0
var _url := ""
var _redirects := 0
var _retries := 0
var _fresh_retry_done := false
## Whether any bytes of the file came from an earlier attempt (a partial, a
## resumed range): a wrong hash then earns one try from nothing.
var _any_resume := false
var _last_ms := 0
var _now := func() -> int: return Time.get_ticks_msec()

func _init(p_pack: PackManifest.Pack, p_sources: PackedStringArray, p_gateway_host: String, p_final: String, p_partial: String) -> void:
	pack = p_pack
	sources = p_sources
	gateway_host = p_gateway_host
	final_path = p_final
	partial_path = p_partial

func _say(line: String) -> void:
	log_lines.append(line)
	print("PACKS: " + line)

func start() -> void:
	if sources.is_empty():
		_fail("no source to fetch %s from" % pack.name)
		return
	DirAccess.make_dir_recursive_absolute(final_path.get_base_dir())
	var have := PackStore._size(partial_path)
	if have > pack.size:
		_say("%s: a partial of %d bytes is longer than the pack -- removed" % [pack.name, have])
		DirAccess.remove_absolute(partial_path)
		have = -1
	if have > 0:
		_any_resume = true
		_hasher = PackStore.FileHasher.new(partial_path, have, true)
		state = S_PREHASH
		_say("%s: resuming after %d of %d bytes" % [pack.name, have, pack.size])
	else:
		_begin_fresh()
		_next_source(false)

func _begin_fresh() -> void:
	_close_file()
	DirAccess.remove_absolute(partial_path)
	received = 0
	_ctx = HashingContext.new()
	_ctx.start(HashingContext.HASH_SHA256)

func is_over() -> bool:
	return state == S_DONE or state == S_FAILED

## One step; true when the download is over (DONE or FAILED, `error` says why).
func poll() -> bool:
	match state:
		S_PREHASH:
			if _hasher.poll():
				if _hasher.error != "":
					_say("%s: the partial cannot be read (%s) -- starting over" % [pack.name, _hasher.error])
					_begin_fresh()
				else:
					_ctx = _hasher.context()
					received = _hasher.size
				_hasher = null
				if received == pack.size:
					state = S_FINISH
				else:
					_next_source(false)
		S_CONNECT, S_REQUEST, S_BODY:
			_poll_http()
		S_FINISH:
			_finish()
	return is_over()

## Moves to the next source (or the same one again when `same`).
func _next_source(same: bool) -> void:
	if not same:
		if _url != "":
			_src_i += 1
		_retries = 0
		_redirects = 0
		if _src_i >= sources.size():
			_fail(error if error != "" else "no source could be read")
			return
		_url = sources[_src_i]
	_connect(_url)

func _connect(url: String) -> void:
	_close_http()
	var why := PackManifest.url_allowed(url, gateway_host, MAX_REDIRECT_URL)
	if why != "":
		_source_failed("%s: %s" % [url, why])
		return
	var u := PackManifest.parse_url(url)
	source = "%s:%d" % [u["host"], u["port"]]
	_http = HTTPClient.new()
	var tls: TLSOptions = TLSOptions.client() if u["scheme"] == "https" else null
	var err := _http.connect_to_host(str(u["host"]), int(u["port"]), tls)
	if err != OK:
		_source_failed("%s: connect_to_host failed (%d)" % [url, err])
		return
	_url = url
	_last_ms = _now.call()
	state = S_CONNECT

func _poll_http() -> void:
	if _http == null:
		return
	_http.poll()
	var st := _http.get_status()
	if _now.call() - _last_ms > STALL_MS:
		_drop("nothing for %d s" % (STALL_MS / 1000))
		return
	match state:
		S_CONNECT:
			match st:
				HTTPClient.STATUS_RESOLVING, HTTPClient.STATUS_CONNECTING:
					return
				HTTPClient.STATUS_CONNECTED:
					_send_request()
				_:
					_source_failed("%s: cannot connect (%s)" % [source, _status_name(st)])
		S_REQUEST:
			if st == HTTPClient.STATUS_REQUESTING:
				return
			if not _http.has_response():
				_drop("the connection closed before an answer (%s)" % _status_name(st))
				return
			_on_response()
		S_BODY:
			_read_body(st)

func _send_request() -> void:
	var u := PackManifest.parse_url(_url)
	var headers := PackedStringArray(["User-Agent: opensro-client", "Accept-Encoding: identity", "Accept: */*"])
	resumed_from = received
	if received > 0:
		_any_resume = true
		headers.append("Range: bytes=%d-" % received)
		headers.append("If-Range: \"%s\"" % pack.sha256)
	var err := _http.request(HTTPClient.METHOD_GET, str(u["path"]), headers)
	if err != OK:
		_source_failed("%s: request failed (%d)" % [source, err])
		return
	_last_ms = _now.call()
	state = S_REQUEST

func _on_response() -> void:
	var code := _http.get_response_code()
	var headers := _headers()
	if code in [301, 302, 303, 307, 308]:
		var loc := str(headers.get("location", ""))
		_redirects += 1
		if loc == "" or _redirects > MAX_REDIRECTS:
			_source_failed("%s: HTTP %d %s" % [source, code, "with no Location" if loc == "" else "-- too many redirects"])
			return
		var target := resolve_location(_url, loc)
		_say("%s: HTTP %d -> %s" % [pack.name, code, target.left(120)])
		_connect(target)
		return
	if code == 200:
		if received > 0:
			_say("%s: the source sent the whole file (no resume) -- reading it from the start" % pack.name)
			_begin_fresh()
		var cl := _http.get_response_body_length()
		if cl >= 0 and cl != pack.size:
			_source_failed("%s: the file there is %d bytes, the server named %d" % [source, cl, pack.size])
			return
	elif code == 206:
		var cr := parse_content_range(str(headers.get("content-range", "")))
		if cr.is_empty() or int(cr["start"]) != received or (int(cr["total"]) >= 0 and int(cr["total"]) != pack.size):
			_say("%s: a range answer that does not continue the partial (%s) -- starting over" % [pack.name, headers.get("content-range", "")])
			_begin_fresh()
			_close_http()
			_connect(_url)
			return
	elif code == 416 and received > 0:
		_say("%s: the source cannot continue after %d bytes -- starting over" % [pack.name, received])
		_begin_fresh()
		_close_http()
		_connect(_url)
		return
	else:
		_source_failed("%s: HTTP %d" % [source, code])
		return
	if not _open_file():
		return
	state = S_BODY
	_last_ms = _now.call()

func _open_file() -> bool:
	if _file == null:
		if FileAccess.file_exists(partial_path):
			_file = FileAccess.open(partial_path, FileAccess.READ_WRITE)
		else:
			_file = FileAccess.open(partial_path, FileAccess.WRITE)
		if _file == null:
			_fail("cannot write %s (%s)" % [partial_path, error_string(FileAccess.get_open_error())])
			return false
	_file.seek(received)
	return true

func _read_body(st: int) -> void:
	var budget := READ_BUDGET
	while st == HTTPClient.STATUS_BODY and budget > 0:
		var chunk := _http.read_response_body_chunk()
		if chunk.is_empty():
			break
		if received + chunk.size() > pack.size:
			_close_file()
			DirAccess.remove_absolute(partial_path)
			received = 0
			_fail("%s sent more than the %d bytes the server named for %s -- stopped" % [source, pack.size, pack.name])
			return
		_file.store_buffer(chunk)
		_ctx.update(chunk)
		received += chunk.size()
		budget -= chunk.size()
		_last_ms = _now.call()
		_http.poll()
		st = _http.get_status()
	if st == HTTPClient.STATUS_BODY:
		return
	# The body ended (or the connection dropped).
	_file.flush()
	if received == pack.size:
		_close_http()
		state = S_FINISH
		return
	_drop("the connection ended after %d of %d bytes" % [received, pack.size])

## A connection lost mid-way: resume on the same source, a few times.
func _drop(why: String) -> void:
	_close_http()
	_retries += 1
	if _retries <= RETRIES:
		_say("%s: %s: %s -- resuming (%d of %d)" % [pack.name, source, why, _retries, RETRIES])
		_connect(_url)
		return
	_source_failed("%s: %s" % [source, why])

func _source_failed(why: String) -> void:
	_close_http()
	error = why
	_say("%s: %s" % [pack.name, why])
	_next_source(false)

func _finish() -> void:
	_close_file()
	var got := _ctx.finish().hex_encode()
	_ctx = null
	if got != pack.sha256:
		DirAccess.remove_absolute(partial_path)
		if _any_resume and not _fresh_retry_done:
			_fresh_retry_done = true
			_any_resume = false
			_say("%s: the resumed file's hash is %s, not the server's -- downloading it again from the start" % [pack.name, got.left(16)])
			_begin_fresh()
			_url = ""
			_src_i = 0
			_next_source(false)
			return
		_fail("%s's hash is %s, not the %s the server named" % [pack.name, got.left(16), pack.sha256.left(16)])
		return
	if DirAccess.rename_absolute(partial_path, final_path) != OK:
		_fail("cannot rename %s to %s" % [partial_path.get_file(), final_path.get_file()])
		return
	state = S_DONE
	error = "" # an earlier source's failure is history now
	_say("%s: %d bytes, sha256 verified -- in place" % [pack.name, pack.size])

func _fail(why: String) -> void:
	_close_http()
	_close_file()
	error = why
	state = S_FAILED

func cancel() -> void:
	if not is_over():
		_fail("cancelled")

func _close_http() -> void:
	if _http != null:
		_http.close()
		_http = null

func _close_file() -> void:
	if _file != null:
		_file.flush()
		_file.close()
		_file = null

## Lower-cased header names -> values.
func _headers() -> Dictionary:
	var out := {}
	for h in _http.get_response_headers():
		var c := str(h).find(":")
		if c > 0:
			out[str(h).substr(0, c).strip_edges().to_lower()] = str(h).substr(c + 1).strip_edges()
	return out

## "bytes 100-199/200" -> {start, end, total} (total -1 for "*"); {} if not.
static func parse_content_range(v: String) -> Dictionary:
	var s := v.strip_edges()
	if not s.to_lower().begins_with("bytes "):
		return {}
	s = s.substr(6).strip_edges()
	var slash := s.find("/")
	var dash := s.find("-")
	if slash < 0 or dash < 0 or dash > slash:
		return {}
	var a := s.substr(0, dash)
	var b := s.substr(dash + 1, slash - dash - 1)
	var t := s.substr(slash + 1)
	if not a.is_valid_int() or not b.is_valid_int() or not (t.is_valid_int() or t == "*"):
		return {}
	return {"start": a.to_int(), "end": b.to_int(), "total": t.to_int() if t != "*" else -1}

## A Location against the URL it answered: absolute, or a path on the same
## origin ("/x" or "x" beside the request's path).
static func resolve_location(base: String, loc: String) -> String:
	var l := loc.strip_edges()
	if l.to_lower().begins_with("http://") or l.to_lower().begins_with("https://"):
		return l
	var u := PackManifest.parse_url(base)
	if u.is_empty():
		return l
	var host := str(u["host"])
	if host.contains(":"):
		host = "[%s]" % host
	var origin := "%s://%s:%d" % [u["scheme"], host, u["port"]]
	if l.begins_with("//"):
		return "%s:%s" % [u["scheme"], l]
	if l.begins_with("/"):
		return origin + l
	var path := str(u["path"])
	var q := path.find("?")
	if q >= 0:
		path = path.substr(0, q)
	return origin + path.get_base_dir().path_join(l)

static func _status_name(st: int) -> String:
	match st:
		HTTPClient.STATUS_DISCONNECTED: return "disconnected"
		HTTPClient.STATUS_CANT_RESOLVE: return "cannot resolve the host"
		HTTPClient.STATUS_CANT_CONNECT: return "cannot connect"
		HTTPClient.STATUS_CONNECTION_ERROR: return "connection error"
		HTTPClient.STATUS_TLS_HANDSHAKE_ERROR: return "TLS handshake error"
	return "status %d" % st
