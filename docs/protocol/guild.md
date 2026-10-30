# Guilds

What the engine enforces about guilds, recovered from `SR_GameServer.exe`.
Implemented in `server/internal/guild`.

OpenSRO already had a guild system — persistent membership, create/join/leave —
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

The name length corrects a value OpenSRO had as own design (`32`). The
**minimum** matters more than the maximum: OpenSRO used to enforce none, so a
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
counts UTF-8 bytes, which is what OpenSRO's client sends. ASCII names agree;
a non-ASCII name can be refused here that the engine would accept.

## Founding a guild — `FUN_00514b20` (round 487)

`CGuildManager::HandleCreateGuild` (`0x00514ce0`) calls `FUN_00514b20` before
it reads the name, and goes on to the length test only when it answers 1.
`in_EAX` is the founder's `GObjPC`. The whole function is seven tests, and the
create job's reply adds an eighth step, the payment:

| step | engine test | refusal | OpenSRO |
|---|---|---|---|
| 1 | `*(char *)(in_EAX[0xc] + 4) == 1`, the character lock | `0x4c09`, not in the client's message table | not modelled: no lock to hold (`char_lock.md`, "For OpenSRO") |
| 2 | vtable `+0xf8` `IGObj::GetLifeState` `!= 1` | `0x4c07` `GUILDERR_IM_DEAD` | **enforced**: the world hub's life state since round 550 (`handleGuildCreate`, `deadBySession` -- a monster's kill under `-player-dead-state`), with HP ≤ 0 the stand-in for a character the hub does not hold |
| 3 | vtable `+0x124` `IGObj::GetLevel` `< 0x14` | `0x4c0a` `GUILDERR_TOO_LOW_CREATOR_LEVEL` | **enforced**: `guild.MinCreatorLevel` = 20 |
| 4 | 64-bit gold at `in_EAX[0xd] + 0x78/+0x7c` `< 500000` | `0x4c0c` `GUILDERR_NOT_ENOUGH_GOLD` | **enforced**: `guild.CreateGoldRequired` = 500,000 |
| 5 | vtable `+0x11c` `IGObj::GetJobState` `!= 4` | `0x4c57` `UIIT_CTL_GUILD_CREATE_JOB_ERROR` | not modelled: OpenSRO has no job state |
| 6 | `GObjPC::FindTimedJob(2,1)` finds one | `0x4c3c` `GUILDWARERR_GUILD_CREATE_PENALTY` | not modelled: OpenSRO has no penalty timer |
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

**What OpenSRO does.** `session.handleGuildCreate` reads the founder and calls
`guild.CheckCreator(HP > 0, Level, Gold)` before `guilds.Create`. That call covers
steps 2 to 4, in the engine's order. `guilds.Create` then covers step 7 and the
length test. After `Create` succeeds, the handler takes
`guild.CreateGoldRequired` with `DeductGold`. The replies use our own wording:
`cannot found a guild while dead`,
`a guild founder must be at least level 20` and
`founding a guild requires 500000 gold`.

**OpenSRO's own handling, not the engine's: the rollback.** The engine's
`OffsetGold` has no refusal path. OpenSRO's `DeductGold` does: it fails if the
gold was spent between the check and the deduction. A guild left standing then
would have been founded for free. So the handler calls `guilds.Leave` for the
founder, which disbands a guild once its last member leaves, in both stores. It
then replies with the not-enough-gold message. There is one window: a second
character could join the new guild by id before the rollback runs, and then
`Leave` hands that character the leadership instead of disbanding. The
`Leave` runs on `context.WithoutCancel(ctx)` (round 531): a server stop that
cancels the handler's `ctx` fails `DeductGold`, and a `Leave` on the same
`ctx` would fail too and leave the guild founded for free.

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

### What a level-up spends (round 528)

When the ladder passes, `CGuild::HandleLevelUp` sends a ShardManager job and
returns: `5c645d push 0x0; push 0x9; push esi; ... call 0x5c80a0`, that is
`CGuildMamager__SendOlappedGuildJobReqToSM(pc, 9, 0)`. Nothing is spent yet.

**The gold is spent on the job's reply, at the checked amount.** Case 9 of
`trs_sm_guildjob::FUN_005c8990` is `trs_sm_guildjob::FUN_005c8fd0`. It reads
`CGuild::GetLevel()`, which is **already the new level** (it asserts the value
is 2 to 5), and calls vtable `+0x16c`, `IGObj::OffsetGold`, with the negated
64-bit entry at `.rdata 0x00ade918 + (new level - 2) * 8`. That is the gold
table's entry for `new level - 1`, the level the check priced. Then
`IGObj::BackupData(0x80, 0)` and the `0xb0fa` reply. As with founding, the
reply is the success path only.

**The guild points are not spent by the game server, and the amount is not in
this binary.**

- The job carries no amount. `SendOlappedGuildJobReqToSM`'s case 9 stores the
  character's id and one more id (`FUN_004ea580`) and nothing else.
- `FUN_005c8fd0` writes no guild field.
- The guild record changes when the ShardManager's update arrives.
  `CMainProcess::FUN_005c9bd0`, the inter-server guild dispatcher, sends its
  cases 9 and 10 to `FUN_005ca4b0`, which finds the guild and calls
  `FUN_005c3c90`. That reads a one-byte field mask, and `FUN_005cfc20` copies
  each field the mask names. The numbers are mask VALUES, the operands of its
  tests (`& 1`, `& 4`, `& 8`, ...), not bit indices (corrected in round 531):
  1 the id (`+0x18`), 4 `Lvl` (`+0x38`), 8 `GatheredSP` (`+0x3c`), `0x20`
  `CurCrestRev` (`+0x94`), `0x40` `MercenaryAttr` (`+0x98`) (offsets as
  `docs/protocol/db_bind_offsets.tsv` binds them); 2 and `0x10` read strings
  (`FUN_00404b60`). It then broadcasts `0x38F5` type 5 with the same mask.
- Which flags the ShardManager sets after a level-up, and what `GatheredSP` it
  sends, is decided in the ShardManager, which is not in `SR_GameServer.exe`.
  That dispatcher case 9 answers job 9 is a match of numbers and fields, not a
  traced path.

**OpenSRO spends the checked guild points, as a disclosed stand-in.** Two
readings point that way, and neither proves it:

1. The other guild purchase gated on `GatheredSP`, `FUN_005c7900` (the
   mercenary attribute at `guild + 0x98`, job `0x2b`; it refuses `0x4c32`
   when `guild + 0x3c` is short), is answered through the dispatcher's case
   `0x2b`: `FUN_005cc590` reads a guild id, a byte and a dword, and
   `FUN_005c5600` writes the byte to `MercenaryAttr` and the dword to
   `GatheredSP`. So the ShardManager does send a new points total after a
   points-gated guild purchase.
2. The gold, checked in the same function against the same level's entry, is
   spent at exactly the checked amount.

Not spending them would make the guild-point cost a threshold only. If the
ShardManager is ever read, `guild.CheckLevelUp`'s `gpCost` is the value to
correct.

**What the client does with a refusal.** `Guild_OnLevelUpResult` (`0x881bd0`,
the client's handler for `0xb0fa`) reads a result byte and, on 2, a `u16` code,
and hands it to the error dispatcher with category `0x10` (`0x881c53 push
0x10`, through `FUN_00778190`). Category `0x10` is the guild switch
(`docs/protocol/error_codes.md`, "The rows the client shows for a pick-up or
repair refusal"): `0x4c07`, `0x4c1e`, `0x4c21`, `0x4c31` and `0x4c32` each have a
message, and `0x4c0d` goes to the default, which shows nothing.

### What OpenSRO does (round 528)

- **The level.** `guild.Guild.Level` is `_GUILD.Lvl`, stored in both stores
  (`lvl INTEGER NOT NULL DEFAULT 1` in Postgres, added with `ADD COLUMN IF NOT
  EXISTS`). A new guild is at `guild.FoundingLevel`, 1. The binary does not
  hold the founding write (the ShardManager creates the row; the create reply
  `trs_sm_guildjob::FUN_005c8bf0` looks the guild up and sets no level), so 1
  is the floor the engine's tables agree on: `CGuild::IsFull` treats 0 as 1
  after an assert, `CGuild::CheckLevelUpCost` has cases 1 to 4, and
  `FUN_005c8fd0` asserts a levelled guild is at least 2.
- **The level-up.** `guild.Store.LevelUp(character, alive, gold, pay)` runs
  `guild.CheckLevelUp`, the ladder above in its order, against the guild as
  stored. It then calls `pay` with the gold cost, takes the guild-point cost off
  `GatheredSP` and adds one to `Level`. Nothing changes unless all of it
  succeeds: `MemStore` holds its lock throughout, and `SQLStore` runs one
  transaction that locks the guild's row (`FOR UPDATE OF g`). Members'
  `GP_Donation` is not touched.
- **The gold.** `session.handleGuildLevel` passes a `pay` that calls
  `DeductGold`. **Our own handling, not the engine's:** the engine's
  `OffsetGold` cannot refuse and runs after the level has changed.
  `DeductGold` can refuse, if the gold was spent since the check, so it runs
  before the new level is kept, and that refusal is reported as `0x4c31`. If
  the store fails after taking the gold (its `UPDATE`, read-back or commit),
  the handler gives the gold back with `AddGold` and logs a refund that fails.
  This is the counterpart of founding's rollback (round 487). Since round 531
  both the refund and that rollback run on `context.WithoutCancel(ctx)`: a
  server stop cancels the handler's `ctx`, and a stop between the deduction
  and the guild's `UPDATE` used to fail the refund too and lose the gold. A
  process that exits before the refund returns still loses it (the stop does
  not wait for connections; round 527). A commit error is ambiguous: a
  connection that drops after Postgres committed reports one too, and then the
  refund pays back a level the guild kept (`SQLStore.LevelUp`'s comment).
- **Alive** is HP above 0, the stand-in the founder check uses for the same
  `GetLifeState` test.
- **The member cap follows the level.** Both stores' `Join` refuse at
  `guild.MaxMembersFor(Level)`: 15, 20, 25, 35, 50. It was the level-1 cap for
  every guild until this round.
- **Wire.** A placeholder pair in `session/guild.go`: `OpGuildLevel`
  (`0x009A`) carries a name and one byte (1 to level up, 0 only to report), and
  `OpGuildLevelResult` (`0x009B`) carries the error string, a `u16` engine code
  (0 for OpenSRO's own failures), then on success the guild id, the level, a
  levelled-up byte, the member cap and the next level's gold and guild points
  (both 0 at level 5). `0x009A`/`0x009B` were unused in `server/internal` and
  `client/scripts` when claimed.
- **Client.** The Guild tab asks for the level with the points after each
  successful guild reply and shows `level N, M/cap members`. The master gets a
  "Level Up Guild (gold, GP)" button, our own dev control and not the real
  client's guild window. It is disabled at level 5. A refusal is shown in the
  game's own words through `ErrorText.guild_level_up_line` where the client has
  a message (`client/scripts/net/error_text.gd`, category `0x10`), and in the
  server's words otherwise. A level-up re-reads the purse and the points, since
  the server pushes neither.
- **Not modelled.** The real client offers the level-up at the guild NPC, the
  master's item `0x17` (`UIIT_MSG_GUILD_LEVEL_UP`,
  `docs/protocol/character_state.md`); OpenSRO's master still gets the
  "Guild" placeholder there. The engine broadcasts the new level to the
  guild's members (`0x38F5` type 5); OpenSRO's other members see it on their
  next guild reply.

### A third purchase gated on `GatheredSP`: the guild store's goods (round 530)

Not part of a level-up; it sits here beside the other two purchases the
guild's points pay for. Every good the `STORE_*_GUILD` stores sell has a
PaymentDevice 8 price row in `refpricepolicyofitem`. PaymentDevice is a mask
too: `ReferenceData::FUN_006a99c0` takes the lowest set bit `i` of the row's
PaymentDevice (`+0x8`, as `RefPricePolicyOfItem_ExtractData` reads the row)
and calls `0x4b2bd0`, which sets `1 << i` in the item's price record (`0x4b2c2d`
`or [ebx],eax`) and stores the row's Cost (`+0x14`) as a 64-bit amount at
`+0x8 + i*8` (`0x4b2c38`, `0x4b2c3c`). So PaymentDevice 8 is flag 8 (`i` = 3),
amount at `+0x20` (round 531). For these goods `GObjPC::CheckCurrencyRequirement`
(`0x617360`) tests that flag (`0x61787d` `test bl,0x8`), after the gold flag.
It refuses `0x18c4` `UIIT_MSG_GUILD_STORE_BUY_LIMIT` when `pc+0x1cbc` is 0 or
`CGuild::IsGuildMaster` answers 0. It refuses `0x18c5` `UIIT_MSG_GUILD_LACK_GP`
when `guild + 0x3c` is below the amount at `+0x20`. OpenSRO models none of
this yet. See `docs/protocol/character_state.md`, "What the server checks at a
guild store (round 530)".

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
total at `guild+0x3c`** (dirty flag 8, a mask value) and to **the member's
`GP_Donation` at `member+0x40`** (dirty flag 4), broadcasting `0x38F5` type 5
(the guild total) and type 6 (the member's donation) through
`CGuild::BroadcastToLocalMember`.
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

### What OpenSRO does (round 525)

- **Storage.** `guild.Guild.GatheredSP` and `guild.Member.GPDonation`, in both
  stores (`gathered_sp` / `gp_donation` in Postgres). `Store.AddPoints(guild,
  member, points)` raises both or neither: `ErrGuildNotFound` for a missing
  guild, `ErrNotInGuild` for a character outside it, and a count of zero or
  less does nothing. The engine's fields are dwords; OpenSRO stores 64-bit.
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
  listener returns. That shutdown flush is OpenSRO's own handling: the engine's
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
    OpenSRO asks the store (`GuildIDOf`). If that fails with a database error
    (not `ErrNotInGuild`), the conversion's points are logged and not booked,
    and a logout flush drops its count. Disclosed in `AddSkillExp`'s and
    `FlushPending`'s comments.
- **The request's life test** (`GetLifeState == 1`, else `0x4c07`) uses the
  stand-in the founder check uses for the same engine test (step 2 of the
  founder-check table above, enforced in `session.handleGuildCreate`): alive is
  HP above 0. OpenSRO stores no life state, and 0 HP is what
  `character.Store.ApplyDamage` reports as died. A dead earner's batch, or a
  dead character's logout flush, is dropped and the count zeroed, as in the
  engine.
- **Not modelled.** The level test cannot fail: OpenSRO's guilds have had a
  level since round 528, and it stops at 5. There is no `0x38F5` push: the client asks with OpenSRO's placeholder
  `OpGuildPoints` (`0x0098`), and `OpGuildPointsResult` (`0x0099`) answers with
  the guild's id, its `GatheredSP` and every member's name and `GPDonation`. The
  client asks after each successful guild reply (world entry, create or join,
  and opening the guild HUD panel) and shows the numbers in the Guild tab, so
  **the numbers shown do not update live** while members earn: they are as of
  the last guild reply.
- **The rate inherits a disclosed choice.** How much skill experience a kill is
  worth is not recovered; OpenSRO takes it 1:1 from the kill's experience
  (the comment above `AddSkillExp` in `session/combat.go`), so guild points
  from kills grow at that disclosed rate.
- **Still open** until round 528: a guild level, and spending `GatheredSP` on a
  level-up. Both are built now (see "Levelling up" above, "What OpenSRO does
  (round 528)").

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
| `0x08` | the guild warehouse | `FUN_005c7440`, `FUN_005c74d0`, raising `GUILD_WAREHOUSE_LIMIT` (round 844: the open and the close, the master exempt -- [guild_storage.md](guild_storage.md)) |
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

**Round 844:** the whole players' flow -- the request and its box, the answer, leave, expel, the union
broken, the union pane, union chat and the union crest -- is `docs/protocol/guild_union.md`. It corrects
two points below: the validator also refuses a requester whose union is led by another guild (0x4c1e),
and 0x4c29 ALLIANCE_FULL is raised -- by the ShardManager's join job.

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

**Round 844 (lane V) completes the war and builds it, both sides: [guild_war.md](guild_war.md)** (the
declaration with its question, the stakes, the wire, the PvP rule, the points, the end, the surrender,
the reward, persistence). The sections below are the first reading, kept as it was.

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
- ~~**The warehouse.** Only the permission bit and `GUILD_WAREHOUSE_LIMIT` are
  known; the limit's value is not.~~ READ in round 844 (lane H): level 2, sizes 30 / 60 / 90 /
  120, one member at a time, the messages and the moves -- [guild_storage.md](guild_storage.md).
- ~~**Guild points: where they come from.**~~ READ in round 272 -- see "Where guild
  points come from" above; credited in OpenSRO since round 525.
- **What a level-up spends in guild points.** The ShardManager decides it, and
  it is not in `SR_GameServer.exe`; OpenSRO spends the checked cost as a
  disclosed stand-in ("What a level-up spends (round 528)" above).

## The guild line and the grant name (round 814)

A member's guild over their name -- `[Guild * Grant]` -- and the grant name (the member's nickname,
`_GUILDMEMBER.Nickname`) have their own page: [guild_plate.md](guild_plate.md). In short: the original's
request 0x7256 lets only the master name a member (`FUN_005c7560`: in a guild, guild level 4, the
master, under 13 bytes and the name filter); OpenSRO lets each member name only themselves, at any guild level
(OURS, the user's requests, rounds 814 and 815), keeping the rest.

## The guild block and the guild window (round 821)

The window's data is the original's guild record, which the server sends as a block (all READ,
`sro_client.exe`):

- **0x34B3** begins it (the buffer reset, `FUN_0087fcd0`), **0x3101** appends its bytes
  (`FUN_00883060 -> 0x833380`, read in pieces of at most 0x1000), **0x34B4** parses it
  (`FUN_00887300 -> 0x885550 -> CharacterDependentData::FUN_009965e0`) and refreshes the guild
  window, the guild line and the plates. The original's server sends it at world entry and to a
  joining member (`s:0x5c8d40`).
- **Layout** (`FUN_009965e0`): u32 guild id, str name, u8 level, u32 GP, str notice title, str
  notice body, u32 crest revision, u8 soldier flags, u8 n x member, u8 n x {u32, u8, u32}
  (`FUN_0099d7e0`; OpenSRO sends 0). A member (stored by `UI_FORT::FUN_009961a0`): u32 character
  id, str name, u8 class (0 master, 5 staff, 10 member), u8 level, u32 GP donated, u32 permission,
  u32 contribution, u32 war kills, u32 war deaths, str grant name, u32 RefObjID, u8 siege role,
  u8 offline (record +0x26: 0 draws `gil_contact_on`, 1 `gil_contact_off`, `0x5b6b40`).
- **The information** (`0x5b5eb0`): 66 the name, 115 "Level %d" (UTF-16 at 0xd92bb0), 124 the
  master's name (the class-0 member), 150 the master's race mark (`0x98caa0(.., race, 1)`, the
  16-px `com_kindred_*16`), 126 "%d / %d" members over the cap (table at 0xd92384 + level x 4: 15,
  20, 25, 35, 50), 116 "%d / %d" GP over the next level's (0xd92398 + level x 4: 5400, 50400,
  135000, 378000, 0), 121 "%d%%" GP / next x 100.0 (0xe1b7d8), truncated, and the gauge 120 the
  ratio; both 0 at level 5 (`0x5b617a`). The notice line 222 -> 117: the title, or
  `UIIT_MSG_GUILD_COMMON_NOTEXIST`.
- **The rows** (`0x5ba310 -> 0x5b8580 -> 0x5b6b40`; parts from `CNIFGuildUserSlot`'s OnCreate
  `0x5b9870`): 64 the lamp, 231 the race mark, 68 the name (display mode +0x7a1: 0 the name, 1 the
  grant name, 2 the fortress role, `0x5b4a00`), 69 the level ("%d"), 70 the rank
  (`UIIT_STT_LEADER` / `_GUILD_STAFF` / `_GUILDSMAN`), 71 the GP donated ("%d"). Text colour (0x475d10
  state 5): the master 0xffffb541, the rest white; an offline member's row is put in the disabled
  state (0x475dd0(3)): 0xffa17233 / 0xff808080. Sorted by the window's mode +0x7a0 (0 the default:
  by name; 1-3 the column headers', OPEN).
- **OpenSRO** sends the block at world entry, after a create, a join, a level-up, a grant name and
  a GP credit (to the members in the world), and again to the others when a member comes or goes
  (OURS until 0x38F5's member update is built). New columns: `guild_members.permission` (the master
  0xffffffff, a member 0 -- both INFERRED: the stored procedures' defaults are not read),
  `contribution`, `war_kill`, `war_killed`, `siege_authority`; `guilds.notice_title`,
  `notice_body`, `crest_rev`, `soldier_flags`.

## Membership (round 822)

Create, invite, leave, expel and disband as the original does them, both sides (READ, `sro_client.exe`
and the GameServer; OURS where marked).

- **Requests.** 0x70F0 create {u32 NPC, str name} (`c:0x81f5a0`, after box 0x12's OK); 0x70F1
  disband {u32 NPC} (box 0x13, the master's NPC line 0x14 `UIIT_CTL_GUILD_BREAK`); 0x70F2 leave
  {u32 NPC} (box 0x14, a member's line 0x1c); 0x70F3 invite {u32 the selected player} (the guild
  window's button 37, `c:0x81fb70(0)`); 0x70F4 expel {str name} (button 39's question, then
  `c:0x824190`, which itself refuses the master and the player with 0x4c1f and sends nothing).
  The NPC must offer interaction 0x0f.
- **Replies.** u8 1, or u8 2 + u16 code (category 0x10, `c:0x7ba32b`; a code without a row shows
  nothing). B0F0's success carries the guild block, its 0x4c3c a u32 of seconds
  (`UIIT_MSG_GUILD_SECESSION_PENALTY` as days / hours / minutes). B0F3 (to the inviter) and B0F8 (to
  the invitee) carry an invitation's failure; B0F8's 0x4c10 closes box 0x0F with no text. The
  master's own leave gets no reply at all (`s:0x515070`).
- **The invitation.** 0x3080 {5, u32 inviter} (`c:0x88aeb7`); the client drops it unless the inviter
  is a spawned player with a guild line. Box 0x0F (agreement box, `UIIT_MSG_GUILD_JOIN_REQUEST` /
  `_QUESTION_JOIN`, a 30 s timer); its answer 0x3080 {1, 1} or {2, 0x4c16}. The server waits 30 s
  and then sends 0x4c10 to both.
- **0x38F5** (`FUN_00887330`): type 1 disbanded (`UIIT_MSG_GUILD_BREAK_RESULT`, also on GDR_NOTICE);
  type 2 a member's record (the block's 13 fields; the siege byte ignored); type 3 {u32 id, u8 1 left
  / 2 expelled} (`_EXIT_RESULT` only for the player's own leave, `_EXPULSION_RESULT` with the name
  either way); type 5 guild fields by mask (0x02 the wide name, 0x04 level with
  `_LEVEL_UP_RESULT`, 0x08 GP, 0x10 the notice with `_COMMON_KNOW_REMIND_UPDATE` on
  GDR_WARNING_WND, 0x40 soldier flags); type 6 member fields by mask (0x01 level, 0x02 offline with
  `_JOIN_RESULT` for the member just added, else `_CONNECT` / `_DISCONNECT`, and `_CONNECT_NOTICE`
  for the player's own; 0x04 class, 0x08 GP, 0x10 permission, 0x20 the character's name, 0x40 the
  siege role). OpenSRO now sends type 2 + 6 on a join, type 3 on a leave or expel, type 1 on a
  disband, type 6 on log-on / log-off and a level, and type 5 on GP and level changes.
- **Penalty.** Leaving, being expelled or disbanding starts a 72 h penalty (timed job (2, 1),
  0x3f480 s): it refuses an invitation (0x4c3d) and a founding (0x4c3c + the seconds left).
  OpenSRO keeps it in `guild_penalties`.
- **The window's buttons** (`0x5b5150`, READ): the player's own permission enables 37 for bit 0x01,
  39 for 0x02, 40 for 0x04, 38 for 0x10000000, the notice edit for 0x10; in a guild 38 reads
  `UIIT_CTL_GUILD_UNION_CHAT_GRANT` (master) or `_CONFIRM`, and the master's 40 follows level >= 4
  with 41 enabled. OpenSRO enables 37 and 39 by their bits; 38, 41 and the notice edit have no
  server yet; 40 keeps round 814's rule. A left press on a row selects its member (`0x5b8790 ->
  0x5b86c0`): that row's bar becomes `com_bar01select_` (`0x5b7090`).
- **Boxes** (`UI_SILKMALL::FUN_00644c90`): 0x0F agreement, 308x148; 0x12 confirm, 440x144, lines and
  buttons moved 0x42 right, `UIIT_MSG_GUILD_QUESTION_CREATE` + `_CREATE_CONFIRM`; 0x13 agreement,
  `UIIT_MSG_GUILD_BREAK_CONFIRM`; 0x14 confirm, `UIIT_MSG_GUILD_SECESSION_CONFIRM`; the ban question
  MsgBoxSimple 280x144, Yes / No, `UIIT_MSG_GUILD_QUESTION_EXPULSION_ANYONE`. OPEN: where box 0x12 is
  opened from (it is centred here), and the window the original names a guild in (OpenSRO keeps
  round 521's own name prompt before box 0x12).

## Crests (round 824)

The guild and union emblems, both sides (READ, `sro_client.exe` and the GameServer, unless marked;
the full notes are round 824's in docs/WORLD_ISSUES.md).

- **The items.** ITEM_ETC_GUILD_CREST_USER (9268), _DELETE (9269), ITEM_ETC_UNION_CREST_USER (9270),
  _DELETE (9271): TypeID 3/3/12/2, Param1 (ref +0x2a0) 1 guild / 2 union, Param2 (+0x2c0) 1 register / 2
  delete (MEASURED in the export: OpenSRO's RestoreHP / RestoreHPPct).
- **The client's boxes** (IFSlotWithHelp 0x676dcb, by code name; texts in UI_SILKMALL 0x644c90): 0x15 /
  0x18 the register questions (460 x 210, four lines at (50, 51 / 68 / 85 / 122), OK and Cancel +80, +60),
  0x16 / 0x19 the delete questions (308 x 148), 0x1a / 0x1b the register's success (five lines, one
  Confirm), and the deletes' success through GInterface 0x788270 (MsgBoxSimple, one OK). Placed at (w/2 -
  0x9a, h/2 - 0x4a) before the resize (CMessageBoxManager 0x6ec5d0).
- **The register's OK** (0x797d90 case 0x15 / 0x18): an own crest already -> UIIT_MSG_CREST_REGISTER_OVERLAP;
  `<install path>\guildmark.bmp` (`unionmark.bmp`) through 0x4f9d70: 'BM', 24-bit, 16 x 16, else
  _REGISTER_ERROR (no file: _REGISTER_FAIL); each pixel the nearest silk.dat entry by |dR|+|dG|+|dB|, ties
  to the higher index, bottom row first. OURS: the install path is the folder Media.pk2 is read from,
  else the executable's.
- **The use.** Retail's 0x704C carries the 256 bytes after the slot and type word; OURS: OpenSRO's use
  request (0x008A) with option 0xC6 and the bytes. GS 0x5c7600 / 0x5c7690: not in a guild 0x4c0d, guild
  level < 4 0x4c4a (union: < 5), not the master 0x4c1e, a crest already 0x4c4e / none 0x4c4f; a union's
  also 0x4c2f with no union (OpenSRO forms none). Retail shows these through category 1, which has no row
  for them: nothing. OURS: the reply's own words.
- **The revision.** One past the guild's last (`guilds.crest_last_rev`; INFERRED from the ShardManager's
  LastCrestRev / CurCrestRev), 0 on a delete. 0x3257 {u8 1, u32 guild, str name, u32 rev} goes to every
  player; the spawn record's and 0x30FF's guild block carry it (the first of its three u32); the client's
  cache entry (0x9a4780) is keyed by guild name, and rev 0 clears it.
- **The bytes.** Retail downloads `G<shard>_<id>_<rev>.crb` (256 raw bytes) over FTP from type.txt's
  MarkFTPAddr and keeps `RD\G<shard>_<id>.rd` (an 8-bit BMP with the revision as its last four bytes,
  MEASURED 1338 bytes). OURS: 0x0130 {u8 kind, u32 id, u32 rev} -> 0x0131 {u8 kind, u32 id, u32 rev, u8
  ok, 256 bytes}, served for the current revision only, kept as `user://crest/G<id>.rd` (the bytes, then
  the u32 revision).
- **Drawing** (FUN_009dea30 0x9df370): a 16 x 16 quad whose left edge is the guild text item's left less
  20 and whose top is the item's top (FUN_008b2d30). The union's (36 px) is OPEN, no unions. Where the
  guild window or union pane shows crests, if they do, is OPEN.

## The guild window and the guild manager (round 844, lane G)

The census of everything the original's guild has is [guild_census.md](guild_census.md). This
section records lane G's readings (READ, `sro_client.exe` c: and `SR_GameServer.exe` s:, unless
marked).

**The member highlight.** The window's rows are CNIFBarWnds. A left press (vslot_017 c:0x5b8790,
message 0x201 only) moves the selection: c:0x5b86c0, then each row's c:0x5b7090. That sets the
selected member's row art to `com_bar01select_Left.ddj` and every other row's to
`com_bar01_Left.ddj`; the bar cuts the name at its last `_` and draws left / mid / right.
`com_bar01select_` is `com_bar01_` with a 1-px (255, 178, 82) frame inset 2 px (MEASURED in
Media.pk2), which is the "yellow highlight". Hover changes nothing. A refill re-marks the rows
from the kept id (c:0x5b8580). The friend rows do the same (c:0x5a8700).

OpenSRO had added the select bar under the row's own opaque bar, so it never showed. Since 844,
`GuildWindow._mark_row` swaps the row's art.

**The list.**
- **Order** (c:0x5ba310), set by headers 400..403 (c:0x5baae0):
  - name ascending (the shown name);
  - level, highest first;
  - class, master first;
  - GP donated, most first.

  The walk directions are READ; the comparators are INFERRED std::less.
- **Button 23** (c:0x5ba970) cycles the shown name through name, grant name and fortress
  position. It retitles header 400 with `UIIT_STT_GUILDSMAN`, `_TITLE` or `_GUILD_POSITION`.
- **The position texts** come from UI_FORT::FUN_009961a0: role 1 commander, 2 subcommander,
  4 battle manager, 8 product manager, 0x10 trainer manager, 0x20 engineer.
- **Scroll bar 21** moves the six rows.

**The buttons** (c:0x5b5150, READ):
- Each button and its bit:
  - 37: bit 0x01;
  - 39: bit 0x02;
  - 40: bit 0x04;
  - 38: bit 0x10000000;
  - the pencil 81: bit 0x10.
- In a guild:
  - 38 is enabled and reads `UIIT_CTL_GUILD_UNION_CHAT_GRANT` for the master,
    `_CONFIRM` for the others.
  - For the master, 40 follows guild level >= 4, and 41 is enabled.
  - For the others, 40 is disabled.

OpenSRO keeps two rules of its own:
- 40 keeps round 814's rule (OURS): any member names themselves.
- 41 (the fortress positions) stays disabled.

**The notice.**
- The bar 222 shows the title (c:0x5b54c0).
- A press on the bar (c:0x5b7110) toggles its art (gil_windo02_on / _off) and the view 1200,
  whose 155 holds the body (c:0x5b61ff -> 0x5aad40). The view's Confirm 153 closes it.
- The pencil opens CIFGuildNotifyWrite (c:0x79b380 / 0x70ba50). The title edit takes 0x7f
  characters and the body 0x3ff. The count line shows "%d/Max.%d" with 0x3ff.
- Completed (c:0x70b7b0) checks locally: an empty title shows 0x4c22, an empty body 0x4c23.
  Otherwise it sends 0x70F9 {title, body}.

The server (s:0x516ea0 -> 0x5c6480) checks, in order:
1. a chat ban: 0x3405, and the request is dropped;
2. a `'` or `"` in either string: dropped silently (filter s:0x7312f0; its configured word list
   is OPEN);
3. dead: 0x4c07;
4. no guild: 0x4c0d;
5. without bit 0x10: 0x4c1e;
6. the title 1..0x80 bytes, else 0x4c22;
7. the body 1..0x800 bytes, else 0x4c23.

Then B0F9 {1} (`_COMMON_KNOW_REMIND_UPDATE`) goes to the writer, and 0x38F5 type 5 mask 0x10
(INFERRED mask) to the members. OpenSRO counts the bytes of the UTF-8 string, not of the ANSI one.

**The permissions** (button 38 -> CNIFGuildGrantPow 47 -> 1000; c:0x5ad320, 0x5ac150, 0x5ace60):
- The pane lists every member but the master, by name. Its checks 105..109 are the bits 0x01
  join, 0x02 withdraw, 0x04 union chat, 0x08 storage and 0x10 notice.
- The master edits; the others only look (0x5ac000).
- Header 93's tooltip is `UIIT_MSG_GUILD_UNION_CHAT_TOOLTIP` with the holders of 0x04 + 1, and 12.
- Confirm sends 0x7104 {u8 n, n x {u32 id, u32 mask}}, the changed rows only.

The server (s:0x5c69f0) refuses, in order:
1. no guild: 0x4c0d;
2. not the master: 0x4c1e;
3. more than 12 union-chat holders after the change: 0x4c4b;
4. the storage's current user losing bit 0x08: 0x4c4c. This is lane H's hook
   (`session.GuildStorageUser`).

On success:
- B104 {1} goes to the master, with type 0x16 mask 0x10 listing the rows.
- Each changed member gets type 6 mask 0x10.
- Every member gets type 0x14.

**The master's mask is 0xffffffff and a member's is 0** (READ s:0x5c46e0, the hand-over). This
settles round 821's INFERRED defaults.

**The hand-over** (line 0x18 -> CIFGuildMasterLeave; 0x7103 {u32 NPC, u32 new master}):
- The window's OK (c:0x70a170) refuses the master's own name (`UIIT_MSG_MLEAVEERR_USERNOTEXIST`).
  Otherwise it asks "[%s]" + `UIIT_MSG_MLEAVE_CONFIRM`.
- The server (s:0x5c6900) refuses, in order:
  1. the NPC out of range: 3;
  2. the target is the master himself: 3;
  3. no guild: 0x4c0d;
  4. a release vote running: 0x4c1e;
  5. not the master: 0x4c1e;
  6. a fortress guild in the siege period: 0x4c5d;
  7. a hired mercenary: 0x4c55;
  8. the target not a member: 0x4c1d.

  It does not check that the target is online, nor the target's level or penalty.
- B103 {1} goes to the old master; his client closes the talk and shows `UIIT_MSG_MLEAVE_SUCCESS`.
- 0x38F5 type 0x16 mask 0x54 goes to the members:
  - the new master: class 0, mask 0xffffffff, siege role 1;
  - the old master: class 10, mask 0, role 0.
- The new master also gets everyone's masks (type 0x16 mask 0x10).

**The donation** (button 250 -> CIFGuildPointUp, 360 x 240; 0x7258 {u32 SP}):
- The server (s:0x5c7880) refuses, in order: 0 SP, 2; dead, 0x4c07; no guild, 0x4c0d; too
  little SP, 0x4c32.
- On success the SP is spent and B258 {1, u32} goes back (`UIIT_MSG_GUILD_GP_SUBSCRIPION_RESULT`).
- The GP goes through CGuild::AddPoints, with type 5 / 6 mask 8 to the members.
- The SP:GP rate is the ShardManager's and is OPEN. OpenSRO uses 1:1, INFERRED from the earned
  points' rate.

**The level-up from the guild manager** (line 0x17 -> CIFGuildLevelUp, 360 x 220; 0x70FA
{u32 NPC}):
- The window shows the GP and gold tables by the current level (c:0xdafa44 / 0xdafa58) and
  `UIIT_MSG_QUESTION_GUILD_LEVEL_UP`.
- The server checks the NPC (else 3), then runs the "Levelling up" ladder above.
- B0FA {1} goes back, and type 5 mask 0x0c to the members.

## The vote, the GP history, the recall and the guild goods (round 844, lane G part 2)

The same sources as above. The ShardManager is `sm:`. The database procedures were recovered as
text from the shard backup on the render box. Each claim is labelled.

### The master-release vote (0x7105-0x7107, 0x3908; lines 0x19 / 0x1a)

**The client.**
- The guild manager shows every member one line after the master's own lines (FUN_00700440,
  READ):
  - 0x19 `UIIT_CTL_MASTERRELEASE` "Vote for a leader";
  - or, while the client knows of a vote (c:0x99da70), 0x1a `UIIT_CTL_MRELEASE_VOTE`.
- Line 0x19 asks a box (type 2), and its OK sends 0x7105 {u32 NPC} (c:0x81ff50).
- Line 0x1a sends 0x7106 {u32 vote} when no state is cached (c:0x820010). B106 opens
  CIFGuildMasterElection (274 x 315, `resinfo\ifguildmasterelection*.txt`):
  - seven rows, each a radio check, the name and the votes;
  - the time left, "%d%s" in minutes;
  - OK enabled only with a row ticked, sending 0x7107 {u32 NPC, u32 vote, u8 index}.
- The replies, READ:
  - B105 {1}: `UIIT_MSG_MRELEASE_VOTING` in an event-guide box.
  - B105 {2, 0x4c33}: `UIIT_MSG_MRELEASEERR_NOTVOTETIME`.
  - B106 {1, u32 vote, u32 ms, u8 n, n x {u32 character, u8 votes}}.
  - B106 / B107 {2, code}, category 0x15: 0x5008 is `UIIT_MSG_MRELEASEERR_NOTVOTING`.
- 0x3908 updates the vote:
  - kind 1: a vote started {u32 vote, u8, u32 ms};
  - kind 3: it ended {u32 vote, u8 result, [u32 winner]}. Result 1 shows
    `UIIT_MSG_MRELEASE_BEELETED` with the guild and the winner; result 2 shows `_BROKEN`;
  - kind 4: a ballot moved {u32 vote, u8 old (0xff none), u8 new, u8 count};
  - kind 5: the time left {u32 vote, u32 ms}.
- The guild block's tail carries a running vote, u8 n x {u32 vote, u8, u32 ms}. The client then
  shows "Vote for a leader is in progress." once (c:0x8856e9).

**The rules** (READ: s:0x5c6ac0, CVoteManager s:0x5e7f00 / 0x5e7ea0, sm:0x436ea0, sm:0x461a50,
and the procedures `_Guild_Master_Election_Available` and `_Guild_Is_Master_Candidators`):
- **Who may start it.** Any member, at the guild manager. The server refuses, in order:
  1. a vote already running: 0x4c37;
  2. the master online: 0x4c33;
  3. the master's last logout less than **45 days** ago: 0x4c33. The days are
     `convert(int, getdate()) - convert(int, LastLogout)`. OpenSRO counts calendar days in UTC
     (INFERRED).
- **The list.** Every member but the master who is online, or whose last logout was **7 days
  ago or less** (the procedure's `@minus <= 7`, READ). The client's
  `UIIT_MSG_MRELEASEERR_NOTVOTING` says three days. OpenSRO follows the procedure; which value
  retail ran is OPEN.
- **The vote lasts 600,000 ms** (`push 0x927c0`). The ShardManager checks it every 10 s. After
  the first minute it broadcasts the time left (kind 5).
- **The winning rule.** A candidate wins the moment `votes * 100 / n >= 60.0`, where n is the
  list's size (`fcomp [0x79ae30]`). Each voter holds one ballot and may move it. The vote breaks
  when time runs out with no winner (kind 3 result 2).
- **The winner** takes the guild through the hand-over's own path. While a vote runs:
  - a hand-over is refused with 0x4c1e;
  - a listed member cannot leave (0x4c38) or be expelled (0x4c39);
  - disbanding ends the vote.
- **A ballot** is refused when:
  - the NPC is out of reach: 3;
  - there is no such vote: 0x5006;
  - the voter is not listed: 0x5008;
  - the index is out of range: 2 (OURS).

**What OpenSRO adds** (OURS):
- Each member's last logout is kept on `guild_members.last_logout`, a column the schema code adds.
  The original keeps it as `_CHAR.LastLogout`.
- The vote itself lives in memory, as the ShardManager's does. A server stop ends it without a
  message.
- The constants are `guild.VoteMasterAbsentDays`, `VoteEligibleDays`, `VoteDuration`,
  `VoteWinPercent` and `VoteTick`.

### GP usage history (line 0x43; 0x7501 / B501)

- **The client** (c:0x8206c0, c:0x885c20, CNIFGPHistoryWnd c:0x5b9b30 / 0x5b9d70, READ):
  - Line 0x43 `UIIT_STT_GUILD_GP_HISTORY` sends 0x7501 {u32 NPC}.
  - B501 {1, u8 n, n x {u32 time_t, str name, u32 GP, u8 kind}} fills `res_ui\guild_gp.2dt`
    (464 x 311). Each entry becomes a `UIIT_MSG_GUILD_GP_HISTORY` line, with the local date and
    time and an empty line after it.
  - The kinds 0..8 are, in order: the fortress buff, structures, NPCs, guards and items; then
    guild growth (5), guild item purchases (6), the fortress dungeon and misc.
- **The server** (s:0x517e90, READ):
  - Out of reach of a guild manager: B501 {2, 3}. No guild: {2, 0x4c0d}. No rank is checked.
  - The ShardManager logs only GP *spent*: the level-up is kind 5 (sm:0x438bb0) and a store good
    is kind 6 (s:0x4e9bce).
  - It loads `TOP 100 ... UsedTime >= GETDATE() - 30 ORDER BY ID DESC` and drops the oldest past
    100 entries.
- **OpenSRO** keeps the history in `guild_gp_history`, a table the schema code creates (OURS),
  under the same 100-entry and 30-day limits.

### The guild recall (0x7030 / 0x7031 / B031; itemdata 9267)

- **The scroll.** "Guild Member Summon Scroll" is TypeID 3/3/12/3 and sits on the guild store's
  tab. Its fields (READ):
  - Param1: 3,600,000 ms, the reuse;
  - Param2: 30,000 ms, the members' gauge;
  - Param3: 5, the guild level it needs.
- **The use** (s:0x49afe0, READ) is refused, in order:
  1. no guild: 0x4c0d;
  2. inside an instance world: 0x18c1;
  3. not the master, or the guild under Param3's level: 0x18bc;
  4. not in a town: 0x18c2;
  5. in region 0x60b6 (the thieves' town): 0x18c7;
  6. the reuse running: 0x185b.

  Then the scroll is spent.
- **The question.** The ShardManager (sm:0x434f90 / 0x437e70) asks every online member but the
  master: 0x7030 {u32 job, u32 caster, u32 seconds = Param2 / 1000}. The job lives 180 s.
- **The member's box.** CIFGuildSummonReq is 360 x 160, with Yes / No and its own 180 s timer
  (c:0x660220). The archive's English `UIIT_MSG_GUILD_RECALL_ANSWER` is empty, so OpenSRO shows
  the Korean row's meaning in its place (OURS).
- **The answer** (s:0x4ee1d0, READ): 0x7031 {u32 job, u32 caster, u8 yes}.
  - A dead, teleporting, trading or talking member gets {2, 0x18c1}.
  - Otherwise B031 {1} goes back, whatever the answer.
  - A yes moves the member to where the master stood when the scroll was used. The delay is
    floored to 0.1 s (0x3833 -> s:0x5ba690). The client's 30 s gauge after B031 {1} is cosmetic
    (INFERRED from that delay).

### The guild store's goods, bought with GP (master only)

- **The prices.** The goods' GP prices are the archive's `refpricepolicyofitem` rows with
  PaymentDevice 8, on the packages the guild manager's tabs sell. MEASURED in this archive, five
  goods carry one:
  - 9267, the recall scroll: 1,000 GP;
  - 9268 / 9269, the guild crest register / delete: 20,000 GP each;
  - 9270 / 9271, the union crest register / delete: 30,000 GP each.
- **The client** (READ):
  - The tooltip adds "%s : %I64d%s" with `UIIT_STT_GUILD_POINT` after the gold price
    (c:0x6784a0, `test bl,0x8`).
  - The buy box adds a second row with the GP times the count (c:0x7c4276).
  - The guild store does not open below guild level 3: `UIIT_MSG_GUILD_STORE_LIMIT`
    (c:0x702161).
- **The server** (CheckCurrencyRequirement s:0x617360, READ) refuses, in order:
  1. too little gold: 0x180f;
  2. no guild or not the master: 0x18c4 `UIIT_MSG_GUILD_STORE_BUY_LIMIT`;
  3. the guild short of GP: 0x18c5 `UIIT_MSG_GUILD_LACK_GP`.

  The payment takes the gold, then the GP (the donation totals stay). The members get type 5
  mask 8, and the history logs kind 6.
- **OpenSRO** reads the GP prices from the mall catalogue's new "npcgp" rows. Production must
  re-export `-mall-csv` (`export-refdata -mode mall`) for the goods to cost GP.

### Union chat follows the permission

A union chat line needs bit 0x04 of the sender's guild permission (`guild.PermUnionChat`). The
master always holds it. A member without it gets "You do not have union chatting authority"
(0x200e). The grant goes through 0x7104 (above), which caps the holders at 12 (0x4c4b).
