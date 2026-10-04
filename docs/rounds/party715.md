# Round 715, lane C3: the party member boxes on the HUD

The HUD half of the party epic's last client lane. Built on `int/party` (`85e6c063`: S1 round
710, C1 round 711, S3 round 713, each with its review fixes) against `party_gui.md` §7, with
every rule re-read in `sro_client.exe` (the box's `/var/tmp/decomp_client`, objdump on the exe,
floats read from `.rdata`). Labels: READ (the binary), MEASURED (the archives / frames),
INFERRED, OURS, OPEN.

## What was built

- **`ui/hud/hud_quick_party.gd` (HudQuickParty)**, CIFQuickPartyWnd, built in code
  (`ifquickpartywnd.txt` is not loaded), each slot `resinfo\ifquickpartyslot.txt`:
  - **The board** (READ `0x6dae90`): at `GDR_QUICKPARTYBOARD`'s 4,137; one 122x40 slot
    (`0x6da110`) per member other than the player, in the party manager's order, skipping the
    player by name; slot n at (13 + column, row), the row stepping 73 with the buff option on and
    56 with it off; a new column 133 to the right when (screen height - board y - row - 73) <
    230. Out of a party: no slots, hidden.
  - **The slot's art**: `window_all.ddj`, u 0.723633..0.842773 x v 0.138672..0.216797 (READ
    from the four floats `0xda5438`/`0xda973c`/`0xda9740`/`0xda9738`) = the 122x40 round-faced
    box at 741..863 x 71..111 of the atlas (MEASURED, decoded). Round 709's spec had the pairs
    swapped (a 641x300 region of other panels): corrected in `party_gui.md`.
  - **Name, HP and MP gauges, the leader's red flag** (`0x6d9250`, `0x6d7db0`: the flag iff
    the party's leader id is the member's); the race mark stays hidden (never taken).
  - **Two mastery icons** (17x17 at -3,39 and 15,39) from the record's two mastery ids through
    `skillmasterydata.txt` (icon column 11, the name code resolved as the tooltip). Since the
    review: retail's rule exactly -- the second icon is hidden by the per-slot reset and shown iff
    its record exists; the first is never hidden once shown (a reused slot keeps it), a retail
    defect reproduced (READ, `0x6d8630`, `0x6d9495`, `0x6d951b`).
  - **The 3D portrait**: a PlayerPortrait at the slot's 64x64 buffer (`0x9edae0(0x40,0x40)`),
    the PMI camera (`0x6d8bf0`: Bip01 Head +1.0, yaw 0.2, distance 6.5, 30 deg), through the
    `qpt_face.ddj` disc. The body is the slot's own model built from the record's model id with
    ANI_POSE (`0x6d80d0`), so a member has a face spawned or not -- bare, since the model id
    carries no equipment. Re-rendered only when the model id changes (the dirty byte `+0x3dc`).
    The party window's member rows borrow it (`HudPartyPane.member_portrait`, `0x6dab10` ->
    `0x6d7f30`).
  - **The "far away" overlay** (READ `0x6db380`, `0x6d86e0`): each frame the squared 3D
    distance to the member's spawned body, else to the record's region/x/z **at y = 0**
    (`local_8` stays 0: the record's y is not used), stepped only in an exp-share party: level 5
    from 1e6 (double), 4 from 810000, 3 from 640000, 2 from 490000 (double), 1 from 360000, each
    `>=`; `qpt_face_faraway_60..100.ddj` on GDR_QPS_STATUS (MEASURED 28x28 discs, alpha
    130..241: five steps, no fade).
  - **The caution effects** (READ `0x6d90e0`): HP/MP below 0.3 (`0xd82f00`) with the record's
    byte `+0x58` = 0, then by the game option bytes +0x12 / +0x13; hidden at level 5. The 8
    frames (4x2 of 64x32) at one per 100 ms: "Speed 100" read as ms a frame is INFERRED.
  - **Buffs** (READ `0x6d9250`'s tail, `0x6d9010`): only for a member spawned in this client and
    with option +0x08 on; the member's skill buffs and abnormal states (the target window's own
    source), re-read every 1000 ms (`0xb93320(1, 0x3e8)`); otherwise cleared. The grid: 6 a row
    (`0x7fabb0(6)`), 15-px pitch (`0x7fabc0(0xf,0xf)`), 12x12 icons (`0x7fabe0(0xc,0xc)`) --
    the meanings the target window's own calls were read with in round 638 (`HudTargetBuffs`
    gains `set_grid`; its own grid is unchanged). Since the review: `0x7fab90(1,1)` caps each
    list at one row (`set_row_caps`; the target window has no cap).
  - **Selection** (READ `0x6d9610`, `0x6db1a0`, `0x6dac10`): the slot whose member is the
    selected object shows GDR_QPS_SELECT (`qpt_grope_select.ddj`, MEASURED teal), the rest hide
    it, every frame; a click (`0x6d8500`) names the slot's member, World3D selects them by name
    when spawned (`0x9c3640` -> `0x78f5f0`), and `prim\snd\ui\uiwinopen.wav` plays either way.
  - **The lock** (READ `0x6db290`, `0x6da210`, `0x6da9d0`, `0x6db5e0`): 20x20 at screen x 0,
    7 above the board; `quickparty_move_lock/_unlock.ddj` and the MOVE/STATE/LOCK/UNLOCK tooltip;
    a click toggles drag; a drop swaps the two members in the party manager's list
    (`0x992490`) and rebuilds; shown only above 2 members (`0x6db3f9`).
- **`hud_player_info.gd`**: GDR_PMI_SELECT (the yellow `pmi_select.ddj`) shown exactly while the
  player is the selected object, and GDR_PMI_PARTY_LEADER while the player leads
  (party_gui.md §7, `0x7b7cbe`, `0x7b81ba`).
- **World3D** (its own functions only): the board's hooks (`_build_quick_party`: where the
  player and each member are, the selection, buffs, a bare body per model id), the slot click,
  **Ctrl+1** (select self, `0x77f230` -> `0x78f5f0`) and **Ctrl+2..8** (slot n-2's member by
  name, `0x6da850`), both no-ops before; the PMI glow per rendered frame. QA steps on
  `OPENSRO_QA_PARTY`: `qpclick:<name>`, `selfselect`, `qplock`, `qplog`.
- **`server/cmd/partybot`**: `-tp "x z"` and `-tp2 "x z" -tp2-after D` (a GM `/tp` on entry and
  again D after joining a party), so a live run can stand bot members at chosen distances (OURS,
  a QA tool; no game code).

## OURS / INFERRED / OPEN

| what | label | note |
|---|---|---|
| ~~game option bytes default on~~ | **READ (review fix 1)** | `0x7776c0` builds the block before `SROptionSet.dat` is read: +0x08 = 1 (buff row on, 73-px rows), +0x12 = +0x13 = 0 (both cautions off) |
| the lock button's hover/press/disable art from the `_focus/_press/_disable` files | INFERRED | the builder's convention for every CIFButton; retail sets the normal art by the button's SetTexture |
| caution sprite: one frame per 100 ms | INFERRED | `0x654730(t)` frames by a timer period `+0x34c` (READ); that the period is the layout's `Speed=100` is the inference; retail phases it on the player block's counter (window 0xb `+0x460`), here on the clock |
| ~~`0x7fab90(1,1)`~~ | **READ (review fix 2)** | one row a list: at most 6 buffs and 6 states |
| the record's byte `+0x58` | OPEN | OpenSRO never sets it, so the caution test treats it as 0 |
| the HP gauge's 0.2 at HP 0 (`0x6d9303`) | OPEN | `0x6d9250` writes 0.2 into the gauge's `+900` and `+0x380`, then `0x6d7db0` (same rebuild) writes the raw ratio into `+900`; which of the two the gauge draws is not read. Drawn: the raw ratio |
| dungeon positions (`region & 0x8000`) in the record distance | OPEN | OpenSRO sends none (S1 omits the position bit); taken as plain region math |

## Corrections to existing records (applied in `party_gui.md` §7)

- The slot's atlas slice (see above).
- "With the member not spawned in the client, nothing is drawn and the disc stays black": the
  portrait is the slot's own model from the record's model id (`0x6d80d0`), drawn spawned or
  not. Screenshots 03/04/11/12 show every disc black **including the player's own mini-info
  portrait**, so those frames come from a client whose BufRender draws nothing (the user tests on
  macOS CrossOver); they are not evidence about the rule.
- The far-away distance uses the record's position at y = 0.
- The buff grid: 6 a row, 15-px pitch, 12x12 icons (the spec had "icons 15x15, 12 per row").
- HudPartyPane's comment that member squares stay black until C3: they borrow the slot render now.

## Tests

- `ui/hud/hud_quick_party_test.gd` (new, 48 checks): the slot positions and the column wrap, the
  faraway steps at every boundary and the free-for-all rule, the record distance across regions
  and at y 0, the rebuild (count, order, the player skipped, the leader flag, the hidden race
  mark, the mastery icons), the lock (count > 2, position, toggle), the glow following the
  selection, overlay and caution levels end to end, the click (member + sound), Ctrl+n's lookup,
  the swap, the buff row (spawned only, the option), and the viewer grid (and the target
  window's unchanged).
- Box (`RENDER_DIR=/opt/opensro-client-c3`), at the final code: `check` 588 scripts and 9
  scenes ALL LOAD; full suite 227 suites, 0 failing.

## Live

Against a server built from this branch (`-in-memory`, the box's retail exports; the skills table
from `/var/tmp/euroskill691/skills.csv`, 91 columns -- the box's default `skills.csv` is the
37-column export of 2026-09-19 and carries no buff columns, so no buff starts with it). Four
characters: **Aria** rendered (the leader), **Bram** a headless second client beside her who
learns and casts Grass Walk (skill 113) from his hotbar, and partybots **Cara** and **Dex**
(`-tp` beside Aria to be invited, `-tp2` 25 s after joining: Cara 650 east, Dex 1500 east).

**Another lane's qa_shot kills every client on the box** (its reap: `pkill -f
godot-bin/Godot_v4.2.2`, `pkill -x Xvfb`). Two of this round's qa_shot runs died that way at frame
~230 when lane C2 started a render. The runs below then used renamed copies of Godot and Xvfb
(`/var/tmp/c3/bin/GodotC3`, `XvfbC3`) under a private lock. **That was wrong, and is not a method
to repeat** (the review, finding 3): the copies were invisible to every other lane's reap and to
the perf gate's idle test, two of their headless second clients outlived the runs (`kill -9` on
the `runuser` wrapper missed the child) and were still running during this round's first gate
run, until the coordinator killed them; `/var/tmp/c3/bin` is deleted. The fix for a run another
lane kills is to queue on the shared box lock and rerun, not to hide from the reap.

**Run A3** (`/var/tmp/c3/liveA/`, RADV NAVI33 on Vulkan; 680 frames):
- the party forms by Aria's invites; the board's log at tick 520:
  `Bram far=0 buffs=1; Cara far=1; Dex far=5`, lock shown (4 members), leader flag on the player
  block;
- `f00000525.png` (screenshots 03 / 04): Bram's box with his portrait, his lightning mastery icon
  and the Grass Walk icon at slot +32,+39; Cara's disc under the light faraway_60 blue, Dex's
  fully blue. **Dex's box also glows teal in this frame**: the QA invite step selects each
  invitee, and Dex, invited last, was still the selection -- so it is not a clean screenshot 03/04
  view in that one respect. MEASURED on the frame: Dex's overlay is exactly the 28x28 disc (632 matching
  pixels, x 23..50, y 289..316 = slot 17,283 + 6,6; mean (16,93,243) over the
  α241 (14,96,255) art), Cara's disc centre mean (74,101,169) (α130 over a face), Bram's
  (137,107,80) (the face, no overlay); the party window's rows carry the same three portraits;
- `f00000590.png` (screenshot 11): Bram's box selected by `qpclick:Bram`: the teal frame.
  MEASURED in run A2's frame 525 (Dex selected, his box at 17,283): teal pixels x 16..139,
  y 281..322, mean (72,218,206), inside the art's 132x48 at slot -3,-4 = 14..145 x 279..326
  (its outer texels transparent);
- `f00000650.png` (screenshot 10): `selfselect`: the player block's yellow glow (648 yellowish
  pixels over x 3..217, y 7..77 against 167 in the frame before -- the "Lv" digits), Bram's
  glow off.

**Run B2: real X input** (`/var/tmp/c3/liveB/main.log`; Compatibility on Xvfb :715, xdotool,
the client as ghidra), Aria and Bram in a party, Bram selected by the invite:
- Ctrl+1 (xdotool keydown ctrl, key 1): `KEYMAP Ctrl+1 -> select_self`, `player block's select
  glow on`, `Bram's box deselected`;
- a click at (78, 157), Bram's box: `HudQuickParty: Bram's box clicked`, `selected player 1
  (Bram)`, `player block's select glow off`, `Bram's box selected (glow on)`;
- a click on the ground (900, 500): **nothing deselects** -- and that is the original's rule:
  the ground click `UI_SILKMALL::FUN_0078f8d0` (from the left press `0x793570`) never calls the
  deselect `0x778650(0)` or the selector `0x780ee0`; it moves the ring (round 698's table). The
  user's request says a ground click ends the selection; the binary says it does not (READ),
  and the client follows the binary. A monster, NPC or another player clicked does replace it
  (World3D's existing selection paths, `0x778650` from the object click `0x792f00`);
- Ctrl+2: `KEYMAP Ctrl+2 -> select_party 1: selected party member Bram`.

## Perf gate

**The table that stands is the head's, in the review-fixes table below (jangan SAME on all four).**
The first run, kept for the record (reeds and cross included), was of `0ccd00a1` and overlapped
the two orphaned second clients (review finding 3):

`client/tools/perf_gate.sh --base 85e6c063 --sites jangan,reeds,cross --frames 12000 --env
'OPENSRO_QA_VIDEO_STEPS=quality=0|quality=1'` (the working tree at `0ccd00a1`'s client code
against `int/party`; 1280x720, Forward+ on the RX 7600, median of 3):

```
jangan  frame ms   base 1.50  head 1.50  (+0.0)  SAME
jangan  entry ms   base 9694  head 9670  (-24.0)  SAME
jangan  freeze ms  base 3337  head 3337  (+0.0)  SAME
jangan  hitches    base 5  head 5  (+0.0)  SAME
reeds   frame ms   base 1.40  head 1.40  (+0.0)  SAME
reeds   entry ms   base 7180  head 7114  (-66.0)  SAME
reeds   freeze ms  base 1980  head 1961  (-19.0)  SAME
reeds   hitches    base 2  head 2  (+0.0)  SAME
cross   frame ms   base 1.66  head 1.66  (+0.0)  SAME
cross   entry ms   base 10395  head 10400  (+5.0)  SAME
cross   freeze ms  base 3375  head 3356  (-19.0)  SAME
cross   hitches    base 4  head 5  (+1.0)  SAME
```

The gate's views carry no party, so the board is hidden there and its own frame cost is not in
these numbers. MEASURED separately (`hud_quick_party_test.gd`'s `TIMING` line, the box,
headless): **26 us a frame** for a full party's board (7 slots, every member placed by record,
the 1 s buff refresh included; the world's lookups stubbed), after two changes made for it: the overlay picture is re-set only
when the level changes, and World3D remembers each member's body by JID and, for a member not
spawned here, scans the bodies at most every 250 ms (OURS) instead of every frame. Those two came
after the gate run and touch only in-party frames.

## Review fixes (`docs/rounds/party715_review.md`)

| # | finding | fix |
|---|---|---|
| 1 | option defaults are READ: caution off | `hp_caution` / `mp_caution` start false, `show_buffs` true, all three labelled READ (`0x7776c0`, before `SROptionSet.dat` is read); the test now checks no caution by default and the effect with option +0x12 set; `party_gui.md` item 5 |
| 2 | `0x7fab90(1,1)` is a row cap | `HudTargetBuffs.set_row_caps(main, second)` (0 = none, so the target window is unchanged); an add past columns x rows is dropped, in `_add`, so `sync`'s new entries respect it after its diff; the board sets (1, 1). Tested: 8 buffs + 8 states give 6 + 6, the first six kept; the target window's viewer keeps all 16 |
| 3 | renamed binaries, orphans | the coordinator killed the two orphans; `/var/tmp/c3/bin` deleted; every box run after this used the stock `remote_godot.sh` / `perf_gate.sh` on the shared lock; the notes above strike the method |
| 4 | mastery icon 1 | retail's rule reproduced and labelled READ: icon 2 hidden by the reset and shown iff its record exists; icon 1 shown when its record exists and never hidden after (`0x6d8630`, `0x6d9495`, `0x6d951b`). Tested, including the stale first icon on a reused slot |
| 5 | per-frame cost, claim scope | the tick allocates nothing: the player's region/local come from two value callables backed by World3D fields updated once a frame (`_update_party_here`, from the minimap's own lookup), each slot is paired with its member by `state.member(s.jid)` (no `shown_members()` array), the caution's nested array is two plain calls. A kind-6 member update now emits `PartyState.member_updated(jid)` instead of `changed`: the board refills that one slot (no rebuild) and the party window redraws only while shown (a hidden one redraws when it next shows; OURS). The timing claim reworded ("the world's lookups stubbed"): 18.7 us a frame now |
| 6 | gate table was not of the head | rerun on the head `23aa94e1` (the review-fix client), jangan, with no other lane's Godot running and the orphans gone (`--frames 12000 --env 'OPENSRO_QA_VIDEO_STEPS=quality=0\|quality=1'`, median of 3): frame 1.47 -> 1.47 ms SAME, entry 9505 -> 9515 ms SAME, freeze 3289 -> 3303 ms SAME, hitches 4 -> 4 SAME. (A first attempt without `--frames` collected too few fps samples and printed "missing numbers"; not a result.) |
| 7 | slots paired by position | `tick` looks each slot's member up by its own JID (`0x6d7f40` -> `0x992260`) |
| 8 | the miss cache changed `_party_body`'s answers | `_party_body` is exact again; the board has its own `_party_body_for_board` with the id and miss tables, cleared when the party is left |
| 9 | lock label | READ (`0x6db2ab`, `0x6db325..0x6db33c`) |
| 10 | caution period evidence | the addresses added to the INFERRED note (code header and the table above) |
| 11 | Ctrl+n on an unspawned member | noted in `party_gui.md` §7: retail sends `0x7045` with id 0 there; OpenSRO's selection is local, so nothing is sent |
| frames | Dex's leftover selection in frame 525 | said in the run's notes above |
