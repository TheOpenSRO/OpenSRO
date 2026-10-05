class_name CameraPlanes

## The world camera's near plane: **1.0, retail's** (READ, round 648: `fld1` in
## the camera constructor `FUN_00bae0a0`, never written again; docs/protocol/
## MAPM_FORMAT.md "Depth"). Round 729: Godot's default 0.05 was kept until
## now. With a standard-z depth buffer (INFERRED for Godot 4.2: reversed z
## arrived in 4.3) the step it can tell apart at distance d is about
## d^2 * 2^-24 / near, so 0.05 gave 20 times less precision than retail at
## every distance. Layers 0.01-1.8 apart (alex_minga02's window grilles, dark
## insets and doors over its walls, MEASURED by tools/probe_coplanar.gd)
## z-fought as the camera moved -- the user's report of 2026-10-05; a
## 0.02-unit camera sweep flipped 2,336 pixels of that building at 0.05
## against 127 at 1.0 (MEASURED, docs/rounds/r729.md).
## The camera arm sweeps a radius-3 sphere with a 5-unit margin
## (World3D.tscn), so nothing with a collider comes within the 1.0 plane's
## reach (its corners stand ~1.6 out at a 1.92 aspect).
## OPENSRO_QA_CAMERA_NEAR=<n> overrides it, for before/after measurement only.
const NEAR := 1.0

static func near() -> float:
	var qa := OS.get_environment("OPENSRO_QA_CAMERA_NEAR")
	if qa != "" and qa.is_valid_float() and float(qa) > 0.0:
		return float(qa)
	return NEAR
