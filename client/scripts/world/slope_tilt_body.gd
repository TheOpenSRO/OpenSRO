extends Node3D
class_name SlopeTiltBody

## Round 813: the script a leaning body (SlopeTilt) carries so that a move or
## a turn reaches the slope tilt as an event, as the original's slot-15
## position (2) and heading (3) events mark its normal stale -- instead of a
## per-frame look at every body: 2,500 standing monsters cost 14 ms a frame
## polled (MEASURED, round 813's perf gate, crowd view). Godot sends
## NOTIFICATION_TRANSFORM_CHANGED once per frame for a node whose global
## transform changed while set_notify_transform is on; the body files itself
## in `hot`, World3D's set of bodies to look at this frame.

var hot: Dictionary = {}

func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED:
		hot[get_instance_id()] = true
