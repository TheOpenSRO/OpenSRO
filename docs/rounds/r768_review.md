# Round 768 review: alchemy (elixir, lucky powder, magic/bless and attribute stones)

Reviewer: independent, adversarial. Scope: the uncommitted working tree against HEAD. No files in
/root/srrevamp were edited.

## Verdict

**Approve with fixes.** The engine matches the binary on nearly every rule I checked against the
disassembly. Two divergences change persisted item data (F1, F2), and one client bug makes the
server refuse a valid-looking attempt (F5). These three should be fixed in this round. F3 (the job
outlives the session) should be fixed or listed as OURS. The rest are low-severity, label or test
items.

### Gates (run by me)

- `go build ./...`, `go vet` on alchemy/magicopt/session: clean.
- `go test ./internal/alchemy/ ./internal/magicopt/ ./internal/session/ -run 'Alchemy|Reinforce|Stone|Magic|Option|Kind|Load' -count=1`: ok (session 143 s).
- Box lane `/opt/opensro-client-r768rev`: `remote_godot.sh check` gives "checked 715 scripts and 9 scenes, ALL LOAD", and `script res://scripts/ui/hud/alchemy_reinforce_test.gd` gives **ALL PASS** (native on).

### Verified against the binary (READ, asm or decomp on the box)

- **Reinforce rate**, 0x506020 asm: the second `0x505f00` call has `EAX = [ctx+0x226a]` (the powder) and `EBX` = the target's plus. There is an early return at `>= 100` before the powder and before luck, and luck is spent through FUN_00505e50. This matches `ReinforceRate`.
- **Failure branch**, FUN_00506ce0 asm 0x506cf0..0x506de3: the order is destroy or flaw (cash test via vslot 0xbc), then atha, soli, flaw, astr. The plus is set to 4 or 0 via `cl` into 0x506ae0, and the plus-0 case clears 0x08. This matches `Reinforce`.
- **Flaw**, 0x506b60 and 0x506c4c asm: the unsigned clamp is `0 -> 1, >= 0x63 -> 99`, and it appends via 0x490720 or overwrites via 0x4907d0. This matches, apart from the ID (F1).
- **Stone MakeAttempt** (0x503680 and 0x5032a0): floor 5, and the attempt fails iff `rate < rand()%100`. The lost roll calls `ReleaseLoadedItems(0)` and returns 0x5423.
- **Executor** (0x506740): any non-1 return goes to `LAB_005067c4`, which sends `Msg_SendTwoFieldReply` and clears the state with **no ReleaseLoadedItems**. So a stone refused after a won roll is really NOT spent.
- **BlessItem** (0x503810, decomp plus asm):
  - Codes in order: count > max gives 2, no group gives 2, degree gives 0x540f, FUN_00727ef0 (group, level record and kind) gives 0x5409.
  - Then 'rep' absent gives 0x5425, and astr with `atha <= astr` gives 0x5424.
  - Charges: `+1 <= 5`, and `rep` `+1 <= 6`. The generated value is clamped to 1..0x6a4 (1700).
  - The "fresh" test is `cmp BYTE [esp+0x13],0` (bl = the count at entry), so the notes are right.
- **Assimilation slots** (vtables 0xaf688c and 0xaf68c4 dumped): slot 10 is 0x501dc0 and slot 11 is 0x502040 in **both** classes. FUN_00501ea0 starts k at FUN_00491780 and takes the strict-min of 4 draws (5 for equip with ref+0x89==2), then indexes {0,23,43,63,83,100}*31/100. This matches.
- **Wire**: Go `encode`/`DecodeAlchemyResult` and GDScript `AlchemyNet.decode_result` agree on every shape: the refusal `2,u16 LE`, the cancel `1,1`, and done with the destroyed byte only on 0x0114 and the record unless destroyed.

---

## Findings

### F1 (Medium): an overwrite replaces the option's ID; the binary keeps the existing ID

- **Where:** `server/internal/alchemy/enchant.go:449` (blessItem: `t.Options[i].ID, t.Options[i].Value = rec.ID, v`) and `enchant.go:298` (flaw: `t.Options[i].ID, t.Options[i].Value = rec.ID, uint32(v)`).
- **What:** when the item already carries the tag, the code writes the stone's level record ID (or the level-3 DEC_MAXDUR ID). Retail writes the new value under the **existing** option's ID.
- **Evidence (READ asm):**
  - FUN_00490550 returns the found option's id through EDI (`mov WORD PTR [edi],si`; `mov WORD PTR [edi],0` when absent).
  - BlessItem: `lea edi,[esp+0x28]` after five pushes, which is `[esp0+0x14]` = Ghidra's `local_70`. It is overwritten with the record id only `if (local_54 == -1)` (0x503a0d `movzx ecx,WORD PTR [ebx]`). The write is then `movzx eax,WORD PTR [esp+0x14]` into 0x4907d0 (0x503b15..0x503b53).
  - Flaw (0x506c27): `lea edi,[esp+0x2c]` gives `[esp0+0x18]`, and then `movzx edx,WORD PTR [esp+0x18]` into 0x4907d0.
  - The RE notes themselves say "overwrite in place (same id, new value)".
- **Effect:**
  - A dropped STR of another level, or a drop's DEC_MAXDUR level 1 or 2 (prob .5 and .25, MEASURED), changes its ID. That changes the level the tooltip shows and the generator that a later assimilation re-roll uses (`opts.ByID(o.ID)`).
  - The docs say "overwrites the same option in place".
  - `TestMagicStoneWritesAFreshValue` cannot catch this, because both writes use id 10.
- **Fix:** on overwrite set only `Value`. Add a test with an existing option of a different ID.

### F2 (Medium-Low): the attribute stone's blue assimilation skips the "MagOptCount is Max" gate

- **Where:** `enchant.go:570-576`. The `len(t.Options) >= t.MaxOptionCount()` refusal is applied only `if magic`.
- **What:** slot 11 is the same function for both stones (0x502040, CEnchant::SetEnchantMagicToAttrAssim). It returns 2 ("MagOptCount is Max!") when `MagParamNum >= FUN_00491780`, and also requires `index < count`. So in retail, an attribute stone's blue assimilation on an item at its cap does nothing. Ours re-rolls the option.
- **Evidence:** the vtable dump `objdump -s 0xaf688c..0xaf68f8`: slot 11 is `40205000` (0x502040) in both tables. The decomp of 0x502040 shows `if (bVar1 < bVar3) {...} else "MagOptCount is Max!"`.
- **Fix:** apply the cap gate for both variants. Add a test (a full item, attr stone, assimilation 100, k drawn into the blue range, expect no change).

### F3 (Medium): a pending job outlives its session

- **Where:** `server/internal/session/alchemy.go:340-398` and `:498-619`.
- **What:**
  - `jobs` is keyed by charID and never cleared on disconnect.
  - `run` commits 4 s later regardless: it can destroy the item or spend elixirs, powders and stones after logout, then `Send`s to the dead session.
  - A relog within 4 s gets its starts silently dropped (the `busy` branch), and its client never sees the result. Its bag changes behind it.
- **Evidence:** there is no session-close hook and no `EntityBySession` re-check in `run`. In retail the operation lives on the GObjPC (`+0x2210..`), so it dies with the PC (INFERRED; not read).
- **Fix:** in `run`, before anything is spent, require `a.Hub.EntityBySession(sess.ID())` to still map to `charID`, else drop silently. If kept as is, list it under OURS in alchemy.md.

### F4 (Low-Med): the lost-roll stone spend has no re-check inside its transaction

- **Where:** `alchemy.go:572-580` (`a.spend` uses `spendIn` directly). Compare the success path at `:592-608`, which re-runs `alchemyUnchanged` inside the txn.
- **What:** `run` executes on the timer goroutine, concurrently with the session's own handlers. If the stone stack moves between the List at `:517` and the spend, `RemoveItem(l.bag, 1)` removes one of whatever item now sits at that index.
- **Fix:** do the `alchemyUnchanged` check inside the spend txn, the same way as the success path.

### F5 (Medium, client): a stone that replaces an elixir leaves the powder loaded, and the server refuses

- **Where:** `client/scripts/ui/hud/alchemy_window.gd:547-566` (`_place`) and `alchemy_reinforce.gd:190` (`request_slots`).
- **What:**
  - Load target + elixir + powder, then Alt+click a magic stone. `pick_slot` returns SLOT_STUFF and the stone replaces the elixir.
  - `_open[POWDER]` becomes false, but `_slots[POWDER]` keeps the powder and still draws its icon.
  - `request_slots` sends every non-null slot, so the start is `[target, stone, powder]` with op 4. The server answers 0x5410 IS_NOT_REINFORCE_STUFF (`alchemyLoadSlot`).
- **Evidence:** retail's vslot_038 skips slots on the "nothing" art (re_client_alchemy.md §4), and "stones never unlock the powder slot".
- **Fix:** clear `_slots[POWDER]` when the new stuff does not open it, and/or skip closed slots in `request_slots`. Add a test.

### F6 (Low-Med, client): with no reply, the prepare effect and its sound loop forever

- **Where:** `alchemy_window.gd:620-650` (`press_action`) and `:700-730` (`tick`).
- **What:** `_busy` clears at 3 s, but `_effect_on` stays true until `apply_result`. `snd_elixir_use` replays every 800 ms. This happens with no reply when:
  - the client is offline (`start_requested` sends nothing unless `is_connected_to_server()`, `hud_panels.gd:834-837`);
  - the server silently drops a second start;
  - the record fails to decode (`decode_result` returns null and nothing is emitted).
  
  The loop ends only when the window is freed.
- **Fix:** do not start when offline, and/or stop the effect at gauge end plus a timeout when no reply has come.

### F7 (Low): the 4 s server wait guarantees a 1 s window in which the client is unlocked but the server is pending

- **Where:** `alchemy.go:108` (`AlchemyDelay = 4s`, OURS); `alchemy_window.gd:700-708` (gauge end clears `_busy`); `:529` (`_refresh_slots` re-enables the action).
- **What:**
  - Between 3 s and the reply, `offer_item` and `take_out` work and re-light the action.
  - A second click sends a start that the server ignores without a reply (the `busy` branch). The client re-snapshots and restarts the gauge and effect, and then applies the first reply to the changed slots.
  - Retail has the same client rule (0x59dca0 tests only +0x7ac), but retail's wait is phase-dependent (3-4 s). Ours always takes the top of that window.
- **Fix (pick one):** answer a start-while-pending with a refusal so the client resets; or gate `offer_item`/`take_out`/`press_action` on "request out, no reply yet" (OURS, disclosed).

### F8 (Low): BlessItem with no room still runs assimilation in the binary

- **Where:** `enchant.go:451-453`, which returns `NothingWritten` before `assimilate`.
- **Evidence:** asm 0x503b44 `jae 0x503be2` (count >= max, not appended) continues at 0x503be2 into the `rand()%0x65` assimilation block, then returns `(local_70 != 1) + 1` = 2. Retail mutates the item in memory (a white re-roll or an ape charge) but sends an error with no DB save. Whether a later save persists it is INFERRED.
- **Fix:** document this as OURS. The test "With the item full ... 2 and nothing added" codifies our version.

### F9 (Low): labels claim READ where the code is a simplification or OURS

- **AttrStone** (`enchant.go:461-470`): the comment says "slot 4, 0x502a40: 0x5421 on either". In the binary:
  - an empty Desc4 returns **2** (`local_18 == 0`);
  - a Desc4 naming none of the words **passes** (falls to `sVar1 = 1`);
  - an unknown NATTR group is not checked at slot 4 at all. The roll comes first, and 0x503430 returns **2** after it (`FUN_00502c80 < 0`), so a lost roll would spend the stone.
  
  Ours refuses 0x5421 before the roll. This cannot be observed on MEASURED data, but it should be labelled OURS.
- **Request checks not implemented:** FUN_00507fe0's `+0x470 needs Param2==1` (0x540f) and FUN_00502910's expiry check (0x5410). They are not in alchemy.md's OURS list.
- **Client 0x578ac0 index 0xe** (Nasrun 3/1/14 with ref+0x2b8==0) is not in `refused_target` and is not in "Not built".
- **OURS items missing from alchemy.md's OURS list:** the silent second-start drop (OURS only in a code comment), F3's after-logout commit, and F8.
- **magicopt** loads Service=0 rows. The export does not filter column 0. Whether the server's ref loader skips them is OPEN and undisclosed.

### F10 (Low): test gaps; some tests would pass on broken code

- F1: the overwrite tests use the same ID.
- F2: there is no assimilation test for the white or blue branches at all (fresh, index 0, the cap, the `justSet` skip). Only the ape path is tested.
- Session:
  - no test that a luck charge spent by the rate is persisted;
  - no `errAlchemyMoved` / "item moved" cancel test;
  - no second-start test;
  - no flaw-with-table test.
- Client:
  - no test for F5 (stuff replaced with the powder loaded);
  - no test for the 3-4 s gap;
  - no test for the no-reply loop.

### F11 (Low, client): timer rounding and per-frame allocation

- **Where:** `alchemy_window.gd:696-698` and `:690`.
- **Rounding:** `tick(int(round(delta*1000)))` drops sub-millisecond time.
  - Above about 2000 fps (uncapped, vsync off) delta rounds to 0, the gauge never ends, and `_busy` never clears.
  - At 144 Hz each frame counts as 7 ms (about 1 % fast).
  - **Fix:** accumulate float seconds.
- **Allocation:** `_draw_frame` allocates a new `AtlasTexture` every 50 ms; reuse one and set its `region`. The `CanvasItemMaterial` is per effect start, not per frame, so it is fine.

### F12 (Low, client): a put-down onto the store or warehouse can go to the alchemy window

- **Where:** `hud_panels.gd:4527` and `:959`.
- **What:** `_over_alchemy` is tested before the `store`/`storage` branches. It compares z-order only against the inventory, and `_drawn_above` returns false across different parents. So a bag item dropped on a store or warehouse window that overlaps the alchemy window is offered to alchemy instead of being sold or deposited.
- **Fix:** use the topmost-window test including the alchemy window, or check `_over_window("store"/"storage")` first.

## Resolution (main session)

Every finding was taken in round 768:
- **F1:** an overwritten option keeps its id (bless stone and flaw). Test:
  `TestOverwriteKeepsTheOptionsID`.
- **F2:** the option-cap gate covers both stones' blue re-roll. Test: `TestAssimilationBranches`.
- **F3:** `run` checks that the session still holds the character before anything is spent.
- **F4:** a lost roll's stone is spent inside a transaction that re-checks the slots.
- **F5:** a stone over an elixir empties the powder slot, and the request names only open slots.
  Client test.
- **F6 and F7:** the window stays locked while a request has no reply, with a 10 s OURS timeout.
  Client test.
- **F8 and F9:** labelled OURS in the code and in alchemy.md's OURS list.
- **F10:** tests added for F1, F2, both assimilation branches, the Lucky charge saved, a moved
  item cancelling, and the flaw saved.
- **F11:** float timers, and one reused atlas texture.
- **F12:** a put-down goes to the alchemy window only when it is the frontmost window there.
