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

## What the server would need (not yet built)

1. **Load the EXP curve at runtime.** `leveldata.txt` is game data, so it cannot be committed — it
   is imported like the item refdata (a `leveldata.csv` the operator generates + an importer, or the
   server reading the table from a BYO path). Until then, no leveling.
2. **Track EXP and grant it on a kill.** The kill reward path already grants gold; add EXP.
3. **Level up** when EXP crosses the row's threshold: raise level, carry the remainder, grant 3 stat
   points, refill HP/MP, broadcast so the client can play the level-up effect.
4. **Store Str/Int + unspent stat points**, and a "spend a point" request.
5. **Derive the combat stats** (HP from Str, MP from Int, phys/mag atk·def, etc.) — those formulas
   still need recovering from the client (Ghidra) before the character window's derived numbers are
   real; the character window shows level/EXP/stat-points/HP first, the derived stats once recovered.

## Client

- **Character window** rebuilt to the real layout (Current/Next Exp, Stat Point, Str/Int with "+"
  buttons, HP/MP, derived stats) — recover the layout from the client, per the answer.
- **Level-up animation**: the golden burst + "You have advanced to level [N]" on the level-up
  broadcast.

## Skills / mastery

Separate system, real data in `skilldata` / `skillmasterydata` (and the Ghidra server) — its own
recovery pass. See `docs/FRONTEND_CHECKLIST.md`.
