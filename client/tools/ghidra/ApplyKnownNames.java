// Write this project's proven findings back into the binary as names.
//
// Everything below was established by reading the code and checking it against
// real data -- not guessed from shape. Each entry carries the evidence that
// settled it, and that evidence is written into the function's plate comment,
// so a later reader can audit the name instead of trusting it. Where behaviour
// is established but the original identifier is unknown, the name says what the
// function DOES rather than inventing what Joymax might have called it.
//
// This exists because findings that live only in commit messages are lost to
// the next session. A name in the program survives, and shows up in every
// future decompilation dump at every call site.
//
// Usage: -postScript ApplyKnownNames.java [apply]   (writable run for apply)
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.symbol.SourceType;

public class ApplyKnownNames extends GhidraScript {

    // address, name, evidence
    private static final String[][] KNOWN = {
        {"006a3090", "RefObjCommon_ExtractData",
         "Parses the shared prefix of a refdata row; called first by RefObjChar's own parser."},
        {"006a58f0", "RefObjChar_ExtractData",
         "Names itself in its assert string. Deserialises a characterdata row field-by-field: "
         + "uint8 Lvl at +0x198, uint8 CharGender +0x199, uint32 MaxHP +0x19c (the field it "
         + "asserts m_dwMaxHP > 0 on), uint32 MaxMP +0x1a0. Column map anchored by that plus "
         + "+0x25c defaulting to 0xbb8 = 3000 = col 82."},
        {"00411130", "RefLevel_GetEntry",
         "Level-table lookup: indexes array[level-1], so it is 1-based by level."},
        {"00587630", "RefSkill_ParseParams",
         "Walks a skill's Param stream as (code, values...) runs, code being a C multi-char "
         + "literal stored big-endian, and stores each value pointer into a field of the skill "
         + "struct. Gives each code its run length: 'att' (0x00617474) is six words."},
        {"0040f5f0", "Formula_SkillPhysDamage",
         "Skill physical damage. Combat resolution calls it when the skill carries 'pdmg' "
         + "(skill+0x234). Takes the base, adds a bonus, and when the attacker out-levels the "
         + "target rolls and clamps to [10%, 100%] of base."},
        {"0058e5f0", "Combat_ResolveDamage",
         "The damage resolution. Reads the skill's damage params (skill+0x234 'pdmg', +0x238) "
         + "and accumulates the result into the damage total."},
        {"004b3510", "ParamKeeper_SetParam",
         "Derived-stat hub: (slotIndex, ctx, floatValue). Forwards to the slot store and sets "
         + "the recalc dirty flag at +0x810. First arg is the SLOT, not the param id -- slot 3 "
         + "is the percent scale, which is what made the level curve look like an absolute."},
        {"004b3000", "ParamKeeper_StoreSlot",
         "Stores a value into a param's slot array at this+8+slot*4."},
        {"004b3210", "ParamKeeper_EvaluateParam",
         "Combines a param's four slots: base * (1 + pct/100) * mult * (scale/100). Slot 3's "
         + "default is 100.0, i.e. 100%."},
        {"004b3780", "ParamKeeper_Flush",
         "Consumes the recalc dirty flag at +0x810 and re-evaluates every param entry."},
        {"004b3850", "ParamKeeper_EnsureParam",
         "Lazily creates the param object for an id: this+4+id*4, and if null builds one and links "
         + "it into the keeper's list at this+0x808. The id arrives in DI, NOT on the stack -- "
         + "which is why every SetParam call site decompiled without it. There is no id->name "
         + "table anywhere in the binary; the enum was compile-time only, so each id has to be "
         + "earned from its use sites."},
        {"004b3540", "ParamKeeper_BindDerived",
         "Builds one edge of the derived-stat graph: EnsureParam(EBX), EnsureParam(EDI), then "
         + "registers paramObj[EDI] + slot as a dependent of paramObj[EBX]. Takes TWO ids in "
         + "registers (EBX source, EDI target) and only the slot on the stack. Direction proven "
         + "by FUN_004b3130, which on a write walks the owner's list and calls StoreSlot on each "
         + "registered target -- and independently by Level/Str/Int only ever appearing as EBX."},
        {"004b3060", "Param_AddDependent",
         "Inserts (targetParam, slot) into this param's dependent list at this+0x30."},
        {"004b3130", "Param_PropagateToDependents",
         "Called by StoreSlot after a value changes: walks the dependent list and pushes the new "
         + "value into each target's registered slot. This is what makes the graph evaluate."},
        // --- Packet handlers, from the message dispatcher's opcode tree. ---
        // FUN_00414260 reads a uint16 opcode out of the message buffer at
        // +0x1050 and branches to a handler per opcode. These are the
        // inter-server / gateway families (0x3xxx requests, 0xBxxx responses,
        // some 0x7xxx); the main client protocol is dispatched elsewhere.
        // Named by their opcode because that is what is PROVEN -- the number,
        // not the meaning. A handler serving several opcodes carries the first
        // two in its name.
        {"004039d0", "MsgHandler_bc10",
         "Packet handler, dispatched on opcode 0xbc10. Recovered from the message dispatcher "
         + "(FUN_00414260 and its family), which reads a uint16 opcode from the message buffer at "
         + "+0x1050 and branches. The opcode is a fact; what the handler DOES is not claimed."},
        {"00403b70", "MsgHandler_34f2",
         "Packet handler, dispatched on opcode 0x34f2. Recovered from the message dispatcher "
         + "(FUN_00414260 and its family), which reads a uint16 opcode from the message buffer at "
         + "+0x1050 and branches. The opcode is a fact; what the handler DOES is not claimed."},
        {"00404e50", "MsgHandler_34ba",
         "Packet handler, dispatched on opcode 0x34ba. Recovered from the message dispatcher "
         + "(FUN_00414260 and its family), which reads a uint16 opcode from the message buffer at "
         + "+0x1050 and branches. The opcode is a fact; what the handler DOES is not claimed."},
        {"00404f80", "MsgHandler_7155",
         "Packet handler, dispatched on opcode 0x7155. Recovered from the message dispatcher "
         + "(FUN_00414260 and its family), which reads a uint16 opcode from the message buffer at "
         + "+0x1050 and branches. The opcode is a fact; what the handler DOES is not claimed."},
        {"00414890", "MsgHandler_b808",
         "Packet handler, dispatched on opcode 0xb808. Recovered from the message dispatcher "
         + "(FUN_00414260 and its family), which reads a uint16 opcode from the message buffer at "
         + "+0x1050 and branches. The opcode is a fact; what the handler DOES is not claimed."},
        {"00415eb0", "MsgHandler_7c00",
         "Packet handler, dispatched on opcode 0x7c00. Recovered from the message dispatcher "
         + "(FUN_00414260 and its family), which reads a uint16 opcode from the message buffer at "
         + "+0x1050 and branches. The opcode is a fact; what the handler DOES is not claimed."},
        {"004169d0", "MsgHandler_3c01",
         "Packet handler, dispatched on opcode 0x3c01. Recovered from the message dispatcher "
         + "(FUN_00414260 and its family), which reads a uint16 opcode from the message buffer at "
         + "+0x1050 and branches. The opcode is a fact; what the handler DOES is not claimed."},
        {"00416d00", "MsgHandler_3122",
         "Packet handler, dispatched on opcode 0x3122. Recovered from the message dispatcher "
         + "(FUN_00414260 and its family), which reads a uint16 opcode from the message buffer at "
         + "+0x1050 and branches. The opcode is a fact; what the handler DOES is not claimed."},
        {"00416db0", "MsgHandler_38e9",
         "Packet handler, dispatched on opcode 0x38e9. Recovered from the message dispatcher "
         + "(FUN_00414260 and its family), which reads a uint16 opcode from the message buffer at "
         + "+0x1050 and branches. The opcode is a fact; what the handler DOES is not claimed."},
        {"004185a0", "MsgHandler_7c85",
         "Packet handler, dispatched on opcode 0x7c85. Recovered from the message dispatcher "
         + "(FUN_00414260 and its family), which reads a uint16 opcode from the message buffer at "
         + "+0x1050 and branches. The opcode is a fact; what the handler DOES is not claimed."},
        {"004186d0", "MsgHandler_b11b",
         "Packet handler, dispatched on opcode 0xb11b. Recovered from the message dispatcher "
         + "(FUN_00414260 and its family), which reads a uint16 opcode from the message buffer at "
         + "+0x1050 and branches. The opcode is a fact; what the handler DOES is not claimed."},
        {"004190c0", "MsgHandler_34bb",
         "Packet handler, dispatched on opcode 0x34bb. Recovered from the message dispatcher "
         + "(FUN_00414260 and its family), which reads a uint16 opcode from the message buffer at "
         + "+0x1050 and branches. The opcode is a fact; what the handler DOES is not claimed."},
        {"00419390", "MsgHandler_3cc3",
         "Packet handler, dispatched on opcode 0x3cc3. Recovered from the message dispatcher "
         + "(FUN_00414260 and its family), which reads a uint16 opcode from the message buffer at "
         + "+0x1050 and branches. The opcode is a fact; what the handler DOES is not claimed."},
        {"00419520", "MsgHandler_bcdc",
         "Packet handler, dispatched on opcode 0xbcdc. Recovered from the message dispatcher "
         + "(FUN_00414260 and its family), which reads a uint16 opcode from the message buffer at "
         + "+0x1050 and branches. The opcode is a fact; what the handler DOES is not claimed."},
        {"00419900", "MsgHandler_3cde",
         "Packet handler, dispatched on opcode 0x3cde. Recovered from the message dispatcher "
         + "(FUN_00414260 and its family), which reads a uint16 opcode from the message buffer at "
         + "+0x1050 and branches. The opcode is a fact; what the handler DOES is not claimed."},
        {"0041a9c0", "MsgHandler_bce6",
         "Packet handler, dispatched on opcode 0xbce6. Recovered from the message dispatcher "
         + "(FUN_00414260 and its family), which reads a uint16 opcode from the message buffer at "
         + "+0x1050 and branches. The opcode is a fact; what the handler DOES is not claimed."},
        {"0041b220", "MsgHandler_3ce8",
         "Packet handler, dispatched on opcode 0x3ce8. Recovered from the message dispatcher "
         + "(FUN_00414260 and its family), which reads a uint16 opcode from the message buffer at "
         + "+0x1050 and branches. The opcode is a fact; what the handler DOES is not claimed."},
        {"0041b3c0", "MsgHandler_bd1b",
         "Packet handler, dispatched on opcode 0xbd1b. Recovered from the message dispatcher "
         + "(FUN_00414260 and its family), which reads a uint16 opcode from the message buffer at "
         + "+0x1050 and branches. The opcode is a fact; what the handler DOES is not claimed."},
        {"0041b420", "MsgHandler_3542",
         "Packet handler, dispatched on opcode 0x3542. Recovered from the message dispatcher "
         + "(FUN_00414260 and its family), which reads a uint16 opcode from the message buffer at "
         + "+0x1050 and branches. The opcode is a fact; what the handler DOES is not claimed."},
        {"0041bac0", "MsgHandler_38f5",
         "Packet handler, dispatched on opcode 0x38f5. Recovered from the message dispatcher "
         + "(FUN_00414260 and its family), which reads a uint16 opcode from the message buffer at "
         + "+0x1050 and branches. The opcode is a fact; what the handler DOES is not claimed."},
        {"0041ce60", "MsgHandler_3b07",
         "Packet handler, dispatched on opcode 0x3b07. Recovered from the message dispatcher "
         + "(FUN_00414260 and its family), which reads a uint16 opcode from the message buffer at "
         + "+0x1050 and branches. The opcode is a fact; what the handler DOES is not claimed."},
        {"0041ce80", "MsgHandler_3908",
         "Packet handler, dispatched on opcode 0x3908. Recovered from the message dispatcher "
         + "(FUN_00414260 and its family), which reads a uint16 opcode from the message buffer at "
         + "+0x1050 and branches. The opcode is a fact; what the handler DOES is not claimed."},
        {"0041d090", "MsgHandler_34b1_74b7",
         "Packet handler, dispatched on opcode 0x34b1, 0x74b7, 0xb4b0. Recovered from the message dispatcher "
         + "(FUN_00414260 and its family), which reads a uint16 opcode from the message buffer at "
         + "+0x1050 and branches. The opcode is a fact; what the handler DOES is not claimed."},
        {"0041d0b0", "MsgHandler_34d2_74d1",
         "Packet handler, dispatched on opcode 0x34d2, 0x74d1, 0xb4d0. Recovered from the message dispatcher "
         + "(FUN_00414260 and its family), which reads a uint16 opcode from the message buffer at "
         + "+0x1050 and branches. The opcode is a fact; what the handler DOES is not claimed."},
        {"004263c0", "MsgHandler_3167",
         "Packet handler, dispatched on opcode 0x3167. Recovered from the message dispatcher "
         + "(FUN_00414260 and its family), which reads a uint16 opcode from the message buffer at "
         + "+0x1050 and branches. The opcode is a fact; what the handler DOES is not claimed."},
        {"004c7a10", "MsgHandler_703e",
         "Packet handler, dispatched on opcode 0x703e. Recovered from the message dispatcher "
         + "(FUN_00414260 and its family), which reads a uint16 opcode from the message buffer at "
         + "+0x1050 and branches. The opcode is a fact; what the handler DOES is not claimed."},
        {"00676aa0", "MsgHandler_34fe",
         "Packet handler, dispatched on opcode 0x34fe. Recovered from the message dispatcher "
         + "(FUN_00414260 and its family), which reads a uint16 opcode from the message buffer at "
         + "+0x1050 and branches. The opcode is a fact; what the handler DOES is not claimed."},
        {"00964b60", "MsgHandler_7d1b",
         "Packet handler, dispatched on opcode 0x7d1b. Recovered from the message dispatcher "
         + "(FUN_00414260 and its family), which reads a uint16 opcode from the message buffer at "
         + "+0x1050 and branches. The opcode is a fact; what the handler DOES is not claimed."},
        {"00969990", "MsgHandler_5000",
         "Packet handler, dispatched on opcode 0x5000. Recovered from the message dispatcher "
         + "(FUN_00414260 and its family), which reads a uint16 opcode from the message buffer at "
         + "+0x1050 and branches. The opcode is a fact; what the handler DOES is not claimed."},
        {"0083e6b0", "CharData_BindDBColumns",
         "The complete charData column map, and the best single artifact in the binary for that "
         + "struct. It binds every persisted _CHAR column to its offset -- FUN_00401fc0(name, "
         + "nameLen) then local_150 = offset, local_20c = type -- for 38 columns. Validated "
         + "against four offsets this project had derived independently by other means: Strength "
         + "0x74, Intellect 0x76, CurLevel 0x65, RemainSkillPoint 0x80, all exact. New from it: "
         + "+0x64 Scale, +0x70 SExpOffset, +0x78 RemainGold, +0x86 RemainHwanCount, +0x88 "
         + "GatheredExpPoint, +0xa8 AutoInvestExp, +0xac InventorySize, +0xb0/0xb2 DailyPK/TotalPK, "
         + "+0xb4 PKPenaltyPoint, +0xdc-0xe8 DiedRegion/Pos, +0xf2 HwanLevel."},
        {"00412c20", "InitializeGame",
         "Names itself: \"InitializeGame() Succeeded!\"."},
        {"00437a50", "CLobby_RemoveStalePlayers",
         "Names itself: \"CLobby::_RemoveStalePlayers() NULL Lobby Entry Found!\"."},
        {"00440870", "AQ_COSManipulator_DoWork",
         "Names itself: \"AQ_COSManipulator::DoWork() - nothing to query\"."},
        {"004e3860", "RemoveParamKeeperItemEntry",
         "Names itself: \"RemoveParamKeeperItemEntry() - What the hell this equip set type? "
         + "-_-; (btType: %d)\". Called by CGItemEquip__DetachAbilityByItemOptLevel, which "
         + "establishes something structural: an equipped item ADDS AND REMOVES ITS OWN ENTRIES "
         + "in the ParamKeeper rather than being folded into a flat total. So a player's derived "
         + "stats are the sum of per-item entries, which is why hunting a single gear aggregate "
         + "kept coming up empty."},
        {"004ec340", "AutoReloadMagazine",
         "Names itself: \"::AutoReloadMagazine() call DelItem_EXT() returned fail!!.\" -- the "
         + "FIRST identifier in the message is the function; DelItem_EXT is what it called."},
        {"004eeb70", "DelItem_EXT",
         "Names itself: \"::DelItem_EXT() call AsyncQuery failed!! [MsgProcState: %d]\"."},
        {"00511f00", "PC_ReleaseCOS",
         "Names itself: \"PC::RelaseCOS() Failed!!!\" -- the misspelling is the game's own."},
        {"0040f930", "Formula_RollMagicalDamage",
         "The twin of Formula_RollWeaponDamage for the other damage type: identical three lines, "
         + "reading param 193 as the minimum and 192 as the maximum instead of 191/190."},
        {"0040f8d0", "Formula_RollWeaponDamage",
         "The weapon damage roll: reads param 191 as the minimum and param 190 as the maximum "
         + "through the GetParam virtual at vtable offset 0x104, returns 0 when max <= min, else "
         + "rand() %% (max-min+1) + min. Char_PublishCombatStats sets 190/191 (and 192/193 as the "
         + "other type's pair) from the gear aggregate."},
        {"0040f890", "Formula_RollLevelDamage",
         "A level-scaled damage roll used when no weapon range applies: takes both parties' levels "
         + "via Char_GetLevel (vtable 0x124) and rolls rand() in a window built from level*5 and "
         + "level*10."},
        {"0040e450", "Formula_MitigatePhysicalDamage",
         "Damage mitigation, physical side. Gated on bit 4 of the flags at +0x230, twinned with "
         + "Formula_MitigateMagicalDamage (bit 8). Reads params 5 and 7 off the same object and "
         + "computes `X / (1 + param7/100) - flat`, floored at 0 -- so param 7 is a PERCENTAGE "
         + "reduction and the subtraction is flat absorption. Constants: 0x00b45ac0 = 1.0, "
         + "0x00b45af0 = 100.0. Physical rather than magical because the player stat graph feeds "
         + "param 5 from Strength (charData+0x74, named by the server's own SQL DDL) while the "
         + "twin's param 6 comes from Intellect."},
        {"0040e830", "Formula_MitigateMagicalDamage",
         "The magical twin of Formula_MitigatePhysicalDamage: same shape, bit 8 of +0x230, reads "
         + "params 6 and 8, `X / (1 + param8/100) - flat` floored at 0. Param 6 is fed from "
         + "Intellect in the player stat graph."},
        {"004105d0", "Formula_MonsterExpReward",
         "The monster exp reward. PROVEN by its use-site: the caller passes the result to the "
         + "virtual at vtable offset 0x694, which on the char vtable (base 0x00af59fc) is "
         + "GObjPC_GiveExp. Reads both parties' levels via Char_GetLevel, takes the MIN of the "
         + "two -- so a kill is worth the LOWER level's reward, which is the anti-powerlevelling "
         + "rule -- indexes the level table at that level, and returns "
         + "scaleByWindow * table[min].field_0x1c * target[0x1cd8] * scaleByDiff, floored at 1. "
         + "WHICH leveldata column field_0x1c is remains INFERRED, not proven: entry+0x8 is the "
         + "int64 col 1 and entry+0x10 is col 2 (both grounded), which puts +0x1c at col 5, and "
         + "col 5's scale matches the game's exp pacing -- but no parser has been read to confirm "
         + "cols 3/4 are 32-bit rather than int64."},
        {"004eac40", "GObjPC_GiveExp",
         "Grants exp to a PC and then runs the party share (FUN_004fcda0). Virtual, vtable offset "
         + "0x694 = slot 421; the slot was read straight out of the vtable at 0x00af6090."},
        {"004a6870", "Char_GetLevel",
         "Virtual, vtable offset 0x124 = slot 73. Not a field read -- it returns ParamKeeper "
         + "param 0 (Level), rounded, which independently re-confirms that param 0 is Level. Used "
         + "as the exponent base in GObjPC_InitStats and as the level-gap term in the damage and "
         + "exp formulae."},
        {"004e6980", "GObjPC_OnDeath",
         "The death handler: it pays the KILLER and penalises the DEAD, and an earlier pass here "
         + "named it GObjPC_GrantKillReward after reading only the first half -- misleading, and "
         + "corrected. The top computes Formula_MonsterExpReward, doubles it under one condition, "
         + "and hands it to GObjPC_GiveExp (vtable 0x694) for param_1. The rest, gated on the "
         + "dead character's level being above 10, is the DEATH PENALTY on param_2: exp loss as "
         + "levelEntry+0x1c (the per-level exp unit) times 20, 100 or 300 depending on branch, "
         + "applied through GObjPC_GainExpAndLevel (vtable 0x170) with a NEGATIVE amount; skill-"
         + "point loss through GObjPC_AddSkillPoints (0x174), also negative and capped at what "
         + "the character has; then a rand roll against FUN_004e6930 that can drop an item via "
         + "CGStorage__RandomSelectNonEmptySlotForDeathPenalty. The 20/100/300 branch conditions "
         + "are NOT understood -- they turn on param_2[0x72d] != 5 and charData+0xb4 -- so the "
         + "penalty is recorded, not shipped."},
        {"0040fed0", "Formula_ExpScaleByLevelWindow",
         "One of the two exp reward scalers. Reads both parties' levels and compares against a "
         + "+10 level window."},
        {"0040ffe0", "Formula_ExpScaleByLevelDiff",
         "The other exp reward scaler: works from (targetLevel - attackerLevel) and picks its "
         + "constants from a flag at the source ref object's +0x88."},
        {"00498690", "Stat_ApplyTaggedModifier",
         "Applies one tagged stat modifier: the tag is a C multi-char literal in EAX, the amount "
         + "in param_2. THIS IS THE id->name TABLE the binary otherwise lacks -- there is no data "
         + "table anywhere, but each branch of this dispatcher pushes into a specific ParamKeeper "
         + "id and slot, so the enum can be read off the code. Verified against the equality "
         + "branches only (the compiler builds a binary-search tree, and its '<' comparisons will "
         + "pair a tag with the wrong branch if you match them): 'int'->2, 'hp'/'hpa'->3, "
         + "'mp'/'mpa'->4, 'era'->9 slot 1, 'bri'->10, 'hra'->11 slot 1, 'cri'->12, 'hprg'->25, "
         + "'mprg'->26, 'rals'->27, 'hpna'->52, 'mpna'->53, 'evbl'->56, 'evcr'->57. Slot 1 is the "
         + "additive percent, slot 0 the base."},
        {"00497830", "Char_PublishCombatStats",
         "Copies the character's precomputed aggregate combat block into the keeper: obj[0x66]->5, "
         + "[0x67]->9, [0x68]->7, [0x69]->10, [0x6a]->6, [0x6b]->8, then 13/14, 15/16, 11/12 and "
         + "the movement pair 23/24. The aggregate itself is built elsewhere; this only publishes "
         + "it."},
        {"004b3830", "ParamKeeper_GetParam",
         "Reads a param's current value by id. The id is in AX (MOVZX EAX,AX), the keeper in ECX; "
         + "indexes [ECX + id*4 + 4] and returns 0.0 when the param was never created. Only four "
         + "call sites -- every other read is inlined, the constant id folded into the "
         + "displacement, which is why grepping for a getter finds almost nothing."},
        {"004b33a0", "Param_GetValue",
         "Returns a param object's value: re-evaluates first if the dirty flag at +0x1a is set, "
         + "then loads the cached result from +0x1c."},
        {"004e3200", "GObjPC_InitStats",
         "Player stat initialiser, and the whole player derived-stat graph in one function: 30 "
         + "BindDerived edges plus the constant pushes. Params 0/1/2 are Level (charData+0x65), "
         + "Strength (+0x74) and Intellect (+0x76) -- id 0 is confirmed Level independently by "
         + "GObjMob_PublishStats pushing the level virtual at the same id. It computes "
         + "1.02^(level-1) by binary exponentiation and pushes it into slot 3 of params 54 and "
         + "55. The chains are Str(1) -> 52 -> 54 -> MaxHP(3) and Int(2) -> 53 -> 55 -> MaxMP(4), "
         + "with 1000.0 in slot 3 of 52/53. Evaluated by the keeper's rule that gives "
         + "MaxHP = Str * 10 * 1.02^(level-1) and MaxMP = Int * 10 * 1.02^(level-1). Constants: "
         + "0x00b45ea0 = 1.02, 0x00b45af0 = 100.0, 0x00b462ac = 1000.0."},
        {"004c3730", "GObjMob_PublishStats",
         "Publishes a monster's stats from its ref object, and the function that pins the param "
         + "ids: it pushes the level virtual at id 0, refobj+0x19c (the field RefObjChar_"
         + "ExtractData asserts m_dwMaxHP > 0 on) at id 3, and +0x1a0 at id 4. So param 3 = MaxHP "
         + "and param 4 = MaxMP. Also 0x230/0x234 -> 5/6, 0x248/0x24c -> 11/12. Each read adds "
         + "2^32 when negative, so these refobj fields are unsigned 32-bit. Notably skips +0x250, "
         + "which is characterdata col 79."},
        {"004e5250", "GObjPC_GainExpAndLevel",
         "Exp gain and level-up; virtual, vtable slot 92 (offset 0x170). Takes exp as a 64-bit "
         + "pair, reads the level entry via pc[0x72c] whose +8/+0xc is the int64 requirement, "
         + "and branches on level < 0x6f (111) and == 0x6e (110, the cap)."},
        {"004e4d90", "GObjPC_SetLevel",
         "Writes the new level to charData+0x65 and, on a new max level, adds levelsGained*5 to "
         + "charData+0x84. NOTE: 5/level here conflicts with the 3/level this project grounded "
         + "from a real character window; y0gi is an Easy server and may have modded it."},
        {"004e4c60", "GObjPC_AddSkillPoints",
         "Adds a delta to skill points at charData+0x80; virtual, vtable slot 93 (offset 0x174). "
         + "A negative delta spends, which is how the mastery cost was found."},
        {"00511470", "GObjPC_SpendStatPoints",
         "Spends stat points from charData+0x84 into Strength (+0x74) and Intellect (+0x76), "
         + "pushing the new values into the ParamKeeper."},
        {"0059c4e0", "Mastery_LevelUp",
         "Mastery level-up. Walks the levels being raised, accumulates the level table's "
         + "entry+0x10 (leveldata column 2) for each, and refuses with error 0x3802 when the "
         + "character's skill points fall short. This is where the mastery cost was recovered."},
    };

    // The client binary's proven functions. Fewer, because the client asserts
    // with __FILE__ and an expression rather than Class::Method, so far less of
    // it names itself -- 17 functions against the server's 533.
    private static final String[][] KNOWN_CLIENT = {
        {"00844cd0", "Client_LoadAllRefData",
         "Master refdata dispatcher: builds each \"%stextdata\\<file>.txt\" name in turn -- "
         + "characterdata, itemdata, skilldata, the shop chain, leveldata -- and calls the "
         + "generic loader for each."},
        {"00952890", "Client_LoadRefDataFile",
         "The generic refdata file loader/tokeniser, called once per textdata file by the "
         + "dispatcher. Per-type column parsing lives behind it in a per-type manager, which is "
         + "why the client side of the characterdata column map was a dead end."},
        {"008a97c0", "Client_ApplyExpAndLevelUp",
         "The client's EXP handler. Its level-up loop subtracts each level's requirement from "
         + "the running EXP and increments the level, carrying the remainder; caps while "
         + "(level != 'n') = 0x6e = 110; and holds max-level EXP at requirement-1 rather than "
         + "zeroing. This is where the 110 cap and the overflow-carry rule were grounded."},
        {"0069b4c0", "Client_TargetWindow_RankIcon",
         "Switch on a monster's rank field (+0x7ac, the raw characterdata col 15 Rarity) "
         + "choosing the target window's gem: 0 normal, 1 champion, 3/8 unique, 4 giant, "
         + "5 titan, 6 elite, 7 normal, 2/default none."},
        {"0069f860", "CIFSkillMastery_SetMasteryData",
         "Skill-mastery window: stores the mastery data pointer and asserts m_pMasteryData "
         + "against IFSkillMastery.cpp."},
    };

    public void run() throws Exception {
        String[] args = getScriptArgs();
        boolean apply = args.length > 0 && args[0].equalsIgnoreCase("apply");
        // 'force' lets this table CORRECT a name it applied before. Needed
        // because findings get revised: GObjPC_GrantKillReward was named after
        // reading only the first half of the function, which turned out to be
        // the death handler. Without force the tool could not fix its own
        // mistakes, only add to them.
        boolean force = args.length > 1 && args[1].equalsIgnoreCase("force");

        // Pick the table that belongs to the program being processed.
        String prog = currentProgram.getName().toLowerCase();
        String[][] table = prog.contains("client") ? KNOWN_CLIENT : KNOWN;
        println("  program=" + currentProgram.getName() + " entries=" + table.length);

        int done = 0, missing = 0, skipped = 0;
        for (String[] k : table) {
            Address a = currentProgram.getAddressFactory().getAddress(k[0]);
            Function f = a == null ? null : currentProgram.getFunctionManager().getFunctionAt(a);
            if (f == null) { println("  no function at " + k[0]); missing++; continue; }
            // Never clobber a name that came from the binary's own assert
            // string -- unless explicitly forced, which is how a correction is
            // applied.
            if (!f.getName().startsWith("FUN_")) {
                if (!force || f.getName().equals(k[1])) {
                    println("  " + k[0] + " already named " + f.getName() + " -- leaving it");
                    skipped++;
                    continue;
                }
                println("  " + k[0] + " RENAMING " + f.getName() + " -> " + k[1]);
            }
            if (!apply) { println("  would name " + k[0] + " -> " + k[1]); done++; continue; }
            f.setName(k[1], SourceType.ANALYSIS);
            f.setComment("Identified by srrevamp RE.\n" + k[2]);
            done++;
        }
        println("===KNOWNNAMES=== named=" + done + " missing=" + missing + " alreadyNamed=" + skipped
                + (apply ? "" : " (report only, pass 'apply')"));
    }
}
