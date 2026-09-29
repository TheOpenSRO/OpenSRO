extends RefCounted
class_name MapAnimationProbe

## QA only (round 645 cost split): where the frame time of the animated map
## objects goes. `SRREVAMP_QA_MAPANIM_SPLIT=<frame>` with
## `SRREVAMP_QA_MAPANIM_MODE=<mode>` switches, at that frame, every
## registered object to one of the states below and halts the driver, so a
## run's `QA MAPANIM` process time before and after the frame -- against a
## `SRREVAMP_NO_MAP_ANIM=1` run for the drift -- prices that part. Each mode
## is one-way: the objects are not put back.
##
##   manual       every player on manual stepping, advanced here once a
##                frame (stepped()) -- `mix_usec` brackets the mixers' work
##   strip_player the players freed: the skeletons and skins stay, still
##   strip_skin   the skins unbound: the players and skeletons keep running
##   unskin_hidden the skins of the objects not drawn now (out of range or
##                never visited) unbound; the driver keeps running
##   freeze_skel  the players freed and the skeletons' processing disabled
##   stripped     players, skeletons and skins all gone: the pre-645 object
##   share        every running copy of one clip draws from the first one's
##                skeleton (its own player and skeleton freed) -- the saving
##                a shared pose would bring, at the cost of lockstep

const MODES := ["manual", "strip_player", "unskin_hidden", "freeze_skel", "strip_skin", "stripped", "share"]

static var mix_usec := 0

## Puts every object `driver` holds into `mode` and halts the driver.
static func apply(driver: MapAnimation.Driver, mode: String) -> void:
	driver.halted = true
	var masters := {}
	for entry in driver.entries():
		if not is_instance_valid(entry[0]) or not is_instance_valid(entry[1]):
			continue
		var player: AnimationPlayer = entry[0]
		var root: Node3D = entry[1]
		var skeleton := root.get_node_or_null(MapAnimation.SKELETON_NODE) as Skeleton3D
		var meshes := root.find_children("*", "MeshInstance3D", true, false)
		match mode:
			"manual":
				player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
			"strip_player":
				player.queue_free()
			"unskin_hidden":
				driver.halted = false
				if root.visible:
					continue
				for mi in meshes:
					(mi as MeshInstance3D).skin = null
					(mi as MeshInstance3D).skeleton = NodePath()
			"freeze_skel":
				player.queue_free()
				if skeleton != null:
					skeleton.process_mode = Node.PROCESS_MODE_DISABLED
			"strip_skin":
				for mi in meshes:
					(mi as MeshInstance3D).skin = null
					(mi as MeshInstance3D).skeleton = NodePath()
			"stripped":
				for mi in meshes:
					(mi as MeshInstance3D).skin = null
					(mi as MeshInstance3D).skeleton = NodePath()
				player.queue_free()
				if skeleton != null:
					skeleton.queue_free()
			"share":
				if not player.active or skeleton == null:
					continue
				var clip := player.get_animation(MapAnimation.CLIP_NAME)
				if not masters.has(clip):
					masters[clip] = skeleton
					continue
				var master: Skeleton3D = masters[clip]
				for mi in meshes:
					if (mi as MeshInstance3D).skin != null:
						(mi as MeshInstance3D).skeleton = (mi as MeshInstance3D).get_path_to(master)
				player.queue_free()
				skeleton.queue_free()

## Advances every active player by `delta` in "manual" mode, timing it.
static func step(driver: MapAnimation.Driver, delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	for entry in driver.entries():
		if is_instance_valid(entry[0]) and (entry[0] as AnimationPlayer).active:
			(entry[0] as AnimationPlayer).advance(delta)
	mix_usec = Time.get_ticks_usec() - t0
