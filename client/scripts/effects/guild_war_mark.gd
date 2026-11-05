extends RefCounted
class_name GuildWarMark

## The guild war mark (round 860): `res\etc\guild_war_mark.bsr` over every
## member of a guild at war, for everyone who sees them -- the player's own
## guild included. Labels: READ (sro_client.exe c:, SR_GameServer.exe s:),
## MEASURED, INFERRED, OURS, OPEN.
##
## THE RULE (READ, CICUser::vslot_009 -> FUN_009ddb00, every frame, the own
## player too): the body's guild id is in the client's "at war" set
## (0xeedc04, FUN_009dd8a0), its job state is 4 -- no job suit (vtable slot
## 43, +0xac -> c:0x9c7a60 returns byte +0x50d: the constructor's 4,
## c:0x9d2d97; the slot-8 suit's 1..3, c:0x9db8b0) -- and the player does not
## stand in a fortress whose war is on (c:0x939a60, INFERRED; never so here:
## OpenSRO has no fortress war) -> the mark (bit 4 of +0x7b5) goes on. A
## guild not in the set -> off. A suit or the fortress test leaves it as it
## was (the original's quirk, kept). The free-PvP marks come first and the
## helper mark after it (not built here).
##
## THE SET (READ): 0x30EF {u8 op, u32 guild} (c:0x88a770; op 0 add, 1
## remove), the spawn's guild block war flag (c:0x9de046) and 0x30FF's
## (0 add, 1 remove), and 0x3109 with any war (the own guild, c:0x99ac71).
## NetClient.war_guilds keeps it. So "at war" means at war with anyone, not
## hostile to the viewer.
##
## THE LOOK (MEASURED, skilleffect.txt): SYSTEM_GUILD_WAR_MARK's ACT_L row,
## AT_LOOP, `res\etc\guild_war_mark.bsr` at bone `*`, offset 0,16,0; it is
## started with only its sustained rows (c:0x9cf982) and kept until the bit
## goes off. `*` (READ, IDecoSkill::FUN_00a4a680 flags 3 and FUN_009c7780):
## the body's turn, the offset times the body's scale, plus the body's
## height -- 20 x the characterInfo Size column x 0.5 (.rdata 0xe1b7d0) x
## the scale. A player (Size 2, MEASURED) wears it 36 above the feet.
##
## Round 862: the file has no mesh (MEASURED, Data.pk2: no .bms, only an
## `ambient` particle set) -- its whole look is `map\guild\guild_war_mark.efp`
## at 0,3,0 in the object's frame, which AuraModel now plays (round 860's
## mark drew nothing). So the efp's origin stands 39 above a player's feet.
## MEASURED: the mark appears on every member's body in the same frame,
## ~0.9 s after the target master's OK; its red glow swells and fades on a
## ~2.0 s cycle (the efp's own); a GM-invisible member still wears it; the
## enemy guild's line on the plate turns red, the own stays orange.

const EFFECT := "SYSTEM_GUILD_WAR_MARK"
## UserSpawnNet.JOB_STATE_NONE: the job state slot 43 must answer.
const NO_SUIT := 4
const ON := 1
const OFF := 0
const KEEP := -1

## FUN_009ddb00's answer for one body.
static func decide(guild_id: int, war_set: Dictionary, job_state: int, fortress_war: bool = false) -> int:
	if guild_id == 0 or not war_set.has(guild_id):
		return OFF
	if job_state != NO_SUIT or fortress_war:
		return KEEP
	return ON

## `*`'s height above the body's foot in the body's units (READ, see the
## header): 20 x Size x 0.5; the body's scale applies on top.
static func star_height(size: float) -> float:
	return 20.0 * size * 0.5

## The mark's row, {path, bone, offset}, or {} without one.
static func row() -> Dictionary:
	for r in SkillEffects.rows_named(EFFECT, SkillAudio.ACT_L, true):
		if int(r.get("kind", 0)) == SkillEffects.KIND_BSR:
			return {"path": String(r["path"]), "bone": String(r["bone"]), "offset": r["offset"]}
	return {}
