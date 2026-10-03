# Jobs, trade routes and the flea market

The trader/hunter/thief system, its job guilds, the specialty goods they move,
and the player flea market. Implemented in `server/internal/jobs`.

49 codes match, across 22 server functions.

## Level 20 to take a job

Two unrelated functions enforce it, both through vtable slot 73 (`+0x124`, the
level getter) with the same comparison:

	FUN_005120f0 (join a job guild):      if (level < 0x14) -> 0x4819  JOBGUILD_JOIN_ERR_LEVEL
	GObjPC::SellItemAtSpecialtyShop:      if (level < 0x14) -> 0x184e  SPECIALTY_ERR_NOTTRADE

so **20** is the floor both for taking a job and for trading the goods a job
exists to move. Two independent readings of the same number.

## Three job kinds

The join handler reads one byte and accepts exactly three values:

	kind = ReadUInt8();
	if (kind == 1)      x = 0x14;
	else if (kind == 2) x = 0x15;
	else if (kind == 3) x = 0x16;
	else return 0x4828;

**Which kind is trader, hunter or thief -- READ (round 273).** The engine labels
them itself, twice and independently: `FUN_00466e70` switches on `GetJobType()`
(vtable slot 71) and `GObjPC::FUN_0060da10` on the job record's byte at `+0x1c`,
and both spell **1 "Trader", 2 "Robber", 3 "Hunter"** (0 "no job"; the second
prints "UNKNOWN" otherwise). `server/internal/jobs` now names them
`KindTrader`, `KindThief`, `KindHunter` (the old A/B/C remain as aliases) and
`Kind.Name()` returns the engine's words.

**A coincidence worth naming before it causes a bug:** kind 1 maps to `0x14`,
which is 20, and the minimum level is also 20. They are different things — an
identifier and a level — and they are equal by accident. The package has a test
whose only job is to say so.

## The flea market holds eight

`FUN_004734e0` refuses with `0x3c18` `FLEAMARKET_ERR_MARKET_FULL` when the entry
vector is that long:

	iVar2 = *(int *)(this + 0x198) - (int)begin;
	if (begin != NULL && iVar2 >> 2 == 8) -> 0x3c18

`>> 2` over a pointer difference counts 4-byte elements, so the vector holds
**eight** entries.

Its other refusals name the failure modes a hosted market has:
`FLEAMARKET_ERR_HOST_LEFT` (`0x3c15`), `FLEAMARKET_ERR_CLOSED_BY_HOST`
(`0x3c17`), `FLEAMARKET_ERR_INVALID_HOST_STATE`, `_IM_BUSY`,
`_CANT_OPEN_MARKET_IN_RIDESTATE`, `_INVENTORY_FULL`, `_NOT_ENOUGH_GOLD`.

The host-state check enumerates the states a host may be in:

	if (state != 5 && state != 4 && state != 6) -> INVALID_HOST_STATE

## Job items

`CGItemEquip::vslot_301` and `vslot_302` gate wearing a job suit. The refusals
enumerate the conditions:

| refusal | condition |
|---|---|
| `JOBITEM_WEAR_ERR_RIDE` | mounted |
| `JOBITEM_WEAR_ERR_PARTY` | in a party — tested twice, on `char[0x85e]` and on `char[0x734]` |
| `JOBITEM_WEAR_ERR_NOPOSITION` | no job position |
| `JOBITEM_WEAR_ERR_NOJOB` | no job |
| `JOBITEM_WEAR_ERR_NOALIAS` | no job alias set |
| `JOBITEM_WEAR_ERR_WEARLIMIT` | a wear limit |
| `STRGERR_CANT_DETACH_JOBITEM_IN_BATTLESTATE` | in combat |

**A job suit and a party are mutually exclusive**, which is the rule most likely
to surprise a reimplementation — and it is why `party.go`'s own match path
refuses with `JOBITEM_WEAR_ERR_PARTYMATCH`. The two systems check each other.

**None of the wear limits' numbers is recovered**; every branch above tests a
flag or a pointer rather than comparing a literal.

## Specialty goods

`GObjPC::SellItemAtSpecialtyShop` (736 bytes) and `GObjPC::FUN_00617f70`:

| refusal | meaning |
|---|---|
| `STRGERR_ONLY_TRADER_CAN_BUY_SPECIALTY` | only a job character may buy |
| `SPECIALTY_ERR_NOTSELL` / `_NOTTRADE` | the goods or the character cannot trade |
| `SPECIALTY_ERR_TRADESHOP` | wrong shop |
| `SPECIALTY_ERR_QUEST_NOTCOMPLETE` | a prerequisite quest |
| `STRGERR_CANT_DEAL_SPECIALTY_SINCE_TOO_FAR_FROM…` | a distance limit |
| `STRGERR_DONT_HAVE_ANY_TRADECART_TO_PICK_SPECIALTY` | goods need a cart |

**The distance limit's value is not recovered** — the check is a helper call,
not a literal comparison, which is the same shape the academy's 24-hour windows
have and is recorded the same way.

The cart requirement ties this system to `docs/protocol/pets.md`:
`CGObjCOS_Cart` is one of the six COS classes, and
`STRGERR_YOU_CANT_ACTIVATE_CART` is in the COS summon path. A trade run needs a
summoned cart, and the two systems meet there.

## The database surface

	_InsertCharTrijobSafeTradeData   3      _OpenMarket_Insert     17
	_DeleteCharTrijobSafeTradeData   1      _OpenMarket_Purchase    9
	                                        _OpenMarket_Cancle      6
	                                        _OpenMarket_Update      5
	                                        _OpenMarket_Receipt     3

`_OpenMarket_Cancle` is the engine's typo and is quoted as spelled.
`CInstanceCharTrijob` is the class; `trs_sm_partyjob` is a stored-procedure
wrapper in the same family.

## Not recovered

- ~~Which of the three kinds is which job.~~ **Recovered in round 273** and
  used again in round 295: **1 Trader, 2 Robber, 3 Hunter**, from two
  independent labellers (`JobTypeName` on `GetJobType()`, and
  `GObjPC::JobRecordKindName` on the job record's `+0x1c`). This bullet was
  stale; see "Three job kinds" above.
- Every numeric limit except the level and the market's eight slots: the
  distance, the wear limits and the trade-route reward rates are all behind
  helpers.
- The `_REFTREATITEMOFSHOP`, `_REFPRICEPOLICYOFITEM` and specialty-related
  reference tables, which are in the catalogue and unread.

## The job experience curve is leveldata's columns 6, 7 and 8 (round 295)

A `TrijobMgr` function (`0x0060dd90`) indexes the per-level table by the **job
level** (the job record's byte at `+0x1d`, minus one) and selects a column by
the **job kind** at `+0x1c` -- the same byte `GObjPC::JobRecordKindName` reads:

	kind 1 (Trader) -> the level row's +0x20   = leveldata column 6
	kind 2 (Robber) -> +0x24                   = column 7
	kind 3 (Hunter) -> +0x28                   = column 8
	anything else   -> Assert_BreakIfDebugger()

The column offsets follow the level record's packing, which four independent
readers pin (`docs/LEVELING.md`). So each job kind has its own per-level column
in the same `leveldata.txt` the character curve comes from, and the function
that reads it is the one maintaining the job record's running total at `+0x20`.

OpenSRO models job kinds but not job levels, so this is recorded rather than
wired.

## The reward statement is issued for two kinds only (round 297)

`ExecAddTrijobReward` builds `EXEC _AddTrijobReward %d, %d`, and its first
argument is **not** the job kind. It is a remap of the job record's kind byte
at `+0x1c`:

	kind 1 (Trader) -> 3
	kind 2 (Robber) -> 2
	anything else   -> Assert_BreakIfDebugger(); return 0

That last branch is the same one a formatting failure lands on, so a kind
outside {1, 2} reaching this function is treated as a programming error. **The
statement is therefore only ever issued for Trader and Robber, never for
Hunter (3).** Why Trader maps to 3 rather than 1 is not read -- the procedure's
first parameter is evidently its own code space, not the kind enum.

The second argument is the async-query object's `+0`.

`ExecDeleteOldTrijobData` issues `EXEC _DeleteOldTrijobData %d` with its one
argument taken from the object's `+0x18`, **not a literal** -- so whatever age
threshold it deletes by is data, and there is no constant here to recover.

## The three job guilds have three interaction ids (round 453)

The kind→value mapping recorded above (`1→0x14`, `2→0x15`, `3→0x16`) was filed
as a bare mapping with the note that kind 1's `0x14` equalling the level floor
of 20 is a coincidence. **What the mapped value IS is now read: it is an NPC
interaction id**, the same vocabulary `docs/protocol/character_state.md`
records. In `CInstanceCharTrijob::HandleJoinJobGuild` the mapped byte goes
straight into the gate:

	if (kind == 1) id = 0x14; else if (kind == 2) id = 0x15;
	else if (kind == 3) id = 0x16; else -> 0x4828
	if (CGObjChar::HasAvailableInteraction(npc, id) == 0) -> 0x480f

so joining a job guild requires standing at an NPC that offers **that job's**
interaction. With the kinds already named from the engine's own two spellings:

| interaction id | job guild |
|---:|---|
| **0x14** (20) | Trader |
| **0x15** (21) | Thief (the engine's word is "Robber") |
| **0x16** (22) | Hunter |

**Three independent readers agree**, which is why this is stated rather than
suggested:

1. `CInstanceCharTrijob::HandleJoinJobGuild` — the kind byte the client sends.
2. `JobGuild_HandleWithdraw` — the same `1/2/3 → 0x14/0x15/0x16` mapping, the
   same `0x4828` for anything else, the same gate.
3. `GObjPC_HandleAliasMsg_0e3` — **the player's OWN job type**, read with
   `GObjPC::FUN_0060e040`, mapped to the same three ids at three separate sites
   that all jump to one shared gate.

The third is the strongest: it does not trust a client byte at all, it reads the
job the character already holds and demands the matching guild NPC.

**`0x480f` now has a meaning.** `error_codes.md` listed it only as "pushed by
`JobGuild_HandleWithdraw`", with no sense attached — it is the refusal for
**"this NPC is not your job's guild"**, and all three handlers raise it from the
same failed `HasAvailableInteraction`.

**The id space is organised.** These three sit directly below the siege block
(`0x17`–`0x1b`, `docs/protocol/siege.md`), so ids 0x14 through 0x1b are one
contiguous run of NPC roles: three job guilds, then five fortress roles.

**Nothing to wire on the server.** `server/internal/jobs` has no NPC interaction
model — the ids matter when job guild NPCs are built, not before.

## The client's join line at the job-guild NPCs (round 526)

The same three ids decide the job-guild NPCs' talk lines in `sro_client.exe`
(`docs/protocol/character_state.md`, "The job guilds' lines (round 526)"):

	FUN_00700440 (the talk menu)
	  id 0x14 present -> IF_NPCTalk::FUN_006fdeb0(n, 1)   ; 0x701237 push 1
	  id 0x16 present -> FUN_006fdeb0(n, 3)               ; 0x70127b push 3
	  id 0x15 present -> FUN_006fdeb0(n, 2)               ; 0x7012bf push 2
	FUN_006fdeb0(n, kind)
	  if (FUN_009db0d0(player) == 0)                      ; mov al,[ecx+0x7be]
	      FUN_006fcd60(n, 0x1e, kind)                     ; the join line
	  ...
	FUN_006fcd60 case 0x1e: kind 1 UIIT_STT_NPC_CHATTING_TRADERMENU_JOIN,
	                        2 ..._THIEFMENU_JOIN, 3 ..._HUNTERMENU_JOIN

The byte at `+0x7be` of the player object (`[0xeef5ec]`) is the player's job
kind. `JobGuild_OnJoinResult` (`0x8890b0`, the 0xb0e1 handler) writes it
through `FUN_009db0b0` at `0x88910a` with the byte its reply carries, and
`FUN_006fdeb0` compares it with the kind (`0x6fdeef` `cmp al,bl`). So a player
with no job sees the join line at each job's NPCs, and a player with a job
sees none.

The server's registrations are the literals, not wildcards: 0x14 on
`NPC_CH_DOCTOR`, `NPC_WC_DOCTOR`, `NPC_KT_DESIGNER`, `NPC_EU_MERCHANT`,
`NPC_CA_MERCHANT`, `NPC_SD_M_AREA_MERCHANT` (`CGObjNPCNPC::Create`, `push 0x14`
at `0x4c6c33`); 0x16 on `NPC_CH_GENARAL_SW`, `NPC_WC_GENARAL_SW`,
`NPC_KT_MINISTER`, `NPC_EU_HUNTER`, `NPC_CA_HUNTER`, `NPC_SD_M_AREA_HUNTER`
(`0x4c6d09`); 0x15 on `NPC_TD_THIEF_SELL` and `NPC_SD_T_AREA_THIEF`
(`0x4c6d57`).

**Wired on the client (round 526).** `NpcServiceReader.services_for` offers a
`"job_guild"` line carrying the kind's join token at those 14 codenames when
`player_job_kind` is 0. The client does not track the player's job yet, so
`World3D` passes nothing and every player is treated as jobless. Choosing the
line reports that it is not available yet: nothing sends the join request.
