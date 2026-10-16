# Round 732 review: the item instance record, the (+x%) maths, blue options

Reviewer: an independent adversarial pass over `dev..cc32c434` (worktree-agent-a1dbdde02d381b76d).
No code was changed. `c:` addresses are sro_client.exe and `gs:` addresses are SR_GameServer.exe.
They were read from the dumps on the render box (`/var/tmp/decomp_client`, `/var/tmp/decomp_server`,
`sro_client.asm`, `srgs.asm`) and from `.rdata` with `objdump -s`.

## Verdict

The maths is right. Every formula the round claims checks out against the x87 code:

- the averaged range line;
- the chop rounding of the plus bonus;
- the single-value line;
- `q / 0.31`;
- the blue percent;
- the integer stat builder;
- the variance-group order.

The schema and the move paths are sound.

The record itself is wrong in one place. The round did not read the GameServer's item writer. That
writer is `gs:CInstanceItem::vslot_010` (0x42e230), and it puts a **u32 rent block in front of
RefItemID**. The client reads that same word first, at c:0x8be52c, which the round's table skips. So
the record is internally consistent but is not retail's (F1).

The writer also settles three of the round's OPEN items: the binding-block order, the advanced
elixir entry's slot and low u32, and the bits 16–31 question. It also shows that time-limited items
carry an expiry where the round sends durability.

## Findings, most severe first

### F1. BUG: the record is missing its leading u32 rent block

- **Where:**
  - `server/internal/session/iteminfo.go:66` (AppendItemRecord) and `:95` (ReadItemRecord);
  - `client/scripts/items/item_instance.gd:97` (read_record);
  - `docs/rounds/r732.md:13`, the table that starts at RefItemID;
  - `docs/protocol/item_tooltip.md`, OPEN item 9.
- **Evidence (READ), the client:**
  - `SOItem::FUN_008be4f0` pushes the stream and calls `0x8bb130` at c:0x8be52c, before the
    RefItemID read at c:0x8be549.
  - `0x8bb130` reads a u32 (c:0x8bb144). When bit 0 or bit 1 is set, it reads more:
    - u16;
    - if bit 0: u32 and u32 (`RefData_refrentitem` period begin and end);
    - if bit 1: u16, then a u32 multiplied by 1000.
- **Evidence (READ), the server:**
  - `gs:0x42e230` modes 1 and 4 call `0x845b30` first. That function lets the item's rent object
    (+0xd4) serialise itself, or, when there is none, writes a u32 0 (`gs:0x862960`).
  - Only then does it write the u32 RefItemID (`gs:0x4958c0`).
- **Effect:**
  - OpenSRO's own container and parser agree with each other, so nothing breaks live today.
  - The record labelled READ/retail is 4 bytes short. Any retail carrier (0x3013, an 0xB034
    pickup) built on `AppendItemRecord` would be misaligned for every item.
  - The golden tests in Go and GD pin the wrong bytes.
- **Fix:**
  - Write a u32 0 (no rent) before RefItemID.
  - Read it, with the bit 0 and bit 1 branches above, in `ReadItemRecord` and in `read_record`.
  - Update the golden bytes, the r732.md table and item_tooltip.md item 9.

### F2. WRONG-LABEL and DEPARTURE: the binding blocks' order and entry contents are READ, not OURS or OPEN

- **Where:** `iteminfo.go:43-46,84-89`; `r732.md:23-24`; the OPEN list ("the type-2 entry's low u32
  and slot").
- **Evidence (READ):**
  - `gs:0x846280` loops type 1 then type 2 and writes u8 type. For each type it writes u8 count 0
    when the item has none, otherwise the count and each entry.
  - The entry is written by `gs:CInstanceBindingOptionWithItem::vslot_009` (0x825a40), modes 1 and 4:
    - u8 nSlot (+0x21);
    - then a u64 whose **low u32 is nOptID (u16, +0x24) | nOptLvl (u8, +0x28) << 16**;
    - and whose **high u32 is nOptValue (+0x2c) for type 2**, or nParam1 (+0x30) for type 1.
  - The column names come from `gs:DB_Bind__BindingOptionWithItem` (0x85e4e0): nItemDBID +0x18,
    bOptType +0x20, nSlot +0x21, nOptID +0x24, nOptLvl +0x28, nOptValue +0x2c, nParam1 +0x30,
    nParam2 +0x34.
- **Effect:**
  - "Type 1 then type 2" is retail's order, not a choice.
  - Sending slot 0 and low u32 0 departs from retail. The client does not see it, because
    c:0x8bb070 uses only the low byte of the high u32 for type 2.
- **Fix:**
  - Relabel the order READ.
  - Document the entry layout.
  - When the elixirs are built, send nSlot, nOptID and nOptLvl.

### F3. DEPARTURE: time-limited equipment carries an expiry, not durability

- **Where:** `iteminfo.go:181` (itemInfoFor), which sends durability for every TypeID 3/1.
- **Evidence (READ):**
  - For TypeID3 14 (`(t & 0x780) == 0x700`), the client takes a different branch:
    `UI_SILKMALL::0x55edf0` at c:0x8be5ce. There it reads the u32 after Variance as
    `active << 31 | seconds` (c:0x8be600-0x8be62f).
  - The server writes `(Data != 0) << 31 | time & 0x7fffffff` there when `gs:0x42fd30` (the same
    0x700 test) holds.
  - The box's itemdata has 28 such rows, for example `ITEM_EVENT_AVATAR_M_NASRUN_RED`. (Round
    789: 28 rows, 26 unique ids; the period word is sent since round 789, docs/protocol/avatars.md.)
- **Fix:** for TypeID3 14, send the period word, or 0 until rentals exist. Do not send durability.

### F4. MINOR: the client sums the advanced elixir's whole u32, not its low byte

- **Where:** `client/scripts/items/item_instance.gd:123`.
- **Evidence:**
  - c:0x8bb070 does `+0x8c += (char)hi` (a u8 wrap) and `+0x71 = (char)hi`.
  - The Go reader (`uint8(v >> 32)`) matches retail; the GD reader keeps the full u32.
- **Fix:** `& 0xff`.

### F5. WRONG-LABEL: an empty blue range shows (+0%), not nothing

- **Where:** `client/scripts/items/magic_option_table.gd:100-106`, which returns -1 with the comment
  "it is not shown".
- **Evidence (READ):**
  - c:0x670f72 divides by max − min with no guard.
  - The ±inf or NaN result goes through `_ftol2` (`cvttsd2si`, c:0xb42d25), which gives 0x80000000.
  - That is clamped to 0 at c:0x670f87.
  - `format_line` already clamps, so the text is right; the API value and its comment are not.
- **Fix:** return 0 and fix the comment.

### F6. DEPARTURE: the blue-option row selection is READ, and the round takes the option's own row

- **Where:** `magic_option_table.gd:94` (`row(id)`) and `blue_pct`; `r732.md:88-91`.
- **Evidence (READ):**
  - The caller (c:0x6782c3-0x678330) computes min and max from the option's own row and passes
    four values: the row, max, min and value. It also passes the item's ItemClass, the byte at
    ref +0x1d0 (c:0x67831a).
  - `0x670dd0` keeps those values when the row's degree equals `(ItemClass − 1)/3 + 1`
    (c:0x670e98-0x670eb1).
  - Otherwise it looks up the **same MATTR code at that degree** with `0x926b30(code, degree)` at
    c:0x670ebd, and takes min and max from that row.
  - For example, MATTR_ER degree 10 has max 60 where lower degrees stop at 30.
- **Columns 8–10 are READ, no longer INFERRED:**
  - The row parser `GlobalDataManager::RefParse_magicoption` (c:0x97b0b0) reads, after the
    caller's Service column:
    - +4 ID, +8 code, +0x24 col 3, +0x40 degree, +0x44 float, +0x48 int;
    - 16 ints from +0x4c (cols 7–22);
    - 6 ints;
    - 10 × (string, int).
  - That is 49 columns, the file's exact count. The 'weapon', 1 pair lands at col 29.
  - The pointer `0x670dd0` holds is row+4: the degree compare is `[ebx+0x3c]` = row+0x40, and the
    code is `[ebx+4]` = row+8. So `[ptr+0x4c]` is row+0x50, which is col 8. (Col 7 is the
    ParamKeeper tag, for example 0x6872 'hr'.)
- **Fix:** have `blue_pct` take the item's ItemClass and use the (code, degree) row, then relabel.

### F7. MINOR: the float builders round where the client does not

- **Where:**
  - `server/internal/durability/quality.go:35` (FloatStat) and `:94` (QualitySingle);
  - `client/scripts/items/item_quality.gd:65` and `:108`.
- **Evidence (READ):**
  - The armour phys-def builder (c:0x8bde5e-0x8bde99) keeps `(U−L)·(q/31.0)` in extended
    precision, adds L, then adds `inc·plus`, and rounds to f32 once at the store.
  - The lane rounds `q/31` to f32 first and adds in a different order.
  - The single line (c:0x66cd25-0x66cd33) subtracts the unrounded product `inc·plus` (a double)
    and rounds once.
  - The lane rounds the product to f32 first.
- **Effect:** none visible. For q in 1..30, q/31·100 is never within 1e-6 of an integer, so a one-ulp
  difference cannot move a percentage.
- **Fix:** mirror the order, for fidelity.

### F8. MINOR: the warehouse list is close to one frame's limit

- **Where:** `server/internal/session/storage.go` (StorageListResult) and
  `server/internal/gateway/gateway.go:287`, which refuses the whole send when it is over
  `proto.MaxPayload` (32,767 bytes).
- **Evidence:** the worst case is 210 slots (`inventory.MaxStorageExpansionSlots`), each equipment
  with 12 options and an advanced elixir.
  - 4 + 18 + 96 + 2 + 11 = 131 bytes per entry.
  - With the snapshots, the list comes to about 30,880 bytes.
  - The F1 fix adds 840 bytes, for about 31,720.
  - One socket entry per item (+9 each) passes the limit, and the player then gets no warehouse
    list at all.
- **Fix:**
  - Test at 210 × 12 options.
  - Plan to split the block (or move to retail's chunked 0x3013 path, `gs:0x430a20`) before
    sockets land.

### F9. MINOR: `/item` accepts any bag item

- **Where:** `server/internal/gm/gm.go`, `item()`.
- **Evidence:**
  - A plus or options set on a stackable item are never listed, because the block lists
    equipment only.
  - When stacks merge, the destination keeps its own instance (`addItem` and `MoveItem` merge
    paths), so the source's instance is dropped.
- **Fix:** refuse anything that is not TypeID 3/1.

### F10. MINOR (process): no perf-gate table for a World3D.gd loading change

- **Where:** the `client/scripts/World3D.gd` hunk at line 1999, which parses magicoption.txt during
  UI initialisation.
- **Evidence:** AGENTS.md requires the gate's table for any round that changes client loading code.
  `r732.md` has none. The parse is 402 rows, so a slowdown is unlikely, but the gate is the rule.
- **Fix:** run `perf_gate.sh --sites jangan` or record why it was skipped.

## The lane's open questions, answered

- **The server's item writer:**
  - It is `gs:CInstanceItem::vslot_010` (0x42e230), reached as item vslot 294
    (`gs:0x48fb60` → the row's vslot 10).
  - Modes 1 and 4 (inventory) write, in this order:
    - the rent block (F1);
    - u32 RefItemID;
    - for TypeID 3/1: u8 OptLevel (+0x2c), u64 Variance (+0x30), and a u32 Data (+0x38) that is
      the expiry word for TypeID3 14;
    - u8 MagParamNum (asserted ≤ 12), then MagParamNum × u64 (`gs:0x42e800` writes 8 bytes);
    - the two binding blocks (`gs:0x846280`).
  - Mode 2 (another player's view) writes only u8 `OptLevel + Σ nOptValue` for equipment
    (`gs:0x846200`).
  - Apart from F1 and F3, the widths and order match the round.
- **Bits 16–31 of an option's low dword:**
  - The server splits them out as their own u16 (`gs:0x4903f0`: `*param_3 = lo >> 16`).
  - The client's equipment branch ignores them: c:0x8bcdf0 keeps `(u16)lo`. Only TypeID 3/3/14/2
    (`c:0x666fc0`, not equipment) keeps the whole low dword.
  - Their meaning is still OPEN. Sending 0 is safe.
- **The advanced elixir's slot and low u32:** see F2. nSlot, then low = nOptID | nOptLvl << 16.
- **What writes item +0x70:**
  - c:0x8beae0 writes it, and c:0x8bcbc0 resets it.
  - When ref +0x1d4 ≠ 0, the value comes from a reference-table lookup (`0x97af60` → +0x2c), not
    from the wire. It is client-derived, so OpenSRO's 0 is correct for items with ref +0x1d4 == 0.
  - Lane A's `effective_plus` should add that term once the table is read.

## The messages: is a trailing block the right carrier?

Yes, for this round. Retail's 0xB034 buy result (type 8) and buy-back result (type 0x22) **do not
carry the item record**:

- c:0x87eb50 reads type 8 as u8 tab, u8 slot, u8 n, n × u8, u16.
- It reads type 0x22 as u8, u8, u16 (`LAB_0087f227`).

The record rides only in the move types whose handler c:0x87ba20 calls the record parser (four call
sites), and in 0x3013. 0x3013 is built by chunking a buffer that vslot 294 fills
(gs:0x4e3e71 → `0x430a20`).

The client re-requests the lists after every 0xB034 (`hud_panels.gd:2417`), so the instances
refresh after a split, a sell, a deposit or a buy back. Older clients stop reading before the
block. A new client facing an older server skips a missing block on all three lists.

## The user's screenshot

- **Amooterium** is `ITEM_EU_TSTAFF_11_SET_A` in the box's itemdata.
- **Its critical range is 2.0–2.0.** So "Critical 2 (+100%)" is the `U == L → 100` path
  (c:0x66cd66), as the round has it.
- **The "Mag. atk. pwr. 4388 ~ 5225 (+0%)" line cannot be reproduced from this data:**
  - Both ends use the same variance group, so at +5 the spread v_hi − v_lo must lie in
    [684, 684 + 41] (MAttackMax_L − MAttackMin_L = 3762 − 3078).
  - The screenshot's spread is 837.
  - So the screenshot's server data differs from this itemdata. This is not a formula fault.

## Verified

- **The record:** each field after the rent word, on both sides:
  - the equipment test (TypeID 3/1, bit 1 clear);
  - MagParamNum ≤ 12 at both ends;
  - the binding loop of exactly two;
  - type 1 stores at +0x74/+0x78, type 2 adds onto +0x8c.
- **The range line** (c:0x66c66f-0x66c841):
  - the ends' own ranges, ref +0x258/+0x25c and +0x260/+0x264;
  - one inc for both ends (+0x268);
  - the fistp under `or 0xc00` (chop);
  - +2^32 for a negative v;
  - the average.
- **The constants**, read from `.rdata`:
  - 0.5 and 100.0 at 0xe1b7d0 and 0xe1b7d8;
  - 2^32 (float) at 0xe1b7c8;
  - 31.0 at 0xddf2c8;
  - 0.3100000023841858 at 0xda1aa0.
  - `0xb42d10` is `_ftol2_sse` (`cvttsd2si`).
- **The single line** (c:0x66cd25-0x66cdb6): plus off with ref +0x1e8, and 100 when U == L.
- **Durability:** `trunc(q / 0.31)` on byte +0x57 of the stat block (c:0x66d316).
- **The integer stat builder** (c:0x8bdb75-0x8bdbd2):
  - `trunc((U−L)·q/31 + L + trunc(inc·plus))`;
  - min and max share q.
- **The variance groups:**
  - group k → builder case k at c:0x8be230 (`>> 5k`, k = 0..11).
  - The weapon jump table at 0x8be1c8 maps cases 0–6 to Dur (+0x1d8), PAStr (+0x280), MAInt
    (+0x290), HR (+0x2a0, inc +0x2a8), PAttack (+0x258), MAttack (+0x26c, inc +0x27c) and CHR
    (+0x2ac).
  - These are itemdata's own column order, so the weapon row of `group_for` is right. The armour,
    shield and accessory rows were not re-derived.
- **The blue percent** (c:0x670ef0-0x670f89):
  - min is the first word's high u16;
  - max is the last non-zero u16 of hi, lo, hi, lo… across three words;
  - the value is read unsigned;
  - the result is clamped at 0.
- **The schema:**
  - `ADD COLUMN IF NOT EXISTS … NOT NULL DEFAULT <const>` on all three tables. On PostgreSQL 11 or
    later that is a metadata-only change, safe on production rows, which read +0 with no options.
  - Every INSERT carries the new columns: add, place, split, swap, equip, the unequip return.
  - The `UPDATE … SET slot` moves keep the row.
  - The durability and legacy-init UPDATEs touch only their own columns.
  - The legacy warehouse migration inserts defaults, which is correct for pre-732 data.
- **The move paths:**
  - the buy-back book (`shop.Inst`);
  - trade (`offerItemID` → `Instance()`);
  - storage deposit and withdraw;
  - equip, swap, unequip and putBack;
  - the potion/berserk restores.
  - Each carries the full `Instance()`.
  - There is no player drop to the ground. Monster drops carry no instance, as before.
  - `Slot` and `Instance` are no longer comparable, and the one `==` (storage deposit undo) became
    `Equal`.
- **Compatibility:**
  - an older client stops before the block;
  - a new client against an older server skips it;
  - the equipment decoder's offset arithmetic (`2 + 12·n`) matches the server's.

## Tests

- **`go test -count=1 -p 1 ./...`** in the reviewed tree: exit 0, 67 packages ok.
- **Box `check`** (`RENDER_DIR=/opt/opensro-client-r732rev`, `GODOT_LOCK=/var/tmp/r732rev/lock`):
  629 scripts and 9 scenes, ALL LOAD.
- **Box `tests`:** 240 suites, 0 failing.
- **Not run:** the perf gate and `qa_shot.sh`, as briefed.
