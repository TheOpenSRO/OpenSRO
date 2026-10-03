# The client's own names for the stat vocabulary

163 `PARAM_*` localisation keys, harvested from the client dump on 2026-09-16.
They matter because they are **the game's own English wording**, and they have
already corrected this project twice: `'era'` is *parry* rate rather than
evasion, and `'hra'` is *attack* rate rather than hit rate.

This file joins them to the vocabulary recovered server-side — the tag
dispatcher (`param_tags.md`), the skill param codes (`skill_params.md`) and the
param registry (`param_registry.md`).

## The joins are in two tiers, deliberately

A client key whose suffix **equals** a server tag or code is the game naming that
thing. A key that merely *resembles* one is an abbreviation argument, which is
exactly the reasoning that got characterdata column 79 wrong twice. The two are
not mixed below.

### Tier 1 — exact suffix match

| client key | server tag/code | param id |
|---|---|---|
| `PARAM_STR` | `str` | 1 |
| `PARAM_INT` | `int` | 2 |
| `PARAM_HP` | `hp` | 3 |
| `PARAM_MP` | `mp` | 4 |
| `PARAM_ER` | `er` | — (dispatcher ignores it) |
| `PARAM_HR` | `hr` | — (skill code) |
| `PARAM_FZ` | `fz` | 27 |
| `PARAM_ES` | `es` | 29 |
| `PARAM_BU` | `bu` | 30 |
| `PARAM_PS` | `ps` | 31 |
| `PARAM_ZB` | `zb` | 32 |
| `PARAM_LUCK` | `luck` | — (dispatcher ignores it) |
| `PARAM_DURA` | `dura` | — (dispatcher ignores it) |
| `PARAM_CK` | `ck` | — (skill code) |
| `PARAM_DA` | `da` | — (skill code) |
| `PARAM_KB` | `kb` | — (skill code) |
| `PARAM_RU` | `ru` | 33 |
| `PARAM_IRGC` | `irgc` | 25, 26 |
| `PARAM_HSTE` | `hste` | 23, 24 |
| `PARAM_EXPU` | `expu` | 186, 202 |

### Tier 2 — plausible, NOT proven

Each of these is an abbreviation argument and nothing more. They are listed so a
later pass can settle them at a use-site, not so they can be quoted as answers.

| client key | candidate | why it is only a candidate |
|---|---|---|
| ~~`PARAM_REPAIRING_CHARGES`~~ | ~~`rep`~~ | **PROMOTED 2026-09-16**: `magicoption.txt` gives `rep` the name MATTR_REPAIR outright, so this is no longer an abbreviation argument |
| `PARAM_LIFE_STEAL` | `lfst` | initials, not the string |
| `PARAM_TIME_BOMB` | `tb` | initials |
| `PARAM_RESU` | `resu` | exact, but `resu` has no confirmed server id yet |
| `PARAM_TRANS` | `tran` | prefix |
| `PARAM_TELE` | `tele` | prefix |
| `PARAM_HEAL_HP` / `PARAM_HEAL_MP` | `heal` | prefix |
| `PARAM_CURE_*` (7 keys) | `cura`, `curt`, `rcur` | prefix, and three codes to three-plus keys |

## What this independently CONFIRMS

Two of the joins land on values OpenSRO already ships, derived by completely
different routes — which is the useful kind of agreement:

- **`PARAM_MC_COUNT` ↔ `mc`.** `refdata.HitCount` / `HitsFor()` was recovered
  from the `mc` param's `(2, N)` shape with N in 1..5, with no reference to the
  client at all. The client calls it a COUNT. Independent agreement.
- **`PARAM_HWAN_TIME_INCREASE` ↔ `hwit` ↔ param 195.** The berserk duration
  chain — `dur = GetParam(60) + GetParam(195)`, base 60 — was recovered from the
  activation handler's disassembly, and `hwit → 195` from the skill-code join
  over `Skill_ApplyEffectsToParams`. The client names 195 "Hwan time increase".
  Three separate derivations meeting is the strongest confirmation available
  here.

## The seven tags the server's dispatcher ignores

All seven have client display names, which settles the narrowing this project
had to make: they are live game concepts, not dead strings.

	astr -> PARAM_ASTRAL        atha -> PARAM_ATHANASIA
	dura -> PARAM_DURA          er   -> PARAM_ER
	luck -> PARAM_LUCK          rep  -> PARAM_REPAIRING_CHARGES
	soli -> (no key found)

`rep` and `dura` are worth a sentence: repairing charges and durability are
**item condition fields**, not character stats, which is a clean reason for the
stat dispatcher to skip them. That is an explanation the tier-2 caveat does not
undermine — `PARAM_REPAIRING_CHARGES` sitting beside `PARAM_DURA` in the same
key set is itself the evidence, independent of whether `rep` is short for
"repairing".

## Names with no server-side match yet

Worth mining next; each is a game concept the server vocabulary has not been
joined to: `PARAM_ABSORB`, `PARAM_AGGRO`, `PARAM_CHAOS`, `PARAM_CURSING`,
`PARAM_DETECT`, `PARAM_DISEASE`, `PARAM_INVISIBLE`, `PARAM_KO`,
`PARAM_MP_ABSORB_RATE`, `PARAM_MYOPIA`, `PARAM_REFLECT`, `PARAM_ROOT`,
`PARAM_SLEEP`, `PARAM_SLOW`, `PARAM_STEALTH`, `PARAM_STONE`, `PARAM_STUN`,
`PARAM_WEAKLY`.
