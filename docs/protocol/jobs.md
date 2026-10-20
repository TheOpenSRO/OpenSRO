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

**(round 709) "0 no job" does not hold for slot 71.** Slot 71 (`GetJobState`, `chardata+0xf`,
`0x4ddc80`) runs **1..4, with 4 = not in job mode**, and 0 is not a valid value. The character
initializer writes 4 (`0x4de3eb`), the worn job suit in equipment slot 8 sets 1/2/3
(`0x4e124e`-`0x4e12cc`), `Party_UserMatches` (`0x5bf240`) asserts on anything outside 1..4, and
the ShardManager's tables (`sm:0x44ed20`, `0x44f7f0`) and the client (`0x9db8b0` returns 4 with no
job item) agree. The party, guild and teleport code all test `!= 4`. The job record's own byte
(`+0x1c`) is a different field and may still use 0. See `docs/protocol/party_protocol.md`,
"Job rules".

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

~~**The distance limit's value is not recovered**~~ — **recovered in round 801**:
the helper compares the PC-to-transport distance with the double **1000.0** at
`s:0xb45c68` (see "Specialty trade" below).

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
- ~~Every numeric limit except the level and the market's eight slots: the
  distance, the wear limits and the trade-route reward rates are all behind
  helpers.~~ **Rounds 799-801 read them**: the distance (1000.0), the wear
  limit (the suit's ReqLevel2 against the job level), the fees, the job exp
  and contribution rates, the quotation formula and the trade scale. See the
  sections from "The job guild (round 799)" on.
- ~~The `_REFTREATITEMOFSHOP`, `_REFPRICEPOLICYOFITEM` and specialty-related
  reference tables, which are in the catalogue and unread.~~ Round 801:
  `_ItemQuotation` is the sale price's table; `_RefTreatItemOfShop` (one
  all-zero DB row, an empty client file) and `_RefPricePolicyOfItem` play no
  part in a sale (READ: the sale path never reads them); the buy price is the
  store's package price (INFERRED refpricepolicy's gold cost, equal to the
  item's Price on every good of the shipped data, MEASURED).

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


## The job guild (round 799)

`server/internal/jobs` and `server/internal/session/jobguild.go`. Every request
names the NPC; the engine's first test (`FUN_004e72a0`: the NPC in reach and
its interaction held, else the literal 3) is the session's NPC state.

| request | handler (READ) | reply |
|---|---|---|
| `0x70E1 {u32 npc, u8 kind}` join | `CInstanceCharTrijob::HandleJoinJobGuild` s:0x5120f0 | `0xB0E1 {1, kind, lvl, u32 exp}` / `{2, u16 code}` |
| `0x70E2 {u32 npc}` withdraw | s:0x5122b0 | `{1}` / `{2, u16}` |
| `0x70E3 {u32 npc, u8 op, str alias}` alias check (0) / set (1) | s:0x512540 | `{1, op, str}` / `{2, u16, op, str}` |
| `0x70E4 {u32 npc, u8 kind, u8 type}` last week's ranking | s:0x512c20 | `{1, kind, type, u8 n, rows}` / `{2, u16, kind, type}` |
| `0x70E5 {u32 npc, u8 op}` the weekly reward: query (0) / collect (1) | s:0x512e70 | `{1, op, u32 gold}` / `{2, u16, op}` |
| `0x70E6 {u32 npc}` the previous job | s:0x513190 | `{1, (u8 lvl, u32 exp) x trader, robber, hunter}` / `{2, u16}` |

A ranking row is `u8 rank, str alias, u8 level, u32 exp, u8 country` for the
activity table and `u8 rank, str alias, u8 level, u32 contribution` for the
contribution table. `0x30E6 {u8 kind, u8 level, u32 exp}` tells a job exp
change. OURS: `0x00BC OpJobInfo {str alias, u8 kind, u8 level, u32 exp, u32
contribution, u32 reward}`, the record the retail client reads out of its own
character data.

**The join (READ, in the handler's order):** the NPC (3); the kind 1..3, else
0x4828; the NPC's guild interaction 0x14 / 0x15 / 0x16 for that kind, else
0x480f; level 20, else 0x4819; no job, else 0x4820; gold at least
`(level - 20) x 5000`, else 0x4807; no 7-day penalty, else 0x4824. The fee is
charged when the join completes (`OffsetGold`, 0x304E unshown). A previous job
of the same kind restores its level and exp (`_QueryOldTrijobInfo`), and the
old row is deleted.

**The withdrawal:** a job suit worn refuses 0x4822; else everything is reset
(the reward too), the alias cleared and a 7-day penalty (604800 s) set.

**The alias:** 2..12 bytes, the pet-name filter (no space, the name filter);
a change costs `level x 50000`; one held by anyone else 0x4825.

**The reward:** robbers and hunters only; the weekly procedure
(`_UpdateTriangleJobWeekly`) shares pool 2 among the robbers and pool 3 among
the hunters by contribution, rebuilds the TOP 50 tables and resets the
contributions. OURS: it runs on a schedule (`-job-week-day` /
`-job-week-hour`); retail runs it outside the GameServer (INFERRED a SQL Agent
job).

**The exp (READ `FUN_0060dd90`):** one level-up a call; level 7 is the cap;
the need is leveldata's columns 6..8 (an unsigned compare, so -1 is never
reached); a robber's or hunter's contribution moves with every exp change,
clamped to 0..2e9. `Unit = trunc(goldmin x 10 x 0.125)`; a job death costs
`3 x Unit` (`FUN_00410370`); a job kill earns
`Unit(victim) x clamp(Unit(victim)/Unit(killer), 0.5, 1.5)`, halved for a
trader killer, at least 1 (`FUN_004103e0`). Both are round 802's.

## The job suit (round 800)

`server/internal/session/jobsuit.go` has every address. A suit (TypeID
3/1/7/1..3) goes into equip slot 8 only through a 10-second change:
`0x3041 {u32 uid, u8 2, u8 2, u8 10}` to the 3x3, cancelled by a move, a blow
or another storage operation (`0x3042 {u32 uid, u8 0}`). The wear refusals in
order: slot 8 taken 0x1846, the generic equip tests, riding 0x18ca, a change
pending 0x1847, the suit's job not the character's 0x189e, no alias 0x189f,
not in a town 0x18a2, a party 0x18a0, the job level below the suit's
ReqLevel2 0x18a3. Taking it off: pending 0x1847, a full bag 0x1807, riding,
the battle state (20 s) 0x1848, a transport out 0x185a, within 10 s of
wearing 0x1847, a party, not in a town. On completion 0x3038 / 0x3039 go out,
the job state is set and each owned COS tells it (`0x30CA {uid, 1, job}`).
The spawn record carries the job type and level always and the alias as the
name while a suit is worn.

The client (READ): the plate is `"*" + name` in job mode with the 16 x 16
`com_job_*` icon above it, the guild line hidden; the strip bar is a yellow
`0xFFFFEE1F` quad 48 x 2 px at (x - 24, y + 10) shrinking 4.8 px a second;
the target window is `CIFTargetWindowJobPlayer`.

Teleport rules (READ s:0x513c58): rule 6 refuses only in job state != 4; rule
2 refuses with a cart (0x1c10); rule 7 refuses a thief's suit with a cart.

## Specialty trade (round 801)

`server/internal/specialty` (the rules), `server/internal/session/
specialtytrade.go` (the messages), the client's `SpecialtyFlow`,
`SpecialtyNet` and `TradeInfoBox`. READ in SR_GameServer.exe (s:) and
sro_client.exe (c:) unless a line says otherwise.

### The specialty NPCs

An NPC gets interaction 0xc either from its code name
(`CGObjNPCNPC::Create`, NPC_CH_SPECIAL2 / WC_SPECIAL2 / TK / RM / EU / CA /
SD_M_AREA_SPECIAL*) or from its store: after id 1 the shop init
(`GObjPC::FUN_004c7920`) asks `ShopApp::FUN_00867850` whether the store lists a
good of the TID word 0x46c (3/3/8) and, when it does, adds 0xc
(s:0x4c79a7..0x4c79c3) and builds the NPC's quotation map (`FUN_004c8220`).
NPC_TD_THIEF_BUY (the thief den's swag shop) has 0xc and 0xd from its name.
OpenSRO's `-specialty-shops-csv` (`export-refdata -mode specialty` from the
client's shop chain) gives the store test; MEASURED on the shipped data: 12
stores, 38 goods.

The client's store line at an NPC with 0xc sends `0x7046 {npc, 0xc}` instead
of `{npc, 1}` (c:0x7022d6..0x702330). The server's answer
`0xB046 {1, 0xc, u8 special}` carries `CMainProcess+0x42405` (the bargain
goods on sale; its schedule `CGameSJ_SpecialGoodsSelling` is OPEN, OURS
`-special-goods`); an NPC with a quotation map then sends its list (0x30E0)
and INTERACTMODE becomes 6 (s:0x5105ca).

### The buy (0x7034 type 0x13)

`u8 0x13, u32 cos, u8 tab, u8 slot, u16 count, u32 npc` (c:0x7923a0). The
server ignores the cos uid and takes the player's own transport (s:0x52675a).
Checks in order (`FUN_005266a0` -> `FUN_00618fe0` ->
`SellItemAtSpecialtyShop` s:0x6182a0): count < 1 0x1829; the NPC; its id 1
held, else 3; no transport 5; the tab 0x1806; an empty slot 0x1809; the
transport bag takes goods only (0x180b); job state 1 with a cart, else 0x1860;
level 20, else 0x184e; the NPC's quest (`FUN_004c9110`: NPC_CH_SPECIAL2 ->
QNO_TRADE_CH_SPECIAL2_1, WC_SPECIAL2 -> QNO_TRADE_WC_SPECIAL2_1, TK ->
QNO_TRADE_TK_SPECIAL_1, RM -> QNO_TRADE_RM_SPECIAL_1, AM ->
QNO_TRADE_AM_SPECIAL_1), else 0x18b0; a bargain good (TypeID4 2) while none
are on sale 0x18af; the PC more than 1000.0 from its transport 0x1865; CanSell
0x183b; count above MaxStack 0x1815. One package takes ONE free slot holding
`count` units (`FUN_004de170`), else 0x1807. The good's instance carries its
buyer's name -- the job alias (`_Items.CreaterName`, written by
`_STRG_ADD_SPECIALTY_NoTX`).

The success, after 0x304E (gold, unshown): `0xB034 {1, 0x13, u32 cos, u8 tab,
u8 slot, u8 n, n x u8 dest, u16 count}` -- no item record: the client places
the goods from its own store data (c:0x87eb50). Then 0x30E8 if the scale moved.
Not modelled (OURS): the quest block 0x185f, the timed job 7 (0x18d1, its
meaning OPEN), MaxContain (0x1872, -1 on every good), the per-TID rule list
`FUN_0061aa40`, the fortress tax.

### The sale (0x7034 type 0x14)

`u8 0x14, u32 cos, u8 slot, u16 count, u32 npc`. `FUN_005267f0` ->
`FUN_006194e0` -> `GObjPC::FUN_00617f70`: count 0x1829; no transport 5; the
slot past the bag 0x1806; the NPC; id 1, else 3; an empty slot 0x1809; for a
good: job state 3 or 4 -> 5, the NPC without 0xc 0x1845, the quest 0x18b0,
goods not bought under the seller's alias at an NPC without 0xd 0x1868, the
PC more than 1000.0 from its transport 0x1865; anything else at an NPC with
0xc 0x1845 (a specialty NPC buys nothing else; the bag's own sale, type 9,
asks the same); CanSell 0x183b; count past the stack 0x1814.

**The price (`GObjNPCNPC::FUN_004c8d10`):** at the thief den's buyer (0xd)
the profit is `Price x count` and the gold 75 % of it (the double 0.75 at
s:0xb462d8); at an NPC that sells the good itself `SellPrice x count`, no
profit; else the NPC's quotation: the stock grows by count (held at
MaxStack), the gold is the unit price before this sale's recompute times
count, the profit `(price - base) x count`; a good with no row sells at its
SellPrice ("CANNOT FIND QUOT DATA"). The profit is clipped at 0.

**The quotation (`FUN_004c8220`, `FUN_004c8810`):** `_ItemQuotation` rows
`ID, Service, AssocNPC, RefItemID, BaseQuot, Quot_LB, Quot_UB,
BaseStockAmount, FluctuateAmount, CurStockAmount` (the table's own columns,
MEASURED); rows with Service 0 or BaseStock 0 are dropped. `base` is the
good's Price (0 -> 1); `MaxStock = round(Fluct x (BaseQuot - LB)/0.01 +
BaseStock)`, `MinStock = round(BaseStock - (UB - BaseQuot) x Fluct/0.01)`
(x87 round-to-even);

	t = float32((Cur - BaseStock) / Fluct x 0.01)
	q = clamp(float32(BaseQuot - t), LB, UB)
	q = float32(trunc(q x 100) / 100)
	price = base + trunc(float32(base) x q - float32(base))

The float widths matter: a float32 1.15 makes a 4000 good 4599, not 4600.
Every ten minutes (timer 0x927C0 ms, s:0x413189, `FUN_004c8b90`) the stock
falls by Fluct (not below 0), held to [MinStock, MaxStock], and every NPC
sends its whole list. A changed price goes out as a one-entry 0x30E0 to the
players the NPC sees (`FUN_004c89d0`, INFERRED its +0x1c0 list is the view).
0x30E0 is `u8 n, n x {u32 ref item, u32 unit price}`, sent only to a player
whose transport holds goods (s:0x4c8a6c). OURS: the stock is not written
back to a database. MEASURED on the shard: 492 rows over 13 NPCs, BaseQuot =
LB = UB on every row (1.1, 1.2 on NPC_KT_SPECIAL's CH goods), so its prices
never move: 4400 for a 4000 good.

**The rewards (s:0x619690..0x6197f2), for a good sold at a profit:** the gold
with reason 0x14 (a party's share, `FUN_005bd180` / `FUN_005bd510`, is OPEN:
the seller keeps it all, OURS); the job exp `GObjPC::FUN_00410520`:
`float32(profit x f)`, at least 1, f = 0.8 for a trader at scale 1, 0.5 at any
other scale, 0.4 for a robber, 1.0 for a hunter -- with the scale before the
goods leave (it runs before the removal); a trader's contribution
`trunc(gold x 0.1)` (`TrijobMgr::FUN_0060e0a0`); the weekly pool
`_AddTrijobReward(3 for a trader, 2 for a robber, trunc(gold x 0.1))` -- the
traders feed the hunters' pool and the robbers their own. The reply:
`0xB034 {1, 0x14, u32 cos, u8 slot, u16 count, u32 npc, u8 0xFF}` (goods are
never booked).

### The trade scale

`CMainProcess::FUN_0060c1f0` and `FUN_0060c330`:

	U      = Unit(levelgold min at clamp(GetMaxLevel, 20, 140))
	S      = 40 for a rarity-1 transport, 30 for rarity 2 (FUN_004d2da0)
	d      = units x 348.0 / U / (40.0 / S)       units: the goods' stack counts
	amount = 1 when 0 < d < 1, else trunc(d)
	scale  = the first i in 0..4 with amount <= T[i], else 5

`T[0]` is 0 and `T[1..4]` are `TRADESCALE1..4_AMOUNT_MAX` (loader
`FUN_0060c6c0`; its own defaults 408, 918, 1428, 2142; MEASURED in the shard's
`_RefShardContentConfig`: 510, 918, 1428, 2142, and TRADESCALE5 2856, never
compared). `0x30E8 {u8 scale}` tells its owner a change (`FUN_005237b0`); the
spawn record's row 28 carries it. A scale that leaves 1 clears the trader
record's safe-trade byte (`FUN_0060e520(0)`, round 802's 1-star rule). OURS:
OpenSRO keeps no level high-water mark, so the level stands in for
GetMaxLevel.

The client draws the first min(scale, 5) of the transport window's five stars,
all tinted by the count (c:0x7a6970, table 0x7a6a28): 0xff3c9be8, 0xff34c97c,
0xffffffff, 0xffff7e00, 0xfffa4848.

### The transport

**The bag (`FUN_004d1a50`):** InventorySize (characterdata column 61, ref
+0x224) 0 means none; else

	cap  = trunc(Unit(levelgold min at the owner's level) x 2448 / 11796.0 x 40.0 / S')
	S'   = S, or S / 1.4 for a cash COS (TID bits 0 and 1 and TypeID 1/2/3)
	size = 1 when cap < 1, else min(cap, InventorySize)

MEASURED: every serviced COS_T row has InventorySize 1 in the shipped data,
so the bag is one slot; a slot holds a whole stack (MaxStack 5000 on every
good). 0x30C8 writes the usable size (storage +0x20). A good's item record is
`u32 rent, u32 ref, u16 count, u16 len, buyer name` -- nothing else (c:0x8be6a1).

**The summon (CGItemExpendable::vslot_307):** a transport needs job state 1 or
2 (0x1849, round 800); refused in the battle state 0x1878 and to a thief in a
town 0x1895. One ride or transport at a time (0x185c).

**The leash (CGObjPC vslot_392 -> `FUN_004fd1d0`):** on every movement step,
the owner's step is refused when the owner is already more than 1000.0 from
its transport (2-D, region-aware) and the step takes it farther; it gets
`0x30E7 {1}` and the 0xB023 stop. The client says
UIIT_MSG_COSERR_TOO_FAR_FROM_TRADECART with a hard-coded 100 (m). OpenSRO tests
the owner's leg once a COS tick (100 ms) instead of every step (OURS), and a
transport is no longer warped back beside its owner within its zone.

**A thief with a transport cannot enter a town (`CGObjPC::vslot_220`
s:0x4eb220):** the region entry is vetoed and `0x300C {0x0c01}` sent
(UIIT_MSG_JSERR_ROBBER_CANT_ENTER_TOWN_WITH_CART, the client's 0x300C default).

**Teleports:** the return scroll and the reverse return scroll refuse a cart
0x185e (`FUN_004a0380`, `FUN_004a00c0`); the thief-den scroll does not -- it
needs job state 2 (0x186a) and goes to the teleport point of the building its
Desc128_4 names (STORE_TD_GATE -> GATE_TD) with option 1.

**Death and dismissal (COS slot 398 -> `FUN_004c3f60`):** a transport's death
or its dismissal (0x70C6, killer 0) lays every stack of its bag on the ground,
goods with no owner, anything else the killer's; a "_QT_" code name is not
dropped. Placement round the transport is OURS (the kill drop's ring). A
transport ridden when its owner dies is released with no drop call (READ);
what becomes of its goods is OPEN -- OpenSRO deletes them with it.

**Picking goods up (`FUN_00525dc0`):** a trader only goods bought under his
own alias (0x1863), a robber only someone else's (0x186f), a hunter none
(0x1863), no job none (0x1864), no transport 0x1861; the good goes into the
transport (`0xB034 {1, 0x11, u32 cos, u8 slot, item record}`), merging into a
stack of the same good and buyer. An ability pet does not take goods (OURS:
the pet route's handling of a good is not read; refused 0x180b).

### The trade-info window (0x74D4 / 0xB4D4)

The talk line 0x39 opens `CIFTradeInfoWnd` with no request (c:0x79e510). Its
stores are specialnpcdata.txt's NPC ids, named text(<the NPC's NameStrID> +
"_T"); Refresh sends `0x74D4 {u32 NPC ref id}`. The server (`FUN_0051a8c0`)
checks nothing and answers from `_ItemQuotation WHERE AssocNPC = id and
Service <> 0`: `0xB4D4 {u16 n, n x {u32 ref item, u16 percent}}`, percent =
`trunc(Price x q2) x 100 / Price` -- the NPC's sale price as a percent of the
good's Price. OURS: the live stock stands in for the DB row's.

### Still OPEN

The bargain goods' schedule; the timed job 7; the 0x42404 mode; the
`FUN_0061aa40` rule list; a party's share of the sale; the CIFSpecialtyDeal
calculator's OK path and the Sell All button's packets (OpenSRO: the store's
count box, one sale a slot); the order of the quotation rows; when the stock
is written back; what a released transport's goods become.

## Job PvP (round 802)

`server/internal/jobs/pvp.go` (the rules), `server/internal/session/jobpvp.go`
(the messages), the client's `JobPvpNet` and World3D's "Job PvP" section. READ
in SR_GameServer.exe (s:) and sro_client.exe (c:) unless a line says
otherwise.

### Who may hit whom (CGObjPC::vslot_394, s:0x5293a0)

A player against a player, or a player's COS (a COS target is judged by its
owner), in order: the attacker's own COS 0x3006; either side in a town (the
region's IsBattleField 0) 0x3018; the same party 0x3022; the caravan rule
(s:0x52b760): a thief against a trader whose transport holds goods, whose
safe-trade Status is 1 and whose trade scale is at most 1 is refused 0x3024
CANT_ATTACK_CARAVAN_LEVEL1, and that protected trader against a thief 0x3006;
then job opposition (s:0x4eb620: a trader or hunter against a thief, either
way round) lets the blow land. A pair not opposed falls to the ordinary PK
rules: an area skill's secondary target is skipped with no code, then levels
under 20 0x3016 / 0x3017, then, for two players both in job suits, the skill
validator's 0x3006 (s:0x58d0a8). OURS, disclosed: OpenSRO has no PK system
(murderers, PvP capes, guild wars), so the rest is refused 0x3025
PK_PROHIBITED_IN_THIS_SERVER -- the engine's code when its PK-off byte is set.

The monster branch (s:0x52967d): a trader or hunter cannot hit an NPC hunter
(characterdata TypeID4 3 of a 1/2/1 row), a thief cannot hit an NPC thief
(TypeID4 2), a player out of a job neither (MEASURED: MOB_THIEF_NPC /
MOB_EU_THIEF_NPC are TypeID4 2, *HUNTER_NPC 3). The monsters' own filter
(CGObjMob::vslot_394, s:0x529110): an NPC hunter targets thieves only, an NPC
thief traders and hunters only; a COS by its owner's job.

### Death and credit

ResolveDeathCause (s:0x4e6590) gives cause 1, the job death, when an opposed
player wearing a suit kills, or an NPC thief kills a trader or hunter, or an
NPC hunter kills any job. Its handler (s:0x4e6820): job exp minus 3 x
Unit(victim level) (jobs.DeathLoss), character exp minus 6 x leveldata's exp
unit at min(victim, killer) level (less a premium reduction OpenSRO does not
have), and none of the normal death penalty. OURS: the loss never takes a
level away. The kill credit (s:0x4e1f60): the killer's KillExp, shared in a
party (s:0x5bd7f0: each member alive, in the zone and within 1000.0 gets
KillExp(member) x level / sum of levels x (1 + 0.05 (n - 1)); a hunter killer
shares only with hunters), and, for a player victim, 3 x the exp unit at
min(killer, victim) level of character exp.

### The wire

- OpAttack (0x0060 in OpenSRO's own numbering) gains an optional trailing u8:
  3 the target id is a character, 4 a COS uid (OURS: retail's 0x7074 names
  any object by its uid). OpUseSkill's targetType 3 names a character for a
  hostile row; a COS uid under targetType 1 names a COS.
- The answer is OpAttackResult with targetType 3 or 4; a refusal carries the
  UIIT key of the code as its error.
- OpPlayerStruck 0x0118 (OURS) tells the zone, the attacker too: `u32
  attacker, u8 kind (0 character, 2 COS), u32 target, i32 damage, u8 flags (1
  critical, 2 blocked, 4 died), i32 hp, i32 max hp`; the struck character's
  own copy adds `i64` the character exp the death cost.
- OURS, disclosed: a hostile skill strikes its primary target only; knockdown,
  knockback, the imbue's add and the skill's states do not reach a player or a
  COS; the swing repeats at the base attack's re-use delay while the target
  lives and stays in reach, ending at a move, a cast, a death or a refusal.

### The client (READ)

- A click on another player (c:0x792f00) attacks only when he is already the
  selection or Alt is held (GetKeyState 0x12), then IsEnemy(Alt) (CICUser
  vslot 42, c:0x9de780): job opposition on the spawned job states (c:0x9d02c0);
  else, while neither side wears a PvP cape, two players who both wear a job
  suit (slot 8 of each, FUN_00666e60 -- INFERRED: the suit test) are not
  enemies whatever is held; else Alt makes one. A party member is not
  attacked; under level 20 the click says 0x3016.
- An offensive skill at a player asks the same IsEnemy with Alt's state
  (c:0x81bc93..0x81bcaf); not an enemy: dropped silently; a party member:
  0x3022.
- Another player's job state is written only by the spawn reader
  (c:0x9de3d6 -> vslot 44); the 0x3038 handler (c:0x8a9260) only re-dresses.
- The name colour (c:0x9cfd50): the viewer's worn suit against the other's
  job state; opposed 0xffff6262.

## Safe trade (round 802)

`server/internal/session/safetrade.go`, `jobs.SafeTrade`. A trader's
_CharTrijobSafeTrade row: AbleCount, Status, LastSafeTrade.

- **Granted** when a trader closes a specialty trader's dialog
  (EndInteraction s:0x510833 in INTERACTMODE 5 or 6 at an NPC with 0xc ->
  s:0x60e800 / s:0x60e890): special goods (3/3/8/2) in a transport, or a scale
  other than 1, make him ineligible (Status 0); with TRADE_SAFETY_OPTION 0
  (counted, the shard's, MEASURED) one of TRADE_SAFETY_NUM (8, MEASURED) grants
  a server-local day -- a grant while already safe counts nothing -- the
  count reset at the first select of a 0xc NPC of a new day (s:0x60e690);
  option 2 always grants, option 1 never.
- **Lost** when the scale leaves 1 (s:0x5237b0), at the sale of his own goods
  (s:0x4c8e20), at the pick of a bargain good (s:0x5261ef), at the suit's
  removal (s:0x4f0dd4).
- **0x34D5** `{u8 status, u8 code[, u8 count, u8 num]}` (s:0x51a960): `{1,
  0x50, count, num}` granted, `{0, 0x41}` the day's limit, `{0, 0x40}` lost or
  ineligible; at login (CGObjPC::vslot_391 s:0x4e0020) `{1, 0x51, count,
  num}` or `{0, 0x40}`.
- **The client** (UI_SAFETRADE c:0x891080): status 1 puts the buff board's
  kind-0xb entry up (FUN_00777f20(0xb, 0, 1); its icon
  `icon\etc\icon_safetrade_progress.ddj` c:0x7ff32f, its tooltip
  UIIT_STT_SAFETRADE_PROGRESS c:0x802589, no gauge c:0x805c3f), and code 0x50
  shows UIIT_MSG_SAFETRADE_PROGRESS ("Safe trade will begin.[%d]/[%d]") with
  count and num on the warning banner (c:0x77b580) -- skipped while a byte at
  +0x20fc of the object at c:0xeef5ec is set (OPEN: what it is); status 0
  takes the entry down (FUN_00777f20(0xb, 0, 0)), and 0x41 writes
  UIIT_MSG_SAFETRADE_NUMBER_ERR_LIMIT to the system lines (c:0x7781b0).
- OURS, disclosed: the select reply's own safe-trade tail (option, num, count
  after the interaction ids, s:0x52b040) is not sent; the client reads the
  counts from 0x34D5.

### Still OPEN

The +0x20fc byte that hides the banner; FUN_00666e60's exact test; what
retail draws for a player killed in view by another (the death clip, the
corpse); the NPC thieves' and hunters' caravan waves (next round).
