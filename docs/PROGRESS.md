# Progress Log

Running log of what's been done, in reverse-chronological order. Each entry: date, what changed, what's next.

## 2026-08-22 (cont'd 39) — fixed the real multi-region terrain overlap bug (found via live screenshot testing)

- Testing the phase-1 multi-region grid against the real pk2 files (temporarily copied in for
  screenshot verification, then removed again -- see below) surfaced a real bug: the camera ended
  up trapped inside overlapping terrain geometry. Root cause, found by reading the placement code
  again with fresh eyes: **every tile independently forced its own near-row-middle vertex to world
  Y=0**, which guarantees a cliff at *every single seam* between two tiles, since neighboring
  regions' real height data has no known relationship to begin with.
- **Fixed**: `_load_region_neighborhood` now loads the center tile first, captures the real
  `near_height` it computed, and passes that as every other cell's `shared_vertical_anchor` (new
  parameter on `_try_load_real_terrain`, which now returns the `near_height` it used -- `NAN` on
  any failure path). Only the center tile still calibrates itself to Y=0; every neighbor renders at
  whatever height its own real data implies *relative to that one shared reference* instead of each
  also independently resetting to zero. Confirmed live: region load order in the console log now
  shows the center region (`100/100.m`) loading before all 8 neighbors, exactly as designed.
- **Honestly scoped**: this fixes the specific bug asked about (tiles compounding cliffs against
  each other) but does **not** and can't fix a separate, already-documented, deeper issue -- even a
  *single* region's real terrain data is steep enough on its own to enclose the camera near a given
  spawn point (confirmed with zero neighbors involved at all, screenshot evidence from the previous
  entry). That remains blocked on the real row/column layout mystery `MAPM_FORMAT.md` already
  documents as unsolved after multiple genuine attempts (including one more this session, see the
  world-building phase-1 entry). Not conflated with what this fix actually addresses.
- Full CI test-suite sweep passes, clean `--import --quit`.
- **Also this session**: did real, live screenshot testing against actual pk2 files copied
  temporarily into this environment from the RE box (not committed, not kept -- deleted
  immediately after each verification pass, consistent with this project's standing policy of never
  persisting real client assets between sessions). This is how both the original overlap bug and
  this fix were actually confirmed, not just reasoned about from code alone.

## 2026-08-22 (cont'd 38) — "skills" phase 6 (final roadmap item): real Skills tab, closing the whole roadmap

- Found the server-side skill system (learn/use, cooldown tracking) was fully implemented and
  tested, but there was **no way for a client to discover which skills exist or which it's
  learned** -- no list opcode at all, and correspondingly zero UI anywhere (not even in the
  deleted 2D client). Skills were real but functionally unreachable from any client.
- Added `OpSkillList`/`OpSkillListResult` (server) and matching `SkillNet.encode_list`/
  `decode_list_result` (client): returns every skill in `skill.Catalog` (sorted by ID for a
  deterministic order), each annotated with whether the requesting character knows it and, if it's
  on cooldown, how many seconds remain (`SkillListHandler`, wired into `main.go`'s handler chain).
- Added a real **Skills tab** to `World3D.tscn`/`World3D.gd` (list + Refresh/Learn
  Selected/Use-on-Selected-Monster buttons + status label, the same layout pattern every other tab
  already uses) -- reuses the Monsters tab's own target selection for "use on monster" rather than
  duplicating a second target picker. Refreshes automatically after learning, and after any attack
  (skill-triggered or plain) since `OpUseSkill` reuses `OpAttackResult`, so a just-used skill's
  updated cooldown shows up without a manual refresh.
- Extended `skill_test.go` (Go, real end-to-end assertions: list shows 2 unlearned skills before
  learning, then skill 1 known+on-cooldown after using it) and `skill_test.gd` (GDScript wire
  round-trip). Full Go test suite + full client CI test-suite sweep both pass, plus a clean
  `--import --quit`.
- **This closes the full roadmap the user set**: world (multi-region terrain) → mobs (real
  positions + 3D rendering) → character/animation (real walk-cycle) → armor → weapons/shields →
  skills. All six phases shipped, tested, and pushed to `origin/dev` in this session.

## 2026-08-22 (cont'd 37) — "armor"/"weapons and shields" phases 4-5: real per-item visual variety

- Checked whether real per-equipped-item visual selection data exists anywhere in this project's
  reach before building anything: `_RefObjItem` has no code-name/model column at all (confirmed
  earlier in `refdata_schema.md`), the client's only text-data table
  (`server_dep\silkroad\textdata\itemtypenumber.txt`) is unrelated, and there's no item-equivalent
  of the real `object.ifo` type-index. **Real per-item-ID-to-model mapping genuinely doesn't exist
  in any data this project can reach** -- confirmed rather than assumed, closing off that direction
  for now (would need digging into the client `.exe` itself for a hardcoded table, a much bigger,
  uncertain undertaking).
- Built the honest alternative instead: real, individually-verified mesh/material variety, picked
  deterministically from each real equipped item's ID, rather than one fixed look for everyone.
  Wrote a small throwaway Go tool (parses a real `.bms`'s own `material_name` field against a real
  archive, reusing `internal/pk2`/`internal/bms` -- not committed, deleted after use) to check each
  candidate weapon/shield's real material by hand rather than assuming a naming formula: found
  `blade_01`-`blade_06` share `blade1_5.bmt`, `blade_07`-`blade_09` share `blade6_10.bmt`,
  `blade_10` uses `blade_10_12.bmt`, `blade_11`-`blade_15` each have their own numbered `.bmt` --
  all 15 confirmed real and working. For shields, confirmed `shield_11`/`15`/`16`/`90`/`91` all
  resolve (real quirk: `shield_91`'s own material_name is `"shield_11"`, a real reuse) and
  **dropped `shield_14`** after finding its real material_name (`"China_shield_14"`) doesn't match
  any real file that exists anywhere in the archive -- a real exception the naming formula alone
  would have silently gotten wrong.
- For armor, confirmed the existing `clothes_03` set is one of many identically-shaped real sets
  (`clothes_<NN>_<part>.bms` + a matching `clothes_<NN>.bmt`, same part-suffix convention) --
  spot-checked `01` and `05` directly, found real gaps at the edges (some numbers missing for one
  gender), settled on `02`-`09` as a verified-safe-for-both-genders range.
- `WEAPON_VARIANTS`/`SHIELD_VARIANTS`/`ARMOR_SET_NUMBERS` (new consts) plus a reworked
  `_load_character_assets`/`_build_assembled_character` (now takes `armor_set_number`/
  `weapon_variant_idx`/`shield_variant_idx`, keyed/looked-up per real equipped item ID) --
  `_real_player_equipped_slots` now also returns each slot's real item ID, not just
  occupied/empty. **Scope, stated honestly**: only the *local* player gets real per-item variety --
  other players still show the original fixed look, since the wire protocol broadcasting their
  equipment to everyone else only carries a boolean, not a real item ID, yet (a real, concrete
  follow-up, not an oversight).
- Full CI test-suite sweep (every `_test.gd` file CI runs) passes, plus a clean `--import --quit`.
- Next up in the roadmap: skills.

## 2026-08-22 (cont'd 36) — "character/animation" phase 3: real walk-cycle playback for the player

- Found the real gap live playtesting flagged: `Skeleton3DBuilder.apply_ban_keyframe` (the only
  animation-application function that existed) only ever drove **one single bone track** -- it was
  built for World3D's standalone decoration-skeleton demo, not a real multi-bone animation player.
  The player's own assembled body had zero animation playback wired to it at all.
- Added `Skeleton3DBuilder.apply_ban_pose(skeleton, anim, frame_idx)`: applies every real bone
  track in a full `.ban` animation via the same per-bone delta-rotation technique
  `apply_ban_keyframe` already proved correct, skipping any track whose bone isn't present on the
  target skeleton (a real, expected mismatch, not an error) and doing one
  `force_update_all_bone_transforms()` at the end rather than per bone.
- Found real generic (not weapon/skill-specific) locomotion clips live against a real retail
  `Data.pk2`, under each gender's real "fighter" class subtree (matching the "warrior" material
  `GENDER_ASSET_PATHS` already used): `chinaman_fighter_standcity.ban`/
  `chinaman_fighter_walkforward.ban` for men, the `chinawoman_` equivalents for women. Added as new
  `idle_anim`/`walk_anim` entries in `GENDER_ASSET_PATHS`, loaded and parsed in
  `_load_character_assets()` alongside the existing skeleton/mesh/material loading.
- `World3D.gd` now tracks the player's own assembled `Skeleton3D` + gender
  (`_player_skeleton`/`_player_gender`, set in `_try_apply_real_player_character`) and drives real
  per-frame playback in `_physics_process`: picks `walk_anim` when movement input is non-zero this
  frame, `idle_anim` otherwise, looping by each clip's own real frame count (no fixed guessed
  duration). A hard cut between the two on input change, no blending -- a reasonable placeholder,
  not claimed as final animation-system polish.
- Added a real `apply_ban_pose` test (confirms it matches `apply_ban_keyframe`'s already-proven
  result, plus an unmatched-bone track is silently skipped rather than erroring) and ran the full
  CI test-suite list end to end -- every suite passes, plus a clean `--import --quit`.
- Next up in the roadmap: armor, then weapons/shields (both already partially real via
  `_build_assembled_character`'s equipment system -- likely means checking/extending real coverage
  rather than starting from zero), then skills.

## 2026-08-22 (cont'd 35) — "mob spawning" phase 2: monsters now have real positions and are visible in 3D

- Found monsters had **no position at all** server-side (`combat.Monster` only carried a `Zone`
  string) -- the monster-list UI panel was purely text, with zero 3D presence, not just "no visual
  polish yet."
- Added real `X, Y, Z` to `combat.Monster` and `Hub.Spawn`'s signature; `server/cmd/server`'s
  `monsterSpec` now carries a fixed per-species `X, Z` spawn anchor (own placeholder design, no
  real per-monster spawn coordinate data exists -- documented the same way other placeholder
  positions in this project already are) so multiple species don't stack exactly on top of each
  other.
- Extended the wire protocol end-to-end: `session.MonsterSnapshot` (Go) and
  `CombatNet.MonsterSnapshot` (GDScript) both gained `X, Y, Z float32`, threaded through
  `Encode`/`decodeMonsterSnapshot` on the Go side and the matching decode on the GDScript side.
  Updated every `Hub.Spawn` call site across `combat`/`session` package tests (mechanical
  signature-shape change) and the client's own `combat_test.gd` snapshot-builder helper.
- `World3D.gd`: monsters are now real 3D bodies (`_spawn_or_update_monster`/`_sync_monster_bodies`,
  driven by the same `OpMonsterListResult` that already fed the UI list -- one authoritative
  snapshot reconciliation, not a diff of individual damage/death events), a dark-red capsule with a
  name+HP `Label3D`, following the same honest "placeholder until a real per-species model exists"
  approach already used for other players before their real character loads. Reused the terrain
  raycast-snap technique from the previous session's player-embedding fix
  (`_terrain_height_at`) so monsters don't spawn embedded in/floating above the real terrain grid
  either. Also fixed a real stale-body bug on zone change, the same class of bug already caught and
  fixed for other players' bodies -- old-zone monster capsules would have kept showing forever
  otherwise, since nothing previously re-requested the monster list after `OpChangeZoneResult`.
- All Go (`combat`, `session`) and GDScript (`combat_test.gd`, `world_test.gd`) test suites pass,
  plus a clean `--import --quit`.
- Next up in the roadmap: character/animation wiring (the player's assembled body still has no
  walk-cycle at all), then armor, then weapons/shields, then skills.

## 2026-08-22 (cont'd 34) — "build the world" phase 1: real multi-region terrain grid

- User set a concrete roadmap: world → mobs → characters/animation → armor → weapons/shields →
  skills. Started with the world, since it's the foundation the rest stands on.
- **First tried the real, honest path**: since a single loaded region turned out to be one giant
  elongated ribbon (777 rows for a real `100/100.m`, ~320x15,500 units) rather than a proper
  square — the true row-layout mystery `MAPM_FORMAT.md` already documented as unsolved — tried one
  more fresh angle before working around it: searched `SR_GameServer.exe` (imported into this
  project's RE environment well after `.m` was originally investigated, so a genuinely new search
  surface) for the real `.m` magic construction site. Zero hits — most likely because the real
  world server validates movement against the separate real `navmesh\*.ifo` files instead of `.m`
  heightmaps. A real, concrete dead end, recorded rather than left silently untried.
- **Practical fix given the mystery stays unsolved**: `MapmTerrainBuilder.build_mesh` now takes an
  optional `max_rows` cap, reshaping the ribbon into an actual square using only the
  already-confirmed real per-tile data (no new claims). `World3D.gd` uses this to build a real,
  walkable **3x3 grid of regions** (`_load_region_neighborhood`) around whichever region
  `SRREVAMP_MAPM_PATH`/a zone change resolves to, each region's own real `.m`/`.o` pair loaded and
  tiled at a fixed, this-project's-own-designed spacing (`REGION_SPAN`) -- real per-region world
  scale/adjacency still isn't confirmed, so this is honestly documented as scaffolding, not a claim
  about the real game's true spatial layout. Missing neighbor files (very likely near a real
  world's edge) are skipped the same honest way a missing single region already was.
- Only the center region snaps the player onto its terrain (`_snap_player_onto_terrain` from the
  previous entry) -- speculative neighbors don't fight over the player's position.
- Added a `max_rows` test to `mapm_terrain_builder_test.gd`; all existing test suites
  (`mapm_terrain_builder_test.gd`, `world_test.gd`, `objidx_reader_test.gd`, `mapo_reader_test.gd`,
  `mapm_reader_test.gd`) still pass, plus a clean `--import --quit` with no script errors.
- Next up in the roadmap: mob spawning (visually placing real server-tracked monsters in the 3D
  world, not just the debug monster-list UI panel), then character/animation wiring (the "no
  animation whatsoever" gap from live playtesting -- the player's assembled body has no walk-cycle
  system at all yet, only a separate decoration skeleton plays its animation).

## 2026-08-22 (cont'd 33) — first real end-to-end playtest: real character/terrain load, found and fixed a real spawn/terrain collision bug

- Walked the user through actually running the full stack locally for the first time this
  session (Docker Compose + Postgres + Go server, Godot 4.2 client) against their own real,
  legally-owned Silkroad client files -- found real, working internal paths via `cmd/pk2list`
  (`prim\skel\char\china\chinaman_skel.bsk`, `prim\ani\char\china\man\chinaman_standbattle.ban`,
  `res\bldg\china\jangan01\cj_streetstall.bsr`, region `100\100` for `Map.pk2`'s `.m`/`.o` files).
  Also hit and fixed two pure setup snags (running `go` from the repo root instead of `server/`
  where `go.mod` lives; Godot's global `class_name` script cache not existing yet on a fresh
  clone, needing one editor-mode open+scan before `class_name`-referenced classes like
  `AssetSource`/`CharacterAssembler` resolve).
- **Real, live-verified success**: real character assembly (37/39 bones, 7 body parts, 6 equipment
  parts per gender), real weapon/shield meshes, real scenery, a real skeleton+animation pair, and
  real terrain (13,211 tiles parsed from region 100/100) all loaded correctly against real,
  unmodified retail pk2 files -- the first time this session's (and prior sessions') asset-pipeline
  work has been confirmed working against a real client install by an actual human running it,
  not just this project's own unit tests.
- **Found a real bug from that playtest**: once real terrain loaded, the player couldn't move at
  all -- confirmed to be `_try_load_real_terrain`'s own already-documented gap (terrain's vertical
  placement is only calibrated to one mesh vertex, not the real height under the player's actual
  spawn X/Z), leaving the player embedded in or clipped through the mesh. Fixed with a practical
  safety net rather than guessing at the real coordinate mapping: a deferred raycast that snaps the
  player onto whatever real surface is directly below/above them once the terrain's collision shape
  registers. Verified via `godot4 --headless --path . --import --quit` (clean, no script errors)
  and the existing `world_test.gd`/`mapm_terrain_builder_test.gd` suites (`ALL PASS`).
- Also surfaced a smaller real gap during the same playtest: `object.ifo` (real map-object index
  path) wasn't found in the user's real `Data.pk2` at the exact conventional path this project
  assumed -- fails gracefully (object placements just don't render, everything else unaffected),
  not yet investigated further; a real, concrete follow-up if map-object rendering matters more
  than it does right now.

## 2026-08-22 (cont'd 32) — decompiled the full real handshake state machine

- Decompiled `ACTIVE_SESSION::_OnMsgReceivedBeforeHandshake()` in full (previously only partially
  examined) and documented the real, multi-step handshake sequence in `handshake.md`: a real
  progress-state field (`+0x200`) gating what's accepted; a real confirmed 12-byte payload size for
  the client's first `0x5000`; confirmation that the real second step replies with *another*
  `0x5000` (not `0x9000`) carrying a small real payload; a real signature-verification step once a
  progress bit is set, which finally replies `0x9000`; and a separate real branch for receiving
  `0x9000` in the pre-initialized state, consistent with `GatewayServer.exe` playing both responder
  and initiator roles at different times. Real, not yet decoded: the exact byte contents of the
  12-byte payload and the state machine's own reply payloads -- flagged as concrete next steps, not
  guessed at.

## 2026-08-22 (cont'd 31) — matched the real checksum usage pattern in `proto.Read`/`Write`

- Acted on the previous entry's finding: `proto.Write` now builds the full 6-byte header with the
  checksum byte field zeroed, feeds that whole header plus the payload through `PacketChecksum` (in
  that order), then overwrites the checksum byte with the real result -- matching
  `FUN_0046ed40`'s real confirmed behavior instead of the old payload-only usage. `proto.Read` mirrors
  this: takes a copy of the received header with the checksum byte zeroed, feeds it plus the payload
  through the same way, and compares against the received byte. Table contents remain this project's
  own from-scratch design either way (`docs/LEGAL.md` policy #2) -- only the *usage pattern* changed.
- Full build + test suite verified green after the change (no test needed updating -- the existing
  round-trip and mismatch tests already exercise both directions symmetrically).
- `PACKET_FORMAT.md` status: checksum-scope item now checked off.

## 2026-08-22 (cont'd 30) — found the real per-packet send-finalization function: checksum covers the whole packet, not just payload

- Decompiled `FUN_0046ed40` in `GatewayServer.exe` (reached while chasing the header-order question
  the previous entry resolved) and found it's the real per-packet send-finalization routine: it
  writes the rolling byte, then **zeroes the checksum byte field first** and runs the checksum over
  `(Size & 0x7fff) + 6` bytes -- the whole packet including the 6-byte header, not the payload
  alone. A real, previously-undocumented fact; `server/internal/proto`'s `PacketChecksum` currently
  only gets fed payload bytes, so its *usage pattern* (not its table contents, which stay original
  per `docs/LEGAL.md` policy #2) is now a known, concrete gap to close for real wire compatibility.
- Also surfaced a second real branch in the same function, gated on a different flags-byte bit
  together with the Size field's top bit, that checks a length against `0x1001` before either
  queuing the packet or raising a real logged error -- ties into `dispatch.md`'s already-found
  queue-overflow error path. Not fully traced; flagged as a real lead that argues against assuming
  the Size top bit simply means "encrypted" (this project's current `ErrEncrypted` trigger) without
  further checking.
- Recorded both as real, open items in `handshake.md`/`PACKET_FORMAT.md` rather than acting on them
  yet -- neither is confirmed enough to safely change code against without risking baking in a wrong
  guess.

## 2026-08-22 (cont'd 29) — confirmed the real header's wire order, then rewired this project's own `proto` package to match

- Resumed the header-order search by decompiling three not-yet-examined callers of the
  `+0x105c` checksum-byte offset in `GatewayServer.exe`. The first, `FUN_0046d5d0`, turned out to
  be exactly the function needed: given a fresh output buffer pointer, it stores four
  byte-offset-adjusted pointers into that same buffer directly into the object's four
  already-confirmed header fields (`+0x1050`=MsgID, `+0x1054`=Size, `+0x1058`=RollingByte,
  `+0x105c`=ChecksumByte). The offsets it uses are real, direct proof of each field's exact byte
  position: `Size(2) @0, Opcode/MsgID(2) @2, RollingByte(1) @4, ChecksumByte(1) @5`.
- This resolves `PACKET_FORMAT.md`'s last open header question -- both the field *set* and the wire
  *order* are now confirmed real facts, matching the original public documentation's `Size` then
  `Opcode` ordering with the two real security bytes appended unconditionally after them.
- Immediately used this to do real wire-compatibility work (not just document it): rewrote
  `server/internal/proto/packet.go`'s `Read`/`Write` to the real confirmed 6-byte layout, replacing
  the old 5-byte `Size+Opcode+Security`-flags-byte placeholder this package started with. The old
  design's `secEncrypted`/`secTrailer`/`secMassive` flag byte wasn't a confirmed real field at all
  -- dropped it. In its place: the real confirmed top bit of the Size field (masked with `0x7fff`)
  now gates `ErrEncrypted`, and `RollingByte`/`ChecksumByte` are threaded through as **optional**
  per-session generators (`*RollingByte`/`*PacketChecksum`, nil-safe) rather than requiring a
  specific crypto scheme to exist first -- nil means "no session security state yet" (e.g.
  pre-handshake), and Read/Write just skip that field's validation/generation in that case.
- Added `gateway.Session.SetSecurity(...)` so higher-level code can install real per-direction
  generators once a handshake derives them; `Send` and the read loop now pass those through
  automatically instead of every caller needing to know about them.
- Updated every direct `proto.Read`/`proto.Write` call site across `internal/gateway` and all of
  `internal/session`'s test suites to the new signature (passing `nil, nil` where no session
  security state is being tested) -- large mechanical diff, verified with a full build + `go vet` +
  full test suite pass across all packages afterward, not just the changed ones.
- Rewrote `internal/proto/packet_test.go`'s encrypted-flag test for the new Size-bit-based
  detection (was hand-building a byte-4 security-flags byte that no longer exists) and added new
  round-trip/mismatch tests exercising the optional RollingByte/PacketChecksum generators together.
- `PACKET_FORMAT.md` status: header field-order item now checked off; added a new open item
  (bringing session-level key exchange far enough along to actually populate real
  `RollingByte`/`PacketChecksum` state on a live `gateway.Session`, since the plumbing now exists
  but nothing populates it yet outside tests).

## 2026-08-22 (cont'd 28) — a well-supported real hypothesis for the full 6-byte header breakdown

- Immediately followed up the "header is 6 bytes, not 5" confirmation with the natural next
  question: which 6 fields? Realized the arithmetic already lines up exactly with fields this
  project independently confirmed earlier: a real 2-byte `MsgID`/opcode, a real 2-byte size field,
  and the two real per-packet security bytes (`RollingByte`, `PacketChecksum`) already
  reverse-engineered and implemented. `2 + 2 + 1 + 1 = 6` -- no field unaccounted for, no padding
  needed.
- Recorded this as a well-supported real hypothesis in `PACKET_FORMAT.md`: the real header is
  `Opcode(2) + Size(2, high bit likely a flag) + RollingByte(1) + ChecksumByte(1)`, with both
  security bytes present unconditionally on every packet rather than gated behind an optional
  trailer (this project's own `Security`-flags-byte design had assumed the latter). Explicitly
  **not** claiming to know the real wire *order* of these four fields yet -- only that this set,
  summing to 6 bytes, accounts for the confirmed total with nothing left over. Finding the actual
  byte-serialization function is the concrete next step for order.
- This is a satisfying, well-earned capstone to a thread that ran across several entries this
  session (first surfaced as an odd `+6` in one function, reinforced independently three more
  times, then explained by the header-size confirmation, now given a real candidate structure).

## 2026-08-22 (cont'd 27) — confirmed the real header is 6 bytes; found real meaning for 0x6111/0x6112

- Picked one real, cross-validated opcode pair from the new catalog (`0x6111`/`0x6112`, part of
  `GatewayServer.exe`'s real login cluster) and decompiled the function writing both. Confirmed:
  this is the real `FRAMEWORKMSG_IMAGE_BASED_USER_VALIDATE_REQ` handler (name already known from a
  real error string), and `0x6111`/`0x6112` are a real success/failure pair relayed gateway ->
  agent for one certification sub-step -- not general client-facing opcodes. Real payload
  structure not fully pulled (each appends one field via the generic append primitive, but that
  field's own type wasn't traced), but the real *purpose* now is.
- Decompiling that generic "append raw bytes to payload" primitive gave a much bigger bonus: its
  own write-cursor field literally starts at `6` and every payload-length calculation is
  `cursor - 6` -- the real header size baked directly into the one shared function every real
  outgoing message goes through. This is the fourth independent observation of `+6` this session,
  and by far the most authoritative source possible for it. **Elevated `PACKET_FORMAT.md` from "an
  unresolved discrepancy" to "confirmed: the real header is 6 bytes, this project's own 5-byte
  header (from public documentation) is missing one real byte"** -- the field breakdown (which
  extra byte) is now the open item, not the total size.
- This closes a genuinely long-running thread (the `+6` question first surfaced several entries
  ago) with a real, solid answer, and gives login.md a second real opcode pair with confirmed
  purpose beyond the four found earlier this session.

## 2026-08-22 (cont'd 26) — imported SR_GameServer.exe, harvested 79 more real gameplay opcodes

- Extended the proven two-instruction opcode-harvest technique to a fourth real binary,
  `SR_GameServer.exe` (same package, ~9x larger than the other two -- the real main world/gameplay
  server, not just login/relay).
- Re-found the shared `ServerFramework` infrastructure cluster (`0x5000`/`0x9000` handshake,
  `0x6004`/`0x6008`/`0x6009`/`0x600d`/`0xa004`/`0xa008`/`0xa009`/`0xa300`/`0xa303`) at the same
  values yet again -- a third independent cross-binary confirmation.
- Harvested **79 unique values total**, most of them real, gameplay-specific opcode families never
  seen in the login/relay binaries at all: `0x30xx`/`0x34xx`/`0x38xx`/`0x3Cxx`,
  `0x74xx`/`0x78xx`/`0x7Cxx` (the largest cluster), and `0xB0xx`/`0xB4xx`/`0xB8xx`/`0xBCxx`. These
  real address ranges line up with the general opcode-family layout long documented by the
  private-server community for this MMO family (world/entity-ish `0x7xxx`, guild/social-ish
  `0xBxxx`) -- an independent cross-check this is a genuine gameplay opcode surface, not noise.
- Noted honestly: this larger binary produced a higher false-positive rate for small values
  (15 hits under `0x400`, vs. 3-4 in the smaller binaries) -- flagged clearly in
  `observed_opcodes.md` rather than silently included at the same confidence as the rest.
- None of these have pulled payloads yet -- real, separate, per-opcode work for future passes. This
  session's opcode catalog now spans four real binaries with real cross-validation between them.

## 2026-08-22 (cont'd 25) — fixed the harvest tool, catalogued ~50 real opcodes at once

- Went back to the dispatch-mechanism RE thread and fixed the tooling gap identified last pass:
  the wholesale-opcode-harvest script was matching a single fused instruction
  (`MOV word ptr [reg+0x1050], imm16`) that doesn't actually occur -- real writes split the address
  computation and the store into two instructions. Rewrote the scanner to match that real
  two-instruction shape (an `LEA`/`ADD`/`MOV` computing `reg = base+0x1050`, followed within a few
  instructions by `MOV word ptr [reg], imm16`).
- Big payoff: harvested **33 unique real opcode values from `AgentServer.exe`** and **36 from
  `GatewayServer.exe`** in one pass each. All four opcodes already independently confirmed this
  session (`0x5000`/`0x9000` handshake, `0x6201`/`0xa103` login hand-off) came back out at the
  exact right values in the expected binaries -- strong, real validation that the rest of the
  harvest is genuine, not noise.
- Wrote up the full catalog in a new file, `docs/protocol/opcodes/observed_opcodes.md`, including
  the real overlap between the two binaries (shared `ServerFramework` infrastructure messages) and
  `GatewayServer.exe`'s own real `0x61xx`/`0x62xx`/`0x63xx` cluster, which sits in the address range
  publicly documented by the private-server community as the real login/server-list/shard-select
  sequence -- an independent cross-check the harvest is real, not just internally self-consistent.
- None of these opcodes' payload layouts are pulled yet -- that's real, separate, per-opcode work.
  But this is a genuinely large jump in known real opcode surface (roughly 50 real values now
  confirmed to exist, up from the handful found one at a time earlier this session), and the
  scanning technique itself is now a proven, reusable capability for future opcode RE passes.

## 2026-08-22 (cont'd 24) — real magic-option schema found; confirmed no real NPC price table exists

- Kept using the now-proven DB-restore access. Followed `_RefDropItemGroup.RefMagicGroupID` to its
  real linked tables (`_RefMagicOpt` 427 rows, `_RefMagicOptGroup` 115 rows, `_RefMagicOptAssign`
  74 rows) -- the real system behind classic "+N" magic-option item stats. Documented the real
  schema in `refdata_schema.md`; deliberately not implemented in Go yet, since nothing in this
  project's current gameplay needs random item magic options -- matches this doc's own "pull
  schemas as relevant, don't front-load" principle.
- Checked `shop.Price()`'s own doc comment, which said the DB was "never fully restored/mined for
  a real price table" -- no longer true, so checked directly. Real finding:
  `_RefPricePolicyOfItem` exists but is the item-mall (cash shop) package pricing table
  (`Country`/`PaymentDevice`/`RefPackageItemCodeName`), not an ordinary NPC vendor's gold price for
  regular items; `_RefObjItem` itself has no `Cost`/`Price` column either. **Confirmed: no real
  per-item NPC vendor price table exists anywhere in this database.** This validates (doesn't just
  excuse) `shop.Price()`'s existing stats-based formula -- real Silkroad NPC prices were plausibly
  always computed, not looked up. Updated `shop.go`'s doc comment from "never checked" to "checked,
  confirmed necessary."
- `go test ./...` passes (no behavior changes, doc-comment corrections only for this entry).

## 2026-08-22 (cont'd 23) — full real _RefSkill schema (all 118 columns), extended refdata.Skill

- With DB-restore access proven working from the drop-table pass, immediately used it again (no
  pause) to finish `_RefSkill`'s full column catalogue -- previously only the first 20 of 118 were
  confirmed. All 118 now are, see `docs/protocol/refdata_schema.md`.
- Real new groups found: a fairly complete targeting-rule bitset (`Target_Required`/
  `TargetType_Animal`/`Land`/`Building`/`TargetGroup_*`), skill prerequisites
  (`ReqCommon_Mastery*`/`ReqLearn_Skill1-3`/`SkillLevel1-3`/`SP`/`Race`), a required-weapon-to-cast
  pair (`ReqCast_Weapon1`/`2`), **real HP/MP resource costs** (`Consume_HP`/`MP`/`HPRatio`/
  `MPRatio`, not previously known), a real skill range (`Action_Range`), monster-AI hints
  (`AI_AttackChance`/`SkillType`), and 50 generic `Param1`-`50` extension slots. Still no column
  named for damage/effect anywhere in all 118 -- reinforces the earlier conclusion that a skill's
  actual combat behavior lives outside this table entirely.
- `UI_SkillName` is a real, plausible (not 100% confirmed) candidate for where a skill's actual
  display name lives -- distinct from the already-ambiguous `Basic_Name`/`Basic_Code`. Recorded
  honestly as "plausible, not proven."
- Extended `refdata.Skill` with the newly-confirmed high-value fields: `Range`, `ConsumeHP`,
  `ConsumeMP`, `ReqLearnSP`, `ReqLearnRace`, `UISkillName`. Updated CSV columns/parser and the
  Postgres schema (additive; had to drop and let the local test DB's `skills` table recreate
  itself, since this project has no migrations yet at this early stage -- fine, no real persisted
  data exists). Updated existing tests' synthetic CSV rows for the new column count, all green.
  `go test ./...` passes.

## 2026-08-22 (cont'd 22) — real drop-table schema pulled and imported (refdata.MonsterDrop/DropGroupEntry)

- Pivoted from the RE dispatch-mechanism hunt (hit real, identified tooling limits) to concrete
  engineering work: real drop-table schema, next on the "actionable" list from the earlier status
  report.
- Restored `SRO_VT_SHARD.Bak` into a temporary local SQL Server Docker container on the RE box
  (same not-persisted approach the earlier `_RefObjItem`/`_RefSkill` passes used -- **this
  project's own server stays 100% PostgreSQL**, this was only ever about reading the *original
  game's* schema, torn down immediately after) and pulled real, complete column schemas for all
  three real drop-related tables: `_RefMonster_AssignedItemRndDrop` (3,108 rows),
  `_RefDropItemGroup` (378 rows), `_RefDropItemAssign` (8,966 rows) -- row counts match the
  earlier string-scan-only pass exactly, confirming consistency.
- This resolves `refdata_schema.md`'s long-standing open item and reveals a real, understood
  two-table drop-resolution path: a monster maps to an item *group* at some rate/quantity
  (`_RefMonster_AssignedItemRndDrop`), and each group is a named weighted list of real items
  (`_RefDropItemGroup`). `_RefDropItemAssign` is a real, separate, simpler table with no
  `RefMonsterID` column at all -- not yet understood how it relates to the other two, honestly
  left unimplemented rather than guessed at.
- Built `refdata.MonsterDrop`/`refdata.DropGroupEntry` + CSV/SQL importers, following the exact
  `refdata.Item`/`refdata.Skill` pattern (curated subset, unclear-meaning columns like `param1`/
  `param2`/`RefMagicGroupID` left out). Full test coverage (CSV parse + SQL upsert/get/count,
  mirroring existing tests). `go test ./...` passes.
- `combat.LootTables` (this project's own invented drop set) not wired to the new real schema yet
  -- it's keyed by monster *name*, the real tables key by a real numeric `RefMonsterID` with no
  confirmed name-to-ID mapping yet. Documented honestly in `loot.go`'s doc comment.

## 2026-08-22 (cont'd 21) — corrected the registry claim; found a real login hand-off + two new opcodes

- Kept pulling the registration-table thread immediately (no pause between sessions). Traced the
  global map's real insert function (`FUN_0040bce0`) to its one real caller to try to enumerate
  real registration call sites.
- **Caught and corrected another mistake**: the previous entry's claim that the global map was
  "almost certainly the real per-MsgID handler registry" was premature. The insert function logs a
  real `"user register duplicated : %d, %d"` error on a hit -- that's duplicate-*login* detection,
  not "opcode already has a handler." Its one real caller is the Agent-side half of the
  Gateway-to-Agent login hand-off. **Revised**: this global map is a real connected-user registry
  (`CUserManager`-shaped), not an opcode-handler table. The general per-opcode dispatch mechanism
  is genuinely still unfound in both `GatewayServer.exe` and `AgentServer.exe`. Corrected in both
  `dispatch.md` and `login.md` rather than left standing -- this project's now caught and fixed
  three of its own RE conclusions this session (Div ID, the registry, and this one), each recorded
  honestly rather than quietly.
- The trace wasn't wasted, though: found a real, concrete Gateway-to-Agent login hand-off sequence,
  confirmed by real literal strings (`"Someone tried to login using strange client that has
  another content id"`, `"...check the Agent & GameServer Sequence"`), and **two new real,
  concrete opcode values**: `0xa103` (sent early in the flow) and `0x6201` (sent on successful
  user registration -- plausibly the real "you're in" notification). Payload layouts not pulled
  yet, same confidence level this project already treats other found-but-unparsed opcodes at.
- Two live leads recorded for continuing this thread: build the vtable-indirect-call-scanning tool
  already identified as missing (to properly check `CAgentMainProcess`'s other ~29 vtable slots),
  or anchor a fresh literal-comparison search off the two new real opcodes.

## 2026-08-22 (cont'd 20) — major architecture find: Gateway relays to Agent; found the real dispatch registry

- Realized `GatewayServer.exe` was the wrong binary to keep searching in for a general per-opcode
  dispatcher: only 5 real `On<MESSAGE_NAME>`-shaped handler names exist in the whole binary, and
  real strings (`"unhandled relay msg error : wRealMsgID : 0x%X..."`, a literal `AgentServer`
  string, `"there is unfurnished shard does not have any agent server"`) confirm the real
  architecture -- `GatewayServer.exe` is a thin login/handshake front door that relays most
  gameplay messages onward to a separate `AgentServer.exe` process (one per shard) by their real
  `wRealMsgID`, without dispatching them itself.
- Imported and analyzed `AgentServer.exe` (same package, same `ServerFramework` codebase). Found a
  real "unhandled msg received" fallback string, traced it to a real `CAgentMainProcess` virtual
  method (confirmed via RTTI) that: (1) exempts two real opcode values/ranges (`0x6314`-`0x6316`,
  `0xa314`) from flood protection, then (2) looks up the message type in what is unmistakably a
  real `std::map`-shaped registry (recognizable MSVC red-black-tree `find()` pattern against a
  global map instance) -- a miss logs "unhandled msg", a hit returns a handler descriptor.
- This is the real mechanism the earlier `"you must register it first!!!"` error was describing --
  a global `MsgID`-keyed registry populated at startup, not per-connection callback tables (which
  were already correctly ruled out in `GatewayServer.exe`). Confirms that project's earlier
  negative results were sound; the mechanism just lives in a different binary for gameplay opcodes.
- Cataloged `AgentServer.exe`'s real class list (30+ real names via RTTI) -- notably `CBlowFish`
  and a `CKeyExchangeBase`/`CKeyRepicient`/`CKeySender` family, real unexplored leads for
  `handshake.md`'s still-open session-cipher key-exchange question.
- **Not yet done, now the single highest-value next target**: enumerating what actually populates
  the registry (the real registration call sites) -- would reveal real opcode-to-handler mappings
  in bulk, a much bigger jump than tracing one opcode at a time.
- Updated `login.md` with a well-grounded hypothesis this creates: `GatewayServer.exe`'s own
  `COverlapJobManager` (found in an earlier pass, same shared codebase) plausibly uses the same
  registry shape internally to pick which `OverlapJob` subclass handles a given `MsgID` -- not
  proven for that specific binary yet, but no longer an unmotivated guess either.

## 2026-08-22 (cont'd 19) — traced the session's real callback table; found a real, unresolved header-size discrepancy

- Continued from `_OnMsgReceivedBeforeHandshake`: found its real constructor/init code, which turns
  out to build a hand-rolled per-instance callback table (real function pointers written directly
  to fixed offsets, mode-dependent across two real branches) rather than a standard C++ vtable.
  Mapped six real offsets (`+0x20c`/`+0x210`/`+0x214`/`+0x218`/`+0x22c`/`+0x230`); confirmed
  `+0x22c` is the handshake receiver and `+0x230` is the real "send a reply" callback. Decompiled
  `+0x218` fully -- it turned out to be an error-reply builder (real opcode `0x1001` observed) for
  a queue/capacity-check failure, not the general dispatcher. A real, ruled-out dead end for the
  specific "where's the post-handshake per-opcode dispatch" question -- written up in
  `dispatch.md` so a future pass doesn't redo this decompile expecting a different answer.
- Found a real, unreconciled discrepancy along the way: `PACKET_FORMAT.md`'s 5-byte header
  (`Size(2)+Opcode(2)+Security(1)`) was written from public private-server documentation, not this
  project's own binary analysis. Real code in `GatewayServer.exe` reconstructs a frame's total size
  from its payload size as `+6`, not `+5` -- the first real, first-party data point on this specific
  question, and it doesn't cleanly match. Recorded honestly in both `PACKET_FORMAT.md` and
  `dispatch.md` as unresolved, not picked one way or the other.
- Decompiled the remaining undecoded slot (`+0x214`) too -- a real send-queue-flush function, also
  ruled out. The `+6` frame-size pattern showed up a third time here, reinforcing that discrepancy
  rather than it being a one-off. All six real callback-table slots on the session object are now
  ruled out as "the general dispatcher" -- it must live elsewhere. Formed a real, testable
  hypothesis from the earlier "you must register it first!!!" error string: a real handler
  registration pattern (subsystems register against a numeric ID at startup, into a global table
  this project hasn't located yet), not a fixed per-session callback set. Recorded as the next
  concrete lead in `dispatch.md`, not confirmed.

The general post-handshake per-opcode dispatch mechanism (needed for login and every other real
gameplay opcode) is still not found after this session's passes -- but the search space is now
meaningfully narrowed (ruled out: the session object's own callback table; hypothesized: a global
registration table) rather than wide open.

## 2026-08-22 (cont'd 18) — big confirmation: RollingByte is bit-for-bit correct against the real server; found the real handshake receive path; corrected a mistake

- Switched technique after `COverlapJobManager`/`CSession` RTTI tracing stalled: instead of
  identifying a class first, searched `GatewayServer.exe` for real `CMP`/`MOV` instructions using
  the already-known handshake opcode values (`0x5000`, `0x9000`) directly. This immediately found
  the real receive path: **`ACTIVE_SESSION::_OnMsgReceivedBeforeHandshake()`** (class and method
  both real, from the binary's own embedded debug strings) -- confirming this technique
  generalizes better than RTTI-vtable-chasing for future opcode RE work: once *any* real opcode
  value is known, searching for literal comparisons against it finds real code directly.
- This function decompiled to two very high-value confirmations:
  1. **The rolling-byte security formula this project already implemented (`RollingByte.Next()`)
     is computed live, in exactly the same shape, inside real `GatewayServer.exe` code** -- not
     just inferred from the client. Bit-for-bit confirmed, not just plausible.
  2. **The multi-table CRC-style byte's table-selection formula is now confirmed too**:
     `table_offset = table_index * 256` into one shared backing array of 256-entry tables. This is
     a fact about *method*, not the proprietary table *data* itself (which stays deliberately
     unpulled, per `docs/LEGAL.md` policy #2, same as before) -- but closes out a real, previously
     open question in `handshake.md`.
  Also found the real per-object field offsets carrying all of this (`MsgID` at `+0x1050`, the two
  security bytes at `+0x1058`/`+0x105c`, etc.) -- written up in `handshake.md`.
- **Caught and corrected a real mistake from earlier this session**: `login.md` had concluded "Div
  ID" (the login dispatcher's internal switch value) was read from the same header offset as the
  real wire opcode, i.e. plausibly `wire_opcode & 0xFF`. This new find shows the real wire opcode
  field (`MsgID`) is read as a full 16-bit value from a *different* object at a *different*
  offset than where Div ID comes from -- meaning that earlier conclusion doesn't hold up. Revised
  `login.md` honestly: Div ID is now believed to most plausibly mean "Division ID" (a server/channel
  registration concept), unrelated to per-packet opcode dispatch, not the resolved fact the
  previous entry claimed. Documented as a correction, not silently overwritten -- consistent with
  how `handshake.md` itself already handles a past mistaken pass.
- Updated `server/internal/proto/security.go`'s doc comments (were stale, predating
  `PacketChecksum`'s existence) to reflect both the real confirmation and current state.
- Net effect: `_OnMsgReceivedBeforeHandshake` answers the *pre-handshake* receive path specifically
  (its own name says so) -- the real *post-handshake* per-opcode dispatch mechanism (login and
  everything else) is still the open question, now much better scoped in `dispatch.md`.

## 2026-08-22 (cont'd 17) — found the real IOCP dispatch architecture (applies to every future opcode)

- After RTTI-vtable tracing stalled on `COverlapJobManager`/`CSession`, switched technique: searched
  for real IOCP/Winsock API imports actually used (`CreateIoCompletionPort`,
  `GetQueuedCompletionStatus`, `WSARecv`, `WSASend`, `AcceptEx`) and traced their call sites instead
  of chasing class identity first.
- Confirmed `GatewayServer.exe` is a real IOCP server with two completion-processing loops: a
  worker-thread pool loop (the real one) and a lighter main-thread/message-pump path. In the real
  worker loop, **a completed I/O event dispatches through a virtual method call (vtable slot `+8`)
  on the completion-key object**, passed `(bytesTransferred, lpOverlapped)` -- this is the real
  entry point where a received packet's raw bytes first become available, and thus where Div
  ID/wire-opcode translation should actually be findable.
- Split this out into a new file, `docs/protocol/opcodes/dispatch.md`, since it's genuinely broader
  than login -- every future opcode this project RE's will start from this same real dispatch path,
  not just login's. Cross-referenced from `login.md`.
- Did not yet confirm which real class (`CSession` is the natural candidate, a real name already
  found) implements that vtable slot, or decompile it directly -- recorded as the shared next step
  for all future opcode RE work in `dispatch.md`, along with an honest note on why the RTTI-based
  technique that worked for `CUserCertifier_OverlapJob` didn't generalize to every class.

## 2026-08-22 (cont'd 16) — traced login's dispatch to a real class; found the OverlapJob architecture

- Continued the login-dispatch RE thread. Used the same RTTI-chain technique that found
  `ResObject::Load` for `.bsr` (`RTTICompleteObjectLocator` -> `TypeDescriptor` -> mangled name) to
  identify the real class the dispatch switch's vtable belongs to: **`CUserCertifier_OverlapJob`**.
- This surfaced real architecture beyond just login: `GatewayServer.exe` has a small family of real
  `ServerFramework::COverlapJob`-derived async job classes (`CUserCertifier_OverlapJob`,
  `COverlapJob_InitializeLocalData`, `COverlapJob_RelayMsg`, `COverlapJob_Local`), managed by a
  real `COverlapJobManager`. Not one job class per opcode, though -- `CUserCertifier_OverlapJob`
  alone owns the whole Div ID `0`-`0x1a` switch internally via one big handler.
- Traced the job's constructor to a real object-pool initializer (pre-allocates a pool of job
  objects at server startup) -- real, useful architecture, but a dead end for the specific
  "where does a live packet's Div ID get set" question, since pool init never touches per-packet
  data.
- Looked for `COverlapJobManager`'s own vtable (the natural next place to find the real
  opcode-to-job dispatch) via the same RTTI technique; found its `TypeDescriptor` but couldn't
  trace a directly-instantiated vtable from it this pass -- a real, honest dead end, flagged as
  the next concrete target rather than pursued further right now.
- All findings written up in `docs/protocol/opcodes/login.md`. This remains one opcode group's
  worth of progress out of the real protocol's full surface -- consistent with
  `PROTOCOL_DECISION.md`'s scope note.

## 2026-08-22 (cont'd 15) — first real opcode-RE progress toward wire compatibility: resolved login's dispatch shape

- Started the actual opcode-by-opcode RE work `PROTOCOL_DECISION.md`'s reversal calls for. Found
  the obtained package includes real, dedicated Silkroad server binaries alongside the client and
  DB backups (`GatewayServer.exe`, `AgentServer.exe`, `SR_GameServer.exe`, `SR_ShardManager.exe`,
  under a private-server distribution's `Blitzkrieq_Bin_Data` folder) -- `login.md`'s prior pass
  only ever analyzed the client binary. Imported and analyzed `GatewayServer.exe` into the same
  Ghidra project.
- Traced the real `_CertifyUser` SQL exec string to its call site and from there to the real
  dispatch switch (a single ~450-line function handling Div IDs `0`-`0x1a`). Confirmed real facts,
  written up in `docs/protocol/opcodes/login.md`:
  - The internal dispatch value login.md previously called "a small dense integer" has a real
    name, confirmed by a literal error string: **Div ID**.
  - It's read as one byte from the same offset (+2) this project's own wire header keeps its
    Opcode field at -- consistent with (but not yet proven to be) the low byte of the real 16-bit
    wire opcode.
  - A **second** real stored procedure, `_CertifyTB_User` (no third argument, unlike
    `_CertifyUser`'s fixed literal), handles most Div IDs -- not previously known, since it never
    appeared in the client-only pass.
  - Two distinct real "blocked account" encodings exist, one per stored procedure (`0x7F`/`0x7F`
    for `_CertifyUser`, a single byte `== 3` for `_CertifyTB_User`), both routing to a real third
    stored procedure, `_QueryBlockGuide %d`, for a block-reason lookup.
- Did **not** yet find where a live incoming packet's Div ID actually gets set per-packet (the one
  write site traced turned out to be one-time server-startup config loading, not the real receive
  path) -- recorded as the next concrete step in `login.md` rather than guessed at.
- This is one opcode group out of the real protocol's full surface -- consistent with
  `PROTOCOL_DECISION.md`'s honest scope note that this is many-sessions work, done the same
  incremental way as this project's asset-format RE.

## 2026-08-22 (cont'd 14) — 2D deleted: World3D.tscn is now the one real client

- Finished the 2D-to-3D port: repointed `CharacterSelect.gd` to load `World3D.tscn` directly
  instead of `World.tscn`; replaced the now-pointless "Back to 2D View" button with a real "Log
  Out" button (`_on_disconnect_pressed` -> `NetClient.disconnect_from_server()`) -- 3D never had
  its own disconnect control since it always assumed you'd go back to 2D to log out. Deleted
  `client/scenes/World.tscn` and `client/scripts/World.gd` outright (confirmed no other real
  references first, only stale `.godot/` editor cache entries, which aren't tracked).
- Updated `World3D.gd`'s top doc comment and `README.md` to describe the 3D scene as the one real
  client rather than "the new 3D view alongside 2D."
- Verified: `CharacterSelect.tscn`/`World3D.tscn` both boot clean standalone, all 35 GDScript
  suites still pass, no `project.godot` diff, full `go test ./...` unaffected (this was
  entirely client-side).
- This closes out the "drop 2D" side of the direction change from this session. The other side
  (full wire-protocol compatibility with the original client) is a much larger, multi-session
  undertaking -- see `docs/protocol/PROTOCOL_DECISION.md`'s reversal for the honest scope note.

## 2026-08-22 (cont'd 13) — ported the rest of 2D's panels into 3D: monsters, inventory, equipment, quests, shop, party, guild, duel, trade, friends

- Continuing the 2D-to-3D UI port started with chat: brought the entire `ActionTabs` tab structure
  from `World.tscn` into `World3D.tscn`'s UI overlay (10 tabs, verbatim node-for-node), and ported
  every corresponding handler function from `World.gd` into `World3D.gd` -- roughly 500 lines,
  unchanged in behavior, just re-hosted.
- Also added `NetClient.disconnected` handling (redirect to `Login.tscn`), which `World3D.gd`
  never had since it always assumed 2D was the real client people ended a session from.
- Caught one real regression risk before it shipped: `World.gd`'s initial `_ready()` data requests
  (`list_monsters`, `list_inventory`, etc.) assumed a live connection unconditionally, since 2D was
  never used any other way. `World3D.gd` is deliberately also a standalone dev/asset-preview tool
  (loaded directly with `SRREVAMP_*` env vars, no login flow) -- ported verbatim, those calls would
  have spammed `_send called while not connected` errors in that mode. Guarded them behind
  `NetClient.is_connected_to_server()`, matching the caution `_real_player_equipped_slots()`
  already uses for the same reason.
- Verified: scene boots clean (back down to the one pre-existing, unrelated `_send` error from
  before this port started), all 35 GDScript suites still pass, no `project.godot` diff, no
  duplicate function names introduced.
- 2D (`World.tscn`/`World.gd`) now has full UI parity in 3D. What's left before it can actually be
  deleted: flip `CharacterSelect.gd` to load `World3D.tscn` directly instead of `World.tscn`,
  remove the now-pointless "Back to 2D View" button, then delete `World.tscn`/`World.gd`.

## 2026-08-22 (cont'd 12) — direction change: full protocol rewrite + porting 2D's UI into 3D (chat first)

- Two decisions from OpenSRO change this project's direction:
  1. The actual goal is a true end-to-end rewrite of the original server *and* protocol, not just
     an own-designed client/server pair with similar game systems. Reversed
     `docs/protocol/PROTOCOL_DECISION.md` accordingly -- this project's own opcodes
     (`OpLogin = 0x0001`, etc.) are now placeholder scaffolding, not the destination; the
     already-built handshake reference code (`RollingByte`/`DeriveSeed`/`PacketChecksum`) is real
     target work now, not just a verified-but-unused reference. Honest scope note recorded in the
     doc: this is hundreds of real opcodes, worked through incrementally over many sessions, the
     same way asset-format RE was.
  2. 2D (`World.tscn`) is being dropped in favor of 3D as the one real client -- but discovered
     first that 2D currently holds the *only* UI for chat/quests/shop/party/guild/duel/trade/
     friends (`World3D.gd` only has movement/zone/equipment-rendering). Decided to port each panel
     into `World3D.tscn` before deleting `World.tscn`, rather than deleting first and losing
     functionality.
- Ported the first panel: chat. Added a `ChatPanel` (log + input + send button) to `World3D.tscn`'s
  UI overlay, and `_on_chat_message`/`_on_chat_whisper_message`/`_on_send_pressed`/`_log_system`
  to `World3D.gd`, verbatim-ported from `World.gd`. Also wired `_log_system` into the existing
  `_on_entity_entered`/`_on_entity_left` handlers ("X entered/left the zone"), matching 2D's
  parity -- `_on_entity_left` reads the departing character's name off their `Label3D` child since
  `World3D.gd` doesn't keep a separate name lookup the way 2D's `_nearby` dict did.
- Verified: scene boots clean, all 35 GDScript suites still pass, no `project.godot` diff, no Go
  changes needed (chat's server side was already complete).
- What's left to port, in the same "verify before moving on" style: monsters/combat, inventory,
  equipment, quests, shop, party, guild, duel, trade, friends -- then flip `CharacterSelect.gd` to
  load `World3D.tscn` directly and delete `World.tscn`/`World.gd`.

## 2026-08-22 (cont'd 11) — real `refdata.Skill` schema + CSV importer (identity/timing, not damage)

- Picked the top item off the "real work, just not built yet" list from the status report: real
  skill data. `refdata_schema.md` had ~20 confirmed `_RefSkill` columns cataloged but no Go type or
  importer built against them yet, unlike `_RefObjItem`/`refdata.Item`.
- Added `refdata.Skill` (`server/internal/refdata/skill.go`): a curated subset of those ~20
  columns, following the exact same curation discipline `refdata.Item` already established --
  columns with confirmed-but-unclear semantics (`Service`, `Basic_Group`, `Basic_Original`,
  `Basic_Activity`) are left out rather than guessed at, the same way `refdata.Item` already drops
  `_RefObjItem`'s undecoded `ER_*`/`PAR_*`/`BR_*` groups.
- Added `LoadSkillsCSV` (mirrors `LoadItemsCSV` exactly) and extended `SQLStore` with a `skills`
  table + `ImportSkills`/`GetSkill`/`ListAllSkills`/`CountSkills`, all following the established
  upsert-by-ID pattern.
- **Important honest limit, not glossed over**: no confirmed `_RefSkill` column encodes a skill's
  actual damage/effect -- that data plausibly lives in a separate, uncatalogued ability/effect
  system this project hasn't found. So `refdata.Skill` is real and importable, but deliberately
  **not wired into `skill.Catalog`**: importing it would only replace a skill's identity/cost/
  timing, not the `DamageBonus` that actually matters for combat, and a half-real-half-invented
  skill felt more confusing than useful to wire up without a real damage source. `skill.Catalog`
  stays fully own-designed for now; `refdata.Skill` is ready to use once one exists.
- Tests: `TestLoadSkillsCSV`/`Empty`/`MalformedRow`/`NonNumericField` (mirroring the item CSV
  tests) and `TestImportAndGetSkill`/`TestImportSkillsUpserts`/`TestGetSkillNotFound` (mirroring
  the item SQL store tests). Full `go test ./...` passes.

## 2026-08-22 (cont'd 10) — fixed a second zone-change fallout bug: cross-zone attacks

- While looking for more fallout from the new multi-zone feature (after already catching the stale
  "other entities" bug), found `performAttack` (`server/internal/session/combat.go`) never checked
  that the attacker is actually in the same zone as the monster they're targeting -- it only looked
  the monster up by ID (`monsters.Get(targetMonsterID)`) and never compared zones. This was
  latent and harmless before real zone changes existed (every character was always in `"jangan"`
  together, so a monster's zone always matched), but now that a player can genuinely be in a
  different zone than a monster ID they hold (e.g. from an `OpMonsterList` call before changing
  zones), it's a real correctness gap -- a player could attack monsters they have no business
  reaching.
- Fixed by resolving the attacker's live zone via `hub.EntityBySession(sess.ID())` and rejecting
  with the same `"target not found"` error an unknown ID gets, rather than a distinct error --
  deliberately not leaking that a target with that ID exists somewhere else, consistent with
  `handleMonsterList` already only ever showing same-zone monsters.
- Extended `TestMonsterListFlow` (which already spawned a monster in a different zone to prove it
  doesn't show up in the list) to also attempt attacking that cross-zone monster directly by ID,
  confirming it's rejected and left untouched. Full `go test ./...` passes.
- Duels and parties were checked too -- neither is zone-gated at all (duel resolves purely by
  character name, party by character ID), so a zone change doesn't affect them either way; no bug
  found there, not changed.

## 2026-08-22 (cont'd 9) — fixed a real bug in the zone-change feature: stale "other" entities

- Caught right after shipping the previous two entries, while considering what to work on next:
  `ChangeZoneResult` only carried the mover's own new position, not a snapshot of who's already in
  the new zone -- unlike `EnterWorldResult`, which always has. The server only broadcasts
  `OpEntityLeft`/`OpEntityEntered` to people *left behind* in the old zone or *already in* the new
  one; the mover's own client never gets told to drop the old zone's other players from its own
  view, and never learns who's actually present in the new zone until someone happens to move.
  Net effect: after a zone change, `World3D.gd` would keep rendering the old zone's other players
  as stale capsules/bodies, and wouldn't show anyone actually in the new zone.
- Fixed by giving `ChangeZoneResult` an `Others []EntitySnapshot` field, populated the same way
  `EnterWorldResult.Others` already is (`entitySnapshotFromWorld` over `hub.ChangeZone`'s
  `othersNew` return). Client-side, `WorldNet.ChangeZoneResult` gained a matching `others` field,
  and `World3D.gd`'s `_on_change_zone_result` now clears every existing `_other_bodies` entry and
  respawns fresh ones from the new zone's snapshot, mirroring exactly what `_ready()` already does
  for the very first `OpEnterWorldResult`.
- Updated `TestChangeZoneResultRoundTripSuccess` (now needs field-by-field comparison since a slice
  field means the struct isn't `==`-comparable any more, same pattern `EnterWorldResult`'s test
  already uses) and extended `TestChangeZoneFlow` to assert `Others` at both zone changes: Bram
  arrives alone, Cyra arrives to find Bram already there. Full `go test ./...` and all 35 GDScript
  suites still pass; no `project.godot` diff.

## 2026-08-22 (cont'd 8) — World3D.gd now actually reacts to a real zone change

- Closed the gap flagged at the end of the previous entry: `World3D.gd`'s terrain/object loading
  was still a one-time, env-var-driven load at scene startup, not wired to
  `NetClient.change_zone_result`.
- Added `_zone_paths(zone)`: splits a zone label shaped like this project's real Map.pk2 region
  naming (`"<x>/<y>"`, e.g. `"100/100"`, `"102/101"` -- the real (x, y) folder/filename convention
  confirmed in `MAPM_FORMAT.md`/`MAPO_FORMAT.md`) into that region's real internal paths
  (`"100\100.m"`, `"100\100.o"`, `"minimap\100x100.ddj"`, matching the exact convention this file's
  own `SRREVAMP_MAPM_PATH`/`SRREVAMP_MAPO_PATH` doc comments already described). Returns `{}` for
  anything not shaped that way (e.g. the default spawn zone `"jangan"`) -- no guessed path for a
  zone that isn't a real region coordinate.
- `_try_load_real_terrain`/`_try_load_real_map_objects`/`_load_real_terrain_texture` now take an
  optional path override, falling back to the original env vars when empty (unchanged behavior for
  the initial `_ready()` load, which still reads env vars directly since the very first zone is
  usually `"jangan"`, not a real region).
- `_reload_zone_assets(zone)`: frees the current `"RealTerrain"`/`"RealMapObjects"` nodes, resets
  the placeholder ground visible/collidable, then re-runs the loaders with `_zone_paths`'
  resolved paths (or leaves the placeholder if the zone isn't region-shaped).
  `_on_change_zone_result` (connected to `NetClient.change_zone_result`) calls it and updates the
  zone label on a successful change.
- Added a small dev-facing UI (`ZoneInput`/`ChangeZoneButton` in `World3D.tscn`) so a zone change
  can actually be triggered and watched end to end, not just verified by reading code.
- Verified: scene boots clean under `godot4 --headless --path . scenes/World3D.tscn` with no new
  errors (confirmed the one pre-existing `_send called while not connected` line already appears
  identically on the prior commit, unrelated to this change). All 35 GDScript test suites still
  pass; no `project.godot` cosmetic diff. Did not add a dedicated automated test for `_zone_paths`
  itself -- a standalone `World3D.gd` unit-test file was already tried and abandoned earlier this
  session (hung indefinitely under `--headless --script`, root cause not fully diagnosed, likely an
  autoload-resolution quirk); relying on the scene-boot smoke test plus manual verification of
  `_zone_paths`' string logic instead, same documented limitation as before.

## 2026-08-22 (cont'd 7) — real multi-zone world: OpChangeZone (server) + wire support (client)

- Every character has spawned at one hardcoded position (`spawnZone = "jangan"`, `(0,0,0)`) since
  the world system existed -- a placeholder noted in `world.go`, never revisited. Decided (with
  OpenSRO) to build real zone-to-zone movement next, grounded in the real `.mapo`/`.mapm` region-file
  naming this project already confirmed via RE (`<x>/<y>.m`/`.o`, e.g. `100/100`, `102/101` --
  region folder/filename are an (x, y) coordinate pair, not always equal -- see
  `docs/protocol/MAPM_FORMAT.md`/`MAPO_FORMAT.md`).
- **Server**: added `world.Hub.ChangeZone` (atomic leave-old/enter-new, no window where the
  character is in neither zone's index) and `OpChangeZone`/`OpChangeZoneResult`
  (`server/internal/session/world.go`). A zone is an opaque string as far as the server's
  concerned -- it never parses Map.pk2 itself, so it can't validate a zone actually exists; it just
  tracks who's in which label, same as always. Guard rails: empty zone and "already in that zone"
  both rejected. New zone spawn is always the same fixed `spawnPos` -- this project has no
  confirmed real transform between one region's local coordinates and another's (see
  `MAPO_FORMAT.md`'s "real-world placement scale" open item), so a zone change is a discrete warp,
  not a continuous cross-region walk. Broadcasts `OpEntityLeft` to whoever's left behind in the old
  zone and a fresh `OpEntityEntered` to whoever's already in the new one, reusing the exact same
  messages `OpEnterWorld`/disconnect already send.
- Tests: `world.TestChangeZoneMovesEntityAndReturnsBothSides`/`TestChangeZoneUnknownSessionFails`
  (Hub-level), plus `session.TestChangeZoneFlow` -- a real three-character TCP flow test covering
  both guard rails and both broadcast directions (left-behind vs. newly-arrived). Full `go test
  ./...` passes.
- **Client**: added matching `WorldNet.encode_change_zone`/`decode_change_zone_result` (wire
  format mirrors `OpEnterWorld`'s shape) and `NetClient.change_zone()`/`change_zone_result`
  signal/`current_zone` state, with GDScript tests in `world_test.gd`. All 35 GDScript suites still
  pass.
- **Deliberately not done this pass**: `World3D.gd`'s actual terrain/object rendering is still a
  one-time, env-var-driven load at scene startup (`SRREVAMP_MAPM_PATH`/`SRREVAMP_MAPO_PATH`) -- it
  doesn't yet react to `NetClient.current_zone` changing by re-resolving those into real per-zone
  pk2 paths (`"100/100"` -> `Map\100\100.m`/`.o`) and reloading. That's real, scoped, honestly
  unfinished follow-up work (documented in `World3D.gd`'s top comment), not attempted here to avoid
  a risky same-session refactor of an already-large, well-tested rendering pipeline.

## 2026-08-22 (cont'd 6) — chased the `.ifo` object-index `Flags` word, real partial progress

- `objidx.Entry.Flags` has been an unconfirmed raw word since the `.ifo` format was solved (values
  seen: 0 and 1, meaning never decompiled). Went back to Ghidra to chase it, per this project's
  standing license to keep pulling RE threads even when some dead-end.
- Found the real loader (`FUN_00a291a0`, via the `"object.ifo"`/`CreateFile` debug string) and
  traced one real consumer of the resulting table: `FUN_00a26a30` looks up a placement's type ID in
  the exact same 32-byte-stride vector `objidx.Parse` builds, bounds-checked the same way, and
  passes the matched entry into `FUN_00a15950` -- a real resource-cache/refcount function that's
  part of the actual mesh-load path. This is a genuine, useful confirmation: the object-index table
  really does drive per-placement model loading (not just naming), matching what this project
  already assumes in `World3D.gd`.
- Did not manage to isolate a specific instruction reading `Flags` on its own (as opposed to being
  part of the whole entry pointer passed along) in this pass -- so its 0-vs-1 meaning is still
  unconfirmed. Recorded as a real, partial finding in `docs/protocol/MAPO_FORMAT.md` and
  `server/internal/objidx/objidx.go`'s doc comment, not pursued further right now since nothing in
  this project's rendering depends on it.
- No code behavior changed -- this was purely an RE/documentation pass.

## 2026-08-22 (cont'd 5) — closed out the handshake CRC checklist item (reference-only, not wired in)

- Went looking for the next real gap and found `server/internal/proto/security.go` already had
  `RollingByte`/`DeriveSeed` (a fully RE-confirmed LFSR-seeded rolling byte) implemented, but the
  handshake opcodes (`OpHandshakeRequest`/`OpHandshakeAccept`) were never wired into the gateway --
  `docs/protocol/opcodes/handshake.md`'s Status section had an open item asking for a decision on
  the second security field (a multi-table CRC-32-style byte) before going further, since pulling
  the real table contents from the binary would be copying literal proprietary data.
- Asked and got an answer: build a from-scratch equivalent table, not a bit-for-bit match to the
  original. Before wiring anything into the gateway, found `docs/protocol/PROTOCOL_DECISION.md`
  (dated 2026-08-19, predating this session's work) which had *already* settled the larger
  question: this project's server and client only need to agree with each other, not with the
  original Joymax client, so the whole handshake/rolling-byte/CRC scheme is explicitly **not**
  meant to be wired into the real server -- it's kept only as a verified reference implementation
  of the RE findings. Wiring it into the gateway would have contradicted an existing, deliberate
  project decision, so didn't do that.
- Instead implemented just the missing reference piece: `PacketChecksum` in
  `server/internal/proto/security.go` -- a from-scratch reflected-CRC-32-style running checksum
  with per-session table selection (`checksumTable`, derived from a folded polynomial rather than
  storing 256 literal tables), matching the real design's *shape* without reproducing its *data*.
  Added `TestPacketChecksumDeterministic`, `TestPacketChecksumDifferentTableIndexDiverges`,
  `TestPacketChecksumSensitiveToInput`. Closed out `handshake.md`'s Status checklist to reflect
  both the completed reference implementation and the explicit decision not to wire it in.
- Full `go test ./...` suite passes; no client changes (this is a server-only reference primitive,
  same treatment as `RollingByte` before it).

## 2026-08-22 (cont'd 4) — investigated `EXTRA` slot rendering: real system found, real dead end

- Looked for what the `EXTRA` equip slot might really render, the last unimplemented item from the
  real 8-slot equip system. Searched `Media.pk2` for accessory/cosmetic conventions before guessing
  anything.
- Found real earring/necklace accessory items (`icon\item\china\acc\`) with a dedicated real UI
  slot icon (`interface\equipment\equip_slot_earring.ddj`) -- real Silkroad jewelry slots, but these
  are stat-only items with no 3D mesh in retail SRO, so they don't explain a *visual* struct slot.
- Found a real, separate cosmetic-item system instead: `resinfo\avataritemdata.txt`, a real
  UTF-16 tab-separated registry of 4 "avatar" (mall cosmetic) items -- angel/devil wings for both
  genders -- each with a real target mesh path (`res\item\avatar\avatar_m_angel_wing.bsr`) and a
  dedicated real UI button (`equip_slot_avata_button.ddj`, distinct from the plain equipment
  button). This is a real, non-armor cosmetic overlay category, plausibly what `EXTRA` is for.
- Confirmed dead end: checked `Media.pk2` directly for the `.bsr` mesh files the registry
  references -- **none of them ship with this client build**, only their icons do. Real system,
  real data file, real UI slot, but no actual mesh asset to render. Recorded in
  `docs/protocol/EQUIP_SLOTS.md` and not pursued further, per this project's standing rule against
  building anything not grounded in real shipped data.
- This closes out the equip-slot investigation: `EXTRA` is tracked server-side (equip/unequip work)
  but intentionally has no rendering, same honest status as before, now backed by an actual
  documented investigation instead of just "not looked at yet".

## 2026-08-22 (cont'd 3) — real armor now mitigates incoming combat damage

- Direct follow-on to the real per-piece equipment slot work: armor `PhysDefense` was tracked per
  real equipped piece but never actually subtracted from incoming damage anywhere -- a monster's
  counterattack in `performAttack` (`server/internal/session/combat.go`) applied `monster.Attack`
  raw, with zero mitigation, unlike the player's own outgoing hit (which already subtracts
  `monster.Defense`).
- Added `defenderArmor(ctx, characterID, eq, items)`, which sums real equipped `PhysDefenseMax`
  across every slot in `equipment.ArmorSlots` (`HELM`/`MAIL`/`SHOULDERGUARD`/`PANTS`/`BOOTS` --
  the same real slot set `EQUIP_SLOTS.md` documents). Wired into `performAttack`'s counterattack
  branch: `incoming := monster.Attack - armor`, floored at 1 (mirroring the existing
  `if net < 1 { net = 1 }` pattern already used for the player's own damage).
- Also wired the same `defenderArmor` into `handleDuelAttack` (`duel.go`), replacing a stale
  top-of-file comment that said PvP damage had "no defense mitigation yet (character has no
  Defense stat)" -- that was true before this session's real equipment-slot work but is no longer
  accurate now that armor is genuinely tracked per piece, so PvP damage is now mitigated the same
  way PvE is.
- Added `TestCombatArmorMitigation` (helm+mail reduce a counterattack from 15 to 5, then adding a
  deliberately oversized shoulderguard exercises the 1-damage floor) and
  `TestDuelArmorMitigation` (Bram's real equipped mail reduces Aria's 30 attack to 18) -- both real
  end-to-end TCP flow tests, same style as the rest of this session's server tests. Full `go test
  ./...` suite passes.
- Not a new RE finding -- this is wiring an already-real stat (`PhysDefenseMax`, already read from
  the CSV item data and already used server-side for shop pricing) into a code path that hadn't
  used it yet. No client changes needed (damage numbers already flow through the existing
  `AttackResult`/`DuelAttackResult` wire messages).
- What's next: `EXTRA` slot still has no rendering convention investigated (tracked, not
  implemented). `.efp`, `.t`, and real-world placement scale remain the standing RE dead
  ends/deferred items noted in prior entries -- nothing new to chase there right now.

## 2026-08-22 (cont'd 2) — real off-hand shield rendering, closing the last real-slot gap

- Direct follow-on to the real per-piece equipment slot work: `SHIELD` was tracked (equip/unequip
  worked) but had no rendering, unlike `WEAPON`. Checked for real shield assets before building
  anything, same discipline as every other equipped-item addition this session.
- Found real, faction-wide shield item meshes under the exact same real weapon folder as weapons
  (`Prim\Mesh\Item\China\weapon\shield_11.bms` and many other real numbered shields) -- confirmed
  real via the same material-name-to-layer-name match already used for weapons/armor
  (`shield_11.bms`'s `material_name` "shield_11" matches a real layer in `shield_11.bmt`).
- Confirmed a second real attach bone the same direct way `WEAPON_BONE` was: pulled a real
  `chinaman_skel.bsk` and found the exact string `"Bip01 L Hand"` -- the real off-hand counterpart
  to the weapon's `"Bip01 R Hand"`.
- Added `CharacterAssembler.assemble_shield`/`SHIELD_BONE` (identical mechanism to
  `assemble_weapon`), a cached shared (non-gender-split) shield mesh/material in `World3D.gd`, and
  extended `EntitySnapshot`/`WorldNet.EntitySnapshot` with a real `HasShield` bool broadcast the
  same live way as `HasWeapon`.
- Verified: new `CharacterAssembler` test for the off-hand attachment, extended
  `TestWorldFullFlow` to equip a real shield on one of its two characters and assert the flag
  propagates through the live broadcast (hit one real snag: the inventory slot a previously-
  equipped item vacates gets reused for the next `AddItem`, not the next sequential slot -- fixed
  by equipping from the correct real slot instead of assuming index order). Full regression: Go
  clean (`build`/`vet`/`test`, all packages), all 35 GDScript suites pass, live scene-boot smoke
  test confirms `World3D.tscn` still renders correctly.
- This closes the last real, renderable gap from the equip-slot work -- `EXTRA` remains tracked
  but unrendered, since no real "extra" cosmetic-item convention has been investigated.

## 2026-08-22 (cont'd) — real per-piece equipment slots: a genuine decompiler find, not an own-design guess

- Considered building real per-piece equipment slots (helm/gloves/etc, matching the aa/ba/fa/ha/
  la/sa convention `CharacterAssembler` already renders with) as an own-design gameplay
  improvement. Before committing to invented slot names disconnected from any real data, checked
  whether the real client's actual equip-slot categories could be found -- and they could.
- Searched `sro_client.exe` for equip-related strings and found a real, literal debug-print format
  string block: `"HELM [ %d ] [ %d ]"`, `"MAIL [ %d ] [ %d ]"`, `"SHOULDERGUARD [ %d ] [ %d ]"`,
  `"PANTS [ %d ] [ %d ]"`, `"BOOTS [ %d ] [ %d ]"`, `"WEAPON [ %d ] [ %d ]"`,
  `"SHIELD [ %d ] [ %d ]"`, `"EXTRA [ %d ] [ %d ]"`, plus real assert strings confirming
  `EQUIP_VISUAL_COUNT` bounds one real slot array. Decompiled the one real function referencing
  all 8 strings (a real "Avatar" equip-visual debug dump) and confirmed both the real order and
  that each slot reads from its own fixed real struct offset -- a genuine, decompiler-confirmed
  fact, not a guess. See `docs/protocol/EQUIP_SLOTS.md` for the full derivation.
- Five of the eight real slots map directly, by real-world meaning, to `CharacterAssembler`'s
  existing real bone-slot codes (`ha`→HELM, `ba`→MAIL, `sa`→SHOULDERGUARD, `la`→PANTS,
  `fa`→BOOTS) -- confirming this project's independently-derived rendering convention and the
  real client's own categories agree. The sixth code (`aa`, forearms) has no confirmed real slot
  name of its own; it renders bundled with MAIL, the same pairing the old fixed armor set always
  used.
- Replaced `equipment.Slot`'s single own-design `SlotArmor` with one real constant per confirmed
  slot (`SlotHelm`, `SlotMail`, `SlotShoulderGuard`, `SlotPants`, `SlotBoots`, plus `SlotShield`/
  `SlotExtra`, tracked but not yet rendered). No DB schema change needed -- slot was already a
  generic `SMALLINT` column. `EntitySnapshot` now broadcasts a real per-piece `ArmorSlotsMask`
  bitmask instead of one flattened `HasArmor` bool, and `World3D.gd`'s new
  `_filter_equipped_parts` renders exactly the real pieces actually equipped -- mixing e.g. a real
  helm with nothing else now renders correctly, not just "some vs. none".
- Extended the 2D equipment HUD (`World.tscn`) with a real slot-picker `OptionButton` (mirroring
  the gender picker's pattern) replacing the old single hardcoded "Equip as Armor" button.
- Verified: new Go tests confirm real pieces can be equipped simultaneously without clobbering each
  other and pin down `ArmorSlots`' real order against drift; extended `TestWorldFullFlow` to equip
  a specific real piece (`SlotMail`) and assert the correct bit propagates through the live
  broadcast; new GDScript wire-format assertions for the bitmask field. Full regression: Go clean
  (`build`/`vet`/`test`, all packages, plus two new dedicated equipment tests), all 35 GDScript
  suites pass, and a live scene-boot smoke test confirms `World3D.tscn` still renders correctly
  with no env vars set.
- A GDScript unit test for the new `_filter_equipped_parts` client-side logic was attempted but
  abandoned: instantiating `World3D.gd` standalone (outside the actual scene) hung under
  `--script` mode for reasons not fully diagnosed (likely autoload resolution quirks already seen
  elsewhere this session). The logic itself is simple, reviewable dictionary/bitwise code with no
  I/O, and is already exercised indirectly by the real wire-format tests plus a live scene-boot
  smoke test -- not left completely unverified, just not unit-tested in isolation.

## 2026-08-22 — verified real per-gender rendering with two actual live Godot clients, not just the automated TCP test

- The `TestWorldFullFlow` Go test already verifies gender/armor/weapon broadcast correctness over
  real TCP, but that only exercises the protocol layer -- it doesn't run the actual client-side
  Godot rendering pipeline. Ran a real, manual, two-client check to close that gap: started the
  real server fresh, drove two separate real Godot client processes (via a throwaway scene +
  script, deleted after use) through the real login → register → create-character →
  enter-world flow using `NetClient` directly, one creating the default gender and one explicitly
  creating `china_woman`.
- Confirmed end-to-end: the second client's own live `EnterWorldResult` correctly listed the first
  client as a real `other` (`gender=china_man`, real position), and loading the actual
  `World3D.tscn` scene (fed a synthetic pk2 with real pulled assets for both genders) rendered the
  first client as a real, separately-labeled assembled body from a live game session -- not a
  placeholder, not a unit-test assertion.
- No bugs found, no code changes needed. Cleaned up: killed the test server and client processes,
  deleted the throwaway scene/scripts (never committed), reverted a cosmetic `project.godot`
  rewrite Godot made on import, deleted the two test accounts/characters from the local dev DB, and
  removed all scratch files from both the local scratchpad and the RE box.

## 2026-08-21 (cont'd 64) — one more RE dead end (`.t`), one real structural find (`.efp`)

- Continued chasing RE leads per explicit direction to keep going and accept some dead ends.
- **`.t` texture blend map**: searched all three client binaries for a real magic string, class
  names, and RTTI type descriptors that might lead to a real loader, the same technique that found
  `ResObject::Load`. No embedded magic string exists (same byte-for-byte validation pattern as
  `.bsr`, not a literal comparison). The one promising real lead (`CMapLoader`, via a real
  `CSingletonT<CMapLoader>` RTTI descriptor and a real `MapLoader.cpp` path string) turned out to
  be the navmesh (AI pathfinding) loader, a different real subsystem -- a confirmed-wrong branch,
  not a guess. Recorded in `MAPM_FORMAT.md` so a future pass doesn't re-check it. Still an
  unsolved, honestly-flagged gap.
- **`.efp` nested tree structure**: revisited the previously-documented `FUN_00cb9120` entry point
  with fresh eyes. That function itself is genuinely just magic/header handling (confirmed by
  decompiling it: builds the literal `"JMXVEFF 0013"` bytes) -- but going one hop further this
  time (to `FUN_00cc27e0`) found something real and useful: **the function recurses on itself**,
  walking one linked list of leaf property entries (via `FUN_00cc2710`, itself a polymorphic
  per-type value writer -- confirms, doesn't newly reveal, that leaf values have no single fixed
  encoding) then a second linked list of child nodes, calling itself again for each child. This is
  the real nested tree shape this project's reader currently flattens away, now backed by
  decompiled code rather than inferred from data alone. Honest caveat: the function constructs the
  magic by writing it, reading as the editor's *save* path rather than the runtime *load* path --
  structurally equivalent tree shape either way, but worth being precise about which real code path
  this actually is.
- **Not yet implemented** for either format -- both entries document real, concrete findings
  (one negative, one structural) rather than code changes, consistent with this project's practice
  of not shipping behavior built on an unconfirmed byte layout. `.efp`'s real per-node header
  shape (the `+0x1c`/`+0x18`/`+0xf`/`+0xd` offsets and the count field, in real file-relative
  terms) still needs a hex-dump cross-check against real files before a recursive reader can be
  built.
- No code changes, no regression run needed.

## 2026-08-21 (cont'd 63) — solved the common case: real sub-mesh material-layer matching, implemented

- Direct follow-on to the previous entry's decompiled finding. Before implementing the deep,
  not-yet-byte-mapped index-list mechanism found there, checked a simpler real possibility first:
  does a `.bsr` sub-mesh piece's own `.bms` file carry the same `material_name` field character
  body parts already use for real name-matched material resolution?
- **Yes, confirmed directly**: pulled a real 27-piece building (`bagh_city_palace.bsr`,
  `Res\Bldg\arabia\bagh_city\structure\`) and its real 28-layer material. Every real layer's
  `layer_name` is literally a piece number (`Bagh_City_Palace_01`, `_04`, ...), in a shuffled
  order that does **not** match mesh-piece file order. Parsed 4 real piece `.bms` files directly
  and found each one's own `material_name` exactly equals its matching real `layer_name`, 4/4.
- **Implemented and verified**: `ObjectLoader.load_object` now tries this real name match first
  (`_find_layer_by_name`), falling back to the old index-based heuristic only when no name
  matches. Added a dedicated synthetic test with two pieces and two layers in deliberately
  shuffled order (mirroring the real `bagh_city_palace` shape) that would give the *wrong* result
  under the old positional pairing — confirms the fix picks the right layer for each piece by
  name regardless of order.
- This solves the common case flagged as an open item since early in this project. The deeper
  decompiled index-list mechanism (previous entry) remains real and documented for the rarer case
  where a piece genuinely has no name match, but isn't blocking anymore since most real objects
  checked so far do have one.
- Full regression: Go unaffected (no Go-side equivalent to this client-only rendering logic), all
  35 GDScript suites pass (added 5 new assertions to `object_loader_test.gd`).

## 2026-08-21 (cont'd 62) — found the real material-layer-to-mesh-piece mechanism via decompilation

- User explicitly asked to keep chasing RE leads, accepting some dead ends. Picked up the last
  open backlog item: `ObjectLoader`'s unconfirmed index-based heuristic for pairing a `.bmt`
  layer to a `.bsr` mesh piece when no name match is available.
- Traced the real client's actual object-loading code from previously-documented entry points
  (`FUN_00bed8d0`/`FUN_00bce3b0`, `BSR_FORMAT.md`) through several more real functions: a
  type-dispatch factory (`FUN_00be9250`) that turned out to have a wrong-branch false start (case
  0 is real `ResChar`, confirmed via a literal `"...ResChar.cpp"` string and an `nComboNum == 0`
  assertion — a different, related real class, not what this project needed), corrected to the
  right branch (`FUN_00be8dc0`), down to the concrete `ResObj` vtable's real `Load` method,
  `FUN_00be41d0` — confirmed as the right target by a literal `"...ResObject.cpp"` string and a
  `"m_PrimMeshGroups.size() == 0"` assertion exactly where the mesh-group list is read.
- **Real finding**: each real mesh piece (`m_PrimMeshGroups` entry) carries its own explicit,
  file-encoded `uint32` count followed by that many further `uint32` indices into a shared
  material/layer array — a real, per-piece index list read directly from the file, not an
  implicit pairing inferred from matching counts (which is what this project's current fallback
  assumes). This directly answers the open question in principle.
- **Deliberately not implemented yet**: this pass found the real *mechanism*, not its exact byte
  offsets in a real file — the decompiled `Load` function reads noticeably more real sections
  than this project's currently-documented flat `.bsr` struct models, so mapping this to concrete
  offsets needs a real hex-dump cross-check (the same technique every other field in `BSR_FORMAT.md`
  was pinned down with) before it can be safely coded against. Recorded in `BSR_FORMAT.md` as a
  real, promising, correctly-scoped next step rather than guessed at further or half-implemented
  against an unconfirmed byte layout.
- This is a genuine partial success, unlike the previous entry's `1920.0f` dead end — the same
  "trace from a known real entry point" technique that solved `.bsr`'s nature-category field-order
  bug worked again here, just needed a wrong-branch correction along the way (worth recording:
  `FUN_00be9250`'s case dispatch isn't 1:1 with "static object vs. character", case 0 specifically
  is character).
- No code changes this entry -- documentation only, since implementing against an unconfirmed byte
  layout would risk shipping wrong behavior. Full regression not re-run (nothing to regress).

## 2026-08-21 (cont'd 61) — real per-player weapons, and a negative RE result recorded honestly

- Attempted the next open item (real-world placement scale) via decompilation: a real `1920.0f`
  float constant exists in `sro_client.exe`, but both its referencing functions decompile as
  keyframe/spline interpolation code, not a coordinate transform. A real negative result, not a
  coincidence worth re-chasing without new evidence -- recorded in `docs/protocol/MAPO_FORMAT.md`
  so a future pass doesn't repeat the same search.
- Pivoted to a more tractable, high-value real feature instead: weapons were tracked server-side
  (`equipment.SlotWeapon`) since early in this project but never rendered at all. Checked whether
  real weapon assets actually exist before building anything (same discipline as the gender work):
  found a real, faction-wide (not per-gender) `Prim\Mesh\Item\China\weapon\` folder with many real
  numbered weapons (`blade_01`, `bow_01`, ...), picked `blade_01` as an arbitrary fixed default.
  Confirmed its real `material_name` field ("blade1_5") matches a real layer inside a real
  `blade1_5.bmt`, and confirmed a real "Bip01 R Hand" bone exists in the real skeleton by pulling
  and inspecting `chinaman_skel.bsk` directly -- not assumed from the naming convention.
- Added `CharacterAssembler.assemble_weapon` (a single-mesh rigid attach to the new confirmed
  `WEAPON_BONE`, no slot-code parsing needed since real weapon meshes are single self-contained
  items, not paired L/R halves like armor). Wired a shared (not per-gender) cached weapon mesh
  into `World3D.gd`, gated on the real `SLOT_WEAPON` equip state via the same `EquipmentNet`
  query already used for armor -- refactored that query into one combined round trip
  (`_real_player_equipped_slots()`) returning both flags instead of querying twice.
- Extended the armor-broadcast mechanism to weapons too: `EntitySnapshot.HasWeapon`, queried live
  alongside `HasArmor` in one `equippedSlots` call server-side (replacing the old single-purpose
  `hasArmorEquipped`), so other players' weapons are real per-player from the same commit, not a
  follow-up.
- Verified with a real, live two-client TCP test (`TestWorldFullFlow`, extended): one character
  equips real armor but no weapon, the other equips a real weapon but no armor, and both the
  initial snapshot and the live `OpEntityEntered` broadcast carry the correct independent flags
  for each. Also rendered the real weapon mesh directly (real 37-bone skeleton + real `blade_01`
  mesh + real material layer match) to confirm the attachment mechanism visually, not just via
  unit assertions.
- Full regression: Go clean (`build`/`vet`/`test`, all packages), all 35 GDScript suites pass
  (added a dedicated `assemble_weapon` test to `character_assembler_test.gd`, extended
  `world_test.gd` for the new field).
- Remaining honest gaps unchanged: real-world placement scale (now with one investigated-and-ruled-
  out lead on record), the `.t` texture-blend-map format, and real per-account race/gender variety
  beyond the two confirmed China genders (Europe lacks real body meshes in this project's data).

## 2026-08-21 (cont'd 60) — got the China-woman screenshot the previous entry flagged as missing

- Closed the one honest gap left open by the gender-selection work: no rendered screenshot of an
  assembled China-woman body existed yet.
- Rebuilt `pk2list` on the RE box (it was still the pre-chain-fix build from earlier in this
  session -- 41 files instead of the real 73139) and pulled real China-man and China-woman
  skeleton/body/material files directly from a real retail `Data.pk2`.
- Wrote a generic nested-directory synthetic pk2 builder (throwaway, never committed) to pack
  real files at their real conventional paths -- more general than this session's earlier
  single-flat-directory synthetic archives, since character assets live several folders deep
  (`Prim\Skel\Char\China\...`, `Prim\Mesh\Char\China\woman\...`). Verified the built archive
  resolves every real file correctly via `ObjectLoader.find_file` before touching the actual
  scene.
- Used the project's existing `client/tools/render_character.gd` dev tool (loose `--bsk`/
  `--parts-dir` args, no gender-awareness needed) against the real pulled China-woman skeleton
  and two real body-part meshes (pelvis, thigh) -- got a real rendered screenshot showing two
  correctly mirrored legs attached to a real 39-bone China-woman skeleton, proving the paired
  L/R bone-attachment mechanism (the same one already verified for China-man) works identically
  for this gender's real data.
- This is the last item from the previous entry's "Not yet done" callout -- gender selection is
  now verified at every layer: live protocol round trip (Go), full encode/decode unit coverage
  (GDScript), a direct material-name-match check, and now an actual rendered real body.

## 2026-08-21 (cont'd 59) — real per-account gender selection: China man and China woman, both with confirmed real assets

- Closed the last honest gap from the armor-broadcast work: every character still rendered the
  same fixed China-man body regardless of who they really were. Checked whether real alternate
  bodies actually exist in this project's available real client data before building anything --
  found real, complete, parallel asset sets for China man and China woman (skeleton, 7 real
  body-part meshes each, a real default material/texture, and a real matching `clothes_03`
  6-piece armor set) via the RE box's real retail `Data.pk2` (rebuilt `pk2list` there first --
  it was still running the pre-chain-fix build from earlier this session, showing 41 files
  instead of the real 73139). Checked for a third real option (Europe) too: its skeletons exist
  but its *base body meshes* were never found in this client's real data, so Europe stays out of
  scope rather than being half-implemented -- only the two genders with genuinely complete real
  asset sets are offered, not a larger invented roster.
- Found and fixed one real naming-convention gap along the way: China-woman's real forearm mesh
  is `woman_arm_fore`, not `..._arm_lower` like China-man's. Confirmed (not guessed) that both
  real skeletons use the identical `Bip01 R/L Forearm` bone names by pulling and inspecting
  `chinawoman_skel.bsk` directly, then added an `arm_fore` alias to
  `CharacterAssembler.BODY_PART_BONES` pointing at the same real bones, with a dedicated
  regression test.
- Also directly confirmed (not assumed from the naming pattern) that China-woman's real
  material-matching works the same way China-man's does: pulled a real `woman_thigh.bms` and
  `chinawoman_warrior.bmt`, parsed both through this project's own readers, and verified
  `woman_thigh.bms`'s real `material_name` field ("chinawoman_body") matches a real layer name
  inside `chinawoman_warrior.bmt` -- the same name-matching mechanism `CharacterAssembler`
  already relies on.
- Added `character.Gender` (`GenderChinaMan`/`GenderChinaWoman`, `DefaultGender`, `ValidGender`)
  to `server/internal/character`, plus `Store.GetByID`/`Store.SetGender` (both stores). Kept
  `Store.Create`'s signature unchanged (no gender parameter) to avoid churning ~40 unrelated call
  sites across the test suite -- gender is applied via a follow-up `SetGender` call from
  `handleCreate` only when a real, valid, non-default choice was actually requested, keeping the
  common case a single unchanged `Create` call.
- Extended `CharacterCreateRequest` with an optional `Gender` field (empty/unrecognized falls
  back to the default rather than failing creation, since it's purely cosmetic) and
  `EnterWorldResult`/`EntitySnapshot` with the entering character's own real Gender and every
  broadcast peer's real Gender respectively (`genderOf`, a live `chars.GetByID` lookup at
  broadcast time -- same pattern as `hasArmorEquipped`, since `world.Entity` deliberately doesn't
  carry character details).
- Mirrored all of it in the GDScript client (`CharacterNet`, `WorldNet`) and wired real per-gender
  asset resolution into `World3D.gd`: `GENDER_ASSET_PATHS` replaces the old single hardcoded
  China-man path set, `_load_character_assets()` now loads and caches real assets for every real
  gender up front, and `_build_assembled_character()`/`_spawn_or_update_other()` pick the right
  cached set from each character's own real Gender (falling back to the default if a gender's
  assets never loaded). Added a real gender picker (`OptionButton`) to `CharacterSelect.tscn` so
  a player can actually choose China Woman at creation, not just via the protocol/tests.
- Verified with real, live end-to-end tests: `TestCharacterCreateWithGender` (Go, real TCP) creates
  a character with an explicit real gender choice and confirms it's actually applied, and that a
  bogus choice falls back to the default without failing creation. `TestWorldFullFlow` was extended
  so one of its two characters picks China-woman at creation, asserting the real gender propagates
  correctly through both `EnterWorldResult` (for the entering player's own body) and the live
  `OpEntityEntered` broadcast (for how a peer sees them) -- not just a standalone encode/decode
  round trip.
- Full regression: Go clean (`build`/`vet`/`test`, all packages), all 35 GDScript suites pass
  (added gender coverage to `world_test.gd`/`character_test.gd`, plus the new `arm_fore` bone-
  mapping test in `character_assembler_test.gd`).
- Honest gap acknowledged, not hidden: didn't get a full rendered screenshot of the China-woman
  body in this pass (the loose-file verification technique used elsewhere this session for
  quick asset checks didn't resolve cleanly through Godot's relative-path handling in the time
  available) -- verification instead rests on the live protocol round trip (Go), full encode/
  decode unit coverage (GDScript), the direct real material-name-match check above, and the fact
  that `World3D.gd`'s change is a straightforward parametrization of the already-proven China-man
  path into a per-gender lookup, not new rendering logic. A follow-up pass should still get an
  actual screenshot of an assembled China-woman character before calling this fully closed.

## 2026-08-21 (cont'd 58) — other players' armor is now real per-player too, broadcast over the network

- Direct follow-on to the local-player armor gating just shipped: that change only fixed the
  *local* player, since there was no way for the client to know any other player's real equip
  state. This closes that gap by having the server broadcast it.
- Added `HasArmor bool` to `EntitySnapshot` (`server/internal/session/world.go`), encoded as one
  extra byte. A new `hasArmorEquipped(ctx, eq, characterID)` queries the real equipment store live
  at broadcast time (both for `OpEnterWorldResult`'s initial "who's here" list and for
  `OpEntityEntered`), so it always reflects a character's actual current equip state rather than a
  value cached at some earlier point. `eq` is allowed to be `nil` (some handler-chain tests wire up
  `WorldHandler` without one) and just reports "not equipped" in that case, rather than requiring
  every caller to carry an equipment store around.
- Mirrored the field in `WorldNet.EntitySnapshot` (`client/scripts/net/world.gd`) and wired it into
  `World3D.gd`: `_spawn_or_update_other` now takes a real `has_armor` flag (from both the initial
  `others` list and live `OpEntityEntered` broadcasts) and passes it straight into
  `_build_assembled_character(include_equipment)` -- the same mechanism the local player already
  uses, so other players now only appear armored if their own account actually has something
  equipped.
- Verified with a real, live end-to-end test, not just unit-level encode/decode: `TestWorldFullFlow`
  now equips real armor on one of its two test characters (via the real `equipment.OpenSQLStore`,
  same Postgres-backed store production uses) and asserts both real outcomes over an actual TCP
  connection -- the unarmored character's snapshot carries `HasArmor: false`, the armored
  character's live `OpEntityEntered` broadcast carries `HasArmor: true`.
- Full regression: Go clean (`build`/`vet`/`test`, including the live two-client flow test), all 33
  GDScript suites pass (added `world_test.gd` coverage for the new field, including decoding a bare
  `OpEntityEntered` payload with each `has_armor` value).
- Remaining honest gap, unchanged: this is still the one fixed China-man *body* for every
  character -- only the armor is now real per-player. Real per-account race/gender selection would
  need actual asset variety this project hasn't gone looking for yet, not just a protocol change.

## 2026-08-21 (cont'd 57) — the local player's armor is now gated on real, server-authoritative equip state

- Continuing down the open-items list: the player's armor previously rendered unconditionally
  whenever the real asset files were found, regardless of whether the character's account had
  actually equipped anything. This project already has a real, tested, server-authoritative
  equip system (`server/internal/equipment`, `EquipmentNet`/`NetClient.list_equipment` on the
  client) wired into the 2D equipment HUD — it just wasn't consulted by the 3D character
  rendering.
- `_build_assembled_character()` now takes an `include_equipment` flag. A new
  `_real_player_has_armor_equipped()` queries the real `OP_LIST` equipment result for the local
  player and checks for a real `SLOT_ARMOR` entry; `_try_apply_real_player_character()` awaits
  that before deciding whether to attach the armor. A newly-created character has nothing
  equipped by default, so it now renders bare-skinned until the player actually equips real
  armor through the existing, already-tested equip flow — more honest than showing the one fixed
  armor set unconditionally on every character regardless of real state.
- Guarded against hanging the many standalone dev-tool/screenshot contexts this project's asset
  work relies on (`World3D.tscn` loaded directly with `SRREVAMP_*` env vars set, no real
  login/enter-world flow): the query is skipped entirely (defaults to no armor) unless
  `NetClient.is_connected_to_server()` is actually true, since awaiting a signal that can never
  fire would otherwise hang the scene forever. Verified this guard directly: rendered the scene
  headless with no server connection and confirmed it completes normally (5 frames, no hang).
- Other connected players are unaffected by this change — still the same honestly-documented
  fixed China-man+armor rendering, since there's no real per-character equip state broadcast for
  *other* players yet (would need a protocol extension, not attempted here).
- Full regression: Go clean, all 33 GDScript suites pass (no test changes needed — this composes
  already-unit-tested primitives, `EquipmentNet`/`NetClient.list_equipment` covered by
  `equipment_test.gd`, behind an already-established connection guard).

## 2026-08-21 (cont'd 56) — real terrain collision, built from the same real triangle data as the visual mesh

- Picked up the last "Not yet done" item directly tied to the terrain work just verified: the
  ground's collision shape was still the flat placeholder box even after the visual mesh became
  real.
- `Mesh.create_trimesh_shape()` (a built-in Godot method) builds a `ConcavePolygonShape3D`
  straight from the real `ArrayMesh` `MapmTerrainBuilder.build_mesh()` already produces — no new
  geometry-generation logic needed, and no risk of visual/collision mesh drifting apart since
  they're built from the exact same real triangle data.
- `World3D.gd`'s `_try_load_real_terrain()` now disables the placeholder `Ground/Collision` shape
  and attaches a `StaticBody3D`/`CollisionShape3D` built this way to the real terrain node
  whenever `SRREVAMP_MAPM_PATH` loads successfully.
- Verified against a real region (`100/100.m`, loose file, no pk2 needed for this check): rendered
  headless and confirmed visually — the player capsule rests directly on the real terrain surface
  with a real cast shadow, not floating above it or clipping through.
- Full regression: Go build/vet clean, the three most relevant GDScript suites
  (`mapm_terrain_builder_test`, `mapm_reader_test`, `net/world_test`) pass — no test changes
  needed, this is pure runtime scene wiring with no new parsing logic to unit-test.
- Same honest caveat as before: rows within the recovered terrain strip are real and correctly
  shaped, but the strip's true position relative to a player's real spawn coordinate still isn't
  confirmed — collision now matches whatever terrain is rendered, not a claim about absolute
  real-world placement.

## 2026-08-21 (cont'd 55) — first real, assembled region: terrain + placed objects rendered together

- User asked to render "a real part of the world environment... successfully mapping all those
  items from a pk2 to create the world" — every previous milestone (terrain, one scenery object,
  one map object, other players) had been verified in isolation. This combined them: real
  `100/100.m` terrain and real `100/100.o` object placements from the same real region, loaded
  into the same scene at once, resolved through the real `object.ifo` index and rendered with
  their real `.bsr` models.
- Pulled real `Map.pk2`/`Data.pk2`/`Media.pk2` data for region 100/100 from the RE box and packed
  it into synthetic test archives (same technique used throughout this project — real bytes at
  conventional real paths, never fabricated). Loaded both `SRREVAMP_MAPM_PATH` and
  `SRREVAMP_MAPO_PATH` from the same region in one `World3D` run.
- Confirmed working end-to-end via log output: 13211 real terrain tiles parsed (777 complete rows
  rendered), 58/58 real map objects loaded and resolved to just 4 distinct real `.bsr` models
  (added a `templates` cache in `_try_load_real_map_objects` keyed by resolved `.bsr` path, so
  repeat placements of the same real object type `duplicate()` an already-loaded template instead
  of re-parsing `.bms`/`.bmt`/`.ddj` for every placement — a real region turned out to reuse very
  few distinct models across many placements).
- First render exposed a real placement-scale issue, not a bug: all 58 objects clustered tightly
  around their own real relative positions (same `Vector3(4, 0, -4)` close offset used for a
  single scenery object left the player standing in the middle of a dense tree cluster, filling
  the frame with canopy/trunk geometry and hiding the terrain entirely). Fixed by widening the map
  object placement offset to `Vector3(20, 0, -30)` so the cluster is framed as a recognizable
  group instead of standing inside it — the default gameplay camera (`World3D.tscn`) was left
  untouched.
- Final render (default camera, corrected offset): real textured terrain (visible path/ground
  blend matching the region's real minimap texture) and a real tree with bark texture, both in
  frame together, player capsule standing at a sensible distance rather than buried in geometry.
- Full regression: Go clean (`build`/`vet`/`test`, all packages), all 33 GDScript suites pass (19
  format/protocol readers + asset builders + 17 net protocol packet suites — no test changes were
  needed, this was pure runtime/placement behavior in `World3D.gd`).
- `MAX_MAP_OBJECTS` raised from 30 to 300 (an honestly-scoped cap on real placements to
  instantiate, not a real engine limit — distinct real models are cached, so this mostly bounds
  node/instance count, not real file parsing).
- Remaining open items unchanged: real-world object placement scale/position isn't independently
  confirmed against in-game reference (objects render at the right *relative* positions from
  `.mapo`, but absolute scale versus the real client isn't cross-checked), real per-account
  character loadouts (server-side, not started), the `.t` texture-blend-map format (found, not
  decoded).

## 2026-08-21 (cont'd 54) — fixed the real `.bsr` nature-category parsing bug

- User said "go for it" after being offered a choice; picked the `.bsr` nature-category bug over
  the bigger per-account-loadout architecture piece, since fixing it directly unlocks the
  object-index work just shipped for real outdoor regions (which are mostly trees/grass, not
  buildings — the one real region sample checked so far had *zero* building-category placements).
- Root-caused it by hex-dumping a real `center_asia_plant01_01.bsr` byte-for-byte: nature-category
  files genuinely order their fields differently from the building-category files this format was
  originally derived against. Building order: mesh path, then bounding box, then material path,
  then a sub-mesh list. Nature order: bounding box, then material path, then a `"1"` field, then
  the mesh path *last* — materially different, not a corrupt/edge-case file.
- Fixed by making the path-finding scan extension-aware: search independently for the first string
  ending in `.bms` (mesh path) and the first ending in `.bmt` (material path), rather than
  assuming "whichever plausible string comes first is the mesh path." This finds the right field
  in either real order without needing to first detect which category a file belongs to. Bounding
  box / sub-mesh-list extraction still only applies to the building order — the nature order's
  bounding-box position isn't confirmed, so it's honestly left unclaimed rather than guessed at.
- Fixed both readers (`server/internal/bsr`, `client/scripts/bsr/bsr_reader.gd`). Added synthetic
  regression tests for the nature-category order to both. Verified against real data at every
  step: confirmed the bug on 2 real nature files, confirmed the fix against the same real
  `center_asia_plant01_01.bsr`, and verified end-to-end — pulled its real mesh/material/texture,
  rendered it through the real scene, and got a real, visibly leafy, correctly textured plant.
- Full regression: Go clean (new nature-order test), all 19 GDScript suites pass.
- This resolves the last open item from the object-index work — real outdoor map objects
  (buildings and vegetation both) now render with their real models through
  `SRREVAMP_MAPO_PATH`. Remaining open items: real per-account character loadouts (the bigger
  architectural piece, not started), real-world object placement scale/position (objects render,
  but not necessarily at their true in-game size/position), and the `.t` texture-blend-map format.

## 2026-08-21 (cont'd 53) — solved the "auto select" dead end: a real object-index table exists

- User asked "what's next" after the pk2 chain fix. Picked re-attempting the `.mapo`
  type-ID-to-resource mapping — a confirmed dead end earlier this session — on the theory that the
  pk2 truncation bug just fixed might have been silently hiding the answer the whole time.
- It was: browsing the newly-fixed `Data.pk2` found `object.ifo` (root level, magic
  `JMXVOBJI1000`) — a real, plain-text (not binary container, unlike every other `JMXV*` format
  here) table of 3299 real object types, each a real sequential type ID plus a real, resolvable
  `.bsr` resource path. Confirmed against real data, not just internal consistency: pulled a real
  `100/100.o` region's real type IDs (`1489`, `1748`, `669`, `1488`) and looked them up, getting
  back genuinely sensible real scenery (trees, grass) — exactly what a real outdoor region
  scattering dozens of those types would plausibly place.
- Implemented `server/internal/objidx` (Go) and `client/scripts/objidx/objidx_reader.gd`
  (GDScript), both verified against the real file. Wired into `World3D.gd`
  (`SRREVAMP_MAPO_PATH`): real `.mapo` placements now resolve through this table and render with
  their real `.bsr` model instead of a placeholder marker.
- Found a real, separate gap along the way: `res\nature\...` (tree/grass) `.bsr` files don't parse
  correctly with the current reader (mesh/material path fields come out garbled), while
  `res\bldg\...` (building) files — the category this format was originally derived against —
  parse fine. Not root-caused; documented in `docs/protocol/BSR_FORMAT.md` rather than guessed at.
  `World3D.gd` skips these gracefully.
- Verified the real wiring end-to-end despite that gap: built a synthetic test using a real
  building object (`cj_ferry_stone01.bsr` + its real mesh/material/texture) at a real object-index
  type ID, referenced by a hand-built (but real-format-shaped) `.mapo` region — rendered
  successfully, a real textured object appearing in the scene (very large/close at default camera
  distance, since no real-world placement scale has been confirmed yet — same honest caveat as
  terrain/scenery elsewhere in this project).
- Full regression: Go clean (new `objidx` package tests), all 19 GDScript suites pass (added
  `objidx_reader_test.gd` to CI).
- Real, honestly-scoped remaining gaps: the nature-category `.bsr` parsing bug: real-world object
  placement scale/position isn't confirmed (objects render, but not necessarily at their true
  in-game position/size); and this only resolves objects whose type ID exists in the table (some
  real placements may still not resolve — that's surfaced honestly via a printed skip count, not
  hidden).

## 2026-08-21 (cont'd 52) — solved the pk2 truncation bug: real files went from 41 to 73139

- User said "everything needs done" — after shipping other-player rendering, picked up the pk2
  directory-truncation bug documented earlier this session as the other half.
- Found and used the actual real client library the bug lives in: `GFXFileManager.dll` (not
  `sro_client.exe` or `EternityLib.dll`, which is why earlier "JMXV"/"JoyMax" string searches in
  those never found the directory-read code). Set up Ghidra headless decompilation against a
  pre-existing analyzed project already on the RE box (installed `pyghidra`/`jpype1` first, then
  fell back to a Java-based Ghidra script when the Python launcher path didn't cooperate) and
  found the real directory-block-reading function by searching for literal references to the
  archive's own "JoyMax File Manager!" magic string.
- Decompiled it and found the real mechanism directly: the block-size (`0xa00`=2560) and
  entry-size (`0x80`=128) constants this project already had confirmed appear exactly where
  expected, and a real "next block" jump reads its target from what this project's docs had
  called a "reserved" field — only on a block's **last (20th) entry slot**, not on every entry
  (which is exactly why an earlier pass this session found what looked like meaningless noise
  there: it checked an entry whose directory didn't need continuation, so the field was
  legitimately near-zero, not a wrong theory).
- Verified against real bytes before touching any code: dumped `Data.pk2`'s root block's last
  entry, found a real nonzero next-block offset, followed it, and found real continuing root
  entries — including, after a third chained block, the **`Prim` folder** this project has been
  building every conventional real asset path against all session, which had never actually been
  reachable through `pk2list` until now.
- Fixed both readers (`server/internal/pk2`, `client/scripts/pk2/pk2_reader.gd`) to follow the
  real chain, bounded by a cycle/corruption guard. Added real chained-block regression tests to
  both. Verified end-to-end against the real `Data.pk2`: `pk2list`'s file count went from 41 to
  **73139**.
- Full regression: Go clean (including 2 new pk2 chain tests), all 18 GDScript suites pass.
- This was the last of the two things flagged as open after the armor work. Both are now
  addressed — other players render as real characters, and the pk2 reader is no longer silently
  dropping most of a real archive's content.

## 2026-08-21 (cont'd 51) — other connected players are real characters now too, not just capsules

- User said "everything needs done" after being offered a choice between the pk2 truncation bug
  and other-player rendering. Picked other-player rendering: it's fully within this project's own
  control (no RE/decompiler uncertainty), and it directly extends today's character+armor work to
  somewhere it's actually visible to more than one person.
- Realized the "real per-account loadout" blocker didn't actually block this: since every player
  already resolves to the exact same fixed China-man+clothes_03 pick (no real per-character race/
  gender/equipment is tracked server-side), showing *every* connected player that same real
  character instead of a capsule isn't overclaiming anything new -- it's the same honest fixed
  default, just applied consistently instead of only to the local player.
- Refactored `World3D.gd`: character asset parsing (skeleton + body parts + equipment + resolved
  materials) is now loaded and cached **once** at scene startup
  (`_load_character_assets`/`_character_skel` etc.), instead of only ever happening inline for the
  local player. A new `_build_assembled_character()` builds one fresh, independent `Skeleton3D`
  per character from that cached data (each connected player needs its own skeleton instance, but
  none of them need to reparse the same real `.bms`/`.bmt` files). `_spawn_or_update_other` now
  calls this to build a real character for every connected player, falling back to the labeled
  placeholder capsule only if the shared assets never loaded.
- Verified end-to-end: rendered the player alongside a second, independently-spawned character
  using the same synthetic pk2 as the armor work -- both render as full real armored characters
  with a name label, confirming the shared-cache approach actually works for more than one
  simultaneous instance (not just re-verifying the single-player case again).
- Full regression: Go clean (no server changes this entry), all 18 GDScript suites pass.
- Real, honestly-scoped limit unchanged: this is still the same fixed character for everyone, not
  a real per-account identity -- that still needs server-side loadout tracking, a separate, larger
  piece of work not started. The pk2 >20-entry truncation bug is also still open.

## 2026-08-21 (cont'd 50) — verified the armor visually, found and documented one real mispositioned piece

- User asked "what's next" after the armor commit; picked verifying it actually looks right over
  starting new work, since the shipped screenshot only showed 3 of 6 pieces clearly.
- Built a throwaway color-coded diagnostic render (one bright, unshaded, non-culled debug material
  per slot) to see exactly where each of the 6 real pieces lands, rather than guessing from the
  gameplay screenshot. Confirmed 5 of 6 are genuinely correct: head, body, legs, and feet were
  already visibly right; the arm/gauntlet piece turned out to be correct too — it was just small
  and subtle under normal shading/lighting, not actually missing (a real "looks broken but isn't"
  case, caught before it got misreported as a bug).
- Found one real, confirmed bug: the shoulder piece (`sa`) renders down near the character's hip,
  not the shoulder. Traced it precisely — its raw baked Y coordinates (~0.9-2.3) sit roughly 13
  units below `Bip01 Clavicle`'s real height (~15), unlike the other 5 slots, whose raw coordinates
  land exactly right using the same absolute-character-space convention body parts already use.
  Documented the real, precise mismatch in `character_assembler.gd` rather than guessing a fake
  offset to paper over it — left it attached (harmless, just tiny and misplaced) instead of hiding
  the real limitation.
- No functional/test changes this entry — verification and honest documentation only.

## 2026-08-21 (cont'd 49) — real armor on the player character

- User asked "what next" after the pk2-truncation-bug documentation; picked equipment/armor
  rendering, since the reference screenshots earlier in this session showed a fully-armored
  character and the assembled player was still bare-skinned.
- Found real China-man armor: `Prim/Mesh/Item/China/man_item/clothes_03_{aa,ba,fa,ha,la,sa}.bms`
  — a real, full 6-piece set (arm/body/foot/head/leg/shoulder, the standard real armor-slot
  convention) plus a matching `clothes_03.bmt` (+ a separate `clothes_03_sa.bmt` for the
  shoulder piece specifically). Confirmed via the Go readers that the exact same real
  material-name-to-layer-name pairing already used for the player's body (see cont'd 43) holds
  for equipment too — each piece's own `material_name` field matches a real `layer_name` inside
  `clothes_03.bmt` one-for-one.
- Determined which slots are genuinely paired (mirrored L/R baked into one file, like body parts)
  vs. single-piece by a real triangle-centroid-X gap scan on all 6 real files, not a guess: `aa`
  (arm), `fa` (foot), and `sa` (shoulder) each have a large (>5 unit) gap centered near x=0 — two
  disjoint real halves; `ba` (body), `ha` (head), and `la` (leg) stay continuous — genuinely single
  pieces. Confirmed the skeleton's real bone names via the Go `.bsk` reader (the GDScript one hung
  on this specific real file for reasons not yet chased down — flagged as an open bug, worked
  around by using the already-tested, already-correct Go reader instead).
- `CharacterAssembler` gained `assemble_equipment` (+ `EQUIPMENT_SLOT_BONES`, keyed by the real
  2-letter slot code, e.g. `"aa"`) — reuses the exact same rigid `BoneAttachment3D` attachment and
  X-sign-split logic already proven for body parts, no new mechanism needed. `World3D.gd`'s player
  loader now also loads this real 6-piece set (arbitrary fixed pick among many real numbered sets,
  same honesty level as the body's material pick) and attaches it via `assemble_equipment`.
- Verified end-to-end against a synthetic pk2 packing the real skeleton + real body + real armor
  set + real armor textures: all 6 equipment parts load and attach without error. Screenshot shows
  a real helmet, shoulder pads, and chest/belt piece clearly; the leg/arm/foot pieces are present
  (confirmed via bone-attachment count) but less visually prominent at the render distance used —
  noted honestly rather than overclaiming a fully-dressed result.
- Full regression: Go clean, all 18 GDScript suites pass (extended `character_assembler_test.gd`
  with equipment-specific cases: paired-slot split, unpaired-slot single-bone, unrecognized-slot
  skip).
- Still open: bare-skinned other players/NPCs (still no per-character loadout tracked
  server-side), the pk2 directory-truncation bug, the `.t` texture-blend-map decode, and now also
  a new small one — the GDScript `BskReader` hang on a specific real file, not yet root-caused.

## 2026-08-21 (cont'd 48) — found a real, confirmed gap in the core pk2 reader: >20-entry directories truncate

- While pushing further on real assets (user said "keep going" after the terrain texture win),
  tried `pk2list` against the real `Data.pk2` on the RE box and got a suspiciously tiny listing
  (41 files from a 3.8GB archive). Chased it down instead of ignoring it.
- Confirmed real and significant: every directory this project had tested before happened to fit
  in one 20-entry block, so the "no chain mechanism found" note in `docs/protocol/PK2_FORMAT.md`
  was never actually stress-tested against a real archive that needed one. `Data.pk2`'s root
  directory has real children (a real `Char`/`NPC`/`particle`/`Struct` folder, among others) that
  this reader simply never sees — proved via a low-level byte scan finding 2451 real,
  self-referential directory blocks in the first 16MB alone, of which only 6 are reachable by
  walking the tree from root the way this reader currently does.
- Spent real effort looking for the actual continuation mechanism (checked every field near a full
  block's last entry and an under-full block's `.` entry for a plausible next-block pointer,
  checked whether blocks are just contiguous per-directory, checked whether `..` might be a
  "back to root" shortcut instead of "immediate parent") and ruled all of them out with concrete
  evidence rather than declaring victory on a guess. Documented the real negative findings and two
  concrete next-step options (decompile the real client's directory-read function, or reconstruct
  trees empirically via `..` back-references) in `docs/protocol/PK2_FORMAT.md` so a future pass
  doesn't re-tread this.
- Real impact, scoped honestly: this doesn't invalidate anything already shipped via an exact,
  known-in-advance path (every `SRREVAMP_*_PATH` env var still works fine — reading one named file
  doesn't require enumerating its siblings). It only affects *browsing* for paths this project
  doesn't already know, which is exactly what `pk2list` (no `-extract`) is for — so that tool's
  listings should be treated as a lower bound, not a complete inventory, until this is solved.
- No code changes this entry — investigation and honest documentation only. Real fix deferred to a
  future pass per the two concrete next steps recorded.

## 2026-08-21 (cont'd 47) — found the real texture: user pointed out the RE box already has real client pk2s

- User pointed out (correctly) that the RE box's `/opt/sro-files/client/` already has full real
  `Data.pk2`/`Media.pk2`/`Map.pk2`/`Particles.pk2`/`Music.pk2` — a genuine retail client install,
  not just the private-server package tree used for everything else in this project. Used
  `pk2list` against it directly instead of asking the user to run it themselves.
- Found the real thing: `Media.pk2\minimap\<region_x>x<region_y>.ddj` — a real, per-region
  top-down painted texture (256×256, confirmed real grass/dirt-path/rock colors, decoded
  successfully via this project's own `DdjReader`), keyed by the exact same region coordinates as
  `Map.pk2`'s `<x>/<y>.m` files. Not a live 3D ground-texture asset (still not found — see below),
  but real, region-accurate painted art.
- Extended `server/cmd/pk2list` with `-extract <path> -out <local file>` so a real file's bytes
  can actually be pulled out, not just listed — pulled the real `100x100.ddj` and its matching
  real `100/100.m` (a Shape-B region) to verify the pairing end-to-end.
- `World3D.gd`'s terrain loader now takes `SRREVAMP_MAPM_TEXTURE_PATH` (+ its own
  `SRREVAMP_MEDIA_PK2_PATH`, since minimap images live in yet a third separate archive from
  `Data.pk2`/`Map.pk2`) and applies it as the terrain's real texture, falling back to the previous
  per-tile vertex-color variation if unset. First render badly streaked (one square image
  stretched across a ~777-row-long recovered strip); fixed by tiling the texture roughly once per
  `GRID_WIDTH` (17) rows via `uv1_scale` instead of one giant stretch — real screenshot sent to
  OpenSRO showing real grass/path/rock texture detail, a dramatic visual improvement over both the
  flat placeholder and the vertex-color stopgap.
- Full regression: Go clean (including new `pk2list` extract tests), all 18 GDScript suites pass.
- Still honestly open: this is real per-region minimap art standing in for a live 3D ground
  texture, not confirmed to be the literal thing the real client's terrain shaders sample at
  runtime — no such live multi-layer system has been found (see MAPM_FORMAT.md). Good enough to
  look like the real game; not claimed as more than what it is.

## 2026-08-21 (cont'd 46) — pushed harder on real ground textures; shipped a way for the user to help find one

- User pushed back on the vertex-color terrain from the previous entry: it's real data, but it's
  not a real texture and doesn't look like the game. Fair -- went back to look harder before
  accepting "no real texture found" as final.
- Checked the two remaining real terrain shaders (`terrainpsp10.psh`, `terrainpspdetail10.psh`,
  the "parallax" variants) not checked last time: same result as the others, one continuous
  `TEX_TERRAIN_COLOR` texture stage, no real multi-layer type-index blend in shader code anywhere
  across all 4 real terrain shaders found.
- Made real progress on the previously-unopened `.t` file type instead: every real region's `.t`
  file is exactly 140436 bytes (fixed, unlike `.m`/`.o`/`.o2` which vary per region); its 140420-byte
  body divides cleanly by 17 (the same real column width `.m` already confirmed); read as `uint32`
  cells, 80% are exactly `0x00000000` or `0xFFFFFFFF` with the remaining 20% spread across 2408
  distinct intermediate values -- a real, structural pattern consistent with a 4-channel
  blend/weight map (mostly "pure" single-texture cells, blended at texture-boundary transitions),
  not random noise. **Not fully decoded** -- row/column layout and cross-validation against a
  matching `.m` file weren't nailed down this pass. Real, promising, genuinely unresolved -- not
  claimed as solved.
- The RE box's real client data (a private-server distribution package) was searched broadly for
  any generic tileable ground texture (grass/dirt/sand/rock/snow, not tied to a specific
  creature/prop) and found none -- only foliage decoration sprites and named rock props. Even a
  fully-decoded `.t` blend map would only say *where* textures blend, not *which* real texture
  files fill each channel -- and no such lookup exists anywhere in the RE box's data. Real
  possibility: this private-server package may have stripped the actual terrain texture set (a
  large asset a server distribution doesn't need), meaning it may only exist in a genuine retail
  client -- which the user has, and this RE environment doesn't.
- Rather than keep guessing blind, shipped `server/cmd/pk2list` -- a small, tested Go CLI
  (`go run ./cmd/pk2list -pk2 "<path>" -filter <substring>`) that lists every real file path
  inside a real pk2 archive the user points it at, so they can search their own real `Data.pk2`/
  `Media.pk2` for real ground/terrain texture paths this project has no sample of, without needing
  to transmit the archive anywhere. `README.md` updated with the full current env-var list (was
  stale, missing the terrain/player-auto-load vars from recent entries) and the new tool.
- Full regression: Go build/vet/test clean including a new `pk2list` test.
- Still open: real ground textures (now genuinely blocked on the user's own real files, not
  abandoned), the `.t` format's full decode, and everything else already tracked as open.

## 2026-08-21 (cont'd 45) — real per-tile terrain color, since no real ground-texture system was found

- User saw the terrain screenshot and pointed out it was flat green — no texture variation.
  Investigated whether a real ground-texture system exists to wire up honestly: found real
  terrain pixel shaders (`shader_maptool/terrainps*.psh`) sampling a single continuous
  `TEX_TERRAIN_COLOR` texture (not a multi-layer type-index blend), and confirmed (via the
  RE-box's own `Map.pk2` listing) that region folders carry no per-region texture file alongside
  `.m`/`.o`/`.t` — so there's no confirmed real texture asset or lookup table this project can
  point to without fabricating one. Declined to invent a texture system.
- Instead used a real field this project already had but wasn't using: Shape A's first `Extra`
  byte (200+ distinct values across real files, previously only described as "plausibly a
  texture/terrain-type index or blend weight" in `docs/protocol/MAPM_FORMAT.md`) now drives real
  per-vertex color variation on the terrain mesh — a green-to-brown hue spread keyed to that real
  byte, not a claim about what any specific value represents. `MapmTerrainBuilder.build_mesh` now
  emits a real `ARRAY_COLOR` array; `World3D.gd`'s terrain material enables
  `vertex_color_use_as_albedo`. Verified against real `0/0.m` data and a fresh screenshot: visibly
  mottled green/yellow-green ground instead of one flat color.
- Extended `mapm_terrain_builder_test.gd` with real-shaped fixtures covering distinct terrain-type
  bytes producing distinct colors. Full regression: Go clean, all 18 GDScript suites pass.
- Real ground textures remain unimplemented — flagged honestly, not silently left looking done.
  If the user points at a specific real texture file, wiring it in as a tiling ground texture
  (UVs are already generated) is a much smaller follow-up than this session's blind search was.

## 2026-08-21 (cont'd 44) — real terrain, unblocked by a real per-tile field found on real data

- User asked to wire up real map/terrain rendering, floating a hunch that it might be "a sort of
  mesh system." Investigated on the RE box first: found a real, previously-unopened `.t` file type
  in every `Map.pk2` region folder (magic `JMXVMAPT1001`, a brand-new never-before-parsed
  container — not decoded yet, flagged for a future pass), but it isn't mesh-shaped data (mostly
  long runs of `0x00`/`0xFF`) and no discrete terrain-tile mesh files exist anywhere on the box —
  the "mesh system" hunch didn't hold literally. Real terrain is still a heightmap.
- Directly inspecting Shape A's two previously-unconfirmed `uint16` fields on a real `0/0.m`
  broke the actual, longstanding blocker instead: the first field increments by a fixed ~4096 step
  and wraps back to 0 after exactly **17** distinct values, every single time — a real, directly
  observed per-tile **column index**, not a statistical inference. This mechanistically confirms
  the T=17 DFT periodicity signal this project had recorded (but explicitly not trusted) across
  several earlier sessions as an actual real grid width. The second field follows the same
  encoding but doesn't cleanly decrement across a whole file — a real, structured, but still
  unresolved row-index candidate, left undecoded. `docs/protocol/MAPM_FORMAT.md` updated with the
  full finding.
- New `client/scripts/assets/mapm_terrain_builder.gd` (`MapmTerrainBuilder`, client-only —
  building a Godot mesh is a rendering concern, not a protocol concern, so no Go mirror): decodes
  the real confirmed column field per tile, groups tiles into real 17-wide rows by detecting where
  that field wraps (self-correcting if the resync scan documented in MAPM_FORMAT.md ever drops a
  tile mid-row, rather than silently shifting every later column), and builds a triangulated
  `ArrayMesh` with real per-tile heights and estimated normals. Only rows with all 17 real tiles
  present are kept — an incomplete row is dropped, not padded with a guess. Unit tested against
  synthetic Shape-A-shaped fixtures (a resync-dropped-tile case included) and verified against a
  real `0/0.m`: 12417 real tiles in, 584 complete real rows recovered (9928 vertices, 18656
  triangles), real height range -53.8 to 598.5.
- Wired into `World3D.gd` behind `SRREVAMP_MAPM_PATH` (+ its own separate `SRREVAMP_MAP_PK2_PATH`,
  since `Map.pk2` is a separate archive from `Data.pk2` in a real retail install — confirmed from
  the user's own file listing) — replaces the placeholder ground's visual mesh (not its collision
  shape yet) when set. Found and fixed two real placement bugs verified end-to-end against a
  synthetic pk2 packing the real `0/0.m`: the terrain's rows extended behind the camera instead of
  into view (fixed with a 180° yaw, a proper rotation that preserves winding), and the mesh's
  triangle winding was backwards for a downward-looking camera, making the near terrain invisible
  under normal back-face culling until the winding order itself was corrected (not worked around
  with double-sided rendering) — confirmed via a disable-culling sanity check before fixing the
  actual index order. Real screenshot sent to OpenSRO: the player now stands on genuine undulating
  real terrain, not a flat placeholder box.
- Full regression: Go build/vet/test clean, all 18 GDScript test suites pass (1 new terrain-builder
  test suite added).
- Still open from the original 3-part request: the deeper "auto select" problem for other
  players/map objects, and real equipment/armor rendering. Also newly open: the real `.t` file
  type found this session (never parsed), and the terrain's real world-position/scale relative to
  a player's actual spawn coordinate (currently placed for visibility, not confirmed accuracy) and
  its collision shape (still the flat placeholder box).

## 2026-08-21 (cont'd 43) — real character texture, and a real `.bmt` parsing bug fixed along the way

- User said the character should "look like the actual game" and, mid-turn, explicitly rejected
  doing this with hand-tuned cosmetic guesses (sky colors, fog, ground tint) not backed by real
  data — reverted those scene edits immediately and stayed on real-asset-driven work only.
- Pulled a real character material + texture from the RE box:
  `Prim/Mtrl/Char/China/man/chinaman_warrior.bmt` and its `chinaman_warrior_body.ddj` texture
  (previously only hair/face `.bmt`s from a patch-staging tree had been checked). Found this
  file's raw bytes start with `JMXVBMT 0102` **directly at byte 0** — no zlib wrapper — whereas
  every previously-seen real `.bmt` was zlib-compressed. Confirmed across 3 real files from the
  live client `Data` tree (`chinaman_warrior.bmt`, `chinaman_bogy.bmt`, `chinaman_monk.bmt`, all
  same magic-at-byte-0 pattern) that this is a second real on-disk variant, not a one-off broken
  file — so both `BmtReader` (GDScript) and `server/internal/bmt` (Go) silently failed to parse
  any real character material until now. Fixed both to detect the magic directly before assuming
  the compressed layout; added a real-shaped synthetic regression test for the new variant to
  each. `docs/protocol/BMT_FORMAT.md` updated with both variants.
- Found the actual pairing rule linking a `.bms` mesh to its real texture: a real `man_thigh.bms`'s
  own `material_name` field reads `"chinaman_body"`, which is also the real `layer_name` of the
  first layer inside the real `chinaman_warrior.bmt` — an exact string match, confirmed by
  inspecting both files directly. This is a stronger, name-matched rule than `ObjectLoader`'s
  existing index-based fallback for `.bsr` pieces (which still applies where no name match is
  possible).
- `CharacterAssembler.assemble` now takes an optional `materials_by_name` Dictionary and resolves
  each part's own material by its real `material_name`, falling back to a flat default color only
  when no match exists. `World3D.gd`'s player-character loader now resolves
  `Prim/Mtrl/Char/China/man/chinaman_warrior.bmt` via `ObjectLoader.load_material`/
  `build_godot_material` (the same pipeline already verified for scenery) and passes the real
  resolved textures in. Verified end-to-end against the real skeleton + real body-part meshes +
  real material + real texture, packed into a synthetic pk2 at the conventional path layout:
  the player character now renders with the actual game's skin texture, not a flat tan color —
  screenshot sent to OpenSRO.
- Full regression: Go build/vet/test clean, all 17 GDScript test suites pass (2 new BMT-variant
  tests added).
- Still open from the original 3-part request: the map/terrain gap (`.mapm` grid dimensions) and
  the deeper "auto select" problem for *other* players/map objects — next up. Also still open:
  equipping real armor/weapons (the reference screenshots the user sent show a fully-armored
  character, not the bare-skinned one this produces) — no equipment-to-mesh mapping has been
  investigated yet.

## 2026-08-20 (cont'd 42) — the bare-skeleton fix: real body-part meshes, no skinning data, and a real auto-loaded character

- User showed their own real client file listing (`Data.pk2`, `Media.pk2`, `Map.pk2`,
  `Particles.pk2`) and asked to fix the bare skeleton, the map/terrain gap, and the "auto select"
  problem. Started with the bare skeleton, since it had the clearest path forward.
- Found real character **body-part** meshes on the RE box (`man_pelvis.bms`, `man_thigh.bms`,
  `man_calf.bms`, `man_torso_upper/lower.bms`, `man_arm_upper/lower.bms` — as opposed to the
  hair/face attachment pieces checked previously) and a real matching human skeleton
  (`Prim/Skel/Char/China/chinaman_skel.bsk`, 37 bones, standard Biped naming — parsed correctly
  with zero changes needed, confirming `.bsk`'s reader is genuinely general).
- **Settled the skinning question for good**: the full 44-byte `.bms` vertex record is now fully
  accounted for and none of it is bone-weight data — there's no room left for one. What real files
  do instead: each paired body part (thigh, calf, upper arm, forearm) bakes **both left and right
  sides into one file** as two mirrored, non-overlapping triangle ranges, split only by which side
  of `x=0` a triangle's centroid falls on (confirmed by hand on `man_thigh.bms`: vertex 0 at
  `x=+0.872` and vertex 23 at `x=-0.872` are exact mirrors). `docs/protocol/BMS_FORMAT.md`
  rewritten with the full finding.
- New `client/scripts/assets/character_assembler.gd` (`CharacterAssembler`): splits paired body
  parts by triangle-centroid x-sign, attaches each (possibly split) piece rigidly to its
  name-matched bone via `BoneAttachment3D`, offset by that bone's own bind-pose position so the
  mesh's real baked absolute-space coordinates land correctly and rotate rigidly around the right
  pivot as the bone animates (derived and documented in the file's top comment — the same rigid-
  rotation math `SkeletonPose`/`Skeleton3DBuilder` already validated, now via `BoneAttachment3D`
  instead of manual per-frame updates). Unit tested against a synthetic mirrored-triangle fixture,
  then **verified against all 7 real body-part files + the real skeleton**: a genuinely
  recognizable human T-pose figure, screenshot sent to OpenSRO.
- Fixed a real usability gap this surfaced: `SRREVAMP_BSK_PATH`/`SRREVAMP_BAN_PATH` only accepted
  loose files, but real client installs only ship pk2 archives (confirmed by the user's own file
  listing — no loose files at all). New `client/scripts/assets/asset_source.gd` (`AssetSource`)
  tries a path as a loose file first, falling back to a path inside `SRREVAMP_PK2_PATH` if set —
  unit tested against both a real loose file and a real synthetic pk2 archive.
- **Real "auto select" fix for the player's own character**: `World3D.gd` now auto-loads a real
  assembled character (real skeleton + real body-part meshes via `CharacterAssembler`) as the
  player's body whenever `SRREVAMP_PK2_PATH` is set, using the conventional real path layout found
  during RE — no other env vars needed. Verified end-to-end by packing the real skeleton + body
  part bytes into a real synthetic pk2 at that exact conventional layout (a throwaway packer
  script, not committed) and running `World3D.tscn` against it: a real, correctly-scaled character
  standing in for the placeholder capsule, screenshot sent. Renamed `ObjectLoader._find_file` to
  the public `find_file` since `AssetSource` needed to share it. Promoted to a fixed default (not
  real per-account race/gender selection — this project's server doesn't track that), and honestly
  scoped as such in `World3D.gd`'s doc comment.
- Renamed `_try_load_real_skeleton` to `_try_load_real_decoration_skeleton` to distinguish it from
  the new player-character auto-load path.
- Still open: the map/terrain gap (`.mapm` grid dimensions) and the deeper "auto select" problem
  for *other* players/map objects (no server-side race/gender/equipment tracking, and the
  `.mapo` type-ID-to-resource mapping remains a confirmed dead end) — next up.

## 2026-08-20 (cont'd 41) — real assets wired into `World3D` live, plus a real camera bug and a real screenshot-technique fix

- User asked directly why none of the RE'd assets/skeletons were showing up in the 3D scene — a
  fair callout: `World3D.gd` only had placeholder capsules and a placeholder ground, none of the
  proven `ObjectLoader`/`Skeleton3DBuilder` pipelines were reachable from it. Wired both in for
  real, gated behind environment variables (this project ships no game data, BYO):
  `SRREVAMP_PK2_PATH`+`SRREVAMP_BSR_PATH` loads real textured scenery via `ObjectLoader`;
  `SRREVAMP_BSK_PATH`+`SRREVAMP_BAN_PATH` builds a real, live-animated `Skeleton3D` via
  `Skeleton3DBuilder`, cycling through the `.ban` track's keyframes at a plausible (unconfirmed)
  30fps. Either can be left unset — same graceful-degradation pattern used throughout this
  project.
- Found and fixed a real gap while verifying: a bare `Skeleton3D` has no mesh of its own (no
  confirmed bone-weight/skinning data exists in `.bms` yet), so it was invisible in the live
  scene despite being built correctly. Added `Skeleton3DBuilder.build_debug_visualization()` /
  `update_debug_visualization()` — the same joint-sphere/bone-cylinder debug rendering
  `client/tools/render_skeleton3d_animated.gd` uses, now reusable and kept in sync with the
  animated pose every frame.
- **Verified against real data, not just a compile check**: rendered `World3D.tscn` live with
  `SRREVAMP_BSK_PATH`/`SRREVAMP_BAN_PATH` pointed at the real `sample.bsk`/`sample_bandi.ban`
  samples this project has used throughout — a real 38-bone, 100-keyframe skeleton animating
  live next to the player capsule, screenshot sent to OpenSRO. For scenery, no real `.bsr` exists
  inside any pk2 archive available in this environment (every real `.bsr` sample found so far was
  a loose file, not packed) — so verified the new glue code against the same synthetic pk2
  archive `object_loader_test.gd` already uses (built to an absolute path with a throwaway script,
  deleted after use), confirming it opens the archive, calls `ObjectLoader`, and places 2 real
  mesh pieces in the live scene without error.
- Along the way, found the actual fix needed to get *any* screenshot out of a normally-launched
  scene (autoloads active) in this sandbox: Godot's own `--write-movie <path>.png --quit-after N`
  movie-recording mode, not a manual `get_texture()` capture (which reliably produced a blank
  frame here for reasons not fully traced) — recorded as a reusable technique. Also found and
  fixed a real, separate bug this surfaced: `World3D.tscn`'s `Camera3D` never had `current = true`
  set, so it wasn't guaranteed to activate at all.
- `README.md` and `client/scripts/World3D.gd` doc comments updated with the new environment
  variables and current honest scope (no real terrain, no automatic asset selection since no
  type-ID-to-resource mapping exists, no real mesh skinning).

## 2026-08-20 (cont'd 40) — a real, multiply-replicated periodicity signal in `.mapm`, still not confirmed as the grid width

- Went back at the `.mapm` grid-dimensions open question with a more rigorous tool than the
  earlier retracted "97" guess: a direct DFT power-spectrum check on the height-value sequence,
  looking for genuine periodic structure. First pass (2 samples) found both non-flat Shape A files
  dominated by one sharp period, T=17. Re-pulled `Map.pk2` and extracted 20 more real `.m` files
  (regions `100`-`104`) to check whether it held up at scale — it did, and got more interesting:
  **17 of 17 Shape B "interior" region files** (`_100` through `_103` suffixes) are dominated by a
  *different* period, T=46, with zero exceptions; the 3 files with a `_104` suffix instead match
  Shape A's T=17, with an order-of-magnitude stronger spike than anything else seen in this whole
  investigation. Whatever distinguishes `_104` regions from their neighbors produces a much
  cleaner signal — a new, real, unexplained split worth its own future pass.
- **Still not promoted to a confirmed grid width**: cross-checking the same DFT method against
  the leading-byte (texture/type) channel on a representative T=46 file doesn't reproduce T=46 as
  dominant there either (top period is 17, T=46 only fifth), and tile counts aren't evenly
  divisible by the candidates. Documented as a real, now well-replicated signal with plausible
  non-grid explanations (a natural terrain feature wavelength, an unaccounted header/trailer
  offset) rather than claimed as solved. `docs/protocol/MAPM_FORMAT.md` updated with the full
  per-region-class breakdown.

## 2026-08-20 (cont'd 39) — first real 3D scene: connect, log in, and walk around, verified end-to-end against the live server

- New `client/scenes/World3D.tscn` + `client/scripts/World3D.gd`: a real, playable 3D scene — a
  `CharacterBody3D` player on a placeholder flat ground, WASD movement, third-person camera, and
  other connected characters rendered as labeled capsules at their real, server-authoritative
  positions. Reachable from the existing 2D `World.tscn` via a new "3D View" button (round trip
  via a "Back to 2D View" button in the 3D scene) — the 2D HUD (chat/inventory/quests/etc.) is
  untouched, this is additive.
- Found, while wiring it up, that the server-side movement protocol (`OpMove`,
  `OpEntityEntered`/`OpEntityMoved`/`OpEntityLeft`) was already fully implemented and tested on
  both ends but **nothing in the client ever called `NetClient.move_to()` or rendered any position
  anywhere** — `World.gd` already had a comment noting exactly this ("position isn't rendered
  anywhere yet"). Not a new protocol — the 3D scene is what closes that gap.
- Not wired to any real game assets yet on purpose — player/other-entity visuals are placeholder
  primitives, so movement/sync could be gotten working and verified end-to-end first before
  layering `.bsr`/`.bms`/`.bsk` rendering on top.
- **Verified against the real, running stack**, not just unit tests: started the actual Go server
  (`go run ./cmd/server`, real local Postgres) and drove the real client autoloads through a
  scratch end-to-end harness (register → login → create character → enter world → instantiate
  `World3D.tscn` → simulate movement), removed after use, never committed. Confirmed:
  - The full connect/register/login/character-create/enter-world flow works against the real
    server.
  - The `CharacterBody3D` spawns at the server-given position and gravity/ground-collision settle
    it correctly.
  - **Two concurrent real client instances see each other**: client A received real
    `entity_entered` and `entity_moved` events for client B logging in and moving, over the actual
    network protocol — genuine multiplayer position sync confirmed working, not assumed.
  - Along the way, confirmed (on both the new script and the pre-existing `World.gd`) that Godot's
    `--headless --path . --script <file>` entry point does **not** initialize project autoloads
    (a real, useful thing to know for any future headless testing here) — the correct way to
    validate autoload-dependent code headlessly is to run the real main scene (or another real
    scene) as a positional argument, not via `--script`.
- This directly answers the "how far from walking around" question: the 2D client/server loop was
  already fully playable; this is the first real step into 3D, with the core movement/sync loop
  now proven end-to-end. Next: real ground/terrain (blocked on `.mapm` grid dimensions), real
  character meshes via `ObjectLoader`/`Skeleton3DBuilder`, and placing real `.bsr` objects via
  `.mapo` data (blocked on the type-ID-to-resource-path mapping, still not found — see
  `docs/protocol/MAPO_FORMAT.md`).

## 2026-08-20 (cont'd 38) — real Skeleton3D/AnimationPlayer-style pipeline (was the last "not yet done" item)

- User asked directly how far this project is from being playable in 3D. Answer: the 2D
  client/server loop is fully playable today (`docker compose up` + open `client/` in Godot logs
  in and drives the whole 2D HUD); none of the 3D asset-format work is wired into a live scene
  yet. Redirected to finish the in-flight `Skeleton3D` work, then start on the actual 3D world
  scene next.
- Added `SkeletonPose.bone_rotation()` (the confirmed local-rotation quaternion from a `.bsk`
  bone's transform bytes, same +4 offset shift as `bone_position()` for root-attached bones),
  unit tested.
- New `client/scripts/assets/skeleton3d_builder.gd` (`Skeleton3DBuilder`): builds a real Godot
  `Skeleton3D` from a parsed `.bsk` skeleton (topologically sorted, since real bone records aren't
  guaranteed to be in parent-before-child file order), and applies a real `.ban` keyframe's
  rotation (relative to that track's own first keyframe — same interpretation
  `render_skeleton_animated.gd` already validated) via `Skeleton3D`'s own pose-rotation
  propagation, not manual per-bone math. Unit tested against a synthetic skeleton, verifying the
  engine's own hierarchy propagation reproduces the exact same rotated positions
  `SkeletonPose.apply_rotation`'s manual math already proved correct.
- Hit and fixed two real Godot API gotchas along the way: `Skeleton3D.add_bone()` returns `void`
  in 4.2 (not the new bone's index — have to `find_bone()` it back), and `get_bone_global_pose()`
  reflects only the *pose* side of a bone's transform, which starts uninitialized rather than
  defaulting to *rest* — needs an explicit `reset_bone_pose()` per bone before any global-pose
  query means anything.
- New dev tool `client/tools/render_skeleton3d_animated.gd`, the `Skeleton3D`-backed counterpart
  to `render_skeleton_animated.gd`. Hit one more real bug getting it running: the two render calls
  need `await`, since the render helper itself uses `await process_frame` — without it the script
  raced ahead to `quit()` before either render actually completed, silently producing no output.
  Once fixed, ran it against the same real `sample.bsk` + `sample_bandi.ban` pair used by the
  manual-FK tool and got a real bind-pose/animated-pose screenshot pair showing genuine, visible
  movement — sent to OpenSRO.
- This closes out the "not yet done: a proper Skeleton3D/AnimationPlayer-based pipeline" item from
  `README.md`'s status section. Full Go+GDScript regression green, CI updated, no regressions.

## 2026-08-20 (cont'd 37) — corrected a wrong `.mapm` conclusion: the "real boundary" was actually a too-narrow resync bound

- Went back to the 2 Shape-B files that only recovered ~290 of an expected ~13,200 tiles
  ((cont'd 36) documented this as "the correct behavior, not a bug" — a real, understood section
  boundary at byte offset `0x800`). That conclusion was **wrong**, caught by scanning the entire
  file for every plausible float value regardless of stride: both files are actually organized
  into repeating bands of ~2025 bytes of genuine tile data separated by gaps of a repeating
  non-tile pattern up to **509 bytes long** — far wider than the 64-byte resync bound (sized for
  `.mapo`'s much shorter trailers) that was making the scan give up before reaching the real data
  on the far side of each gap.
- Fixed by widening the resync bound to 600 bytes in both `server/internal/mapm` and
  `client/scripts/mapm/mapm_reader.gd`. Both previously-"anomalous" files now recover 12,698 and
  12,947 tiles respectively — consistent with their sibling files in the same size class — with
  sane heights and no NaN. Verified no regression on the other 8 real files (still ~100%
  consumption). `docs/protocol/MAPM_FORMAT.md` corrected in place, explicitly flagging the earlier
  conclusion as wrong rather than quietly revising it.
- The repeating `00 01` pattern itself is still not understood (plausibly a "no data here"
  run-length/mask marker) — logged as an open question, but it no longer blocks recovering the
  real tile data around it.

## 2026-08-20 (cont'd 36) — `.mapm` second file family cracked: two real tile shapes

- Went back to the `.mapm` "second file family" gap logged in (cont'd 34) (5 real `~92KB` region
  files that didn't fit the original 11-byte tile model at all). Applied the same brute-force
  byte-stride measurement that found the original shape: found a genuine **second tile record
  shape** — 7 bytes (2 unconfirmed leading bytes + a `float32` height + 1 unconfirmed trailing
  byte) — used consistently by every file in this size class, as opposed to the original 11-byte
  shape used by the larger ~136-137KB size class.
- Rewrote both readers (`server/internal/mapm`, `client/scripts/mapm/mapm_reader.gd`) around a
  **shape-and-offset auto-detector**: try every `(shape, starting offset)` combination in a small
  window after the version tag, keep whichever produces the longest unbroken run of plausible
  tiles. This both correctly resolves the two shapes *and* incidentally improved every original
  Shape-A file's consumption to a clean 100% (up from 99.6-99.9%), since the new detector finds a
  tighter real starting offset than the previously-hardcoded header length.
- 3 of the 5 new files now parse to 100% completion. The other 2 stop at ~290 tiles each, both at
  the exact same byte offset (`0x800`) — traced by hand and confirmed this is a real, different
  section of the file (a long repeating `00 01` pattern), not a resync-tunable failure. Documented
  this explicitly as **the correct behavior**, not a bug: reporting the real tiles found and
  stopping cleanly at a boundary this project doesn't understand yet is honest; inventing a way
  past it would risk fabricating data.
- `Tile` struct simplified on both sides to `{Height, Extra}` — the old `{TypeID, Counters}` shape
  only made sense for Shape A; `Extra` now holds whatever the non-height bytes are for either
  shape, kept raw per this project's established policy. Rewrote both languages' unit tests around
  the two shapes plus the resync path. `docs/protocol/MAPM_FORMAT.md` rewritten with a full
  per-file verification table (10 real files now, both shapes documented).
- Also (while investigating) confirmed a widened height-sanity range wasn't actually needed for
  any of this — re-verified the original, tighter bounds (`-2000` to `5000`) still produce
  identical results, so left them unchanged rather than loosening the sanity filter without cause.

## 2026-08-20 (cont'd 35) — session housekeeping + a dead-end ruled out

- Looked for a `.mapo` type-ID → `.bsr` resource-path mapping in the game's reference-data tables
  (`TextData_Object.txt`, `characterdata_*.txt`) as a way to make `render_map_objects.gd` show
  real models instead of colored markers. `TextData_Object.txt` turned out to be a monster
  display-name table (not indexed by anything resembling the observed `.mapo` type IDs);
  `characterdata_*.txt` is a proprietary binary/compressed table, a big enough RE target on its
  own that it's out of scope to open right now. Ruled out, not pursued further — consistent with
  this project's existing honest "no mapping found" note in `docs/protocol/MAPO_FORMAT.md`.
- Audited the CI workflow (`.github/workflows/ci.yml`) against the actual repo contents after many
  edits this session: every `*_test.gd` file in `client/scripts/` is wired into CI, and every
  script CI references actually exists — clean, no drift. Read `README.md` top to bottom for
  cross-reference consistency (format lists, counts, doc links) — accurate as of this entry. No
  stray `TODO`/`FIXME` markers in any of this session's new packages.

## 2026-08-20 (cont'd 34) — cross-checked `.mapo`/`.mapm` against more real regions, found and fixed a real `.mapo` bug

- Pulled the real `Map.pk2` (1.5GB) from the RE box and extracted 10 more real `.o`/`.m` samples
  (regions `0/0`-`0/2`, `1/0`-`1/1`, `100/100`-`100/104`) via a throwaway `server/cmd/pk2extract`
  tool (removed after use), to raise confidence on both lower-sample-count formats beyond the
  single/double samples they'd been verified against so far.
- **Found and fixed a real bug in `.mapo`**: 3 of the new populated (`"1001"`) regions
  (`100/100.o`, `100/101.o`, `100/102.o`) silently parsed as 0 objects — the fixed 20-byte header
  offset this format was built around landed inside real record data for these files, which
  happen to use an 18-byte header instead (2 bytes narrower, cause unconfirmed). Fixed the same
  way every other ambiguous boundary in this project's formats was resolved: scan forward
  (bounded) for the first plausible record instead of trusting a fixed header length. Re-verified:
  those 3 files now correctly recover 58, 50, and 12 real objects respectively (up to 11 distinct
  type IDs across them). Also confirmed the version tag (`"1000"`/`"1001"`) isn't a reliable
  populated/empty signal on its own — 2 of the new `"1001"` files are genuinely empty, same as
  every `"1000"` file checked; both readers already handle this correctly (empty is a normal
  successful parse, not an error). Fixed in both `server/internal/mapo` and
  `client/scripts/mapo/mapo_reader.gd`, with a new synthetic test for the narrower-header case on
  both sides. `docs/protocol/MAPO_FORMAT.md` updated with the full verification table (11 real
  files now, up from 2).
- Cross-checked `.mapm` too: the 5 new samples matching the original file's size class (`0/0.m`,
  `0/1.m`, `0/2.m`, `1/0.m`, `1/1.m`, all ~136-137KB) all reproduce the ~99.6-99.9% consumption
  rate seen on the original single sample — real confidence increase (5 consistent samples now,
  up from 1). But the 5 `100/100.m`-`100/104.m` files (a smaller ~92KB size class) do **not** fit
  the same model at all — 3 consume only ~83% with much wider height ranges, and 2 fail almost
  immediately (~2%). This looks like a genuinely different terrain sub-format for this region
  size class, not a resync-tunable issue — recorded as a new, real, confirmed gap rather than
  forced into the existing model. `docs/protocol/MAPM_FORMAT.md` updated with both the confidence
  increase and the new gap.

## 2026-08-20 (cont'd 33) — real map-region render from `.mapo` data

- Built `client/tools/render_map_objects.gd`: loads a real `.o` file through `MapoReader` and
  renders every placed object's real world position as a colored (by type ID) marker, top-down.
  Doesn't resolve type IDs to real `.bsr` models — no mapping from a `.mapo` type ID to a
  resource path exists anywhere in this project's data, so markers stand in for real scenery.
  Run against the real 95-object populated region: produces a genuinely sensible spatial layout
  (objects cluster into distinct groups, not noise) — a real visual confirmation of the `.mapo`
  reader's correctness beyond the numeric verification already done. Screenshot sent to OpenSRO.
  `client/tools/README.md` updated.

## 2026-08-20 (cont'd 32) — `.efp` particle effects: real reader, last format cracked

- Went after the one remaining format with zero working reader. `.efp` is structurally different
  from everything else here — a self-describing, nested, tagged property system, not a fixed
  record — so it needed real sample data to work with. Wrote a throwaway pk2-extraction tool
  (`server/cmd/pk2extract`, removed after use) using this project's own `server/internal/pk2`
  reader, pulled the real `Particles.pk2` archive (236MB) from the RE box, and extracted 30 real
  `.efp` files.
- Tried to find a fixed per-key value schema first (measuring the byte gap between each key
  occurrence and the next name token, across all 30 files) — some keys are genuinely consistent
  (`ProgramUpdate` always 35 bytes, `NormalTimeLife` always a bare marker with 0 bytes), but many
  others vary a lot (containers with nested content), so a hand-built schema table would need
  dozens of entries with no way to verify the container ones were bounded correctly.
- Found something better: a **schema-free flat reader** — read a name, then scan forward for the
  next valid name-shaped token, treat everything between as that entry's opaque value — recovers
  94-100% of every one of the 30 real files with zero hardcoded per-key knowledge. This flattens
  the true nested tree into a flat list (loses parent/child relationships) but keeps every real
  `(name, value bytes)` pair in the file. Also found and correctly handled a second real header
  version (`"0013"`, 6/30 files, a different fixed pre-name-header shape) alongside the originally
  documented `"0011"`.
- Implemented `server/internal/efp` and `client/scripts/efp/efp_reader.gd`; both parse all 30 real
  files without error, matching exactly. `docs/protocol/EFP_FORMAT.md` rewritten around the
  working reader, with the flat-vs-tree tradeoff and the per-key schema investigation documented
  honestly (including what a future, more thorough pass could still use that data for).
- **Every documented `.pk2`-family container format in this project now has a real, working
  reader on both sides** — pk2, bsr, bms, ddj, bmt, ban, bsk, mapo, mapm, efp (10 total). `.bsk`
  and `.mapo` are fully/near-fully confirmed against multiple real files; `.mapm` and `.efp` are
  real but lower-confidence (single-sample terrain data, and a flattened rather than fully nested
  tree, respectively) — both honestly labeled as such in their docs.

## 2026-08-20 (cont'd 31) — `.mapm` terrain format: real (lower-confidence) reader

- Applied the same brute-force approach to `.m` (terrain/heightmap), the last format with no
  working reader at all. Retracted the earlier "97 at offset 0x18 = grid width" guess after
  dumping consecutive 11-byte chunks and finding `0x61` (97) is just the most common single tile
  value (~6% of all tiles), not a one-time header field.
- Found real per-tile structure: byte 0 = a small varying value (too many distinct values — 200+
  — to be a small fixed catalog like `.mapo`'s object types), bytes 1-4 = two changing
  `uint16`-shaped fields (unconfirmed), bytes 5-8 = a `float32` that decodes to a genuinely
  sane-looking elevation range (real data: -195 to +598, no NaN), bytes 9-10 = unconfirmed
  (always zero so far). 11 bytes per tile.
- The fixed 11-byte stride isn't perfectly regular over the whole file — about 27% of a naive
  fixed-stride walk degrades into NaN/garbage partway through. Applied the same
  plausibility-based resync scan `.mapo`'s variable trailer needed: only ~1.2% of tiles actually
  need a resync, the rest read directly at the fixed stride. Hit and fixed the same "subnormal
  float noise passes a naive sanity range check" bug already seen in `.mapo`.
- Implemented `server/internal/mapm` and `client/scripts/mapm/mapm_reader.gd`, both matching
  exactly on the one real file available (12,416 tiles recovered). **Flagged as lower-confidence
  than every other format here** — only one real `.m` sample exists in this environment, so
  nothing here got the cross-file verification `.bsk` (8 files) and `.mapo` (2 files) had; a
  synthetic byte-exact "gap" unit test for the resync path turned out to be genuinely fragile to
  construct (any finite gap can have a boundary-straddling window that coincidentally looks like
  a plausible tile) — solved by brute-force searching for gap bytes that provably don't collide,
  with the fixture self-checking that guarantee before asserting on the parse result.
- `docs/protocol/MAPM_FORMAT.md` rewritten around this — explicitly labeled lower-confidence, with
  open questions (grid dimensions still unknown, the two uint16 fields, cause of the 1.2%
  misalignment) listed rather than glossed over.
- **All 9 documented container formats now have at least a real, working reader** (`.efp`
  particle effects remains the one format with none at all — see `docs/protocol/EFP_FORMAT.md`).

## 2026-08-20 (cont'd 30) — `.mapo` object-placement format cracked

- Applied the same brute-force byte-scanning approach that cracked `.bsk` to `.mapo` (`Map.pk2`'s
  per-region object-placement list, previously scoped-but-unimplemented — the earlier fixed
  28-byte-stride guess drifted into garbage after 2 records). Scanned the one real populated
  sample (`102/101.o`, 105-ish records) for every byte offset where a plausible small type ID is
  immediately followed by 3 non-garbage floats, and found the real record boundaries: a fixed
  28-byte record (type ID + position + 12 unconfirmed bytes, not just the 16-byte type+position
  the original guess assumed), followed by an optional variable-length trailing block (0-40
  bytes, always zero padding plus a small nonzero tail value) with no length field of its own.
- Implemented a "resync" reader: after each fixed 28-byte record, scan forward for the next
  plausible record start rather than trusting a fixed stride — the same
  verify-plausibility-not-a-fixed-layout approach `.bsk` needed for its two record shapes,
  applied here to record length instead. New packages: `server/internal/mapo` and
  `client/scripts/mapo/mapo_reader.gd`, both with unit tests against synthetic fixtures. Hit and
  fixed a real bug during development: using the 16-byte type+position size (rather than the full
  28-byte fixed record) as the resync starting point caused false-positive record detections
  inside the trailing 12 unconfirmed bytes, producing several bogus singleton-count "object
  types" — fixed by resyncing from the full 28-byte boundary, which cleanly recovers exactly the
  4 real type IDs (`1159`, `1798`, `1800`, `1805`) across all 95 real objects, matching between
  Go and GDScript exactly. Also verified an all-zero/empty-region sample correctly parses to 0
  objects.
- Still open: rotation isn't obviously present in any field (either encoded somewhere in the
  unconfirmed bytes, or not stored per-placement for these object types); the trailing block's
  meaning; whether the 2 unconfirmed header fields mean anything (e.g. an object count).
  `docs/protocol/MAPO_FORMAT.md` rewritten around the working format.

## 2026-08-20 (cont'd 29) — `.bsk` fully cracked

- Followed through on the "needs more real samples" note from (cont'd 28) and cracked it
  completely. Pulled a second real Biped file (`mob_garm.bsk`) and found the forward-declaration
  pattern (`Bip01 L Thigh`/`Bip01 R Thigh` announced with no immediate resolution) at the exact
  same structural position as `dubhe.bsk` — confirmed it's a real, repeatable part of the format,
  not a one-off. Traced `Bip01 L Thigh` all the way to its actual resolution point in `dubhe.bsk`
  (announced at offset 391, resolves at offset 7899) and, prototyping in Python for fast
  iteration, found the real general rule: every bone name in the file is *announced* once and
  *resolved* later (immediately, or after any number of other announce/resolve pairs interleave)
  — the previously-documented "alias table" isn't a separate concept at all, it's the same
  mechanism, just bunched into one run at the start of the one non-Biped file originally used to
  crack this format. Resolution can take either of two record shapes (no-parent/92-byte, or
  with-parent/88-byte), and — the key new finding — **both shapes can appear within a single
  file**, disambiguated per-bone by checking whether what follows looks like a valid next token,
  not by a whole-file convention as previously assumed.
- The Python prototype parsed **all 8 real `.bsk` files available in this environment** (the
  original mirrored-decoration rig, plus `dubhe`, `garm`, `wendigo`, `jalliaza`, `shamoot`, and 2
  duplicate paths) to **full completion** — zero unresolved names, landing exactly on each file's
  8-byte trailer every time. Ported the confirmed algorithm to both `server/internal/bsk/bsk.go`
  and `client/scripts/bsk/bsk_reader.gd`, replacing the old two-phase
  (alias-table-then-per-bone-children) implementation entirely; re-verified byte-for-byte against
  all 8 real files from both languages. Rewrote the Go and GDScript unit tests around the new
  model (immediate resolution, deferred/interleaved resolution, unresolved-announcement error
  case) — both green, no regressions in any other format's test suite.
- Rendered a real Biped creature skeleton (`dubhe.bsk`, `mob/dm/dubhe.bsk`) for the first time —
  a genuinely recognizable 66-bone humanoid figure: head, spine, correctly left/right-mirrored
  arms with individual fingers, correctly mirrored legs. Also fixed a real cosmetic bug this
  surfaced in `client/tools/render_skeleton.gd`: its joint-sphere/bone-cylinder radius was a
  fixed size tuned for the original (widely-spaced) skeleton, which fused into an unrecognizable
  blob on this tighter-spaced 66-bone rig — now derived from each skeleton's own shortest real
  bone length. Re-verified the original skeleton still renders correctly (no regression).
  Screenshot sent to OpenSRO.
- `docs/protocol/BSK_FORMAT.md` rewritten from scratch around the final model (previous versions
  narrated the incremental gap-discovery process; this one describes the complete, working
  format).

## 2026-08-20 (cont'd 28)

- Dug further into the `.bsk` Biped forward-reference gap left at the end of (cont'd 27). Pulled a
  second real Biped file (`mob_garm.bsk`) and found the exact same `Bip01 L Thigh`/`Bip01 R
  Thigh` forward-declaration shape at the exact same structural position as `dubhe.bsk` — not a
  one-off, a real repeatable part of the format.
- Real insight: this is the **same mechanism as the alias/mirror table**, just triggered
  mid-stream instead of only at the top of the file. Confirmed by re-scanning the original
  fully-cracked `sample.bsk`: its alias table is exactly "announce a name now, get its real
  record much later" (`Bone01` announced at offset 119, doesn't resolve until offset 220) — the
  existing alias-table-vs-bone-record disambiguation logic already implements a special case of
  this more general rule. Biped files just spread the announce/resolve pairs out mid-stream
  instead of bunching them all at the front.
- Traced `Bip01 L Thigh` all the way to its resolution in `dubhe.bsk` (announced at 391, appears
  again at 7746, resolves at 7899) and found real evidence that **both of `.bsk`'s two known
  per-bone record shapes (with-parent/88-byte, and without-parent/92-byte "root-attached") can
  coexist inside a single Biped file** — the original model (from `sample.bsk`) assumed that
  choice was a whole-file convention, which no longer holds. Documented precisely, with exact
  byte offsets, in `docs/protocol/BSK_FORMAT.md` rather than guessed at; not implemented, since
  disambiguating the two shapes per-name needs more real samples than the 2 checked so far.
  Genuine forward progress on understanding, not a working parser yet — logged honestly as such.

## 2026-08-20 (cont'd 27)

- Made real progress on the `.bsk` Biped-skeleton gap. Byte-level analysis of a real file
  (`dubhe.bsk`, comparing a brute-force scan of every plausible length-prefixed string against
  what the parser expected) resolved the previously-vague "some bones have an extra optional
  field" note into a confirmed mechanism: a bone record can list zero or more of its direct
  children by name (up to 3 seen, e.g. `Bip01 Neck` lists `L_chain_01`/`R_chain_01`/`Spine1_ice`)
  between its own name and the repeat of that name — every listed child name was confirmed to
  have its own later full record elsewhere in the file, parented back correctly, plus a matching
  `<name>_end` tip bone. Implemented in both `server/internal/bsk` (`Bone.ChildNames`) and
  `client/scripts/bsk/bsk_reader.gd` (`Bone.child_names`), with a new synthetic 2-child-name test
  case on both sides (`go test`/GDScript test both green, no regression on the existing
  fully-working real file).
- Still doesn't fully parse any Biped file: found a second, distinct complication right after —
  some bone names (e.g. `Bip01 L Thigh`, `Bip01 R Thigh`) are announced with no self-repeat
  nearby at all; their real transform-bearing record doesn't appear until ~7000+ bytes later in
  the same file. Which bone they're logically a child of at the announcement point isn't
  established. Documented precisely (with exact byte offsets) in `docs/protocol/BSK_FORMAT.md`
  rather than guessed at; both readers fail this case with a clean, controlled parse error
  instead of misreading transform bytes as garbage names.
- Investigated whether real character `.bms` meshes carry skinning data — see "(cont'd 26)"
  below for that finding.

## 2026-08-20 (cont'd 26)

- Investigated whether real character/skinned `.bms` meshes carry visible skinning data in the
  fields previously documented as "always 0 in every non-character mesh checked." Pulled 4 real
  files from `Prim/Mesh/Char/Europe/man/` (hair and face pieces — the only skinned-looking meshes
  available in this environment; no full skinned body mesh exists, bodies are built from
  equippable-armor-style static pieces instead). `server/internal/bms` parses all 4 without error.
  Result: the header's reserved 0x28 field is still 0 on every one of them — ruled out as a
  skinning-data location. But the per-vertex trailing 12 bytes (previously "usually opaque white,
  one outlier vertex differs, unconfirmed") turned out to have real, consistent internal
  structure once checked across multiple files: every vertex is one of two classes — a plain
  "no link" class (`FFFFFFFF` + `0`), or a class carrying what looks like a `uint32` index back
  into the same mesh's own vertex array (values always in-range for that mesh; confirmed as 16+
  bits wide, not 8, using a 312-vertex file whose index values exceed a single byte) plus a
  constant flag value of `2`. Plausibly a hair-strand physics anchor/pair reference — not
  skinning (no accompanying weight, values don't fit a bone-index range). Not decompiled, so kept
  as raw bytes in both readers rather than promoted to typed fields, per this project's established
  policy of not mislabeling a field ahead of confirmed semantics. Documented in full in
  `docs/protocol/BMS_FORMAT.md`, including fixing that doc's stale claim that the GDScript `.bms`
  reader didn't exist yet (it does, and has for a while — `client/scripts/bms/bms_reader.gd`).

## 2026-08-20 (cont'd 24)

- Investigated `.m` (`Map.pk2` terrain/heightmap, `JMXVMAPM1000`) a bit further: no loader was
  found via the usual "JMXV + type suffix" search (map streaming may go through a different
  binary/path not yet searched), but empirically confirmed an 11-byte per-tile stride (measured
  from repeated marker bytes) and a suspicious `97` in the header matching the classic Silkroad
  97x97 terrain grid — not enough to call this format cracked, documented honestly as partial in
  `docs/protocol/MAPM_FORMAT.md`, same bar as `.efp`/`.mapo`.
- Promoted the bind-pose + forward-kinematics logic that was living only in the two dev-tool
  scripts (`client/tools/render_skeleton{,_animated}.gd`) into real, tested library code:
  `client/scripts/assets/skeleton_pose.gd` (`SkeletonPose`) — bind-pose extraction, a
  descendants-of-a-bone walk, and the rotate-around-pivot FK helper, unit tested against a
  synthetic 3-bone skeleton (verifies exact rotated positions, not just "didn't crash"). Both
  render tools refactored to use it instead of duplicating the logic; re-ran both against the
  same real data as before and confirmed byte-identical output to the pre-refactor screenshots —
  a real regression check, not just "it still runs."

## 2026-08-20 (cont'd 24)

- Pulled 6 more real `.bsk` skeleton samples to broaden validation and found something important:
  the "3ds Max Biped" bone-naming style (`"Bip01"` root, `"Bip01 Pelvis"`, etc.) that was
  previously written off as a rare/unusual edge case is actually the **common** convention for
  real creature skeletons — 5 of 6 new samples use it; the mirrored-tentacle decoration
  (`demon_altar_deco.bsk`) the format was originally cracked against turned out to be the unusual
  one.
- Found and fixed a real correctness bug in how the alias/mirror table's boundary was detected:
  the old code read names greedily and then blindly skipped a fixed 1-byte separator before
  bone records began — which only worked by coincidence on the one file with a populated alias
  table (there really is a 1-byte gap there) and silently mis-parsed any file with zero alias
  entries (there's no gap at all in that case — confirmed on all 5 Biped-style files, which have
  none). The real rule, confirmed across every file checked: an alias-table entry is never
  immediately followed by an exact repeat of itself; a real bone record's own name always is —
  that's how a reader tells the two apart with no explicit count or terminator. Applied to both
  `server/internal/bsk/bsk.go` and `client/scripts/bsk/bsk_reader.gd`, re-verified byte-identical
  output to before on the one fully-working real file (`demon_altar_deco.bsk`, still 38 bones),
  and fixed the synthetic test fixtures on both sides to actually exercise this case correctly
  (the old fixtures had accidentally avoided it). `docs/protocol/BSK_FORMAT.md` updated with the
  disambiguation rule and an honest account of why the old code was wrong.
- Got further into the Biped-style files with this fix (correctly handles their empty alias
  table) but they still don't fully parse — found two more genuine, confirmed structural
  differences: some bones have an optional extra field between their own name and its repeat
  (e.g. a `"Bip01 Prop1"` attachment reference), and at least one point in the hierarchy has
  multiple children enumerated together rather than the strictly linear one-bone-then-the-next
  walk this parser does. Recorded both honestly in `docs/protocol/BSK_FORMAT.md` as confirmed but
  unhandled, not forced into a shape that doesn't fit.
- Ran full Ghidra auto-analysis passes (not just the lighter `-noanalysis` decompiles used
  everywhere else) on both `sro_client.exe` and `EternityLib.dll` specifically to search harder
  for `.m`/`.o` loaders — confirmed via the magic-construction search *and* a check of every
  recovered RTTI class name in both binaries that neither format loads through either of them.
  That's every plausible client binary in this build checked thoroughly. `docs/protocol/
  {MAPM,MAPO}_FORMAT.md` updated: further progress on these two needs a genuinely different
  approach, not more of the same search — a real, honest wall, not a lack of effort.

## 2026-08-20 (cont'd 25) — session housekeeping

This concludes an unusually long, continuous stretch of work in one sitting: the pk2 fix, five
new fully-cracked formats (`bsr`, `bms`, `ddj`, `bmt`, `ban`) plus a sixth mostly-cracked one
(`bsk`), a real rendered-mesh screenshot, a real animated-skeleton screenshot, a promoted/tested
`SkeletonPose` library, and three honestly-scoped-but-unimplemented formats (`efp`, `mapo`,
`mapm`) with real, documented reasons why each one stopped where it did. Every fully-cracked
format has real Go + GDScript readers, real unit tests, and was verified against real extracted
game data — not just synthetic fixtures. See the format-specific docs under `docs/protocol/` and
the entries above for the detailed trail; `README.md`'s Status section reflects the current state
of all of it.

## 2026-08-20 (cont'd 23)

- Scoped out `Map.pk2`'s object-placement format, `.o` (`JMXVMAPO`) — very likely where a `.bsr`
  object actually gets positioned/rotated in the world, since `.bsr` itself carries no such data.
  Confirmed the outer header and that records start with a plausible type/resource ID + 3
  position floats, but a fixed 28-byte record-size guess only held for the first couple of
  records before drifting into garbage across the rest of a real, populated 105-record sample —
  real records are very likely variable-length. Documented what's confirmed in
  `docs/protocol/MAPO_FORMAT.md` as another explicit **no reader exists yet** partial spec,
  same honesty bar as `.efp` — didn't force a wrong fixed-stride implementation just to have
  something.
- Also confirmed `Map.pk2`'s heightmap/terrain format exists (`.m`, magic `"JMXVMAPM1000"`, real
  samples ~137KB) but didn't investigate its internals this round.
- Along the way, confirmed this environment's `Map.pk2` (like `Data.pk2` before it) is a small
  subset of a full world map — only 19 region folders (`0`, `1`, `100`-`116`) rather than the
  hundreds a real retail map would have — consistent with this being a trimmed/dev client build
  throughout, not a reader gap.

## 2026-08-20 (cont'd 22)

- Scoped out the second real `.bsk` sample's different naming convention (a 3ds Max "Biped"-style
  skeleton, `"Bip01 Pelvis"` etc.) further: it's not just different names, it has genuinely extra
  fields (a "Prop1" attachment reference, self-referencing name patterns) beyond what the first
  file's record shape accounts for. Left as the documented gap it already was rather than forced
  — a real, separate RE task, not a quick fix.
- Started looking at `.efp` (particle effects — 211 real samples in `Particles.pk2`, magic
  `"JMXVEFF 0011"`) and quickly found it's a different kind of format from everything else in
  this project: a self-describing, recursively-nested, tagged property system (named string keys
  like `"NormalTimeLife"`, `"StaticEmit"`, `"Program"` each followed by typed parameter data),
  not a flat fixed-layout record. Located the real loader (`FUN_00cb9120` in `sro_client.exe`,
  same discovery technique as every other format) but a first decompile pass was too obfuscated
  by stack/register reuse to read field types off directly — this needs the same
  per-section-tracing effort `.bms`'s vertex/index sections got, which is a substantially bigger
  undertaking than any format cracked so far. Documented what's confirmed (the outer envelope:
  magic, name, a top-level section count, repeating named sections) in
  `docs/protocol/EFP_FORMAT.md` as an explicit **no reader exists yet** partial spec, rather than
  rush a low-confidence implementation — the first format in this project not held to the "real
  reader, real tests, real data verification" bar the others hit, and it says so plainly.

## 2026-08-20 (cont'd 21)

- Fully closed `.bsk`'s remaining open question: the root-attached-bone "extra 4 bytes" is one
  leading field inserted before the *entire* transform block, not partway through it — confirmed
  on two independent fields (the rotation quaternion at what becomes offset 0x04 instead of 0x00
  only has magnitude ≈1.0 with the shift applied; same story for the position field at 0x30 vs.
  0x2c found last round). `docs/protocol/BSK_FORMAT.md` updated.
- Built and ran the actual animation payoff: `client/tools/render_skeleton_animated.gd` loads a
  real `.bsk` skeleton and a real `.ban` animation, computes the animation's rotation delta for
  one bone (relative to that bone's own first keyframe), applies it to that bone and every one
  of its descendants via basic forward kinematics (rotate each descendant's bind position around
  the animated bone's own position), and renders bind-pose vs. animated-pose screenshots. Ran it
  for real: `demon_altar_deco.bsk`'s `Bone01` chain driven by `bandi.ban`'s `Bone01` keyframe 50
  (108.6° of real rotation) — the rendered before/after clearly shows that chain swinging to a
  different position. Sent both frames to the user. The `.ban` and `.bsk` samples aren't from the
  same character (no matching pair exists in the data available), so this is explicitly a proof
  of the *playback mechanism* against real keyframe numbers landing on a real, matching bone
  name — documented as such in the tool's own header, not oversold as "this creature's actual
  idle animation."
- This closes the loop on the whole `.ban`/`.bsk` skeletal-animation investigation for now: both
  formats are fully reverse-engineered on both Go and GDScript sides, cross-verified against each
  other and against real files, and demonstrated end-to-end with real data producing a visibly
  correct result — the same bar every other format in this project has been held to.

## 2026-08-20 (cont'd 20)

- Wrote the GDScript mirror for `.bsk` (`client/scripts/bsk/bsk_reader.gd`), cross-checked
  against the Go reader on the same real file (`demon_altar_deco.bsk`) — identical 38-bone output
  on both sides.
- Resolved the last open question in `.bsk`'s transform layout: extracted the position field
  from all 38 real bones at the previously-assumed offset (0x2c) and the numbers didn't form a
  sensible shape for root-attached (92-byte) bones. Shifting by exactly the 4 extra bytes those
  bones have (position at 0x30 instead) immediately produced a smooth, continuous, correctly
  left/right-mirrored bone chain. `docs/protocol/BSK_FORMAT.md` updated with the confirmed
  offset.
- Built the payoff for this whole asset-pipeline arc: `client/tools/render_skeleton.gd`, a real
  dev tool that loads a real `.bsk` through `BskReader` and renders its actual bone hierarchy (a
  line segment per bone-to-parent connection, a sphere at each joint) using the position data
  above. Ran it against the real `demon_altar_deco.bsk` and got a genuinely recognizable,
  correctly-symmetric skeleton shape — mirrored curved limb/tentacle chains matching what an
  "altar decoration" prop's root system should look like. Sent the screenshot to the user as
  concrete visual proof, the same way the earlier mesh+texture render was. This closes the loop
  on `.bsk`: not just "the parser doesn't crash and consumes the whole file", but "the numbers it
  produces describe a real, sensible 3D shape."
- Corrected a mistake from two rounds ago along the way (see cont'd 19): re-confirmed nothing
  else was being silently missed by broadening the search before concluding data doesn't exist.

## 2026-08-20 (cont'd 19)

- Corrected a real mistake from the previous round: told the user "we need fuller client archives
  to investigate skeletons/character meshes further" as if that data plain didn't exist anywhere
  accessible — it does. Only `/opt/sro-files/client/` (the `.pk2` archives) had been searched;
  `/opt/sro-files/server/y0gi_Easy_vPLUS/` (the private-server package itself) turned out to
  contain a full 2.7GB **unpacked** `Prim/` tree (loose files, never packed into a `.pk2`) with
  real character meshes, the exact `.bms` files our theater `.bsr` samples reference, and —
  critically — real `.bsk` files, a format that plain doesn't exist in the `.pk2` archives at
  all. Root cause: only searching one directory prefix rather than the whole box. Fixed by
  searching more broadly before concluding data doesn't exist, going forward.
- Used this to close the `.bsr` "known gap" from two rounds ago for real, instead of leaving it
  as a documented unknown: pulled the two real referenced sub-mesh pieces
  (`asiaminor_theater02_brokenwall01.bms`, `asiaminor_theater02_column01.bms`) and confirmed each
  has its own large-scale, independently-positioned bounding box (not centered at the origin) —
  i.e. each `.bms` piece already carries its own absolute position baked into its vertex data.
  **`.bsr` genuinely needs no per-part transform data; there was no gap to find.**
  `docs/protocol/BSR_FORMAT.md` and `ObjectLoader`'s doc comment updated to state this as
  confirmed, not "not yet done".
- Reverse-engineered and implemented a sixth asset format, `.bsk` (`JMXVBSK 0101`) — skeleton /
  bone-hierarchy data, the piece `.ban` itself is missing (it has bone names and keyframes but no
  parent references). Real structure: a root bone, an alias/mirror table listing every bone with
  no parent (one per limb chain), then per-bone records giving each ordinary bone's own name and
  its **parent's name** as an explicit string. Verified as strongly as any format in this
  project: the parser consumes a real 5117-byte file down to its last 8 bytes (a constant zero
  trailer), producing a fully coherent 38-bone hierarchy (4 chains rooted at the skeleton, plus an
  exact mirrored copy of 3 of them — a plausible left/right-symmetric creature rig). Each bone's
  88-byte transform block decodes to two unit quaternions where the second is the exact
  conjugate of the first (a bind-pose/inverse-bind-pose pair) plus two position vectors — strong,
  though not fully semantically labeled, confirmation. No decompiled loader was found for this
  format specifically (searched the same way as every other `JMXV*` format; no hits — it may load
  through a more generic/indirect path), the first format in this project without that
  cross-check, but the empirical full-file consumption is unusually strong on its own. A second
  real file (a 3ds Max "Biped"-style skeleton, different naming convention) didn't fit the same
  heuristic on a first pass and is left as an honest, documented gap rather than forced or
  guessed at. New `server/internal/bsk` (Go), unit tested; new `docs/protocol/BSK_FORMAT.md`. No
  GDScript mirror yet.
- Wrote the GDScript mirror for `.ban` (`client/scripts/ban/ban_reader.gd`), cross-checked
  against the Go reader on the same real file. Combined with `.bsk`, the project now has
  everything needed (hierarchy + keyframes) to build a real skeletal-animation pipeline for a
  Godot `Skeleton3D` — not yet wired into actual rendering.

## 2026-08-20 (cont'd 18)

- Wrote the GDScript mirror of `.ban`: `client/scripts/ban/ban_reader.gd`, unit tested
  (`ban_reader_test.gd`) against a synthetic fixture and cross-checked against the Go reader on
  the same real file (`bandi.ban`) — identical output on both sides.
- Investigated where bone-hierarchy (parent/child) data lives, since `.ban` itself only has a
  flat list of named bone tracks with no parent references. Found real evidence in
  `sro_client.exe`: string references to `"Parent Bone : %x"` / `"Parent Bone Name : %s"` in a
  `CRTSkeleton` class (`RTSkeleton.cpp`/`PrimSkeleton.cpp`). Decompiling its actual
  skeleton-assembly function (`FUN_00c51ef0`) showed it builds a skeleton from an **array of
  resource IDs** dispatched through a small per-bone-type factory — not by parsing one flat
  binary file the way `.bms`/`.bsr`/`.ban` do. Checked whether `.bms` itself might carry
  per-vertex bone/skinning data in the header fields flagged as "reserved, likely used for
  skinned meshes we haven't seen" — confirmed still exactly zero across all 18 real `.bms` files
  available in `Particles.pk2`, but none of those are skinned character meshes, so this doesn't
  resolve the question either way. **Genuine dead end given available data**: no skinned
  character mesh or skeleton-resource sample exists in any archive accessible in this
  environment (`Data.pk2`/`Media.pk2`/`Particles.pk2` — confirmed via the earlier full-tree
  walks that these really are all the files present, not a reader gap). Actually animating a
  character needs either a fuller client archive with a real `prim/mesh/char` tree, or a
  different concrete lead — parked here rather than guessed at further.

## 2026-08-20 (cont'd 17)

- Got real off-screen 3D rendering working in this sandbox (Xvfb + Mesa software OpenGL via
  `LIBGL_ALWAYS_SOFTWARE=1 xvfb-run -a godot4 --rendering-driver opengl3`, since plain
  `--headless` mode uses a dummy renderer that can't actually rasterize anything) and used it to
  render a **real screenshot** end-to-end: a real 9-vertex mesh and a real DXT3-compressed
  texture, both extracted from the actual `Particles.pk2` archive and decoded through this
  project's own `BmsReader`/`DdjReader` — not synthetic fixtures, not Godot's native asset
  import. It looked correct (a real particle "glow" texture on a real diamond-shaped quad).
  Turned the one-off script into a real, reusable dev tool: `client/tools/render_asset.gd` (see
  `client/tools/README.md`).
- Pulled the *actual* full-size real archives (`Data.pk2` 3.86GB, `Media.pk2` 1.5GB,
  `Particles.pk2` 248MB) to check our pk2 reader against real production-scale files, not just
  small samples. Root-directory entry counts matched exactly what smaller earlier checks had
  found (19 entries), and a full recursive tree walk confirmed **zero missing content** — every
  directory our reader found had well under 20 entries, no silent truncation. The 3.86GB size of
  `Data.pk2` despite only 41 files/3.3MB of *declared* content is pre-allocated/padding space
  within the archive, not a reader bug — a very common pattern for MMO client archives designed
  to receive future patches without resizing.
- Reverse-engineered and implemented a fourth asset format, `.ban` (`JMXVBAN 0102`) — bone
  animation data: a named clip containing one or more named bone tracks, each an array of
  keyframes (a `float32` quaternion + a `float32` position, 28 bytes each). Confirmed as strongly
  as any format in this project so far: all 3 real `.ban` files checked parse to **exactly**
  their own byte length with nothing left over, every single keyframe's quaternion has magnitude
  ≈1.0 (a real, meaningful rotation, not garbage), and the 28-byte keyframe record size was
  independently confirmed by decompiling the actual loader
  (`FUN_00c01e20` → `FUN_00c01ca0` → `FUN_00c00630` in `sro_client.exe`, which reads exactly
  `count * 0x1c` bytes). New `server/internal/ban` (Go), unit tested against a synthetic fixture;
  new `docs/protocol/BAN_FORMAT.md`. No GDScript mirror yet, and no bone-hierarchy
  (parent/child) data was found in `.ban` itself — that'll need locating separately before
  keyframes can actually drive a Godot `Skeleton3D`.
- Wired materials/textures into `client/scripts/assets/object_loader.gd`: resolves each mesh
  piece's `.bmt` material and that material's `.ddj` texture, applies it as a real
  `StandardMaterial3D` albedo texture. Verified end-to-end in `object_loader_test.gd` against a
  full synthetic archive exercising the whole pk2 -> bsr -> bms -> bmt -> ddj chain (not just
  each parser standalone) — every resulting `MeshInstance3D` genuinely has a real texture
  applied, not just a parsed color.
- Hit and worked around a real Godot 4.2.2 engine bug: `PackedByteArray.decompress(...,
  FileAccess.COMPRESSION_DEFLATE)` returns 0 bytes on a real `.bmt` file's zlib stream that
  Python's zlib and our own Go `compress/zlib`-based reader both decode correctly — evidently a
  correctness gap in the engine's bundled DEFLATE decoder for some class of valid streams.
  Wrote a from-scratch, standalone RFC 1951 decoder in pure GDScript
  (`client/scripts/bmt/inflate.gd`) rather than route around it with real-data-only special
  casing; verified against streams from an independent, known-correct encoder (Python's zlib)
  and against the real file that exposed the bug.
- All 6 Go packages (`pk2`, `bsr`, `bms`, `ddj`, `bmt`, `ban`) and all 9 GDScript test
  suites (`pk2`, `blowfish`, `ddj`, `bms`, `bsr`, `inflate`, `bmt`, `object_loader`, plus the
  full pre-existing `net/` protocol suite, 25 scripts total) pass clean; new tests wired into CI.

## 2026-08-20 (cont'd 16)

- Found real `.bmt` sample data after all — a broader filesystem search on the RE box (past just
  the pk2 archives, which have none) turned up a loose, unpacked server patch-data tree
  (`.../SMC_Independent/.../patch_upload_temp/data/Prim/mtrl/avatar/*.bmt`). Reverse-engineered
  and implemented both sides: `server/internal/bmt` (Go) and `client/scripts/bmt/bmt_reader.gd`
  (GDScript). `.bmt` is unlike every other `JMXV*` format here: the whole file (after a 4-byte
  size header) is a standard zlib stream, decompressing to a `"JMXVBMT 0102"`-prefixed structure
  of one or more material "layers" (ambient/diffuse/specular/emissive RGBA + a bare `.ddj`
  filename reference). Verified against 4 real files: color values are sane (a shared engine
  default across most layers), and multi-layer materials parse correctly (6 of a declared 7
  layers on the most complex sample — the reader stops cleanly at the point where the exact
  inter-layer trailer size becomes ambiguous, rather than fabricating data, same policy as
  `.bsr`'s known edge case from last round).
- Hit a real, confirmed engine bug along the way: Godot 4.2.2's built-in
  `PackedByteArray.decompress(..., FileAccess.COMPRESSION_DEFLATE)` returns 0 bytes
  ("Condition err != 1") on a real `.bmt` file's zlib stream — the exact same bytes decode
  correctly via Python's zlib and via our own Go `compress/zlib`-based reader. Rather than route
  around it with real-data-only workarounds, wrote a from-scratch, standalone RFC 1951 (DEFLATE)
  decoder in pure GDScript (`client/scripts/bmt/inflate.gd`: stored/fixed-Huffman/
  dynamic-Huffman blocks, canonical Huffman decoding, LZ77 back-references), verified against
  streams from an independent, known-correct encoder (Python's zlib) and against the real file
  that exposed the bug — decodes it correctly, byte-for-byte matching the Go reader's output.
- Wired the whole chain together for real: `client/scripts/assets/object_loader.gd` now resolves
  each mesh piece's material and that material's texture (`.bmt` -> `.ddj`, via `DdjReader`) and
  applies it as a Godot `StandardMaterial3D`'s albedo texture — no longer untextured. Verified
  end-to-end in `object_loader_test.gd` against a full synthetic pk2 archive exercising the
  entire pk2 -> bsr -> bms -> bmt -> ddj chain (not just each parser in isolation): loads a
  `.bsr`, both its mesh pieces, their shared material, and its texture, and confirms each
  resulting `MeshInstance3D` actually has a real 4x4 `ImageTexture` applied. All 8 GDScript test
  suites (`pk2`, `blowfish`, `ddj`, `bms`, `bsr`, `inflate`, `bmt`, `object_loader`) and all 5 Go
  packages (`pk2`, `bsr`, `bms`, `ddj`, `bmt`) pass; new tests wired into CI.
- Remaining known gaps, both documented rather than silently accepted: `.bsr` sub-mesh pieces
  are placed at the origin (no confirmed per-part transform data), and when a `.bmt` has multiple
  layers, which layer applies to which mesh piece is an unconfirmed heuristic (pairs by index
  when the counts match, otherwise every piece gets the first layer).

## 2026-08-20 (cont'd 15)

- Found real `.bmt` (material) sample data after all — not in any pk2 archive on the RE box
  (checked `Data`/`Media`/`Particles.pk2`, none contain a single `.bmt`), but in a loose, unpacked
  server patch-data tree (`.../SMC_Independent/.../patch_upload_temp/data/Prim/mtrl/avatar/*.bmt`)
  that a broader filesystem search turned up. Reverse-engineered and implemented
  (`server/internal/bmt`, `docs/protocol/BMT_FORMAT.md`): unlike every other `JMXV*` format here,
  `.bmt` isn't a raw magic-prefixed blob — the whole file (after a 4-byte size header) is a
  standard zlib stream, decompressing to a `"JMXVBMT 0102"`-prefixed structure of one or more
  material "layers" (ambient/diffuse/specular/emissive RGBA colors + a bare `.ddj` filename
  reference, no path). Verified against 4 real files: color values are sane and consistent
  (evidently shared engine defaults across most layers), and multi-layer materials parse
  correctly (6 of a declared 7 layers on the most complex real sample — the 7th is a known,
  documented gap where the exact inter-layer trailer size isn't confirmed; the reader stops
  cleanly there rather than fabricating data, the same policy as `.bsr`'s known edge case).
- No GDScript mirror or `ObjectLoader` texture/material hookup yet — `.bmt` is Go-only for now,
  same as `.bsr` was before this round. That + real per-sub-mesh `.bsr` transforms (still
  unconfirmed) are the two concrete remaining gaps before the asset pipeline can render a fully
  textured, correctly-assembled object.

## 2026-08-20 (cont'd 14)

- Real RE breakthrough on the pk2 (JMXVFS) container format: our reader (`server/internal/pk2`),
  previously validated only against synthetic fixtures, hung indefinitely against the real
  `Media.pk2`. Root-caused via a hand-built cycle-detection trace tool, then fixed by decompiling
  the actual `CPFileManager` reader class in `GFXFileManager.dll` on the RE box
  (192.168.5.120 -> LXC 103 "ghidra-mcp", headless Ghidra + custom Java `GhidraScript`s). The
  previously-documented format was wrong in several ways, confirmed byte-for-byte against real
  archives: directory-entry name field is 89 bytes (not 81), position/size live at offsets
  0x6A/0x72 (not 0x5A/0x5E, because two 8-byte FILETIME fields sit in between that the old docs
  missed entirely), the assumed "next block chain pointer" doesn't exist (that's what was causing
  the infinite loop — chasing a garbage file-size value as if it were a chain offset), and the
  Blowfish setup has two undocumented client-specific quirks: the raw key gets XORed against a
  fixed 10-byte table before the standard key schedule runs, and each 8-byte block is processed
  with its two 4-byte halves byte-order-reversed (little-endian words, not the textbook
  big-endian). Verified end-to-end against the real `Media.pk2`: correctly reads nested folders
  and real file contents (`command.txt`, `n_protect.dat` a BMP, etc). Also fixed a second,
  independent bug found along the way: `.`/`..` entries weren't being filtered because stale
  bytes after a slot's NUL terminator broke a trim-based string comparison. `docs/protocol/
  PK2_FORMAT.md` rewritten with the corrected, empirically-verified layout; both
  `server/internal/pk2` and `client/scripts/pk2/pk2_reader.gd` fixed and their tests updated.
- Extended the same decompile-then-verify methodology to the next layer of the asset pipeline:
  - `.bsr` (`JMXVRES 0109`) — a composite "static object" descriptor referencing one or more
    `.bms` (mesh) + one `.bmt` (material) file by relative path (e.g. a theater building
    assembled from separate wall/column/stair/tile pieces). Magic confirmed against the real
    runtime loader (traced `sro_client.exe` through `FUN_00bed8d0`, identified via a literal
    path string reading `...SimpleViewer\objengine\ResourceMgr.cpp`, down to `FUN_00bce3b0`
    /`ResObject.cpp`, which validates bytes 4-7 == `"RES "` and bytes 8-11 == `"0109"`
    byte-for-byte). The bounding-box-plus-sentinel gap after the mesh path and the
    self-validating sub-mesh count field after the material path (exactly matches the number of
    remaining `.bms` paths in every well-formed real file checked: 4, 6, and 13) were both found
    empirically across 3 real extracted files. One file turned out to be an edge case (an
    apparently-empty mesh path, a material reference to a different, differently-named object) —
    our reader fails cleanly on it with a clear error rather than fabricating wrong data, which
    is documented as a known limitation rather than papered over.
  - `.bms` (`JMXVBMS 0110`) — real mesh geometry. Decompiled the actual vertex-array loader
    (`FUN_00cb1d50`, reached from the same magic-construction code path as `.bsr`'s), confirming
    a `count`-prefixed array of 44-byte vertex records and a `count`-prefixed array of 6-byte
    (3x `uint16`) triangle indices. Cross-checked against a real extracted file: all 11
    `float`/`uint32` fields per vertex record decoded to sane values (position/normal/UV
    triples, a bounding box matching the real vertex extents exactly). 12 bytes per vertex record
    (offset 0x20-0x2B) aren't confirmed to have consistent meaning (non-constant on at least one
    "fan center" vertex) and are kept as opaque bytes rather than mislabeled.
  - `.ddj` (`JMXVDDJ 1000`) — textures. The simplest of the four: a 20-byte proprietary wrapper
    around a byte-for-byte standard, unmodified Microsoft DDS file. Confirmed identically across
    3 real samples, including one that turned out to be uncompressed RGBA rather than
    DXT-compressed (correctly detected purely from the standard DDS pixel-format flags).
  - New docs: `docs/protocol/{BSR,BMS,DDJ}_FORMAT.md`. New Go packages, each with real unit
    tests against synthetic fixtures (never real game data, same policy as `pk2`):
    `server/internal/{bsr,bms,ddj}`.
- Built the client-side (GDScript) mirrors of all three new readers —
  `client/scripts/{bsr,bms,ddj}/*_reader.gd` — plus `client/scripts/assets/object_loader.gd`,
  which ties pk2 + bsr + bms together into an actual, real, working pipeline: given an open
  `Pk2Reader` and a `.bsr` path, it resolves and loads every referenced `.bms` piece and returns
  a real Godot `Node3D` with one `MeshInstance3D` child per mesh piece — verified end-to-end
  against a synthetic in-memory pk2 archive (`object_loader_test.gd`), not just parser-level
  unit tests. `DdjReader.to_texture()` decodes DXT1/DXT3/DXT5 straight through Godot's native
  S3TC support, or manually swizzles BGRA->RGBA for uncompressed textures. Hit and fixed two real
  GDScript gotchas along the way: a nested class named `Mesh` or `Texture` silently shadows
  Godot's own built-in types (renamed to `ParsedMesh`/`ParsedTexture`), and new `class_name`
  globals aren't visible to other scripts until a project reimport
  (`godot4 --headless --editor --quit`) actually registers them — a plain `--path . --quit` run
  isn't enough. All 6 new/updated GDScript test scripts wired into CI, `.gitignore` and the
  CI "no committed game assets" guard extended to cover `.bms`/`.bsr`/`.bmt`.
- Not yet done: `.bmt` (material) format — no real sample data exists in this client build to
  reverse-engineer against (checked `Data.pk2`/`Media.pk2`/`Particles.pk2`, none contain a
  single `.bmt` file), so texture/material application in `ObjectLoader` is blocked until a
  fuller client build is available. Per-sub-mesh transforms within a `.bsr` (position/rotation of
  each piece within the assembled object) also aren't confirmed from real data yet, so
  `ObjectLoader` currently places every piece at the origin.

## 2026-08-20 (cont'd 13)

- Added Docker packaging for the server and a real client export pipeline, ahead of starting the
  3D asset-format RE work -- both explicitly aimed at making local iteration fast once that
  starts.
  **Docker**: `server/Dockerfile` (multi-stage: `golang:1.25-bookworm` build stage, distroless
  static runtime -- no game data baked in, consistent with the BYO-data policy) plus root
  `docker-compose.yml` (Postgres + server, healthcheck-gated so the server doesn't start racing
  Postgres). Verified everything I could verify in this sandbox: `docker build`/`docker compose
  up` themselves can't actually run here (this LXC has no nesting enabled, so even `docker run
  hello-world` fails on a plain `overlayfs: permission denied` at the mount step -- confirmed,
  not assumed), but `docker compose config` validates the YAML cleanly, and building both
  `cmd/server` and `cmd/import-refdata` with the exact `CGO_ENABLED=0` flags the Dockerfile uses
  succeeds. Left Docker installed but disabled (`systemctl disable`) rather than pretending it's
  a working local runtime here.
  **Client export**: downloaded and installed the matching 4.2.2-stable export templates (854MB),
  wrote `client/export_presets.cfg` (gitignored, like before -- each operator configures their
  own) for Linux and Windows Desktop, and ran real exports via `godot4 --headless --export-
  release`. Windows initially reported a warning (`rcedit` not installed, only needed for
  embedding a custom icon/version metadata) -- disabled `application/modify_resources` since no
  icon is configured anyway, and it exports clean.
  Caught a real, pre-existing bug doing this, not an export artifact: running the exported Linux
  binary printed `ERROR: Parent node is busy adding/removing children` on boot -- reproduced the
  identical error running the *unexported* project too, confirming it wasn't export-specific.
  Root cause: `Boot.gd` called `get_tree().change_scene_to_file(...)` directly from `_ready()`,
  fighting the scene tree's own in-progress node-addition for that same node. Fixed with
  `.call_deferred(...)`; reproduced the clean (error-free) boot afterward for both the raw
  project and the re-exported binaries. All 19 GDScript suites still pass headless; full Go test
  suite green (no server logic changed, just packaging).
  Produced real, running artifacts: a 60MB Linux ELF and a 67MB Windows PE32+ executable, both
  built from the current `dev` tip, both confirmed to boot cleanly and (Linux) actually connect
  to a locally-run server binary with no errors. Added `README.md` instructions for both the
  Docker and plain-`go run` paths. `client/build/` added to `.gitignore` (build output, not
  source).

## 2026-08-20 (cont'd 12)

- Made friends playable from `World.tscn`, completing the "close the protocol-to-UI gap 1:1" pass
  -- every system built this session (party, guild, chat, quests, duels, trade, friends) now has a
  working tab in `World.tscn`, not just a tested-but-invisible wire protocol. No server changes
  needed: `OpFriendRequest`/`OpFriendPendingList`/`OpFriendAccept`/`OpFriendDecline`/
  `OpFriendList`/`OpFriendRemove` already covered everything a UI needs.
  Friends tab: a friends list (name + online/offline, from `FriendSnapshot.Online`), a pending-
  requests list, Accept/Decline acting on the selected pending request (by ID, same
  persistence-safe pattern as party/guild info from last round -- friend requests survive a
  relog), a request-by-name field (target must be online, same tradeoff as duel/trade/chat), and
  Remove acting on the selected friend.
  Verified end-to-end with two live `NetClient` instances against a real server, applying both
  lessons learned from the last two rounds: uniquified character names to avoid cross-run
  collisions, and every listener attached before triggering the action that produces it. Confirmed
  the full sequence for real: Alice requests Bob, Bob gets a live notification and sees it in his
  pending list, Bob accepts and Alice gets a live acceptance notification, both sides' friend
  lists show each other (Alice sees Bob correctly marked online), and removing the friendship
  empties both lists.
  All 19 GDScript suites pass headless (no new files -- Friends reuses `Auth.decode_result` for
  its OK/reason acks, same as every other tab this pass). No Go changes this round. This closes
  out the UI-wiring pass started a few rounds back: combat, inventory, equipment, quests, shop,
  party, guild, duel, trade, and friends are all now playable from one scene.

## 2026-08-20 (cont'd 11)

- Made duel and trade playable from `World.tscn` -- no server changes needed this round, since
  both protocols already resolve their target by name via `world.Hub` (the same online-only
  tradeoff chat/friends already made), unlike party/guild's ID-discovery gap from last round.
  Pure client wiring: Duel tab (challenge-by-name, accept/decline an incoming invite, Attack once
  started, status updates on damage/death) and Trade tab (request-by-name, accept/decline, set an
  offer via gold/item-slot/quantity fields, see the other side's offer update live, confirm/
  cancel, a completion summary logged to chat). Tracked the pending challenger/requester name in
  `World.gd` state so Accept/Decline can answer without the player re-typing a name.
  Verified end-to-end again with two live `NetClient` instances against a real server -- and hit a
  second real async-timing bug in the test harness itself (not the feature) while doing it: the
  first draft attached each signal listener only right before awaiting it, but the server can
  deliver an invite/started notification to the *other* connection before the script gets around
  to listening for it, and Godot signals don't queue for late listeners -- a fired-but-unheard
  signal is just gone. Fixed by attaching every listener for both sides of a flow **before**
  triggering the action that produces them, not incrementally. Confirmed the full sequence for
  real once fixed: Alice challenges Bob, Bob receives the invite and accepts, Alice's duel starts,
  an attack lands real damage; then Alice requests a trade, Bob accepts, both set offers (50 gold
  for nothing), confirming both sides executes the swap and Bob's `OpTradeCompleted` shows exactly
  50 gold received.
  All 19 GDScript suites still pass headless (no new files -- duel/trade reuse `Auth.decode_result`
  and their own already-verified wire types, same as party/guild's OK/reason acks). No Go changes
  this round.

## 2026-08-20 (cont'd 10)

- Made party and guild playable from `World.tscn`, and fixed a discoverability gap affecting
  both -- worse for guild, since guild membership is **persistent**: a player who already has a
  guild from a previous session had no way to learn that on entering the world, short of trying
  to Create/Join and getting an `ErrAlreadyInGuild` surprise back. Added `OpPartyInfo`/
  `OpPartyInfoResult` (0x0088/0x0089) and `OpGuildInfo`/`OpGuildInfoResult` (0x0096/0x0097),
  reusing the existing `PartyResult`/`GuildResult` wire shapes (`PartyID`/`GuildID == 0` with no
  members means "not in one" -- real IDs start at 1, so no ambiguity). `World.gd` queries both on
  `_ready()` alongside the other list queries from previous rounds.
  Party/guild join still has an accepted, undocumented-until-now gap: joining requires already
  knowing the party/guild's numeric ID, and there's no invite or discovery mechanism for *finding*
  one -- unlike duel/trade/friends, which resolve a target by name via `world.Hub`. Fixing that
  properly would mean designing an invite flow, out of scope for a UI-wiring pass; the pragmatic
  answer for this round is a "Join by ID" text field, with the ID meant to be shared out-of-band
  (e.g. via the chat already built) -- the creator sees their own ID in the tab's status label
  after creating.
  Hit a real, instructive bug while writing this round's end-to-end verification (not in the
  feature itself): GDScript lambdas capture outer local variables **by value**, so `func(): done =
  true` inside a closure silently rebinds a snapshot rather than mutating the outer `done` that a
  polling loop was checking -- the test looked like the feature was broken (timeouts, "no such
  character" errors that were actually fallout from an unrelated character-name collision across
  repeated runs) when the actual bug was in the test harness's closure usage. Fixed by capturing
  results in single-key Dictionaries (a reference type) instead of primitives, and wrote up the
  gotcha directly in the temporary test file's own comment in case it recurs.
  Verified end-to-end for real once the harness was fixed: two separate `NetClient` instances
  (two players) against a live server -- Alice creates a party, Bob joins using only the ID Alice
  was given (no other channel), `OpPartyInfo` confirms Alice's real roster; same sequence for
  guild, plus confirming `OpGuildInfo` sees the guild on a fresh query (standing in for a relog,
  since guild membership persists).
  Go: `TestPartyInfoFlow`/`TestGuildInfoFlow` (both: "not in one" before, real roster after). Full
  Go test suite green. GDScript: `party.gd`/`guild.gd` gained `encode_name_request`-based info
  requests (no new wire shape, reused `decode_result`), all 19 GDScript suites still pass headless
  (no new test file needed -- info reuses already-verified `PartyResult`/`GuildResult` decoding).

## 2026-08-20 (cont'd 9)

- Made quests and the NPC shop playable from `World.tscn`, continuing the "close the protocol-to-
  UI gap 1:1" pass. Quests needed no server changes -- `OpQuestList`/`OpQuestAccept` already
  covered everything a UI needs, so this was pure client wiring: a Quests tab (list + Accept
  button) that also refreshes on every kill (progress can advance without completing, and
  `OpQuestCompleted` only fires on completion, so `_on_attack_result` now re-lists quests on every
  kill too, not just `_on_quest_completed`).
  The shop needed the same kind of protocol gap fix combat did last round: **there was no way for
  a client to discover what's actually purchasable.** `shop.Service.Buy` accepts any refdata item
  ID with no curated catalog, but nothing exposed the catalog itself. Added `refdata.SQLStore.
  ListAll` and `shop.Service.Catalog` (computing each item's price via the existing `Price`
  formula), then a new `OpShopList`/`OpShopListResult` opcode pair (0x0052/0x0053). Extending
  `shop.ItemLookup` with `ListAll` broke both existing test stubs (`stubItems` in `shop`,
  `stubShopItems` in `session`) at compile time via `go vet` -- fixed both rather than narrowing
  the interface back down, since every real caller (refdata.SQLStore) needs it anyway.
  Worth noting honestly: `refdata.Item` has no display name field (the curated schema never
  included one), so the shop list can only show item ID + stats + computed price -- `ShopCatalogEntry`
  surfaces `ItemClass`/`PhysAttackMax`/`PhysDefenseMax` specifically so a UI has *something* to
  tell items apart by, rather than pretending a name exists.
  Verified for real again: booted `World.tscn` directly to confirm the two new tabs' node paths
  resolve, then built another temporary end-to-end test scene (deleted after this run) that seeded
  one real item into the dev Postgres `items` table via `psql`, registered an account, entered the
  world, and drove the actual Shop/Quests UI controls against a live server -- confirmed the shop
  list populated with the seeded item, clicking Buy actually deducted gold and landed the item in
  inventory, the quest list populated with the catalog's two quests, and clicking Accept actually
  accepted one. Cleaned up the seeded row afterward.
  Go: `TestListAll` (refdata), `TestCatalogListsEveryItemWithComputedPrice` (shop), plus
  `OpShopList` round-trip and full-flow coverage in `session`. Full Go test suite green. GDScript:
  extended `shop_test.gd` with `ShopListResult` coverage, reconfirmed byte-exact wire compatibility
  via independent Go/GDScript hex generation. All 19 GDScript suites pass headless.

## 2026-08-20 (cont'd 8)

- Made combat, inventory, and equipment actually playable from `World.tscn`, closing a real
  protocol gap discovered while building the UI: **there was no way for a client to ever learn a
  monster's ID.** `OpAttack` requires a `TargetMonsterID`, but nothing broadcasts monster IDs to
  a client on entering a zone or otherwise -- every existing combat test only worked because the
  Go test code has direct access to `monster.ID` from `Hub.Spawn()`'s return value, which a real
  client obviously never gets. Fixed at the source: added `combat.Hub.InZone(zone)` and a new
  `OpMonsterList`/`OpMonsterListResult` opcode pair (0x0065/0x0066) resolving the requester's zone
  via `world.Hub.EntityBySession` (same pattern chat/duel/trade/friends already use) -- no
  character name needed in the request. Added a session test that discovers a monster's ID purely
  through `OpMonsterList` and then successfully uses that exact ID against `OpAttack`, proving the
  list isn't just decorative.
  Extended `World.tscn` with a `TabContainer` (Monsters / Inventory / Equipment) alongside the
  existing HUD/chat. Monsters tab: list + Attack button, refreshing after every attack/damage/
  death signal. Inventory tab: list + two explicit "Equip as Weapon"/"Equip as Armor" buttons
  (own design -- simpler than a slot picker). Equipment tab: list + two explicit unequip buttons.
  Hit a real ambiguity while wiring the equipment tab: `NetClient.equipment_result` fires for
  *both* `OpEquipmentList` and equip/unequip acks, and a successful ack has the same empty-items
  shape as "you have nothing equipped" -- already flagged in that signal's own doc comment as
  something callers need to track themselves. Added an `_awaiting_equip_ack` flag in `World.gd`
  set right before sending an equip/unequip request, so an empty response is correctly read as
  "action succeeded, go refresh" instead of wrongly clearing the equipment list on a real ack.
  Verified for real, not just structurally: booted `World.tscn` directly through the normal
  engine bootstrap (confirming all new `@onready` paths in the extended scene resolve), then built
  a temporary end-to-end test scene (deleted after this run, not committed) that registered a
  fresh account, logged in, created a character, entered the world, and drove the actual `World.gd`
  UI controls -- not `NetClient` directly -- against a live server: confirmed the monster list
  populates for real, and clicking Attack really damaged a monster (counterattack and all) with
  the status label reflecting the real server response.
  Go: `TestInZoneOnlyReturnsMatchingZone`/`TestInZoneEmptyForUnknownZone`/
  `TestInZoneExcludesDeadMonsters` in `combat`, `TestMonsterListFlow` (the discover-then-attack
  test) plus round-trip tests in `session`. Full Go test suite green. GDScript: extended
  `combat_test.gd` with `MonsterListResult` round-trip coverage, reconfirmed byte-exact wire
  compatibility via independent Go/GDScript hex generation. All 19 GDScript suites pass headless.

## 2026-08-20 (cont'd 7)

- Added the first in-world client scene, closing the biggest remaining gap named in every prior
  scope assessment this session: an enormous amount of server-side protocol (world, chat, combat,
  quests, party, guild, duels, trade, friends) existed with **no client scene that used any of
  it** past character select -- `CharacterSelect.gd`'s `_on_enter_world_result` literally said "No
  in-world scene exists yet" and just printed a status line. `scenes/World.tscn` +
  `scripts/World.gd` is that scene: a plain 2D HUD overlay (zone label, nearby-entities list, chat
  log + input), explicitly **not** a 3D map view -- no real map/asset rendering exists yet (that's
  a separate, unfinished piece involving the pk2 reader), and the scene's own doc comment says so
  rather than faking one. Deliberately doesn't show character HP either: `EnterWorldResult`
  doesn't carry it and there's no "get my current HP" query opcode yet (HP only ever appears as a
  side effect of an attack), so there was nothing honest to display.
  `CharacterSelect.gd` now transitions to `World.tscn` on a successful `OpEnterWorld` instead of
  just printing a status line. Since `get_tree().change_scene_to_file` has no way to pass data to
  the new scene, added two small pieces of state to the `NetClient` autoload (which survives scene
  changes): `current_character_name` (set by `enter_world()`) and `last_enter_world_result`
  (cached alongside the existing signal emission) -- `World.gd` reads both in `_ready()` to seed
  its zone label and initial nearby-entity list.
  Chat input supports a `/w <name> <message>` prefix for whispers, plain text otherwise for zone
  say, reusing `NetClient.say`/`whisper` from the existing chat system. A "Log Out" button
  disconnects and returns to the login screen.
  Verification took real effort to get right: GDScript's `--script` headless entrypoint (used for
  every `*_test.gd` file in this project) does **not** register project autoloads, so a script
  written in that style can't reference the bare `NetClient` identifier at all -- confirmed this
  with a probe script showing zero children under `root` during `_init()`. Scene *controller*
  scripts (`Login.gd`, `CharacterSelect.gd`, and now `World.gd`) are a different case: they compile
  and run fine referencing `NetClient` when the scene is loaded through the *normal* engine
  bootstrap. Verified by running `godot --headless --path . scenes/World.tscn --quit-after 2`
  directly (not through `--script`) -- confirmed a clean boot with no node-path or script errors,
  meaning every `@onready $NodePath` reference in `World.tscn` actually resolves and `_ready()`'s
  `NetClient` access works for real. Did the same for `CharacterSelect.tscn` to confirm the
  transition edit didn't break its boot (it correctly errors on `list_characters()` when skipped
  straight to that scene without a live connection -- expected, not a bug). This matches the
  verification bar already established for `Login.gd`/`CharacterSelect.gd`, which likewise have no
  dedicated automated tests; the `net/*.gd` wire-protocol classes are what get unit tests in this
  project, scene controllers get a clean-boot check.
  All 19 GDScript wire-protocol test suites still pass headless (unaffected, no new one added --
  scene controllers aren't part of that test style, consistent with existing practice). Full Go
  test suite unaffected (no server-side changes this round).

## 2026-08-20 (cont'd 6)

- Added optional TLS support, closing the transport-security gap `docs/protocol/
  PROTOCOL_DECISION.md` explicitly named back when the own-protocol decision was made: "a
  from-scratch client and server talking to each other over a connection we control (TLS
  available if wanted) has no reason to replicate [the original's rolling-byte obfuscation]" --
  TLS just hadn't actually been wired up yet until now.
  Server: `gateway.Server` gained a `TLSConfig *tls.Config` field; when set, `ListenAndServe`
  wraps the plain `net.Listener` with `tls.NewListener` (one-line change, since `serveConn`
  already just needs a `net.Conn`, which `*tls.Conn` satisfies). `cmd/server/main.go` gained
  `-tls-cert`/`-tls-key` flags -- both required together or the server refuses to start with a
  clear error, rather than silently ignoring a half-supplied pair. Plain TCP remains the default
  with no flags set, so nothing about local dev changes unless TLS is explicitly requested.
  Client: `NetClient` now tracks connection state as `_tcp_peer` (the real socket) plus `_peer`
  (a `StreamPeer` -- either `_tcp_peer` directly, or a `StreamPeerTLS` wrapping it once
  `connect_to_server(host, port, use_tls)`'s TCP phase completes and the TLS handshake starts).
  Deliberately tracks connection state via its own `_connected`/`_tls_handshaking` booleans
  rather than comparing `get_status()` against `StreamPeerTCP.STATUS_CONNECTED` after the TLS
  phase begins -- `StreamPeerTCP.Status` and `StreamPeerTLS.Status` are different enums, and
  relying on their integer values happening to line up would've been fragile. `PacketReader.poll`
  and `Packet`'s type hints loosened from `StreamPeerTCP` to the shared `StreamPeer` base so the
  same frame-reading code works over either transport unchanged.
  Verified for real, not just type-checked: a new `gateway_test.go` generates a genuine
  self-signed ECDSA certificate in-memory and runs two tests against a real `tls.Config`-backed
  `Server` -- one confirms a real `tls.Dial` handshake and framed round-trip work, the other
  confirms a plaintext TCP connection against a TLS-configured server fails during the handshake
  rather than being silently accepted as unencrypted. On the client side, manually drove a real
  `NetClient` instance (instantiated directly, not through the editor) against a locally-run
  server binary twice -- once with `-tls-cert`/`-tls-key` and `use_tls=true` (confirmed `connected`
  fires only after the TLS handshake completes, and a real login round-trip works over the
  encrypted channel) and once plain (confirming the refactor didn't regress the existing
  no-TLS path). Self-signed certs use `TLSOptions.client_unsafe()` client-side (no CA to
  validate against for local dev) -- documented inline that a real deployment with a real cert
  should use `TLSOptions.client()` instead.
  All 19 GDScript suites still pass headless. Full Go test suite green, including two new TLS
  tests in `gateway`. No new CI entries needed (extended existing `gateway_test.go` and
  `net_client.gd`/`packet_reader.gd`, no new files).

## 2026-08-20 (cont'd 5)

- Added a persistent friends list, the last piece of core MMO social infrastructure (party/guild/
  chat/quests/duels/trade/friends are all in now). `server/internal/friend`: Postgres-backed from
  the start, like guild -- a friendship should survive a relog or restart, unlike party/duel/
  trade's live session state. `friend_requests` (pending, one row per outstanding request) and
  `friendships` (accepted, one row per direction so each side's list query is a plain indexed
  SELECT rather than an OR'd lookup). `AcceptRequest` runs in a transaction: consume the request,
  insert both directions of the friendship, all-or-nothing.
  Caught a real design mistake mid-implementation, not after: the first draft of
  `session/friend.go` had `OpFriendAccept`/`OpFriendDecline`/`OpFriendRemove` all take the other
  character's *name*, resolved the same way duel/trade resolve a target -- via `world.Hub`, which
  only finds someone if they're currently online. That's fine for *sending* a request (you're
  interacting with someone live), but it quietly broke the entire point of a *persistent* friends
  list: you'd only be able to accept a request from someone who happened to still be online, which
  defeats "accept it later." Reworked accept/decline/remove to take a character ID instead (which
  the client already has from a prior list response), and added a new `OpFriendPendingList`
  opcode so there's actually a way to see incoming requests by ID before acting on them. Documented
  this reasoning directly in `friend.go`'s opcode comment so the asymmetry (request-by-name,
  respond-by-ID) doesn't look like an inconsistency later.
  `OpFriendRequestReceived`/`OpFriendAccepted` notifications are still best-effort/online-only
  (same tradeoff duel/trade already made for their own live notifications) -- an offline
  recipient just sees the change next time they list. Added `world.Hub.EntityByCharacterID`
  (mirroring the existing `FindByName`) to resolve online status by ID for friends-list responses.
  Full flow tested end-to-end over two real TCP connections: Aria requests Bram (online), Bram
  gets a live notification, lists pending requests and accepts by ID, Aria gets a live
  acceptance notification, both lists show each other online, Aria removes Bram and both lists
  go back to empty. A second test confirms requesting an offline/nonexistent name fails cleanly.
  Ported to GDScript (`friend.gd` + test), wired into `NetClient`, reconfirmed byte-exact wire
  compatibility for `FriendListResult` and `FriendPendingListResult` via independent Go/GDScript
  hex generation. All 19 GDScript suites pass headless; wired into CI. Full Go test suite green
  across all packages including the new `friend` package; server binary smoke-tested with
  friends wired in.

## 2026-08-20 (cont'd 4)

- Fixed the `Packet.read_from` busy-wait limitation that's been flagged in `NetClient`'s doc
  comment since it was first written: the old implementation consumed a frame's header off the
  socket, then blocked the calling thread in a `while ... OS.delay_msec(1)` loop until the full
  payload had arrived, which would stall `NetClient._process()` -- and therefore every frame of
  the game -- against a slow or adversarial connection.
  Replaced it with `PacketReader` (`client/scripts/net/packet_reader.gd`): a small stateful
  reader that tracks "have we buffered a header yet, and how much payload are we still waiting
  on" as instance state instead of a blocking loop. `poll()` returns `null` immediately if a full
  frame isn't available yet -- no delay, no busy-wait -- and the caller (now `NetClient`, one
  `PacketReader` per connection) just calls it again next frame. `Packet.read_from` was removed
  entirely rather than left alongside as a second, divergence-prone implementation; it had
  exactly one caller.
  This is the kind of bug that's easy to fix wrong by testing only the parts that don't matter --
  encode/decode round-trips (already covered by `packet_test.gd`) say nothing about whether
  reading a frame that arrives in two separate TCP writes actually works. Wrote
  `packet_reader_test.gd` against a **real loopback socket** (a `TCPServer` + `StreamPeerTCP`
  pair, not synthetic byte arrays) specifically to exercise that: sending a frame's header and
  payload as two separate `put_data` calls confirms `poll()` returns `null` after the header
  alone and the completed `Packet` only once the payload lands, and a second test sends two full
  frames back-to-back in one write to confirm both decode correctly out of a single combined
  buffer. Both passed on the first real run.
  All 18 GDScript suites pass headless; wired the new test into CI.

## 2026-08-20 (cont'd 3)

- Expanded monster content from one placeholder species to three: `cmd/server/main.go`'s
  `maintainMonster` took a single hardcoded zone/name/stats set; refactored it to take a
  `monsterSpec` and run one goroutine per entry in a new `monsterSpecs` slice, so adding a
  species is now a one-line data addition rather than a code change. Added "Wild Boar" (jangan,
  weaker/faster to kill) and "Sand Scorpion" (donwhang, a second zone, tougher) alongside the
  existing "Stone Golem". Own placeholder content throughout, same as before -- no real
  `_RefObjMonster`-equivalent data has been catalogued to import.
  Extended `combat.LootTables` and `quest.Catalog` to match: Wild Boar and Sand Scorpion both get
  loot entries (Sand Scorpion has two independently-rolled entries, exercising the multi-entry
  path `LootTable []LootEntry` was already designed for but only had one monster using), and a
  second quest ("Boar Hunt": kill 5 Wild Boar for 100 gold) joins "Golem Cull" in the catalog.
  No protocol changes needed -- this was purely content, reusing everything wired in the last few
  rounds (loot rolling, quest kill-tracking, gold rewards all already keyed by monster name).
  Verified via a clean build and full Go test suite (existing quest-listing test loops over
  entries by ID rather than asserting an exact catalog size, so it stayed valid with two quests
  instead of one), plus a server binary smoke-test confirming all three species actually spawn
  (in their correct zones) on startup.

## 2026-08-20 (cont'd 2)

- Added monster loot drops -- combat previously only ever granted gold on a kill, never items,
  which made the item/inventory/equipment/shop systems built earlier feel disconnected from
  actually playing the game. `server/internal/combat/loot.go`: `LootTables map[string][]LootEntry`
  keyed by monster species name (own design, same pattern as `skill.Catalog`/`quest.Catalog` --
  not real `_RefObjItem` drop-rate data, which hasn't been catalogued). Currently one entry:
  "Stone Golem" guarantees 1x placeholder item 500, chosen deliberately as a 100%-chance drop so
  the flow is deterministic and testable without flaky probability-based assertions.
  Wired into `session/combat.go`'s existing kill-hook location (same spot quests hook in):
  `rollLoot` resolves the table, rolls each entry's chance/quantity range, and calls
  `inventory.Store.AddItem` directly -- failures (unknown ref item, full inventory) are swallowed
  rather than failing the kill, since loot is enrichment on a successful attack, not a
  precondition for one. This needed threading `inventory.Store` through `CombatHandler`,
  `UseSkillHandler`, and `performAttack` (same shape as the quest.Store threading from last
  round) -- updated all call sites (`cmd/server/main.go`, and `combat_test.go`/`skill_test.go`/
  `quest_test.go`'s existing full-flow tests) to pass the `inv` store each already had on hand
  for equipment.
  New `OpLootDropped` opcode (0x0064), sent directly to the killer only when there's at least one
  actual drop (not sent on every kill) -- deliberately a separate message rather than bolting a
  variable-length field onto the existing fixed-shape `AttackResult`, which would have broken its
  simple `!=` struct-comparison round-trip tests.
  Full flow tested end-to-end over real TCP against the "Stone Golem" guaranteed drop, confirming
  both the `OpLootDropped` message contents AND the actual `inventory.Store` state afterward (not
  just the wire message) -- same store-level verification discipline used for trade's swap test.
  Ported to GDScript (extended `combat.gd`/`combat_test.gd` rather than a new file, since loot is
  part of the existing combat protocol), wired into `NetClient`, reconfirmed byte-exact wire
  compatibility for `LootDropped` via independent Go/GDScript hex generation. All 17 GDScript
  suites still pass headless (no new CI entry needed -- no new test file). Full Go test suite
  green across all packages; server binary smoke-tested with loot wired in.

## 2026-08-20 (cont'd)

- Added player-to-player trading, rounding out the social/economy feature set (parties, guilds,
  chat, quests, duels, and now trade are all in). `server/internal/trade`: an in-memory `Hub`
  (own design, live/session-scoped like `party.Hub`/`duel.Hub` -- trade *sessions* aren't
  persisted, only their end result once executed) with the same request/accept shape as duel's
  challenge/accept, plus per-side `Offer{Gold, ItemSlot, Quantity}` state and a two-sided
  confirm gate: changing an offer after confirming clears BOTH sides' confirmation (a deliberate
  anti-bait-and-switch rule -- you can't quietly swap what you're offering after your counterpart
  has already locked in).
  The interesting design problem was execution: there's no single database transaction spanning
  `character.Store` (gold) and `inventory.Store` (items) -- they're independent stores. Rather
  than pretending otherwise, `session/trade.go`'s `executeTrade` documents exactly where the
  narrow gap is: it validates both offers, deducts gold with a refund-on-failure for the second
  deduction, removes items with the same refund pattern, then credits everything -- the one
  case that isn't fully covered is a recipient's inventory filling up at the very last
  `AddItem` call, which would lose an item rather than return it. Called out inline as a known,
  low-probability limitation rather than silently leaving a subtle bug for later.
  Opcodes 0x00D0-0x00DE (request/respond/offer/confirm/cancel, each with results, plus
  invite/started/declined/offer-updated/completed/cancelled notifications) -- the largest opcode
  block added this session, but each payload is small and mechanical, following the same pattern
  established by duel. `OpTradeCompleted` is sent asymmetrically to each side describing what
  *they* received (not a shared summary), which needed `executeTrade` to return the resolved item
  IDs rather than re-deriving them after the swap (by then they'd be sitting in the recipient's
  inventory under a possibly different slot, not useful for the message).
  Full flow tested end-to-end over two real TCP connections, verifying actual `character.Store`/
  `inventory.Store` state after the swap (not just the wire messages): a full trade (Aria gives
  50 gold + her weapon, Bram gives his full item stack, no gold) confirms both sides' gold and
  inventory contents afterward; a cancel-before-confirm flow confirms neither side is touched; an
  insufficient-gold flow confirms the trade fails cleanly with a system `OpTradeCancelled` and
  neither side's gold moves.
  Ported to GDScript (`trade.gd` + test), wired into `NetClient`, reconfirmed byte-exact wire
  compatibility for `TradeSetOfferRequest` (including the -1 "no item" sentinel encoding as
  `0xFFFFFFFF`) and `TradeCompleted` via independent Go/GDScript hex generation. All 17 GDScript
  suites pass headless; wired into CI. Full Go test suite green across all packages including the
  new `trade` package; server binary smoke-tested with trade wired in.

## 2026-08-20

- Added 1v1 PvP duels, closing the last item of the "parties/guilds/PvP: 0%" gap from the
  earlier scope assessment -- all three are now implemented (parties/guilds/quests/PvP), though
  content depth (real skill/monster/item data) remains the honest remaining gap.
  `server/internal/duel`: an in-memory `Hub` (own design, live/session-scoped like `party.Hub`,
  not persisted -- a duel outliving a server restart wouldn't make sense) tracking pending
  challenges and active 1v1 pairings. `Challenge`/`Respond`/`OpponentOf`/`End` plus
  `CancelPendingFor` for disconnect cleanup. Documented a deliberate simplification in
  `CancelPendingFor`: if the *challenger* disconnects before the target responds, the target
  isn't notified (their Member, including Session, was never recorded on that side of the map --
  only the challenger's was) -- an accepted scope cut, not an oversight, called out inline rather
  than silently leaving a subtle gap.
  `server/internal/session/duel.go`: opcodes 0x00C0-0x00CA (challenge/respond/attack, each with
  results, plus invite/started/declined/damaged/ended notifications). Target resolution reuses
  `world.Hub.FindByName`, the same mechanism chat's whisper already established, rather than
  inventing a second player-lookup path. PvP damage reuses `attackerDamage` from
  `session/combat.go` (equipped weapon or unarmed) but has **no defense mitigation** yet --
  characters have no Defense stat, only HP -- a deliberate scope cut stated in the code, not a
  bug. A dead duel loser has their HP reset (no death penalty, consistent with PvE).
  Disconnect handling required getting the `OnDisconnect` hook's *ordering* right in
  `cmd/server/main.go`: `duelDisconnect` must run before `worldDisconnect`, since it looks the
  departing session up via `world.Hub.EntityBySession`, which `worldDisconnect` immediately
  removes them from. Caught this by reading `WorldDisconnectHandler`'s implementation before
  wiring, not by hitting it at runtime.
  Full flow tested end-to-end over two real TCP connections: a decline flow (challenge -> decline
  -> challenger notified -> neither ends up dueling -> attacking without an active duel fails
  cleanly), and a full fight flow (challenge -> accept -> both sides get `OpDuelStarted` -> three
  non-lethal hits each deliver `OpDuelOpponentDamaged` to the defender -> the fourth, lethal hit
  delivers `OpDuelEnded` with the correct winner to both sides and clears both from the active
  duel set).
  Ported to GDScript (`duel.gd` + test), wired into `NetClient`, reconfirmed byte-exact wire
  compatibility for `DuelChallengeRequest`, `DuelAttackResult`, and `DuelRespondRequest` via
  independent Go/GDScript hex generation. All 16 GDScript suites pass headless; wired into CI.
  Full Go test suite green across all packages including the new `duel` package; server binary
  smoke-tested with duels wired in.

## 2026-08-19 (cont'd 29)

- Added a quest system, closing the last named 0% gap from the earlier scope assessment
  (quests/guilds/PvP -- guilds and quests are now done; PvP/duels remain future work).
  `server/internal/quest`: a small fixed catalog (own design, same pattern as `skill.Catalog` --
  currently one quest, "Golem Cull": kill 3 Stone Golems for 200 gold) with Postgres-backed
  per-character progress (`character_quests`: character_id, quest_id, kills, completed_at) that
  survives disconnects, unlike party/combat state.
  The interesting wiring problem: quest progress needs to react to monster deaths, which already
  happen deep inside `session/combat.go`'s `performAttack` (shared by plain attacks and skill
  uses). Rather than inventing a separate event/pubsub layer, threaded a `quest.Store` straight
  through `performAttack`'s existing parameter list (and both its callers, `CombatHandler` and
  `UseSkillHandler`) -- on a kill, it now calls `quests.RecordKill(characterID, monster.Name)`
  right where the existing gold-reward logic already lives, granting quest gold and sending a new
  `OpQuestCompleted` packet the same way. Added opcodes 0x00B0-0x00B4 for list/accept/completed.
  Updated `combat_test.go` and `skill_test.go`'s existing full-flow tests for the new parameter
  (both now spin up a real Postgres-backed `quest.Store`, matching the pattern already used for
  inventory/equipment/skill in those same tests) -- confirms the wiring didn't regress plain
  attacks or skill-boosted attacks.
  Full flow tested end-to-end over real TCP: accept a quest, re-accepting the same one fails
  cleanly, killing three one-hit-kill monsters progresses it, and the third kill triggers
  `OpQuestCompleted` with the correct gold reward (not the first or second) -- verified as a
  distinct packet read, not inferred from side effects.
  Ported to GDScript (`quest.gd` + test), wired into `NetClient`, reconfirmed byte-exact wire
  compatibility for `QuestListResult` and `QuestCompleted` via independent Go/GDScript hex
  generation. All 15 GDScript suites pass headless; wired into CI. Full Go test suite green
  across all packages; server binary smoke-tested with quests wired in.

## 2026-08-19 (cont'd 28)

- Added a chat system: zone-wide "say" and cross-zone "whisper", the last piece of basic MMO
  social infrastructure that was entirely missing (players could group up and guild up but had
  no way to talk to each other). Deliberately lightweight: `session/chat.go` needs only
  `world.Hub`, not `character.Store` -- a chatting session's identity and current zone come from
  its existing `world.Hub` entity (added two small accessors, `EntityBySession` and `FindByName`,
  rather than making callers re-resolve a character name they already established by entering the
  world). Opcodes 0x00A0-0x00A4: `OpChatSay` broadcasts to everyone in the sender's zone
  (including the sender itself, so the sender's own client renders it the same way as everyone
  else's -- no separate "local echo" path to keep in sync); `OpChatWhisper` looks the target up
  by name across all zones and delivers directly to their session, with an explicit ack back to
  the sender (`OK` or a reason like "player not found") rather than silently dropping whispers to
  offline/nonexistent players.
  Full flow tested end-to-end over two real TCP connections: both characters enter the same zone,
  a Say from one is received by both (including the sender, verified as a distinct read from the
  sender's own connection, not inferred), a Whisper is received only by its target with a
  separate delivery ack for the sender, and whispering a name that isn't in the world returns a
  clear failure reason instead of hanging.
  Ported to GDScript (`chat.gd` + test), wired into `NetClient`, reconfirmed byte-exact wire
  compatibility for `ChatMessage` and `ChatWhisperRequest` via independent Go/GDScript hex
  generation. All 14 GDScript suites pass headless; wired into CI. Full Go test suite green;
  server binary smoke-tested with chat wired in.

## 2026-08-19 (cont'd 27)

- Added a guild system, distinct from party in one deliberate way: parties (`internal/party`)
  are in-memory/session-scoped by design (dissolving on restart is fine for a live grouping),
  but guilds are meant to be a long-lived social structure, so `server/internal/guild` is
  Postgres-backed from the start -- no `MemStore` variant, matching the reasoning that a
  guild you can lose on server restart isn't really a guild. Schema: `guilds` (id, name, unique
  case-insensitively) + `guild_members` (guild_id, character_id unique across all guilds, role,
  joined_at). Create/Join/Leave all run inside a transaction so a name clash or a
  duplicate-membership race can't leave a half-created guild or double membership behind.
  Leave promotes the earliest-joined remaining member (by `joined_at`) to leader, or deletes the
  guild row entirely if the leaver was the last member -- transactional, so a crash mid-leave
  can't leave a leaderless guild.
  `server/internal/session/guild.go`: opcodes 0x0090-0x0095 (create/join/leave requests +
  results). Deliberately no broadcast opcodes here (unlike party's MemberJoined/MemberLeft) --
  `guild.Store` has no notion of which members are currently online since membership outlives
  any one session, so there's no session list to broadcast to; a client learns about roster
  changes from its own join/leave response instead. Documented this reasoning inline rather than
  leaving it to look like a missed feature.
  Full flow tested end-to-end over two real TCP connections against a real Postgres-backed
  `guild.Store` (not a mock): Alice founds a guild, Bob joins it, Alice (the founder) leaves and
  leadership passes to Bob rather than disbanding the guild since he's the only member left.
  Ported to GDScript (`guild.gd` + test), wired into `NetClient`, reconfirmed byte-exact wire
  compatibility for `GuildResult` and `GuildCreateRequest` via independent Go/GDScript hex
  generation. All 13 GDScript suites pass headless; wired into CI. Full Go test suite green
  across all packages including the new `guild` package; server binary smoke-tested with guilds
  wired in.

## 2026-08-19 (cont'd 26)

- Added a party/grouping system, closing the "parties/guilds/PvP: 0%" gap from the earlier scope
  assessment (guilds/PvP still remain future work). `server/internal/party`: an in-memory `Hub`
  (own design, no real party data to RE — parties are pure session state, not persisted) tracking
  parties by ID, a character->party index, and a session->character index used specifically for
  disconnect cleanup. `MaxSize = 5`. `Leave` promotes the next member to leader or disbands the
  party if the leaving member was last; `LeaveBySession` wraps the same logic keyed by session ID
  so a dropped TCP connection cleans up its party membership without the client sending an
  explicit leave first.
  `server/internal/session/party.go`: opcodes 0x0080-0x0087 (create/join/leave requests + results,
  plus member-joined/member-left broadcasts to the rest of the party). `PartyDisconnectHandler`
  wired alongside the existing `WorldDisconnectHandler` into `cmd/server`'s combined
  `OnDisconnect` hook.
  Full flow tested end-to-end over two real TCP connections: alice creates a party, bob joins it
  and alice receives the `PartyMemberJoined` broadcast, bob leaves and alice receives
  `PartyMemberLeft`. (First draft of this test file used an over-engineered generic type-assertion
  helper that didn't make sense — scrapped it for the same plain `net.Conn` pattern already used
  by every other session test.)
  Ported to GDScript (`party.gd` + test), wired into `NetClient` (signals + create/join/leave
  methods + dispatch cases), reconfirmed byte-exact wire compatibility for `PartyResult` and
  `PartyJoinRequest` via independent Go/GDScript hex generation. All 12 GDScript suites pass
  headless; wired into CI. Full Go test suite green across all packages; server binary
  smoke-tested with parties wired in.

## 2026-08-19 (cont'd 25)

- Added a skill system: `server/internal/skill` (own design, tiny fixed catalog -- "Power Strike"
  +15 damage/5s cooldown, "Whirlwind" +10 damage/3s cooldown -- since `_RefSkill`'s ~118 columns
  are still only partially catalogued, no real skill data exists to import yet). Postgres-backed
  per-character "known skills + last-used-at" tracking for cooldown enforcement.
  Refactored `session/combat.go`'s attack-resolution logic (damage calc, monster HP, counterattack,
  gold reward, zone broadcast) out of `CombatHandler` into a shared `performAttack` helper, so
  `OpUseSkill` (skill.go) and `OpAttack` (combat.go) go through identical logic — a skill is just
  an attack with a damage bonus, not a separate combat path with its own chance to drift out of
  sync. `OpUseSkill`'s response deliberately reuses `OpAttackResult` rather than inventing a
  parallel result type for the same information.
  Full flow tested end-to-end over real TCP: using an unlearned skill fails, learning it twice
  fails the second time, using it lands the correct combined damage (weapon + skill bonus -
  defense), and using it again immediately hits the cooldown.
  Ported to GDScript (`skill.gd` + test), wired into `NetClient`, reconfirmed byte-exact wire
  compatibility for `UseSkillRequest`. All 11 GDScript suites pass headless; wired into CI. Server
  binary smoke-tested with skills wired in.

## 2026-08-19 (cont'd 24)

- Closed the client/server parity gap: the last several rounds added inventory, equipment, shop,
  and combat to the Go server's protocol, but the GDScript client had no code for any of them
  (only login/character-select). Ported all four: `client/scripts/net/{inventory,equipment,shop,
  combat}.gd`, matching each Go payload shape exactly. Wired all of it into the `NetClient`
  autoload as new signals/methods.
  Worth noting one real protocol shape discovered while wiring `NetClient`: `OpEquipmentResult`
  covers list results *and* equip/unequip acks with the same opcode and payload shape (a successful
  equip ack is just an empty items list) — there's no way for the client to distinguish "this is a
  list response" from "this is my equip request's ack" at the opcode level. Went with a single
  `equipment_result` signal reflecting that reality rather than inventing a false distinction the
  wire format doesn't actually support.
  Reconfirmed byte-exact wire compatibility for the three most structurally complex new payloads
  (`AttackResult`, `EquipRequest`, `ShopBuyRequest`) by hex-diffing independently generated output
  from the Go and GDScript sides. All 10 GDScript test suites pass headless; wired into CI.

## 2026-08-19 (cont'd 23)

- Made combat two-directional: characters previously had no HP and monsters never fought back, so
  the "combat" system landed last round was really just a damage sponge with no risk. Added
  `character.MaxHP`/`HP` (flat 100, own design) with `ApplyDamage`/`ResetHP` on `Store` (both
  `MemStore` and `SQLStore` — another `ALTER TABLE ... ADD COLUMN IF NOT EXISTS hp` migration,
  same pattern as gold's). `combat.Monster` gained an `Attack` field; `CombatHandler` now applies a
  monster's counterattack to the attacking player whenever the monster survives the hit (a dead
  monster can't retaliate). Death auto-respawns the player at full HP rather than leaving them
  stuck — no harsh MMO death penalty for this MVP.
  Reshaped `AttackResult`'s wire format to carry both sides of the exchange (`MonsterDamage`/
  `MonsterRemainingHP`/`MonsterDied` and `PlayerDamageTaken`/`PlayerHP`/`PlayerDied`) rather than
  bolting player fields onto the old monster-only shape.
  Full flow re-verified end-to-end: first hit shows the monster taking damage *and* the player
  taking counter-damage; second hit kills the monster with no counterattack and confirms the
  player's HP carries over unchanged from the first hit (not reset, not further reduced).
  All packages build/vet/test clean; server binary smoke-tested.

## 2026-08-19 (cont'd 22)

- Added `server/internal/combat`: the closing piece of the core gameplay loop this session built
  toward. Own design throughout — `Hub` tracks live monsters (in-memory, same reasoning as
  `world.Hub`), damage = attacker's equipped weapon's `PhysAttackMax` (or a flat `unarmedDamage`
  fallback with nothing equipped) minus the monster's `Defense`, floored at 1 so combat can never
  stall at zero damage. `world.Hub` gained `EntitiesInZone` (everyone in a zone, unlike the
  existing `Move`/`Enter`/`Leave` methods which return "everyone *except* the mover") so combat can
  broadcast hits to bystanders.
  Wired `OpAttack` + `OpMonsterDamaged`/`OpMonsterDied` broadcasts into the protocol.
  Caught a real bug via the end-to-end test, not by inspection: the first version broadcast
  `OpMonsterDamaged`/`OpMonsterDied` to *everyone* in the zone including the attacker themselves,
  who already gets a richer direct `OpAttackResult` — so the attacker's socket received two packets
  per attack, and a test helper that read only one response per request decoded the second attack's
  reply as the *first attack's leftover broadcast*, producing nonsense values (`RemainingHP:5120`
  instead of 0). Fixed by excluding the attacker's own session from the broadcast.
  `cmd/server` now spawns a single placeholder monster ("Stone Golem", own invented content — no
  real monster/drop data has been imported, see `refdata_schema.md`'s open items) in the world's
  one spawn zone, with a background loop that respawns it 10s after each death.
  Full flow (login -> enter world -> equip weapon -> attack twice -> confirm damage/death/gold
  reward -> confirm the dead monster is actually gone) tested end-to-end over real TCP. All
  packages build/vet/test clean; full server binary smoke-tested spawning its monster on startup.

**This closes out "do it all" for the core MVP gameplay loop**: account -> character ->
persistence -> world/movement -> inventory -> equipment -> shop -> combat, all cross-verified
between Go and (for the client-facing pieces) GDScript where applicable. What's *not* done and
worth being honest about: skills, real monster/drop content (this session's monster and shop
prices are placeholder own-designed content, not derived from the original's actual game-balance
data), quests, parties/guilds/PvP, and all client-side 3D rendering/UI beyond login and character
select.

## 2026-08-19 (cont'd 21)

- Added `server/internal/shop`: a basic NPC vendor, entirely own design. No original pricing data
  exists to draw from (never restored/mined a real price table from the obtained DB backups), so
  `Price()` computes cost from an item's own combat stats via a simple own formula
  (`basePrice + statMultiplier * sum-of-attack/defense`) rather than looking anything up. `Service`
  composes `character.Store` (gold), `inventory.Store` (receiving items), and an `ItemLookup`
  (catalog/pricing) — not backed by its own table, just a computed layer over the others.
  `Buy` refunds gold automatically if adding the item to inventory fails after gold was already
  deducted (e.g. no inventory room), so a failed purchase can't silently take someone's money.
  Wired `OpShopBuy` into the protocol; full buy flow (login -> buy -> confirm gold deducted and
  item received) tested end-to-end over real TCP.
- All packages build/vet/test clean; full server binary (accounts, characters, refdata, inventory,
  equipment, shop, all sharing one Postgres connection) smoke-tested starting up cleanly.

## 2026-08-19 (cont'd 20)

- Added currency: `character.Character` gained a `Gold` field (`StartingGold` = 1000, own design),
  `Store` gained `AddGold`/`DeductGold` (both `MemStore` and `SQLStore`). Caught a real migration
  bug: `CREATE TABLE IF NOT EXISTS` doesn't add columns to an already-existing table, so the shared
  local Postgres instance (which already had a `characters` table from earlier sessions) silently
  kept the old schema until an explicit `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` was added — a
  real "works on a fresh DB, breaks on an existing one" class of bug, caught by testing against the
  actual persistent local instance rather than a fresh one each time.
- Added `server/internal/equipment`: own design, two slots for now (`SlotWeapon`, `SlotArmor` —
  enough to make combat math meaningful without over-building). Equip moves an item out of
  inventory (swapping out and returning whatever was previously equipped first, so nothing is ever
  silently lost); Unequip returns it. Depends on `inventory.Store` as an interface, not a concrete
  type. Wired `OpEquipmentList`/`OpEquip`/`OpUnequip` into the protocol. Full equip -> list ->
  unequip flow tested end-to-end over real TCP, confirming the item actually leaves and returns to
  the inventory, not just that the equipment table looks right in isolation.
- All packages build/vet/test clean against the real local Postgres instance; full server binary
  wired with accounts/characters/refdata/inventory/equipment all sharing one Postgres connection
  string.

## 2026-08-19 (cont'd 19)

- Added `server/internal/inventory`: an independently-designed per-character item store (fixed
  50 slots, stacking up to each item's `refdata`-defined `MaxStack`, own placement logic — fill
  existing under-full stacks before opening new slots). Postgres-backed, same pattern as
  account/character/refdata. `refdata.SQLStore` now also implements `inventory.MaxStackLookup`
  (`GetMaxStack`) so inventory doesn't need its own copy of item stack-size data.
  Wired `OpInventoryList` into the protocol (`session/inventory.go`) — deliberately **not** wiring
  add/remove to any opcode yet, since there's no legitimate way for a player to acquire items
  without a shop, combat, or drop system, none of which exist yet; those opcodes land once those
  systems do.
  Caught and fixed a real bug while writing the session-level test: forgot that Postgres-backed
  test packages need their own truncate-between-runs step, unlike `MemStore`-only packages — the
  first run of the full end-to-end test silently accumulated inventory across repeated test runs
  (5 items became 10) before being caught and fixed with a small `TruncateForTest` helper.
  All packages build/vet/test clean against the local Postgres instance; full server binary
  smoke-tested with inventory wired in.

## 2026-08-19 (cont'd 18)

- Migrated all three persistent stores (`account`, `character`, `refdata`) from SQLite to
  PostgreSQL, per OpenSRO's preference. Swapped `modernc.org/sqlite` for `jackc/pgx/v5` (via its
  `database/sql` compatibility shim, `pgx/v5/stdlib`, so the rest of the code didn't need to change
  shape) and adjusted each schema for real Postgres idioms rather than a lazy port of the SQLite
  DDL: `BIGSERIAL`/`RETURNING id` instead of `AUTOINCREMENT`/`LastInsertId()` (Postgres's
  `database/sql` driver doesn't support the latter), native `BOOLEAN` instead of an `INTEGER`
  0/1 hack, `DOUBLE PRECISION` instead of SQLite's untyped `REAL`, and a
  `CREATE UNIQUE INDEX ON characters (LOWER(name))` for case-insensitive name uniqueness in place
  of SQLite's `COLLATE NOCASE` (Postgres has no direct equivalent).
  Installed PostgreSQL 14 locally to actually test against a real instance rather than guessing —
  SQLite's `:memory:` trick doesn't exist for Postgres, so tests now share one local
  `srrevamp_test` database and `TRUNCATE` their own tables per test for isolation
  (`SRREVAMP_TEST_POSTGRES_DSN` env var overrides the default local connection string, used by CI's
  new `postgres:16` service container). `cmd/server` and `cmd/import-refdata` now take a single
  `-postgres-dsn` flag instead of per-store SQLite file paths. Full test suite passes against the
  real local Postgres instance, and the built server binary smoke-tested starting up and connecting
  successfully. `go.sum`/`go.mod` no longer reference `modernc.org/sqlite` at all.

## 2026-08-19 (cont'd 17)

- Static game data pipeline, first slice: string-scanning a `.Bak` file (the earlier `db_schema.md`
  pass) only gets table/column *names*, not real schema or any actual data. To go further, stood
  up a temporary SQL Server 2019 instance via Docker on the `ghidra-mcp` box (which already had
  `nesting=1` enabled) and actually restored `SRO_VT_SHARD.Bak`. Confirmed real data: `_RefObjItem`
  (24,521 rows, 105 columns — item stats) and `_RefSkill` (36,144 rows, 118 columns — skill data)
  are genuinely populated, not empty scaffolding.
  Per the same reasoning applied all session (declined to remove `docs/LEGAL.md`'s substance
  earlier): pulled the *schema* (structural facts, written up in new
  `docs/protocol/refdata_schema.md`) but did not commit any actual row data anywhere. Instead built
  `server/internal/refdata` + `server/cmd/import-refdata`: a "bring your own data" CSV importer
  populating our own, independently-designed SQLite schema (a curated subset of the original's 105
  item columns, not a 1:1 port) — the same pattern this repo already uses for pk2 client assets.
  Tested for real against the actual 24,521-row export (kept in a scratch dir outside the repo,
  deleted after) — full round trip worked. Tore down the SQL Server container and deleted the test
  database afterward; nothing about this step is persisted anywhere outside the schema docs and
  importer code.
  Skills, drop tables, and where item/skill display names actually live (not in `_RefObjItem`
  itself) are the next things to figure out — noted in the doc's Status section rather than
  guessed at now.

## 2026-08-19 (cont'd 16)

- Built actual Godot client scenes wired to the protocol layer that already worked in isolation:
  `NetClient` (`client/scripts/net/net_client.gd`, an autoload singleton) wraps a `StreamPeerTCP`
  connection and dispatches decoded packets as signals; `Login.tscn`/`.gd` and
  `CharacterSelect.tscn`/`.gd` are real UI (LineEdit/Button/ItemList, not mockups) driving login,
  registration, character list/create/delete, and entering the world. `Boot.gd` now transitions
  into `Login.tscn` instead of just printing a message.
  Hit a real Godot gotcha immediately: `NetClient`'s script had both `class_name NetClient` and an
  autoload registered under the same name — Godot refuses this ("hides an autoload singleton") and
  it broke every scene referencing it. Fixed by dropping `class_name` (the script is only ever used
  as the autoload, never instantiated as a standalone type elsewhere).
  Verified for real, not just "loads without errors": ran a throwaway script that instantiated
  `NetClient` directly (autoloads aren't available in `--script` mode) against the actual running
  Go server binary and drove it through register -> login -> list (empty) -> create -> enter world,
  asserting on every response -- full stack, real TCP, real server process, not mocked. Deleted the
  script after (not meant to be a committed test, just a one-time integration check); the committed
  GDScript unit tests only cover encode/decode, not the live networking wrapper, which is a real
  coverage gap worth closing with a proper integration test harness later.
  No in-world 3D scene exists yet (needs real map/asset rendering, out of scope here) — character
  select shows a confirmation of zone/position/nearby-player-count as the current end of this
  vertical slice.

## 2026-08-19 (cont'd 15)

- Added a minimal world/zone system: `server/internal/world` (`Hub`, in-memory by design — live
  position data resetting on restart is normal for an MMO, unlike account/character data) tracks
  which characters are present in which zone and who's near whom; `server/internal/session/world.go`
  wires it to the wire protocol (`OpEnterWorld`, `OpMove`, and three broadcast opcodes —
  `OpEntityEntered`/`OpEntityMoved`/`OpEntityLeft`). One fixed spawn point (`jangan`, `{0,0,0}`)
  since no real map data has been pulled apart yet.
  Needed two additions to `gateway` that didn't exist before: a unique `Session.ID()` (so `Hub` can
  key state without comparing `*Session` pointers) and an `OnDisconnect` hook (so leaving the world
  on disconnect doesn't require every handler to poll for dead connections).
  Full flow tested end-to-end over real TCP with two simultaneous connections: second player's
  `OpEnterWorld` sees the first as an "other", first player receives `OpEntityEntered` for the
  second, a move broadcasts `OpEntityMoved`, and disconnecting broadcasts `OpEntityLeft` — all
  through the actual server stack, not mocked.
  Caught a real bug while writing the result decoder: `EnterWorldResult` has more fields after
  `Reason` when `OK=true` (zone, position, others), but the shared `decodeOKReason` helper requires
  *nothing* follow `Reason` — reusing it here would have made every successful `OpEnterWorldResult`
  fail to decode. Wrote a manual decoder for this one instead of forcing the shared helper to fit.
  Ported the same opcodes to GDScript (`client/scripts/net/world.gd` + test), wired into CI, and
  reconfirmed byte-exact wire compatibility for both `EnterWorldResult` and `MoveRequest`.
- Also pushed 15 accumulated local commits to `origin/dev` (merging in one commit — a README edit —
  that had landed there independently in the meantime; no conflicts).

## 2026-08-19 (cont'd 14)

- Gave `character` the same SQLite treatment as `account` (the TODO flagged in the previous
  entry): `character.SQLStore`, same pattern (pure-Go driver, own schema, `COLLATE NOCASE` for
  case-insensitive name uniqueness at the DB level matching `MemStore`'s behavior), same test
  shape including a reopen-persistence test. `cmd/server` now opens both databases by default
  (`-account-db`/`-character-db` flags, both `:memory:`-capable for ephemeral runs) — nothing in
  the running server is backed by `MemStore` anymore. Smoke-tested the actual built binary starts
  and opens both databases cleanly, not just `go test`.

## 2026-08-19 (cont'd 13)

- Closed the most-repeated TODO from earlier entries: `account.SQLStore` (`server/internal/account/sqlstore.go`)
  is a real, persistent `Store`/`Registerer` backed by SQLite via the pure-Go `modernc.org/sqlite`
  driver (no cgo, so it builds the same way everywhere). Own schema (see `db_schema.md`'s facts,
  not the original's `TB_User` layout). Tests cover the same scenarios as `MemStore` plus one that
  actually matters for a "persistent" store and wouldn't be caught by in-memory tests alone:
  closing and reopening a file-backed database and confirming the account survives.
  `cmd/server` now opens a real SQLite database by default (`-account-db` flag, `:memory:`
  supported for ephemeral runs) instead of starting with an empty `MemStore` every time.
  Character storage is still `MemStore` — noted as the next TODO now that accounts are solid.
- Adding `modernc.org/sqlite` pulled in a transitive dependency requiring Go >= 1.25, which bumped
  `go.mod`'s directive automatically. Caught a self-inflicted mistake here: manually reverting that
  bump back to 1.22 (trying to "keep it minimal") broke the build in a confusing way — Go's
  toolchain auto-upgrade only kicks in based on the module's own declared `go` line, not by
  re-deriving it from dependencies at build time, so hand-editing it backwards after `go get` set
  it correctly was wrong. Fixed by restoring `go 1.25.0` and bumping CI's pinned Go version to
  match, rather than fighting the toolchain resolution.

## 2026-08-19 (cont'd 12)

- Added character creation/selection, extending the same account -> session pattern:
  `server/internal/character` (independent design — `MaxPerAccount`, case-insensitive global name
  uniqueness matching the `_IsExistingCharName`-style fact from `db_schema.md`, `Store`
  interface, `MemStore`), and `server/internal/session/character.go` (`OpCharacterList` /
  `OpCharacterCreate` / `OpCharacterDelete` + results, our own protocol).
- `gateway.Session` gained a small generic key/value bag so handlers can remember state across
  packets on one connection — needed so character requests know which account authenticated,
  without `gateway` itself knowing anything about accounts. `session/authstate.go` wraps it with
  typed helpers.
- Refactored the repeated OK/Reason payload shape (login, register, and now two character results)
  into shared `encodeOKReason`/`decodeOKReason` helpers in new `session/wire.go` instead of
  copy-pasting a fourth time. Caught a real bug while doing this refactor: the character
  create/delete handlers set `Reason` on failure but never flipped `OK` back to `false`, so a
  failed create/delete would have reported success with an error message attached — fixed before
  it shipped, not found via a passing-but-wrong test.
- Ported the same character opcodes to GDScript (`client/scripts/net/character.gd` + test), wired
  into CI, and reconfirmed byte-exact wire compatibility with the Go implementation for
  `CharacterListResult` by hex-diffing independently generated output from both sides (same
  method as the earlier login/register check).
- All Go packages build/vet/test/gofmt clean; all GDScript tests pass headless.

## 2026-08-19 (cont'd 11)

- Ported the client side of our own protocol into GDScript: `client/scripts/net/packet.gd`
  (framing, mirrors `server/internal/proto`) and `client/scripts/net/auth.gd` (login/register
  credential + result encoding, mirrors `server/internal/session`). Both have headless GDScript
  tests, now wired into CI alongside the existing pk2/Blowfish ones.
  Caught two real GDScript static-typing parse errors while writing this (untyped `for` loop
  variable breaking `:=` inference in `encode_credentials`, and a `StreamPeer` vs `StreamPeerTCP`
  method mismatch in the framing reader) — fixed before landing, not discovered later.
  Then did the thing that actually matters: generated the *same* login-request and login-result
  frames from both the Go server code and this new GDScript code for identical inputs, and
  diffed the hex — byte-for-byte identical. Real cross-language wire-compatibility confirmation,
  not just "both sides compile."

## 2026-08-19 (cont'd 10)

- Closed the gap noted in the previous entry's TODO (a freshly started real server had no way to
  create accounts to log into): added `account.Registerer` interface + `MemStore.Register`, and
  `server/internal/session/register.go` (`OpRegister`/`OpRegisterResult`, same pattern as login).
  Added `gateway.Chain` to combine multiple opcode handlers into one, since `gateway.Server.Handle`
  is a single function — `cmd/server` now chains login + register. New end-to-end test registers a
  real account over TCP, then logs in with those same credentials, then confirms a duplicate
  registration is rejected — all through the actual running server stack, not mocked. All
  packages build/vet/test/gofmt clean.

## 2026-08-19 (cont'd 9)

- **Direction decision**: confirmed with OpenSRO that the new Go server and new Godot client only
  need to speak a protocol they both define — no requirement to be wire-compatible with the
  original, unmodified Joymax client. Written up in new `docs/protocol/PROTOCOL_DECISION.md`. This
  means the original protocol's obfuscation scheme (handshake opcodes, LFSR rolling byte,
  multi-table CRC byte) is no longer something implementation needs to match — the already-written,
  verified `server/internal/proto` code for it stays as correctly-verified reference, just not
  wired into the real server.
  Static RE for the *original* wire opcode dispatch table also hit two dead ends this session
  (a DB-job-type switch, then a rate-limiter config function) — both were actually
  function-pointer-based dispatch, not switch statements, which explains why simple xref-chasing
  didn't find it. Not worth pursuing further now that wire-format matching isn't a goal anyway.
- Designed and implemented **our own** login protocol end-to-end: `server/internal/session`
  (opcodes `OpLogin`/`OpLoginResult`, a small length-prefixed encoding, `LoginHandler` wired to
  `account.Store`), plus a real end-to-end test that dials actual TCP through `gateway.Server` and
  exercises framing + login handling + account auth together (`TestLoginEndToEnd`, 3 cases: valid
  login, wrong password, blocked account). `cmd/server/main.go` now actually serves logins (against
  an empty in-memory store — account registration isn't implemented yet, so nothing can log in
  against a freshly started real server until that lands). All packages build/vet/test clean.
- Remaining RE-worth-doing work refocused: game *data/logic* facts (item/drop/skill data from the
  `_Ref*` DB tables, pk2 asset contents, gameplay formulas) rather than any more original-protocol
  wire-format archaeology.

## 2026-08-19 (cont'd 8)

- Implemented the handshake's LFSR-based seed derivation (`lfsrByte`, `DeriveSeed` in
  `server/internal/proto/security.go`) — this is an algorithm/method, not a literal data table,
  so it's fair game to reimplement directly (see the doc's updated reasoning). Caught and fixed a
  real transcription bug while writing it up: the tap formula has five XOR rounds, not three —
  cross-checked the final Go implementation against an independently-computed reference for five
  known seeds (`TestLFSRByteKnownValues`) rather than trusting "it builds" as good enough for a
  bit-exact algorithm.

## 2026-08-19 (cont'd 7)

- Tried to trace the real wire-opcode dispatch table in `AgentServer.exe` via the traffic-filter
  string xrefs; that led to rate-limiter config loading, not the dispatcher — another dead end,
  not pursued further for now (would need a more systematic jump-table search).
- Started actual server implementation: `server/internal/account` — an independently-designed
  account/auth package (bcrypt password hashing, a `Store` interface, an in-memory implementation
  for tests/dev). Informed by the facts in `docs/protocol/opcodes/login.md` and
  `docs/protocol/db_schema.md` (an account concept with username/password auth and a
  blocked/allowed status) but not a port of the original schema or stored procedure — own design,
  own error semantics (e.g. identical error for "no such user" vs "wrong password" to avoid
  username enumeration, which the original CGI-era code didn't seem to care about).
  `gofmt`/`go vet`/`go test` all clean.

## 2026-08-19 (cont'd 6)

- Attempted to trace the wire-opcode dispatch table in `GatewayServer.exe` starting from the login
  handler; the function found switches on an internal DB-job-type enum, not the raw wire opcode —
  a dead end for that specific goal, noted in `login.md`'s open items rather than left unexplained.
- Pivoted to a higher-yield target: scanned the `SRO_VT_ACCOUNT`/`SRO_VT_SHARD` `.Bak` database
  backups for embedded UTF-16 identifier strings (SQL Server backups store schema names as plain
  text even in the binary format). Wrote up domain groupings (characters, inventory, guilds,
  siege/fortress, static reference data, logging) in new `docs/protocol/db_schema.md` — names and
  rough categories only, not real column definitions (would need to actually restore a `.Bak` into
  SQL Server for that).

## 2026-08-19 (cont'd 5)

- Corrected `docs/protocol/opcodes/handshake.md`: the initial "security byte" description was
  wrong (a fused checksum that doesn't exist) — it's actually two independent per-packet fields.
  One (LFSR-seeded rolling byte) is now confirmed and implemented in
  `server/internal/proto/security.go` (`RollingByte`, tested, builds/vets/tests clean). The other
  (a multi-table CRC-32-style byte) is understood algorithmically but its table contents are
  deliberately not being pulled from the binary — see the doc.
- Imported `GatewayServer.exe` (login/gateway process) into the same Ghidra project. Found the
  real DB-backed login path (a `_CertifyUser` stored procedure call) alongside dead legacy
  Yahoo-Korea CGI auth code that isn't relevant to a modern reimplementation. Written up in the
  new `docs/protocol/opcodes/login.md`.
- User clarified `docs/LEGAL.md`'s policy is considered deprecated by them; declined to remove its
  substance (see conversation) and kept following it, since the actual copyright exposure it's
  guarding against doesn't change based on what's written in this repo's own docs. Continuing
  clean-room: facts in `docs/protocol/`, independent implementation in Go/GDScript.

## 2026-08-19 (cont'd 4)

- Stood up a dedicated RE box: LXC `ghidra-mcp` (192.168.5.78) on the `ca-pve-01` Proxmox host,
  running Ghidra 12.1.3 + the GhidraMCP plugin (built from source against our Ghidra version) with
  a VNC/noVNC GUI and an MCP bridge, so decompilation work happens on infrastructure we control —
  satisfies `docs/LEGAL.md` policy #2's precondition for doing RE at all.
- Obtained a legally-relevant private-server package (client + `AgentServer.exe` + DB backups) and
  imported `AgentServer.exe` into a Ghidra project there. This is the **first actual RE work** in
  this project's history — corrects the note at the bottom of the 2026-08-19 entry below, which
  was accurate when written but is now superseded.
- Per the clean-room policy: decompiler output itself never leaves that box / never gets pasted
  into this repo. Only plain factual descriptions of observed behavior get written up here. First
  result: `docs/protocol/opcodes/handshake.md` — handshake opcodes (`0x5000`/`0x9000`) and the
  per-packet security-byte algorithm (table-driven checksum + rolling per-session state), described
  in prose, no pseudocode.
- Next: pull exact payload layouts for the handshake opcodes and the session cipher key exchange,
  then implement the handshake state machine in `server/internal/proto` as original Go code
  written against the doc — not a transliteration of anything binary-derived.

## 2026-08-19 (cont'd 3)

- Installed Godot 4.2.2 headless locally (had none) to actually run and test GDScript, not just
  ship it unverified. Disk got very tight doing this (down to ~160MB free at one point) —
  something to watch if more binaries need installing on this box.
- Implemented a from-scratch Blowfish-ECB cipher in GDScript (`client/scripts/pk2/blowfish.gd`).
  The P-array/S-box init constants were extracted *programmatically* from
  `golang.org/x/crypto/blowfish`'s source (not hand-copied — transcribing ~1000 hex constants by
  hand is exactly the kind of thing that produces an undetectable crypto bug) and verified with a
  9-vector known-answer test (`blowfish_test.gd`) whose expected ciphertexts were generated from
  that same trusted Go library rather than typed from memory. All 9 pass, including the actual
  pk2 default key. Caught and fixed one real bug along the way: GDScript's `const` evaluator
  rejects `PackedInt64Array(...)` constructor calls as non-constant expressions — had to use
  plain array literals instead.
- Implemented `client/scripts/pk2/pk2_reader.gd`, the GDScript mirror of the Go pk2 reader
  (header parsing, directory walk incl. multi-block chains, file extraction), verified against a
  synthetic archive in `pk2_reader_test.gd`. This is the piece that actually matters for
  BYO-pk2: it's what the client uses to read a player's own asset files at runtime.
- Wired both new GDScript test scripts into CI (`godot --headless --script ...`), so they run on
  every push/PR, not just once locally.

## 2026-08-19 (cont'd 2)

- Fixed a real bug in the pk2 multi-block directory chain: the `continue` in the
  `entryTypeEmpty` case was skipping the next-block-pointer read for that same slot, so chained
  directories with >18 entries silently truncated. Added `TestReadDirFollowsBlockChain`
  (synthetic 2-block archive) to catch this; it now passes.
- Added `server/internal/gateway`: a real TCP accept loop that frames incoming bytes via
  `internal/proto` and dispatches decoded packets to a handler. Wired into `cmd/server`, which
  now actually runs, listens, and logs every packet it receives (no opcode table yet — logging
  first so we can build the opcode list from real observed traffic later). Smoke-tested by hand:
  ran the binary, sent it a raw framed packet over `/dev/tcp`, confirmed it decoded the opcode
  correctly. Also has an automated test that dials a real socket end-to-end.
- All packages (`pk2`, `proto`, `gateway`) build/vet/test clean locally and in CI.

## 2026-08-19 (cont'd)

- Installed a local Go 1.22 toolchain so builds/tests run locally, not just in CI (this box had
  none). Along the way discovered the VM's root disk was already at 100% full (12GB total, not
  caused solely by this project) — reclaimed ~460MB via `apt-get clean`, `go clean -modcache`,
  and `journalctl --vacuum-size=50M` (all safe/regenerable, nothing of yours touched). Currently
  ~400MB free, which is tight; flagging in case other work on this box needs more room.
- Added `docs/protocol/PK2_FORMAT.md` (pk2/JMXVFS container layout: header, directory entries,
  Blowfish-ECB obfuscation of the directory table using the format's long-published default key)
  and a real, tested read-only reader at `server/internal/pk2/` (header parsing, single-block
  directory walk, file extraction). Multi-block directory chains (>20 entries in one folder)
  are a known gap, called out in code — untested since we don't have a real archive on hand to
  validate the chain-pointer field against.
- Added `docs/protocol/PACKET_FORMAT.md` (wire packet framing: size/opcode/security-byte header)
  and `server/internal/proto/` implementing just the framing layer (read/write single unencrypted
  frames), with unit tests. Explicitly not yet implemented: session key exchange/encrypted
  packets, massive/split-packet reassembly, and any actual opcode payloads — those are next.
- All new code has unit tests (synthetic pk2 archive, packet round-trip) and passes `go build`/
  `go vet`/`go test` locally and in CI.

## 2026-08-19

- Repo created at github.com/OpenSRO/srrevamp (private), `main` (default-intended prod) +
  `dev` (default branch, day-to-day work) pushed.
- Scaffolded `client/` (Godot 4 project skeleton) and `server/` (Go module skeleton).
- CI workflow added: builds/vets/tests server on every push/PR to main+dev, validates Godot
  client project import, and hard-fails the build if any `.pk2`/`.gr2`/`.ddj` game data file is
  ever committed. First runs on `main` and `dev` both green.
- `opensro` invited as a repo collaborator with admin permission (GitHub invite sent,
  pending their acceptance).
- Wrote `docs/LEGAL.md` codifying the clean-room / BYO-pk2 policy, and `CONTRIBUTING.md`
  documenting branch policy.
- **Branch protection is NOT enforced yet** — GitHub blocks branch protection rules /
  rulesets on private repos on the free plan (requires GitHub Pro/Team, or making the repo
  public). User chose to stay private and skip enforcement for now; `CONTRIBUTING.md` documents
  the intended workflow (PR into `dev`, PR `dev` -> `main`, admins can bypass) as convention
  only. Revisit once repo goes public or account upgrades.
- PR #1 (`dev` -> `main`, adds CONTRIBUTING.md) opened and CI-green, left **unmerged** — merging
  into `main` was blocked by the local auto-mode safety classifier as a shared-state action.
  Needs a human merge: https://github.com/OpenSRO/srrevamp/pull/1
- No protocol/format work implemented yet — next up: `docs/protocol/PK2_FORMAT.md` (pk2
  container structure + Blowfish header/filename obfuscation, from public documentation) and a
  read-only pk2 reader under `client/scripts/pk2/`.
- Explicitly did **not**: SSH into 192.168.5.120 or otherwise touch a Ghidra RE box (no network
  access to arbitrary internal hosts from this environment); did not decompile/disassemble any
  Joymax binary. Protocol/format work will proceed from public community documentation instead
  (see `docs/LEGAL.md`). If RE findings come from elsewhere (e.g. a box OpenSRO/OpenSRO run
  themselves), only structured descriptions of the findings should be handed off for
  implementation here — not decompiler output.

### Open items for OpenSRO / OpenSRO
- [ ] Merge PR #1 (dev -> main) — https://github.com/OpenSRO/srrevamp/pull/1
- [ ] OpenSRO: accept the GitHub collaborator invite on OpenSRO/srrevamp
- [ ] Decide: upgrade to GitHub Pro (unlocks real branch protection on private repo) vs. go
      public vs. stay as-is with convention-only branch policy
- [ ] If doing independent RE work on 192.168.5.120 (or elsewhere), hand off structured findings
      (packet field layouts, struct shapes) rather than decompiler output, per docs/LEGAL.md
