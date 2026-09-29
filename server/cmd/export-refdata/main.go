// Command export-refdata turns a client's own itemdata text tables (the
// Media.pk2 `server_dep\silkroad\textdata\itemdata*.txt` files, which are
// the game's _RefObjItem table dumped tab-separated) into the headerless
// CSV that import-refdata loads. No game data ships with this tool or the
// repo -- the operator points it at their own extracted tables, exactly as
// the client is pointed at their own pk2.
//
//	export-refdata -out items.csv itemdata_1000.txt itemdata_5000.txt ...
//	import-refdata -items-csv items.csv -postgres-dsn ...
//
// Column mapping. The itemdata fields are 0-indexed here (field 0 is the
// leading "service" column, field 1 the id). Each mapping below is either
// measured against real rows and, where a ground truth existed, verified,
// or left at an honest default when this project has not established the
// column yet -- never a guess dressed as data. The verification: a real
// Copper Sword (+5) tooltip a player sent reads exactly the physical
// attack (field 96/98, base 15/16), magical attack (101/103, 25/28),
// durability (64/65, 62/76), attack rate (114) and critical (117) these
// columns hold; the attack columns are the same for the bow and spear.
// See docs/protocol/ITEM_FORMAT.md and WORLD_ISSUES.md.
//
// MaxStack is real, from column 57: 1 for every one of the 8,616 equipment
// rows (TypeID2=1) and a real per-item cap for the stackables (an alchemy
// stone 500, a potion 5,000, arrows 2,500), which is exactly how a MaxStack
// column behaves. An earlier note here defaulted it to 1 "because it is 1 for
// every row" -- that was reading the wrong thing; the real column makes
// potions and materials stack instead of filling a slot each. Physical/magical
// DEFENCE is 0: armour
// stores its defence in different columns than a weapon's attack, and this
// project has no ground-truth armour tooltip to label them, so rather than
// guess they are left empty -- combat does not read defence, and the only
// effect is that the shop prices armour at its base price. ItemClass and
// TwoHanded are 0/false, no worse than the "unknown item" the server sees
// today. When an armour tooltip or the _RefObjItem schema pins the rest,
// fill these in here.
package main

import (
	"bufio"
	"encoding/csv"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"unicode/utf16"

	"github.com/OpenSRO/srrevamp/server/internal/skillparam"
	"github.com/OpenSRO/srrevamp/server/internal/spawn"
	"github.com/OpenSRO/srrevamp/server/internal/teleport"
)

// Field indices into a tab-split itemdata row (0-indexed; field 0 is the
// leading service column).
const (
	fID      = 1
	fTypeID1 = 9 // TypeID1..4 run 9..12
	fCountry = 14
	// DecayTime: how long a dropped item lies on the ground, in ms (see
	// refdata.Item.DecayTimeMs for the reading that ties column 13 to it).
	fDecayTime = 13
	// MaxStack: 1 for all equipment, a real cap for stackables (col 57).
	//
	// CONTESTED 2026-09-16 AND RESOLVED THE SAME DAY. The conflict was real
	// but it was between two FORMATS, not two readings.
	//
	// The server does not parse these text files. It parses a BINARY record
	// (4-byte fields, 2-byte length-prefixed strings) whose last common field,
	// `_RefObjCommon+0x184`, every ExtractData override asserts non-zero and
	// passes to a lookup logging "Can't find associated item data
	// [RefObjCommon ID: %d, RefItem ID: %d]". That lookup
	// (CGameServer::FUN_006ba850) scans a list of row-streams and compares the
	// key against each candidate's FIRST 4-byte field, so it is a per-row
	// foreign key -- the binary common record ends with a link to the
	// type-specific record.
	//
	// The client's text table is the DENORMALISED JOIN of the two, and it does
	// not carry that link: no itemdata column is per-row unique, and
	// characterdata's only unique columns are 1 and 2 (ID and code name). So
	// binary field 57 and text column 57 are simply different fields at the
	// same index, and reading text column 57 as MaxStack -- 18 distinct values
	// shaped 1 / 250 / 500 / 50 -- is correct.
	//
	// See docs/protocol/refobj_binary_format.md.
	fMaxStack = 57
	// Real NPC vendor prices: _RefObjCommon Price (buy) and SellPrice
	// (buy-back). Confirmed against real rows -- SellPrice < Price on every
	// item checked, potions carry a Price with 0 CostRepair, weapons carry
	// both -- and pinned by fReqLevelType1=32 lining up (ItemTableReader reads
	// the same column). See docs/protocol/refdata_schema.md.
	fPrice     = 26
	fSellPrice = 31
	// fRepairCost is the item's FULL-REPAIR cost in gold -- see
	// refdata.Item.RepairCost for the engine arithmetic that identifies it.
	//
	// CORRECTED 2026-09-20 from 28 to 27 (round 304). The engine reads the
	// basis from `refRecord+0xa4`, and `RefObjCommon_ExtractData` writes that
	// offset at its **field 28**, which is text column **27** -- deserializer
	// field k is 1-based over the row and column k-1 is 0-based, so they differ
	// by one. Column 28 is `+0xa8`, the adjacent flat restore cost, and taking
	// it overcharged every repair by exactly 1.5x (the two columns are an
	// authored 1.5 ratio: the Copper Sword is 198 and 297).
	//
	// Three disjoint anchors fix field k <-> row field k, so the off-by-one is
	// not a judgement call: fields 3-7 are five string reads and the row's
	// fields 3-7 are CodeName/ObjName/OrgObjCodeName/NameStrID/DescStrID;
	// fields 33-40 are the stride-8 (dword,byte) requirement pairs; fields
	// 53-57 are five more string reads and the row's are the .bsr/.bsr/.ddj
	// asset paths plus two "xxx". See docs/protocol/refobj_binary_format.md.
	fRepairCost = 27
	// The Param block stores a value beside its own label: 118 "HP...",
	// 120 "HP...(%)", 122 "MP...", 124 "MP...(%)". Potion restore amounts --
	// on the recovery rows (TypeID 3/3/1, TypeID4 not 4..10) only, which is
	// where GObjPC::FUN_0049aa70 reads them as HP / HP% / MP / MP% from
	// Param1..4 (+0x2a0/+0x2c0/+0x2e0/+0x300). They are emitted for every row
	// because the CSV is per-column; session.UseItemHandler gates on the kind
	// (round 491), since a scroll's or a storage expansion's Param1 is not HP.
	fRestoreHP    = 118
	fRestoreHPPct = 120
	fRestoreMP    = 122
	fRestoreMPPct = 124
	// The four requirement slots. _RefObjCommon holds them as four
	// (int32 type, uint8 value) pairs at +0xb4 and +0xb8, stride 8, and
	// RefObjCommon_ExtractData fills them from columns 32..39 in a
	// four-iteration loop (0x6a36ab..0x6a3700, trip count from
	// `mov eax,0x4`). CGItemEquip::CheckEquipRequirements (0x004919e0)
	// walks all four and asserts on a slot index above 3, which is where
	// the count of four comes from rather than from the column layout.
	//
	// Only slot 1 was exported before, which is right for 11,636 of 23,327
	// real rows (the ones whose only requirement is a character level) but
	// silently drops every requirement in the other slots.
	fReqLevelType1 = 32
	fReqLevel1     = 33
	fReqLevelType2 = 34
	fReqLevel2     = 35
	fReqLevelType3 = 36
	fReqLevel3     = 37
	fReqLevelType4 = 38
	fReqLevel4     = 39
	fReqGender     = 58
	fReqStr        = 59
	fReqInt        = 60
	fDurabilityMin = 63 // and 64 for max
	fRange         = 94 // the weapon's reach, world units (tenths of a metre)
	// The 20 (Param, Desc128) pairs the item parser stores as a strided array
	// at record+0x2a0: Param{k+1} is column 118 + 2k. Elements 1..3 -- Param2,
	// Param3, Param4 -- are an elixir's packed reinforce success rates
	// (round 262; the table's own Desc texts read "1,2,3,4" / "5,6,7,8" /
	// "9,10,11,12").
	fParam1        = 118
	fParam2        = 120
	fParam3        = 122
	fParam4        = 124
	fPhysAttackMin = 95 // and 97 for max (96/98 one-indexed)
	fPhysAttackMax = 97
	fMagAttackMin  = 100
	fMagAttackMax  = 102
	// A weapon's REINFORCE percentages, in tenths of a percent (306 = 30.6%),
	// laid out with the same (n, n+2) spacing as the attack pair above: n and
	// n+2 are the min's and max's low end, n+1 and n+3 their per-instance
	// variance high end, and 99/104 the per-plus increments the engine reads
	// as the `inc` of each (lo, hi, inc) triple (FUN_00495d60 computes an
	// item's actual stat as lo + t*(hi-lo) + inc*plus, and asserts lo < hi).
	//
	// Pinned by the engine, not by position: GObjPC_InitStats writes each
	// param's innate default from .rdata -- 30.6 (param 34), 34.2 (36), 49.0
	// (35), 54.8 (37) -- and 306/342/490/548 are exactly the minima of columns
	// 105/107/109/111 across all 1,568 weapon rows. Four constants, four
	// column floors.
	//
	// srrevamp models no per-instance variance and no plus level, so it takes
	// the low end, which is also the end the innate defaults correspond to.
	fReinforcePhysMin = 105 // and 107 for max
	fReinforcePhysMax = 107
	fReinforceMagMin  = 109 // and 111 for max
	fReinforceMagMax  = 111
	fHitRate          = 113
	fCritical         = 116
	// Armour defence and the shield's block ratio, all verified against real
	// +5 tooltips in docs/protocol/ITEM_FORMAT.md: a Cotton garment reads
	// 2~2.5 physical and 4.3~5.2 magical, a starter shield 10~20 block. Each
	// is a TRIPLE (min, max, a per-tier third value), so max is +1.
	//
	// These were exported as literal "0" until 2026-09-15, marked "armour,
	// not verified" -- a note that stopped being true when ITEM_FORMAT.md
	// grounded the columns three ways and was never revisited. Every
	// deployment importing through this tool therefore gave armour no
	// defence at all.
	// Whether the weapon needs both hands -- a clean 0/1 that is CONSTANT
	// within every weapon kind (TypeID4) and 0 on all 511 shield rows.
	//
	// Identified by diffing a known one-hander against a known two-hander and
	// then cross-checked against a source that knows nothing about this
	// table: the CLIENT's own weapon-to-animation-group switch, recovered in
	// docs/WORLD_ISSUES.md's hundred-and-thirty-third round, names five kinds
	// explicitly -- 7 `onehand_sword`, 10 and 15 `onehand_staff`, 8
	// `twohand_sword`, 11 `twohand_staff`. This column reads 0 for all three
	// "onehand" kinds and 1 for both "twohand" kinds. Five for five, from a
	// different binary recovered by a different route.
	// ItemClass, the item's own class/degree byte. Column 61.
	//
	// Derived from the ORDER of the server's own deserialiser rather than by
	// pattern-matching the data: RefObjItem::ExtractData reads its fields
	// consecutively off the row -- +0x198 (4 bytes), +0x19c (1), +0x1a0 (4),
	// +0x1a4 (4), +0x1a8 (1) -- and +0x19c is confirmed as ReqGender by
	// CGPCInventoryOP::CheckEquipsetIntegrity, which compares it against the
	// character's GetGender(). This exporter already maps 57/58/59/60 to
	// MaxStack/ReqGender/ReqStr/ReqInt, exactly those four in exactly that
	// order, so the next field is column 61 -- and it is a 1-byte read, which
	// matches m_btItemClass.
	//
	// Checked against the binary's own assertion rather than against a curve:
	// ExtractData asserts "ItemClass must be not zero" / "m_btItemClass > 0",
	// and column 61 is non-zero on all 21,552 equipment rows. Its values are
	// small (1..14+), and one family's tiers walk it 1, 4, 7, 10, 13.
	fItemClass = 61
	// SetID, the item set this piece belongs to. Column 62, and the field
	// RefObjItem::vslot_001 writes at +0x1ac immediately after ItemClass's
	// +0x1a8 -- the same consecutive march that pinned 57..61.
	//
	// The use-site names it: CSetMagicOptionOP::PutoutTheBindingItem reads
	// `*(item[0xd] + 0x18) + 0x1ac` and logs it as
	// `"## %s %d ## Invalid data is used! [SetID:%d]"`. Cross-checked against
	// the data by joining to `refsetitemgroup.txt`: the race and gender in an
	// item's code name match its set's code name on 360 of 360 rows that spell
	// both, where the other columns holding only legal set ids score ~25%.
	fSetID = 62
	// The capability flags. Columns 16, 17 and 20 of _RefObjCommon, read off
	// RefObjCommon_ExtractData (0x006a3090) by its own column counter,
	// [stream+0x28] -- see docs/protocol/item_capability_flags.md, round 460's
	// table ("The columns, anchored against real data"). CanTrade's byte goes
	// to esp+0x11 (column 16, flags bit 0) and CanSell's to esp+0x26 (17, bit
	// 1). Then:
	//
	//   - column 18 is CONSUMED BUT NOT STORED: 0x6a33f0 `add [edi+0x1c],ebx`
	//     advances the cursor with no load and 0x6a33f6 `add [edi+0x28],ebx`
	//     bumps the counter;
	//   - column 19 is a packed byte, stored at 0x6a341e `mov [esp+0x12],dl`
	//     and tested `& 0x80` (0x6a3516) and `& 0x40` (0x6a352f) for flags
	//     bits 12 and 13. The engine names neither bit and this exporter does
	//     not export them. Over the combined itemdata it holds
	//     255/128/223/192/159/1/0, and until round 494 fCanDrop read it by
	//     mistake;
	//   - column 20 is CanDrop's byte, stored at 0x6a3441 `mov [esp+0x13],dl`
	//     and folded at 0x6a3540..0x6a3552 as `((b & 2) << 9 | b & 1) << 4`:
	//     `& 1` is flags bit 4, the bit CGObj::CanDrop (0x00483de0) reads, and
	//     `& 2` is the unnamed bit 14. The column holds 0/1/3.
	//
	// canDrop (below) applies the parser's one coupling between the two:
	// CanTrade clear and a CanDrop byte of exactly 1 becomes 0.
	fCanTrade = 16
	fCanSell  = 17
	fCanDrop  = 20
	// fCanUse is flags bit 8, the one Item_HandleUseItem (0x00510980) asks
	// about after the item's rental expiry (0x183d) and the user's life state
	// (0x1889) and before the TID match: `(**(code **)(*item +
	// 0xe0))()` -- vtable slot 56, IGObj::CanUse (docs/protocol/igobj_vtable.md)
	// -- and a zero refuses the use with 0x183e UIIT_MSG_STRGERR_CANNOT_BE_USED
	// (docs/protocol/error_codes.md). Every CGItem* vtable holds CGObj::CanUse
	// (0x00483ee0) there, which -- after vslot 0x48 IGObj::IsItem, always
	// true for a bag item -- reads `refobj+0x8c >> 8 & 1`, and
	// RefObjCommon_ExtractData (0x006a3090) sets that bit as `-(cVar1 != 0) &
	// 0x100`: any non-zero byte is permission.
	//
	// Column 24 is round 460's table in docs/protocol/item_capability_flags.md
	// ("The columns, anchored against real data"), confirmed there by meaning
	// -- 0 on every armour row, non-zero only among consumables. Re-measured
	// for round 489 over itemdata_all: the column holds 0/1/129; it is non-zero
	// on 99 of 99 HP/MP potion rows (TypeID 3/3/1) and zero on every equipment
	// row but the 28 cash-shop avatars (3/1/14). Column 23, where the same
	// file's older read-count table put CanUse, reads 0 on the HP potions, so
	// it cannot be the bit a potion is used through.
	fCanUse = 24
	// fCanPick is flags bit 5, the one GObjPC::CheckCanPickUp (0x004a9050)
	// asks right after it has found the object and IGObj::IsItem said yes:
	// `(**(code **)(*item + 0xd4))()` -- vtable slot 53, IGObj::CanPick
	// (docs/protocol/igobj_vtable.md) -- and a zero refuses the pick with
	// 0x1839 UIIT_MSG_STRGERR_CANNOT_BE_PICKED (docs/protocol/error_emitters.tsv,
	// the 0x004a9050 row). All seven CGItem* vtables (the ones carrying
	// CGItem::Update at slot 211, 0xae9384 .. 0xaeb824) hold CGObj::CanPick
	// (0x00483e50) there: IsItem, then `refobj+0x8c >> 5 & 1`.
	//
	// The column, read off RefObjCommon_ExtractData (0x006a3090) by its own
	// column counter, [stream+0x28], bumped once per column: CanTrade's byte
	// goes to esp+0x11 (column 16), CanSell's to esp+0x26 (17); column 18 is
	// CONSUMED BUT NOT STORED -- 0x6a33f0 advances the cursor with no load and
	// 0x6a33f6 bumps the counter -- then esp+0x12 (19), esp+0x13 (20), and the
	// bump at 0x6a3455 with its byte stored at 0x6a3464 `mov [esp+0x23],dl`:
	// column 21. That slot becomes the bit at 0x6a3588..0x6a3590, `neg al; sbb
	// eax,eax; and eax,0x20`. Counting on from there lands bl on column 24,
	// fCanUse above, so the two anchor each other. Round 460's data-anchored
	// table in docs/protocol/item_capability_flags.md says 21 too, and over
	// the combined itemdata the column is 0/1 only, 0 on 309 of 21,552 rows --
	// all 84 starter `_DEF` rows among them -- and 1 on gold and potions.
	fCanPick = 21
	// fCodeName is CodeName128 (round 497). RefObjCommon_ExtractData
	// (0x006a3090) reads two dwords -- column 0, then column 1, the ID, stored
	// at ref+0x8 (0x6a3123) -- and then its first string, `add eax,0x10;
	// call 0x6b2ef0` (0x6a3130/0x6a3139), into the std::string at ref+0x10:
	// deserializer field 3, text column 2 (the field-k/column-(k-1) rule
	// fRepairCost records). CGObj::GetCodeName (0x004824c0, IGObj slot 58)
	// returns that string, and GObjPC::CheckCanPickUp compares it with
	// "ITEM_QNO_RM_ARCHEMY" (0x4a9342). On the combined itemdata column 2 is
	// ITEM_ETC_GOLD_01 on id 1 and ITEM_QNO_RM_ARCHEMY_1..8 on ids
	// 23980..23987.
	fCodeName       = 2
	fTwoHanded      = 93
	fPhysDefenseMin = 65
	fBlockRatio     = 74 // shields only -- see fParryRatio
	// fParryRatio is BODY ARMOUR's parry pair, and it is the complement of
	// fBlockRatio rather than a neighbour of it. Grounded 2026-09-21 (round 377)
	// by a census of all 21,560 item rows: 9,663 carry a non-zero column 68 and
	// NONE of them is a shield; 500 carry a non-zero column 74 and EVERY one is a
	// shield; and NO row carries both. Shields block, body armour parries.
	//
	// Three shipped columns act as the control on the indexing, all matching on
	// the same rows: 65/66/67 is the PhysDefense (lo, hi, inc) triple, 74/75 the
	// block pair, 76/77/78 the MagDefense triple. The defence block's recorded
	// order is PD, ER, PAR, BR, MD, MAR, which puts ER -- the parry rate the
	// client names PARAM_ER and the engine reads as ParamKeeper param 9 -- at 68.
	fParryRatio    = 68
	fMagDefenseMin = 76
	// The highest field any mapping reads: a row shorter than this is not a
	// real item row and is skipped.
	fMax = 117
)

// Skill (_RefSkill / skilldata_*.txt) raw column indices, 0-based. The
// learn-gating columns AND the cast timing / range / resource cost are named
// and mapped -- all verified against a real SMASH_A row (the column order is
// the schema's group order, anchored by 6 known indices; see the
// skilldata-columns note and docs/protocol/refdata_schema.md). Two flag
// columns (FlyingSpeed, Interruptable) stay unmapped; Overlap is read only for
// its high byte, the cooldown group (skOverlap, round 504).
const (
	skID         = 1 // unique per-level skill id
	skGroupID    = 2 // shared by every level of the skill
	skBasicCode  = 3 // SKILL_CH_..._NN
	skBasicLevel = 7
	// skChainCode is Basic_ChainCode, the id of the next link of a chain skill
	// (0 = no next link). CRefSkill::CopyFixedColumns (0x6ab5a0) copies the
	// fixed columns field by field in column order, and the tenth field --
	// column 9, after Service/ID/GroupID/Code/Name/Group/Original/Level/
	// Activity -- is the u32 at CRefSkill+0x68 (docs/protocol/skill_fields.md,
	// the CopyFixedColumns table). The skill tick 0x4ae590 phase 2 reads +0x68
	// to start the chain bookkeeping. Anchored by its neighbours: PreparingTime
	// (+0x70) is column 11 (skPreparingTime below, verified against a real
	// SMASH_A row). Measured on the 33,632 real rows: 2,822 carry a non-zero
	// value and 2,820 of those name a real skill id (SKILL_CH_SWORD_SMASH_D_01
	// -> 7140, SKILL_CH_SWORD_SMASH_D2_01).
	skChainCode = 9
	// Cast timing / range / cost, all in ms except Range. Verified against a
	// real SMASH_A row (see the skilldata-columns note): the column order is the
	// schema's group order, anchored by 6 known indices. All clean int values.
	skPreparingTime  = 11
	skCastingTime    = 12
	skActionDuration = 13
	skReuseDelay     = 14 // the cooldown
	skCoolTime       = 15
	// skAutoAttackType is Action_AutoAttackType, the u8 at CRefSkill+0x90:
	// the twentieth field CopyFixedColumns (0x6ab5a0) copies, between CoolTime
	// (+0x80, column 15) and Range (+0x92, column 21) with FlyingSpeed +0x84,
	// Interruptable +0x88, Overlap +0x8c at 16-18 and InTown +0x91 at 20.
	// CGCharAutoCommandActor::Tick_UseSkill (0x4ae590) phase 3 tests it
	// `== '\x01'` to push the plain-attack hand-off (auto_command.md, "The
	// skill tick"). Measured on the 33,632 real rows: 1 on 28,702, 0 on 4,608,
	// 2 on 322 -- no other value.
	skAutoAttackType = 19
	// skOverlap is Action_Overlap, the u32 at CRefSkill+0x8c: the nineteenth
	// field CopyFixedColumns (0x6ab5a0) copies, after Interruptable (+0x88,
	// column 17) and before AutoAttackType (+0x90, column 19 above)
	// (docs/protocol/skill_fields.md, the CopyFixedColumns table). Only its
	// HIGH byte is exported: SkillCooldowns::IsReady (0x64c1a0) reads
	// `*(char *)(ref + 0x8f)` as the skill's COOLDOWN GROUP and, when it is
	// non-zero, checks the shared group map at block+0x2c instead of the
	// per-id map at +0x1c; the arm FUN_0064c700 files the timer under the same
	// byte (see cooldownGroup). Measured on the 33,632 real rows: 2,566 carry
	// a non-zero group, every one a SKILL_ row; on the 6,123 SKILL_CH_/
	// SKILL_EU_ class rows 2,436 are grouped, groups 1..106 --
	// SKILL_CH_SWORD_SMASH_A_01 and _D_01 are both group 2 (33554432).
	skOverlap = 18
	skRange   = 21 // 0 = melee
	// skTargetRequired is Target_Required, the u8 at CRefSkill+0x94: the
	// field CopyFixedColumns (0x6ab5a0) copies right after Range (+0x92,
	// column 21), so column 22 (docs/protocol/skill_fields.md, the
	// fixed-columns table). Skill_ApplyEffectsAndNotify (0x593f50) heals the
	// caster only when it is 0 (0x5942b1 `cmp byte [edx+0x94],0`). Measured
	// on the real rows (round 507): 0 on all 49 SKILL_CH_WATER_SELFHEAL rows,
	// 1 on all 45 SKILL_CH_WATER_HEAL_A..E rows, the targeted heals (27 plain
	// 'heal', 18 'heal' with 'efr'). The 9 SKILL_EU_BARD_RECOVERA_ABNORMAL_A
	// rows are 1 too, but they are cures ('curt'/'curl', no 'heal'), not heals.
	skTargetRequired = 22
	// The targeting bytes after it, in CopyFixedColumns' order
	// (docs/protocol/skill_fields.md): TargetType_Land +0x96 (column 24),
	// TargetGroup_Self/Ally/Party +0x98/+0x99/+0x9a (columns 26-28).
	// MEASURED on SKILL_CH_LIGHTNING_GYEONGGONG_B_01 (Ghost Walk, id 114):
	// columns 22 and 24 are 1; on SKILL_CH_WATER_HEAL_A_01 (id 149) 22 and
	// 26-28 are 1 (docs/protocol/skill_buffs.md).
	skTargetLand  = 24
	skTargetSelf  = 26
	skTargetAlly  = 27
	skTargetParty = 28
	// skActionKind is the skill's ACTION KIND, the first raw Param word at
	// CRefSkill+0x168 -- the column before the code runs start
	// (skillparam.ParamBlockColumn, +0x16c; docs/protocol/skill_params.md,
	// "The buff lifecycle"). The heal branch runs only for kind 0 (0x5941f1
	// `cmp [ebx+0x168],0`).
	skActionKind    = skillparam.ParamBlockColumn - 1
	skConsumeHP     = 52
	skConsumeMP     = 53
	skMastery1      = 34 // ReqCommon_Mastery1
	skMasteryLevel1 = 36 // ReqCommon_MasteryLevel1 (required mastery level)
	// The two required-weapon bytes. The engine names them itself: the
	// skilldata row loader SkillGlobal::FUN_005893e0 refuses a row whose
	// CRefSkill+199/+200 are zero with "ReqWeapon Error [RefSkill ID: %d]",
	// and FUN_0058d480 checks them against the equipped weapon's TID >> 11.
	// 0xff (255) marks an unused slot; both 0xff means no requirement.
	skReqCastWeapon1 = 50
	skReqCastWeapon2 = 51
	// The learn prerequisites: three (group id, required level) pairs.
	// Verified on the Power Strike chain 2026-09-19: SKILL_CH_SWORD_SMASH_B_01
	// carries 174/9 -- the A series' group at level 9 -- and 3,305 of the
	// 33,632 real rows carry one.
	skReqLearnSkill1      = 40
	skReqLearnSkill2      = 41
	skReqLearnSkill3      = 42
	skReqLearnSkillLevel1 = 43
	skReqLearnSkillLevel2 = 44
	skReqLearnSkillLevel3 = 45
	skReqLearnSP          = 46 // ReqLearn_SP (learn cost, verified 2/5/7 across SMASH_A 1-3)
	skReqLearnRace        = 47 // ReqLearn_Race
	skName                = 62 // SN_SKILL_ name code
	// skBasicGroup and skBasicActivity are Basic_Group (the std::string at
	// CRefSkill+0x44) and Basic_Activity (the u8 at +0x65), columns 5 and 8
	// in CopyFixedColumns' order (docs/protocol/skill_fields.md). Round 636:
	// the recast rule's 'efr' kind-2 branch compares Basic_Group strings
	// (0x59d985 FUN_00425210 on +0x44), and the category end FUN_005a16c0
	// takes only rows whose +0x65 is non-zero.
	skBasicGroup    = 5
	skBasicActivity = 8
	// The highest field skillRecord reads; a shorter row isn't a real skill.
	skMax = 62
)

func main() {
	out := flag.String("out", "-", "output CSV path, or - for stdout")
	mode := flag.String("mode", "items", "which reference table the input files are: items, skills, npcpos or teleport")
	flag.Parse()
	if flag.NArg() == 0 || (*mode != "items" && *mode != "skills" && *mode != "npcpos" && *mode != "teleport") {
		fmt.Fprintln(os.Stderr, "usage: export-refdata [-mode items|skills|npcpos] -out out.csv <data_*.txt> ...")
		fmt.Fprintln(os.Stderr, "       export-refdata -mode teleport -out <dir> teleportdata.txt teleportlink.txt teleportbuilding.txt")
		os.Exit(2)
	}
	record, noun := itemRecord, "item"
	switch *mode {
	case "skills":
		record, noun = skillRecord, "skill"
	case "npcpos":
		// npcpos rows are placements, not records keyed by id: one species
		// has dozens of them. Every row goes out, in file order, under the
		// header spawn.NpcPosCSVColumns.
		exportNpcPos(*out)
		return
	case "teleport":
		// Three tables in, three CSVs out, into the directory -out names:
		// what cmd/server's -teleport-dir loads (internal/teleport).
		if err := exportTeleport(*out, flag.Args()); err != nil {
			fmt.Fprintf(os.Stderr, "export-refdata: %v\n", err)
			os.Exit(1)
		}
		return
	}

	var sink *os.File
	if *out == "-" {
		sink = os.Stdout
	} else {
		f, err := os.Create(*out)
		if err != nil {
			fmt.Fprintf(os.Stderr, "creating %s: %v\n", *out, err)
			os.Exit(1)
		}
		defer f.Close()
		sink = f
	}
	w := csv.NewWriter(sink)
	defer w.Flush()

	// The client's itemdata shards OVERLAP. Measured 2026-09-16 over a real
	// client's tables: 6,224 of 15,338 item ids appear in more than one shard,
	// and 608 of those carry genuinely different values -- itemdata_1000.txt
	// and itemdata_5000.txt disagree on shield defence (1.3 against 1.25),
	// which is an older copy of the table sitting beside a newer one.
	//
	// Streaming every row straight out would put both copies in the CSV and
	// leave which one reaches the database up to the importer's upsert order,
	// i.e. up to the order the operator's shell happened to glob the files in.
	// So rows are collected keyed by id, LAST occurrence wins (the same rule
	// the upsert follows, now made explicit rather than accidental), and the
	// operator is told what collided.
	written, skipped, dupes, conflicts := 0, 0, 0, 0
	order := []string{}
	byID := map[string][]string{}
	for _, path := range flag.Args() {
		rows, err := readTable(path)
		if err != nil {
			fmt.Fprintf(os.Stderr, "reading %s: %v\n", path, err)
			os.Exit(1)
		}
		for _, cols := range rows {
			rec, ok := record(cols)
			if !ok {
				skipped++
				continue
			}
			id := rec[0]
			if prev, seen := byID[id]; seen {
				dupes++
				if !sameRecord(prev, rec) {
					conflicts++
				}
			} else {
				order = append(order, id)
			}
			byID[id] = rec
		}
	}
	for _, id := range order {
		if err := w.Write(byID[id]); err != nil {
			fmt.Fprintf(os.Stderr, "writing: %v\n", err)
			os.Exit(1)
		}
		written++
	}
	w.Flush()
	fmt.Fprintf(os.Stderr, "export-refdata: wrote %d %s rows, skipped %d non-%s rows\n", written, noun, skipped, noun)
	if dupes > 0 {
		fmt.Fprintf(os.Stderr, "export-refdata: %d duplicate ids across the input files, %d of them with CONFLICTING values; kept the last occurrence of each\n", dupes, conflicts)
	}
}

// sameRecord reports whether two CSV records are equal field for field, with
// numbers compared as numbers. The shards disagree on formatting far more often
// than on substance -- the same value appears as "0" in one table and "0.0" in
// another -- and reporting those as conflicts would bury the 608 that matter in
// thousands that do not.
func sameRecord(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] == b[i] {
			continue
		}
		x, errX := strconv.ParseFloat(a[i], 64)
		y, errY := strconv.ParseFloat(b[i], 64)
		if errX != nil || errY != nil || x != y {
			return false
		}
	}
	return true
}

// itemRecord maps one tab-split itemdata row to the 28-column CSV
// import-refdata expects, or (nil, false) if the row is not a real item.
func itemRecord(cols []string) ([]string, bool) {
	if len(cols) <= fMax {
		return nil, false
	}
	if _, err := strconv.Atoi(strings.TrimSpace(cols[fID])); err != nil {
		return nil, false
	}
	// Bounds-checked: the columns read here run out to the Param block near
	// col 124, and a short or older itemdata row must yield "0" rather than
	// panic the exporter.
	get := func(i int) string {
		if i >= len(cols) {
			return "0"
		}
		s := strings.TrimSpace(cols[i])
		if s == "" {
			return "0"
		}
		return s
	}
	// An unsigned dword field: the Param columns of rows that are not
	// elixirs hold other things, "-1" among them, and a packed-rate reader
	// wants a dword or nothing.
	u32 := func(i int) string {
		if i >= len(cols) {
			return "0"
		}
		s := strings.TrimSpace(cols[i])
		if _, err := strconv.ParseUint(s, 10, 32); err != nil {
			return "0"
		}
		return s
	}
	// A string field, trimmed, empty when the row is short.
	str := func(i int) string {
		if i >= len(cols) {
			return ""
		}
		return strings.TrimSpace(cols[i])
	}
	// A float field: itemdata writes some as "2.4"; keep as-is, default 0.
	num := func(i int) string {
		if i >= len(cols) {
			return "0"
		}
		s := strings.TrimSpace(cols[i])
		if _, err := strconv.ParseFloat(s, 64); err != nil {
			return "0"
		}
		return s
	}
	cooltimeGroup, cooltimeMs := cooltimeOf(cols)
	dropFlag := canDrop(get(fCanTrade), get(fCanDrop))
	return []string{
		get(fID),                 // 0  ID
		get(fMaxStack),           // 1  MaxStack (col 57: 1 for equipment, real cap for stackables)
		get(fReqStr),             // 2  ReqStr
		get(fReqInt),             // 3  ReqInt
		get(fItemClass),          // 4  ItemClass
		get(fTwoHanded),          // 5  TwoHanded
		num(fDurabilityMin),      // 6  DurabilityMin
		num(fDurabilityMin + 1),  // 7  DurabilityMax
		num(fPhysDefenseMin),     // 8  PhysDefenseMin
		num(fPhysDefenseMin + 1), // 9  PhysDefenseMax
		num(fMagDefenseMin),      // 10 MagDefenseMin
		num(fMagDefenseMin + 1),  // 11 MagDefenseMax
		num(fPhysAttackMin),      // 12 PhysAttackMin
		num(fPhysAttackMax),      // 13 PhysAttackMax
		num(fMagAttackMin),       // 14 MagAttackMin
		num(fMagAttackMax),       // 15 MagAttackMax
		num(fHitRate),            // 16 HitRateMin -- col 113, the verified tooltip value
		// 17 HitRateMax and 19 CriticalMax are REAL after all, restored
		// 2026-09-15. They had been withdrawn and emitted as literal "0" on the
		// argument that a real max would display as a range the way physical
		// attack does ("27 ~ 28"), while the verified Copper Sword tooltip shows
		// "Attack rate 24" and "Critical 3" -- single values.
		//
		// That argument's premise was wrong. Physical attack displays as a range
		// because its min and max are two DIFFERENT stats, at cols 95 and 97, each
		// with its own (lo, hi) variance pair beside it. Attack rate and critical
		// are ONE stat each, and the pair beside them is that stat's per-instance
		// variance -- so an instance has a single value and shows a single number.
		// The tooltip is consistent with both readings; it never discriminated.
		//
		// What settles it is the engine. FUN_00495d60 computes every item stat as
		// `lo + t*(hi-lo) + inc*plus` from a (lo, hi, inc) triple at consecutive
		// ref-object dwords, and two of those triples are (0x288, 0x28c, 0x290) ->
		// item +0x1d8 and (0x294, 0x298, 0x29c) -> item +0x1dc -- the exact fields
		// Char_PublishCombatStats publishes as ParamKeeper params 11 ('hra',
		// attack rate) and 12 ('cri', critical). So each of them IS a lo/hi pair,
		// and the tooltip value is the lo.
		//
		// The data agrees with the engine's own precondition: it asserts that
		// lo > hi is impossible, and across all 1,568 rows carrying the block,
		// col 113 <= col 114 and col 116 <= col 117 with ZERO inversions (448 rows
		// have col 116 == col 117, which the assert permits). Two unrelated stats
		// would invert somewhere.
		num(fHitRate + 1),      // 17 HitRateMax  -- col 114, the variance ceiling
		num(fCritical),         // 18 CriticalMin -- col 116, the verified tooltip value
		num(fCritical + 1),     // 19 CriticalMax -- col 117, the variance ceiling
		get(fTypeID1),          // 20 TypeID1
		get(fTypeID1 + 1),      // 21 TypeID2
		get(fTypeID1 + 2),      // 22 TypeID3
		get(fTypeID1 + 3),      // 23 TypeID4
		get(fCountry),          // 24 Country
		get(fReqGender),        // 25 ReqGender
		get(fReqLevelType1),    // 26 ReqLevelType1
		get(fReqLevel1),        // 27 ReqLevel1
		get(fPrice),            // 28 Price (real NPC buy price)
		get(fSellPrice),        // 29 SellPrice (real NPC buy-back price)
		get(fRestoreHP),        // 30 RestoreHP    (Param block, labelled "HP...")
		get(fRestoreHPPct),     // 31 RestoreHPPct
		get(fRestoreMP),        // 32 RestoreMP    (Param block, labelled "MP...")
		get(fRestoreMPPct),     // 33 RestoreMPPct
		num(fBlockRatio),       // 34 BlockRatioMin (shields only)
		num(fBlockRatio + 1),   // 35 BlockRatioMax
		num(fReinforcePhysMin), // 36 ReinforcePhysMin (weapons only)
		num(fReinforcePhysMax), // 37 ReinforcePhysMax
		num(fReinforceMagMin),  // 38 ReinforceMagMin
		num(fReinforceMagMax),  // 39 ReinforceMagMax
		get(fSetID),            // 40 SetID
		get(fCanTrade),         // 41 CanTrade
		get(fCanSell),          // 42 CanSell
		dropFlag,               // 43 CanDrop -- col 20 bit 0, cleared by the CanTrade coupling
		get(fReqLevelType2),    // 44 ReqLevelType2 -- requirement slots 2..4
		get(fReqLevel2),        // 45 ReqLevel2
		get(fReqLevelType3),    // 46 ReqLevelType3
		get(fReqLevel3),        // 47 ReqLevel3
		get(fReqLevelType4),    // 48 ReqLevelType4
		get(fReqLevel4),        // 49 ReqLevel4
		num(fRepairCost),       // 50 RepairCost
		get(fDecayTime),        // 51 DecayTime (ms on the ground)
		// 52..59: the weapon stats' per-instance HIGH ends (round 244). The
		// item parser (RefObjItem::ExtractData, 0x006a3d50) reads columns 95/96
		// into the physical-damage-min pair at +0x228/+0x22c, 97/98 into the
		// max pair at +0x234/+0x238 (99 is the shared per-plus increment at
		// +0x23c), 100/101 and 102/103 into the magical pairs, and 105..112
		// into the four reinforce pairs (divided by 1000 on the way in). The
		// weapon branch of Char_BuildAggregateStats interpolates each pair by
		// the instance's variance group -- 4, 5, 1, 2 respectively -- which is
		// what combat.WeaponRange now does with these.
		num(fPhysAttackMin + 1),    // 52 PhysAttackMinHi     (col 96)
		num(fPhysAttackMax + 1),    // 53 PhysAttackMaxHi     (col 98)
		num(fMagAttackMin + 1),     // 54 MagAttackMinHi      (col 101)
		num(fMagAttackMax + 1),     // 55 MagAttackMaxHi      (col 103)
		num(fReinforcePhysMin + 1), // 56 ReinforcePhysMinHi  (col 106)
		num(fReinforcePhysMax + 1), // 57 ReinforcePhysMaxHi  (col 108)
		num(fReinforceMagMin + 1),  // 58 ReinforceMagMinHi   (col 110)
		num(fReinforceMagMax + 1),  // 59 ReinforceMagMaxHi   (col 112)
		// 60: the weapon's Range, itemdata column 94 -- the u16 the item parser
		// stores at ref+0x224 and Char_PublishCombatStats publishes as param 33
		// (round 247). World units: swords 6, spears 18, bows 180, daggers 3.
		get(fRange), // 60 Range (col 94)
		// 61-63: an elixir's packed reinforce rates, itemdata Param2/3/4
		// (columns 120/122/124), decimal dwords as the table prints them.
		u32(fParam2), // 61 ReinforceRate1 (col 120)
		u32(fParam3), // 62 ReinforceRate2 (col 122)
		u32(fParam4), // 63 ReinforceRate3 (col 124)
		// 64-65: the item's reuse cooltime. RefObjItem::ExtractData scans the
		// 20 Desc128 strings for "cooltime" and, on "COOLTIME:<group>", stores
		// the group (decimal, or hex after "0x") at ref+0x520 and that
		// element's Param -- milliseconds -- at ref+0x524; Item_HandleUseItem
		// refuses 0x185b WAIT_FOR_REUSE_DELAY while the group's timer runs and
		// arms it for that many ms on success (round 263). 148 retail rows
		// carry one; no HP/MP potion does.
		cooltimeGroup, cooltimeMs,
		// 66-67: body armour's parry pair, itemdata columns 68/69. The engine
		// reads it as ParamKeeper param 9 ('era'), the defender's half of the
		// damage centre. srrevamp models neither per-instance variance nor plus
		// level, so the lo end is the value that applies -- the same rule the
		// attack and reinforce pairs follow.
		num(fParryRatio),     // 66 ParryRatioMin (body armour only)
		num(fParryRatio + 1), // 67 ParryRatioMax
		// 68: CanUse, flags bit 8 (round 489, see fCanUse). The parser keeps
		// only whether the byte is non-zero, and the column really holds 129
		// on some rows, so it is emitted as 0/1 like CanDrop's bit.
		nonZero(get(fCanUse)), // 68 CanUse (col 24)
		// 69: CanPick, flags bit 5 (round 493, see fCanPick), folded to 0/1 by
		// the same `c != 0` rule.
		nonZero(get(fCanPick)), // 69 CanPick (col 21)
		// 70: CodeName (round 497, see fCodeName), verbatim: an empty cell
		// stays empty rather than becoming get's "0".
		str(fCodeName), // 70 CodeName (col 2)
		// 71: CompositeDesc (round 632 review, see compositeDescOf).
		compositeDescOf(cols, get(fTypeID1), get(fTypeID1+1), get(fTypeID1+2), get(fTypeID1+3)),
	}, true
}

// nonZero emits a flag column the way RefObjCommon_ExtractData (0x006a3090)
// folds it into the flags word, `-(c != 0) & bit`: "1" for any non-zero
// value, "0" for zero or anything that is not a number. It exists because
// such columns are not always 0/1 -- CanUse (column 24) holds 129 on 213
// retail rows -- and a consumer reading the raw byte as a boolean would have
// to repeat the rule.
func nonZero(s string) string {
	n, err := strconv.Atoi(strings.TrimSpace(s))
	if err != nil || n == 0 {
		return "0"
	}
	return "1"
}

// canDrop emits CanDrop, flags bit 4, as "0"/"1" from the CanTrade byte
// (column 16) and the CanDrop byte (column 20), the way
// RefObjCommon_ExtractData (0x006a3090) builds the bit.
//
// First the coupling, just before the flags word is assembled: 0x6a34e6 `cmp
// [esp+0x11],0` (CanTrade), 0x6a34f0 `cmp [esp+0x13],1` and 0x6a34f7 `mov
// [esp+0x13],0`. An untradeable item whose CanDrop byte is exactly 1 is made
// undroppable. The test is equality, so a byte of 3 keeps bit 0.
//
// Then the bit, at 0x6a3540..0x6a3552: `b & 1` is CanDrop, and `b & 2` is the
// unnamed bit 14, which is not exported. A value that is not a number counts
// as 0, as nonZero treats it.
func canDrop(trade, drop string) string {
	t, err := strconv.Atoi(strings.TrimSpace(trade))
	if err != nil {
		t = 0
	}
	d, err := strconv.Atoi(strings.TrimSpace(drop))
	if err != nil {
		d = 0
	}
	if t == 0 && d == 1 {
		d = 0
	}
	if d&1 != 0 {
		return "1"
	}
	return "0"
}

// compositeDescOf is the composite item's timed-job list: RefObjItem's
// ExtractData (the loop at 0x6a558e..0x6a55aa) hands Desc_k to the list
// parser ReferenceData::FUN_00864bc0 for k = 2..5 on TypeID 3/3/13/14 and
// k = 2..3 on 3/3/13/15, only where Param_k (the dword before the desc,
// `cmp [esi-0x4],1`) is 1. Joined with "," (each list is itself
// "[...],[...]"); empty for every other row.
func compositeDescOf(cols []string, t1, t2, t3, t4 string) string {
	if t1 != "3" || t2 != "3" || t3 != "13" || (t4 != "14" && t4 != "15") {
		return ""
	}
	last := 5
	if t4 == "15" {
		last = 3
	}
	var parts []string
	for k := 2; k <= last; k++ {
		vi, di := fParam1+2*(k-1), fParam1+2*(k-1)+1
		if di >= len(cols) {
			break
		}
		if strings.TrimSpace(cols[vi]) != "1" {
			continue
		}
		if d := strings.TrimSpace(cols[di]); d != "" && d != "xxx" {
			parts = append(parts, d)
		}
	}
	return strings.Join(parts, ",")
}

// cooltimeOf finds the (Param, Desc128) pair whose descriptor reads
// "COOLTIME:<group>" and returns the group and the delay in milliseconds as
// strings, "0"/"0" when the row has none -- the parser's own rule (case-
// insensitive "cooltime", the group after ':' in decimal or 0x-hex).
func cooltimeOf(cols []string) (group, ms string) {
	group, ms = "0", "0"
	for k := 0; k < 20; k++ {
		vi, di := fParam1+2*k, fParam1+2*k+1
		if di >= len(cols) {
			break
		}
		desc := strings.TrimSpace(cols[di])
		if !strings.Contains(strings.ToLower(desc), "cooltime") {
			continue
		}
		colon := strings.IndexByte(desc, ':')
		if colon < 0 {
			continue
		}
		g := strings.TrimSpace(desc[colon+1:])
		var v uint64
		var err error
		if strings.HasPrefix(strings.ToLower(g), "0x") {
			v, err = strconv.ParseUint(g[2:], 16, 32)
		} else {
			v, err = strconv.ParseUint(g, 10, 32)
		}
		if err != nil {
			continue
		}
		if _, err := strconv.ParseUint(strings.TrimSpace(cols[vi]), 10, 32); err != nil {
			continue
		}
		return strconv.FormatUint(v, 10), strings.TrimSpace(cols[vi])
	}
	return group, ms
}

// skillRecord maps one tab-split skilldata row to the 62-column skill CSV
// (refdata.skillCSVColumns order) import-refdata expects, or (nil, false) if
// the row is not a real skill. The learn-gating fields and the cast timing /
// range / resource cost are mapped from verified real columns (see the
// skilldata-columns note); so are Basic_ChainCode and AutoAttackType, the two
// fields the keep-up hand-off tests (round 502 -- until then both shipped as
// "0", so the hand-off round 256 built never fired). Two flags (FlyingSpeed,
// Interruptable), the Overlap slot itself and the unused Basic_Name /
// Basic_RecycleCost stay "0" placeholders; Overlap's high byte, the cooldown
// group, goes out as its own column 45 (round 504, cooldownGroup).
func skillRecord(cols []string) ([]string, bool) {
	if len(cols) <= skMax {
		return nil, false
	}
	if _, err := strconv.Atoi(strings.TrimSpace(cols[skID])); err != nil {
		return nil, false
	}
	get := func(i int) string {
		if i >= len(cols) {
			return "0"
		}
		s := strings.TrimSpace(cols[i])
		if s == "" {
			return "0"
		}
		return s
	}
	atkType, pct, dmgMin, dmgMax := attackParam(cols)
	hits := hitCountParam(cols)
	healHP, healMP := selfHeal(cols)
	return append([]string{
		get(skID),             // 0  ID
		get(skGroupID),        // 1  GroupID
		get(skBasicCode),      // 2  Basic_Code
		"0",                   // 3  Basic_Name (not verified)
		get(skBasicLevel),     // 4  Basic_Level
		get(skChainCode),      // 5  Basic_ChainCode (raw col 9, CRefSkill+0x68)
		"0",                   // 6  Basic_RecycleCost (not verified)
		get(skPreparingTime),  // 7  PreparingTime  (verified raw col 11)
		get(skCastingTime),    // 8  CastingTime    (verified raw col 12)
		get(skActionDuration), // 9  ActionDuration (verified raw col 13)
		get(skReuseDelay),     // 10 ReuseDelay/cooldown (verified raw col 14)
		get(skCoolTime),       // 11 CoolTime       (verified raw col 15)
		"0",                   // 12 FlyingSpeed (flag, not mapped)
		"0",                   // 13 Interruptable (flag, not mapped)
		"0",                   // 14 Overlap (bitfield; only its high byte is read -- column 45)
		get(skAutoAttackType), // 15 AutoAttackType (raw col 19, CRefSkill+0x90)
		get(skRange),          // 16 Range          (verified raw col 21)
		get(skConsumeHP),      // 17 Consume_HP     (verified raw col 52)
		get(skConsumeMP),      // 18 Consume_MP     (verified raw col 53)
		get(skReqLearnSP),     // 19 ReqLearn_SP    (verified raw col 46)
		get(skReqLearnRace),   // 20 ReqLearn_Race  (raw col 47)
		get(skName),           // 21 UI_SkillName    (SN_SKILL_ name code, raw col 62)
		get(skMastery1),       // 22 ReqCommon_Mastery1      (verified raw col 34)
		get(skMasteryLevel1),  // 23 ReqCommon_MasteryLevel1 (verified raw col 36)
		pct,                   // 24 AttackPercent -- real, from the 'att' param
		dmgMin,                // 25 DamageMin
		dmgMax,                // 26 DamageMax
		hits,                  // 27 HitCount -- real, from the 'mc' param
		atkType,               // 28 AttackType -- real, 'att' value[0]
		get(skReqCastWeapon1), // 29 ReqCast_Weapon1
		get(skReqCastWeapon2), // 30 ReqCast_Weapon2
		reqItemCount(cols),    // 31 ReqCastListCount -- 'reqi' runs; non-zero disables the weapon gate
		reqItemList(cols),     // 32 ReqCastList -- the 'reqi' records as kind:value;...
		reqAll(cols),          // 33 ReqCastAll -- 'reqn': the list is ALL-of, not ANY-of
		noCombatParam(cols),   // 34 NoCombatParam -- the engine resolves no blow for this skill
		zeroDamage(cols),      // 35 ZeroDamage -- a resolved blow whose damage is zero
		floorBlow(cols),       // 36 FloorBlow -- a computed blow that is identically zero, so always the floor of 1
		// 37..42: the learn prerequisites (group id, level) x3, skilldata 40..45.
		get(skReqLearnSkill1),      // 37 ReqLearnSkill1
		get(skReqLearnSkillLevel1), // 38 ReqLearnSkillLevel1
		get(skReqLearnSkill2),      // 39 ReqLearnSkill2
		get(skReqLearnSkillLevel2), // 40 ReqLearnSkillLevel2
		get(skReqLearnSkill3),      // 41 ReqLearnSkill3
		get(skReqLearnSkillLevel3), // 42 ReqLearnSkillLevel3
		healHP,                     // 43 SelfHealHP -- 'heal' value[0] a flat self-heal restores (round 503)
		healMP,                     // 44 SelfHealMP -- 'heal' value[2], its MP half
		cooldownGroup(cols),        // 45 CooldownGroup -- Overlap's high byte, CRefSkill+0x8f (round 504)
		sitGate(cols),              // 46 SitGate -- the skill gate's motion-state refusals (round 607)
		// 47..61: the buff and self-cast columns (round 616, buffColumns); then
		// 62..88 (targetHeal, stackColumns, linkColumns, wallColumns, teleColumns).
	}, append(append(append(append(append(buffColumns(cols), targetHeal(cols)...), stackColumns(cols)...), linkColumns(cols)...), wallColumns(cols)...), teleColumns(cols)...)...), true
}

// targetHeal is skill CSV columns 62/63 (round 622), TargetHealHP and
// TargetHealMP: what one cast restores to EACH character it names --
// skillparam.TargetHealAmounts over the row's action kind, Target_Required
// and Param block. Anything it cannot read answers ("0", "0"), which is also
// what an export predating the columns loads: no heal on a target.
func targetHeal(cols []string) []string {
	words, ok := paramWords(cols)
	if !ok {
		return []string{"0", "0"}
	}
	kind, err := strconv.ParseInt(strings.TrimSpace(cols[skActionKind]), 10, 32)
	if err != nil {
		return []string{"0", "0"}
	}
	tr, err := strconv.Atoi(strings.TrimSpace(cols[skTargetRequired]))
	if err != nil {
		return []string{"0", "0"}
	}
	h, m := skillparam.TargetHealAmounts(int32(kind), tr != 0, words)
	return []string{strconv.Itoa(h), strconv.Itoa(m)}
}

// buffColumns are skill CSV columns 47..61 (round 616,
// docs/protocol/skill_buffs.md), in refdata.skillCSVColumns order:
//
//	47 ActionKind      the first raw Param word, CRefSkill+0x168 (skActionKind)
//	48 TargetRequired  +0x94, column 22
//	49 TargetLand      +0x96, column 24
//	50-52 TargetSelf/Ally/Party  +0x98..+0x9a, columns 26-28
//	53 DuraMs          'dura' value[0] (+0x280), 0 without one
//	54-57 Cbuf/Nbuf/Bbuf/Lnks  the marker and 'lnks' runs, 1 when present
//	58-59 Tele0/Tele1  'tele' value[0] and value[1] (+0x2ec), 0 without one
//	60 BuffParams      every publishing run (skillparam.Contributions) as
//	                   code:v0,v1;...
//	61 Lks2            the 'lks2' marker (+0x374), 1 when present
//
// Columns 62/63 (TargetHealHP/MP, round 622) follow, from targetHeal.
//
// The Param block is WALKED (skillparam.Walk), never scanned. A walk that
// does not finish -- none does on the 33,632 retail rows (skill_params.md) --
// decides a code absent only when its literal word is nowhere in the row;
// otherwise a flag is set (the refusal it drives is kept) and a value is 0.
func buffColumns(cols []string) []string {
	get := func(i int) string {
		if i >= len(cols) {
			return "0"
		}
		s := strings.TrimSpace(cols[i])
		if s == "" {
			return "0"
		}
		if _, err := strconv.Atoi(s); err != nil {
			return "0"
		}
		return s
	}
	flag01 := func(i int) string {
		if get(i) != "0" {
			return "1"
		}
		return "0"
	}
	out := []string{
		get(skActionKind),
		flag01(skTargetRequired),
		flag01(skTargetLand),
		flag01(skTargetSelf),
		flag01(skTargetAlly),
		flag01(skTargetParty),
	}
	words, ok := paramWords(cols)
	if !ok {
		return append(out, "0", "0", "0", "0", "0", "0", "0", "", "0")
	}
	entries, _, complete := skillparam.Walk(words)
	find := func(c skillparam.Code) (skillparam.Entry, bool) {
		for _, e := range entries {
			if e.Code == c {
				return e, true
			}
		}
		return skillparam.Entry{}, false
	}
	value := func(e skillparam.Entry, k int) string {
		if e.Index+1+k >= len(words) || k+1 >= e.Run {
			return "0"
		}
		return strconv.Itoa(int(words[e.Index+1+k]))
	}
	dura := "0"
	if e, ok := find("dura"); ok {
		dura = value(e, 0)
	}
	out = append(out, dura)
	for _, c := range []skillparam.Code{"cbuf", "nbuf", "bbuf", "lnks"} {
		_, ok := find(c)
		if !ok && !complete && !literalAbsent(cols, []skillparam.Code{c}) {
			ok = true
		}
		if ok {
			out = append(out, "1")
		} else {
			out = append(out, "0")
		}
	}
	tele0, tele1 := "0", "0"
	if e, ok := find("tele"); ok {
		tele0, tele1 = value(e, 0), value(e, 1)
	}
	out = append(out, tele0, tele1)
	var runs []string
	for _, e := range entries {
		if _, publishes := skillparam.Contributions[e.Code]; !publishes {
			continue
		}
		vals := make([]string, 0, e.Run-1)
		for k := 0; k+1 < e.Run; k++ {
			vals = append(vals, value(e, k))
		}
		runs = append(runs, string(e.Code)+":"+strings.Join(vals, ","))
	}
	out = append(out, strings.Join(runs, ";"))
	// 61 Lks2 (round 616's review): the 'lks2' marker, decided like the four
	// above.
	_, lks2 := find("lks2")
	if !lks2 && !complete && !literalAbsent(cols, []skillparam.Code{"lks2"}) {
		lks2 = true
	}
	if lks2 {
		return append(out, "1")
	}
	return append(out, "0")
}

// stackColumns are skill CSV columns 64..76 (round 636,
// docs/protocol/skill_buffs.md "The recast rule"): what FUN_0059d870, its
// bit test FUN_0059db10, SkillBook::SetGroupBits (0x59dc00) and the category
// end FUN_005a16c0 read off a row, in refdata.skillCSVColumns order:
//
//	64 ActionOverlap  Action_Overlap (+0x8c, column 18) AND 0xffffff: the three
//	                  low bytes the bit test and SetGroupBits walk (shifts 0, 8,
//	                  16; the high byte is the cooldown group, column 45)
//	65 Ovl2           'ovl2' value[0] (+0x37c), 0 without one (all 32 bits:
//	                  the functions mask the three low bytes themselves)
//	66 HasDttp        'dttp' (+0x424) present
//	67-68 Dttp0/Dttp1 'dttp' value[0] and value[1]
//	69 Efr2           an 'efr' run with value[0] == 2, the field +0x290
//	                  (skill_params.md: efr files itself at 0x28c/0x290/0x294
//	                  by value[0])
//	70 Offensive      FUN_00589d20's answer (see offensiveCodes)
//	71 Msch1          'msch' (+0x4a4) with value[0] == 1
//	72 Hide           'hide' (+0x428) present
//	73 SkcEnd         'skc' (+0x490) value[1] AND 0xff -- the byte at +4
//	                  FUN_005a16c0 intersects with its event mask
//	74 BasicGroup     Basic_Group, column 5 (+0x44)
//	75 Activity       Basic_Activity, column 8 (+0x65)
//	76 Dtt            'dtt' (+0x420) present: SkillAction_Buff attaches the
//	                  caster to an 'efr' kind-2 record only without it
//	                  (0x5830b0, `puVar12[0xa4] != 0 && puVar12[0x108] == 0`)
//
// An older export loads all of them as zero/empty: no overlap bits, which is
// what the server tested before this round.
func stackColumns(cols []string) []string {
	intCol := func(i int) int64 {
		if i >= len(cols) {
			return 0
		}
		v, err := strconv.ParseInt(strings.TrimSpace(cols[i]), 10, 64)
		if err != nil {
			return 0
		}
		return v
	}
	strCol := func(i int) string {
		if i >= len(cols) {
			return ""
		}
		return strings.TrimSpace(cols[i])
	}
	overlap := strconv.FormatUint(uint64(uint32(intCol(skOverlap))&0xffffff), 10)
	tail := []string{strCol(skBasicGroup), strconv.FormatInt(intCol(skBasicActivity), 10)}
	words, ok := paramWords(cols)
	if !ok {
		return append(append([]string{overlap, "0", "0", "0", "0", "0", "0", "0", "0", "0"}, tail...), "0")
	}
	entries, _, _ := skillparam.Walk(words)
	value := func(e skillparam.Entry, k int) int64 {
		if e.Index+1+k >= len(words) || k+1 >= e.Run {
			return 0
		}
		return int64(words[e.Index+1+k])
	}
	var (
		ovl2, dttp0, dttp1, skc         int64
		hasDttp, efr2, msch1, hide, off bool
		dtt                             bool
		present                         = map[skillparam.Code]bool{}
	)
	for _, e := range entries {
		present[e.Code] = true
		switch e.Code {
		case "ovl2":
			ovl2 = value(e, 0)
		case "dttp":
			hasDttp, dttp0, dttp1 = true, value(e, 0), value(e, 1)
		case "efr":
			if value(e, 0) == 2 {
				efr2 = true
			}
		case "msch":
			if value(e, 0) == 1 {
				msch1 = true
			}
		case "hide":
			hide = true
		case "dtt":
			dtt = true
		case "skc":
			skc = value(e, 1) & 0xff
		}
	}
	off = offensive(present)
	b := func(v bool) string {
		if v {
			return "1"
		}
		return "0"
	}
	return append([]string{
		overlap,
		strconv.FormatInt(ovl2, 10),
		b(hasDttp), strconv.FormatInt(dttp0, 10), strconv.FormatInt(dttp1, 10),
		b(efr2), b(off), b(msch1), b(hide),
		strconv.FormatInt(skc, 10),
	}, append(tail, b(dtt))...)
}

// linkColumns are skill CSV columns 77..82 (round 636's review): what
// FUN_0059dc80, the 'lnks' rows' recast check, reads off a row, in
// refdata.skillCSVColumns order:
//
//	77 LnksGroup  'lnks' (+0x370) value[0]: the records it compares
//	78 LnksMax    'lnks' value[2]: the count that refuses
//	79 Efr3       an 'efr' run with value[0] == 3, the field +0x294: gate row
//	              16 calls FUN_0059dc80 for an 'lnks' row only with it
//	              (0x58e308)
//	80 Qest       'qest' (+0x49c) present
//	81 Trap       'trap' (+0x4a0) present: with Qest, 0x3037 instead of 0x3029
//	82 Efr1       an 'efr' run with value[0] == 1, the field +0x28c (the
//	              follow-up of round 636's review): SkillAction_Buff's
//	              sub-state 0 takes an 'efr' kind-1 row whose Basic_Activity
//	              is not 1 down the target-collector path (0x5830b0, READ),
//	              which charges before any bit test, instead of the bit test
//	              at 0x583ffb..0x584044
//
// An older export loads zero for all of them: the check never refuses.
func linkColumns(cols []string) []string {
	words, ok := paramWords(cols)
	if !ok {
		return []string{"0", "0", "0", "0", "0", "0"}
	}
	entries, _, _ := skillparam.Walk(words)
	value := func(e skillparam.Entry, k int) int64 {
		if e.Index+1+k >= len(words) || k+1 >= e.Run {
			return 0
		}
		return int64(words[e.Index+1+k])
	}
	var group, max int64
	var efr1, efr3, qest, trap bool
	for _, e := range entries {
		switch e.Code {
		case "lnks":
			group, max = value(e, 0), value(e, 2)
		case "efr":
			switch value(e, 0) {
			case 1:
				efr1 = true
			case 3:
				efr3 = true
			}
		case "qest":
			qest = true
		case "trap":
			trap = true
		}
	}
	b := func(v bool) string {
		if v {
			return "1"
		}
		return "0"
	}
	return []string{strconv.FormatInt(group, 10), strconv.FormatInt(max, 10), b(efr3), b(qest), b(trap), b(efr1)}
}

// wallColumns are skill CSV columns 83..86 (round 640, docs/protocol/
// skill_buffs.md "The protection walls"): the four values of 'pw' (+0x2b4),
// 0 without the run. What each is, READ in SR_GameServer.exe:
//
//	83 Pw0  the damage-type mask the wall covers: bit 4 physical, bit 8
//	        magical (Combat_ResolveDamage 0x58e5f0 tests it against the
//	        attacker's 'att' value[0]; FUN_0040ebe0 / FUN_0040eef0 compute a
//	        half only when both carry its bit)
//	84 Pw1  the wall's HP: EngageSkill (0x593540) copies `*(pw+4)` into the
//	        wall object at ctx+0x5c, +8; Combat_ApplyActionEffects subtracts
//	        each absorbed blow from it
//	85 Pw2  the wall's flat defence: FUN_0040ebe0 subtracts `*(pw+8)` where
//	        Formula_MitigatePhysicalDamage subtracts the defender's param 5
//	86 Pw3  the wall's defence percent: FUN_0040ebe0 divides by
//	        `1 + *(pw+0xc)/100` where the formula divides by the defender's
//	        param 7
//
// 55 rows of the retail export carry it (MEASURED, round 640's census): 28
// SKILL_CH_COLD_BINGBYEOK_* with mask 7 and 27 SKILL_CH_FIRE_HWABYEOK_* with
// mask 11, every one with 'onff' too. An older export loads 0: no wall.
func wallColumns(cols []string) []string {
	out := []string{"0", "0", "0", "0"}
	words, ok := paramWords(cols)
	if !ok {
		return out
	}
	entries, _, _ := skillparam.Walk(words)
	for _, e := range entries {
		if e.Code != "pw" {
			continue
		}
		for k := 0; k < 4 && k+1 < e.Run && e.Index+1+k < len(words); k++ {
			out[k] = strconv.FormatInt(int64(words[e.Index+1+k]), 10)
		}
		break
	}
	return out
}

// teleColumns are skill CSV columns 87..88 (the rounds 636-640 integration
// review): whether the row carries 'tel2' (+0x2f0) and 'tel3' (+0x2f4), the
// two fields Skill_CheckUseConditions tests beside 'tele' (+0x2ec) when it
// refuses a cast 0x3009 while the caster's book holds a wall (0x58e033..
// 0x58e061, READ). Decided as the markers are: the walk's run, or -- for a
// walk that does not finish -- the literal word anywhere in the row.
//
// MEASURED on the box's Media.pk2 (the 60 plain skilldata shards, 33,709
// ids): 'tel2' on 7 rows (SKILL_EU_WIZARD_PSYCHICA_TELEPORT_A_01..03 and
// _B_01..02, SKILL_EU_WARLOCK_PSYCHICA_TELEPORT_A_01,
// SKILL_EU_BARD_PSYCHICA_TELEPORT_A_01), 'tel3' on 21
// (SKILL_EU_WARRIOR_FRENZYA_TOUNT_SPRINT_A_01..21), 'tele' on 20; every
// walk finished and the literal words agree. An older export loads both 0.
func teleColumns(cols []string) []string {
	out := []string{"0", "0"}
	words, ok := paramWords(cols)
	if !ok {
		return out
	}
	entries, _, complete := skillparam.Walk(words)
	for i, c := range []skillparam.Code{"tel2", "tel3"} {
		found := false
		for _, e := range entries {
			if e.Code == c {
				found = true
				break
			}
		}
		if !found && !complete && !literalAbsent(cols, []skillparam.Code{c}) {
			found = true
		}
		if found {
			out[i] = "1"
		}
	}
	return out
}

// offensiveCodes is FUN_00589d20 (READ, round 636): with no 'abnb' (+0x41c)
// it answers 1 when the row carries any of these fields -- the offsets its
// test reads, each named through skillparam.Field. The recast rule's 'efr'
// kind-2 branch (0x59d978, 0x59d9b3) runs only for rows it answers 0.
var offensiveCodes = []skillparam.Code{
	"att", "fz", "fb", "es", "bu", "ps", "zb", // 0x230, 0x30c..0x320
	"se", "rt", "sl", "fe", "my", "bl", "dn", "st", "ds", "ca", // 0x430..0x458 (not 0x448)
	"cssr", "csit", "cspd", "csmd", "cshp", "csmp", // 0x45c..0x470
	"lfst", "tb", "ck", "pdmg", "pdm2", "tant", "tnt2", "dttp", // 0x400 0x474 0x248 0x234 0x238 0x3c8 0x3cc 0x424
	"terd", "hitm", "trap", "hntp", "thrd", // 0x2dc 0x2c8 0x4a0 0x48c 0x2e0
}

func offensive(present map[skillparam.Code]bool) bool {
	if present["abnb"] {
		return false
	}
	for _, c := range offensiveCodes {
		if present[c] {
			return true
		}
	}
	return false
}

// cooldownGroup is the skill's cooldown group as the CooldownGroup column:
// the high byte of Action_Overlap (skOverlap, the u32 at CRefSkill+0x8c), the
// byte SkillCooldowns::IsReady (0x64c1a0) reads at +0x8f and the arm
// FUN_0064c700 files the re-use timer under. The column is read as an integer
// and shifted right 24 bits -- the little-endian u32's top byte. An empty or
// unreadable column answers "0", no group, which is also what an export
// predating the column loads.
func cooldownGroup(cols []string) string {
	if skOverlap >= len(cols) {
		return "0"
	}
	v, err := strconv.ParseInt(strings.TrimSpace(cols[skOverlap]), 10, 64)
	if err != nil {
		return "0"
	}
	return strconv.FormatUint(uint64(uint32(v)>>24), 10)
}

// sitGate is the SitGate column: which of the skill-use gate's two
// motion-state refusals (Skill_CheckUseConditions, answering 0x3009) apply to
// the skill, as a bit mask (round 607, docs/protocol/opcodes/motion.md):
//
//	1  the skill carries 'ao' (field 0x274) or 'pw' (0x2b4): a PC may not
//	   cast it in SIT, CHANGEMOTION, KNOCKDOWN, SKILL_ACTIONOFF or
//	   SKILL_PROTECTIONWALL (0x58e0ad..0x58e0ed)
//	2  the skill carries 'msch' (0x4a4) with value[0] == 1: refused in SIT
//	   (0x58de46..0x58ded4)
//
// A skill with neither is not refused for its caster's motion state at all.
// A walk that does not finish decides a code absent only when its literal word
// appears nowhere in the row; otherwise the bit is set (the refusal is kept).
func sitGate(cols []string) string {
	words, ok := paramWords(cols)
	if !ok {
		return "0"
	}
	entries, _, complete := skillparam.Walk(words)
	gate := 0
	seen := map[skillparam.Code]bool{}
	for _, e := range entries {
		seen[e.Code] = true
		switch e.Code {
		case "ao", "pw":
			gate |= 1
		case "msch":
			if e.Index+1 < len(words) && words[e.Index+1] == 1 {
				gate |= 2
			}
		}
	}
	if !complete {
		if !seen["ao"] && !seen["pw"] && !literalAbsent(cols, []skillparam.Code{"ao", "pw"}) {
			gate |= 1
		}
		if !seen["msch"] && !literalAbsent(cols, []skillparam.Code{"msch"}) {
			gate |= 2
		}
	}
	return strconv.Itoa(gate)
}

// selfHeal is the (HP, MP) a skill restores to its own caster, as the
// SelfHealHP/SelfHealMP columns: skillparam.SelfHealAmounts over the row's
// action kind (skActionKind), Target_Required (skTargetRequired) and Param
// block. Anything it cannot read answers ("0", "0"), which is also what an
// export predating the columns loads -- no heal, the behaviour srrevamp had.
func selfHeal(cols []string) (hp, mp string) {
	words, ok := paramWords(cols)
	if !ok {
		return "0", "0"
	}
	kind, err := strconv.ParseInt(strings.TrimSpace(cols[skActionKind]), 10, 32)
	if err != nil {
		return "0", "0"
	}
	tr, err := strconv.Atoi(strings.TrimSpace(cols[skTargetRequired]))
	if err != nil {
		return "0", "0"
	}
	h, m := skillparam.SelfHealAmounts(int32(kind), tr != 0, words)
	return strconv.Itoa(h), strconv.Itoa(m)
}

// attackCode is the skill parameter tagged 'att', the one that carries a
// skill's damage. Skill parameters live in the row's Param block as
// (code, values...) runs, where a code is a C multi-character literal stored
// as a big-endian integer -- 'att' is 0x00617474 = 6386804. The server's own
// parameter parser reads 'att' as a fixed run of six words (the code plus five
// values), which is how the layout below is known rather than guessed.
const attackCode = "6386804"

// reqItemCode is the skill parameter tagged 'reqi'. Its handler appends into a
// FIVE-SLOT LIST at CRefSkill+0x3a0 (`mov [esi+edx*4+0x3a0],eax` at 00588f79,
// with the slot chosen by scanning for the first zero and capped at 5), and
// that list is what the weapon gate branches on:
//
//	if (skill[0x3a0] == 0) { ...check ReqCastWeapon... }
//	else                   { ...a different check entirely... }
//
// So a skill carrying 'reqi' does NOT have its ReqCastWeapon bytes applied.
// 1,094 real skills carry it, 517 of them alongside a weapon requirement that
// the engine therefore ignores. Let Python compute the constant -- hand-typing
// these has been wrong twice in this project.
const reqItemCode = "1919250793" // 0x72657169

// reqAllCode is the skill parameter tagged 'reqn' (0x7265716e, one `sub edi,5`
// past 'reqi' in the parser's dispatch chain). Its presence sets CRefSkill+0x3b4,
// and FUN_0058d480 reads that field to turn the requirement list from ANY-of
// into ALL-of. 128 real skills carry it against 966 that do not.
const reqAllCode = "1919250798" // 0x7265716e

// hitCountCode is the skill's 'mc' parameter -- 0x6d63, the pair (2, N) where N
// is how many times one cast strikes. See refdata.Skill.HitCount for the
// use-site that settles it as a count rather than a multiplier.
const hitCountCode = "28003"

// paramRuns walks a skilldata row's Param block the way the server's own parser
// does, using the recovered run lengths in internal/skillparam.
//
// WHY THIS EXISTS ALONGSIDE THE SCANS BELOW. Each of those finds a parameter by
// searching the whole row for its code literal, which is a heuristic: nothing
// stops the same integer occurring as some other column's value. The walk has
// no such failure mode -- it starts where the block starts and steps run by run
// -- so it is the primary, and a scan is used only where the walk cannot
// finish.
//
// The two agree today. Walking all 33,632 rows of the seven skilldata shards in
// a real Media.pk2, 32,367 (96.2%) walk end to end and the scans' answers for
// 'att', 'mc' and 'reqi' match the walk's on every one of them -- zero
// disagreements. So this change is not a fix; it replaces an argument that the
// scan is safe with a method that does not need the argument.
//
// The other 1,265 rows stop at a variable-length parameter, whose run length
// the parser genuinely does not state, so the walk cannot pass it. Those fall
// back to the scan, which is what they used before.
func paramRuns(cols []string) (runs []skillparam.Entry, complete bool) {
	if len(cols) <= skillparam.ParamBlockColumn {
		return nil, false
	}
	words := make([]int32, 0, len(cols)-skillparam.ParamBlockColumn)
	for _, v := range cols[skillparam.ParamBlockColumn:] {
		s := strings.TrimSpace(v)
		if s == "" {
			continue
		}
		n, err := strconv.ParseInt(s, 10, 32)
		if err != nil {
			return nil, false
		}
		words = append(words, int32(n))
	}
	runs, _, complete = skillparam.Walk(words)
	return runs, complete
}

// paramWords is a row's Param block as the 32-bit words the parser walks.
func paramWords(cols []string) ([]int32, bool) {
	if len(cols) <= skillparam.ParamBlockColumn {
		return nil, false
	}
	words := make([]int32, 0, len(cols)-skillparam.ParamBlockColumn)
	for _, v := range cols[skillparam.ParamBlockColumn:] {
		s := strings.TrimSpace(v)
		if s == "" {
			continue
		}
		n, err := strconv.ParseInt(s, 10, 32)
		if err != nil {
			return nil, false
		}
		words = append(words, int32(n))
	}
	return words, true
}

// paramFind returns the ROW COLUMN of the first run carrying code.
//
// decided says whether the answer can be trusted on its own. A completed walk
// decides both ways: it either found the run or proved the row has not got one.
// An incomplete walk decides nothing, because the code may sit past where the
// walk stopped, and the caller must fall back rather than read "not found" as
// "the skill has not got it".
func paramFind(cols []string, code skillparam.Code) (col int, found, decided bool) {
	runs, complete := paramRuns(cols)
	for _, r := range runs {
		if r.Code == code {
			return skillparam.ParamBlockColumn + r.Index, true, true
		}
	}
	return 0, false, complete
}

// paramFindAll returns the row columns of every run carrying code, for the
// parameters the engine keeps a list of. Same decided contract as paramFind.
func paramFindAll(cols []string, code skillparam.Code) (out []int, decided bool) {
	runs, complete := paramRuns(cols)
	if !complete {
		return nil, false
	}
	for _, r := range runs {
		if r.Code == code {
			out = append(out, skillparam.ParamBlockColumn+r.Index)
		}
	}
	return out, true
}

// attackParam pulls a skill's damage out of its Param block: the percentage of
// weapon damage it deals, and the flat damage range added on top.
//
// The five values after the code are (type, percent, min, max, percent again).
// Read across a skill's levels the meaning is plain: for SKILL_CH_SWORD_SMASH_A
// levels 1-5 the percent stays 143 while min/max climb 15-18, 18-22, 21-26,
// 25-30, 29-35. A plain swing (SKILL_CH_SWORD_BASE_01) is 60 percent and no
// flat damage at all, which is exactly what a basic attack should be.
//
// Returns "0","0","0" for a skill with no 'att' -- most skills are buffs,
// heals or passives and have no attack parameter.
//
// SCANNING THE WHOLE ROW rather than walking the Param block is safe, and that
// is now measured rather than hoped. The risk is obvious -- 6386804 could occur
// as some other parameter's VALUE and be read as a code -- so it was tested
// against the parser's own schema (docs/protocol/skill_params.md, the 102 codes
// recovered from SkillGlobal::RefSkill_ParseParams):
//
//   - The Param block starts at column 69. Across every real skill row, the
//     lowest column the literal ever appears at is 69, so nothing precedes the
//     block: 0 rows carry it earlier.
//   - No row carries it twice, so "first match" cannot pick the wrong one.
//
// RE-VALIDATED 2026-09-16 on the COMPLETE table. The figures above were
// measured over 31,605 rows, which turned out to be a partial extraction --
// only some skilldata shards were on disk at the time. Pulling all seven from
// Media.pk2 gives **33,632 rows**, of which 30,064 carry 'att', and both claims
// still hold exactly: 0 rows carry it before column 69, 0 rows carry it twice,
// and the lowest column it ever appears at is 69. The first-match scan is safe
// on the whole table, not just the part that happened to be extracted.
//   - On the rows whose Param block walks cleanly end to end under the
//     recovered run lengths, the walk's 'att' position and this scan's first
//     match agree and never differ.
//
// RE-VALIDATED AGAIN 2026-09-16, against a COMPLETE vocabulary. The check above
// ran against a 104-code table under which 15,625 rows stopped at a code nobody
// had recovered -- so "they agree on the rows that walk" was quietly conditioned
// on the rows that happened to walk. The vocabulary is now 148 codes and **no
// row in the table hits an unrecognised code** (docs/protocol/skill_params.md).
// Re-run on that footing:
//
//   - 19,990 rows walk end to end; the walk's 'att' position and this scan's
//     first match agree on 18,727 of them and differ on 0.
//   - The 'att' literal 6386804 appears as some other code's VALUE exactly
//     **0 times** across every walked run. That is the scan's actual failure
//     mode, and it is now measured directly rather than argued from the
//     schema.
//
// The scan is also the more version-robust of the two: a client whose skilldata
// shifts the block would break a hard-coded column 69, and this would not.
// attackType is value[0], the damage-TYPE mask -- exported since 2026-09-16
// because the engine gates each half of a blow on it. Bit 4 enables the
// physical half, bit 8 the magical one; bits 1 and 2 are a second axis
// selecting which flat-absorption param applies. See combat.AttackType and
// docs/protocol/skill_params.md.
func attackParam(cols []string) (attackType, percent, dmgMin, dmgMax string) {
	at := func(i, off int) string {
		if i+off >= len(cols) {
			return "0"
		}
		s := strings.TrimSpace(cols[i+off])
		if s == "" {
			return "0"
		}
		return s
	}
	i, found := attackRun(cols)
	if !found {
		return "0", "0", "0", "0"
	}
	// i+1 is the type; the damage is in the three that follow.
	return at(i, 1), at(i, 2), at(i, 3), at(i, 4)
}

// attackRun returns the row column of the skill's 'att' code word. The walk is
// authoritative when it finishes (see paramRuns); otherwise the whole-row scan
// the comment above measures.
func attackRun(cols []string) (col int, found bool) {
	if i, found, decided := paramFind(cols, "att"); decided {
		return i, found
	}
	for i, v := range cols {
		if strings.TrimSpace(v) == attackCode {
			return i, true
		}
	}
	return 0, false
}

// literalAbsent reports that NONE of the codes' stored words appears anywhere in
// the row. It is the one inference about a Param block that needs no walk: a
// parameter whose code word is nowhere in the row cannot be in the block. Only
// absence is proof -- presence is not, since the same integer could be some
// other column's value -- so this is used to decide rows the walk cannot
// finish, and only ever in the direction that is sound.
func literalAbsent(cols []string, codes []skillparam.Code) bool {
	present := make(map[string]bool, len(cols))
	for _, v := range cols {
		present[strings.TrimSpace(v)] = true
	}
	for _, c := range codes {
		if present[strconv.Itoa(int(skillparam.WordOf(c)))] {
			return false
		}
	}
	return true
}

// reqItemCount counts the skill's 'reqi' runs, i.e. how many entries it puts in
// the list at CRefSkill+0x3a0. The engine caps the list at 5.
//
// Only whether it is ZERO matters to the weapon gate, but the count is exported
// rather than a boolean because what the list HOLDS is not recovered yet, and a
// count is the more useful thing to already have when it is.
func reqItemCount(cols []string) string {
	n := 0
	if at, decided := paramFindAll(cols, "reqi"); decided {
		n = len(at)
	} else {
		for _, v := range cols {
			if strings.TrimSpace(v) == reqItemCode {
				n++
			}
		}
	}
	if n > 5 {
		n = 5 // the engine's own cap: `cmp edx,0x5 / je` ends the slot scan
	}
	return strconv.Itoa(n)
}

// reqItemList packs the skill's 'reqi' records as `kind:value;kind:value`.
// The run is three words -- the code plus (kind, value) -- and the engine stores
// a pointer to the pair, reading *p as the kind and p[1] as the value.
func reqItemList(cols []string) string {
	var out []string
	add := func(i int) bool {
		if i+2 >= len(cols) {
			return false
		}
		kind := strings.TrimSpace(cols[i+1])
		val := strings.TrimSpace(cols[i+2])
		if kind == "" || val == "" {
			return false
		}
		out = append(out, kind+":"+val)
		return len(out) == 5 // the engine's own cap on the list
	}
	if at, decided := paramFindAll(cols, "reqi"); decided {
		for _, i := range at {
			if add(i) {
				break
			}
		}
		return strings.Join(out, ";")
	}
	for i, v := range cols {
		if strings.TrimSpace(v) != reqItemCode {
			continue
		}
		if add(i) {
			break
		}
	}
	return strings.Join(out, ";")
}

// floorBlow reports, as "1" or "0", that every blow this skill lands is exactly
// the engine's floor of 1: `local_d0` is 0, so the blow IS computed, but the
// computation is identically zero and Combat_ResolveDamage floors it. See
// skillparam.BlowIsFloor for the three ways that happens and their citations.
//
// 446 real rows: 440 carrying 'att' with a percent of 0 (420 of them the mall
// pets' elemental skills), 5 carrying a percent but neither damage bit, and the
// single row in the table that carries 'ck' alone. Before this column every one
// of them dealt a full weapon blow plus DisclosedSkillDamagePerLevel * level.
//
// A row that is zero-damage is not a floor blow, and a row where neither
// parameter was found but absence could not be proved answers "0".
func floorBlow(cols []string) string {
	if zeroDamage(cols) == "1" {
		return "0"
	}
	num := func(i int) int32 {
		if i >= len(cols) {
			return 0
		}
		n, err := strconv.ParseInt(strings.TrimSpace(cols[i]), 10, 32)
		if err != nil {
			return 0
		}
		return int32(n)
	}
	i, hasAtt := attackRun(cols)
	var attType, attPercent int32
	if hasAtt {
		attType, attPercent = num(i+1), num(i+2)
	}
	_, carriesCk, _ := paramFind(cols, "ck")
	if !hasAtt && !carriesCk {
		return "0"
	}
	if skillparam.BlowIsFloor(hasAtt, attType, attPercent, carriesCk) {
		return "1"
	}
	return "0"
}

// zeroDamage reports, as "1" or "0", that Combat_ResolveDamage's `local_d0`
// would be 1 for this skill -- it carries neither 'att' nor 'ck', so the
// ordinary damage kind writes zero to both halves of the blow and their sum is
// the total. See skillparam.DamageParameters.
//
// This is WIDER than noCombatParam and contains it: 2,482 real rows carry
// neither, of which 1,813 also carry none of the 33 and return earlier still.
// Both columns are exported because the distinction is real -- no blow at all
// versus a blow of zero -- even though srrevamp models both as no damage today.
//
// Positive sense is safe here for the same reason the other column's negative
// sense is: an export predating this one loads false, which means "this skill's
// damage is computed", the behaviour every older export already had.
func zeroDamage(cols []string) string {
	words, ok := paramWords(cols)
	if !ok {
		return "0"
	}
	zero, decided := skillparam.DealsZeroDamage(words)
	if decided {
		if zero {
			return "1"
		}
		return "0"
	}
	// The walk stopped at a variable-length code and proved nothing -- but if
	// neither 'att' nor 'ck' appears ANYWHERE in the row, the block cannot
	// carry them. That is proof, not a heuristic, and it decides 1,085 of the
	// 1,265 real rows the walk cannot finish. (The other 180 all carry the
	// 'att' literal, so with this the three classes -- 'att', 'ck' alone,
	// neither -- partition all 33,632 rows with nothing left over.)
	if literalAbsent(cols, skillparam.DamageParameters) {
		return "1"
	}
	return "0"
}

// noCombatParam reports, as "1" or "0", that Combat_ResolveDamage would return
// WITHOUT RESOLVING A BLOW for this skill: it carries none of the 33 parameters
// that function tests, and no 'efr' whose second value is 6. See
// skillparam.CombatParameters for the list and the citation.
//
// THE COLUMN IS NEGATIVE ON PURPOSE. Skill CSV columns are a strict suffix: an
// export made before a column existed loads with the Go zero value. False here
// means "this skill does resolve a blow", which is what every older export
// already assumed, so an old export keeps its current behaviour instead of
// silently muting a third of the table.
//
// UNDECIDABLE ROWS ANSWER "0". A row whose Param block stops at a
// variable-length code hides whatever follows, so nothing can be concluded
// about it -- 1,265 of 33,632 real rows are like this. They answer "0", the
// conservative direction: the skill keeps the damage it has today rather than
// being silenced on evidence that does not exist.
func noCombatParam(cols []string) string {
	words, ok := paramWords(cols)
	if !ok {
		return "0"
	}
	carries, decided := skillparam.CarriesCombatParameter(words)
	if decided {
		if !carries {
			return "1"
		}
		return "0"
	}
	// Same sound inference as zeroDamage: a row in which none of the 33 code
	// words appears anywhere cannot carry any of them. 872 of the 1,265 rows
	// the walk cannot finish are decided this way. 'efr' is in the list, so a
	// row passing this has no 'efr' to qualify either.
	if literalAbsent(cols, skillparam.CombatParameters) {
		return "1"
	}
	return "0"
}

// reqAll reports whether the skill carries 'reqn', as "1" or "0".
func reqAll(cols []string) string {
	for _, v := range cols {
		if strings.TrimSpace(v) == reqAllCode {
			return "1"
		}
	}
	return "0"
}

// hitCountParam pulls a skill's hit count out of its Param block. The run is
// (code, 2, N); the leading 2 is a selector the server tests before taking N,
// so a run that does not carry it is not a hit count and is ignored.
//
// Returns "0" when the skill has no 'mc', which refdata.Skill.HitsFor reads as
// a single strike -- the engine's own default.
func hitCountParam(cols []string) string {
	take := func(i int) (string, bool) {
		if i+2 >= len(cols) || strings.TrimSpace(cols[i+1]) != "2" {
			return "", false
		}
		n := strings.TrimSpace(cols[i+2])
		if n == "" {
			return "0", true
		}
		return n, true
	}
	if i, found, decided := paramFind(cols, "mc"); decided {
		if !found {
			return "0"
		}
		if n, ok := take(i); ok {
			return n
		}
		return "0"
	}
	for i, v := range cols {
		if strings.TrimSpace(v) != hitCountCode {
			continue
		}
		if n, ok := take(i); ok {
			return n
		}
	}
	return "0"
}

// readTable reads a tab-separated itemdata file, decoding UTF-16LE (with or
// without a BOM) or UTF-8, and returns each non-empty, non-comment line
// split on tabs.
func readTable(path string) ([][]string, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	text := decode(raw)
	var out [][]string
	sc := bufio.NewScanner(strings.NewReader(text))
	sc.Buffer(make([]byte, 0, 1<<20), 1<<24)
	for sc.Scan() {
		line := strings.TrimRight(sc.Text(), "\r")
		if line == "" || strings.HasPrefix(line, "//") {
			continue
		}
		out = append(out, strings.Split(line, "\t"))
	}
	return out, sc.Err()
}

// decode turns raw bytes into a string, honouring a UTF-16LE BOM (the form
// the Media text tables use) and falling back to UTF-8.
func decode(raw []byte) string {
	if len(raw) >= 2 && raw[0] == 0xFF && raw[1] == 0xFE {
		u16 := make([]uint16, 0, (len(raw)-2)/2)
		for i := 2; i+1 < len(raw); i += 2 {
			u16 = append(u16, uint16(raw[i])|uint16(raw[i+1])<<8)
		}
		return string(utf16.Decode(u16))
	}
	return string(raw)
}

// exportNpcPos writes the client's npcpos.txt (5 tab-separated columns:
// object id, region id, local x, y, z -- 12,367 rows in a retail archive,
// 12,110 of them monsters) as the CSV cmd/server's -npcpos-csv reads. Unlike
// the item and skill tables a row is not unique by id, so nothing is
// de-duplicated: a species with 55 placements gets 55 rows.
func exportNpcPos(out string) {
	var sink *os.File
	if out == "-" {
		sink = os.Stdout
	} else {
		f, err := os.Create(out)
		if err != nil {
			fmt.Fprintf(os.Stderr, "creating %s: %v\n", out, err)
			os.Exit(1)
		}
		defer f.Close()
		sink = f
	}
	w := csv.NewWriter(sink)
	defer w.Flush()
	if err := w.Write(spawn.NpcPosCSVColumns); err != nil {
		fmt.Fprintf(os.Stderr, "writing: %v\n", err)
		os.Exit(1)
	}
	written, skipped := 0, 0
	for _, path := range flag.Args() {
		rows, err := readTable(path)
		if err != nil {
			fmt.Fprintf(os.Stderr, "reading %s: %v\n", path, err)
			os.Exit(1)
		}
		for _, cols := range rows {
			if len(cols) < 5 {
				skipped++
				continue
			}
			id := strings.TrimSpace(cols[0])
			if _, err := strconv.Atoi(id); err != nil {
				skipped++
				continue
			}
			rec := []string{id, strings.TrimSpace(cols[1]), strings.TrimSpace(cols[2]), strings.TrimSpace(cols[3]), strings.TrimSpace(cols[4])}
			if err := w.Write(rec); err != nil {
				fmt.Fprintf(os.Stderr, "writing: %v\n", err)
				os.Exit(1)
			}
			written++
		}
	}
	w.Flush()
	fmt.Fprintf(os.Stderr, "export-refdata: wrote %d npcpos rows, skipped %d\n", written, skipped)
}

// The teleport tables' columns, 0-indexed like every table here: column 0 is
// the Service flag, which the client's loader reads (skipping a 0) before
// handing the row to its parser -- at 0x954b1a before
// GlobalDataManager::RefParse_teleportdata (called at 0x954b61), at 0x954b9d
// before RefParse_teleportlink (called at 0x954be4); the reader, FUN_00b9cc80,
// returns the column's integer and the loader parses the row only when it is
// non-zero. exportTeleport skips those rows the same way (all 222 teleportdata
// and 292 teleportlink retail rows have service 1, so nothing is skipped
// today). teleportbuilding.txt is loaded elsewhere (its path is formatted in
// the client's Client_LoadAllRefData, 0x844cd0) and its service handling is
// not read, so its column 0 is not filtered. Every column was checked against
// the retail rows on the render box (round 575,
// docs/protocol/teleport_network.md "The columns srrevamp reads").
const (
	// teleportdata.txt, 14 fields: GlobalDataManager::RefParse_teleportdata
	// (client 0x976840) reads id, codename, associated object, zone name,
	// region, x, y, z, radius, then two tokens it throws away -- the two flags
	// the server's RefTeleport_ExtractData (0x6a7be0) registers as NPC
	// interaction ids 7 and 9 (round 454, which numbered them 9/10 as if the
	// server's copy had no zone name). Whether it lacks that column or skips
	// it is not settled -- RefTeleport_ExtractData calls the column-skip helper
	// FUN_006b1a80 right after the associated-object dword -- and it does not
	// matter here: the server's two bytes follow its five words (region ..
	// radius), so they are the two tokens after radius, columns 10/11.
	tpID           = 1
	tpCode         = 2
	tpObject       = 3
	tpZoneName     = 4
	tpRegion       = 5
	tpX            = 6
	tpY            = 7
	tpZ            = 8
	tpRadius       = 9
	tpInteraction7 = 10
	tpInteraction9 = 11

	// teleportlink.txt, 23 fields: source, destination, the fee (the word the
	// server compares to gold, 0x513590, and the client's dialog shows,
	// UI_TELEPORT::FUN_006fd3e0), three columns 0 in every retail row, then
	// five (type, data, data) triples from column 7. The triples' position is
	// settled by the data, not by the client's parser (which reads one fewer
	// leading token -- teleport_network.md). Counted over the 292 retail rows
	// (read-only, the render box's /var/tmp/tables, round 575): from column 7
	// the types are 0 (1,125 slots of 1,460), 1, 2, 4, 5, 6 and 7, and every
	// type-0 slot carries blank or zero data words (3 blank, all on link
	// 1 -> 5, and 1,122 zero); from column 6 they would include 999 (69), 110
	// (14), 102 and two blanks, and every row's first type would be the
	// always-0 column 6. And the one type-4 slot names 23973,
	// ITEM_QNO_RM_MEETROC_6_01, where the evaluator's type-4 arm looks an item
	// up by that word and refuses with UIIT_MSG_QUEST_ROC_CANNOT_ENTRANCE.
	tlFrom  = 1
	tlTo    = 2
	tlFee   = 3
	tlRules = 7 // 7..21: five triples

	// teleportbuilding.txt, 59 fields in the _RefObjCommon prefix's layout
	// (refobj_binary_format.md): id, codename, the name string id (SN_NPC_*)
	// at 5, RegionID at 41, OffsetX/Y/Z at 43..45 (42 is Dir). Column 55 is the
	// FORTRESS_* code, read from the values only.
	tbID       = 1
	tbCode     = 2
	tbName     = 5
	tbRegion   = 41
	tbX        = 43
	tbY        = 44
	tbZ        = 45
	tbFortress = 55
)

// exportTeleport writes teleportdata.csv, teleportlink.csv and
// teleportbuilding.csv into outDir from the three client tables named on the
// command line (by file name, in any order). A row with fewer fields than the
// columns read need is an ERROR, not a skip: the export stops and names the
// file and row, because a truncated or mis-split table would otherwise lose
// gates or links without a word (every retail row has the table's full width
// -- 14, 23 and 59 fields -- and readTable already drops the blank lines and
// the trailing //Copyright comment). Rows whose id is not a number are
// skipped and counted, and so are teleportdata and teleportlink rows whose
// service column is 0, which the client never parses (above). The CSVs keep
// the tables' own values; checking them
// (headers, joins, numbers) is internal/teleport.Read's job, so a table this
// writes and the server cannot load fails at export time, not at boot: the
// output is loaded back before this returns.
func exportTeleport(outDir string, paths []string) error {
	if outDir == "-" || outDir == "" {
		return fmt.Errorf("-mode teleport writes three files: -out must name a directory")
	}
	inputs := map[string]string{}
	for _, p := range paths {
		inputs[strings.ToLower(filepath.Base(p))] = p
	}
	type table struct {
		in, out string
		header  []string
		width   int  // fields a row must have to carry every column read
		service bool // skip a row whose column 0 is 0, as the client's loader does (above)
		record  func([]string) []string
	}
	tables := []table{
		{"teleportdata.txt", teleport.PointsFile, teleport.PointCSVColumns, tpInteraction9 + 1, true, func(c []string) []string {
			return []string{c[tpID], c[tpCode], c[tpObject], c[tpZoneName], c[tpRegion],
				c[tpX], c[tpY], c[tpZ], c[tpRadius], c[tpInteraction7], c[tpInteraction9]}
		}},
		{"teleportlink.txt", teleport.LinksFile, teleport.LinkCSVColumns, tlRules + 15, true, func(c []string) []string {
			rec := []string{c[tlFrom], c[tlTo], c[tlFee]}
			return append(rec, c[tlRules:tlRules+15]...)
		}},
		{"teleportbuilding.txt", teleport.BuildingsFile, teleport.BuildingCSVColumns, tbFortress + 1, false, func(c []string) []string {
			return []string{c[tbID], c[tbCode], c[tbName], c[tbRegion], c[tbX], c[tbY], c[tbZ], c[tbFortress]}
		}},
	}
	for _, tb := range tables {
		if _, ok := inputs[tb.in]; !ok {
			return fmt.Errorf("-mode teleport needs %s among the inputs", tb.in)
		}
	}
	// Every table is read and its rows' widths checked before anything is
	// written, so a short row leaves no half-written directory behind.
	tableRows := make([][][]string, len(tables))
	for ti, tb := range tables {
		rows, err := readTable(inputs[tb.in])
		if err != nil {
			return fmt.Errorf("reading %s: %w", inputs[tb.in], err)
		}
		for i, cols := range rows {
			if len(cols) < tb.width {
				return fmt.Errorf("%s: row %d (not counting blank and // lines) has %d fields, fewer than the %d the export reads: %.60q",
					inputs[tb.in], i+1, len(cols), tb.width, strings.Join(cols, "\t"))
			}
		}
		tableRows[ti] = rows
	}
	if err := os.MkdirAll(outDir, 0o755); err != nil {
		return err
	}
	for ti, tb := range tables {
		f, err := os.Create(filepath.Join(outDir, tb.out))
		if err != nil {
			return err
		}
		w := csv.NewWriter(f)
		if err := w.Write(tb.header); err != nil {
			f.Close()
			return err
		}
		written, skipped, unserviced := 0, 0, 0
		for _, cols := range tableRows[ti] {
			for i := range cols {
				cols[i] = strings.TrimSpace(cols[i])
			}
			if n, err := strconv.Atoi(cols[0]); tb.service && err == nil && n == 0 {
				unserviced++
				continue
			}
			if _, err := strconv.Atoi(cols[1]); err != nil {
				skipped++
				continue
			}
			if err := w.Write(tb.record(cols)); err != nil {
				f.Close()
				return err
			}
			written++
		}
		w.Flush()
		if err := w.Error(); err != nil {
			f.Close()
			return err
		}
		if err := f.Close(); err != nil {
			return err
		}
		fmt.Fprintf(os.Stderr, "export-refdata: wrote %d %s rows, skipped %d, %d with service 0\n", written, tb.out, skipped, unserviced)
	}
	t, err := teleport.Load(outDir)
	if err != nil {
		return fmt.Errorf("the exported tables do not load: %w", err)
	}
	fmt.Fprintf(os.Stderr, "export-refdata: teleport network loads back: %d points, %d links, %d buildings\n",
		len(t.Points), len(t.Links), len(t.Buildings))
	return nil
}
