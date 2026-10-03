class_name MapmWater

## A region's water surfaces, built the way the retail client builds them:
## from each `.m` block's own PlaneType / WaveID / PlaneHeight (round 627,
## docs/protocol/MAPM_FORMAT.md "Water"). Labels: READ = recovered from
## sro_client.exe, MEASURED = counted over the real Map.pk2, INFERRED =
## follows from what was read but was not itself read, OURS = this project's
## choice.
##
## What retail does (READ):
## - The block loader `FUN_00a35c50` seeks to `index * 0xa0f + 0xc` and reads
##   the block's 0xa0f bytes straight into its record, so the record keeps the
##   file's offsets: PlaneType at block+0x7ed, WaveID at +0x7ee, PlaneHeight at
##   +0x7ef (+6 for Flag and EnvironmentID, then 289 7-byte vertices). The
##   block index is `col + row * 6` and the block's origin is (col * 320,
##   row * 320) -- the terrain builder's own layout.
## - PlaneType -1 is no water; 0 is animated water; 1 is a still surface drawn
##   with water\water201.ddj. The same loader forces -1 on every block of a
##   region whose flag at +0x2475 is set (`FUN_00a361b0` sets it from the
##   first byte of a per-region object list); what that list is, and so which
##   regions it hides water in, is OPEN.
## - For PlaneType 0, `Map::FUN_009fb280` gives each of the block's 17x17
##   vertices a shoreline alpha nibble, clamp(trunc((PlaneHeight - height) *
##   0.5), 0, 15) -- truncated: the `fistp` at 0x9fb34e runs under a control
##   word the code sets to RC=11 (fnstcw / or 0xc00 / fldcw at 0x9fb338) --
##   writes it into a 17x17 alpha texture, and overwrites
##   +0x7ee with the block's state: 0 every vertex dry, 1 no vertex dry, 2 dry
##   and partial, 3 dry and fully deep. A state-0 block is not drawn.
## - `Map::FUN_00a220b0` then draws ONE flat quad over the whole 320x320
##   block at PlaneHeight: stage 0 is the alpha texture (alpha only), stage 1
##   the water frame `water\water1NN.ddj`, frame (GetTickCount() / 100) % 30,
##   with UV 0..4 across the block, modulated by the texture factor, whose RGB
##   is the environment's WaterColor (channel 14). Alpha blending
##   SRCALPHA/INVSRCALPHA, cull mode NONE.
## - For PlaneType 1 with a non-zero WaveID (FUN_009fb280 returns before
##   touching +0x7ee, so this is the file's own byte), the same quad is drawn
##   with water201.ddj, colour straight from the texture, alpha the texture
##   factor's 0xB4.
##
## What is MEASURED (waterat -census over 4,704 real regions, 169,344
## blocks): PlaneType -1 128,879, 0 39,510, 1 955. For PlaneType 0 the file's
## own WaveID equals the state this file recomputes on 39,486 of 39,510
## blocks (the authoring tool ran the same rule), which checks the reading of
## FUN_009fb280.
##
## What is ours: the alpha texture is sampled per vertex rather than through a
## 17x17 texture (the two agree at every vertex; between vertices the texture
## is bilinear and the mesh is linear across two triangles), and each block is
## a 16x16 grid of quads so it can carry that alpha.

const PLANE_NONE := -1
const PLANE_WATER := 0
const PLANE_STILL := 1

## READ: the quad spans one block, `_DAT_00e1b908` = 320.0.
const BLOCK_SPAN := 320.0
const GRID_WIDTH := MapmReader.GRID_WIDTH
const TILE_SPAN := BLOCK_SPAN / float(GRID_WIDTH - 1)

## READ: the frame texture's UV runs 0..`_DAT_00e1b860` = 4.0 across a
## block, so one frame repeats every 80 units.
const FRAME_UV_REPEAT := 4.0
## READ: depth to alpha, `(PlaneHeight - height) * _DAT_00e1b7d0` (0.5),
## clamped to `_DAT_00d878a0` (15.0).
const DEPTH_TO_NIBBLE := 0.5
const NIBBLE_MAX := 15
## READ: frame = (GetTickCount() / 100) % 0x1e.
const FRAME_COUNT := 30
const FRAME_MS := 100
## READ: the texture factor's alpha byte, `| 0xffffb400` -> 0xB4.
const STILL_ALPHA := 180.0 / 255.0

## The block's shoreline alpha nibble at one vertex (READ, FUN_009fb280).
static func shoreline_nibble(plane_height: float, ground: float) -> int:
	var f := (plane_height - ground) * DEPTH_TO_NIBBLE
	if f <= 0.0:
		return 0
	if f > float(NIBBLE_MAX):
		return NIBBLE_MAX
	# READ: truncation. FUN_009fb280 sets the x87 rounding control to
	# RC=11 (chop) right before the `fistp` (0x9fb338-0x9fb34e); f is
	# positive here, so truncating is flooring.
	return int(f)

## The nibble as a vertex alpha. The client packs it as A4R4G4B4 (n/15) or,
## on the other branch of `DAT_0110f728 < 3`, as the top nibble of an
## A8R8G8B8 alpha (n*16/255, at most 0.94); which branch a given machine
## takes is OPEN. OURS: n/15, so deep water is fully opaque on both counts
## but 6%.
static func nibble_alpha(n: int) -> float:
	return float(n) / float(NIBBLE_MAX)

## The block state the client writes to +0x7ee for a PlaneType-0 block
## (READ, FUN_009fb280): 0 all dry -- not drawn; 1 no vertex dry; 2 dry and
## partial, no fully deep vertex; 3 dry and fully deep.
static func block_state(block: MapmReader.Block) -> int:
	var dry := false
	var partial := false
	var deep := false
	for v in block.vertices:
		var f: float = (block.plane_height - (v as MapmReader.Vertex).height) * DEPTH_TO_NIBBLE
		if f <= 0.0:
			dry = true
		elif f > float(NIBBLE_MAX):
			deep = true
		else:
			partial = true
	if not dry:
		return 1
	if deep:
		return 3
	if partial:
		return 2
	return 0

## Whether every vertex of a block is nibble 15 -- fully opaque water.
static func all_deep(block: MapmReader.Block) -> bool:
	for v in block.vertices:
		if shoreline_nibble(block.plane_height, (v as MapmReader.Vertex).height) != NIBBLE_MAX:
			return false
	return true

## Whether the client draws block water at all for a world whose current
## region id is `region_id` (READ, `Map::FUN_00a220b0`): with bit 15 set --
## a dungeon, whose ids world+0x237e's own setter (`SWorld::vslot_001`)
## routes to the dungeon manager -- the object-water branch runs and jumps
## past both block loops. No `.m` region has x >= 128 (MEASURED: Map.pk2's
## 4,721 `.m` files top out at x = 127), so this never hides a field region.
static func draws_block_water(region_id: int) -> bool:
	return (region_id & 0x8000) == 0

## A region's 36 block EnvironmentIDs, block index col + row * 6 -- what
## environment_at reads, kept per region so the whole parsed region need not
## be.
static func block_environment_ids(region: MapmReader.ParsedRegion) -> PackedInt32Array:
	var ids := PackedInt32Array()
	if region == null or region.blocks.size() != MapmReader.BLOCK_COUNT:
		return ids
	for block in region.blocks:
		ids.append((block as MapmReader.Block).environment_id)
	return ids

## The EnvironmentID of the block containing region-local (x, z), or -1.
## Retail takes its environment -- WaterColor included -- from the first
## entry of its drawn-block list: `Map::FUN_00a1baf0` reads
## `**(world+0x2783) + 4`, the block's EnvironmentID (READ). That list is
## copied in order from an ordered map (`Map::FUN_00a2b030`) that
## `Map::FUN_00a2b370` fills with every block passing the view test, keyed
## by its squared block-grid distance from the camera's block
## (world+0x6914/0x6910; READ). So the first entry is the camera's own block
## whenever that block passes the view test (INFERRED: it nearly always
## does, the camera standing over it), and ONE environment drives the whole
## world's water, not one per region.
static func environment_at(ids: PackedInt32Array, x: float, z: float) -> int:
	var side := MapmReader.BLOCKS_PER_SIDE
	if ids.size() != side * side:
		return -1
	var bx := int(floorf(x / BLOCK_SPAN))
	var bz := int(floorf(z / BLOCK_SPAN))
	if bx < 0 or bz < 0 or bx >= side or bz >= side:
		return -1
	return ids[bz * side + bx]

## Whether the client draws this block, and as which surface.
static func block_kind(block: MapmReader.Block) -> int:
	if block.plane_type == PLANE_WATER:
		return PLANE_WATER if block_state(block) != 0 else PLANE_NONE
	if block.plane_type == PLANE_STILL and block.wave_id != 0:
		return PLANE_STILL
	return PLANE_NONE

class Built:
	## Animated water (PlaneType 0), or null.
	var water: ArrayMesh
	## Still surface (PlaneType 1), or null.
	var still: ArrayMesh
	var water_blocks := 0
	var still_blocks := 0
	## PlaneType-0 blocks the client skips because every vertex is dry.
	var dry_blocks := 0
	## Drawn PlaneType-0 blocks that are fully deep (nibble 15 at every
	## vertex), built as one quad instead of a 16x16 grid.
	var deep_blocks := 0
	## Distinct plane heights drawn, for the log.
	var heights := {}
	## Every drawn block as (local x0, local z0, PlaneHeight), for the
	## reflection's choice of plane (WaterReflection).
	var drawn := PackedFloat32Array()

## Builds a region's water in region-local space (the terrain mesh's: block
## column -> X, block row -> Z, 20 units a tile, heights raw), wound so
## Godot's front face points up like the terrain's. Retail culls neither side
## (cull mode NONE), which the material has to say too -- see World3D.
static func build(region: MapmReader.ParsedRegion) -> Built:
	var out := Built.new()
	if region == null or region.blocks.size() != MapmReader.BLOCK_COUNT:
		return out
	var w_pos := PackedVector3Array()
	var w_uv := PackedVector2Array()
	var w_col := PackedColorArray()
	var w_idx := PackedInt32Array()
	var s_pos := PackedVector3Array()
	var s_uv := PackedVector2Array()
	var s_idx := PackedInt32Array()
	var side := MapmReader.BLOCKS_PER_SIDE
	for band_row in range(side):
		for band_col in range(side):
			var block: MapmReader.Block = region.blocks[band_row * side + band_col]
			var x0 := float(band_col) * BLOCK_SPAN
			var z0 := float(band_row) * BLOCK_SPAN
			if block.plane_type == PLANE_WATER and block_state(block) == 0:
				out.dry_blocks += 1
			match block_kind(block):
				PLANE_WATER:
					out.water_blocks += 1
					out.heights[block.plane_height] = true
					out.drawn.append_array(PackedFloat32Array([x0, z0, block.plane_height]))
					var base := w_pos.size()
					if all_deep(block):
						# Every vertex is nibble 15, so the alpha is 1 all over
						# and one quad draws the same thing as 512 triangles
						# (OURS: a mesh economy, not a retail rule -- retail
						# draws one quad per block anyway).
						out.deep_blocks += 1
						var h := block.plane_height
						w_pos.append_array(PackedVector3Array([
							Vector3(x0, h, z0), Vector3(x0 + BLOCK_SPAN, h, z0),
							Vector3(x0 + BLOCK_SPAN, h, z0 + BLOCK_SPAN), Vector3(x0, h, z0 + BLOCK_SPAN),
						]))
						w_uv.append_array(PackedVector2Array([
							Vector2(0, 0), Vector2(FRAME_UV_REPEAT, 0),
							Vector2(FRAME_UV_REPEAT, FRAME_UV_REPEAT), Vector2(0, FRAME_UV_REPEAT),
						]))
						w_col.append_array(PackedColorArray([Color(1, 1, 1, 1), Color(1, 1, 1, 1), Color(1, 1, 1, 1), Color(1, 1, 1, 1)]))
						w_idx.append_array(PackedInt32Array([base, base + 1, base + 2, base, base + 2, base + 3]))
					else:
						for r in range(GRID_WIDTH):
							for c in range(GRID_WIDTH):
								var ground: float = block.vertices[r * GRID_WIDTH + c].height
								w_pos.append(Vector3(x0 + c * TILE_SPAN, block.plane_height, z0 + r * TILE_SPAN))
								w_uv.append(Vector2(float(c), float(r)) / float(GRID_WIDTH - 1) * FRAME_UV_REPEAT)
								w_col.append(Color(1, 1, 1, nibble_alpha(shoreline_nibble(block.plane_height, ground))))
						for r in range(GRID_WIDTH - 1):
							for c in range(GRID_WIDTH - 1):
								var i00 := base + r * GRID_WIDTH + c
								var i10 := i00 + 1
								var i01 := i00 + GRID_WIDTH
								var i11 := i01 + 1
								w_idx.append_array(PackedInt32Array([i00, i10, i11, i00, i11, i01]))
				PLANE_STILL:
					out.still_blocks += 1
					out.heights[block.plane_height] = true
					out.drawn.append_array(PackedFloat32Array([x0, z0, block.plane_height]))
					var base := s_pos.size()
					var h := block.plane_height
					s_pos.append_array(PackedVector3Array([
						Vector3(x0, h, z0), Vector3(x0 + BLOCK_SPAN, h, z0),
						Vector3(x0 + BLOCK_SPAN, h, z0 + BLOCK_SPAN), Vector3(x0, h, z0 + BLOCK_SPAN),
					]))
					s_uv.append_array(PackedVector2Array([
						Vector2(0, 0), Vector2(FRAME_UV_REPEAT, 0),
						Vector2(FRAME_UV_REPEAT, FRAME_UV_REPEAT), Vector2(0, FRAME_UV_REPEAT),
					]))
					s_idx.append_array(PackedInt32Array([base, base + 1, base + 2, base, base + 2, base + 3]))
	out.water = _mesh(w_pos, w_uv, w_col, w_idx)
	out.still = _mesh(s_pos, s_uv, PackedColorArray(), s_idx)
	return out

static func _mesh(pos: PackedVector3Array, uv: PackedVector2Array, col: PackedColorArray, idx: PackedInt32Array) -> ArrayMesh:
	if idx.is_empty():
		return null
	var normals := PackedVector3Array()
	normals.resize(pos.size())
	normals.fill(Vector3.UP)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = pos
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uv
	if not col.is_empty():
		arrays[Mesh.ARRAY_COLOR] = col
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

## The animated surface's material (READ, `Map::FUN_00a220b0`):
## - colour = the frame (stage 1) times the texture factor, whose RGB is the
##   environment's WaterColor -- stage 1 is MODULATE(TEXTURE, TFACTOR) and
##   never reads the diffuse, so no lighting reaches it: unshaded;
## - alpha = the shoreline alpha (stage 0 SELECTARG1 TEXTURE, stage 1 alpha
##   disabled), here the vertex alpha build() writes; the frames' own alpha
##   is 255 on every texel (MEASURED, water101 and water115), so the
##   material multiplying it in changes nothing;
## - SRCALPHA / INVSRCALPHA blending and D3DCULL_NONE: both sides are drawn.
##   A culled back face is what hid the water from above until round 627.
static func water_material(frames: Texture2D, water_color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.vertex_color_use_as_albedo = true
	# Display values, as Compatibility reads them; decoded where the output
	# is linear (Forward+), round 693's ShaderColour.
	mat.vertex_color_is_srgb = ShaderColour.VERTEX_COLOR_IS_SRGB
	mat.albedo_texture = frames
	set_water_color(mat, water_color)
	# Drawn before the fog pass, so it is fogged with the ground it covers
	# (round 702, WorldFog.UNDER_PASS_PRIORITY).
	mat.render_priority = WorldFog.UNDER_PASS_PRIORITY
	return mat

## The texture factor's RGB: WaterColor clamped to [0, 1], as
## `Map::FUN_00a1baf0` clamps world+0x688f..0x6897 (READ).
static func set_water_color(mat: StandardMaterial3D, water_color: Color) -> void:
	mat.albedo_color = Color(clampf(water_color.r, 0.0, 1.0), clampf(water_color.g, 0.0, 1.0), clampf(water_color.b, 0.0, 1.0), 1.0)

## The still surface's material (READ, same function): colour SELECTARG1
## TEXTURE (water201 unmodulated), alpha SELECTARG1 TFACTOR (0xB4), the same
## blending, no culling.
static func still_material(tex: Texture2D) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_texture = tex
	mat.albedo_color = Color(1, 1, 1, STILL_ALPHA)
	mat.render_priority = WorldFog.UNDER_PASS_PRIORITY
	return mat

## How many of a mesh's triangles face up by Godot's own front-face rule
## (Plane(a, b, c) is the front side), and how many face down. The world
## group's z -> -z mirror does not change this: Godot flips the cull test for
## a negative-determinant transform (World3D's place_group comment).
static func facing_counts(mesh: ArrayMesh) -> Vector2i:
	var up := 0
	var down := 0
	if mesh == null:
		return Vector2i.ZERO
	for s in range(mesh.get_surface_count()):
		var arrays := mesh.surface_get_arrays(s)
		var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		for t in range(0, idx.size(), 3):
			var n := Plane(pos[idx[t]], pos[idx[t + 1]], pos[idx[t + 2]]).normal
			if n.y > 0.0:
				up += 1
			elif n.y < 0.0:
				down += 1
	return Vector2i(up, down)
