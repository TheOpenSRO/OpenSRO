# Exchange spec: adversarial verification (round 834)

The claims in `docs/protocol/exchange.md` that the implementation depends on, re-read from the
binaries on 2026-10-26: `SR_GameServer.exe` (`/var/tmp/gs_dis.txt`, `/var/tmp/decomp_server`),
`sro_client.exe` (`/var/tmp/sro_client.dis`, `/var/tmp/decomp_client`) and Media.pk2
(`resinfo\ifexchange.txt`, `resinfo\ginterface.txt`, `config\define.txt` and
`server_dep\silkroad\textdata\textuisystem.txt`, extracted on the box only). `s:` is a server
address and `c:` a client address. The probe scripts are in the round's scratchpad
(`r834/verify_ex/`).

Verdicts:

- **CONFIRMED**: the code at the cited address says what the spec says.
- **CONFIRMED+**: right, but the code does more, and that matters.
- **WRONG**: the correct reading is given.
- **PARTLY**: the claim's chain was not re-read end to end.

## WRONG items first

| # | Spec claim (section) | Correct reading | Evidence |
|---|---|---|---|
| W1 | §2.1 step 1: `FUN_004f0a00(1)==1` means the request is "dropped silently" | Not silent. `0x4f0a00` checks restriction slot 3 at pc`+0x188` (`0x40b870`). When that check is true, it sends **`0x3405 [u8 1][u32 packed time]`** to the requester and returns 1. The `081` handler then returns with no `0xb081`. | `s:0x4f0a6c` `push 0x3405`; append size 1 at `0x4f0a7b` (the argument byte) and size 4 at `0x4f0a95` (`0x4f8860` result); sent through vslot `0x27c` at `0x4f0aac`. Caller `s:0x515530`. |
| W2 | §2: `FUN_0047fc30(expect,next)` "checks the session state and the caller's own state" | It checks **only the session state**: session state ≠ `expect` gives `0x181f`, and a missing partner gives `0x1820`. It then writes the caller's state to `next` and reports whether both participants are at `next`. Consequences for presses out of order: **a second Confirm while the session is still at 2 is accepted again.** The server resends `0x308c` to both, `0x3089` and `0x3086` to the partner, and `0xb082 [1]`. **A second Approve at session 3** gets `0xb083 [1]` again. Confirm at session 3, or Approve while the session is at 2, gives `0x181f`, which is in the close list, so the session closes. Only the move ops check the caller's own state (`p+0x24 == 2`). | `s:0x47fc5c` `cmp ecx,[esp+0x14]` → `0x181f` at `0x47fc62`; partner gone → `0x1820` at `0x47fcb0`; own state written at `0x47fce9`; both-equal test from `0x47fcef`. Own-state checks: add `0x480ac2`, remove `0x480cf0`, gold `0x480fcb`. |
| W3 | §2.2 "Every failure goes to both as `0x3088 [code]`"; §2.7 "Both players then get `0x3088 [code]`" for every code in the close list | **`0x1811` never produces `0x3088`.** `SendItemExchangeResult` takes its abnormal path when the session is at state 5 **or** the code is `0x1811`. That path logs "Trading Session Closed Abnormally", calls `0x4ea0a0(0)` and **disconnects both participants** (`0x4df050(4)`). Nothing is sent, and `0x182a` is only the return value. The `0x1811` closes are: Establish with INTERACTMODE ≠ 1, Approve with INTERACTMODE ≠ 2, DealIt's COS check, and the failure to post the DB job. Two more codes send nothing: `0x181b` (no session) returns without sending, and `0x1825` (the caller is not a participant) **frees the session without sending anything or resetting INTERACTMODE**. | `s:0x48073f` (`state==5`), `0x480745` (`cmp word [ebp+0x10],0x1811`) → `0x48080d`; disconnect `0x480884`; `0x181b` return at `0x480715`; `0x1825` at `0x480762` → `0x48089d` (`0x43c7b0`, `0x9dd03d` free, `0x481620` erase). |
| W4 | §2.7.3 "A database failure (`AQ_ItemXChanger::vslot_008`) sends `0x1811`" | Nothing is sent. `vslot_008 s:0x43ff40` case 0 calls `0x4806d0(0, session, 0x1811)` while the session is at state 5, so **both players are disconnected** (W3). | `s:0x43ff85` → `0x4806d0`; the state-5 branch is at `0x48073f`. |
| W5 | §2.7 last paragraph: "`0x3088 [code]` comes after the `0xb08x`/`0xb034` refusal" | That order is right for `0x7082`/`0x7083` (`0xb08x [2]` first, then the close). **For the move ops 4/5/0xd it is reversed.** The op function itself closes the session (`0x3088` to both) before it returns, and `StorageOperation` only then sends `0xb034 [2][code]`. On `0x1811` the handler also disconnects the mover. For `0x7084` the order is `0x3088 [0x182c]` to both first, then `0xb084 [1]`. | Op closes: `s:0x526a32`, `0x526aad`, `0x526eb1`. `0xb034` refusal: `0x50f6e0`/`0x50f6e7`. Disconnect on `0x1811`: `0x50f6ec..0x50f717`. Confirm and approve: `0x5158a9` → `0x5158d9`, `0x515978` → `0x5159a8`. Cancel: `0x5159e7` → `0x515a0d`. |
| W6 | §4.3 trust check: guild = `0x997410`, union = `0x995ed0`, friend = `0x996d60` | The set {guild, union, friend} is right, **but the addresses are mislabelled.** `0x997410` = **friend list**: the opponent's name (`obj+0x110`) against CharacterDependentData `+0x24c`, the list the friend connect/disconnect handler `c:0x886310` maintains. `0x995ed0` = **guild members**: the name against `+0x1d0`, used by the UI_GUILD functions `0x5b5150` and `0x5afc70`. `0x996d60` = **union**: it takes the opponent's **guild name** (`0x9db100` = `obj+0x7e4`) and compares it with the allied-guild list at `(CDD+0x148)+0x98`. The same call is used by the fortress owner/ally test `c:0x6fe1ca` and the guild-window colouring `0x9a447e`. The test order is friend, guild, union. | `c:0x7b22a1`/`0x7b22bb`/`0x7b22d5`; callers of the list maintainers: `0x886469` (`0x997290`), `0x5b523d`/`0x5afd94` (`0x9960a0`/`0x995fd0`). |
| W7 | §4.2 "UIIT_STT_PARTY_SOMEUSER … the generic subject of every request popup" | It is used by **exactly three popup kinds**: 6 and 8 (party invitation, with UIIT_STT_PARTY_PROPOSAL_ASK) and 7 (exchange, with UIIT_MSG_DEAL_ASK). The guild join (kind 15, UIIT_MSG_GUILD_JOIN_REQUEST), friend (kind 35, UIIT_MSG_FRIEND_REQUEST_01/02), resurrection and other popups use their own keys. | The popup switch at `c:0x644d20` (`jmp [eax*4+0x648758]`, index = kind − 1). Kind 7 → `0x64602e`; kinds 6 and 8 → `0x645c59`. The only `push 0xd9cff8` (PARTY_SOMEUSER) are at `0x645cb0` and `0x64605c`. |
| W8 | §4.2 "a private overlay block (19 columns, rows ≥ ~7400) … The screenshots show the retail rows (first block, 16 columns)" | **This contradicts `chat.md` (round 725).** That doc labels lines 1–6955 (16 columns) as a private server's rewording and lines 6956+ (19 columns) as stock. The archive does not settle which label is right: the 19-column copies of these exchange keys carry the "CHECK THE NAME!" / "***READ***" texts, and the 16-column copies have Korean mangled to `?`. **What is certain:** the original client keeps the *first* row of a duplicated key, and for English it reads column 8 (`chat.md`, READ `0x8cb266`/`0x8ca120`), so it shows the 16-column rows. **OpenSRO's `UiTextTable.select_rows` does the opposite** (round 725's joined-table rule). Unless these keys get a first-row exception like `keeps_first_row`, OpenSRO would show `[%s] sent you  party invite. CHECK THE NAME!`, `Exchange request! HAVE YOU CHECKED THE NAME?` and the `***READ***…` banner. | textuisystem line 2411 (16 col) vs 9299 (19 col) for PARTY_SOMEUSER, 2024 vs 8912 for DEAL_ASK, 4821 vs 11672 for DECEPTION_COMPARE. `client/scripts/ui/ui_text_table.gd:158-205`. |
| W9 | §4.3 Done step 5: "The log/system line UIIT_MSG_EXCHANGE_END" | EXCHANGE_END goes to the **system line only** (`0x7781b0`), not to the window log. ITEM_EXCHANGE_SUCCEED goes to the notice. Step 3 also omits window **0xaf**, which is notified as well as 0xb2. | `c:0x88bb50` (key `0xddc760`). |
| W10 | §4.3 ginterface: "The `#else` branch is 363×363" (and §4.3's "`#else` x values" for the screenshot buttons) | Strictly, 363×363 is the **inner** `#else`: `APPLY_EXCHANGE_UPDATE_1TH` defined without `UI_UPDATE_2009_FIRST`. The outer `#else` (no 1TH) is 254×361 again. `config\define.txt` defines both names, so the client uses 254×361. That part of the spec stands. | ginterface lines 563–571; define.txt lines 17–18; `#ifdef` lookup `0xb37a30` → `0x5004a0` (map `0xeed4e0`). |

## 1. Wire layouts

| Claim | Verdict | Evidence |
|---|---|---|
| Handler registration for every opcode | CONFIRMED | The client's table `c:0x8705f8..0x870ca8` binds b034→`87f370`, b081→`880330`, 3080→`88aa60`, 3085→`8803f0`, b082→`880430`, b083→`8804a0`, b084→`880520`, 3089→`880590`, 3086→`87fcb0`, 3087→`88bb50`, 3088→`880840`, 308c→`8806b0`. |
| `0x7081` = u32 target id | CONFIRMED | `c:0x81d947` is the only `0x508fe0` (size 4). Server reads the u32, then the self check (`s:0x51559f`). |
| `0x3080` invitation = `[u8 1][u32 requester id]`, no flags byte | CONFIRMED | Server `s:0x46c950` (eax=1), `0x46c964` (eax=4). For type 1, jump table `0x46cafc[0]` → `0x46caca`, with no third field. Client `c:0x88aaaf` reads u8, `0x88aabd` reads u32; case 1 reads nothing more. |
| `0x3080` answer = `[u8 1][u8 answer]`; Accept = 1 | CONFIRMED | `c:0x81dbf7`/`0x81dc03`. Accept `0x63b6e0` sets popup`+0x83c`=1 → `0x777dd0` → `0x797d90` → kind 7 → `0x81db80(answer)`. Enter takes the same path. |
| Refuse sends `[1][0]` (spec OPEN 4 had it INFERRED) | CONFIRMED (closes OPEN 4) | Refuse `0x63b8b0` sets `+0x83c`=0. Esc does the same when Refuse is shown. Auto-refuse `c:0x88aaef` (option byte `+2`==0) sends `0x81db80(0)`. Server `s:0x46cb30`: the answer must be exactly 1 to establish, and **any other value** gives `0x1828` to both. |
| Router: `[1]` → vslot 2; otherwise u16 + vslot 3 | CONFIRMED+ | `s:0x46f2d0`. Vslot 3 (`0x46cea0` → `0x46cec0`) closes the session with **the client's u16** as the code. The vtable is at `0xae650c`. |
| `0xb081 [1][u32 target]` to requester; refusals `[2][u16]` | CONFIRMED | Success at `s:0x47fb41`/`0x47fb54`, to participant 0 only. Every `081` refusal goes through `0x4e7250` (`0xb081 [2][code]`), never `0x3088`, since `081` does not call `0x515490`/`0x4806d0`. Return 1 means nothing is sent (`0x5157a1`). Client `c:0x880330`. |
| `0x3085 [u32 requester id]` to target; the client does not use it | CONFIRMED | `s:0x47fb6c` (size 4, session`+8`); `c:0x8803f0`. |
| `0x7034` add = `[u8 4][u8 bag slot]` (inventory index 13+) | CONFIRMED | `c:0x7957ad` (`add bl,0xd`, type 4). Serializer `0x7923a0` case 4 writes `+3` only (flag 0, `0x7963e1`). Server parser `s:0x4d8bf0` case 4 reads one u8. |
| `0x7034` remove = `[u8 5][u8 index]` | CONFIRMED | `c:0x795f9c` (no +13); serializer case 5 `0x79265e`; server case 5 reads u8. |
| `0x7034` gold = `[u8 0x0d][u64]`, zero not sent | CONFIRMED+ | `c:0x825f50` → `0x82607b` (`mov byte [struct],0xd`); serializer case 0xd `0x792a9e` writes 8 bytes; zero skipped at `0x825f9b`. **Addition:** the serializer clamps the value to 0..1,000,000,000 (`c:0x7923ee`), and the gold box is capped at min(gold carried, 1e9) (`c:0x6b2d8a`). |
| The move carries no count; the whole stack moves | CONFIRMED | Client count word `+6` is never serialized. Server bay entry (`0x471700`) holds slot `+8` and DBID `+0x10`, with no count. |
| `0x7082`/`0x7083`/`0x7084` bodies are empty | CONFIRMED | `c:0x81d9a0`/`0x81da40`/`0x81dae0` make no `0x508fe0` call. |
| `0xb082`/`0xb083`/`0xb084` = `[1]` or `[2][u16]` | CONFIRMED | Server `s:0x515877`/`0x515941`/`0x515a0d` (size 1); `[2]` via `0x4e7250`. Client `0x880430`/`0x8804a0`/`0x880520`. |
| `0xb034` success forms `[1][4][slot][idx]`, `[1][5][idx]`, `[1][0xd][u64]`; refusal `[2][u16]` | CONFIRMED | Server `s:0x50f906` then `0x4f76e0`: case 4 `0x4f7a85` (`+3`,`+4`), case 5 `0x4f7b4b`, case 0xd `0x4f7f5f` (u64 `+0x90`). Client `0x87f370` → `0x87eb50` (case 4 `0x87f065`). |
| `0x308c` = u32 owner, u8 n, then n × (`[u8 bag slot]` only to the owner, u8 index, record) | CONFIRMED | Server `s:0x480e50`: the bag-slot flag is `sete` (receiver == owner) at `0x480ee2`, and only-owner skipping at `0x480eb7`. `0x47ef00` writes the bag slot as the item's current slot, the index as a counter from 0, and the record via vslot `0x498(buf,1)` (`0x47f02b`). Callers: add `0x480bfe`/remove `0x480de9` → owner only; confirm `0x47fd91` → both. The only `push 0x308c` is at `0x480ece`. Client `c:0x8806b0` (owner == `DAT_00eef5e8`). |
| `0x3089 [2][u64 gold]`; kind 1 is parsed but never sent | CONFIRMED | `s:0x47fded`/`0x47fdfc` (eax=8) is the only push. Client `0x880590`: kind 1 = u8 + record (opponent grid), kind 2 = u64 → `0x7b2350`. |
| `0x3086` empty | CONFIRMED | `s:0x47fe1d`; `c:0x87fcb0` → `0x7b2670(1)`. |
| `0x3087` empty; `0x3088 [u16 code]` | CONFIRMED | `s:0x4806d0` → `0x4807aa` (code 1), else u16 (eax=2). Client `0x88bb50` reads nothing; `0x880840` reads u16. |
| `0x304E` kind 1 for each gold delta at completion | CONFIRMED | DealIt `s:0x4802a0`: vslot `0x16c` (= `0x4e4b60`) with (delta, `0x22`, 1, 0) → `0x4e3fb0`. Gold is moved before items. |
| Item record = the full retail record `AppendItemRecord` writes | CONFIRMED | Client `SOItem c:0x8be4f0`: rent block, u32 RefItemID (0 ends the record), then for 3/1 equipment u8 plus, u64 variance, u32 durability, magic options (u8 n × u64), two binding blocks; a count or COS state otherwise. This matches `session/iteminfo.go`. It is **the same reader with the same flag** as the own-player data `0x3013` (`CICPlayer::vslot_025 c:0x9d9b5c`). Server: vslot `0x498` mode 1 → `CGItem s:0x48fb60` → instance vslot `0x28` mode 1 → `CInstanceItem s:0x42e230` (modes 1 and 4 alike). |
| …equals `pc_spawn.md`'s record | **Not equal; not claimed by the spec** | `pc_spawn.md` row 8 is the spawn message's worn list, the short mode-2 form (RefItemID + plus). The exchange record is the full mode-1 form. Compare against `AppendItemRecord`, not `pc_spawn.md`. |
| Opponent-confirmed message = `0x3086` | CONFIRMED | See above. |

## 2. State machine

| Claim | Verdict | Evidence |
|---|---|---|
| The partner sees nothing of your offer until you Confirm | CONFIRMED | Add/remove send `0x308c` with only-owner = 1. Gold sends nothing to the partner (`s:0x480f30`). The only `0x3089` is in Confirm. |
| Confirm order: `0x308c` to both, then `0x3089 [2]` and `0x3086` to the partner, then `0xb082 [1]` | CONFIRMED | `s:0x47fd20` (session → 3 at `0x47fd6d` when both are at 3), then `0x515862`. |
| Approve accepted only after both confirmed; executes on the second Approve | CONFIRMED | `0x47fc30(3,4)` requires session 3, which only both confirms make. Not both at 4 → return 1 → `0xb083 [1]`, and the partner gets nothing. |
| Out-of-order presses | **WRONG in part, see W2** | Confirm repeated at 2 → accepted and resent. Approve repeated at 3 → `0xb083 [1]`. Confirm at 3 or Approve at 2 → `0x181f` → session closed. |
| Nothing resets a confirmation | CONFIRMED | Add, remove and gold write no participant state; only `0x47fc30` and Establish do. |
| A confirmed player cannot change the offer (`0x181f`) | CONFIRMED | Own-state checks at `0x480ac2`/`0x480cf0`/`0x480fcb`. `0x181f` closes the session (close list). |
| Close list `{2, 3, 5, 0x181b, 0x1825, 0x181f, 0x1820, 0x1823, 0x1841, 0x1811, 0x181c}` used by confirm, approve and moves | CONFIRMED | `s:0x515490`. Not used by `081`. Consequences: gold > 1e9 (code 2) and DBID 0 (code 3) close the session. |
| Completion: state 6, `0x3087` to both | CONFIRMED | `s:0x480530` (state at `0x480588`; vslot `0x144(0x21,0,item)` for items with vslot `0xb8` ≠ 0); then `0x4806d0(code 1)`. |
| On close both INTERACTMODEs → 0 before `0x3087`/`0x3088` | CONFIRMED (normal path only) | `s:0x48078c`. The abnormal path (W3) disconnects instead. |

## 3. Server checks and their order

| Claim | Verdict | Evidence |
|---|---|---|
| Request step 1 silent drop | **WRONG, see W1** | |
| Step 2 vslot `0x244(0x100)` → `0x185f` | CONFIRMED | `s:0x51555d`/`0x515563` |
| Step 3 self / not found / not PC → `3` | CONFIRMED | `s:0x51559f`, `0x5155c4`, `0x5155da` |
| Step 4 `FUN_004ea050` sub-cases (`0x181d`; `0x1833` for mode 2/7; mode 1 same target silent; other target → cancel with `0x182c` and continue; else `0x181d`) | CONFIRMED | `0x4ea050` = vslot244==0 && life==1 && INTERACTMODE==0 && GROUPMODE≠1. `0x515765`, `0x515750`, `0x51566d`, `0x51568e`, `0x51573b`. "Same target" also matches the requester of the pending session. |
| Step 5 3-D distance not below 320.0 → `4` | CONFIRMED | `.rdata 0xb460dc` = 320.0f; `0x405270` = sqrt(x²+y²+z²); `s:0x51571c` |
| Step 6 OpenTradeSession: busy `0x181e`, collision `0x1811`, wait fail `2`; state 1, both modes 1, wait type 1 | CONFIRMED+ | `s:0x47f6e9`, `0x47f733`, `0x47f75c`; state `0x47f7a7`; modes `0x47f8a9`/`0x47f8bd`; logs `0x32`/`0x33`. **Also:** a target that vanished or is not a PC → `3` (`0x47f943`). All go out as `0xb081 [2][code]` (`0x5157b4`). |
| 30 s wait; timeout → `0x1826` to both | CONFIRMED | `0xb45b48` = 30.0f (`s:0x46c817`); timeout `0x46ce37` |
| `0x1834` at the request is client-only | CONFIRMED | The server's `0x1834`s are all in StorageOperation/storage ops (`s:0x50f675..0x50f7e3`, `0x524404`, `0x526b19`, `0x526d14`). Client `c:0x81d790` (player `+0x7bc`, `0x9db000`) → `(1, 0x1834)`. |
| Accept: Establish order `0x181b`, `0x1825`, `0x181f`, `0x1827`, `4`, `0x1811` | CONFIRMED (order) / **WRONG (delivery), W3** | `s:0x47f970`, `0x47f9e1`, `0x47f9f1`, `0x47f0b0`, `0x47fc05`. `0x1811` is checked inside the per-participant loop, so participant 0 may already be at mode 2 and have `0xb081 [1]`. |
| Answer: not alive → `0x1840`, vanished → `0x1820`, other → `0x1828` | CONFIRMED | `s:0x46cb6e`, `0x46cc1d`, `0x46cc71`. `0x1840` is checked before the answer byte. |
| `0x7034` dispatch table `0xcd3b58` (op4 `0x526910`, op5 `0x526a50`, op0xd `0x526e20`); guard lets only 4/5/0xd through at mode 2/7 | CONFIRMED+ | Filled by `s:0x50ce80` (`0x50ceae..0x50cf12`). Guard `0x50f7cd`: other ops → `0xb034 [2][0x1834]`. Mode 4 → `0x1834` for all ops. |
| Add item: the 13 checks in order (`0x1806`, `0x1809`, `0x183a`, `3`, `0x18b6`, `0x18fa`, `0x181b`/`0x1825`/`0x181f`, `0x182d`, `0x1806`, `0x1821` at 12, `0x1820`, `0x1836`, `0x1850`) | CONFIRMED | `s:0x526910` then `0x480a20` (`0x480b58`, `0x480b6a`, `0x480b8c`). Partner space = `CountEmptySlot(0xd,-1)` < count + 1. |
| Add success: index = count before add; owner-only `0x308c`; log `0x36`; vslot `0x508(1)`; `0xb034 [1][4][slot][idx]` | CONFIRMED | `0x471700`. Note: remove never calls `0x508(0)`. |
| Remove: `0x181f`, `0x1824`, `0x1806` (index ≥ count or ≥ 12), `0x1820`, `0x1809`; later items shift down | CONFIRMED | `s:0x480c70` (`0x480d20`/`0x480d28`; erase `0x47edc0`); log `0x37` |
| Gold: ≤0 → `0x1829`; > 1e9 → `2`; state → `0x181f`; partner → `0x1820`; > carried → `0x180f`; replaces; not reserved | CONFIRMED | `s:0x526e20`, `0x480f30` (the amount checks run before the session lookup), `0x480f68`; `0x47ee70` overwrites `p+0x28` |
| Confirm needs session 2 | CONFIRMED (not the caller's state, W2) | |
| Approve checks: VerifyLoadedItemValidity `0x1841`; mode ≠ 2 `0x1811`; nothing `0x1823`; space `0x1841`; gold < 0 `0x1841`; first empty slots from 13 in bay order, else `0x1841` | CONFIRMED+ | `s:0x47fe40`; `0x47f0f0`; `0x47feea`/`0x47ff31`; `0x43c370`; `0x4b87f0(0xd,-1)`; `0x480029`/`0x480039`; `0x4801b0` → `0x4b8260` (`0x48024c`), log `ae72f8`. **Also:** vslot `0x274(0x80,0)` is called on each PC before the space count (`0x47ffbe`; meaning not established). A null session gives `0x181c`. |
| DealIt COS check aborts with `0x1811` | CONFIRMED (delivery per W3) | The receiver's vslot `0x5dc` non-zero → abort (`s:0x480456`); `0x4800d8` |
| DB post failure → disconnect both + `0x1811` | CONFIRMED (no `0x3088`, W3) | Logs `ae7340`/`ae73c0` ("both of participants will be logout!"); `0x4df050(4)`; then `0x4806d0(0x1811)` (`0x480182`) |
| DB failure → `0x1811` | **WRONG, see W4** | |
| Walking away does not cancel | CONFIRMED | All 16 callers of `0x4806d0` are listed below. None is a tick or movement routine, and none measures distance. |
| Death cancels with `0x182b` (INTERACTMODE 1, 2, 7) | CONFIRMED / PARTLY | `s:0x529ce0`/`0x52cf41` push `0x182b`, via tables `0x529dbc`/`0x52cfe8` (entries 0, 1, 6). That vslot_306/307 are the death paths rests on `return_scroll_cast.md` and was not re-read. |
| Warp / logout / disconnect cancel with `0x182b` | CONFIRMED | `s:0x4def2a`. Callers: `0x4def90` (from leave-world `0x4df050`), `CGObjPC::vslot_222` (`0x4df612`, the teleport), and `0x50ef70`. `0x50ef70` is reached from `0x50eff0`, which sends `0xb005`, so it is the logout-countdown start: **the trade is cancelled when logout is pressed**. |
| 16 callers of `SendItemExchangeResult` | CONFIRMED | `43ff85` (DB fail), `46cb7f`, `46cc71`, `46cedf`, `47fc19`, `480182`, `4806b0` (done), `4def36`, `5158d9`, `5159a8`, `5159e7` (cancel `0x182c`), `526a32`, `526aad`, `526eb1`, `529cf0`, `52cf51` |
| Cancel / X / new request → `0x182c` | CONFIRMED (order per W5) | `s:0x5159db`; `0x5156a3` |

## 4. Client window

| Claim | Verdict | Evidence |
|---|---|---|
| CIFExchange window id 0x1a | CONFIRMED | ginterface `GDR_EXCHANGE` ID=26; `c:0x798d30` `push 0x1a` |
| Layout `resinfo\ifexchange.txt` | CONFIRMED | `c:0x7b27e6` pushes `0xdbcf44` |
| ginterface rect 254×361 under both defines | CONFIRMED (see W10 for `#else`) | define.txt defines both names |
| Every control id, rect and art row of §4.3's table | CONFIRMED | Checked row by row against the file. Buttons 11/12 at 50,328 / 130,328 under both defines; statics 18/19 at 71,152 / 71,296, size 0×0, HAlign 2, CR 5,4,6,4. |
| Duplicate ids 13/14 resolve to the subframes | CONFIRMED | The loader inserts with unique keys (`0x516c70` at `0x8b5669`), so the first child created wins. Children are created in reverse file order (`0xb3dea0` prepends; `0xb3dcb0` walks), and the subframes (file lines 1043/1066) come before the Gold labels (669/688). So GetChild(13) = MY_SUBFRAME and GetChild(14) = OTHER_SUBFRAME. |
| Create's id → field map | CONFIRMED | `c:0x7b281e..0x7b29e8`. Every slot gets kind 26 (`0x6666f0`) and index 0..11 (`0x6667d0`). 153 is hidden at Create. |
| Retail parks 150/250/151/251/155/156/152/252/304/303/302/301/300 at x=9999 | CONFIRMED | ifexchange.txt rows (155: 9999,70,128,128, `ch_red.ddj`, Style 512, 9 frames, 4×4 at 512, Speed 100, loop) |
| No client code moves them | CONFIRMED | CIFExchange vtable `0xdbce4c` differs from CIFMainFrame only at slots 0, 1, 2, 3, 10, 12, 15, 23, 28 and 43. Every access to `+0x33d0..+0x33e8`, `+0x3588/+0x358c` and `+0x3730` is in `0x7b2074..0x7b3a7c`, and the only calls on them are show `0x5c`, text `0xb4`, style, tooltip, animation and log. No move (`0x9c`). The portrait draw `0x4ffc50` skips anything past the screen width. The window is only re-placed at its own position (`0x79df10`) and never resized. |
| Blue grid `interface\ifcommon\com_item_exchange.ddj` | CONFIRMED | Loaded into `+0x61c` by `CIFSlotWithHelp::vslot_010 c:0x66b4a6`; drawn when `+0x595` (`0x67cfcc` → `0x67d01c`). Own grid via `0xb082 [1]` → `0x7b2700(1)`; opponent grid via `0x3086` → `0x7b2670(1)`. |
| Caption Confirm → Approve; enable rule | CONFIRMED | `0x7b2700(1)`: `+0x7bd`=1, `+0x7bc`=0, MYMONEY `0x80000000`, slots blue and not pickable (`0xb9daf0(0)`), UIIT_CTL_ACKNOWLEDGMENT (`0xdbcf14`); button enabled only if `+0x7be`. `0x7b2670` mirrors it with `+0x7bd`. Reset `0x7b36b0` sets UIIT_CTL_CONFIRM (`0xd89fc4`). |
| `0xb083 [1]` sets `+0x7bc` and disables the button | CONFIRMED+ | `c:0x8804a0` sets `+0x7bc`=1 (`0x7b2410(1)`) **before** testing the result, so it is set on `[2]` too. |
| Button 11 `0x7b3480`: nothing offered → local `0xb082 [2][0x1823]` (gold equality quirk); busy → nothing; first press → REAFFIRM as notice + system line + orange log, then `0x7082`; both confirmed → AGREEMENT_WAIT orange log, then `0x7083` | CONFIRMED | `0x7b2480` compares `+0x33c8/cc` with `+0x33c0/c4`; `0xba8f70`; `0x77b580`, `0x7781b0`, `0x64f8a0`, `0xffffb541`; `0x81d9a0`/`0x81da40` |
| "Please check opponet user's ID…" trigger | CONFIRMED | First press of button 11 while `+0x7bd`==0, as above |
| Header "[%s - %s]'s item" (UIIT_STT_SOMEONESITEM_GUILD), no-guild key UIIT_STT_WITH_OUT_GUILD; other state → SOMEONESITEM with `*`; opponent on top | CONFIRMED | `c:0x7b2d00`; guild via `0x9db100` (`0x7b2f6f`); `0xdbcfc0`; `0xd92240`=`*`. Own player → `+0x7c0` (13, MY_SUBFRAME); opponent → `+0x7c4` (14, OTHER_SUBFRAME). |
| Offered items greyed in the bag | CONFIRMED | `0x8806b0`: own list → `0x6b3f40(1)`, `0x7b3380`, then per entry `0x6b3f00(slot−13,0)` (slot `+0x574`=0) → tint `0x80000000` at `0x67cfc2` |
| Add paths: drop (`0x7b2600`) / Alt+click (`0x681b7a`) → CanTrade + devil checks → quantity box purpose 7 → `0x7034 [4]`; only while `+0x7bd`==0 | CONFIRMED | `SOItem 0x8baf10` (`ref+0xa4`→`0x183a`; `0x55edf0`→`0x18fa`); `0x6b1980` (purpose 7 at `0x6b1a85`); OK `0x6b4fd0` → `0x7950b0(0x46,slot,0x1a,−1,count,0)`; Alt key `GetKeyState(0x12)` at `0x681912` |
| Remove paths: drag to inventory (`0x6b5b80`), Alt+click (`0x681de8`, neither confirmed) | CONFIRMED | `0x6b5daf`. The opponent-slot quirk (both grids are kind 0x1a) applies to drag and to Alt+click. |
| Gold button (15) → quantity box purpose 8, only before confirm; OK → `0x825f50`; 0 not sent | CONFIRMED+ | `0x7b2500` → `0x6b2c30` (purpose 8 at `0x6b2cab`, `icon\mini_gold_icon.ddj`); OK `0x6b4b1a` (`jbe` at `0x6b4a26`). Cap min(gold, 1e9) at `0x6b2d8a`. |
| X (vslot 43) → `0x7b24d0` → `0x7084`; window stays until `0xb084 [1]` or `0x3088`; no sound | CONFIRMED | `0x7b2660`; `jmp 0x81dae0`. `0x652c00` plays its close sound only for CIFStore. |
| Done `0x3087`: opponent items to slot −1, window off | CONFIRMED (W9 for the lines) | `0x6b7770(item,−1)`; windows 0xb2 **and 0xaf**; `0x79df10(0)` |
| Closed `0x3088`: sends `0x7084` if still in mode, hides, clears `+0x509`, removes HUD kinds 8/6/7, category-1 message, notice ITEM_EXCHANGE_FAILED | CONFIRMED+ | `0x880840`. **Also:** it sets `+0x3734`=1 for the duration, which makes vslot_023's hide branch skip its extras, and releases focus when GI`+0x71c`. |
| §4.1 request checks in order (alchemy `0x5419`, `+0x7bc` → `0x1834`, mode/NPC silent, target silent, `+0x509`, DEAL_ASKING type 5, `0x7081`) | CONFIRMED | `c:0x81d790`; `0x9db000`; `0x777d70`/`0x7992e0`; `0x9c3220`; `0xdd2544` |

## 5. Request popup text and the trust warning

| Claim | Verdict | Evidence |
|---|---|---|
| Popup kind 7 = caption UIIT_STT_CONFIRM_BOX, line 1 UIIT_STT_PARTY_SOMEUSER with the name, line 2 UIIT_MSG_DEAL_ASK, buttons UIIT_STT_ACCEPT/REFUSE | CONFIRMED | `c:0x64602e` (kind 7 = jump table index 6): `push 0xd89140` (caption, vslot `0xb4`), `0xd9cff8` swprintf'd with popup`+0x820` (the name) into `+0x840`, `0xd9ce58` into `+0x844`, `0xd9ce9c`/`0xd9ce7c` on `+0x800`/`+0x804` |
| PARTY_SOMEUSER is the subject of every request kind | **WRONG, see W7** | Kinds 6, 7 and 8 only |
| English rows: PARTY_SOMEUSER "[%s] sent you  party invite." (double space), DEAL_ASK "Applied for the exchange. Will you accept it?" | CONFIRMED (16-column rows, lines 2411/2024; Korean `[%s]님이` in the 19-column copy) | The 19-column copies read `… party invite. CHECK THE NAME!` and `Exchange request! HAVE YOU CHECKED THE NAME?`. The base wording appearing in both tables suggests it predates the private edits (INFERRED). |
| These are what the client displays | CONFIRMED for the original client / **hazard for OpenSRO, see W8** | The original keeps the first row (16-column); OpenSRO's joined-table rule would pick the 19-column row. |
| The trust check is client-side: guild, union, friend lists; opponent must be in normal state (vslot `0xac`==4) | CONFIRMED (addresses per W6) | `c:0x7b2270`: null opponent or state ≠ 4 → untrusted. Local manager lists only; no packet. |
| Key: DECEPTION_COMPARE when state 4, else NAME_WARNING | CONFIRMED | `c:0x7b3943` `cmp al,4` → `0xdbd0c8` / `0xdbd084` |
| Four presentations: banner, system line, red log line, `ch_red.ddj` effect (plus tooltip) | CONFIRMED | `c:0x7b397f` `0x77b580` (window 0x23 notify); `0x7b399a` `0x7781b0` (window 0x44, type 0 colour `0xffdbc99b`); tooltip 156 shown + `0x653dc0`; effect 155 shown (`0x5c(1)`) + `0x654730(0)`; log `0x64f8a0` with `0xffff4a4a`. Trusted → 156/155 hidden (`0x7b38f2..0x7b3914`). **Note:** in retail's layout the log (304) and the effect (155) are parked at x=9999, so only the banner and the system line are visible there. |
| EXCHANGE_START in orange `0xffffb541`, system line + log | CONFIRMED | `c:0x7b3839` (`0xdbd110`), `0x7b389a`, `0x7b38b6` |

## Counts

- **WRONG:** 10 (W1–W10).
  - Five change wire behaviour: W1, W2, W3, W4, W5.
  - Two change client logic and text choice: W6, W8.
  - Three are wording or precision fixes: W7, W9, W10.
- **CONFIRMED:** 80 table rows, 8 of them marked CONFIRMED+ for behaviour the spec leaves out. Five
  further rows only point back to a W item.
- **PARTLY:** 1. That vslot_306/307 are the death paths is taken from `return_scroll_cast.md`.
- **Not the spec's claim:** 1. The `pc_spawn.md` record comparison does not match, and the spec does not claim it does.
- **Spec OPEN items closed:** OPEN 4 (Refuse = 0 is READ).
