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

Other columns (durability/gold/job-exp-looking values) are not needed for basic leveling and are
left unread until a use for them is pinned.

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
3. **Grant EXP on a kill + level up + broadcast.** ⏳ next — the kill path grants gold; add EXP,
   run `Table.Advance`, grant stat points, refill HP, and send an `OpLevelUp`.
4. **Str/Int + spending the points.** later — the stat system; needs the derived-stat formulas.
5. **Derive the combat stats** (HP from Str, MP from Int, phys/mag atk·def) — recover from the
   client (Ghidra) before the character window's derived numbers are real. The window can show
   level / EXP / stat-points / HP first, the derived stats once recovered.

## Client

- **Character window** rebuilt to the real layout (Current/Next Exp, Stat Point, Str/Int with "+"
  buttons, HP/MP, derived stats) — recover the layout from the client, per the answer.
- **Level-up animation**: the golden burst + "You have advanced to level [N]" on the level-up
  broadcast.

## Skills / mastery

Separate system, real data in `skilldata` / `skillmasterydata` (and the Ghidra server) — its own
recovery pass. See `docs/FRONTEND_CHECKLIST.md`.
