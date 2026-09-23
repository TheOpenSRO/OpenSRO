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
**minimum** matters more than the maximum: srrevamp used to enforce none, so a
one-character guild name was legal here and is not in the engine.

**Enforced since round 481.** Both stores' `Create` (`MemStore`, `SQLStore`)
refuse a name outside 2–12 with `guild.ErrInvalidNameLength`, which the session
layer reports as `guild name must be 2 to 12 characters`. The order is the
engine's: the handler's pre-check `FUN_00514b20` refuses a character already in
a guild first (`pc[0x72f] != 0` → `0x4c17`
`GUILDERR_MEMBER_OF_ANOTHER_GUILD`), then the handler tests the length; `0x4c1a`
`GUILDERR_SAME_GUILDNAME_EXIST` is raised by no function in the game-server
dump, so uniqueness is settled after both, by the job the handler sends on
(`FUN_005c5f90` → `SendOlappedGuildJobReqToSM`). `FUN_005c5f90` also refuses an
empty name with `0x4c18` on its own, a second guard the length test already
covers.

One divergence remains, in the unit: the engine's name is a narrow
`std::string` (initialised with capacity `0xf`, the MSVC small-string buffer of
a `char` string), so it counts bytes in the client's codepage; Go's `len()`
counts UTF-8 bytes, which is what srrevamp's client sends. ASCII names agree;
a non-ASCII name can be refused here that the engine would accept.

## Founding a guild — `FUN_00514b20` (round 487)

`CGuildManager::HandleCreateGuild` (`0x00514ce0`) calls `FUN_00514b20` before
it reads the name, and goes on to the length test only when it answers 1.
`in_EAX` is the founder's `GObjPC`. The whole function is seven tests, and the
create job's reply adds an eighth step, the payment:

| step | engine test | refusal | srrevamp |
|---|---|---|---|
| 1 | `*(char *)(in_EAX[0xc] + 4) == 1`, the character lock | `0x4c09`, not in the client's message table | not modelled: no lock to hold (`char_lock.md`, "For srrevamp") |
| 2 | vtable `+0xf8` `IGObj::GetLifeState` `!= 1` | `0x4c07` `GUILDERR_IM_DEAD` | **enforced**, with HP ≤ 0 standing in for dead |
| 3 | vtable `+0x124` `IGObj::GetLevel` `< 0x14` | `0x4c0a` `GUILDERR_TOO_LOW_CREATOR_LEVEL` | **enforced**: `guild.MinCreatorLevel` = 20 |
| 4 | 64-bit gold at `in_EAX[0xd] + 0x78/+0x7c` `< 500000` | `0x4c0c` `GUILDERR_NOT_ENOUGH_GOLD` | **enforced**: `guild.CreateGoldRequired` = 500,000 |
| 5 | vtable `+0x11c` `IGObj::GetJobState` `!= 4` | `0x4c57` `UIIT_CTL_GUILD_CREATE_JOB_ERROR` | not modelled: srrevamp has no job state |
| 6 | `GObjPC::FindTimedJob(2,1)` finds one | `0x4c3c` `GUILDWARERR_GUILD_CREATE_PENALTY` | not modelled: srrevamp has no penalty timer |
| 7 | `in_EAX[0x72f] != 0`, already in a guild | `0x4c17` `GUILDERR_MEMBER_OF_ANOTHER_GUILD` | **enforced** already: the stores' `ErrAlreadyInGuild` |
| 8 | the create job's reply spends 500,000 | none | **enforced**: `DeductGold` after `Create` |

The gold test is a 64-bit compare written in halves:

	iVar1 = *(int *)(in_EAX[0xd] + 0x7c);
	if ((iVar1 < 1) && ((iVar1 < 0 || (*(uint *)(in_EAX[0xd] + 0x78) < 500000))))
	    return 0x4c0c;

That is the same `+0x34` object (`in_EAX[0xd]`) and the same `+0x78/+0x7c` pair
that `CGuild::CheckLevelUpCost` (`0x005c6240`) reads gold from (see "Gold is
64-bit" below).

**The check does not spend the gold. The create job's reply does.** When the
handler's length test passes, `FUN_005c5f90` logs `"Name: %s (CurGold: %I64d)"`
and calls `SendOlappedGuildJobReqToSM(pc, 0, 0)`. Job 0's reply is case 0 of
`trs_sm_guildjob::FUN_005c8990`, which is `trs_sm_guildjob::FUN_005c8bf0`. That
function reads the gold at `+0x78/+0x7c`, calls `GObjPC::FUN_004e4140`, logs
`"Gold: %I64d ==> %I64d"` under event `0x3d`, and sends `0xb0f0`, the
guild-create response. `FUN_004e4140` is two virtual calls, and `FUN_005c8bf0`
is its only caller (`srv.asm`, `5c8c39 call 0x4e4140`):

	4e4148  push 0x0
	4e414a  push 0x1
	4e414c  push 0x4
	4e414e  push 0xffffffff        ; high dword
	4e4150  push 0xfff85ee0        ; low dword: together, int64 -500000
	4e4157  call [vtable+0x16c]    ; IGObj::OffsetGold
	...     call [vtable+0x274]    ; IGObj::BackupData(0x80, 0)

So founding **costs** 500,000. The gold is taken on the reply to the same job
that settles the name's uniqueness (see above), so only a guild that was
actually created is paid for. The evidence that it is the SUCCESS reply only
(round 490): `trs_sm_guildjob::FUN_005c8990` has exactly one caller,
`trs_sm_guildjob::vslot_002` (`0x0046e090`); the job's other two exits,
`vslot_003` (`0x0046e800`) and `OnTimeout` (`0x0046e7e0`), both go to
`trs_wait_response::FUN_005cc8d0`, whose case 0 (the create job) is
`FUN_005ccb50` -- that logs game event `0x3e` and reads no gold.
`OffsetGold`'s other three arguments (`4, 1, 0`) are not interpreted here.

The other 500,000 in the guild module is `FUN_005d0e00`'s. It belongs to
`FUN_005c7900`, which refuses a guild below level 4 (`0x4c52`) before calling it.
That is a guild service, not founding.

**What srrevamp does.** `session.handleGuildCreate` reads the founder and calls
`guild.CheckCreator(HP > 0, Level, Gold)` before `guilds.Create`. That call covers
steps 2 to 4, in the engine's order. `guilds.Create` then covers step 7 and the
length test. After `Create` succeeds, the handler takes
`guild.CreateGoldRequired` with `DeductGold`. The replies use our own wording:
`cannot found a guild while dead`,
`a guild founder must be at least level 20` and
`founding a guild requires 500000 gold`.

**srrevamp's own handling, not the engine's: the rollback.** The engine's
`OffsetGold` has no refusal path. srrevamp's `DeductGold` does: it fails if the
gold was spent between the check and the deduction. A guild left standing then
would have been founded for free. So the handler calls `guilds.Leave` for the
founder, which disbands a guild once its last member leaves, in both stores. It
then replies with the not-enough-gold message. There is one window: a second
character could join the new guild by id before the rollback runs, and then
`Leave` hands that character the leadership instead of disbanding.

**The client's purse.** The server sends no gold update, just as it sends none
after a shop buy. The client re-reads the character's stats when a create
succeeds (`World3D._on_guild_create_result`), the same way the shop window does
after a purchase.

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

## Where guild points come from (round 272)

They are the **skill points a member earns**, one for one. `GObjPC_GainExpAndLevel`
(`0x4e5250`), right after converting skill experience into whole points at 400:1
and granting them through slot 93, does

	if (points > 0 && pc[0x72f] /* the guild */ != 0) {
	    pc[0x861] += points;                 // pc+0x2184, the pending guild points
	    if (pc[0x861] > 9) { CGuildManager::RequestAddGuildPoints(pc[0x861]); pc[0x861] = 0; }
	}

`RequestAddGuildPoints` (`0x5c62e0`) requires a count above zero
(`5c62e3 cmp [esp+0x14],0; ja`), a living character (`5c62fe` vtable `+0xf8`,
`IGObj::GetLifeState`, compared with 1 at `5c6308`; `0x4c07`
`GUILDERR_IM_DEAD` otherwise), a guild (`pc+0x1cbc`, `0x4c0d`) and a guild
level of 5 or below (`5c6335 cmp al,0x5; ja`), and sends **`0x78F7 {byte,
guild id, member id, points}`** to the global server; the game server later
receives the echo and `CGuild::AddPoints` (`0x5c4110`, from the `0x5c9bd0`
inter-server dispatcher through `0x5ca500`) adds the count to **the guild's
total at `guild+0x3c`** (dirty bit 8) and to **the member's `GP_Donation` at
`member+0x40`** (dirty bit 4), broadcasting `0x38F5` type 5 (the guild total)
and type 6 (the member's donation) through `CGuild::BroadcastToLocalMember`.
`AddPoints` does both only when `FUN_005d0c90` finds the member, and neither
otherwise.

*Two corrections (round 525).* This section used to say the request "requires
a PC"; the `0x4c07` test is `GetLifeState` (`docs/protocol/igobj_vtable.md`,
slot 62), so it requires a living one. It also called `member+0x40` the member's
"contribution". The column bound at `+0x40` is `GP_Donation`;
`_GUILDMEMBER.Contribution` is a separate column at `+0x58`
(`docs/protocol/db_bind_offsets.tsv`, the `_GUILDMEMBER` rows). The guild's
`+0x3c` is `_GUILD.GatheredSP` (same file, the `_GUILD` rows).

**The logout flush (round 525).** `srv.asm` addresses `+0x2184` at three sites
only (a grep for `0x2184]` over every base register), and `GainExpAndLevel`'s
(`0x4e5625`-`0x4e5647`) is just one of them.
`CGObjPC::vslot_000` zeroes it for every new PC object (`4dea77 mov
[esi+0x2184],ebx`, with `4de9cb xor ebx,ebx` and no write to `ebx` between).
`FUN_004def90` flushes it:

	4def96 cmp [esi+0x2184],ebp ; jle   -- something pending (ebp = 0)
	4def9f cmp [esi+0x1cbc],ebp ; je    -- in a guild (pc[0x72f])
	4defbd call 0x5c62e0                -- RequestAddGuildPoints(pending)
	4defc2 mov [esi+0x2184],ebp         -- zeroed

that is `if (0 < pc[0x861] && pc[0x72f] != 0) { RequestAddGuildPoints(pc[0x861]);
pc[0x861] = 0; }`, **with no threshold**: one to nine pending points go too.
`FUN_004def90`'s one caller is `FUN_004df050` (`4df214`), the path that takes a
PC out of the world, which has 61 call sites. `transaction::transaction__OnTimeout`
(`0x46c780`) calls it right after logging "DISCONNECT FROM
transaction::OnTimeout()"; `CGObjPC::StorageOperation` (`0x50f5c0`) reaches it
after logging "posting AsyncQuery failed. will be disconnected!!!";
`CMainProcess::FUN_00417a80` calls it for every PC, and is itself called when
the ShardManager link drops (`CMainProcess::FUN_00416f80`: "all user
connections will be lost (but, data saved)"); and right after the flush
`FUN_004df050` calls vtable `+0x1f0` (`IGObj::SetLifeState`,
`igobj_vtable.md` slot 124) with 3, `GONE` (`character_state.md`, LIFESTATE).
The flush goes through the same request, so the same gates apply: a PC dead
at logout gets `0x4c07` and its count is dropped (`FUN_004df050`'s branch for
state 2 only computes the return point and writes the saved position,
`CGObjPC::FUN_004e08a0` and `FUN_004f9950`/`9920`/`9850`, with no
`SetLifeState` among them). There is nothing to persist: the count lives
exactly as long as the PC is in the world.

So a guild's points grow by exactly the skill points its members gain,
delivered in batches of at least ten per member while they play, and whatever
is left, one to nine, when they leave the world. Both callers zero the
accumulator once the count is handed over, without testing the request's
result.

### What srrevamp does (round 525)

- **Storage.** `guild.Guild.GatheredSP` and `guild.Member.GPDonation`, in both
  stores (`gathered_sp` / `gp_donation` in Postgres). `Store.AddPoints(guild,
  member, points)` raises both or neither: `ErrGuildNotFound` for a missing
  guild, `ErrNotInGuild` for a character outside it, and a count of zero or
  less does nothing. The engine's fields are dwords; srrevamp stores 64-bit.
- **Crediting.** `session.NewGuildPointSkills` wraps the skill store that
  `cmd/server` hands the combat and skill-use handlers, the only callers of
  `AddSkillExp`. After a conversion that yields points, a guild member's points
  (membership alone, `Store.GuildIDOf`: no roster load) go through a
  per-character `guild.PointAccumulator`, and each batch of ten or more goes to
  `AddPoints`. Points granted directly (`AddSkillPoints`: GM `/sp`, learn
  refunds, the no-level-table kill fallback) credit nothing, as none of them is
  `GainExpAndLevel`'s conversion. A failed credit is logged and dropped, and the
  accumulator is zeroed either way, as in `0x4e5250`.
- **The logout flush.** `session.GuildPointsDisconnectHandler`, in
  `cmd/server`'s `OnDisconnect` chain ahead of the world hub's, runs
  `FlushPending`: whatever the character has pending, any count above zero, goes
  to its guild, and the character's accumulator is removed from the map. A
  character no longer in a guild has its count dropped, as the engine's PC
  object does. The gateway does not run `OnDisconnect` for sessions still open
  when the process stops, so `cmd/server` calls `FlushAllPending` once the
  listener returns. That shutdown flush is srrevamp's own handling: the engine's
  clean-shutdown path has not been read, and its all-users-out path that has
  (the ShardManager drop, above) flushes every PC. A session that enters the
  world as a second character without disconnecting keeps the first one's count
  until that character's next flush. Pending points are otherwise lost when the
  process dies without stopping cleanly, or when the credit itself fails
  (logged, as on the batch path), and in two more cases found in review
  (round 527; this said "only" the first two):
  - **The stop flush's window.** `FlushAllPending` runs as soon as the
    listener returns, but the gateway does not wait for its connection
    goroutines (one blocked in a read still hands its next packet to the
    handler), and keep-up swings run on their own timers. A kill during or
    after the flush books on an accumulator the flush has already passed,
    and `main` returns without sending it: up to nine points per character,
    on a clean stop, plus any batch whose credit is still running at exit.
    Disclosed in `FlushAllPending`'s comment, not closed: closing it needs a
    gateway that tracks, closes and waits for its connections, and keep-up
    loops stopped first.
  - **A membership lookup error.** The engine tests `pc[0x72f]` in memory;
    srrevamp asks the store (`GuildIDOf`). If that fails with a database error
    (not `ErrNotInGuild`), the conversion's points are logged and not booked,
    and a logout flush drops its count. Disclosed in `AddSkillExp`'s and
    `FlushPending`'s comments.
- **The request's life test** (`GetLifeState == 1`, else `0x4c07`) uses the
  stand-in the founder check uses for the same engine test (step 2 of the
  founder-check table above, enforced in `session.handleGuildCreate`): alive is
  HP above 0. srrevamp stores no life state, and 0 HP is what
  `character.Store.ApplyDamage` reports as died. A dead earner's batch, or a
  dead character's logout flush, is dropped and the count zeroed, as in the
  engine.
- **Not modelled.** The level test cannot fail, since srrevamp's guilds have no
  level. There is no `0x38F5` push: the client asks with srrevamp's placeholder
  `OpGuildPoints` (`0x0098`), and `OpGuildPointsResult` (`0x0099`) answers with
  the guild's id, its `GatheredSP` and every member's name and `GPDonation`. The
  client asks after each successful guild reply (world entry, create or join,
  and opening the guild HUD panel) and shows the numbers in the Guild tab, so
  **the numbers shown do not update live** while members earn: they are as of
  the last guild reply.
- **The rate inherits a disclosed choice.** How much skill experience a kill is
  worth is not recovered; srrevamp takes it 1:1 from the kill's experience
  (the comment above `AddSkillExp` in `session/combat.go`), so guild points
  from kills grow at that disclosed rate.
- **Still open.** A guild level, and spending `GatheredSP` on a level-up
  (`guild.LevelUpCost`).

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

`0xb0f0` is the guild-create response. `FUN_00514ce0` sends it on the penalty
path and the length-refusal path. `trs_sm_guildjob::FUN_005c8bf0` sends it on
success, once the create job has answered and the 500,000 has been taken (round
487, "Founding a guild" above).

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
- ~~**Guild points: where they come from.**~~ READ in round 272 -- see "Where guild
  points come from" above; credited in srrevamp since round 525.
