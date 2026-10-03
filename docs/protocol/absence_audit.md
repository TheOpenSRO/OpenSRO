# Audit of OpenSRO's "nothing to recover here" claims

Fifteen packages under `server/internal/` carry a comment saying some value is
own design, or that there is no real data to recover. Those read like settled
conclusions and are quoted as such by later work — but **two of them were simply
wrong**, and neither had ever been tested:

- `party.MaxSize`: *"Own design, and NOT grounded"* — the engine enforces a cap
  at join time, 8 for an exp-sharing party and 4 otherwise.
- `friend`: *"Entirely own design; no real friends-list data to RE"* — the server
  has a friend system with its own error family and a list cap of 20.

Both are now recovered. This file records the sweep that followed, so the
surviving claims are **tested** rather than merely asserted.

## The test

The server refuses actions with numeric codes that the client maps to
`UIIT_*` message names (see [`error_codes.md`](error_codes.md)). **A system that
exists in the server almost always has an error family**, so the presence of one
is good evidence a subsystem is there to recover, and its absence is evidence the
server has no such subsystem.

**What this does NOT prove.** An absent error family does not mean nothing is
recoverable — a constant reached on no failure path leaves no code. It narrows
where to look; it does not close the question. Every "holds" below means *no
engine error family was found*, not *nothing exists*.

**A caveat on the probe itself.** Substring matching produces false positives
freely: a first pass matched `mana` against `FORT_MANAGER`, `leveldata` against
`RENT_EXP_ITEM`, and `quest` against `REQUESTED_JOB`, `QUESTION_GUILD` and
`FREQUEST_WAR`. Match the domain **prefix** (`UIIT_MSG_<DOMAIN>ERR_`), not the
word anywhere in the name.

## Verdicts

| package | engine error family | verdict |
|---|---|---|
| `party` | PARTY, 19 codes | **was wrong** — cap 8/4 and creation level 5 recovered |
| `friend` | FRIEND, 8 codes | **was wrong** — list cap 20 recovered |
| `guild` | GUILD, 61 codes | **was incomplete** — member cap and permission mask recovered |
| `inventory` | STRG, 92 codes | **was incomplete** — bounds and the quantity guard recovered |
| `trade` | STRG (deal codes) | holds; the two exploit questions it raised were checked and OpenSRO was already correct |
| `duel` | 2 codes, both free-PvP mode changes | **holds** — no duel challenge/accept/refuse family exists |
| `quest` | 4 genuine codes (Roc entrance, trap-making) | **holds** — specific mechanics, no system limit |
| `berserk` | 1 code, `HWANITEM_CANNOT_USE`, about an item | holds — and the mechanic was separately recovered anyway |
| `mana` | none | **holds** — the "no passive regen" this row once cited was wrong (2026-09-16: the 4 s timer; round 607: the rate is 0.8% of the maximum standing, 8% sitting, `docs/protocol/opcodes/motion.md`) |
| `leveldata` | none | holds |
| `rates` | none | holds — the knobs were recovered from the config loader, not an error path |
| `combat` (loot) | none | holds — needs operator drop tables, already disclosed |
| `character` | none | holds — creation lives on the AgentServer, already disclosed |
| `world` | none | holds |

## What this leaves

For the packages above, the *values* half of the project's goal is as closed as
this lever can make it. What remains is the harder half: **naming functions**.

**CORRECTED 2026-09-17: the server is at 5.3% and the client at 3.0%**, not
21.7% and 14.8%. The old figures counted `vslot_NNN` — a vtable slot number
applied by the RTTI plate pass — as a real name. `SymbolReport.java` tested
`!name.startsWith("FUN_")`, and `vslot_395` passes that test while saying
nothing about what the function does.

The arithmetic reconciles exactly, which is how the mechanism was confirmed:

	server   1,825 named + 5,617 slotted = 7,442   (recorded: 7,386, 21.7%)
	client   1,285 named + 5,136 slotted = 6,421   (recorded: 6,432, 14.8%)

The tool now reports four tiers — NAMED, SLOTTED, ATTRIBUTED, UNKNOWN — because
a slot number is the same kind of knowing as a module name: **where a function
lives, not what it is.** Its own header had already warned that folding
attribution into naming "would flatter the number"; the warning was right and
was being applied to the wrong tier.

| | server | client |
|---|---:|---:|
| NAMED (a real name) | **1,825 (5.3%)** | **1,285 (3.0%)** |
| SLOTTED (vtable slot only) | 5,617 | 5,136 |
| ATTRIBUTED (module only) | 14,473 | 13,565 |
| UNKNOWN | 12,198 | 23,474 |

**Re-measured 2026-09-20 (round 305), after applying 271 filed-but-unapplied
names and rebuilding both dumps.** Same tool, same tiers:

| | server | client |
|---|---:|---:|
| NAMED (a real name) | **5,355 (15.7%)** | **2,219 (5.1%)** |
| SLOTTED (vtable slot only) | 2,579 | 4,349 |
| ATTRIBUTED (module only) | 14,300 | 13,500 |
| UNKNOWN | 11,973 | 23,494 |
| identified | 22,234 (65.0%) | 20,068 (46.1%) |

**Where the server's three-fold rise came from, and it is not the apply.** The
264 names applied this round are a small part of it. The large movement is
`SLOTTED` falling **5,617 → 2,579**: roughly three thousand functions that were
known only by a vtable slot number now carry a real name, from the slot
propagation of the intervening rounds. A function moving from SLOTTED to NAMED
is the tier boundary this page exists to police, and it moved the right way.

The client barely moved (3.0% → 5.1%) because almost none of that work was done
on it, and its UNKNOWN tier is unchanged at ~23,500 — still the honest floor.
| — of those, real bodies | 11,495 | 21,270 |
