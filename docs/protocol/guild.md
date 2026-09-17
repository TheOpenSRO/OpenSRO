# Guilds

What the engine enforces about guilds, recovered from `SR_GameServer.exe`.
Implemented in `server/internal/guild`.

srrevamp already had a guild system — persistent membership, create/join/leave —
and parts of it were grounded earlier: the per-level member capacity and the
permission bitmask. This page is that plus what a second pass, using the
error-code table, added.

## The method, stated once

`docs/protocol/error_codes.md` names 89 codes matching `GUILD`, and **68 server
functions return one**. Annotating each returned code with its client name turns
an anonymous branch into a labelled requirement. Every number below came from
reading the comparison immediately above a named refusal.

## Size and level

| | value | evidence |
|---|---|---|
| **name length** | **2 to 12** | `if (len - 2u < 0xb)` in the create handler `FUN_00514ce0`; the else branch raises `0x4c18` `GUILDERR_INVALID_GUILDNAME_LEN` |
| **max level** | **5** | `cmp al,0x5; jb` in `FUN_005c63d0`; a level-5 guild is refused with `0x4c21` `ERROR_GUILD_LEVEL_UP_FULL` |
| **members by level** | 15, 20, 25, 35, 50 | five dwords at `.rdata 0x00ade8dc`, compared by the "is this guild full" predicate `0x005d0fb0` |

**The max level and the capacity table confirm each other.** The table's length
was fixed by a bounds assert in the fullness predicate; the cap of 5 comes from
a different function entirely. Two independent readings landing on the same
number is what makes either one safe to rely on.

The name length corrects a value srrevamp had as own design (`32`). The
**minimum** matters more than the maximum: srrevamp enforced none, so a
one-character guild name was legal here and is not in the engine.

## Levelling up — `FUN_005c63d0`, cost in `FUN_005c6240`

	if (!IsAlive())          -> 0x4c07  GUILDERR_IM_DEAD
	if (guildID == 0)        -> 0x4c0d
	if (!IsGuildMaster())    -> 0x4c1e  GUILDERR_PERMISSION_DENIED
	if (level >= 5)          -> 0x4c21  ERROR_GUILD_LEVEL_UP_FULL
	cost = CheckLevelUpCost(level)      <- the CURRENT level, confirmed in asm
	if (not enough gold)     -> 0x4c31  ERROR_GUILD_LEVEL_UP_GOLD_DEFICIT
	if (not enough GP)       -> 0x4c32  ERROR_GUILD_LEVEL_UP_GP_DEFICIT

The index is the **current** level, not the target — the disassembly saves
`GetLevel()`'s result and pushes that same byte:

	5c6434  cmp  al,0x5
	5c6436  mov  BYTE PTR [esp+0x8],al
	5c643a  jb   0x5c6445
	...
	5c6445  mov  eax,DWORD PTR [esp+0x8]
	5c6449  push eax
	5c644c  call 0x5c6240

so the table reads "to advance **from** this level".

| from level | gold | guild points |
|---:|---:|---:|
| 1 | 3,000,000 | 5,400 |
| 2 | 9,000,000 | 50,400 |
| 3 | 15,000,000 | 135,000 |
| 4 | 21,000,000 | 378,000 |

Gold lives in a **64-bit** table at `.rdata 0x00ade918`, indexed
`&DAT_00ade910 + level*8`; the high dword is zero for all four. Guild points are
dwords at `.rdata 0x00ade8f0`, indexed `&DAT_00ade8ec + level*4`. The switch
accepts only levels 1–4, which is what keeps index 0 — holding `3` and `6`, not
gold — from ever being read.

### This settles a question the code explicitly left open

`server/internal/guild` used to say, of the dwords after the capacity table:

> The three dwords that follow it (5400, 50400, 135000) look like a guild-
> experience curve and are NOT claimed here — nothing read so far uses them.

They are the **guild-point level-up costs**, there are **four** of them (378,000
sits past where that pass looked), and `FUN_005c6240` is the use-site.

Declining to claim them was the right call, and worth keeping as an example: a
guild-experience curve and a level-up cost table are literally the same numbers
in the same place. Only the use-site separates them, and the earlier pass did not
have it.

## Gold is 64-bit

The cost check is a 64-bit comparison spelled out in two halves:

	charHi = *(int *)(char->inventory + 0x7c);
	if (charHi <= costHi && (charHi < costHi || *(uint *)(… + 0x78) < costLo))
	    return GOLD_DEFICIT;

so a character's gold is a 64-bit value at `+0x78` (low) and `+0x7c` (high), and
the engine really does compare all of it. Guild points are a dword at
`guild + 0x3c`.

## Permissions

Unchanged from the earlier pass and recorded here for completeness: each member
carries a 32-bit mask at `member->rec + 0x54`, tested by `FUN_005d0f80` with
`(mask & required) == required` — **every** bit of the requested mask must be
set.

**Its storage is now named too**: `_GUILDMEMBER.Permission`
(`docs/protocol/db_columns.md`), beside `Contribution`, `GP_Donation`,
`CharLevel`, `GuildWarKill`, `GuildWarKilled`, `Nickname` and `SiegeAuthority`.
`SiegeAuthority` is a separate column from `Permission`, so the fortress-war
rights the siege system checks are **not** bits of this mask.

Three bits are named from the errors their call sites raise:

| bit | gates | raised by |
|---|---|---|
| `0x01` | invite | `FUN_00514f10`, which also raises `GUILDERR_MEMBER_FULL` |
| `0x08` | the guild warehouse | `FUN_005c7440`, `FUN_005c74d0`, raising `GUILD_WAREHOUSE_LIMIT` |
| `0x10` | the notice and title | `FUN_005c6480`, raising `GUILDERR_INVALID_MASTER_COMMENT` and `_TITLE` |

**Bit `0x04` is required at two call sites whose handlers raise no error code**,
so nothing names it. Bits 1 and 5–31 are not observed at any call site, which is
an absence of evidence rather than evidence of absence.

## Opcodes

`0xb0f0` is the guild-create response (`FUN_00514ce0` sends it on both the
penalty path and the length-refusal path).

## What is not recovered

- **The alliance rules.** `FUN_005c6550` (433 bytes) carries
  `CANT_ALLY_TO_OWN_GUILD`, `CANT_FIND_TARGET_GUILD` and more, and has not been
  read. Unions holding eight guilds is a long-standing note in this project that
  no read has confirmed.
- **Guild war.** `FUN_005c6b60` (1,102 bytes) and the `GUILDWARERR_*` family.
- **The warehouse.** Only the permission bit and `GUILD_WAREHOUSE_LIMIT` are
  known; the limit's value is not.
- **Guild points: where they come from.** The costs above are grounded; what
  earns a guild a point is not.
