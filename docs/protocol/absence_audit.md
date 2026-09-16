# Audit of srrevamp's "nothing to recover here" claims

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
| `trade` | STRG (deal codes) | holds; the two exploit questions it raised were checked and srrevamp was already correct |
| `duel` | 2 codes, both free-PvP mode changes | **holds** — no duel challenge/accept/refuse family exists |
| `quest` | 4 genuine codes (Roc entrance, trap-making) | **holds** — specific mechanics, no system limit |
| `berserk` | 1 code, `HWANITEM_CANNOT_USE`, about an item | holds — and the mechanic was separately recovered anyway |
| `mana` | none | **holds** — and a separate search already established the engine has no passive regen |
| `leveldata` | none | holds |
| `rates` | none | holds — the knobs were recovered from the config loader, not an error path |
| `combat` (loot) | none | holds — needs operator drop tables, already disclosed |
| `character` | none | holds — creation lives on the AgentServer, already disclosed |
| `world` | none | holds |

## What this leaves

For the packages above, the *values* half of the project's goal is as closed as
this lever can make it. What remains is the harder half: **naming functions**,
where the server sits at 21.7% and the client at 14.8%.
