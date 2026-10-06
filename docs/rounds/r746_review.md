# Review of round 746 (EquipFx own simulation, whole-weapon budget, characterdata and skilldata from their indexes)

Independent adversarial review. Branch `worktree-agent-abc8157a0b452cb25`, head `610b3f0f`, diff
against dev `76d8b456`. Reviewed in a detached worktree. Godot ran only on the render box
(`RENDER_DIR=/opt/opensro-client-r746rev`, own lock `/var/tmp/r746rev/lock`; the perf gate on the
shared lock with the box quiet). Labels as in the rounds: **READ** (decompile or disassembly,
address given), **MEASURED** (the retail archives on the box), **INFERRED** (from code, not run).

## Verdict

**Ship characterdata, the EquipFx changes and the effect/audio skill tables. Do not ship the skill
board's switch to `skilldata.txt` as it is** (finding 1): it is the one change here that moves the
client away from retail, on a screen players use. It is a one-line revert
(`hud_panels.gd` back to `tables_for_race(race)`), which also removes finding 3's stall.

- **characterdata (MEASURED):** every reader the world runs, diffed old list against the index for
  every key. **0 changed winners and 0 lost keys** for NPC models, codes, names, models by code, Org
  codes, speeds, Country, DecayTime, BCRadius, name keys and the effective monster model (own or
  Org). The bodies' catalogue is identical (52 = 52). Only additions: 4,576 models. Retail reads
  the same index (READ, `Client_LoadAllRefData` 0x844cd0 builds `%stextdata\characterdata.txt`).
- **skilldata for effects and audio (MEASURED):** 0 changed and 0 lost rows; 5,002 ids added.
- **skilldata for the skill board:** retail does NOT read `skilldata.txt`. It reads
  `skilldataenc.txt` (READ, 0x844cd0, the same dispatcher), whose ENC parts differ from the plain
  twins. Against the decrypted ENC set, the old board cover matched retail on every player-mastery
  row; the new one does not (finding 1).

## Gates

- `remote_godot.sh check`: `checked 656 scripts and 9 scenes` / `ALL LOAD` (655 of the round's, plus
  this review's own uncommitted probe).
- `remote_godot.sh tests`: **`ran 249 suite(s), 0 failing`**.
- `perf_gate.sh --base 76d8b456 --head 610b3f0f --sites jangan --frames 40000`: **SAME on all four numbers**. Frame 1.48 → 1.48 ms; entry 9,698 → 9,133 ms; freeze 3,361 → 2,866 ms; hitches 5 → 4 (table at the end).

## Findings, most severe first

### 1. DEPARTURE (play-visible): the China skill board gains two skills retail does not have, and one skill's mastery requirement drops from 110 to 10

**Where:** `client/scripts/ui/hud/hud_panels.gd` l. 5036 (`SkillDataReader.tables_for_race(race,
archive)`); `client/scripts/npc/skill_data_reader.gd` l. 61-77 (`INDEX := "skilldata.txt"`,
`index_tables`, `tables_for_race`); the claim in `docs/rounds/r746.md` ("the client loads the parts
its index `textdata\skilldata.txt` names") and the header comment at l. 53-60.

**Evidence:**

- **Which list retail loads (READ):** `UI_ALCHEMYBOX::Client_LoadAllRefData` 0x844cd0 calls the
  loader on `"%stextdata\\skilldataenc.txt"`. It never names `skilldata.txt`. This was already
  recorded in `docs/protocol/magic_state_board.md` ("The files retail loads") and in
  `skill_buff_catalog.gd`'s header.
- **The ENC set, decrypted (MEASURED):** the 47 `skilldata_<n>enc.txt` parts were extracted from the
  box's Media.pk2 and decrypted with the scheme in `magic_state_board.md` (0x4f5140,
  `byte += T2[k % 0xa7] - T1[k % 0x1ef]`, k = 0x8c1f + offset, the key tables read from the box's
  own `sro_client.exe` at 0xeae758 / 0xeae948; nothing copied into the repo). The first rows decode
  (`1  1  172  SKILL_PUNCH_01 ...`). 33,632 ids.
- **Round 746's rows (`skilldata.txt`'s 47 plain parts, last row wins) against retail:**
  - **66 ids retail lacks.** Two are China mastery rows the board now shows:
    `35004 SKILL_CH_WATER_BATTLEA_OVERHEAL_A_01` and `35005 SKILL_CH_WATER_BATTLEA_OVERHEAL_B_01`
    (mastery 276, row 7, bases 1076 and 1077). Their name keys are a Europe cleric's
    (`SN_SKILL_EU_CLERIC_BATTLEA_OVERHEAL_A/B`, the box's `skills.csv`), so they are leftovers in
    the plain twin of `skilldata_36000`, which is 2,800 bytes larger than its ENC file. The other 64
    are Europe levels the old Europe cover already read (not this round's change).
  - **One player row differs from retail:** `36791 SKILL_CH_LIGHT_SAINTA_ABNORMAL_A_01`,
    column 36 (required mastery level): ENC 110 in both `35000ENC` and `37000ENC`; plain
    `skilldata_35000` 110, plain `skilldata_37000` **10**. Last-wins takes 37000's 10.
  - The old cover (10 plain parts, last wins): **0** player-mastery rows differ from ENC.
  - First-wins over the 47 plain parts (SkillBuffCatalog's rule) is worse for the board: 16 player
    rows differ (11971-11978, 11986, ...).
- **The board itself (MEASURED, this review's probe running `SkillDataReader.parse_skills` over the
  old and the new parts):**
  - China, per base: 258 → 260, 1 changed: base 2014 `min_req_mastery_level` and `level_reqs`
    `[110]` → `[10]`.
  - China, layout: row `276:7` `[306]` → `[306, 1076, 1077]`.
  - Europe: 0 changed.
- So the "35005 appears" result in r746.md is real for the plain files but is not retail. Retail's
  China Force board has one skill in row 7, and Saint (Light) ABNORMAL_A unlocks at Lightning 110.

**Effect in play:** a China player sees two extra skill cells in the Force board's row 7 (a Europe
cleric skill's name). They also see `SAINTA_ABNORMAL_A` lit at mastery 10. The server's `skills.csv`
is exported from the same plain index and carries the same three rows (MEASURED: `35004`, `35005`
and `36791 ... 274,10` in `/opt/sro-files/client/skills.csv`), so a learn would be accepted. That is
a pre-existing server departure (finding 8). The client used to hide it, and now shows it.

**Fix:**
- Revert the board to the legacy cover: `hud_panels.gd` calls `tables_for_race(race)` without the
  archive. It matched ENC on every player-mastery row, and it is the 167 ms parse, not 474 ms.
- Keep `all_tables(media)` for SkillEffects and SkillAudio. Over their columns the index changed
  nothing and only added ids.
- Correct the comments and r746.md: retail's list is `skilldataenc.txt`, and the plain index is a
  superset with 66 non-retail ids and one disagreeing duplicate.
- An exact fix needs the ENC rows (the key tables live in the player's own `sro_client.exe`): OPEN.

### 2. PERF (minor, boot): the characterdata boot task reads 63 parts for data the old 7 already held

**Where:** `client/scripts/npc/char_tables.gd` `read_boot` (l. 168); `World3D._load_character_assets`.

**Evidence:**
- **The data has not changed (MEASURED, probe):** speeds 52 → 52, Country 52 → 52, the bodies'
  catalogue 52 → 52, 0 changed.
- The boot task reads 25.3 MB, decodes each part three times (two readers and
  `CharCatalog.from_tables`), and the world waits about 0.7 s for it on the main thread. That is
  most of the table step's growth from 1,024 to 1,593 ms (this review's logs: 1,594 and 1,606 ms;
  boot waits of 712 and 700 ms).
- The world entry is still shorter overall (the gate, and below), because the NPC and monster
  readers left the main thread.

**Small CPUs, checked (MEASURED):** Godot 4.2 is suspected of running low-priority tasks
(everything here is `add_task(..., false)`) on only 30 % of the pool. So base and head were booted
at Jangan with `threading/worker_pool/max_threads=4` (`override.cfg`; confirmed applied: the
project reads `max_threads=4`).

| | base run 1 | base run 2 | head run 1 | head run 2 |
|---|---|---|---|---|
| entry (region grid) | 9,449 ms | 9,460 ms | 9,035 ms | 9,055 ms |
| freeze | 3,362 ms | 3,360 ms | 2,882 ms | 2,870 ms |
| tables step | 1,010 ms | 1,015 ms | 1,594 ms | 1,606 ms |

No queueing showed: the boot task still overlapped the item preload, and the entry task was done
before the NPC loader asked (0 us waiting). In this Godot,
`threading/worker_pool/use_system_threads_for_low_priority_tasks` is `true` (read from the same
run), so a low-priority task gets its own system thread. The worry does not apply.

**Fix (optional):**
- Start `CharTables.preload_async` from the select screen, where `ItemTableReader` already loads in
  a real login. The gate boots World3D directly and never shows that path.
- Or decode each part once and filter `CHAR_` rows before splitting.

### 3. PERF (a visible stall): the skill board's first parse grows 167 → 474 ms (China) / 198 → 507 ms (Europe) on the main thread

**Where:** `client/scripts/ui/hud/hud_panels.gd` `_load_skill_catalog_for` (l. 5025-5040).

**When it happens (READ, the call sites):**
- With a skill on the saved hotbar: inside `World3D._ready` → `_try_initialize_pk2_ui` (l. 1981) →
  `_restore_hotbar` (l. 2408) → `skill_icon_path` → `_board_skill_with_level_id`. This lengthens the
  boot behind the loading screen by about 0.3 s. It is not felt in play.
- Without one: the **first skill cast** (`skill_reach`, World3D l. 9784/10077/10515), a 0.47 s
  freeze in combat. Or the **first K** (`_fill_skill_masteries`), a 0.47 s freeze before the window
  shows. Above 100 ms this counts as a hitch by the gate's own threshold.
- The QA boot never reaches it (the `s746` log has no `HudPanels: skill catalog` line), so no gate
  measures it.

**Fix:**
- Finding 1's revert brings it back to 167 ms.
- Beyond that, parse the board on a worker at world entry (the race is known there,
  `last_enter_world_result.gender`) and let the first use wait, as `SkillEffects.warm_async` does.
- Or build it on the SkillBuffCatalog task, which already holds the 47 shards' bytes (read in 18 ms).

### 4. VISUAL (pop): no hysteresis when the own simulation moves to another weapon; a fresh one starts empty, a resumed one shows stale particles

**Where:** `client/scripts/assets/equip_fx.gd` `_finish_cycle`, l. 607-633 (the own set by strict
distance order, re-chosen every `RESELECT_FRAMES` = 10 frames); `_own_holder` l. 255.

**Evidence (INFERRED, from the code; not rendered):**
- A host entering the own set gets a new `EfpEffect.create`, which starts with no particles, while
  its shared holder (steady state) hides at once. So the effect visibly empties and rebuilds.
- A host leaving the set flips at once to the shared holder: the world-axis sparks snap to the
  bone's axes.
- A paused own effect that resumes keeps the world-space particles it had when paused. On its first
  `_place()` they are re-anchored only if the weapon moved past `ANCHOR_RECENTRE`/`ANCHOR_JUMP`, so
  they show for a moment where the weapon was.
- With the camera following a player who carries a world-axis weapon, the own weapon is the
  player's and never changes: no pop. The case that pops is a player **without** one, in a crowd of
  Nova or seal weapons. Two such weapons at near-equal distance can trade the own slot every 10
  frames.

**Fix:**
- Prefer the player's own weapon outright, and otherwise keep the current own weapon until another
  is nearer by a margin (for example 20 %).
- On a switch, start the new own effect with a short pre-roll (step it a second's worth) or cross
  over only when it has particles.
- Clear a resumed own effect's particles (or `sim.shift` to the new placement) before showing it.

### 5. MINOR (memory): an own effect is never freed while its weapon lives

**Where:** `equip_fx.gd` l. 631-633 and 647-651: leaving the own set only hides and pauses
`h.own_fx`. It is freed only in `_drop` (l. 243).

**Evidence (INFERRED):** each weapon that has ever been the nearest keeps a paused `EfpEffect`, with
its simulation, MultiMesh and pipes, for as long as it is equipped. In a town where the nearest
weapon keeps changing (finding 4's case), this grows with the number of weapons that have been
nearest. It is bounded by the hosts, so it is not unbounded.

**Fix:** free `own_fx` when it leaves the own set (or after it has been out for N cycles).

### 6. MINOR (perf): a kind whose every shown host runs on its own still steps its shared master

**Where:** `equip_fx.gd` l. 601: `k.active += 1` counts own hosts too, so a master with only own
hosts never pauses.

**Evidence (INFERRED):** the player alone with a Nova spear simulates nova_01 and nova_02 twice:
the own effects, and masters that nobody draws. The Jangan gate with the player's own Nova spear
reads SAME (1.54 → 1.54), so this is small at 650 fps. In r746.md's 45 fps crowd, each step costs
script time.

**Fix:** count `k.active` only for hosts drawn through the master (after the own decision).

### 7. MINOR (by-name fallback changes for two names; one duplicate code depends on an unread rule)

**Evidence (MEASURED, probe):**
- `models_by_name` (the monster fallback by display name, used only when a code resolves to
  nothing): 2 winners change:
  - `"large gate phase i"`: `Bldg\guild\ht\big_gate_ht.bsr` → `Dun\Property\wreck\event\wreck_event_break.bsr`;
  - `"0"`: a junk key.
- Over the new parts, 33 names disagree between their first and last definition (the guard towers,
  `wolf cub` → the white wolf, `stone ghost` → `TombStoneGhost`). None reaches a code-keyed lookup.
- Among code-keyed readers exactly one key disagrees between parts: `NPC_SOSUN` (61183),
  `Char\China\chinaman_spidey.bsr` first, `npc\sd\sd_m_area_merchant.bsr` last. It is new in this
  round. Retail's duplicate rule for characterdata is not READ (the server's exporter keeps the last).

**Fix:** none needed now. If the by-name fallback is ever reached for siege objects, key it by code.
Note `NPC_SOSUN` in characterdata.md as the one id where the rule matters.

### 8. WRONG-LABEL (server claim: true for the order, but the order is not retail's for skills)

**Where:** `docs/rounds/r746.md` "The server".

**Evidence (READ, `server/cmd/export-refdata/main.go` l. 558-596 and `deploy/README.md` l. 204-232):**
- **Confirmed:** the exporter takes the parts in `itemdata.txt`/`skilldata.txt`/`characterdata.txt`
  order (`order()`) and keeps the last occurrence. It has no hard-coded part list.
- **But** for skills that list is the plain index, so the server's `skills.csv` holds the 66 ids
  retail lacks and `36791`'s requirement of 10 (MEASURED in the box's `skills.csv`). This was a
  server departure before this round. Round 746 makes the client agree with it instead of with retail.

**Fix:** say so in r746.md. The server-side correction belongs with finding 1's OPEN. Export from
the decrypted ENC rows on a machine that has the player's `sro_client.exe`, or drop the 66 ids and
take 37000's duplicate from 35000.

### 9. MINOR (shutdown): the skill table tasks are not waited for at `_exit_tree`

**Where:** `World3D._exit_tree` l. 6178-6181 waits for `ItemTableReader` and `CharTables`, but
`SkillAudio.warm_async`/`SkillEffects.warm_async` (l. 1693/1698) are waited for only by their first
use.

**Evidence (INFERRED):** a world left (or the game quit) within about 0.6 s of `_ready` leaves those
two workers running script code during teardown. That is the case the previous review's finding 5
fixed for the item preload.

**Fix:** call `SkillAudio.warm()` and `SkillEffects.warm()` (they wait) in `_exit_tree`, or give each
a `wait_pending`.

## Checked and found sound

- **Thread safety:**
  - `Pk2Reader.read_file` and `read_dir` hold the reader's own Mutex (pk2_reader.gd l. 83-93), so
    the CharTables workers, the item preload and the main thread share `_media_pk2` safely.
  - `AudioBank._archive` and `read_table` lock and use their own handle.
  - `ParseProfile.add` locks.
  - `NativeAssets.table_rows` makes a fresh `SrNativeTables` per call (thread-safe by its contract).
  - The worker results are written into per-task boxes and adopted only on the main thread after
    `wait_for_task_completion`.
  - `SkillEffects._warm_now` sets `_loaded` first on the worker. Every main-thread reader goes
    through `warm()`, which waits for the task first (`rows_for`, `paths_for`, `start_cast`,
    `SkillAudio.context_for`/`sounds_for`/`effect_rows`). `reset()` waits too.
- **Adoption order:** `_bc_radius_by_code` and `_monster_decay_ms_by_code` are adopted
  - by `_load_npc_tables`, which runs in the region grid before any NPC is placed;
  - by `_monster_model_path`;
  - at the latest when the loading drain ends.

  The player's blob re-registers while its radius is 0 (`_update_blob_shadow`). The live log shows
  adoption with `0 us waiting`.
- **Mirrored views, portrait, select screen:**
  - EquipFx keeps one driver per viewport, so the portrait and the select screen each get their own
    `OWN_BUDGET`.
  - The select screen's particle fade (`charselect_stage._fade_particles`) finds own effects too:
    they carry `EquipGlow.FX_META` and stay children of the weapon skeleton.
  - An own effect's anchor keeps the host's handedness (`EfpEffect.scale_basis`), as every skill
    effect does. This is unchanged.
- **The budget** (`_finish_cycle`): never more than 64 holders, whole weapons only. The test covers
  80 × 2.
- **Finding 3 of r741 (group names through item codes):** the rebuild runs when new codes arrive.
  The archive result is unchanged (the round's 480/480).

## Performance

`perf_gate.sh --base 76d8b456 --head 610b3f0f --sites jangan --frames 40000`. The box was quiet
(one base run another lane overlapped was repeated by the gate). 1280×720, Forward+ on the RX 7600,
native readers OFF, median of 3:

| Site | frame ms | entry ms | freeze ms | hitches |
|---|---|---|---|---|
| jangan | 1.48 → 1.48 SAME | 9698 → 9133 SAME | 3361 → 2866 SAME | 5 → 4 SAME |

Runs: base 1.48/1.49/1.48 ms, 9702/9593/9698 ms, 3361/3361/3412 ms; head 1.47/1.49/1.48 ms,
9101/9155/9133 ms, 2864/2866/2899 ms.

Neither this gate nor the 4-thread runs reach the skill board's parse (finding 3) or EquipFx's
own-switch (finding 4). The round's own crowd figures (+1.4 / +2.0 ms with 200 seal spears, and
`OWN_BUDGET` 0 against 1) were not re-run here.

## Method (for a re-run)

- **Old-vs-new resolution:** a headless probe on the box (not committed) folds every reader
  (`NpcTableReader.parse_models/codes/models_by_code/org_codes/names/models_by_name/speeds/
  country/decay/bc_radius/name_keys`, `CharCatalog.from_tables`, `SkillAudio.parse_skills`,
  `SkillEffects.parse_timings`, `SkillDataReader.parse_skills` per race) over
  `NpcTableReader.LEGACY_MODEL_TABLE_PATHS` / `SkillDataReader.LEGACY_*` and over
  `CharTables.table_paths` / `SkillDataReader.index_tables`. It prints added, lost and changed keys,
  and, per key, whether its first and last part disagree.
- **Retail's skill rows:** `pk2list -extract` of the 47 `skilldata_<n>enc.txt`, decrypted in Python
  with the tables read from `/opt/sro-files/client/sro_client.exe` at runtime. The rows were compared
  column by column with the plain parts under last-wins, first-wins and the old cover. The
  extracted files were deleted after.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>
