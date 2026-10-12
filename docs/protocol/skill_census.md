# The player skills' Param codes, census and status (round 785)

`cmd/skillcensus` over the round-785 ENC export (`skills.csv` with the Params column), the RE box's
retail archive, 2026-10-12. **Player rows**: every SKILL_CH_ / SKILL_EU_ row with a mastery and a
learn cost, the base attacks, and every chain link they reach -- 2,944 China, 3,171 Europe
(MEASURED). Counts are rows carrying the code at least once (statistics; no row is reproduced).
Re-run: `skillcensus -skills-csv skills.csv` (`-code X` lists one code's rows locally).

## By mechanic: before and after round 785

| mechanic | codes (rows CH+EU) | before | after (round 785) |
|---|---|---|---|
| the blow | `att` 3,529 | one target, all hits summed, one result | every target, every hit its own blow and record; the 0xAB action block (READ layout) on the answer and the zone's cast |
| multi-hit | `mc` 1,580 | hits summed | per-hit records, kill bit, void hits after a fall |
| area / line / chain targets | `efr` 1,880 | primary only | collectors 1/2/3/4/6 at monsters with cap and falloff; 5/6/1/2 over characters for heals and cures |
| mastery scaling | `getv` MAAT 4,043 | every row with a mastery slot | only rows with `getv MAAT`, both slots weighed (0x59e770) |
| buff / passive stats | `defp` `defr` `hr` `er` `cr` `br` `hpi` `mpi` `apau` `apru` `dru` `odar` `ru` `dcri` `stri` `inti` `pm*` `rhru` ...: 980 learnable rows carry one (MEASURED) | records kept, only the run speed read | written into the defence, parry, block, crit, hit rate, weapon bounds, range, max HP/MP, damage % of the blow; passives (744 rows) apply while known |
| passive variables | `setv` 540 / `getv` keys | none | E1SA/E2SA/E2AA/CBAT/DGHR multiply the blows that read them |
| knockdown / knockback | `ko` 111, `kb` 253, `da` 403 | none | hit kinds 4/5 with the move and the hold; `da` on a downed target |
| state bonus | `atca` 171 | none | x1.5 on a matching state |
| imbues | the `*_GIGONGTA_*` rows | a buff with no effect | their magical add on every hit of skills and plain swings, their states, the lightning chain |
| chains | 1,246 links | the head's blow only | every link resolved at its own time; the last link's hand-off |
| ground moves | `tele` 19, `tel2` 7, `tel3` 21 | Ghost Walk only, untruncated | Ghost Walk, Teleport, Sprint; truncated region-local landing; the move in the block |
| debuffs on monsters | kind-3 hostile Target_Required 1 rows: 170 learnable (MEASURED) | not started | records on the monster (ownerKind 1), their stats in the blow, the linked blow each `puls` |
| heals | `heal` 304 | flat self / one target | + `efr` party and chain heals, heal over time |
| cures | `curl`/`curt`/`rcur` 67 | none | Holder.Cure, broadcast |
| resurrection | `resu` 52 | none | the 0x3080 offer and the revive |
| hate | `tant` 293, `tnt2` 548 | none | computed and credited to the threat table (the AI's retarget is the AI lane's) |
| HP drain | `lfst` 43 | a plain blow | the drain formula; the caster heals |
| abnormal states | 23 codes | done (round 659) | statusBits in the hit record |
| ammunition | `cnsm` 386 | none | **OPEN** (no count on the worn item) |
| stealth / detection / transforms / summons / traps | `hide` 47, `dttp` 36, `msch` 12, `summ` 24, `trap` 25 | recast rules only | **OPEN** |
| defensive links | `dmgr` 21, `lkdr` 26, `lkdd` 20, `lkag` 12, `abnb` 9, `lkdh` 18 | none | **OPEN** (they act on blows a character takes) |

## Every code

| code | CH | EU | status |
|---|---:|---:|---|
| `getv` | 2027 | 2016 | done: MAAT gates the mastery scale; DGHR/CBAT/E1SA/E2SA/E2AA x passive setv; HLRU and the rest open |
| `att` | 2028 | 1501 | done: per target, per hit (skillhit.go); the imbue's value[4] add |
| `efr` | 823 | 1057 | done: kinds 1/2/3/4/6 at monsters, 5/6/1/2 over characters for heals and cures; kind 7 (monster casters) open |
| `mc` | 91 | 1489 | done: every hit its own blow and its own hit record |
| `dura` | 650 | 607 | done (round 616); monster debuffs end at it too |
| `reqi` | 129 | 642 | done (2026-09-16) |
| `tnt2` | 0 | 548 | part: hate computed and credited to the threat table; the AI's retarget by hate is open (mob-threat-retarget) |
| `setv` | 0 | 540 | done: a passive's variables for getv |
| `da` | 57 | 346 | done: x da[0]/100 on a knocked-down target |
| `cnsm` | 269 | 117 | open: no ammunition count in OpenSRO |
| `bu` | 98 | 262 | done (round 659): burn on monsters |
| `heal` | 122 | 182 | done: flat self/target (rounds 503/622), efr party/chain heals, heal over time (puls); mwhh/mwmh open |
| `tant` | 116 | 177 | part: as tnt2; p187 written by a kind-3 row |
| `lnks` | 15 | 269 | part: the linked blow of a monster debuff each puls; the recast links (round 636); lkdr/lkdd open |
| `defp` | 159 | 98 | done: p5/p6 flat (the v2 cap open) |
| `kb` | 84 | 169 | done: hit kind 5, kb[1] units, 2 s hold |
| `fb` | 193 | 48 | done (round 659) |
| `st` | 83 | 153 | done (round 659) |
| `bl` | 67 | 166 | done (round 659) |
| `nbuf` | 42 | 186 | done: the dispel refusal (round 616) |
| `puls` | 0 | 225 | done: bleeding's interval (659), the heal over time and the linked blow (785) |
| `bbuf` | 39 | 174 | done: marker |
| `fz` | 163 | 48 | done (round 659) |
| `atca` | 0 | 171 | done: x (1 + atca[1]/100) on a matching state |
| `cbuf` | 167 | 0 | done: the recast rule (round 636) |
| `sl` | 38 | 128 | done (round 659) |
| `lks2` | 0 | 160 | done: the recast rule (round 636) |
| `ru` | 90 | 48 | done: p33 |
| `es` | 49 | 70 | done (round 659) |
| `onff` | 55 | 61 | done (round 640) |
| `ko` | 68 | 43 | done: hit kind 4, 20 units, (KO_RecoverTime + ActionDuration) + 0.5 s hold |
| `dru` | 42 | 67 | done: p128..131 on a skill's hit |
| `mwhh` | 0 | 106 | open |
| `skc` | 0 | 95 | part: the category end (round 636); break-on-hit open |
| `cr` | 83 | 10 | done: a passive's p12; an attack row's crit term |
| `reqc` | 57 | 34 | open (a cast requirement not read) |
| `hr` | 79 | 8 | done: p11 |
| `ovl2` | 0 | 80 | done (round 636) |
| `efta` | 0 | 73 | done: the spawn's creator byte (646) |
| `pdmg` | 0 | 71 | open |
| `real` | 2 | 66 | open (state immunity tokens) |
| `reat` | 2 | 66 | part: written (p145..150), the status lane reads none |
| `curl` | 40 | 27 | done: Holder.Cure |
| `curt` | 40 | 27 | done: Holder.Cure |
| `rcur` | 40 | 27 | done: Holder.Cure |
| `br` | 56 | 10 | done: p136 in the block chance |
| `apau` | 0 | 64 | done: p13..16 |
| `ps` | 0 | 64 | done (round 659) |
| `reqn` | 0 | 64 | done (2026-09-16) |
| `pw` | 55 | 0 | done (round 640) |
| `resu` | 28 | 24 | done: the 0x3080 offer and the revive; the EXP return open |
| `hide` | 0 | 47 | open (body mode 6/7) |
| `eshp` | 18 | 27 | part: the chain's lowest-HP pick open; the group aura open |
| `mwmh` | 0 | 44 | open |
| `ds` | 0 | 43 | done (round 659) |
| `lfst` | 0 | 43 | open (HP drain) |
| `mwhs` | 0 | 43 | open (with lfst) |
| `er` | 41 | 0 | done: p9 |
| `rt` | 0 | 41 | done (round 659) |
| `hste` | 27 | 11 | done (round 616) |
| `odar` | 3 | 35 | done: p174..177 multiplier |
| `dttp` | 18 | 18 | done: the recast rule (636); detection open |
| `cssr` | 23 | 11 | done (round 659) |
| `pola` | 24 | 10 | open |
| `pmdp` | 0 | 32 | done: p5/p6 percent |
| `csit` | 22 | 9 | done (round 659) |
| `pmhp` | 0 | 31 | done: p3 debuff |
| `hpi` | 12 | 17 | done: p3 |
| `dgmp` | 28 | 0 | open |
| `spda` | 28 | 0 | open |
| `scls` | 0 | 27 | no server reader (READ): client only |
| `dtnt` | 0 | 26 | open |
| `lkdr` | 0 | 26 | open |
| `mwdt` | 0 | 26 | open |
| `pwtt` | 0 | 26 | open |
| `dmgt` | 0 | 25 | open |
| `trap` | 0 | 25 | open (the recast rule only) |
| `irgc` | 24 | 0 | part: written (p25/26); regeneration reads none |
| `summ` | 24 | 0 | open |
| `bgra` | 23 | 0 | part: written (p27..32) |
| `cspd` | 6 | 15 | done (round 659) |
| `dmgr` | 0 | 21 | open |
| `tel3` | 0 | 21 | done: the sprint to the target |
| `fe` | 6 | 14 | done (round 659) |
| `lkdd` | 15 | 5 | open |
| `tele` | 19 | 0 | done: Ghost Walk |
| `csmd` | 5 | 13 | done (round 659) |
| `lkdh` | 0 | 18 | open |
| `pmdg` | 0 | 16 | done: p178/179 |
| `csmp` | 0 | 14 | done (round 659) |
| `se` | 0 | 14 | done (round 659) |
| `cshp` | 0 | 12 | done (round 659) |
| `lkag` | 0 | 12 | open |
| `msch` | 0 | 12 | part: the sit gate (607) |
| `my` | 0 | 12 | done (round 659) |
| `terd` | 12 | 0 | done: p9 debuff |
| `hst2` | 0 | 11 | done (round 616) |
| `mpi` | 11 | 0 | done: p4 |
| `mcap` | 0 | 10 | open |
| `tb` | 0 | 10 | done (round 659) |
| `abnb` | 0 | 9 | open |
| `ca` | 0 | 9 | done (round 659) |
| `dcri` | 0 | 9 | done: p57 |
| `dn` | 9 | 0 | done (round 659) |
| `dtt` | 0 | 9 | done: the recast rule (636) |
| `inti` | 0 | 9 | done: p2 |
| `stri` | 0 | 9 | done: p1 |
| `thrd` | 9 | 0 | done: p11 debuff |
| `rhru` | 0 | 8 | done: p170/171 |
| `dcmp` | 0 | 7 | open |
| `hitm` | 0 | 7 | open |
| `hntp` | 0 | 7 | open |
| `rmut` | 0 | 7 | open |
| `tel2` | 0 | 7 | done: Teleport |
| `hwir` | 0 | 4 | open |
