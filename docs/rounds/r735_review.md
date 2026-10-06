# Round 735 review: other players see each other's plus

The reviewed diff is `dev..2c7be9e9`. The reviewer worked in a detached worktree, changed no code
and ran no `qa_shot.sh`.

Labels: **READ** means the decompile or disassembly was read this review. **MEASURED** means a
run or a count. **INFERRED** means reasoned from READ code.

## Findings, most severe first

### 1. BUG: an equip broadcast during a zone change's load strips an arriving player to one item

- **Where:** `client/scripts/World3D.gd:15568-15588` (`_on_other_equipment_changed`).
- **Evidence:** A player who enters while my zone change loads exists only in `_arrival_entries`.
  `_on_entity_entered` returns before `_spawn_or_update_other`, so nothing is written to
  `_other_equipped` or `_other_pluses` for them. The handler builds `worn` and `pluses` from those
  two dictionaries, then overwrites the kept snapshot with them:
  ```
  var worn: Dictionary = (_other_equipped.get(id, {}) as Dictionary).duplicate()
  ...
  if _arrival_entries.has(id):
      var kept: WorldNet.EntitySnapshot = _arrival_entries[id]
      kept.equipped = worn
      kept.pluses = pluses
  ```
  - For a player this client never drew, `worn` is `{slot: ref}`. `_replace_others_for_arrival`
    then draws them wearing that one item, and `_note_other_pluses` keeps only that one plus.
  - For a player drawn in an earlier zone, it is that zone's gear, which may be stale.
    `_other_equipped` is never erased.
- **Fix:** When `_arrival_entries.has(id)`, start from `kept.equipped.duplicate()` and
  `kept.pluses.duplicate()`, apply the change, and store it back. Do not touch `_other_equipped`.
- **Same window, MINOR:** During `await _show_loading_screen()` (`World3D.gd:5821`), the result's
  own `others` are held only in the coroutine. A `0x3038` or `0x3039` for one of them hits the
  "who is not drawn -- ignored" path (`:15566`), and their stale snapshot is drawn until they
  re-enter. To fix it, keep the pending result's others where the handler can reach them, or buffer
  broadcasts for unknown uids until `_replace_others_for_arrival`.
- **Test to add:** A GD test that puts a snapshot in `_arrival_entries`, sends a broadcast for it,
  and checks that the other slots survive.

### 2. REGRESSION (round 732, not this branch): the exit-time abort

The abort is `corrupted size vs. prev_size in fastbins`, rc 134. **Dev's tree does it too.** The
cause is round 732's static lambda, reproduced in isolation.

**MEASURED from the box's logs.** Each row is a perf gate's Jangan runs.

| Tree | Runs | Aborts | Prints "magic option rows" |
|---|---|---|---|
| `8201d8fe` (round 730 spec), the base of gate `a1dbdde` | 3 | 0 | no |
| Gate `a1dbdde`'s head (rounds 731/732) | 3 | 3 | yes |
| **`ae993d82` = dev**, the base of lane A's gate `a6fa7c97` | Jangan 3 + reeds 2 | 5 | yes |
| r735 `ctl`, `live1`, `live2` | 3 | 3 | yes |

All 60 other rendered logs since 2026-09-28 are clean.

**The likely cause.** `World3D.gd:2015` (added in `852d2b93`, round 732):
```
MagicOptionTable.shared_text = func(key: String) -> String: return texts.get_text(key, key)
```
This is a lambda made in the World3D node's script, kept in a `static var`
(`magic_option_table.gd:64`). Godot 4.2.2 frees it out of order when the script language shuts
down. It is the only static-lambda store in the `8201d8fe..ae993d82` range. The range's native
changes (`tables.rs`) are not loaded on the box, which has no `native_bin`.

**Minimal repro.** It ran on the box (`/var/tmp/r735rev/repro`, headless Godot 4.2.2):

| Variant | rc | Glibc message |
|---|---|---|
| A static var holding a RefCounted only | 0 | none |
| A static var holding a lambda made in a Node script that captures a RefCounted (3 runs) | 134 (3/3) | the same `corrupted size vs. prev_size in fastbins` |
| The same, with the static set back to `Callable()` before quit (2 runs) | 0 (2/2) | none |

**User impact:** a crash on every quit, on Linux at least. On Windows a heap corruption at exit is
likely too. This was not run on Windows.

**Fix:**
- In `World3D._exit_tree`, set `MagicOptionTable.shared_text = Callable()` and
  `MagicOptionTable.shared = null`.
- Better: keep the `UiTextTable` (a RefCounted) in a static and call `get_text` on it, with no
  lambda.

This belongs in its own fix round, not in round 735.

### 3. WRONG-LABEL: what `FUN_00490390` tests

- **Where:**
  - `docs/rounds/r735.md:19` ("not read what they test");
  - `docs/rounds/r735.md:139-140` (OPEN);
  - `docs/protocol/weapon_glow.md` §5 ("two vslot tests at `+0x454`/`+0x470` not read");
  - `server/internal/session/equip_broadcast.go:31-33`.
- **Evidence (READ):** All three vcalls are on the **item** (`esi` = the item from `0x4b8000`), not
  on the PC. The `GObjPC::` prefix is only the module the function was attributed to. The `CGItem`
  vtable family (e.g. `0xaeb824`, and every vtable with the same slots) has:

  | Offset | Function | What it tests |
  |---|---|---|
  | `+0x84` | `0x483210` `CGObj::IsEquip` | TypeID1 3, TypeID2 1 |
  | `+0x454` | `0x483b70` | equipment with `(w & 0x780) == 0x680`, that is TypeID3 13 |
  | `+0x470` | `0x483cc0` | the same with `0x700`, that is TypeID3 14 |

  - **MEASURED** in itemdata (`/var/tmp/idparts`):
    - TypeID3 13 is 352 rows, the avatars (`ITEM_ETC_E041225_SANTA_HAT_F`, `…_ATTACH`, flags);
    - TypeID3 14 is 18 rows, all `ITEM_EVENT_AVATAR_*_NASRUN*` (the devil's spirit).
  - The client's `0x3038` and `0x3039` handlers branch on the same two values (`FUN_009daf80` and
    `FUN_009daf90`, the avatar path).
- **Fix:** Relabel as READ: "equipment, and an equip slot of 8 or less, or an avatar (TypeID3 13)
  or devil's spirit (TypeID3 14)". Close that OPEN. The code is right for OpenSRO, which has no
  avatar slots.

### 4. WRONG-LABEL: `0x3039` has a second, ungated path, and the client uses its slot byte

- **Where:**
  - `equip_broadcast.go:30-34`, `:36-41`;
  - `equipment.gd` (the doc comment of `OP_*_BROADCAST`);
  - `r735.md:12`, `:18`, `:74`.
- **Evidence (READ, `srgs.asm`):**
  - **The equip path:** `0x4e9de2` (`0x3038`) is gated by `0x490390` on the item at the
    destination slot.
  - **The unequip path:** `0x4e9f98` (`0x3039`) is gated by `0x490390` on the item at the
    destination bag slot.
  - **The other path:** `0x4e9d03` (`0x3039`) is **not** gated. It is the move-type-7 branch: `[edi]`
    is 7 and the source `[edi+3]` is below `0xd` (`0x4e9ca5..0x4e9cb4`, flag 4). It takes the item
    at `[edi+0x3c]`, so it covers every equip slot 0..12, accessories included. So "both go out only
    for an item `FUN_00490390` passes" is wrong for that path. OpenSRO has no such move, so this is
    not a code bug.
  - **Client side:** The `0x3039` handler `FUN_008a9560` does **not** ignore the slot byte. For a
    non-avatar item it calls `FUN_009daf70(param_1 = the slot byte, 0, 0, 0)`, which is
    `InstallEquipVisual(slot, …)`. Only `0x3038` reads the slot into a variable that is then
    overwritten, and resolves the slot by `ResolveVisualSlotForItem`. The text "Both find the
    character by uid and redress it through the visual slot the item's type resolves to" holds for
    `0x3038` only.
- **Fix:** Relabel. OpenSRO's use of the slot byte for `0x3039` is the retail behaviour, not OURS.

### 5. DEPARTURE (was OPEN): retail sends `0x3038` and `0x3039` to the mover too

- **Where:** `equip_broadcast.go:48-51` and `:116-131` (`equipObservers` leaves the mover out), and
  `r735.md:22`, `:138`.
- **Evidence:**
  - **READ:** Both client handlers have a branch for `local_14 == DAT_00eef5e8` after the general
    redress. `DAT_00eef5e8` is written only by `CICPlayer::vslot_018` (`0x9d49a0`), so it is your
    own character's unique id. The branch updates `IFMainPopup` (the character window) and calls
    `CObjCharacter::InstallEquipVisual` on its preview. The general path before it also redresses
    your own `CICPlayer`, through `IGIDObject::FUN_009c31a0`.
  - **INFERRED:** That branch would be dead code if the mover were not told, so it was not traced
    through the broadcaster. `FUN_00484d90` is `[esi+0x12c]->vslot 6(region word from vslot 5,
    packet)`, a region-scoped send from the mover's own object.
  - The departure is harmless in OpenSRO: the client resolves uids only among others and would log
    "ignored".
- **Fix:** Record it as a DEPARTURE (OURS: your own client redresses from `0x0042`), not as OPEN.
  If retail exactness is wanted, send the mover the broadcast too. Its client must then skip its
  own uid in `_on_other_equipment_changed`, which it already does.

### 6. DEPARTURE (labelled, confirmed): the zone scope against retail's region

- **Evidence (READ):** `0x484d90` sends through `[esi+0x12c]`'s vslot 6 with the region word from
  the mover's position. That is the region machinery, not a zone.
- OpenSRO spawns other players zone-wide (`world.go:1519`, `:1640`, `EntitiesInZone`), so the zone
  scope matches OpenSRO's own visibility, and nobody who can see the mover misses a broadcast.
- Already labelled OURS. No change needed.

### 7. MINOR: the client treats a `0x3038` with no plus byte as a removal

- **Where:** `client/scripts/net/net_client.gd:1067` and `World3D.gd:15571-15579`.
- **Evidence:** `decode_broadcast` gives `plus = -1` when the byte is absent, which the retail
  layout allows for a non-equipment item. `eb.plus if on else -1` passes the -1 through, and the
  handler's `plus >= 0` test then erases the slot.
- The OpenSRO server always writes the byte for worn items (`isEquipmentItem` defaults to true).
  This is latent, but it is wrong to retail's layout.
- **Fix:** Emit a separate `removed` flag, or treat a `0x3038` with no byte as plus 0.

### 8. MINOR: the frame size

- **Evidence:** The pluses tail adds at most `1 + 2*13` = 27 bytes per other in
  `OpEnterWorldResult` and `OpChangeZoneResult`, and 19 for a full nine-slot kit.
- **MEASURED:** The `plusSnapshot` bytes are 67 bytes for three items, so a nine-item other is about
  121 + 2 (heading) + 5 (model) = 128 bytes. With the tail it is about 147.
- `proto.MaxPayload` is 32767, and neither result is split. The cap goes from about 255 others in
  a zone to about 222.
- This is an existing limit that the tail lowers by about 13 %. Recording it is enough.

### 9. MINOR: process, no perf gate

- **Where:** `r735.md:144`.
- The round changes `World3D.gd` body building and animation registration (`_redress_other`).
  AGENTS.md asks for `--sites jangan` on such rounds.
- The redress runs only on a broadcast, so the offline gate would not exercise it. A Jangan run
  still proves the spawn path (`_note_other_pluses` on every snapshot) costs nothing.
- **Fix:** Run `perf_gate.sh --sites jangan`, or record why it was skipped in the WORLD_ISSUES
  entry.

## OPEN 2, client half: settled (READ)

**Your own character's `CObjCharacter+0x3c+slot*0xc` byte is the effective plus**
(OptLevel + advanced elixir).

- `InstallEquipVisual` (`c:0xa61010`) writes `param_4` to `this + (slot*3+0xf)*4`, which is
  `+0x3c + slot*0xc`.
- Your own body reader, `CICPlayer::vslot_025` (`c:0x9d9a80`), calls it for each item below slot
  `0xd` with these arguments (pushed at `0x9d9b61..0x9d9b7a`):
  - the slot;
  - `FUN_008ba470` = item `+0x34`, the RefItemID;
  - `FUN_008ba570` = item `+0x8c` (byte), the plus;
  - 0.
- The item parser `SOItem::FUN_008be4f0` reads OptLevel into `+0x8c`. Then `SOItem::FUN_008bb070`
  adds every binding entry of type 2 (the advanced elixir) into it:
  `*(char*)(this+0x8c) += value`.
- Your own `0x3038` (finding 5) also passes the server's effective byte to the same setter.

**Lane A:** use the effective plus for the local player as well. In OpenSRO that is
`OptLevel + AdvElixir` from your own item record, summed in a byte as both binaries do.

## Verified, no finding

Each item below is READ or MEASURED as marked.

**Layouts and plus values (READ):**
- **`0x3038`:**
  - Server `0x4e9de2..0x4e9e47`: u32 uid `[ebp+8]`, then u8 `[edi+4]` (the destination).
  - Then the item's vslot 294 (`+0x498`) at mode 2 into `0xcd3a80`, appended. The mode 2 branch
    of `CInstanceItem::vslot_010` writes the RefItemID (`+0x28`), then for equipment
    `(u8)(FUN_00846200's elixir sum + OptLevel +0x2c)`.
  - Client `FUN_008a9260`: Read 4, 1, 4, then 1 under the same type test.
- **`0x3039`:**
  - Server `0x4e9f98`: u32 uid, u8 `[edi+3]` (the source), u32 from the item's vslot 1, no plus.
  - Client `FUN_008a9560`: Read 4, 1, 4.
- **The effective plus:** `FUN_00846200` sums each attached elixir's `+0x2c` into a byte, and the
  caller adds OptLevel in the byte. `EffectivePlus()` (a uint8 sum, wrapping) is the same.
- **`0x3015`:** the client's `GlobalDataManager::FUN_009de2f0` reads u8, u8 count, then per item
  u32 ref + u8 plus for equipment. That is followed by the avatar block (ref + u8 for TypeID3
  13/14).

**The server's equip and unequip handling (READ, `0x4e9c40..0x4e9c9b`):**
- **The equip and unequip flags.** These are type 0 moves:
  - an equip is a bag slot `0xd..0x6f` going to an equip slot below `0xd` (flag `0x4000`);
  - an unequip is the reverse (flag `0x8000`).
- **A swap.** `[edi+1] == 3` sends no `0x3039` for the displaced item (`0x4e9ede..0x4e9f5a`), only
  stats. So "a swap is one `0x3038`" is right.

**OpenSRO server:**
- **Slots:** `BroadcastSlotMax` = `SlotJobSuit` = 8, and slots 0..12 match retail's equip slots.
- **Only path:** Only `EquipmentHandler` changes worn slots. `SetDurability` and `SetInstance` are
  the only other writers, and only `/item worn` changes a plus.
- **No hidden unequip:**
  - A two-hander with a shield is refused (`equipment.go:282-300`), so no unequip goes unbroadcast.
  - The unequip reads `removed` before `Unequip` and sends nothing on failure.
- **Spawn after a re-equip:** Every snapshot path (`world.go:395`, `:1513`, `:1635`) uses
  `equippedItems`, which reads the store live, so a spawn after a re-equip carries the current
  plus.

**The pluses tail:**
- **Only when a plus exists:**
  - Byte for byte the old payload when no plus exists (Go golden test).
  - The models tail is forced, and with it the headings, Seated and Restored. That is right for
    both results, and also for `EncodeEntered`'s 0/0 model.
- **Older clients ignore the trailing bytes.** On dev, `decode_entity_entered` reads the model only
  when present and stops. `_decode_models` returns without checking trailing bytes.
- **Unknown opcodes** fall to `_dispatch`'s default.
- **The `ChangeZoneResult` decoders** (Go and GD) accept an absent tail and reject a mismatched
  count.

**Leave, logout and the GM command:**
- **Leaving and logout:** `_other_pluses` is erased on leave. A zone change overwrites it per
  snapshot.
- **The GM's `/item worn` is safe:**
  - It is behind the GM gate.
  - Slot 0..12 is range-checked, and the value is `ParseUint(…, 8)`.
  - An empty slot is refused.
  - The store is checked as an `InstanceSetter`.
  - A slot above 8 changes the item but broadcasts nothing.
  - `deps` is non-nil whenever `WornChanged` is set.
- **SQL `SetInstance`** uses the same columns as the bag store's and the worn `Get`. Its test is a
  `t.Fatalf` on a missing Postgres, not a skip, so it really ran.

**`_redress_other`:**
- The freed skeleton's `_animated` entries are pruned (`World3D.gd:6284`, `6397`).
- A moving gait is restarted, and sitting is kept.

## Tests (MEASURED)

| Test | Result |
|---|---|
| `go build ./... && go test -count=1 -p 1 ./...` | 67 packages ok, rc 0 |
| `remote_godot.sh tests` (`RENDER_DIR=/opt/opensro-client-r735rev`, `GODOT_LOCK=/var/tmp/r735rev/lock`) | ran 242 suites, 0 failing |
| `remote_godot.sh check` | ALL LOAD (635 scripts, 9 scenes) |
| The abort repro (above) | 5 headless runs of a few seconds each, under the same lock |

No `qa_shot.sh` or perf gate was run, and no process was killed.
