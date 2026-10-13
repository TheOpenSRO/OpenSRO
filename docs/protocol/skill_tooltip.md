# Skill tooltips and mastery names (round 786)

The user (2026-10-13): "when hovering over skills you should [see] the sml2 blue windows but it
shows the native game gui instead", and "the previous round of skills fixed the sorcery -> cold
force name. Please fix it again."

Labels: **READ** (`sro_client.exe`, address given; the decompile `/var/tmp/decomp_client` and
`objdump` of the exe on the render box), **MEASURED** (the box's archive tables, counted),
**INFERRED**, **OURS**, **OPEN**. No game data is in this file.

## 1. Mastery names

| Fact | Value | Label |
|---|---|---|
| Tab title | `CIFSkillMastery` SetMasteryData `0x69f860`: the record of the mastery id (`0x9376b0`), then `0x8c9bb0(record + 4)` -- the record's name code -- through the text manager's hash lookup `0x8c9b20`, then the title's SetText (vslot `0xb4`) | READ |
| The name code | `skillmasterydata.txt` column 2 (`UIIT_STT_MASTERY_VI`, `_HEUK`, `_PA`, `_HAN`, `_PUNG`, `_HWA`, `_GI`; Europe `UIIT_STT_WARRIOR`, `_ROG`, `_WIZARD`, `_WARLOCK`, `_BARD`, `_CLERIC`) | MEASURED (the table's own header names it `MasteryNameCode`) |
| Which row of a key | the first: TextStringManager `0x8cac30` inserts every row into a hash map (`0x8ca120`) that keeps the existing entry | READ (round 634, confirmed round 725) |
| The same lookup elsewhere | the skill tooltip's mastery condition (`0x96d0e0`: `0x8c9bb0` of the mastery record + 4, `"%s : %s Lv %d"`); the item requirement lines (`0x67eec0`, the same keys) | READ |

**The archive (MEASURED, the box's `textuisystem.txt`, which is also the user's).** The file is
two tables joined (round 725). Each China mastery key is in both; the Europe keys are only in
`textdata_equip&skill.txt`, once each.

| Key | Mastery | First table | Stock table |
|---|---|---|---|
| `UIIT_STT_MASTERY_VI` | 257 | Bicheon | Bicheon |
| `UIIT_STT_MASTERY_HEUK` | 258 | Heuksal | Heuksal |
| `UIIT_STT_MASTERY_PA` | 259 | Pacheon | Pacheon |
| `UIIT_STT_MASTERY_HAN` | 273 | **Cold** | **Sorcery** |
| `UIIT_STT_MASTERY_PUNG` | 274 | Lightning | Lightning |
| `UIIT_STT_MASTERY_HWA` | 275 | Fire | Fire |
| `UIIT_STT_MASTERY_GI` | 276 | Force | Force |
| `UIIT_STT_MASTERY_HAN_EXPLANATION` | 273 | "...uses the energy of ice..." | "...uses the energy of ice, lightning & fire..." |
| `UIIT_STT_WARRIOR` ... `_CLERIC` | 513-518 | (one row each, `textdata_equip&skill.txt`) | |

The stock table's 273 rows describe a server that merged the three elemental masteries into one
"Sorcery" mastery (it also adds `UIIT_CTL_SORCERY_SKILL` "Sorcery"). This game keeps 273, 274 and
275 apart (`skillmasterydata.txt`, `MasteryReader.RACE_MASTERIES`). No mastery-name key carries
"Cold Force": that text is only in a skill-group description in `textdata_equip&skill.txt`
("Cold Force Series", "The basic Cold Force Mastery training ...", a multi-line row whose first
line the loader reads has no English). So the client, reading the first row, titles 273 **Cold**.

**The cause of the regression (the rule changes MEASURED from `git log -S`; the names they gave
INFERRED from the rules, except where a log or note says so):**
- Before round 634 `UiTextTable` let a later row overwrite an earlier one: 273 read "Sorcery"
  (round 143's own note lists "Sorcery, Lightning, Fire, Force").
- Round 634's review (`7e962d07`, the first commit with `keep_first`) made it keep the first
  row, the client's rule: 273 read "Cold" from then on, through round 691's skill work. No commit
  ever named "Cold" or "Cold Force" (`git log --all -S` finds none): the "fix" the user remembers
  was this rule, not a change to the skill window.
- Round 725 (`3f1f8abb`, a USER DECISION for the stock English wording) made the stock table's
  row win in a joined `textuisystem.txt`. That rule took 273 back to "Sorcery", in the skill
  window's tab and header, the practice box, the item requirement lines; round 781's window
  shipped with it (its offline QA log on the box prints `masteries ["Sorcery", "Lightning",
  "Fire", "Force"]`). No test named a mastery, so nothing caught it.

**The fix (OURS rule on READ evidence):** `UiTextTable.FIRST_ROW_PREFIX` (`UIIT_STT_MASTERY_`):
in a joined table those keys keep their first row, as the client does; every other key keeps the
round 725 decision. All seven China masteries were checked: only `_HAN` and `_HAN_EXPLANATION`
differ. The Europe six are single rows and were never affected. Guarded by
`ui_text_table_test.gd`, `mastery_reader_test.gd` and `skill_window_race_test.gd` (the Force tab
reads Cold, Lightning, Fire, Force and 273's header "Cold Mastery"); each fails with the rule off.

## 2. The skill tooltip

**Which window (READ).** `CIFSlotWithHelp::vslot_048` (`0x686db0`) builds every slot's help in
the helper bubble (`0x798db0`, the `CNIFHelperBubbleWindow` of `item_tooltip.md`), after giving its
text box `0x54(200, 1)`. A slot of kind `0x49` (the skill window, `GDR_SKILL` ID 73; the skill
slot gets it at `0x6a09e5`), or a quick slot (kind `0x0c`, `GDR_UNDERBAR` ID 12) whose content
kind is `0x19` (`GDR_MAINPOPUP` ID 25, set at `0x60ec5d` when the bar takes a skill), goes to
`UI_SILKMALL 0x67a970`. So a skill's tooltip is the same blue window an item's is.

**The rows (READ, `0x67a970`):**

| # | Row | Colour, face | Where |
|---|---|---|---|
| 1 | `"%s %s %d\n "`: the name (the record's `+0x124` through the text manager, else `+0x24`), `UIIT_STT_LEVEL_LV`, the level byte `+0x60` | white, the name sign, font 3 | `0x67aa64`, `0x67aaa5`, `0x67aae9`, `0x67aaf0` |
| 2 | `PARAM_PASSIVE_SKILL` when `+0x61` is 0, else `PARAM_ACTIVE_SKILL` | beige `0xffefdaa4` | `0x67ab54` |
| 3 | the requirement text `0x96d7e0` fills: `PARAM_REQ_HP` / `PARAM_REQ_MP` "%d" (`+0x854` / `+0x858`, when > 0), `PARAM_REQ_HP_RATIO` / `_MP_RATIO` (`+0x85c` / `+0x85e`), then `"%s: %s\n"` or `"%s: %s, %s\n"` of `PARAM_REQ_WEAPON_TYPE` and the weapons `+0xd8` / `+0xdc` (`0xff` none, `0x96dc60` / `0x96dc70`) named by `PARAM_WEAPON_SWORD/BLADE/SPEAR/TBLADE/BOW` (2-6) and `UIO_NEWCHAR_STT_EU_*` (7-15) | beige | `0x96d7e0` |
| 4 | the required item (`UIIT_STT_EU_REQUIRE_ITEM` / `_ESSENTIAL_ITEM`, `+0x1c4`..), checked against the worn items | beige or red `0xffff4a4a` | `0x96d7e0`, `0x67ac60..` |
| 5 | the description: the text of `+0x15c` when `+0x170` (its length) is not 0 | white | `0x67ad69` |
| 6 | `" "` | white | `0x67ad81..0x67ad8e` |
| 7 | the effect text `0x96e480` bit 2 fills (`PARAM_PA` / `PARAM_MA` "%s %d~%d (%d%%)", reach and count rows, the params through `ICPlayer 0x960b50`) | beige | `0x96e480` |
| 8 | **only when neither kind is `0x19`** (`0x67adb4..0x67adce`): a level-1 skill not learned whose mastery is held -- `PARAM_CONDITION_OF_LEARN` (white, a second sign, `0x7771e0`) and the level's conditions; a learned skill below its last level (`0x944940`) -- `"\n%s"` of `" "` (`0x67b054`), `PARAM_CONDITION_OF_NEXT_LEVEL`, the next level's conditions | | `0x67ae10`.. |

**The conditions (READ, `0x96d0e0`, in this order), coloured by `0x67a970`:** each is beige when
the player has it and red when not.

| Type | Row | Test |
|---|---|---|
| 1 | `"%s : %s Lv %d"` (`0x96d19a`): `PARAM_MASTERY_LEVEL`, the mastery's name, `+0x820` | the held mastery's level below it: red |
| 2, 3 | `"%s : %d"`: `PARAM_STR` / `PARAM_INT` (`+0x824` / `+0x828`), when not 0 | the player's Str / Int below it |
| 5 | `"%s%d : %s %s %d"` (`0x96d55a`): `PARAM_REQ_PREV_SKILL`, the place in the list from 1, the skill's name, `UIIT_STT_LEVEL_LV`, its level; a skill of this skill's own group (`+0x778`) is skipped | known (`0x9c0b90`): beige |
| 4 | `"%s : %d"`: `PARAM_REQ_SP` (`+0x83c`), when not 0 | the points (`+0x880`) below it |

**Record offsets to skilldata columns (INFERRED from the record's layout, as round 781 mapped
`+0xf8` / `+0xfc`):** `+0x60` level (column 7), `+0x61` Basic_Activity (column 8: MEASURED 0 on all
seven China `*_PASSIVE_A_01` rows, 1 on buffs, 2 on attacks), `+0xd8` / `+0xdc` ReqCast_Weapon1/2
(50 / 51), `+0x124` the name (62) and `+0x15c` the description (64: one 0x1c-byte string apart),
`+0x820` / `+0x83c` / `+0x858` the level's mastery level / SP / MP (36 / 46 / 53).

**What OpenSRO draws (`SkillTooltipLines`, `ItemTooltipBubble`, `HudPanels.set_bubble_tip`):**
rows 1, 2, 3 (MP and the weapons), 5 (its `<sml2>` markup as rows, `ItemTooltipLines.sml2_rows`),
6, and 8 with the mastery, prerequisite and SP conditions. Every help on the skill window (the
slots, the ADD / UP buttons, the group icons, the mastery icon, LEVEL UP) and every quick slot
holding a skill goes to the bubble; no `tooltip_text` is left on them. A row wider than 200 px is
broken at spaces (INFERRED from `0x54(200, 1)`). The condition header's sign is drawn with the
name's `com_itemsign.ddj`.

**OPEN:**
- Row 4 (the required item) and row 7 (the effect text: attack power, reach, the param rows of
  `0x960b50`): SkillDataReader does not parse those columns or params.
- The HP cost and the two ratio costs of row 3; the Str / Int conditions (0 on player skills).
- Which static the condition header's sign is (`+0x7e8`, tinted by the row's colour at `0x7771e0`)
  and its art; whether the text box breaks `"\n "` into an empty row and a `" "` row (drawn so).
- The mastery icon's and LEVEL UP's help: retail's builders for those were not read; the bubble
  shows round 781's text (the name and explanation; OURS for LEVEL UP).
- The buff bar's and the target window's buff icons still use Godot's own tooltip (`_get_tooltip`);
  their retail help (`0x800a10`) is a separate builder.
- A quick slot holding an item shows no help yet (retail: `0x686c50` through the same bubble).
