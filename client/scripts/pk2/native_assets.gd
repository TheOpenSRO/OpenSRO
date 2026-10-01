extends RefCounted
class_name NativeAssets

## The switch between the native (Rust, GDExtension) asset readers and the
## GDScript ones (round 667; native/README.md).
##
## The native library is optional. client/srrevamp_native.gdextension names
## it; when the file it names is absent -- CI's Godot validation, every test
## suite, a client shipped without the DLL -- Godot 4.2.2 prints one error
## while loading the extension and registers no classes, and everything here
## answers "not available", so the GDScript readers run exactly as before.
## Nothing in the client names a native class as a type: they are looked up
## by string through ClassDB, so no script fails to compile without them.
##
## SRREVAMP_NATIVE=0 forces the GDScript path even when the library loaded:
## the A/B switch perf_gate.sh's `--base-env` uses to compare one build both
## ways (client/tools/README.md, "Native readers A/B").

## The native pk2 archive class (native/src/gd.rs).
const PK2_CLASS := "SrNativePk2"
## The native parsers (native/src/gd.rs), one static-like method per format.
const PARSERS_CLASS := "SrNativeParsers"

## Set by a parity check or a test to run the GDScript path in a process
## that has the library (native_parity.gd, native_assets_test.gd): every
## handle opened and every decode made while it is set is GDScript's.
static var force_gdscript := false

## True when the library loaded, whatever SRREVAMP_NATIVE or force_gdscript
## say -- what a parity check needs to know before comparing anything.
static func library_loaded() -> bool:
	return ClassDB.class_exists(PK2_CLASS) and ClassDB.class_exists(PARSERS_CLASS)

static var _checked := false
static var _available := false
static var _parsers: Object = null

## True when the extension loaded and SRREVAMP_NATIVE is not "0". Logged once.
static func available() -> bool:
	if not _checked:
		_checked = true
		var loaded := library_loaded()
		var forced_off := OS.get_environment("SRREVAMP_NATIVE") == "0"
		_available = loaded and not forced_off
		var version := ""
		if loaded:
			# Made here, on the first caller's thread (Pk2Reader.open, at boot,
			# on the main thread), so worker threads only ever read it.
			_parsers = ClassDB.instantiate(PARSERS_CLASS)
			version = str(_parsers.call("version"))
		print("NativeAssets: native readers %s (library %s%s)" % [
			"ON" if _available else "OFF",
			("loaded, " + version) if loaded else "not loaded",
			", forced off by SRREVAMP_NATIVE=0" if loaded and forced_off else ""])
	return _available and not force_gdscript

## The shared parser object (stateless; its methods are thread-safe), or null.
static func parsers() -> Object:
	if not available():
		return null
	return _parsers

## A new native pk2 handle, or null when the library is unavailable.
static func new_pk2() -> Object:
	if not available():
		return null
	return ClassDB.instantiate(PK2_CLASS)
