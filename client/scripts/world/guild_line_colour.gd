extends RefCounted
class_name GuildLineColour

## Round 842: the colour of a character's guild line, by its guild's relation
## to the player's (docs/protocol/guild_plate.md, "Colour"). READ from
## sro_client.exe:
##
## - Every character's line of one guild is ONE shared plate item: the guild
##   manager 0xeeef70 keeps a refcounted entry per guild NAME (its map at +8,
##   looked up by FUN_009a4090), whose plate item is entry +0x20
##   (FUN_009a4f40 makes it once, FUN_009a4650 releases it). A character's
##   line (CICUser +0x7c4) is that entry.
## - When the entry is made, its colour is (FUN_009a4f40, 0x9a5045..0x9a5084):
##   0xffa0fe68 when the guild name is in the union map (FUN_00996d60 on
##   CharacterDependentData 0xeeebd8: its record +0x148, map +0x94 -- asserted
##   "IsAllianceGuild" in CharacterDependentData::FUN_00999120), else
##   0xffff0000 when it is in the hostile list (FUN_00992a90, the list at +0xa4 --
##   "IsHostileGuild(sGuildWarDef...)" in FUN_00999260, filled by 0x3109),
##   else 0xff66b9ff.
## - The own player's line (FUN_009dc460, an exact CICPlayer -- FUN_00b94b70
##   on 0xef1b44 -- at 0x9dc4c2) then recolours ITS entry 0xfffead2e
##   (0x9dc4d4: `mov ecx,[eax+0x20]; push 0xfffead2e; call 0x8b2b70`). Being
##   shared, that recolours every line of the player's guild: a fellow
##   member's line is orange like the player's own.
## - Every line is recoloured the same way (FUN_009a4450: each entry by the
##   two lists, then the own player's entry orange, 0x9a44d4) after 0x3102
##   (FUN_0087fd00), 0x3109 (FUN_0087fd90), the guild block 0x34B4
##   (0x885794) and 0x38F5 types 2, 3, 0x0d, 0x12, 0x19, 0x1c and 0x23
##   (FUN_00887330: 0x887710, 0x8879a7, 0x887c0c, 0x88810f / 0x888124,
##   0x888207, 0x8886ff, 0x888a6c).
## Colours are ARGB in the binary, opaque.
const OWN := Color8(0xfe, 0xad, 0x2e)
const ALLY := Color8(0xa0, 0xfe, 0x68)
const HOSTILE := Color8(0xff, 0x00, 0x00)
const OTHER := Color8(0x66, 0xb9, 0xff)

## The line's colour for a character of `guild_name`, with `own_guild_name`
## the player's guild ("" none), `allied` the union's test (Callable(name)
## -> bool, or null) and `hostile` the war list's (the same; OpenSRO has no
## guild wars, so it is null: OPEN). The own player's own line passes its
## own guild name and is OWN.
static func colour_for(guild_name: String, own_guild_name: String, allied: Callable = Callable(), hostile: Callable = Callable()) -> Color:
	if guild_name != "" and guild_name == own_guild_name:
		return OWN
	if allied.is_valid() and bool(allied.call(guild_name)):
		return ALLY
	if hostile.is_valid() and bool(hostile.call(guild_name)):
		return HOSTILE
	return OTHER
