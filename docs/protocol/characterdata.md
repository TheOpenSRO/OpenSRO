# characterdata: how the client reads a character row

`server_dep\silkroad\textdata\characterdata_*.txt` in Media.pk2 (UTF-16LE, tab separated). One row
per character: a monster, an NPC, a player class, a pet (`_RefObjChar` on the server). This page
covers what round 655 read in `sro_client.exe` (the decompile on the render box,
`/var/tmp/decomp_client`). Everything below is **READ** with its address unless it says otherwise.

## The parser

`FUN_00971450` parses one characterdata row. It hands the shared RefObjCommon parser
`FUN_00972910` the common block at record+8 (asm `971483 lea ecx,[edi+0x8]`; `FUN_00971210`
returns `this+8`). Offsets below are relative to that block. Text columns are 0-based.

| column | offset | what |
|---|---|---|
| 1 | +0x04 | ID, which the parser returns as the row key. That column 0 (Service) is consumed first is INFERRED |
| 2 | +0x08 | CodeName (wide) |
| 3 | — | ObjName, read and discarded |
| **4** | **+0x40** (length +0x54) | **OrgObjCodeName** (wide) |
| — | **+0x5c** | **the Org link: the Org row's ID** (zeroed by the parser: `*(param_1+0x2e)=0`) |
| 5, 6 | +0x60, +0x7c | NameStrID, DescStrID |
| 7-12 | +0x00 (u16) | bit 0 CashItem, bit 1 Bionic, bits 2-4 TypeID1, 5-6 TypeID2, 7-10 TypeID3, 11-15 TypeID4 |
| 48 | +0x110 | Scale; CICMonster uses it as scale / 100 |
| **52** | **+0x124** (length +0x138) | **the model: the first file of AssocFileObj** |

Column 52 is split on `","` (0xd8c364) into a vector at +0x1b0, and each piece goes through
`FUN_0097f860` mode 2, which prefixes `res\` (0xde118c). **Only piece 0 is copied to +0x124**
(asm `972f1d lea ecx,[edi+0x124]; call 0x425ae0`). Two rows carry several files there
(`MOB_SD_HAROERIS`, `MOB_SD_SETH`, MEASURED).

**`xxx` is stored as an empty string.** The narrow and wide text readers `FUN_0097f860` and
`FUN_0097f920` compare the cell with `"xxx"` (0xdae70c; `L"xxx"`) and on a match assign `""`
(`DAT_00e16204` for the narrow reader, `DAT_00e17460` for the wide one). So a row "with no model" has an empty +0x124, never the text `xxx`. The only
other `xxx` test (0x973218, column 55 before a siege-fortress lookup) has nothing to do with models.

## The model of a row with none (the `_CLON` rule)

1. **The Org link.** While each row is parsed (`FUN_0093ec90`, asm 0x93ed1a-0x93edae), a non-empty
   OrgObjCodeName is looked up in the code-name -> ID map at `[mgr+0x160]` (`FUN_004ff080`), which
   holds only the rows parsed so far. After the whole file is loaded (`FUN_0093fb50(5)`, called at
   `9591a2` for characterdata, loaded as type 5 at `844fed`), every character record is linked
   again: its Org name is looked up, the record fetched (`FUN_0093f370`), and +0x5c set to that
   record's ID. So the link does not depend on row order (58 `_CLON` rows name an Org with a
   larger ID, MEASURED).
2. **At object creation** (`FUN_009c1ce0` -> `FUN_009c1840`): `this+0x220` is the row's record,
   and `this+0x224` the Org record when the row's +0x5c is not 0.
3. **The pick**, identical at `0x9c1d10`, `0x9c1d40` (CIGIDObject slot 32), `CICCos::vslot_025`
   `0x9c60b0` and `CICMonster::vslot_025` `0x9d3850`:
   ```
   path = rec + 0x124;
   if (*(rec + 0x138) == 0 && this[0x224] != 0) path = org + 0x124;
   GlobalDataManager::FUN_009c4ec0(path, 1);
   ```
4. **The fallback.** `FUN_009c4ec0` loads through `CCObjAnimation::FUN_00a5b4b0`, which loads only
   a non-empty path; when nothing loaded, it loads `res\mob\china\mangnyang.bsr` (0xde1f90).

So: **the row's own model; if it has none, its Org row's own model; one level only** (the Org
row's own Org is never consulted). An Org that is `xxx`, missing or has no model of its own gives
nothing, and the client then draws a Mangyang. Everything else, the scale included, still comes
from the row itself.

Not covered by this rule: CICMonster rows with TypeID 1/2/1/2 (thieves) and 1/2/1/3 (hunters)
pick their model from a list (`ICMonster::FUN_009d3470`), with no Org fallback, and CICCos has its
own branch for TypeID3 = 3, TypeID4 = 5.

### On the real table (MEASURED, round 655)

13,291 distinct IDs (`/var/tmp/tables/characterdata_*.txt` on the render box). 184 rows contain
`_CLON`, 57 of them with a model of their own; **all 127 with `xxx` name an Org row that exists and
has a model**. Across the whole table 161 `xxx` rows get a model through their Org (the 127 plus
34 others: `*_L2`/`_L3` variants, `MOB_QT_01_*`, `MOB_CA_ONG`, `COS_P_SPOT_RABBIT`,
`COS_P_PINKPIG`, ...). The other 7,700 `xxx` rows get none from their Org, and they are exactly the
special classes above (2,800 thief rows, 2,800 hunter rows, 2,100 guild soldiers). No row needs a
chain.

### In srrevamp

`NpcTableReader.parse_org_codes` reads column 4 (`xxx` and "" name none) and
`NpcTableReader.model_with_org` applies the rule; `World3D._monster_model_path` resolves a
monster's model through it before the display-name join. The Mangyang fallback is not taken: in
the real table no monster row reaches it except the thief/hunter/guild classes, which retail draws
from their own list, so srrevamp keeps the labelled capsule there (OURS). Column 48 (Scale) is not
applied to any monster yet (OPEN, docs/TODO.md).
