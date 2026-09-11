class_name CharacterPreview
extends Control

## A live 3D preview of an assembled character body for a chosen gender, for
## the character-create screen. It reuses the world's own pieces -- the
## characterdata code->.bsr resolution, SkinnedBsrAssembler, and PaperDoll (a
## SubViewport that frames and lights a skeleton in its own little scene) --
## so the preview is the same body the world builds, not a stand-in.
##
## Everything is loaded at runtime from the player's own Data.pk2 / Media.pk2;
## nothing is shipped. With no archives (a dev run without game data) it shows
## nothing rather than a placeholder. See docs/FRONTEND.md.

# The same mapping World3D uses (GENDER_BODY_CODE): a gender to its
# characterdata code, which the table resolves to a body .bsr.
const GENDER_BODY_CODE := {
	"china_man": "CHAR_CH_MAN_FIGHTER",
	"china_woman": "CHAR_CH_WOMAN_FIGHTER",
}

var _data_pk2: Pk2Reader
var _media_pk2: Pk2Reader
var _bodies := {} # characterdata code -> body .bsr path
var _doll: PaperDoll
var _view: TextureRect
var _gender := ""
var _ready_done := false
# The body's own idle, played so the preview stands and breathes rather than
# holding the bind (T-)pose -- the same animation the world gives the player.
var _skeleton: Skeleton3D
var _idle: BanReader.ParsedAnimation
var _anim_time := 0.0

func _init(size_px: Vector2i = Vector2i(320, 640)) -> void:
	_doll = PaperDoll.new()
	_doll.size = size_px
	add_child(_doll)
	_view = TextureRect.new()
	_view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_view.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_view)

func _ready() -> void:
	# The doll is in the tree now, so its viewport texture is live.
	_view.texture = _doll.get_texture()
	_open_archives()
	_ready_done = true
	if _gender != "":
		_rebuild()

## Opens the player's Data.pk2 (bodies) and Media.pk2 (characterdata), and
## reads the code->.bsr table. Leaves everything empty when no archives are
## configured.
func _open_archives() -> void:
	var data_path := Pk2Config.data_path()
	var media_path := Pk2Config.media_path()
	if data_path == "" or media_path == "":
		return
	_data_pk2 = Pk2Reader.open(data_path)
	_media_pk2 = Pk2Reader.open(media_path)
	if _media_pk2 == null:
		return
	for path in NpcTableReader.MODEL_TABLE_PATHS:
		var entry := ObjectLoader.find_file(_media_pk2, path)
		if entry != null:
			_bodies = NpcTableReader.parse_models_by_code(_media_pk2.read_file(entry), _bodies)

## Shows the body for `gender` (one of GENDER_BODY_CODE's keys). Cheap to
## call with the current gender (a no-op).
func set_gender(gender: String) -> void:
	if gender == _gender:
		return
	_gender = gender
	if _ready_done:
		_rebuild()

func _rebuild() -> void:
	if _data_pk2 == null or _bodies.is_empty():
		return
	var code: String = GENDER_BODY_CODE.get(_gender, GENDER_BODY_CODE["china_man"])
	var bsr_path: String = _bodies.get(code, "")
	if bsr_path == "":
		push_warning("CharacterPreview: characterdata has no %s body" % code)
		return
	var assembled := SkinnedBsrAssembler.assemble_from_archive(_data_pk2, bsr_path, true)
	if assembled == null:
		return
	_skeleton = assembled.skeleton
	_idle = assembled.idle_animation
	_anim_time = 0.0
	_doll.set_character(_skeleton)

## Advances the idle so the preview breathes instead of holding its bind
## pose. The skeleton is re-framed once by PaperDoll on set_character; the
## idle keeps the bones near that framing.
func _process(delta: float) -> void:
	if _idle == null or _skeleton == null or not is_instance_valid(_skeleton):
		return
	_anim_time += delta
	Skeleton3DBuilder.apply_ban_pose_at(_skeleton, _idle, _anim_time, true)

## Whether real archives were found -- the create screen shows a plain note
## instead of an empty box when not.
func has_archives() -> bool:
	return _data_pk2 != null and not _bodies.is_empty()
