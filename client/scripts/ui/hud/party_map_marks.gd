class_name PartyMapMarks
extends RefCounted

## Party members on the minimap and the world map (round 717). The rules are
## the original client's (`sro_client.exe`, md5 2a5794b72c90908d945be8b3f3f2edd4);
## docs/protocol/party_gui.md section 9 has the reading. Pure functions, so the
## placement is tested without a scene.
##
## **The minimap** (CIFMinimap::vslot_013, the party loop at 0x6643a0..0x664ad1):
## - For each member of the party manager's list (0x986f50, list +0x20) other
##   than the player (`member +0x44 != manager +0x18`, 0x6643bb) whose world id
##   equals the player's (`record +0x68` against `player +0x20e4`, 0x6643ca),
##   and whose region the player can see (0x9d5520: a field region while the
##   player is in the field, or the player's own dungeon on the player's
##   floor; region_visible), READ. In a dungeon the positions are the
##   dungeon's own space, the player's +0x80 as the record's (round 786).
## - The position is the member's spawned object's (+0x90..+0x98) when one
##   exists (0x9c35e0, 0x66441f), else the record's (x, 0, z) in its region
##   (0x9ecfd0, 0x66444c), READ.
## - The map offset is (dx, -dz) / 1920 x the drawn tile size (+0x3fc), and its
##   length (0xb42de0 is sqrt) decides (0x6644e5..0x664503): under 47.0
##   (`[0xda0ef0]`, a float) the 8x8 `mm_sign_party.ddj` (+0x39c) at the offset;
##   47 or more the 16x16 `mm_sign_partyarrow.ddj` (+0x36c) at the offset scaled
##   to length 47 (`47.0 / dist`, the double at 0xda0ee8), turned by
##   -(theta + pi) where theta = acos(dx_px / dist) (0xb47c50 is acos), negated
##   when dz < 0, through 0x8b5c50 (cos 0xb44a10, sin 0xb44b40: a rotation).
##   In screen space (y down) that is atan2(oy, ox) - pi. READ.
## - One mark per member, every frame (vslot_013 is the draw), after the other
##   signs and the academy marks, then the quest marks (+0x3c0 questarrow,
##   +0x3c4 questnpc, 0x664ae6..; OpenSRO draws none), and the player's own
##   arrow (+0x374) last. READ.
##
## **The world map** (CNIFWorldMap::FUN_0061eec0, 0x61f8c0..0x61ffce): every
## member but the player (no world-id test there), at the same position
## source, placed by the map shown (round 786, HudWorldmap.party_pixel: a
## field member at its field position, a dungeon member at its dungeon's
## field point on a field map, or on its floor on that floor's map), as the
## 16x16 `wmap_sign_party.ddj` (+0x7ec) centred on its map
## pixel (corners +-8.0, 0xd89240, each truncated through 0xb42d10, _ftol2),
## drawn before the player's marker. The first member whose quad holds the
## mouse (each is tested until one hits, 0x61fec0; the quad less its half pixel
## and inset by 2.0, 0xe1b898) has the manager's text for it (map +0x28,
## 0x61b2f0) drawn centred above the quad, right after it (0x8b2f20 size,
## 0x8b48b0 draw at trunc(x - trunc(w / 2)), trunc(top - h)). READ, and so is
## the text: the member's name, `*Name` in a job party, set when the member is
## added (CharacterDependentData 0x99a2e0: 0x99a4c5..0x99a4c9, 0x99a5ce..0x99a673).

## **The quads draw their texture transposed** (READ): each party quad's
## corners go top-left, top-right, bottom-right, bottom-left (the dot,
## 0x664578..; the world map's, 0x61fd4e..) with the texture coordinates
## (0,0), (0,1), (1,1), (1,0) (`fldz` / `fld1` at 0x664544 and 0x664720;
## the world map's 0x61f9ee..0x61fa1d), a fan (D3DPT_TRIANGLEFAN, 6). So screen
## (x, y) samples texture (y, x): the art is mirrored about its diagonal before
## the turn. mm_sign_partyarrow's art points up (MEASURED), so it draws
## pointing west unturned, and the turn above sends it outward. A Control
## does the same with flip_h and a further -90 degrees (the transpose is
## R(-90) after a horizontal mirror): TRANSPOSE_TURN.
const TRANSPOSE_TURN := -PI / 2.0

const REGION_SPAN := 1920.0
## The minimap's dot/arrow switch and the arrow's rim radius, in map pixels.
const ARROW_RADIUS := 47.0
const DOT_SIZE := Vector2(8, 8)
const ARROW_SIZE := Vector2(16, 16)
const WORLD_DOT_SIZE := Vector2(16, 16)
const HOVER_INSET := 2.0
const DOT_DDJ := "interface\\minimap\\mm_sign_party.ddj"
const ARROW_DDJ := "interface\\minimap\\mm_sign_partyarrow.ddj"
const WORLD_DOT_DDJ := "interface\\worldmap\\wmap_sign_party.ddj"
## A region word with this bit is a dungeon (the record's +0x5a, as 0x9d5520
## tests it).
const DUNGEON_BIT := 0x8000

## The minimap offset, in map pixels from the aperture's centre (x east, y
## down), of a member at `member_local` seen from `player_local`; both are
## region-local ground positions (x east, z north) in the player's region.
static func minimap_offset(player_local: Vector2, member_local: Vector2, tile_px: float) -> Vector2:
	var d := member_local - player_local
	return Vector2(d.x, -d.y) / REGION_SPAN * tile_px

## True when the mark at `offset` is the rim arrow rather than the dot.
static func is_arrow(offset: Vector2) -> bool:
	return offset.length() >= ARROW_RADIUS

## Where the arrow's centre goes: the offset scaled to the rim radius.
static func arrow_centre(offset: Vector2) -> Vector2:
	var d := offset.length()
	if d <= 0.0:
		return Vector2.ZERO
	return offset * (ARROW_RADIUS / d)

## The arrow's turn (a Control's rotation, clockwise on screen):
## -(theta + pi) with theta the original's signed acos, which is
## atan2(oy, ox) - pi for an offset with y down.
static func arrow_rotation(offset: Vector2) -> float:
	return atan2(offset.y, offset.x) - PI

## A record's position in the player's region-local frame: region y steps
## world X and region x world Z (AGENTS.md), the record's y unused (0x9ecfd0
## is given y = 0).
static func record_local(player_region: Vector2i, region: int, x: float, z: float) -> Vector2:
	var rx := (region >> 8) & 0xFF
	var ry := region & 0xFF
	return Vector2(float(ry - player_region.y) * REGION_SPAN + x, float(rx - player_region.x) * REGION_SPAN + z)

## Whether the minimap draws `m` (0x6643bb..0x664419): not the player, the
## same world id, and a region the player can see (`region_visible`, the
## record's region and position as 0x9d5520 is given them). `player_region`
## is the player's region word (+0x7c: a field region id, or the dungeon's
## with bit 15), `same_floor` whether the record's position lies on the
## player's floor (World3D works it out; only asked for a dungeon record).
static func minimap_draws(m: PartyNet.Member, own_jid: int, own_world_id: int,
		player_region: int = 0, same_floor: bool = false) -> bool:
	if m == null or m.jid == own_jid:
		return false
	if m.world_id != own_world_id:
		return false
	return region_visible(m.region, player_region, same_floor)

## UI_SILKMALL::FUN_009d5520(region, pos) on the player (READ, asm
## 0x9d5520..0x9d561d): 1 for a field region (bit 15 clear) while the player
## is in the field (`+0x7c` without 0x8000); otherwise 1 only for the
## player's own dungeon region (`cmp di, [ecx+0x7c]`) when the block under
## the position (the region manager 0x111a02c, slot 0x2c) has the floor of
## the player's block (+0x74 slot 0x14 of +0x78): both through
## `[0x1103cc6]` slot 1, then the block's slot 2 -- the floor index
## ICPlayer::FUN_009d7880 reads the floor name with. A field member is never
## shown from a dungeon, nor a dungeon member from the field.
static func region_visible(member_region: int, player_region: int, same_floor: bool) -> bool:
	var member_dungeon := (member_region & DUNGEON_BIT) != 0
	var player_dungeon := (player_region & DUNGEON_BIT) != 0
	if not member_dungeon and not player_dungeon:
		return true
	if not member_dungeon or (member_region & 0xFFFF) != (player_region & 0xFFFF):
		return false
	return same_floor

## Whether the world map draws `m` at all: every member but the player (no
## world-id test, 0x61f8d3..0x61f8e4). Where, and whether the map shown
## takes it, is HudWorldmap.party_pixel's (round 786).
static func worldmap_draws(m: PartyNet.Member, own_jid: int) -> bool:
	return m != null and m.jid != own_jid

## The Donwhang cave's floor bands (CNIFWorldMap::FUN_00610ed0, READ, asm
## 0x610ed0..0x610f77): a height under 70.0 (the float at 0xd990a8) is
## level 0, under 210.0 (the double at 0xd990a0) level 1, under 350.0 (the
## float at 0xd9909c) level 2, else level 3.
const CAVE_BANDS := [70.0, 210.0, 350.0]

static func cave_level(y: float) -> int:
	for i in CAVE_BANDS.size():
		if y < CAVE_BANDS[i]:
			return i
	return CAVE_BANDS.size()

## Whether a dungeon floor's map (+0x97d0 == 2) draws a member whose record
## has `region` and height `y` (FUN_0061eec0, READ, asm 0x61fc00..0x61fd42):
## only a dungeon record (0x61fc00; a field member is not drawn on a floor),
## of the floor row's region id (column 16, row +0x88: `[0x62c030() +
## 0x84]` against `region & 0x7fff`, 0x61fce5..0x61fcf0), and for region 1,
## the cave, whose four floors share one region, only when the record's
## height falls in the floor's band: 0x610ed0(1, the row's floor number
## (+0x40, 1-based), region, &(x, y, z)) is `floor - 1 == cave_level(y)`.
static func floor_map_draws(map_region_id: int, map_floor: int, region: int, y: float) -> bool:
	if (region & DUNGEON_BIT) == 0:
		return false
	if map_region_id != (region & 0x7FFF):
		return false
	if map_region_id != 1:
		return true
	return map_floor - 1 == cave_level(y)

## Whether the mouse is on a world-map dot whose (truncated) quad is `quad`:
## the corners less the half pixel (0x61fe11..0x61fe88), then
## `mx >= v0.x + 2` and `v2.x - 2 >= mx` (0x61fecb..0x61ff2d), the same for y,
## with the mouse in whole pixels (`fild` of +0x7a4 / +0x7a8). On a quad at L
## that is L + 2 ..= L + 13.
static func hover_hit(quad: Rect2, mouse: Vector2) -> bool:
	var m := mouse.floor()
	var lo := quad.position - Vector2(0.5, 0.5) + Vector2(HOVER_INSET, HOVER_INSET)
	var hi := quad.end - Vector2(0.5, 0.5) - Vector2(HOVER_INSET, HOVER_INSET)
	return m.x >= lo.x and m.y >= lo.y and m.x <= hi.x and m.y <= hi.y
