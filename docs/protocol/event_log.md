# The server's event-record formatters

Recovered 2026-09-20 (rounds 338–340). The server keeps a human-readable record
of what happens in the world — kills, guild wars, job rewards, item drops, token
spends. Three functions carry it, and they sit next to each other in the image.

| address | name | what it does |
|---|---|---|
| `0x00936640` | `CGameServer::LogFormatted` | the sink: `__vsnprintf_s` into an 8,191-byte buffer, first argument a category mask |
| `0x00467100` | `GameEventLog_FormatRecord` | 5,067 B. Character and world events |
| `0x00469100` | `ItemEventLog_FormatRecord` | 7,622 B. Item and currency events |

Both formatters are a `switch` over an event kind that builds text and hands it
back through out-parameters. **Neither logs directly** — `ItemEventLog_FormatRecord`
makes zero calls to `LogFormatted` — so where the records finally go is not
established here and is not claimed.

## What each one is, from its own strings

`GameEventLog_FormatRecord` — guild war outcomes
(`GuildWar Guild[%d,%d] Winner[%s]`, `... Surrendered Guild[%d]`), guild
investment (`Invested %d SP to guild [%s]`), the trade-route jobs
(`Trader Contributed to hunter guild: %u gold`, `Trijob Reward Received: %u gold`),
`Mercenary Count[%d]`, `Starvation`, `CampID : %d`, and PvP kill records
(`%s,%s,%s vs %s(PC),%s,%s,%s`, the same with `(PET)`, and
`[%s vs %s(victim: %s)]`). It calls `JobTypeName` ten times.

`ItemEventLog_FormatRecord` — item serial changes
(`%d : Serial Change %I64d -> %I64d`), drops and pickups
(`%I64d, %I64d -> %I64d, %s, %s, picker[%s]`, `0,failed to drop item`,
`0,Unknown,picked item == NULL`), the four arena token currencies
(`Remain TokenGold / TokenSilver / TokenBrass / TokenMedal : %d ==> %d`) and
`%I64d, Trader JobLvl: %d`. It calls `GObjPC::DumpItemWithOptions` eleven times.

**`ItemEventLog_FormatRecord` was characterised before it was named.** The
2026-09-17 entry in `RE_COMPLETION.md` already described this address as "a
7,622-byte logging function full of item-serial, drop, gold and token messages",
reached by a different pass while disproving a label-based naming rule. It was
never filed as a name until round 340 — the same gap as
`MsgBuf_ReadUInt32FromTail`, which sat identified in a published table for eleven
rounds. **Being characterised in prose is not being named.**

## The item-event kind vocabulary (round 341)

Round 340 left `0x00468a80` unnamed because Ghidra's argument order contradicted
its call sites. **Settled from disassembly, and both readings were true of
different parameters.** The convention is `__fastcall`:

	push 0x39            <- last push before the call: the first STACK argument
	mov  edx, ebp        <- second register argument
	mov  ecx, ebx        <- first register argument (the object)
	call 0x468a80

ECX and EDX carry the object; the small constant is the next argument along. So
the decompiler's `param_1 = int *` (ECX) and the call site's `0x9f` (first stack
arg) were never in conflict — they are different parameters, and the mismatch was
Ghidra dropping the register ones.

`0x00468a80` is now `ItemEventLog_Record`: the entry point an operation calls to
record what it did to an item. **49 call sites, 47 carrying a kind immediate, 43
distinct kinds, every one inside an already-named caller.**

### The cross-check

A kind that appears at several sites should mark the same *action*, not the same
*function* — and it does:

| kind | raised by | |
|---|---|---|
| `0x9f` | `CEnchant_SocketMaker::vslot_009`, `CEnchant_SocketStoneEraser::vslot_009`, `CEnchant_SocketStoneInserter::BlessItem` | three functions, one socket operation |
| `0x83` | `CEnchant_EnchantMagicStone::MakeAttempt`, `CEnchant_EnchantAvatarItem::MakeAttempt` | two enchant attempts |
| `0x50` | `CGObjPC::OffsetGold`, `FUN_00513250` | two gold paths |

That is what an event kind should do, and it is why the caller is taken as
evidence rather than as a coincidence of position.

### The table

Each kind is named by the operation that raises it. **This is a use-site, not a
curve**: the caller is an already-recovered name, and the kind is the constant it
passes.

| kind | raised by |
|---|---|
| `0x10` | `Item_HandleUseItem` |
| `0x32`, `0x33` | `TradeMgr::CTradeMgr__OpenTradeSession` |
| `0x34` | `TradeMgr::CTradeMgr__EstablishTradeSession` |
| `0x35` | `FUN_004808d0` |
| `0x36` | `TradeMgr::OfferItemToPartner` |
| `0x37`, `0x38` | `FUN_00480c70`, `FUN_00480f30` |
| `0x39`, `0x3b`, `0x3c`, `0x74` | `AQ_ItemXChanger::ValidateItemExchange` |
| `0x46` | `FleaMarket_HandleOpenStall` |
| `0x47` | `FUN_00515da0` |
| `0x48`, `0x49`, `0x4a` | `FUN_00472e20` |
| `0x4b`, `0x4d` | `FleaMarket::CFleaMarket__SellFMarketItem` |
| `0x50` | `CGObjPC::OffsetGold`, `FUN_00513250` |
| `0x5a`, `0x5b` | `CEnchant_Reinforce::MakeAttempt` |
| `0x6e`, `0x99`, `0xaa` | `CGItemExpendable::UseByKind` (it switches on the item kind) |
| `0x70`, `0x71` | `FUN_004c7e20`, `GObjPC::FUN_004ed910` |
| `0x82` | `CEnchant_EnchantMagicStone___BlessItem` |
| `0x83` | `CEnchant_EnchantMagicStone::MakeAttempt`, `CEnchant_EnchantAvatarItem::MakeAttempt` |
| `0x84`, `0x87` | `CEnchant__SetEnchantMagicToAttrAssim`, `CEnchant__SetEnchantAttrToAttrAssim` |
| `0x85`, `0x86` | `CEnchant_EnchantAttrStone::vslot_009` / `::MakeAttempt` |
| `0x88` | `CMakeStuff_Compound::FUN_00509d00` |
| `0x89`, `0x8a` | `CMakeStuff_ResolveEquip`, `CMakeStuff_ResolveMaterial` |
| `0x8b` | `CGObjPC::vslot_358` |
| `0x94` | `CBless_AvatarItemWithNPC` |
| `0x97`, `0x98` | `GObjPC::CGObjPC___AsyncQuerySucceeded` |
| `0x9f` | the three `CEnchant_Socket*` functions above |
| `0xa0` | `CEnchant_UpperReinforce::MakeAttempt` |
| `0xa9` | `CTJ_OpenMarketTicketKeeper::FUN_00655670` |

**Two call sites pass no immediate** — `CTimedJobManagerForPC::vslot_005` and
`CTimedJobManagerForPet::vslot_005` build the kind in a register instead, so they
are not in the table rather than being guessed at.

**What this does not say.** The kind numbers are the server's own; nothing here
maps them to a name the game uses for them, because no such table has been found.
The caller tells you what the event *is*, not what it is *called*.

## The lead as it stood (round 340), now closed above

`0x00468a80` calls `ItemEventLog_FormatRecord` and is itself called from **50
sites**, each passing a distinctive small constant — `0x9f`, `0x83`, `0x50`,
`0xaa`, `0xa9`, `0xa0`, `0x99`, `0x94` … That looks like a vocabulary of item
event kinds, and recovering it would label fifty call sites at once.

**It is not taken here, because the argument order is not trustworthy.** Ghidra
types the first parameter as `int *` and the body immediately uses it as an
object with a vtable (`(**(code **)(*param_1 + 0x1c))()`), yet the call sites
read `FUN_00468a80(0x9f, …)`. Both cannot be the first argument. This is exactly
the shape that forced round 323's retraction, where Ghidra's argument for
`Msg_SendTwoFieldReply` was wrong and a whole conclusion rested on it — the real
operands were an immediate pushed on the stack and a value in ECX, readable only
from disassembly.

So the next step for this lead is to read the call sites in `srgs.asm` and settle
which operand is the kind, before any of the fifty is labelled.

## The character/world vocabulary, and the sweep that found it (round 342)

Round 341 recovered the item-event kinds by hand. The *shape* generalises: a call
target with many sites whose last pushed immediate varies is a vocabulary. Swept
across the whole disassembly, with `ItemEventLog_Record` as the control — it came
back at **43 codes / 49 sites**, matching round 341's independent count exactly.

`0x00466f90` is now **`GameEventLog_Record`**: 84 sites, **56 distinct kinds**, 75
callers, and it calls `GameEventLog_FormatRecord`, which is what places it in this
family rather than the item one. Kinds are named by their callers, all
already-recovered names:

| kind | raised by | |
|---|---|---|
| `0x09` | `CMainProcess::CGame__EnterWorld` | entering the world |
| `0x16` | `GObjPC::GObjPC_SetLevel` | level set |
| `0x17` | `GObjPC::GObjPC_GainExpAndLevel` | exp gain / level up |
| `0x18`, `0x19` | `GObjPC_HandleIncreaseStr`, `GObjPC_HandleIncreaseInt` | stat spend |
| `0x1a` | `Mastery_LevelUp` | mastery raise |
| `0x3d`–`0x55` | `trs_sm_guildjob::*`, `trs_wait_response::*` | the guild-job state machine |
| `0x5d`, `0x5f` | `GObjPC::CGObjPC___AsyncQuerySucceeded` | async DB results |
| `0x67`–`0x70` | `TrainingCamp_RequestOpenJob`, `TrainingCamp_SendOpenResult`, `trs_sm_trainingcampjob::*` | academy |
| `0xd5`, `0xd6` | `CGObjCOS_SilkPet::vslot_368`, `CGObjCOS_GoldPet::OffsetExpPoint` | pets |
| `0xd9`, `0xdb` | `CGItemExpendable::SetEngagedCOSforOpenMarket`, `::vslot_328` | open-market COS |
| `0xea` | `FLAG_WORLD_EVENT_HANDLERS::OnDea…`, `CMainProcess::*` | world event flags |
| `0xef` | `CBattleArenaInfoFlag::*`, `CMainProcess::*` | battle arena |
| `0xf4` | `GObjPC_HandleCallUserMsg_51a` | call-user |

**A second entry point shares the kind space.** `0x00467050` (29 sites, 20 kinds)
also calls `GameEventLog_FormatRecord`, and its kinds — `0x3d`, `0x3e`, `0x44`,
`0x68`, `0x69`, `0x6a` — appear in `GameEventLog_Record`'s list too, from the same
guild-job and training-camp callers. **It is left unnamed**: both functions take
their object in ESI and `0x467050` shows no stack parameters at all, so what
distinguishes the two is not settled, and a name would have to claim it.

## The guard this lever needs

The sweep's top hit by raw count was **not** a vocabulary. `CGameServer::FUN_00964760`
has 128 distinct immediates across 135 sites — nearly one per site — and they run
**43 … 4730**. Those are `__LINE__` values: the function takes `IsDebuggerPresent`,
`__vsnprintf_s` and `__CxxThrowException_8`, so it is an assert/fatal reporter
whose callers pass their source line. It carries no string of its own, so it is
**not named here** either.

So the lever needs two guards, both cheap:

- **one code per site is a warning, not a win** — a real vocabulary reuses codes
  across callers (`0x9f` from three socket functions, `0x50` from two gold paths);
- **check the value range** — line numbers spread over thousands, event kinds
  cluster in a byte.

Other candidates the sweep surfaced, unexamined: `0x00456ec0` (`AQ_Siege`, 29
codes), `0x005c80a0` (23), `0x004b3570` (20), `0x0063d4a0` (15).
