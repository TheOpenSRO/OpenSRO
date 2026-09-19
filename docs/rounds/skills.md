## The skill window at Bicheon 3 was right, and said nothing -- now it says why

**The report.** A level-3 fighter with Bicheon 3 and 9 SP: "leveling up my Bicheon
but it's not giving me skills to add; the UI looks broken and maybe assumed", with
a screenshot of the window -- rows of grey cells, three "up arrows" at the end of
each row, LEVEL UP dimmed.

**What the data says (the user's own skilldata export, `skills.csv` from
Media.pk2, fields 22/23/19 = raw cols 34/36/46).** Bicheon (mastery 257) has no
level-1 skill below mastery **5**: `SKILL_CH_SWORD_SMASH_A_01` (id 3, group 174)
needs Bicheon 5 and 2 SP; `CHAIN_A` 7; `SHIELD_A` and `PASSIVE_A` 10; `GEOMGI_A`
14; `KNOCKDOWN_A` / `DOWNATTACK_A` 19. Only `SKILL_CH_SWORD_BASE_01` (the basic
swing) needs 0. So at Bicheon 3 there is genuinely nothing to learn.

**Why Bicheon could not be raised to 5.** A mastery cannot pass the character's
level: `Mastery_LevelUp` (`0x0059c4e0`) refuses with `0x3804` when
`characterLevel < currentMasteryLevel + levelsRequested` (already cited in
`session/skill.go`). Character level 3 -> Bicheon caps at 3 -> the first skill
is out of reach until character level 5. Both rules are the game's; the server
applies both; the client showed both correctly -- LEVEL UP disabled with its
reason in a tooltip, every cell locked with its requirement in a tooltip.

**The "up arrows".** `interface\skill\skl_mastery_nothing.ddj` is a 32x32 dark
cell with an embossed diamond -- dumped with `tools/dump_ddj.gd` and looked at.
At window scale the diamond reads as an arrow. It is the empty-column padding
`CIFSkillGroup::SetGroup` draws up to eight columns (recovered earlier from the
decompile), so a row shows `8 - skills` of them. Bicheon's rows hold
5/7/6/5/5/5/4/5/3 skills (logged by the client), hence three pads on the
five-skill rows the screenshot showed, one on the chain row, two on the shield
row. The coloured icon at each row's left is the group's pack icon
(`skillgroup\china\pack_sword_*.ddj` at 6,8), not a skill cell.

**What was actually wrong: two things the window did not say.**
1. Skill names never resolved. They live in
   `server_dep\silkroad\textdata\textdata_equip&skill.txt`, which nothing
   loaded, so tooltips showed `SN_SKILL_CH_SWORD_SMASH_A`. It is loaded now
   beside the skill catalogue; the pserver client's English for that skill is
   **"Strike Smash"**, with its authored description.
2. A locked cell's tooltip gave the cost but not the gap. It now reads, from the
   same real numbers: `Learn Lv 1: Bicheon Lv 5 required (yours: Lv 3)`,
   `Skill point needed: 2` (the client's own `UIIT_STT_NEED_SP`), and -- when the
   requirement is above the character's level -- `A mastery cannot pass your
   character level (Lv 3). Reach character level 5, then raise Bicheon to Lv 5.`

**Verified.** `SRREVAMP_QA_SKILL_STATE="sp=9,level=3,257=3"` (new; sets points,
character level and mastery levels for a render without a server) reproduces
the user's window: `Bicheon Lv 3, 9 SP, char Lv 3, total 3/9 -> LEVEL UP
disabled: at your character-level cap (Lv 3)`; first cell
`SKILL_CH_SWORD_SMASH_A_01 learned=0 available=false` with the tooltip above.
Server side, `TestLearnGateOnTheRealFirstBicheonSkill` drives
`LearnSkillHandler` with the real row: refused at Bicheon 3 with 9 SP ("mastery
level too low"), refused at Bicheon 5 with 1 SP, learned at Bicheon 5 for
exactly 2. 222 scripts load on the box.

**Not changed, on purpose.** The grey books, the pads and the tooltip-only
explanations are what the real client does; nothing was drawn that its layout
does not have. **Disclosed:** the two explanation sentences are ours (the
client has no string for the character-level cap in `textuisystem.txt`); the
requirement numbers and the SP label are not.
