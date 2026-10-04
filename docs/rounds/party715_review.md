# Round 715 (lane C3) review: the party member boxes, the player block's glow and flag, Ctrl+1..8

This is an independent adversarial review of `int/party..worktree-agent-ae639aa70cb636a53`. That is five
commits on `85e6c063`: `2b9be98e`, `660cb6ef`, `0ccd00a1`, `23159c94` and `db41d25e`.

The review checked them against:
- `party_gui.md` §7;
- the user's request and screenshots 03, 04, 10 and 11;
- the client itself, through the decompile `/var/tmp/decomp_client`, the disassembly
  `/var/tmp/sro_client.asm`, and `.rdata` values read straight out of
  `/opt/sro-files/client/sro_client.exe`;
- a direct-call graph of the whole exe, built for this review from the disassembly and the
  dump's function index.

No code was changed.

## Test results (render box, the branch head `db41d25e`)

| run | result |
|---|---|
| `RENDER_DIR=/opt/opensro-client-r715rev GODOT_LOCK=/var/tmp/r715rev/lock remote_godot.sh tests` | **ran 227 suites, 0 failing** |
| `remote_godot.sh check` | **checked 588 scripts and 9 scenes, ALL LOAD** (the only errors are the missing native library, which falls back) |
| `hud_quick_party_test.gd` alone | 0 failures; `TIMING: HudQuickParty.tick with 7 slots: 26.0 us a frame (mean of 2000)`, the lane's number reproduced |
| `cd server && go build ./... && go vet ./cmd/partybot` | clean |

## The ground-click question: verdict

**The lane is right. In the original, a left click on the ground does not end a selection.** The
user's request says it does. The binary says it does not. This is READ.

### What a left click does

The game window's message handler is `CGInterface::vslot_017` (`0x77c260`, vtable `0xdb95a4`
slot 17). It handles three left-button messages:

- **`WM_LBUTTONDOWN` (0x201):**
  - It calls `SetFocus`, `0x8b51f0(1,1)`, `0xb8f4f0`, `0xb9d9f0`, the option `+0x1a` sound check
    `0x468c50(0xae)`, `0x7994e0(0)` and `0x60a610`.
  - Then it calls `0x793570`.
  - `0x793570` picks with `0x78ee20`. When the pick returns nothing (the terrain), it takes the
    branch `0x793669 je 0x793a1c`, which runs `0x793a1c..0x793ad8`. That branch does the following, in order:
    1. Only in the `+0x7ec == 2` mode, `0x7890c0` and `0x779260(0)`.
    2. `0x798d40` + `0xb8f530`, and, when window `0x1e` is open, `0x78fc20`. That function
       sends `0x704b`, the end-interaction message for an NPC talk (`character_state.md`).
    3. It clears `player+0x20ff`.
    4. It calls `0x78f8d0(press, 0, 0)` at `0x793a7d`, the move. Its own calls are `0x77c8e0`, `0x77c9b0`,
       `0x778c40`, `0x81f100`, `0x9d4a20`, `0x9ce930`, `0x777ba0` (kill timer 7), `0x9ec6b0`,
       `0xa5ade0`, `0x9edd60`, `0x9ec570`, `0x410cd0`, `0x9ed130`, `0x9ebec0`, and `0x777b90`
       (timer 7, 500 ms, the held-button repeat).
    5. The `0x799920`/`0x60fc..` window checks.
- **`WM_LBUTTONUP` (0x202):** `0x78e5d0`.
- **Double click (0x203):** `0x792190`.

### Where the selection lives, and who can change it

The selection is `CGInterface+0x628`. Only four functions in the exe write `[reg+0x628]`:
- **`0x780ee0`**, SetTarget. It also tells the target window (`0x699540`) and the quick party
  board (`0x6d9610` → `+0x37c`).
- **`0x778650`**, which sets the id silently. `0x778650(0)` is the silent deselect.
- **`CGInterface::vslot_012` `0x77b140`**, which zeroes the id when the selected object no longer
  exists.
- **`0x66b460`**, a different class (`CIFSlotWithHelp`). `0xa9ae80` is a stack slot.

Every direct caller of the two setters is accounted for:

| setter | callers |
|---|---|
| `0x780ee0` | the object branch of `0x793570`; the pet window `0x7a8af0`/`0x7a8b50`; the player block's click `0x7b4be0`; the `0xB045` select answer `0x88b200` (both sites pass the selected object's id); the skill-start handler `0x8a59e0` (it switches to the attack target); and `0x8a9e30` |
| `0x778650` | the target window's per-frame `0x698ae0` (target dead); the right-click target menu `0x77b5e0`; the interface's init `0x786f30`; the object click `0x792f00` (three sites, each the clicked object); the object branch of `0x793570`; `0x88b200`; and the object destructor `0x9c2460` (the selected object despawning) |

None of these lies on the ground path.

### Second probe

The probe was a transitive walk of direct calls, eight levels deep. It started from every callee
of the ground branch and of the 0x201, 0x202 and 0x203 handlers:
- the ground branch reaches 359 functions;
- `0x792190` reaches 509;
- `0x778ff0` reaches 831.

No walk reaches `0x780ee0`, `0x778650`, `0x6d9610` or `0x699540`, and none reaches a writer of
`+0x628`.

The walk does not follow virtual calls. So a deselect reached through a vtable would still have to
call one of the setters, and the table above lists every caller of both. No message handler
answers a move with a deselect: `0x88b200` is the select answer, and it never passes 0. No key
deselects either.

### What does end the glow in the original

- Another selection:
  - a monster, NPC or player clicked;
  - the player block clicked;
  - Ctrl+1..8;
  - a skill started on a target (`0x8a59e0`).
- The selected object despawning (`0x9c2460`, and the board's own `0x6db380` → `0x6dac10`).
- The target dying (`0x698ae0` → `0x778650(0)`, which clears `+0x628` without telling the board).

**Recommendation:** keep the binary's behaviour. Tell the user in one line that the original does
not deselect on a ground click and that this was read from the exe; the round notes already say
so. If the user still wants the deselect, it is their decision to make against the original.

## Findings, most severe first

### 1. DEPARTURE + WRONG-LABEL: the caution effects default ON; the original's defaults are READ, and HP/MP caution start OFF

- **Where:**
  - `client/scripts/ui/hud/hud_quick_party.gd:105-109` (header) and `:173-176`
    (`show_buffs := true`, `hp_caution := true`, `mp_caution := true`);
  - `docs/rounds/party715.md:73`, the OURS row ("their defaults with no `SROptionSet.dat` are not
    read");
  - `docs/protocol/party_gui.md:632-633`.
- **Evidence (READ):**
  1. The game options block is `CGame+0x543` (`0x4f9d00` → `0x835270`: `lea eax,[ecx+0x543]`;
     29 bytes, copied in by `0x835250`).
  2. Its constructor is **`0x7776c0`**. It writes:

     | bytes | value |
     |---|---|
     | `+0..+8` | 1 (so **`+0x08` = 1**) |
     | `+9` | 0 |
     | `+0xa` | 1 |
     | `+0xb` | 0 |
     | `+0xc..+0x11` | 1 |
     | **`+0x12`** | **0** |
     | **`+0x13`** | **0** |
     | `+0x15..+0x18` | 0 |
     | `+0x19` | 1 |
     | `+0x1a` | 0 |
     | `+0x1b` | 1 |
     | `+0x1c` | 0 |

  3. It is called in three places:
     - `CGame`'s constructor (`0x848c4c` `lea ecx,[esi+0x543]` … `0x848ca0` `call 0x7776c0`);
     - on the stack copy in `CGame::FUN_008469c0` (`0x8484f2` `lea ecx,[esp+0xc4]`; `0x8484f9`
       `call 0x7776c0`), **before** the file load `0x501720` at `0x848923` and the copy-in
       `0x835250` at `0x8488d3` / `0x84899a`;
     - in `CGInterface::FUN_0077c190`, right before it reads `%s\Setting\SROptionSet.dat` with
       `0x502680`.

  So without the file: **the buff row is on, and the HP and MP caution effects are off.** The
  player block's own caution also gates on `+0x12` (`0x7b8265..0x7b826e`).

  Cost to find: four lookups. "Could not be read" was not true.
- **Effect:** every OpenSRO player sees the low-HP/MP blink on party boxes. A retail player who
  never opened the Game options never does.
- **Fix:**
  - set `hp_caution := false` and `mp_caution := false`, and keep `show_buffs := true`;
  - label all three READ (`0x7776c0`; the load order above);
  - correct `party715.md`'s row and `party_gui.md` item 5;
  - flip the test to check that the cautions stay hidden by default and show only with the
    option set.

### 2. BUG / DEPARTURE: `0x7fab90(1,1)` is a row cap (one row per list), left OPEN; the board's buff rows are unbounded and overflow into the next box

- **Where:**
  - `hud_quick_party.gd:87-94` and `:511-518`;
  - `hud_target_buffs.gd` (`set_grid`, `sync`, `_add`): no cap;
  - `party715.md:48` and `:76`;
  - `party_gui.md:509-513` and `:689`.
- **Evidence (READ):**
  - `0x7fab90` is `+0x36c = a; +0x370 = b`.
  - The viewer's add `0x7fd020` checks both before creating an icon:
    - one list compares `count +0x3a0 >= per_row(+0x374) * rows(+0x36c)` (`0x7fd0cd..0x7fd0eb`);
    - the other compares `count +0x3a4 >= per_row * rows(+0x370)` (`0x7fd0a0..0x7fd0bd`).
  - When the cap is reached, the entry is dropped (`0x7fb070` and skip).
  - The abnormal-state add `0x7fd2e0` makes the same `+0x370` test (`0x7fd31b..0x7fd32e`).
  - A 0 means no cap. The target window never calls `0x7fab90`, so it has no cap. Only the quick
    party board (`0x6d902a`) and `0x7b4730` call it.

  With `(1,1)` and 6 per row, **a party box shows at most 6 buffs plus 6 states, one row each.**

  Screenshot 04 agrees: all seven boxes show exactly 6 buff icons.

  This review's reading also turns the round-638 "per row" analogy into a direct READ for this
  viewer: `+0x374` is the multiplier in the cap. `0x7fd020` also creates each icon at
  `(+0x380, +0x384)`, which is the icon size.
- **Effect:**
  - A member with 7 or more buffs gets a second buff row at slot y 54.
  - With 13 or more entries, a third row at y 69..81 runs past the 73-px row step into the next
    member's box.
  - High-level characters routinely carry more than 6 buffs.
- **Fix:**
  - Give `HudTargetBuffs` per-list row caps, for example
    `set_row_caps(main_rows, second_rows)` with 0 meaning unlimited, so the target window is
    unchanged.
  - Drop entries past `columns * rows` in add order. The rebuild's fill `0x6d9010` clears the
    viewer (`0x7fbcf0`) and re-adds in the member's own order, so the first six of that order are
    the ones kept. The 1 s refresh goes through `0x7fd640`, whose ordering this review did not
    read. `sync` must apply the cap after its diff, not only in `_add`.
  - Call it with `(1,1)` from `_add_buffs`. Add a test with 8 buffs and 8 states that expects
    6 + 6.

### 3. PERF (process hygiene): two orphaned renamed-binary clients are still running, invisible to the gate and to the reaper, and they overlapped the lane's own gate run

- **Where:** the box, not the repo.
  - `ps` at review time showed PIDs `153836` and `165564`. Both are
    `/var/tmp/c3/bin/GodotC3 --headless … World3D.tscn`, user `ghidra`, PPID 1, with
    `OPENSRO_QA_CHARACTER=Bram` and cwd `/opt/opensro-client-c3`.
  - They started at 06:17:16 and 06:22:45 (runs A2 and A3's second clients). They were still
    alive about 35 minutes later at 1.7 GB RSS each, about 6 % CPU each, and still appending to
    `/var/tmp/c3/liveA/second.log`.
  - `run_c3a2.sh`'s `kill -9 $SEC` did not reach them.
- **Evidence:**
  - `perf_gate.sh:246`'s `others()` matches only `^/opt/godot-bin/Godot_v4`.
  - `qa_shot.sh:192-198`'s reap matches `godot-bin/Godot_v4.2.2` and `-x Xvfb`.
  - So a `GodotC3` or `XvfbC3` is invisible to both. The lane's gate run (06:25–06:34, from the
    perf cache directory's times) ran while both orphans were alive.
  - The scripts used a private lock (`GODOT_LOCK=/var/tmp/c3/lock`), so they never queued behind
    other lanes either.
  - The load is small and hit base and head alike, so the table's SAME verdicts probably stand.
    But they were not taken on a quiet box.
- **Committed dependency: none.**
  - No file in the tree references `GodotC3`, `XvfbC3` or `/var/tmp/c3`, except the round notes'
    prose (`party715.md:114-118`).
  - `run_c3a*.sh`, `run_c3b.sh` and `wait_run.sh` live only in `/var/tmp/c3` on the box.
  - The only committed tool change is partybot's `-tp` flags.
- **Fix:**
  - The lane owner or the coordinator kills the two `GodotC3` processes. This review did not, per
    its brief.
  - Delete `/var/tmp/c3/bin`.
  - Re-run `perf_gate.sh --sites jangan` on the head (see finding 6).
  - Strike the renamed-binary method from the notes as a recommendation. If another lane's reap
    kills a run, the fix is to queue on the box lock, not to hide from it.

### 4. WRONG-LABEL: "an id with no record hides its icon" is not what the binary does for the first mastery icon

- **Where:** `hud_quick_party.gd:45-47` (header, READ) and `:542-554` (`_fill_masteries` hides
  either icon); `party715.md:22-24`.
- **Evidence (READ, asm):**
  - The per-slot reset `0x6d8630` hides **`+0x3c4` twice** (`0x6d8696..0x6d86bc`); it never
    hides `+0x3c0`.
  - In `0x6d9250`, a missing first mastery (`ebp == 0`, `0x6d9420 je 0x6d9495`) runs
    `mov ecx,[esi+0x3c4]; push 0; call [vtbl+0x5c]`. That hides the **second** icon.
  - The second icon then gets `Show(mastery2 != 0)` at `0x6d951b`.
  - So in retail, icon 1 is hidden only at creation (`0x6d8a64`) and otherwise keeps its last
    state.
  - Slots are reused across rebuilds (`0x6da110` runs only when the vector runs out). So a reused
    slot whose new member has no first mastery keeps showing the previous member's icon. This is
    a retail defect.
- **Fix:** keep the lane's behaviour, but label it honestly. Retail never hides icon 1 once shown
  (`0x6d8630`, `0x6d9495`), and hiding it is OURS (a retail defect not reproduced). The other
  option is to reproduce the defect and say so. That is the user's call; label it either way.

### 5. PERF (claim scope) / MINOR: the 26 µs figure measures the board with the world stubbed out, and the tick allocates every frame

- **Where:**
  - `party715.md:174-177` ("a full party's board … the 1 s buff refresh included");
  - `hud_quick_party_test.gd:260-275`;
  - `hud_quick_party.gd:677-707`;
  - `World3D.gd:21334-21349` and `:21438-21456`.
- **Evidence:**
  - The test sets `player_region_local` to a constant lambda and leaves `member_body` and
    `buffs_of` unset. So every member takes the record path against a fixed dictionary, the buff
    refresh does nothing, and there is no archive (no textures, no atlas frames).
  - In the game, each tick also does the following:
    - 7 × `_party_body` through `member_distance_sq`;
    - 7 × `_party_player_region_local`, each allocating a Dictionary, doing `group.to_local`, and
      maybe walking `_nav_graph_for` when the minimap group is stale;
    - one `shown_members()` array;
    - per slot, the `[[fx, bool], [fx, bool]]` literal in `_caution`.
  - The rebuild runs on every `PartyState.changed`. The server samples each member once a second
    (`session/party.go:54`), so a moving 8-party rebuilds up to 7 times a second, each with a
    party-pane refresh. That cost is not measured at all.
  - The 26.0 µs reproduces exactly (see the test results). It is the board's own logic, not the
    in-world cost.
- **Fix:**
  - Reword the claim to "the board's own tick with the world's lookups stubbed".
  - Hoist `player_region_local` to once per tick.
  - Iterate `_slots` with each slot's own member (finding 7) instead of rebuilding
    `shown_members()`.
  - Replace the nested-array literal with two plain calls.
  - Time a tick through World3D's real callbacks, or the live run's frame log, with a full party.

### 6. MINOR (process): the perf-gate table is of `0ccd00a1`, not the head

- **Where:** `party715.md:152-178`.
- **Evidence:** the notes say the two perf changes "came after the gate run". The table's base and
  head ran with the orphans of finding 3 alive.
  - The head's extra client code touches only in-party paths: the `_party_body` cache and
    `set_faraway`.
  - `_tick_party_hud`, which runs every frame in every view, was already in `2b9be98e`. So a
    regression is unlikely.
- **Fix:** after the orphans are gone, run `perf_gate.sh --base int/party --sites jangan` once on
  `db41d25e` (6 minutes) and replace the table.

### 7. MINOR: the per-frame tick pairs `members[i]` with `_slots[i]` instead of looking the member up by the slot's JID

- **Where:** `hud_quick_party.gd:679-689`.
- **Evidence:**
  - Retail's `0x6db380` takes each slot's own JID (`0x6d7f40`) and looks the record up by it
    (`0x992260`), asserting that it is not the player.
  - The lane re-derives `shown_members()` every frame and indexes both lists by position. The
    glow uses `s.jid` while the overlay uses `members[i]`.
  - They agree today only because `rebuild` runs synchronously on every `changed`.
  - Any path that reorders or edits `state.members` without emitting `changed` would put one
    member's overlay on another member's box. `swap_members` mutates first and rebuilds second,
    so it is safe today.
- **Fix:** in `tick`, use `state.member(s.jid)` (PartyState already has it) for each slot.

### 8. MINOR: the 250 ms negative cache in `_party_body` also answers round 711's `is_spawned_player` and `player_name`

- **Where:** `World3D.gd:21432-21462`.
- **Evidence:**
  - `party.is_spawned_player = _party_is_spawned` (`:21268`) and `_party_player_name`
    (`:21460`, the system-message names at `:21542`) both go through `_party_body`.
  - After the board misses a member, either query for that JID returns null or "" for up to
    250 ms after the member actually spawns.
  - Impact is small:
    - the invitation check (`party_state.gd:276`) asks about inviters, who are not in your party
      and so are never on the board;
    - the name lookups only ever named spawned players.
  - Still, a throttle meant for the board changed two other callers' answers without saying so.
  - `_party_body_ids` and `_party_body_misses` are never pruned. They grow by one entry per JID
    ever seen, which is negligible.
- **Fix:** keep `_party_body` exact. Give the board its own throttled wrapper
  (`_party_body_for_board`) that owns the miss table. Clear both tables on leaving a party.

### 9. MINOR (label understated): the lock's 20x20 and its (0, board y − 7) position are READ, not "the round-709 spec's"

- **Where:** `hud_quick_party.gd:35-37`.
- **Evidence:**
  - `CIFQuickPartyWnd::vslot_010` `0x6db2ab..0x6db2b4` builds the button rect `{0,0,0x14,0x14}`.
  - `0x6db325..0x6db33c` moves it to `(0, rect.y + 0xfffffff9)`, where the rect comes from the
    board's `0xb8f420`.
  - The lane's code is right; only its label is weaker than the evidence.
- **Fix:** relabel as READ (`0x6db2ab`, `0x6db337`).

### 10. MINOR (evidence for an INFERRED label): the caution sprite's period is a timer interval in ms, phased by the player block's counter

- **Where:** `hud_quick_party.gd:79-85` and `:694-716`.
- **Evidence (READ):**
  - The sprite start `0x654730(t)`:
    - takes `t % (frames(+0x348) × period(+0x34c) [+ +0x350])`;
    - sets the frame to `t / period`;
    - arms timer 1 with `period` (`0xb93320(1, +0x34c)`), the same call that takes 1000 for the
      1 s buff timer.
  - The slot passes `t = window 0xb's +0x460` (`0x6d90f2..0x6d9144`, `ecx = [0x110f80c]`, the
    interface). Window 0xb is the player block, whose own caution adds each frame's ms to `+0x460`
    and wraps it by the same product (`0x7b81e8..0x7b822d`).
  - So the board blinks in phase with the player block. If window 0xb were missing, the whole
    caution routine would be skipped (`0x6d9103`).
  - `0x652e10` (stop) also hides the sprite, so recovery above 0.3 hides it. The lane does the
    same.
  - What is still unread is only which layout field fills `+0x34c` ("Speed" = 100 is the obvious
    candidate). INFERRED stays honest. With finding 1, the effect is off by default anyway.
- **Fix:** add these addresses to the INFERRED note; nothing else.

### 11. MINOR: Ctrl+2..8 on a member who is not spawned

- **Where:** `World3D.gd` `_select_quick_party_member`.
- **Evidence:**
  - `0x77f230` calls `0x78f5f0(edi)` unconditionally after `0x9c3640` (`0x77f2fa..0x77f30e`).
    For an unspawned member, retail therefore sends `0x7045` with id 0, and the server refuses it.
  - The slot click `0x6d8500` sends only when found.
  - OpenSRO's selection is local (round 622's design, not this lane's), so nothing is sent either
    way.
- **Fix:** none needed in this round. Note it in `party_gui.md` §7's Ctrl line, for the day
  selection goes through `0x7045`/`0xB045`.

## Verified correct (READ or MEASURED by this review)

- **Board origin and wrap** (`0x6db033..0x6db07c`):
  - wrap when `screenH(0x4f9cd0+0x28) − board y − row − 0x49 < 0xe6`, then `column += 0x85` and
    `row = 0`;
  - x = board x + column + 0xd, y = board y + row;
  - rows step 0x49 with option `+0x08` and 0x38 without (`0x6db0d8..0x6db0e9`);
  - the test runs before every slot, the first included.
  - The frames put the slots at y 137 / 210 / 283 and x 17.
- **The slot UV** (`.rdata`, read from the exe): `0xda5438` = 0.723633, `0xda973c` = 0.842773,
  `0xda9740` = 0.138672, `0xda9738` = 0.216797. These give exactly 741..863 × 71..111 =
  122 × 40, the slot's size. The old pairing gave 641 × 300.
- **Faraway** (`0x6db380`, `0x6d86e0`, `0x9ed1e0`):
  - squared region-aware 3D distance;
  - the unspawned record at `local_8 = 0`, so y = 0;
  - stepped only when manager `+0` (exp mode) == 1;
  - `0xda9910` = 1e6 (double), `0xda990c` = 810000 (float), `0xda9908` = 640000 (float),
    `0xda9900` = 490000 (double), `0xda98fc` = 360000 (float), each `>=`. Ghidra's
    `a < d == (a == d)` decodes as `d < a`.
  - `0x472340`, the early return in each case, is only a same-texture-name check.
- **Selection glow** (`0x6db1a0`, `0x6dab90`, `0x6dac10`, `0x6d9610`):
  - per slot, `Show(selected == slot jid)`;
  - cleared when nothing matches or the object is gone;
  - the board's id comes only from SetTarget `0x780ee0`.
- **Slot click** (`0x6d8500`): name → `0x9c3640` → `0x78f5f0` only when found; `uiwinopen.wav`
  either way.
- **Leader flag on a slot** (`0x6d7db0`): manager `+0x14 ==` the slot's JID.
- **Player block** (`0x7b7cae..0x7b7cd6`): glow iff the target window's id (`0x778140` → window
  0x10 → `0x698bd0`) is the player's own (`0xeef5e8`). This is the same as the lane's
  `_selected_character == own` in every path OpenSRO has. The leader flag is
  `Show(0x987080())`, manager `+0x0d`, at `0x7b81ba..0x7b81d9`.
- **Ctrl+1..8** (`0x77f230`): `'1'` → `0x78f5f0(player+0xf8)`, which really selects yourself.
  Otherwise slot `key − 0x32` (`0x6da850`). `keymap.gd`'s mapping
  (`select_party`, `d − 1`) with World3D's `arg − 1` gives slot `n − 2`. `keymap.gd` is unchanged
  by this round, and Ctrl+digits are resolved there and nowhere else: Ctrl+9 and Ctrl+0 stay
  no-ops, and digits are not run while typing.
- **Caution rules** (`0x6d90e0`):
  - shown when the gauge's `+0x384` is below 0.3 (`0xd82f00` = 0.3) and slot `+0x3ac`
    (record `+0x58`, copied by `0x6d7db0`) is 0;
  - the HP effect is `Show(option +0x12)` and MP is `Show(option +0x13)`;
  - both are hidden at faraway level 5.
  - The HP gauge's `0.2` is `0xda95f8` = 0.2.
- **Buffs** (`0x6d9250` tail, `0x6d8b20` = the slot's OnTimer): fill only for a spawned character
  with option `+0x08` on. Timer 1 runs at 1000 ms, and the timer clears the viewer when the member
  is not spawned.
- **Grid** (`0x7fabb0`, `0x7fabc0`, `0x7fabe0`): 6 a row, 15 pitch, 12 × 12.
- **Lock** (`0x6db380` end): shown iff manager `+0x10 > 2`. Otherwise `+0x384 = 0` and the art is
  reset (`0x6da210`). A click flips `+0x384`.
- **Portrait** (`0x6d80d0`, `0x6d8bf0`, `0xe1b7fc` = 0.1, `0xe1b7f0` = 1.0 (double), `0xda95f8` =
  0.2, `0xda95f4` = 6.5, `0xd82ef0` = 30):
  - The model is the slot's own, from the record's model id.
  - The only conditions are that the model is loaded (`vslot 0x98`, else retry next frame) and
    that `BufRender::FUN_009edb60(0)` succeeds. There is no spawn test and no option.
  - The lane's reading of the user's black discs is fair:
    - in screenshots 03 and 04 the player block's disc is black too, while the pet slot's picture
      beside it draws;
    - the user's own text asks for the 3D portrait to "show … like at the top left".
  - `PlayerPortrait`'s constants match (`MODEL_YAW` 0.1, `TARGET_LIFT` 1.0, `CAMERA_YAW` 0.2,
    `CAMERA_DISTANCE` 6.5, `CAMERA_FOV_DEG` 30). The slot reuses them.
- **No regressions found** in the following:
  - **`HudTargetBuffs`:** the new layout formulas equal `main_rows`/`second_rows`/`slot_position`
    at the defaults, and the icon resample stays 20 × 20 (`HudBuffBoard.ICON_SIZE` is (20,20)).
    So the target window is unchanged.
  - **`hud_player_info.gd`:** additive. The two nodes are found after the allow-list pass at
    `:156`, which runs only in `setup`.
  - **Party window rows:** the leader row and member rows take `member_portrait(jid)`, and own
    rows still take `own_portrait`.
  - **partybot:** builds and vets clean, and `-tp`/`-tp2` default off. `moveTo` already existed
    and sends a relocated move.
  - **World3D:** only its own new functions plus hooks: the `_build_quick_party` call, the
    `_tick_party_hud` call in the once-a-frame minimap block, two keymap cases, QA steps, the
    `_party_body` cache (finding 8), and the `member_portrait` wiring.

## The frames, measured (`/var/tmp/c3/liveA`, 1280x720)

| frame | measurement | expected |
|---|---|---|
| `f00000590` | teal pixels (`g > 150`, `b > 140`, `r < 140`, `g − r > 60`) span x 15..140, y 134..177; 1963 px, mean (57,174,159) | Bram's slot at (17,137) with the glow art 132 × 48 at (−3,−4) = 14..145 × 133..180, transparent rim |
| `f00000525` | the same test spans x 15..140, y 280..323 (Dex's box) | slot at (17,283) |
| `f00000525` | Dex's blue disc (`b > 200`, `r < 60`, `g < 130`): x 23..50, y 289..316; 632 px, mean (16,93,243) | a 28 × 28 at slot + (6,6) |
| `f00000650` | yellow (`r, g > 150`, `b < 110`) spans x 3..216, y 7..77 in the player block; 578 px | — |

Notes on the frames:
- **`f00000525`:** Dex's box is also *selected* in this frame. The invite step left Dex selected,
  so this frame is not a clean "screenshot 03/04" view. The notes call it one without saying so.
- **`f00000650`:** frame 649 gives the same box and count. The selection is at QA tick 620.
- **The lock:** at (0,130) by eye, the same place as screenshot 03's lock (about (1,129) after
  dividing by that screenshot's ×1.97). This one is a picture reading, not a measurement.
- **Against the user's screenshots:**
  - the pitch, the slot art, the teal glow's extent (11), the yellow glow over the name strip
    (10), the leader flag beside the disc, and the mastery pair under the disc with the buffs to
    their right (04, 11) all match;
  - the buff pitch in 04 is 25 px at ×1.67 = 15 and the icons about 12;
  - the one visible difference is the portraits, explained above.

## Clean-up

- This review's worktree and its box scratch (`/opt/opensro-client-r715rev`, `/var/tmp/r715rev`)
  were removed.
- The lane's own `/var/tmp/c3` and its two orphaned processes (finding 3) were left alone, per the
  brief.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Y12ecfRLgyrW8rPt8BVTF9
