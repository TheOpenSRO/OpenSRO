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

## Alliances (unions) — RECOVERED 2026-09-17

`FUN_005c6550` (433 bytes) is the alliance request. It was listed below as not
read; it surfaced as one of the 62 single-vocabulary functions the widened
error-code scan located (`client/tools/re/errsites.py`), every code it raises
being a `GUILDERR_`. Implemented in `server/internal/guild/alliance.go`.

### The cap is 8, and the long-standing note is now confirmed

This page said: *"Unions holding eight guilds is a long-standing note in this
project that no read has confirmed."* It is now read **four ways**, none of them
a curve:

1. The slot setter (`CMainProcess::FUN_005b8c70`) asserts the index before
   writing: `if (7 < index) Assert_BreakIfDebugger();`, then
   `alliance[+0x1c + index*4] = guildID`.
2. The slot clearer (`FUN_005b8cf0`) carries the same assert.
3. That function's loop runs `0 .. 7` inclusive, exiting on `if (7 < i) return 1`
   — a **traversal**, not a defensive guard.
4. The membership scan (`FUN_005b8e90`) is a literal
   `do { ... } while (i < 8);` over the same array.

So the alliance record holds a fixed array of **eight** guild ids at `+0x1c`.
Two of the four witnesses are code the engine actually walks, which is the
difference between a bound and an assumption. `7 < index` is this engine's usual
`limit-1 < value` idiom.

**It is a fixed array, not a list.** The setter refuses an occupied index with
its own log line — `"Anohter Alliance guild is set in that index!!"`, the
engine's typo — so a guild occupies a *slot*, and leaving frees that slot rather
than compacting the array.

### Both guilds must be level 2

	if (GetLifeState() != 1)            -> 0x4c07  GUILDERR_IM_DEAD
	if (myGuild == 0)                   -> 0x4c0d
	if (!IsGuildMaster())               -> 0x4c1e  PERMISSION_DENIED
	if (myGuild.GetLevel() < 2)         -> 0x4c2a  TOO_LOW_CREATOR_ALLIANCE
	if (target has no guild)            -> 0x4c25  CANT_FIND_TARGET_GUILD
	if (targetGuild == myGuild)         -> 0x4c26  CANT_ALLY_TO_OWN_GUILD
	if (targetGuild.GetLevel() < 2)     -> 0x4c2b  TOO_LOW_JOINER_ALLIANCE
	if (target already in an alliance)  -> 0x4c28  TARGET_GUILD_HAS_ALLIANCE_ALREADY
	if (!target.IsGuildMaster())        -> 0x4c24

**The two level checks are what makes this safe to read.** They are the same
comparison against the same constant on two different objects, and on its own
that is exactly the kind of symmetry a reader invents a story about. The client's
names settle it: the requester's failure is `TOO_LOW_CREATOR_ALLIANCE` and the
target's is `TOO_LOW_JOINER_ALLIANCE`, and each matches the object whose
`GetLevel()` was called. The error table is doing the work an independent
witness would otherwise have to.

### Two codes the server never raises

`0x4c27 ALREADY_ALLIED` and `0x4c29 ALLIANCE_FULL` are in the client's message
table and are **not materialised anywhere in `SR_GameServer.exe`** — checked
with the widened scan, which finds `0x4c2a` in this very function, so the probe
is known to work on this family.

That does not mean the rules do not exist; the cap is enforced by the array
bound above, and `ALREADY_ALLIED` is implied by `TARGET_GUILD_HAS_ALLIANCE_ALREADY`.
It means **the engine refuses these two conditions structurally rather than by
returning a code**, and the client carries messages it may never receive. Both
are kept in `alliance.go` so the vocabulary is complete and nobody re-derives
their absence.

## Guild war — RECOVERED 2026-09-17

`FUN_005c6b60` (1,102 bytes) is the declaration handler, located the same way the
alliance was: every code it raises belongs to one vocabulary. Implemented in
`server/internal/guild/war.go`.

### The cap is 50, and the decompiler says 49

Ghidra renders the check as `if (0x31 < (byte)guild[0x11])`, which reads as a cap
of **49**. The instructions say otherwise:

	005c6ddd  mov eax,DWORD PTR [esi+0x44]
	005c6de0  cmp al,0x32                  ; 50
	005c6de2  jb  0x5c6dfe                 ; proceed only while count < 50
	005c6df5  mov ax,0x4c3e                ; GUILDWARERR_MAX_HOSTILE_GUILD

`0x31 <` is Ghidra's rewriting of `< 0x32`. **This is the second `limit-1 < value`
shape in this document that has had to be read in assembly to get the limit
right** — the alliance array's bound appears as `7 < index` for an array of 8.
The rule that falls out: when the decompiler shows a bound as `N < x`, the
engine's own constant is `N+1`, and the assembly is what to quote.

The check runs on **both** guilds at the same offset, with two refusals —
`GUILDWARERR_MAX_HOSTILE_GUILD` (`0x4c3e`) for the declarer and
`GUILDWARERR_TARGET_MAX_HOSTILE_GUILD` (`0x4c3f`) for the target. Same
construction as the alliance level check, and safe for the same reason: the
client's names say which side each identical comparison is about.

### The declaration ladder

	if (target resolves to no guild)     -> 0x4c25  CANT_FIND_TARGET_GUILD
	if (out of range)                    -> 0x4c60  ERR_COMMON_TOO_FAR
	if (!IsGuildMaster())                -> 0x4c1e  PERMISSION_DENIED
	if (myHostiles   >= 50)              -> 0x4c3e  MAX_HOSTILE_GUILD
	if (theirHostiles >= 50)             -> 0x4c3f  TARGET_MAX_HOSTILE_GUILD
	if (already at war with them)        -> 0x4c3a  ENEMYGUILD
	if (same alliance)                   -> 0x4c41  ALLYGUILD
	if (inside the battle arena)         -> 0x4c7a  ARENA_ERR_FREQUEST_WAR_IN_BATTLE_ARENA

**A war is declared in person** — there is a range check — but its value is not
recovered: the distance is computed by a helper rather than compared against a
literal.

**An ally cannot be a war target**, so the two systems recovered this week are
mutually exclusive on the same pair of guilds.

### `guild + 0x44` is the hostile count, named by two refusals

	FUN_005c6b60  count >= 50  -> GUILDWARERR_MAX_HOSTILE_GUILD
	FUN_005c6870  count != 0   -> GUILD_ERROR_BREAK_WAR (0x4c46)

A state enum would not be compared against 50, and a flag would not need a byte.
**No writer was found**: every access to that offset inside the guild module is a
comparison, so the count is maintained somewhere this pass did not reach — most
likely rebuilt from the `_GUILDWAR` rows on load. Stated as a gap rather than
guessed.

### A war is wagered and timed, not a flag

`DB_Bind__GUILDWAR` (`0x0084dd90`) binds `WarType`, `VictoryPointIndex`,
**`LodgedGold`**, `WarEndTime`, two `Guild` columns and two `PointGain` columns,
plus `Data1`/`Data2` (already listed in `docs/protocol/db_columns.md`, which
deduplicates the paired names).

So a war has a type, a victory-point index, **staked gold**, an end time and a
per-side score. Recorded because the shape rules out the simplest reading: a war
is not a boolean between two guilds, and an implementation that starts there
will have to be undone.

## What is not recovered

- **The war range**, and what `WarType`, `VictoryPointIndex` and the two `Data`
  columns hold.
- **What maintains `guild + 0x44`.**
- **The warehouse.** Only the permission bit and `GUILD_WAREHOUSE_LIMIT` are
  known; the limit's value is not.
- **Guild points: where they come from.** The costs above are grounded; what
  earns a guild a point is not.
