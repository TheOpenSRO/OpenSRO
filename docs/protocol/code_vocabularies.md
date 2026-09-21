# Code vocabularies, and the lever that finds them

Some functions take a small integer that says *which* of something the caller
means: an event kind, a query id, a parameter id. Recovering one of those
vocabularies labels every call site at once, which makes it worth far more than
naming the function alone.

**The lever.** In the server disassembly, a call target with many sites whose
last pushed immediate *varies* is a vocabulary candidate. Swept across all 23,424
call targets. `ItemEventLog_Record` is the control: it comes back at 43 codes /
49 sites, matching the count reached independently by hand in round 341.

**Read the calling convention first.** These functions are `__fastcall`: ECX and
EDX carry the first two arguments and the rest are pushed, so the last
`push <imm>` before the call is the first *stack* argument. Ghidra shows the
stack arguments and drops the register ones, which is why a decompiled signature
can flatly contradict its own call sites without either being wrong.

## The guards — one of which was published wrong

Round 342 stated two guards. **The range test holds. The reuse test does not, and
it would have thrown away a real vocabulary.**

| guard | verdict |
|---|---|
| **Value range**: codes cluster in a byte; `__LINE__` spreads over thousands | **holds** — `CGameServer::FUN_00964760` has 128 codes over 43…4730 across 135 sites and is an assert reporter, not a vocabulary |
| **Codes reused across callers** | **WRONG as a requirement** — see below |

`AQ_Siege_SubmitQuery` has 29 codes across 29 sites, one raiser each, and is a
genuine enum: **each query id has exactly one raiser because each query is its
own function**. A one-to-one code/site ratio is normal for an enum whose members
are separate functions, and only suspicious when the *range* is also wide.

So: **reuse is a positive signal, not a requirement.** Range is the test that
discriminates.

## Recovered so far

### `AQ_Siege_SubmitQuery` (`0x00456ec0`) — the siege queries

The strongest case in the sweep, because **the callers carry the engine's own
constant names**:

| id | caller |
|---|---|
| `0x0` | `AQ_Siege__QUERY_SIEGE_TAX_RATIO` |
| `0x1` | `AQ_Siege__QUERY_SIEGE_TAX_ACCUMULATE` |
| `0x2` | `AQ_Siege__QUERY_SIEGE_TAX_COLLECT` |
| `0x3` | `AQ_Siege__QUERY_SIEGE_HIRED_NPC` |
| `0x4` | `AQ_Siege__QUERY_SIEGE_TEMPORAL_OWNER` |
| `0x5` | `AQ_Siege__QUERY_SIEGE_MODIFY_GUILD_INTRODUCTION` |
| `0xa`, `0xb` | `..._REQUEST_ADD`, `..._REQUEST_REMOVE` |
| `0xc`, `0xd` | `..._ITEM_FORGE_ADD`, `..._ITEM_FORGE_REMOVE` |

### `Param_RefreshContributions` (`0x004b3570`) — parameter ids

Takes `(paramId, sourceKind)` and asserts `0x1ff < paramId`, so **the param-id
space is 0..511** (also recorded in `engine_limits.md`).

**The callers validate the reading exactly**, because their names encode the ids
they pass:

| caller | passes |
|---|---|
| `AbnormalState_Apply19_p178_179` | `0xb2`, `0xb3` = 178, 179 |
| `AbnormalState_Apply20_p180_181` | `0xb4` = 180 |
| `AbnormalState_Apply13_p11` | `0xb` = 11 |
| `AbnormalState_Apply21_p3_143` | `0x8f` = 143 |
| `AbnormalState_Apply22_p4_144` | `0x90` = 144 |
| `Param5And6_ApplyOrRemoveContribution` | `0x5`, `0x6` |

178/179 are the attacker damage params of the recovered damage pipeline, so this
is the same id space the combat work already uses.

### `CGuildMamager__SendOlappedGuildJobReqToSM` (`0x005c80a0`)

Already named (the engine's own spelling). 24 sites, 23 guild-job request ids
`0x0`…`0x32`, each raised by one `trs_sm_guildjob` / `AQ_GuildQuery` function.

## Deferred, with the reason

`0x0063d4a0` — 21 sites, 15 codes `0x2`…`0x1f`, raised by
`CGObjChar::CanBeEquipedAt`, `CGObj::EnterWorld`, `Item_HandleUseItem`,
`CGObjPC::EnterScriptMode`, `CGObjCOS_Summoned::SetBodyMode`. It looks like a
character state/mode test, and `Item_HandleUseItem` calls it with `0xc` before
allowing an item to be used.

**Not named, because the argument roles are not settled.** The decompiled body is
`bool f(int param_1)` computing `param_1 + in_EAX * 0xc` — so `param_1` is a
*base* and `in_EAX` an *index*, which cannot both be true of a call site that
passes the code on the stack. That is the same mismatch `ItemEventLog_Record` had,
and it took reading the disassembly to resolve. Until that is done here, naming it
would be guessing which operand is the state.

## Sharpening the lever: rank by whether the callers are readable (round 344)

A vocabulary is only worth recovering if its call sites can be *read*, and what
made `AQ_Siege_SubmitQuery` readable was that its callers already carried the
engine's own constant names. So the sweep now ranks candidates by **how many of
their callers are already named**, with two filters: the corrected range guard
(codes at or below `0x400`) and dropping the CRT address range, which otherwise
fills the top with `__lock`, `_strlen`, `__calloc_crt` and `__isctype_l`.

The three vocabularies already recovered rank 1st, 2nd and 4th among non-CRT
hits, which is the control.

### `COpenMarketMgr__PostAsyncQeury` (`0x0047b230`) — the open-market queries

Same shape as the siege queries, and the function was already named (with the
engine's own spelling). The callers are its `On*Req` handlers:

| id | raised by |
|---|---|
| `0x0` | `COpenMarketMgr__OnPutonGoodsReq`, `COpenMarketMgr__OnPutoutGoodsReq` |
| `0x1` | `COpenMarketMgr__OnReceiptReq` |
| `0x4` | `COpenMarketMgr__OnSearchReq` |
| `0x5` | `COpenMarketMgr__OnPurchaseGoodsReq` |
| `0x7` | `COpenMarketMgr__OnGoodsDetailDataReq` |
| `0x8` | `COpenMarketMgr__UpdateOpenMarketGoods` |

### `0x0050cd80` — a guild/siege operation code

9 codes across 41 sites. `0xf` is raised by `CGuildManager::HandleCreateGuild`
and `GObjPC_HandleGuildMsg_0f1`; `0x17`, `0x18`, `0x19`, `0x1a`, `0x1b`, `0x1f`
and `0x28` are all raised by `SiegeFortress_DispatchCommand`. The function is
**not named here** — seven of its nine codes come from one caller, so the callers
do not distinguish them, and what the code selects has not been read.

## Two candidates closed as negatives

### `0x0063d4a0` is infrastructure, not a character state test

Round 343 deferred this one and guessed it "looks like a character state/mode
test", because `Item_HandleUseItem` calls it with `0xc` and the other callers are
`CanBeEquipedAt`, `EnterWorld`, `EnterScriptMode`, `SetBodyMode`. **The guess was
wrong.**

Read from disassembly: `ret 0x8`, so two stack arguments plus a register one —
`f(EAX = index, object, code)`. The body indexes a 12-byte-stride table off a
global at `ds:0xd6a9f0`, compares a generation counter against a "currently held"
pointer, and falls into a noreturn SEH throw helper (`0x0063d800`) on mismatch.
That is an ownership/re-entrancy guard, and **its own body never reads the code
argument at all**. The callers are game logic; the function is not.

### `0x00540d00`'s codes are neither AI messages nor AI states

Its callers are `CAIState_FOLLOW::OnEnter`, `CAIState_HOMING::OnEnter`,
`CAIState_BATTLE::OnEnter`, `CAIState_FLEE::OnEnter`, `CAIState_PICKITEM::OnEnter`
— which makes an AI vocabulary look obvious. It was tested against both enums
this project has already recovered, and fails both:

- **Not `ai.Message`.** Those are `0x21`–`0x2b`; these codes are `0x0`–`0xa`.
- **Not `ai.State`.** Those are `0`–`15`, so the range fits, and `BATTLE` passes
  `0x3` while `StateBattle` is 3, and `FLEE` passes `0x4` while `StateFlee` is 4
  — but `FOLLOW` passes `0x0` (which is `SPAWN`) and `HOMING` passes `0x2` (which
  is `WANDER`). Two agreements out of five is what coincidence looks like in a
  small dense range, and `BATTLE::OnEnter` passes three different codes anyway.

So it is left unnamed. Recorded because the caller list makes a wrong reading
attractive, and because having two independently recovered enums to test against
is exactly what stopped it.
