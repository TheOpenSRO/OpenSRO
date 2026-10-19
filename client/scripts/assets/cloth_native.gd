extends RefCounted
class_name ClothNative

## Round 794: which cloth steps a body's meshes -- SrCloth (native/src/core/
## cloth.rs through native/src/gd_cloth.rs) when the library has it, ClothSim
## (GDScript, the same rules) otherwise. Both answer setup, last_error, reset,
## skin, step, vertex_data, positions and bounds. The class is looked up by
## name, so the client compiles without the library. OPENSRO_CLOTH_NATIVE=0
## keeps GDScript (QA, an A/B).

const CLASS := "SrCloth"
## gd_cloth.rs CLOTH_API.
const CLOTH_API := 1

static var _checked := false
static var _available := false
static var status := ""

static func available() -> bool:
	if not _checked:
		_checked = true
		var why := ""
		if OS.get_environment("OPENSRO_CLOTH_NATIVE") == "0":
			why = "forced off by OPENSRO_CLOTH_NATIVE=0"
		elif not NativeAssets.available():
			why = "native readers off"
		elif not ClassDB.class_exists(CLASS):
			why = "the library has no cloth (built before round 794: rebuild it with native/build.sh)"
		else:
			var probe: Object = ClassDB.instantiate(CLASS)
			if not probe.has_method("cloth_api") or int(probe.call("cloth_api")) != CLOTH_API:
				why = "the library's cloth interface is %s, this client needs %d" % [
					str(probe.call("cloth_api")) if probe.has_method("cloth_api") else "none", CLOTH_API]
		_available = why == ""
		status = "ClothNative: native cloth ON" if _available else "ClothNative: native cloth OFF (%s) -- cloth steps in GDScript" % why
		print(status)
	return _available and not NativeAssets.force_gdscript

## A new, empty cloth of whichever kind runs here.
static func create() -> Object:
	if available():
		return ClassDB.instantiate(CLASS)
	return ClothSim.new()

## Seeds both generators (MSVC srand), so a test or a QA run repeats.
static func srand(seed: int) -> void:
	ClothSim.srand(seed)
	if available():
		(ClassDB.instantiate(CLASS) as Object).call("seed_rand", seed)
