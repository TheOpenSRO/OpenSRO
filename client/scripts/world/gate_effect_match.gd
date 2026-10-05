class_name GateEffectMatch

## Which placed objects play a teleport row's gate effects (round 723).
##
## Round 720 matched a row only against the objects in its OWN region's
## container. A gate's model is not always there: a placement listed by
## several sectors' .o2 lists is placed once, by whichever of those regions
## loads first ("N already placed by a loaded region"), and a region can own
## objects placed in its neighbour's frame. On the user's teleport into
## Samarkand, region 106/108 loaded before 107/107, so `samarkand_center_01`
## -- the gate's model, 1.0 from STORE_CA_GATE's row at 107/107 local
## (1917, 108) -- sat in a neighbour's container and no gate effect was ever
## attached (MEASURED, the user's client log, 2026-10-05). Donwhang's row
## (103/153 local (962, 8)) stands on its region's edge the same way.
##
## So a row is matched against the objects of its region and its eight
## neighbours, in one frame: the frame of the region being committed, which
## a neighbour's region-local point reaches by its grid offset. Before the
## world's z mirror, region (x + dx, y + dy)'s local origin stands at
## (dy * SPAN, dx * SPAN) in region (x, y)'s local frame -- region y runs
## along world X, region x along world Z (World3D._cell_offset; AGENTS.md).
## The match runs on every region's commit for that region and its
## neighbours, so either load order finds the pair.

const SPAN := 1920.0

## A row's region-local x/z (`local`, its own region `row_region`) in the
## local frame of `frame_region`. Region coordinates are (region_x, region_y).
static func row_in_frame(local: Vector2, row_region: Vector2i, frame_region: Vector2i) -> Vector2:
	var dx: int = row_region.x - frame_region.x
	var dy: int = row_region.y - frame_region.y
	return Vector2(local.x + dy * SPAN, local.y + dx * SPAN)

## The regions whose rows or objects can pair with region `at`'s: itself and
## its eight neighbours.
static func around(at: Vector2i) -> Array:
	var out: Array = []
	for dx in [-1, 0, 1]:
		for dy in [-1, 0, 1]:
			var rx: int = at.x + dx
			var ry: int = at.y + dy
			out.append(Vector2i(rx, ry))
	return out

## The pairs within `radius` (horizontally, one shared frame): `rows` holds
## Dictionaries {"key", "at": Vector2}, `objects` {"key", "at": Vector2,
## "done": bool}. An object already done, or already paired with an earlier
## row, is skipped -- an object plays its effects once. Returns
## [{"row", "object", "distance"}], the keys.
static func pairs(rows: Array, objects: Array, radius: float) -> Array:
	var out: Array = []
	var taken := {}
	for row in rows:
		var at: Vector2 = row["at"]
		for obj in objects:
			if obj.get("done", false) or taken.has(obj["key"]):
				continue
			var d := (obj["at"] as Vector2).distance_to(at)
			if d > radius:
				continue
			taken[obj["key"]] = true
			out.append({"row": row["key"], "object": obj["key"], "distance": d})
	return out
