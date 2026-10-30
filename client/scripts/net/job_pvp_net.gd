extends RefCounted
class_name JobPvpNet

## Round 802: job PvP and safe trade on the client (docs/protocol/jobs.md,
## "Job PvP" and "Safe trade"). READ in sro_client.exe unless a line says
## otherwise:
## - a click on another player attacks only when he is already the
##   selection or Alt is held (GetKeyState 0x12), and IsEnemy(Alt) holds
##   (c:0x792f00 -> c:0x9de780): job opposition on the spawn's job state
##   (c:0x9d02c0: a trader or hunter against a thief, either way round), or
##   Alt unless both wear a job suit (is_enemy); a party member is never
##   attacked, and below level 20 the click says 0x3016 and sends nothing;
## - the opposed player's name is drawn 0xffff6262, decided by the viewer's
##   own worn suit (c:0x9cfd50);
## - another player's job state is written only by the spawn reader
##   (c:0x9de3d6 -> vslot 44); the 0x3038 handler only re-dresses him;
## - 0x34D5 {u8 status, u8 code[, u8 count, u8 num]} (UI_SAFETRADE
##   c:0x891080): status 1 puts the board's kind-0xb entry up
##   (FUN_00777f20(0xb, 0, 1): icon\etc\icon_safetrade_progress.ddj, tooltip
##   UIIT_STT_SAFETRADE_PROGRESS, no gauge, c:0x7ff32f / c:0x802589 /
##   c:0x805a40), and code 0x50 shows UIIT_MSG_SAFETRADE_PROGRESS with
##   count / num on the warning banner (c:0x77b580); status 0 takes the
##   entry down, and code 0x41 writes UIIT_MSG_SAFETRADE_NUMBER_ERR_LIMIT to
##   the system lines (c:0x7781b0(0, ...)).
## OPEN: the banner is skipped while a byte at +0x20fc of the object at
## c:0xeef5ec is set; what that byte is was not read, and it is not modelled.
## OURS, disclosed: the attack request names its target kind by a trailing
## byte of OpAttack, and the zone hears a blow on a player or a COS by
## OpPlayerStruck 0x0118 (session/jobpvp.go), the struck player's own copy
## carrying what his death cost.

const OP_PLAYER_STRUCK := 0x0118
const OP_SAFE_TRADE := 0x34D5

## OpAttack's trailing target kind (session/jobpvp.go).
const TARGET_CHARACTER := 3
const TARGET_COS := 4

const STATE_TRADER := 1
const STATE_THIEF := 2
const STATE_HUNTER := 3
const STATE_NONE := 4

const PK_MIN_LEVEL := 20

## The server's COS uid range (session/cosworld.go cosUIDBase, OURS; the
## NPCs' begin at 0x7f000000).
const COS_UID_BASE := 0x7e000000
const NPC_UID_BASE := 0x7f000000

static func is_cos_uid(id: int) -> bool:
	return id >= COS_UID_BASE and id < NPC_UID_BASE

## The hostile name colour (c:0x9cfd50).
const ENEMY_NAME_COLOUR := Color8(0xff, 0x62, 0x62, 0xff)

const SAFE_GRANTED := 0x50
const SAFE_LIMIT := 0x41
const SAFE_LOST := 0x40
const SAFE_AT_LOGIN := 0x51
const SAFE_ICON := "icon\\etc\\icon_safetrade_progress.ddj"
const SAFE_TOOLTIP_KEY := "UIIT_STT_SAFETRADE_PROGRESS"
const SAFE_PROGRESS_KEY := "UIIT_MSG_SAFETRADE_PROGRESS"
const SAFE_LIMIT_KEY := "UIIT_MSG_SAFETRADE_NUMBER_ERR_LIMIT"
## The board token of the safe-trade entry (OURS: the board keys entries by
## a token; a server buff token is positive, an item grant's negative id).
const SAFE_BOARD_TOKEN := -0x34D5

const YOUR_LEVEL_LOW_KEY := "UIIT_MSG_SKILL_USE_FAIL_YOUR_LEVEL_TOO_LOW_TO_PK"

## c:0x9d02c0's matrix: a trader or hunter against a thief, either way.
static func opposed(a: int, b: int) -> bool:
	var a_side := a == STATE_TRADER or a == STATE_HUNTER
	var b_side := b == STATE_TRADER or b == STATE_HUNTER
	return (a_side and b == STATE_THIEF) or (a == STATE_THIEF and b_side)

## IsEnemy(alt) for another player (CICUser vslot 42, c:0x9de780): job
## opposition first (c:0x9d02c0 on the spawned states); then, while either
## side has no PvP cape (FUN_009db210, never in OpenSRO), two players who
## both wear a job suit in slot 8 (FUN_009daf50(8) on each, FUN_00666e60 --
## INFERRED: the suit test) are no enemies whatever is held; otherwise Alt
## makes one. OpenSRO has no teams, fortress war, capes or murder list, so
## those branches never apply.
##
## Round 844 (lane V): after Alt, a player whose guild is in the hostile list
## (FUN_00992a90 on the target's guild, 0x9de8f4..) is an enemy without Alt
## -- `hostile_guild` (the caller rules out the own guild, the 0x10 branch).
static func is_enemy(own_state: int, their_state: int, alt: bool, both_suits: bool, hostile_guild: bool = false) -> bool:
	if opposed(own_state, their_state):
		return true
	return (alt or hostile_guild) and not both_suits

## c:0x792f00's player branch: "attack" (send it), "select", "party" (no
## attack), or "level" (0x3016, nothing sent).
##
## Round 844 (lane V): the level rule is waived while the guild is at war
## (0x3016 only with the hostile map empty, 0x988a70) -- `at_war`.
static func player_click(is_selection: bool, alt: bool, enemy: bool, party_member: bool, own_level: int, at_war: bool = false) -> String:
	if not (is_selection or alt) or not enemy:
		return "select"
	if party_member:
		return "party"
	if own_level < PK_MIN_LEVEL and not at_war:
		return "level"
	return "attack"

## Whether a name is drawn in the hostile colour: the viewer's worn suit's
## state against the other's spawned state (c:0x9cfd50).
static func enemy_name(own_suit_state: int, their_state: int) -> bool:
	return opposed(own_suit_state, their_state)

## OpAttack with the trailing kind.
static func encode_attack(character_name: String, target: int, kind: int) -> PackedByteArray:
	var out := CombatNet.encode_attack(character_name, target)
	out.append(kind)
	return out

## OpPlayerStruck: {} when short.
static func decode_struck(data: PackedByteArray) -> Dictionary:
	if data.size() < 22:
		return {}
	var flags := data[13]
	var d := {
		"attacker": data.decode_u32(0),
		"cos": data[4] == 2,
		"target": data.decode_u32(5),
		"damage": data.decode_s32(9),
		"critical": flags & 1 != 0,
		"blocked": flags & 2 != 0,
		"died": flags & 4 != 0,
		"hp": data.decode_s32(14),
		"max_hp": data.decode_s32(18),
		"exp_lost": 0,
		"own": false,
	}
	if data.size() >= 30:
		d["exp_lost"] = data.decode_s64(22)
		d["own"] = true
	return d

## 0x34D5: {} when short.
static func decode_safe_trade(data: PackedByteArray) -> Dictionary:
	if data.size() < 2:
		return {}
	var d := {"status": data[0] == 1, "code": data[1], "count": 0, "num": 0}
	if data[0] == 1 and data.size() >= 4:
		d["count"] = data[2]
		d["num"] = data[3]
	return d

## The banner line for a 0x34D5 (the handler's swprintf of %d / %d), or ""
## when it shows none. `format` is the archive's text for the key.
static func safe_trade_banner(d: Dictionary, format: String) -> String:
	if not bool(d.get("status", false)) or int(d.get("code", 0)) != SAFE_GRANTED or format == "":
		return ""
	var out := format
	for v in [int(d["count"]), int(d["num"])]:
		var at := out.find("%d")
		if at < 0:
			break
		out = out.substr(0, at) + str(v) + out.substr(at + 2)
	return out.strip_edges()
