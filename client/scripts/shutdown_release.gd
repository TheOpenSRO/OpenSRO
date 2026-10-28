extends Node
## Releases the rendering resources the client's static caches hold, while the
## RenderingServer still exists (round 754, the Godot 4.7.2 spike).
##
## A `static var` lives until the script language shuts down, which Godot does
## AFTER the RenderingServer is freed (Main::cleanup). Under 4.2.2 that left
## only leak lines at exit. Under 4.7.2 every world run on Forward+ ended
## `ERROR: Parameter "RenderingServer::get_singleton()" is null. at:
## ~ImageTexture` and then aborted, rc 134 (MEASURED round 754 on the box: the
## Jangan, Hotan, Samarkand and Karakoram parity boots; the select screen,
## which builds no world, exited 0). An autoload leaves the tree when the
## SceneTree finalises, before Main::cleanup, so its _exit_tree is the last
## point at which these can still be freed cleanly. Autoloads persist across
## scene changes, so this runs at quit only, never at a world -> login change.
## Each cache refills itself on its next use, so a later use (there is none
## at quit) would only pay the build again.

func _exit_tree() -> void:
	wait_tasks()
	release()

## Waits for every WorkerThreadPool task a static holder may still own. Godot
## 4.7 frees a finished task that nobody waited for at the pool's shutdown,
## after the scripts are gone, and its Callable takes the process down: rc 134
## at every quit (MEASURED round 754: a lambda task never waited aborts 4.7.2
## at exit, while 4.2.2 printed "Pages in use exist at exit in PagedAllocator:
## N16WorkerThreadPool4TaskE" and exited). Instance holders wait in their own
## teardown (MusicDirector._exit_tree, SkillBuffCatalog and MonsterDraw's
## PREDELETE, CharacterAppearance's, World3D's _exit_tree).
static func wait_tasks() -> void:
	for id in [CharTables._boot_task, CharTables._entry_task, ItemTableReader._pending_task,
			SkillAudio._warm_task, SkillEffects._warm_task]:
		if int(id) >= 0:
			PoolWait.task(int(id))
	CharTables._boot_task = -1
	CharTables._entry_task = -1
	ItemTableReader._pending_task = -1
	SkillAudio._warm_task = -1
	SkillEffects._warm_task = -1
	EfpEffect.wait_preloads()
	AuraModel.wait_pending()

## Every static rendering resource the client keeps (READ: `grep -n "^static var"`
## over client/scripts, the ones holding a Texture, Mesh, Shader or Material).
static func release() -> void:
	# The game's cursor (GameCursor.show): the display server keeps the
	# ImageTextures it was handed for each shape until it is torn down.
	if DisplayServer.has_feature(DisplayServer.FEATURE_CUSTOM_CURSOR_SHAPE):
		for shape in range(Input.CURSOR_HELP + 1):
			Input.set_custom_mouse_cursor(null, shape)
	UiBuilder._flat_texture = null
	OptionVideoPage._blank_arrow_tex = null
	HudMinimap._black = null
	GameCursor._scaled_sets.clear()
	EquipGlow._option_textures.clear()
	EquipGlow._materials.clear()
	EfpEffect._textures.clear()
	EfpEffect._meshes.clear()
	EfpEffect._materials.clear()
	EfpEffect._shaders.clear()
	EfpEffect._turn_materials.clear()
	EfpEffect._images.clear()
	ItemCountLabel._digits.clear()
	RetailBloom._mesh = null
	ShadowCatcher._material = null
	GroundMarkers._ring_shader = null
	GammaSkyMaterial._shader = null
	# Caches of shaders, materials, images and shared tables that hold any of
	# the above, and callables whose lambdas may capture them.
	TexAni._live.clear()
	TexAni._bound.clear()
	CharSelectStage._undo_shaders.clear()
	CharSelectStage._fade_shaders.clear()
	ObjectLight._variants.clear()
	ObjectLoader._object_shaders.clear()
	ObjectLoader._mod_shaders.clear()
	ObjectLoader.FOLIAGE_SHADER = null
	ObjectLoader.FOLIAGE_SHADER_ONE_SIDED = null
	ObjectLoader.OBJECT_SHADER = null
	EquipGlow._shaders.clear()
	AppearFade._standard_fade_shaders.clear()
	AmbientParticles._arrays_cache.clear()
	AmbientParticles._image_cache.clear()
	CrowdAnim._shared.clear()
	SkillEffects._auras.clear()
	SkillEffects._flights.clear()
	SkillEffects.effect_factory = Callable()
	SkillEffects.own_body = null
	FrontEndBackdrop._world_script = null
	CharSelectHandoff.theme = null
	HudNotice._bold_cache.clear()
	UiBuilder._font_cache.clear()
	UiBuilder._button_fonts.clear()
	ItemTooltipInstance._quality = null
	ItemTooltipInstance._magic = null
	ItemGlowTables.shared = null
	MagicOptionTable.shared = null
	MagicOptionTable.shared_text = Callable()
	EquipFx.far_frame = Callable()
	EquipFx.far_origin = Callable()
	EquipFx.ghost_frame = Callable()
	EquipFx.ghost_origin = Callable()
	EquipFx.ghost_gpu = Callable()
	EquipFx.own_factory = Callable()
	CharacterBlobs.on_cast = Callable()
	CharacterLight.on_changed = Callable()
	VideoOptions._in_force = null
	AudioBank._cache.clear()
	ComboList._open = null
	AnimSoundSeam._sink = null
	GameCursor._base.clear()
