extends SceneTree

## The Forgotten World gate's model (StructureWorld.gate_model, round 871).
## MEASURED: the original draws the gate as a blue crystal with a glow
## (`quest\ins_quest_teleport.bsr`, the database's row); this archive's
## teleportbuilding row names `alex_raid_portal.bsr`. The crystal is drawn
## when the archive has it, the row's model otherwise; other gate codes keep
## their row. The archive part reads the box's Data.pk2 and checks the
## crystal's file: a static .bsr whose ambient effects are the glow and the
## light. Run headless on the render box: `client/tools/remote_godot.sh tests`.

const DATA := "/opt/sro-files/client/Data.pk2"
const ROW := "Bldg\\North Africa\\Alexandria\\alex_raid_portal.bsr"
const CRYSTAL := "quest\\ins_quest_teleport.bsr"

var _failures := 0

## World3D's one call StructureWorld.gate_model makes.
class StubWorld extends Node:
	var archive: Pk2Reader = null
	func _open_pk2_if_set() -> Pk2Reader:
		return archive

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## StructureWorld names the NetClient autoload, which a --script suite
## registers only after _init: the script is loaded once the tree runs
## (height_retry_test.gd's pattern).
func _initialize() -> void:
	var watchdog := create_timer(60.0)
	watchdog.timeout.connect(func() -> void:
		print("FAIL the suite never reported (a script error stopped it)")
		quit(1))
	await process_frame
	var structure_world: GDScript = load("res://scripts/world/structure_world.gd")
	var stub := StubWorld.new()
	var sw = structure_world.new(stub)
	_check(sw.gate_model("INS_QUEST_TELEPORT", ROW) == ROW, "no archive: the row's model")
	_check(sw.gate_model("INS_TEMPLE_TELEPORT", ROW) == ROW, "another gate keeps its row's model")
	var data := Pk2Reader.open(DATA) if FileAccess.file_exists(DATA) else null
	if data == null:
		print("SKIP the archive part: no Data.pk2")
	else:
		stub.archive = data
		_check(sw.gate_model("INS_QUEST_TELEPORT", ROW) == CRYSTAL,
			"with the archive: the Forgotten World gate is the crystal (%s)" % sw.gate_model("INS_QUEST_TELEPORT", ROW))
		_check(structure_world.crystal_model("NPC_INS_EXIT_TELEPORT", ROW, data) == CRYSTAL,
			"and so is the layer's exit NPC (characterdata 36032)")
		_check(structure_world.crystal_model("NPC_FWORLD_RECALL_PARTY", "Dun\\Property\\com\\property_recall.bsr", data) == "Dun\\Property\\com\\property_recall.bsr",
			"the recall pillar keeps its row")
		var parsed := BsrReader.parse(SkinnedBsrAssembler._read(data, CRYSTAL))
		_check(parsed != null and not parsed.is_character and parsed.skeleton_path == "",
			"MEASURED: the crystal is a static object .bsr (no skeleton): the scenery path builds it")
		var raw := SkinnedBsrAssembler._read(data, CRYSTAL)
		var text := ""
		for b in raw:
			text += char(b) if b >= 32 and b < 127 else " "
		_check(text.contains("bigsujung_potal_glow.efp") and text.contains("bigsujung_light_blue.efp"),
			"MEASURED: its ambient effects are the glow and the blue light (%d bytes)" % raw.size())
		data.close()
	stub.free()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
