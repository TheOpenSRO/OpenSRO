# Leveling, EXP and stats — recovered from the client

The systems behind the character window (EXP/level, Str/Int stat points) and the level-up event,
recovered from the client's own data rather than designed, per the standing rule. Nothing here is
committed as data — the tables live in the player's own Media.pk2 and must be imported at runtime,
the same way item reference data is (see `deploy/README.md`).

## The EXP curve — `server_dep\silkroad\textdata\leveldata.txt`

UTF-16LE, tab-separated, one row per level, 139 levels. **Column 1 (0-indexed) is the EXP required
to advance from that level to the next.** Verified against a real character window: level 9's value
is `17978`, which is exactly the "Next Exp" a level-9 character showed. Sample:

| Level | EXP to next (col 1) |
|---|---|
| 1 | 118 |
| 2 | 470 |
| 3 | 1058 |
| 8 | 13160 |
| 9 | 17978 |
| 10 | 23500 |
| 11 | 34898 |

**Column 1 is grounded in the binary too (round 294, 2026-09-20).** The live
"Next Exp" match above is one witness; the server is the other.
`GObjPC::GObjPC_SetLevel` stores the level row on the character at `+0x1cb0`
(indexing the per-level vector by `level - 1`), and
`GObjPC::GObjPC_GainExpAndLevel` reads **`row+8` / `row+0xc` as a 64-bit pair**
-- adding to it, dividing by it with `__alldiv`, and walking successive rows to
carry several levels in one gain. The same record's `+0x1c` is column 5, the
exp unit `cmd/export-leveldata` already cites, so both offsets sit in one
record. That is why `leveldata.Table.expToNext` is `int64` and not `int`.

The gold pet reads **the same field of the same table** for its own level-up
threshold (`docs/protocol/pets.md`), so pet and character levelling share one
curve.

Other columns (10 total; cols 2/5/6-8 look job/cost/gold-related) are not needed for basic
leveling and are left unread until a use for them is pinned. **leveldata.txt carries no per-level
HP/MP** — those come from a derived-stat formula not yet recovered.

### The carry/cap behaviour is recovered too (not assumed)

From `sro_client.exe`'s EXP handler `FUN_008a97c0` (2026-09-11, see `docs/GROUNDING_AUDIT.md`):
on a gain, each level's requirement is subtracted from the running EXP and the level incremented
in a loop — **excess EXP carries into the next level**. The loop caps `while (level != 'n')`,
where `'n'` is 0x6E = **110**, so the character cap is level 110 regardless of the table having 139
rows. At the cap the bar is **held at that level's requirement minus one**, not zeroed.
`leveldata.Advance` and `MaxCharacterLevel` now match this.

## Stat points — 3 per level

A real character window showed **Stat Point 24 at level 9**, and (9 − 1) × 3 = 24, so a character
gets **3 stat points per level**, spent into Str or Int (the character window's "+" buttons). This
is a rule, not a table value. A new character is level 1 with 0 spent points.

## Server work — status

1. **Load the EXP curve at runtime.** ✅ **Built.** `leveldata.txt` is game data, so it is not
   committed: `cmd/export-leveldata` turns a client's own `leveldata.txt` (UTF-16LE) into a small
   `level,exp` CSV, and `internal/leveldata` parses it into a `Table` with the level-up math
   (`Advance`). An operator points the server at the CSV (`SRREVAMP_LEVELDATA_CSV`); without it,
   characters do not level. Both are tested (level 9 = 17978 pinned).
2. **Character fields.** ✅ **Built.** `character.Character` gained `Exp` (progress at the current
   level) and `StatPoints` (unspent, `leveldata.StatPointsPerLevel` = 3 per level), with a
   `SetLeveling` store method (memstore + sqlstore, migrated).
3. **Grant EXP on a kill + level up + broadcast.** ✅ **Built.** The kill path (`performAttack`)
   now, when a curve is loaded, reads the character, runs `Table.Advance`, grants
   `StatPointsPerLevel` per level gained, and on a level-up refills HP and sends an `OpLevelUp`
   (`0x0067`, payload `NewLevel:int32, StatPoints:int32` LE) right behind the `OpAttackResult`,
   direct to the attacker. Without a curve loaded, no exp is tracked (like flat damage with no
   item table).
4. **Str/Int + spending the points.** Half built. `character.Character` now carries `Str` and
   `Int` (migrated, defaulting to the disclosed starting 20/20), and health and mana derive from
   them. **Spending** the accumulated points is still to come — the server has
   `GObjPC_SpendStatPoints` (`00511470`) recovered as the reference: it moves points from
   `charData+0x84` into `+0x74`/`+0x76` and pushes the new values into the keeper.
5. **Derive the combat stats.** ✅ **HP and MP done (2026-09-15), recovered in full:**
   `MaxHP = Str × 10 × 1.02^(level−1)` and `MaxMP = Int × 10 × 1.02^(level−1)`, read out of
   `SR_GameServer.exe`'s own derived-stat graph — see `docs/GROUNDING_AUDIT.md` for the chain and
   how the parameter ids were pinned. Phys/mag atk·def are the next ones; the same graph carries
   them (`GObjMob_PublishStats` publishes ids 5/6 and 11/12 from the monster ref object).

## Client

- **Level-up animation** ✅ **Built** — `client/scripts/effects/level_up_effect.gd`. On `OpLevelUp`
  (decoded in `net/combat.gd`, surfaced as `NetClient.level_up`), `World3D._on_level_up` logs the
  **real** recovered message and plays the burst on the player.
  - **Real (recovered from the client):** the meshes and textures. The four core primitives from
    `system\system_levelup.efp` (Particles.pk2) — `levelup01.bms`→`won-light-up-i.ddj`,
    `levelup02`→`won-light-up-sb`, `levelup03`→`hoon-out-light-02`, `levelup04`→`sdamage-wb-01` —
    with the mesh↔texture pairings read straight off that effect's RenderMesh node stream (see
    `docs/WORLD_ISSUES.md`). Loaded at runtime from the player's own Particles.pk2, never committed.
    The message is `UIIT_MSG_STRGERR_LEVEL` "You have advanced to level [%d]." from
    `textuisystem.txt`, looked up at runtime and the level substituted into its own `[%d]`.
  - **Designed (disclosed, not recovered):** the animation itself — timing (`LIFE`), per-layer
    grow/overshoot/spin and the additive fade. The `.efp`'s real `ScaleGraph`/`DiffuseGraph`
    keyframe layout is **not** reliably recovered (the reader flattens the tagged tree to
    `(name, raw-bytes)`, and a float decode of the graph block fits cleanly on only ~a third of
    this file's ScaleGraph nodes — see `docs/protocol/EFP_FORMAT.md`), so the exact curves are not
    driven from it. Only the burst's *size* is data-driven: each layer is normalized to the
    player's own rendered height.
- **Character window**: rebuild to the real layout (Current/Next Exp, Stat Point, Str/Int with "+"
  buttons, HP/MP, derived stats) — recover the layout from the client, per the answer. Still to do;
  the stat-point count the window shows is already carried on `OpLevelUp`.

## Skills / mastery

Separate system, real data in `skilldata` / `skillmasterydata` (and the Ghidra server) — its own
recovery pass. See `docs/FRONTEND_CHECKLIST.md`.
