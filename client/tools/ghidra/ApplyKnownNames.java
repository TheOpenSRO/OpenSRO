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
        {"004c7a10", "MsgHandler_703e",
         "Packet handler, dispatched on opcode 0x703e. Recovered from the message dispatcher "
         + "(FUN_00414260 and its family), which reads a uint16 opcode from the message buffer at "
         + "+0x1050 and branches. The opcode is a fact; what the handler DOES is not claimed."},
        {"00676aa0", "MsgHandler_34fe",
         "Packet handler, dispatched on opcode 0x34fe. Recovered from the message dispatcher "
         + "(FUN_00414260 and its family), which reads a uint16 opcode from the message buffer at "
         + "+0x1050 and branches. The opcode is a fact; what the handler DOES is not claimed."},
        {"00969990", "MsgHandler_5000",
         "Packet handler, dispatched on opcode 0x5000. Recovered from the message dispatcher "
         + "(FUN_00414260 and its family), which reads a uint16 opcode from the message buffer at "
         + "+0x1050 and branches. The opcode is a fact; what the handler DOES is not claimed."},
        {"00404e50", "FUN_00404e50",
         "NAME WITHDRAWN. An earlier opcode-tree pass called this MsgHandler_34ba; it has 17 "
         + "callers and branches on a message-object field (+0x1048) into one of two functions, "
         + "so it is a helper of some kind -- but what kind is not established, and an unsupported "
         + "name is worse than none. Reset to the default so it reads as unknown."},
        {"00404f80", "MsgBuf_ReadUInt8",
         "Reads one byte from the message buffer and advances the read cursor. The buffer is "
         + "base +0x1034, read cursor +0x103c, size +0x103e -- the same object whose +0x1050 holds "
         + "the opcode. 65 callers, because every handler reads its fields through this; an "
         + "earlier pass mistook that for a packet handler."},
        {"004263c0", "MsgBuf_ReadUInt16",
         "The uint16 twin of MsgBuf_ReadUInt8: reads two bytes and advances the cursor by two."},
        // --- Singleton accessors (server). Self-evidencing shape. ---
        {"00401d10", "GetSingleton_00d6a8e8",
         "Singleton accessor: `if (DAT_00d6a8e8 == 0) Assert_BreakIfDebugger(); return DAT_00d6a8e8;` -- the "
         + "shape is unambiguous and self-evidencing, no inference needed. 34 of these exist."},
        {"00401d30", "GetSingleton_00d6a8dc",
         "Singleton accessor: `if (DAT_00d6a8dc == 0) Assert_BreakIfDebugger(); return DAT_00d6a8dc;` -- the "
         + "shape is unambiguous and self-evidencing, no inference needed. 34 of these exist."},
        {"00401d50", "GetSingleton_00d6aa18",
         "Singleton accessor: `if (DAT_00d6aa18 == 0) Assert_BreakIfDebugger(); return DAT_00d6aa18;` -- the "
         + "shape is unambiguous and self-evidencing, no inference needed. 34 of these exist."},
        {"00401d70", "GetSingleton_00d6a984",
         "Singleton accessor: `if (DAT_00d6a984 == 0) Assert_BreakIfDebugger(); return DAT_00d6a984;` -- the "
         + "shape is unambiguous and self-evidencing, no inference needed. 34 of these exist."},
        {"004039d0", "GetSingleton_00d6a9a4",
         "Singleton accessor: `if (DAT_00d6a9a4 == 0) Assert_BreakIfDebugger(); return DAT_00d6a9a4;` -- the "
         + "shape is unambiguous and self-evidencing, no inference needed. 34 of these exist."},
        {"004039f0", "GetSingleton_00d6a968",
         "Singleton accessor: `if (DAT_00d6a968 == 0) Assert_BreakIfDebugger(); return DAT_00d6a968;` -- the "
         + "shape is unambiguous and self-evidencing, no inference needed. 34 of these exist."},
        {"00403b50", "GetSingleton_00d6a9ec",
         "Singleton accessor: `if (DAT_00d6a9ec == 0) Assert_BreakIfDebugger(); return DAT_00d6a9ec;` -- the "
         + "shape is unambiguous and self-evidencing, no inference needed. 34 of these exist."},
        {"00403b70", "GetSingleton_00d6aa00",
         "Singleton accessor: `if (DAT_00d6aa00 == 0) Assert_BreakIfDebugger(); return DAT_00d6aa00;` -- the "
         + "shape is unambiguous and self-evidencing, no inference needed. 34 of these exist."},
        {"00404ca0", "GetSingleton_00d6aa14",
         "Singleton accessor: `if (DAT_00d6aa14 == 0) Assert_BreakIfDebugger(); return DAT_00d6aa14;` -- the "
         + "shape is unambiguous and self-evidencing, no inference needed. 34 of these exist."},
        {"0040bb50", "GetSingleton_00d6aa1c",
         "Singleton accessor: `if (DAT_00d6aa1c == 0) Assert_BreakIfDebugger(); return DAT_00d6aa1c;` -- the "
         + "shape is unambiguous and self-evidencing, no inference needed. 34 of these exist."},
        {"00411110", "GetSingleton_00d6a8e4",
         "Singleton accessor: `if (DAT_00d6a8e4 == 0) Assert_BreakIfDebugger(); return DAT_00d6a8e4;` -- the "
         + "shape is unambiguous and self-evidencing, no inference needed. 34 of these exist."},
        {"0041baa0", "GetSingleton_00d6a990",
         "Singleton accessor: `if (DAT_00d6a990 == 0) Assert_BreakIfDebugger(); return DAT_00d6a990;` -- the "
         + "shape is unambiguous and self-evidencing, no inference needed. 34 of these exist."},
        {"0041bac0", "GetSingleton_00d6a994",
         "Singleton accessor: `if (DAT_00d6a994 == 0) Assert_BreakIfDebugger(); return DAT_00d6a994;` -- the "
         + "shape is unambiguous and self-evidencing, no inference needed. 34 of these exist."},
        {"0041bae0", "GetSingleton_00d6a954",
         "Singleton accessor: `if (DAT_00d6a954 == 0) Assert_BreakIfDebugger(); return DAT_00d6a954;` -- the "
         + "shape is unambiguous and self-evidencing, no inference needed. 34 of these exist."},
        {"0041bc40", "GetSingleton_00d6a96c",
         "Singleton accessor: `if (DAT_00d6a96c == 0) Assert_BreakIfDebugger(); return DAT_00d6a96c;` -- the "
         + "shape is unambiguous and self-evidencing, no inference needed. 34 of these exist."},
        {"0041bc60", "GetSingleton_00d6a900",
         "Singleton accessor: `if (DAT_00d6a900 == 0) Assert_BreakIfDebugger(); return DAT_00d6a900;` -- the "
         + "shape is unambiguous and self-evidencing, no inference needed. 34 of these exist."},
        {"0041bc80", "GetSingleton_00d6a950",
         "Singleton accessor: `if (DAT_00d6a950 == 0) Assert_BreakIfDebugger(); return DAT_00d6a950;` -- the "
         + "shape is unambiguous and self-evidencing, no inference needed. 34 of these exist."},
        {"0041bca0", "GetSingleton_00d6a960",
         "Singleton accessor: `if (DAT_00d6a960 == 0) Assert_BreakIfDebugger(); return DAT_00d6a960;` -- the "
         + "shape is unambiguous and self-evidencing, no inference needed. 34 of these exist."},
        {"0041ce40", "GetSingleton_00d6a94c",
         "Singleton accessor: `if (DAT_00d6a94c == 0) Assert_BreakIfDebugger(); return DAT_00d6a94c;` -- the "
         + "shape is unambiguous and self-evidencing, no inference needed. 34 of these exist."},
        {"0041ce60", "GetSingleton_00d6a998",
         "Singleton accessor: `if (DAT_00d6a998 == 0) Assert_BreakIfDebugger(); return DAT_00d6a998;` -- the "
         + "shape is unambiguous and self-evidencing, no inference needed. 34 of these exist."},
        {"0041ce80", "GetSingleton_00d6a9a0",
         "Singleton accessor: `if (DAT_00d6a9a0 == 0) Assert_BreakIfDebugger(); return DAT_00d6a9a0;` -- the "
         + "shape is unambiguous and self-evidencing, no inference needed. 34 of these exist."},
        {"0041cea0", "GetSingleton_00d6a99c",
         "Singleton accessor: `if (DAT_00d6a99c == 0) Assert_BreakIfDebugger(); return DAT_00d6a99c;` -- the "
         + "shape is unambiguous and self-evidencing, no inference needed. 34 of these exist."},
        {"0041cec0", "GetSingleton_00d6a980",
         "Singleton accessor: `if (DAT_00d6a980 == 0) Assert_BreakIfDebugger(); return DAT_00d6a980;` -- the "
         + "shape is unambiguous and self-evidencing, no inference needed. 34 of these exist."},
        {"0041cee0", "GetSingleton_00d6a98c",
         "Singleton accessor: `if (DAT_00d6a98c == 0) Assert_BreakIfDebugger(); return DAT_00d6a98c;` -- the "
         + "shape is unambiguous and self-evidencing, no inference needed. 34 of these exist."},
        {"0041d050", "GetSingleton_00d6a9e4",
         "Singleton accessor: `if (DAT_00d6a9e4 == 0) Assert_BreakIfDebugger(); return DAT_00d6a9e4;` -- the "
         + "shape is unambiguous and self-evidencing, no inference needed. 34 of these exist."},
        {"0041d070", "GetSingleton_00d6a9a8",
         "Singleton accessor: `if (DAT_00d6a9a8 == 0) Assert_BreakIfDebugger(); return DAT_00d6a9a8;` -- the "
         + "shape is unambiguous and self-evidencing, no inference needed. 34 of these exist."},
        {"0041d090", "GetSingleton_00d6a9f4",
         "Singleton accessor: `if (DAT_00d6a9f4 == 0) Assert_BreakIfDebugger(); return DAT_00d6a9f4;` -- the "
         + "shape is unambiguous and self-evidencing, no inference needed. 34 of these exist."},
        {"0041d0b0", "GetSingleton_00d6a9fc",
         "Singleton accessor: `if (DAT_00d6a9fc == 0) Assert_BreakIfDebugger(); return DAT_00d6a9fc;` -- the "
         + "shape is unambiguous and self-evidencing, no inference needed. 34 of these exist."},
        {"0041d0d0", "GetSingleton_00d6a964",
         "Singleton accessor: `if (DAT_00d6a964 == 0) Assert_BreakIfDebugger(); return DAT_00d6a964;` -- the "
         + "shape is unambiguous and self-evidencing, no inference needed. 34 of these exist."},
        {"0041d2e0", "GetSingleton_00d6a988",
         "Singleton accessor: `if (DAT_00d6a988 == 0) Assert_BreakIfDebugger(); return DAT_00d6a988;` -- the "
         + "shape is unambiguous and self-evidencing, no inference needed. 34 of these exist."},
        {"0041d300", "GetSingleton_00d6a9b4",
         "Singleton accessor: `if (DAT_00d6a9b4 == 0) Assert_BreakIfDebugger(); return DAT_00d6a9b4;` -- the "
         + "shape is unambiguous and self-evidencing, no inference needed. 34 of these exist."},
        {"00442370", "GetSingleton_00d6a95c",
         "Singleton accessor: `if (DAT_00d6a95c == 0) Assert_BreakIfDebugger(); return DAT_00d6a95c;` -- the "
         + "shape is unambiguous and self-evidencing, no inference needed. 34 of these exist."},
        {"004c27b0", "GetSingleton_00d6a9ac",
         "Singleton accessor: `if (DAT_00d6a9ac == 0) Assert_BreakIfDebugger(); return DAT_00d6a9ac;` -- the "
         + "shape is unambiguous and self-evidencing, no inference needed. 34 of these exist."},
        {"005fcfc0", "GetSingleton_00d6a9f8",
         "Singleton accessor: `if (DAT_00d6a9f8 == 0) Assert_BreakIfDebugger(); return DAT_00d6a9f8;` -- the "
         + "shape is unambiguous and self-evidencing, no inference needed. 34 of these exist."},
        {"00964b60", "Assert_BreakIfDebugger",
         "The assert/verify helper -- calls IsDebuggerPresent and breaks. **10,357 call sites**, "
         + "the most-called function in the binary. An earlier pass here named it "
         + "MsgHandler_7d1b: the opcode-tree extractor paired a comparison with the next call, "
         + "and in one branch that call was this. The tell was the call count -- a packet handler "
         + "has 2, not ten thousand -- and the address band, 0x96xxxx being infrastructure while "
         + "every real handler sits near the 0x41xxxx dispatcher."},
        {"00869640", "QuestHandler_OnDead",
         "One quest's OnDead handler. All three of this triple resolve the SAME name id (0x15a) "
         + "through a virtual at +0x34 and log \"HandlerOnDead_%s()\" with it -- so the %s is the "
         + "quest's name fetched for the log line, and the handler itself is COMPILED CODE for "
         + "that quest. This is what \"quest objectives are not data\" looks like concretely."},
        {"00869740", "QuestHandler_OnUpdate",
         "The same quest's OnUpdate handler; logs \"HandlerOnUpdate_%s()\"."},
        {"008699a0", "QuestHandler_SetupQuest",
         "The same quest's setup handler; logs \"HandlerSetupQuest_%s(%d)\". Together with "
         + "OnDead and OnUpdate this is the three-handler lifecycle each custom quest gets."},
        {"008341b0", "DB_Load_RefQuest",
         "Loads the _REFQUEST refdata table from the database -- quest identity and metadata, the "
         + "server's counterpart to the client's questdata.txt. Like the drop loaders it is a "
         + "SELECT * with no column names in the binary."},
        {"0082c5e0", "DB_Load_RefDropItemGroup",
         "Loads the _REFDROPITEMGROUP refdata table from the server's DATABASE. Drops are not in "
         + "any shipped file -- they are SQL refdata, which is why no artifact this project has "
         + "contains them."},
        {"0082be90", "DB_Load_RefMonster_AssignedItemDrop",
         "Loads _REFMONSTER_ASSIGNEDITEMDROP: the per-monster drop assignment. Its error string "
         + "names the table -- \"Can't find ItemGroupID(%d) within _RefMonster_AssignedItemRndDrop "
         + "Table\" -- so a monster maps to an item GROUP id, and the group maps to items."},
        {"00833000", "DB_Load_RefDropItemAssign",
         "Loads _REFDROPITEMASSIGN. CRefDropData__AddAssignedItemDrop walks these as a 48-byte "
         + "(0x30) stride array and compares a rand against a FLOAT at record+8, so +8 is the drop "
         + "probability."},
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
         + "additive percent, slot 0 the base. EXTRACTED IN FULL 2026-09-15 -- 53 tags, 31 "
         + "resolved, 7 proven dead, see docs/protocol/param_tags.md. 34 of the 53 reach their "
         + "param through the shared tail at LAB_00498adf with the id left in EDI, which the "
         + "annotation pass cannot see; disassembly dataflow resolves them. That is how 'drua' "
         + "turned out to write 128,129,130 AND 131 (the fourth is 'mov edi,0x83; jmp 0x498adf'), "
         + "and how param 1 was confirmed as Strength ('str'/'stra'/'strj'/'strv', and the tail's "
         + "own default is 'mov edi,0x1'). Params 27-32 are the six status resistances. Tags "
         + "'er', 'atha', 'rep', 'astr', 'dura', 'luck' and 'soli' return without touching a "
         + "param -- they are DEAD, not unimplemented."},
        {"004d60a0", "COS_ApplyHalfCombatScale",
         "Sets slot 3 (the percent scale, which compounds from 100) to 50.0 on the whole combat "
         + "block at once -- params 5, 6, 9, 11 and 13/14/15/16 -- then flushes the keeper. The "
         + "constant is 'fld DWORD ds:0xb4603c' = 50.0f, so it HALVES damage bounds, defence, "
         + "parry rate and attack rate. Reached only from CGObjCOS_GoldPet::vslot_215 and "
         + "vslot_211 (one call, one tail-jmp, no address-taken references), so it is the gold "
         + "pet's combat penalty rather than a general scale."},
        {"004aaf80", "Effect_NegateDaraFamily",
         "Dispatches on the 4-char code 0x44414252 ('DABR' read big-endian) and negates the "
         + "value into params 174-177 at slot 2 -- the same family the 'dara' tag writes. Paired "
         + "with GObjPC::FUN_004ab060, which removes the same four via FUN_004b3570(0xae..0xb1). "
         + "What the code itself denotes is NOT recovered; only the mechanics are."},
        {"00508170", "AvatarBless_TagList",
         "Builds the 12-tag list an avatar item's blessing can carry, in order: 'stra', 'inta', "
         + "'hra', 'era', 'hpa', 'mpa', 'drua', 'dara', 'mdia', 'hprg', 'mprg', 'luca'. Pairs "
         + "with the 'AVT <tag> +%d%%' / 'Ava <tag> +%d%%' format strings. Tags are stored "
         + "big-endian, so read the constants as BE bytes -- a little-endian read reverses them."},
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
         + "character's skill points fall short. This is where the mastery cost was recovered. "
         + "FULL RULE read 2026-09-16: there are THREE total-cap branches, selected by the byte "
         + "at (charData+0x18)+0x88 -- selector 0 refuses when sum+requested >= 0x14b (a flat "
         + "total of 330, no level term); selector 1 allows only when total <= 240.0 (the double "
         + "at 0xb46130, via FCOMP QWORD) AND total <= level+level; selector 2 imposes no total "
         + "cap; anything else is error 0x3801. Past the cap check it applies a PER-MASTERY "
         + "rule, refusing with 0x3804 when characterLevel < currentMasteryLevel + requested -- "
         + "so one mastery may never exceed the character's level. Error codes: 0x3801 bad "
         + "mastery or selector, 0x3802 insufficient skill points, 0x3803, 0x3804 exceeds "
         + "character level, 0x3805 total cap. The selector is NOT identified: it is the same "
         + "field a skill's +0xc4 is compared against and that indexes DAT_00c8262c, which fits "
         + "race/country, but that is a shape argument without a use-site."},

        {"00594ac0", "Skill_ApplyEffectsToParams",
         "Reads a skill's parsed param fields and pushes them into the target's ParamKeeper -- "
         + "the applier side of the pair whose teardown is GObjPC_OnEffectExpired. Touches 34 "
         + "distinct skill-param field offsets, more than any function but the parser itself, "
         + "which is what makes it the lever for identifying what a skill code DOES: pairing "
         + "each field read with the param ids written just after gives the code->param join in "
         + "docs/protocol/skill_params.md. 85 of its SetParam calls are positive and 17 negated "
         + "(debuffs such as the dara family). Controlled against six independently established "
         + "codes -- irgc->25,26; er->9; hr->11; stri->1; mpi->4; dru->128,129,130,131 -- all of "
         + "which reproduce exactly."},

        {"004e4d00", "GObjPC_AdjustHwanCount",
         "Adds a signed delta to _CHAR.RemainHwanCount (charData+0x86), clamped to [0, 5], "
         + "setting dirty bit 0x10 and notifying on change. Refuses a POSITIVE delta while "
         + "GetBodyMode() == 1, which is an independent confirmation that body mode 1 is "
         + "berserk: you cannot bank charges mid-berserk. Six call sites -- an item grants +5, "
         + "the berserk activation spends -5, and the rest are variable."},

        {"004aa5b0", "IGObj_GetBodyMode",
         "Vtable slot 64, named from the base class's own assert. Returns the body-mode byte at "
         + "(*(this+0x30))+3 -- the same byte IGObj::SetBodyMode writes. Combat_ResolveDamage "
         + "compares it against 1 to set the berserk damage flag, so BODY MODE 1 IS BERSERK."},

        {"00427050", "CMainProcess_LoadGainRates",
         "Startup loader for the server's gain multipliers. Each knob follows one shape: "
         + "value = atol(setting) / 100.0 (so the setting is a PERCENTAGE), then a floor at 1.0 "
         + "reached via the branch that logs \"<knob>: system default\", then a clamp at a "
         + "per-knob ceiling. So rates below 1x cannot be configured at all. The knobs and their "
         + "caps, each a float32 loaded by the comparison: ExpRatio and ExpRatioParty 2.5 "
         + "(0xb45b90), DropItemRatio 3.0 (0xb45b84), DropGoldAmountCoef 2.5, HwanGainFactor "
         + "10.0 (0xb45b44). The globals (0xc82518, 0xc8251c, 0xc82520, 0xc82524, 0xc82528) are "
         + "statically initialised to 0x3f800000 = 1.0f first, confirming the default "
         + "independently. GObjPC_ReceiveKillReward picks ONE of the two exp knobs by party "
         + "membership -- `fVar1 = ExpRatio; if (pc[0x72e] != 0) fVar1 = ExpRatioParty;` -- "
         + "rather than multiplying them."},

        // Chance rolls, which are not memoryless.
        {"00599cc0", "Chance_RollWithBadLuckProtection",
         "The engine's chance roll. Returns false at once for a chance of 0 and true for 100 or "
         + "more, touching no state; otherwise it looks up a per-actor accumulator and compares "
         + "THAT against rand()%%101 rather than the raw chance, then adds `chance` on a failure "
         + "or `chance - 100` on a success. The first roll for a key has no entry, compares the "
         + "raw chance, and seeds chance*2 or chance*2-100 -- which is the same update rule "
         + "applied once, not a special case. Net effect: bad-luck protection, with the long-run "
         + "rate unchanged."},
        {"005a1a20", "GObjPC_RollChanceForActor",
         "Thin wrapper on Chance_RollWithBadLuckProtection: refuses a chance below 1, then calls "
         + "it with the container at param_2+4 and the key in param_1. Call sites build the key "
         + "as (objectId & 0xFFFFFF) | tag<<24 -- `and ecx,0xffffff` then `or ecx,<tag>000000` -- "
         + "so accumulators are per actor AND per kind. Seven tags appear in the binary, six "
         + "ASCII: B, C, D, E, H, M. Only 0x43 ('C') has a use-site behind it, the call inside "
         + "Combat_ResolveDamage; the rest are unidentified."},

        // The mastery collection at pc+0xa30, and the exp rule built on it.
        {"0059e870", "Mastery_MaxLevel",
         "Walks the mastery list under pc+0xa30 (head at +0x238, sentinel +0x234) and returns the "
         + "MAXIMUM level byte at entry[0x10][8]+0x20, skipping entries whose [0x10]+0xc is 3. "
         + "Proven by its twin: FUN_0059e7c0 walks the identical list with the identical skip "
         + "rule and value path but SUMS, and Mastery_LevelUp compares that sum plus the levels "
         + "requested against its total-mastery cap -- so the list is masteries and the byte is "
         + "a mastery level."},
        {"0059e7c0", "Mastery_SumLevels",
         "Sums every mastery level over the same list Mastery_MaxLevel maximises. Its result is "
         + "what Mastery_LevelUp checks a raise against: 'sum + requested' is compared with the "
         + "flat 0x14b (331) on one branch and with the double 240.0 at 0xb46130 on another, so "
         + "this binary carries two total-cap shapes rather than one."},
        {"0060c4b0", "CMainProcess_RollByEffectiveLevel",
         "Takes max(characterLevel, Mastery_MaxLevel) -- confirming the mastery level is on the "
         + "same scale as a character level -- subtracts 4, floors at 16, and combines that with "
         + "a random draw and its argument. The argument is doubled on a 2%% chance "
         + "(rand() %% 100 < 2). What the result feeds is not recovered."},

        // Monster rank, and the two objects that share offset 0x1cd8.
        {"004c1550", "CGObjMob_SetRankSpeedScale",
         "Switches on the monster's rank byte (mob+0x1cd8 & 0xf, copied from refObj+0x50 by "
         + "CGObjMob::vslot_212) and stores a float32 multiplier at mob+0x1cdc: 1.5 for rank 1, "
         + "3.0 for rank 4, 1.7 for rank 6, and 1.0 for ranks 0/3/5/7/8, with an assert on "
         + "anything else. The rank domain 0-8 matches characterdata column 15's rarity values, "
         + "but that correspondence is NOT proven by a use-site and the multiplier is not an "
         + "experience bonus -- see CGObjMob_ApplyRankSpeedScale for what actually consumes it."},
        {"004c1690", "CGObjMob_ApplyRankSpeedScale",
         "CGObjMob vtable slot 215. Multiplies the mob's two movement fields (+0x16c and +0x170) "
         + "by the rank multiplier at +0x1cdc and publishes both into the ParamKeeper as params "
         + "23 and 24 -- 'mov edi,0x17' then 'mov edi,0x18' -- which Char_PublishCombatStats "
         + "already established as the MOVEMENT pair. So the rank multiplier is a movement-speed "
         + "scale: champions and giants move faster. It is not an exp or damage term."},
        {"004e30d0", "GObjPC_RecalcLevelDiffExpScale",
         "Computes the symmetric pair at pc+0x1cd8 / pc+0x1cdc, the first of which "
         + "Formula_MonsterExpReward multiplies a kill's reward by. ref = FUN_0059e870(pc+0xa30), "
         + "a byte; if ref > 0x78 both are set to 1.0f, otherwise "
         + "pc[0x1cd8] = clamp(1 - (charLevel - ref) * 0.1, 0.1, 1.9) and pc[0x1cdc] the mirror. "
         + "K is 'fmul QWORD 0xb45ec0' = 0.1 (a double); the clamp bounds are 0.1 and 1.9. "
         + "Recomputed on exactly three events: CGObjPC::vslot_212, GObjPC_SetLevel and "
         + "Mastery_LevelUp. What the reference byte denotes is NOT recovered -- the mastery "
         + "reading fits (120 is the mastery cap) but has no use-site, so it is not asserted."},

        // RefItemDrop.cpp -- how a kill decides what falls.
        {"00724e30", "RefItemDrop_RollGroupDrop",
         "Rolls a drop group and picks an entry from it. Uses the same per-million roll as the "
         + "assigned-drop path -- two rand() calls combined as (r2<<15)|r1 modulo 1000000, "
         + "because MSVC's rand() yields 15 bits -- and selects by CUMULATIVE weight: "
         + "accumulates round(selectRatio * 1000000.0) across the group's entries (the ratio is "
         + "a float32 at entry+0x24) and takes the first whose running total reaches the roll. A "
         + "group whose ratios do not sum to 1 really can select nothing."},

        {"00724a00", "CRefDropData_AddAssignedItemDrop",
         "Named from its own assert string. Walks the monster ref object's assigned-drop vector "
         + "(0x30-byte records at +0x28c): skips records whose group id at +0 is zero, picks an "
         + "attempt count as rand() %% (max-min+1) + min from the BYTES at +6 and +7, then loops "
         + "that many times rolling DropRatio (float32 at +8) independently each pass against "
         + "(rand()<<15|rand()) %% 1000000 scaled by 'fmul QWORD ds:0xb45bc0' = 1000000.0. So the "
         + "amount fields are an ATTEMPT COUNT, not a stack size."},

        // The kill-reward path: who contributed, how much each share is worth,
        // and the party multiplier on top. See docs/RE_COMPLETION.md.
        {"004106b0", "Formula_ExpShareByDamage",
         "Scales a contributor's share of a kill by the damage it dealt: divides the accumulated "
         + "damage by the victim's MaxHP (vf[0x110]) and clamps to [1e-6, 1.0], the lower bound "
         + "being an epsilon rather than a balance value ('fld DWORD ds:0xb45c84' = 1e-06f). "
         + "Multiplies that by Formula_ExpScaleByLevelWindow, Formula_ExpScaleByLevelDiff, the "
         + "victim's reward and the killer's own multiplier at +0x1cdc. A solo killer's "
         + "accumulated damage exceeds MaxHP, so its share clamps to exactly 1.0. Asserts from "
         + "Formulae.cpp:0x69a."},
        {"00410110", "Formula_ExpRewardForContributor",
         "The sibling of Formula_ExpShareByDamage on the same reward path, returning a 64-bit "
         + "amount. Calls the same two level scalers and asserts from Formulae.cpp:0x5c7."},
        {"004d68c0", "COS_DistributeKillReward",
         "Walks the victim's contributor list twice: the first pass accumulates each "
         + "contributor's damage into entry+0x18 ('add DWORD PTR [eax+0x18],edx'), the second "
         + "calls vtable slot 420 on each PC contributor with that accumulated total. Builds the "
         + "PARTY MULTIPLIER just before each call -- FLD1, then if pc+0x1cb8 (the party field, "
         + "pc[0x72e]) is non-zero, (memberCount-1) * 0.03 + 1.0, both constants read as QWORD "
         + "so both are doubles. That is the 3%-per-extra-member party exp bonus."},
        {"004ea6a0", "GObjPC_ReceiveKillReward",
         "CGObjPC vtable slot 420 (offset 0x690): takes the contributor's accumulated damage as "
         + "arg 2 and the party multiplier as arg 3, runs both Formulae reward functions over "
         + "them, and hands the result on to GObjPC_DistributePartyExp."},

        // ReferenceData.cpp -- the refdata parsing layer. These were found by
        // harvesting assert strings across the whole ReferenceData namespace:
        // each one names the game's own variables, constants and error text, so
        // the names below say what the code demonstrably does rather than
        // guessing an original identifier.
        {"006a8090", "RefItem_ReadTypeIDs",
         "Deserialises an item's five type bytes in order (btCash, btType1..btType4), advancing "
         + "the cursor at +0x1c and counting at +0x28, then bounds-checks each against a named "
         + "constant with the game's own file and line: ReferenceData.cpp:2466-2470, "
         + "'btCash < MAX_CASHITEM_TID_COUNT' (fires when 1 < btCash), "
         + "'btType1 < MAX_TID1_COUNT' (7 <), 'btType2 < MAX_TID2_COUNT' (3 <), "
         + "'btType3 < MAX_TID3_COUNT' (0xf <), 'btType4 < MAX_TID4_COUNT' (0x1f <). So the "
         + "limits are 2, 8, 4, 16, 32 and the field widths are 1, 3, 2, 4 and 5 bits."},
        {"006a61b0", "RefMonsterAssignedItemDrop_ExtractData",
         "Validates a magic option's value against its allowed range. Reports "
         + "'error data that is a magicoption value. [ItemCode: %d, MagicOptionID: %d]' and "
         + "'(%s) error data out of range to MagicoptionValue', from ReferenceData.cpp."},
        {"006a6660", "RefMagicOpt_ResolveExtractor",
         "Resolves the per-MagicType extractor for a magic option and validates its custom "
         + "value. Reports 'can`t find MagicType[%d] extractor!!! [MagicOptID:%d]' and "
         + "'CustomValue(RefMagicOptID[%d]) is error data out of range to MagicoptionValue'."},
        {"006a8d80", "RefScrapOfPackageItem_ExtractData",
         "Checks an item package row's durability, max stack and magic-option level. Reports "
         + "'error data that is a durability or maxstack of a item. [PackageID: %s, ItemCode: %s]' "
         + "and the matching magicoption-level message, both keyed by PackageID and ItemCode."},
        {"006a9840", "RefShop_RegisterGoldPrice",
         "Registers a shop good's gold price. Asserts '(%s) Expandable Items must be set "
         + "StockCount > 0', touches pRefScrap->m_InstanceInfoOfItem.m_dwData, and logs "
         + "'(%s) register gold price.'"},
        {"006a99c0", "RefShop_ReplacePriceWithSilk",
         "Drops a good's other prices in favour of the silk suit: 'Remove all price of (%s) "
         + "except silkprice suit.' and 'insert cost to %s'."},
        {"006a9ab0", "RefShopGoods_ExtractData",
         "Gates a good on being sellable: asserts 'pRefItem != NULL && (pRefItem->m_dwAvailableOPs "
         + "& OBJ_INTERACT_FLAG_CAN_SELL)' and handles the 'MALL_' name prefix."},
        {"006a94a0", "RefShop_InsertPricePolicyLevel",
         "Inserts a price-policy condition keyed by level: 'insert a PricePolicyConditionLevel "
         + "%s', from ReferenceData.cpp."},
        {"006a7650", "RefTeleport_LoadEntry",
         "Loads a teleport reference row -- carries the literal 'TELEPORT' and asserts "
         + "'dwID != 0' from ReferenceData.cpp. Its neighbour 006a7980 asserts the same "
         + "'dwID != 0' and is the sibling loader."},

        // The ParamKeeper registry: where every param's min, max and default
        // come from. Recovering this table settled a whole class of
        // "is this term zero?" questions -- see docs/protocol/param_registry.md.
        {"004b3960", "ParamRegistry_Register",
         "Startup loop that publishes the param descriptor table into the global map keyed by "
         + "param id. Walks a static array of 20-byte records at VA 0x00c64110 -- "
         + "{uint16 id, int32 min, int32 max, int32 default, int32 flag} -- terminated by an id "
         + "of 0xFFFF, 120 entries covering ids 0-259 with gaps. This table is the authoritative "
         + "list of every param that can exist."},
        {"004b2f40", "Param_Init",
         "Initialises one CParam from a descriptor: +0x20 min, +0x24 max, +0x1c value and +0x28 "
         + "default (both from the same argument), +0x2c the flag, and zeroes the four slot "
         + "heads at +0x8/+0xc/+0x10/+0x14. min and max are pinned by EvaluateParam's own CLAMP "
         + "assert, which prints +0x20 as min and +0x24 as max."},
        {"004b3850", "ParamKeeper_EnsureParam",
         "Lazily creates the param for an id at this+4+id*4. The ONLY CParam allocation site in "
         + "the whole binary, and it runs only when the id is present in the registry map -- an "
         + "absent id asserts and creates nothing. The id arrives in DI, not on the stack, which "
         + "is why SetParam call sites decompile without it."},
        {"004b3740", "ParamKeeper_ReadParam",
         "The public param read: asserts if the id is >= 0x200, calls ParamKeeper_EnsureParam, "
         + "asserts again if the param is still null, then TAIL-JUMPS into Param_GetValue with "
         + "the pointer. Param_GetValue dereferences it with no null check, so reading a param "
         + "absent from the registry would fault -- the asserts are the only warning."},
        {"004b33a0", "Param_GetValue",
         "Returns a param's cached value at +0x1c, first calling ParamKeeper_EvaluateParam when "
         + "the dirty byte at +0x1a is set. No null check on the receiver."},

        // The HP/MP pool. Recovered while establishing that passive regeneration
        // does NOT exist server-side: naming every writer was how the negative
        // was made complete. SetCurHP names its own source file in its CLAMP
        // assert, which anchors the pair and the four accessor slots.
        {"004a66f0", "GObjChar_SetCurHP",
         "Clamped current-HP setter. Asserts with its own source path "
         + "d:\\work2005\\source\\silkroadonline\\server\\sr_gameserver\\GObjChar.h line 0x16c "
         + "and the format \"CLAMP() ==> min(%.3f) exceeded max(%.3f) value)\", so the clamp is "
         + "the game's own. Takes the value in EAX, clamps to [0, GetMaxHP()] and writes it "
         + "through charData (pc[0xd]) vtable slot 0x40."},
        {"004a6790", "GObjChar_SetCurMP",
         "Clamped current-MP setter, the twin of GObjChar_SetCurHP in the same GObjChar.h; "
         + "clamps to [0, GetMaxMP()] and writes charData vtable slot 0x44."},
        {"004a87d0", "GObjPC_AdjustHpMp",
         "The generic pool adjustment every gameplay path funnels through: HP delta in EAX, MP "
         + "delta in param_2, and a notify bitmask in param_3 OR'd into pc+0xa0e. Returns early "
         + "unless vf[0xf8] says alive, and skips each half when its delta is zero -- which is "
         + "why CGObjChar::vslot_318 calling it as (0, amount) is MP-only. Establishes the four "
         + "pool accessor slots by use: vf[0x108] GetCurHP, vf[0x10c] GetCurMP, vf[0x110] "
         + "GetMaxHP, vf[0x114] GetMaxMP."},
        {"004a86a0", "GObjPC_RecoverHpMp",
         "The recovery path potions and heal skills reach: separate HP (arg 2) and MP (arg 3) "
         + "amounts, each passed through FUN_004b3740/FUN_009fbb40 before use, then handed to "
         + "GObjPC_AdjustHpMp with the notify mask. When a scaled amount differs from the one "
         + "asked for it reports through vf[0x15c] with a name constant (&DAT_00aebec0 for the "
         + "HP half, &DAT_00aebedc for the MP half). Ghidra drops the HP argument here because "
         + "it travels in EAX."},
        {"004e6330", "CGObjPC_PublishHpMp",
         "Vtable slot 310 (offset 0x4d8). Clamps current HP down when it exceeds max, then "
         + "builds the update packet from a flag byte: bit 0 sends GetCurHP, bit 1 GetCurMP, "
         + "bit 2 defers to GObjPC::FUN_004a5a50. A notifier, not a source of healing."},
        {"005829d0", "GObjPC_OnEffectExpired",
         "Buff/effect teardown, called three times from FUN_005830b0. Where the expiring effect "
         + "touched MaxHP (effect+0x368) or MaxMP (+0x36c) it re-clamps the current pool down to "
         + "the reduced maximum via GObjChar_SetCurHP/SetCurMP. This is the second-largest "
         + "consumer of the pool setters and contains no healing."},
        {"004e1120", "GObjPC_RestorePoolOnLoad",
         "Login/respawn pool restore. When charData's vf[0x38]/vf[0x3c] report the stored pool "
         + "as zero, seeds it with GetParam(3)=MaxHP and GetParam(4)=MaxMP scaled by the double "
         + "at 0x00b460f0 -- the recovered 0.4 respawn fraction. Writes charData slots 0x40/0x44 "
         + "DIRECTLY rather than through the clamped setters, because at load time there is no "
         + "valid current value to clamp against."},
    };

    // The client binary's proven functions. Fewer, because the client asserts
    // with __FILE__ and an expression rather than Class::Method, so far less of
    // it names itself -- 17 functions against the server's 533.
    private static final String[][] KNOWN_CLIENT = {
        // --- Refdata record parsers, one per textdata type. ---
        // Client_LoadAllRefData pushes a type id beside each filename and
        // Client_LoadRefDataFile switches on it; a function appearing in
        // exactly one case AND reading many sequential tokens is that file's
        // record parser. Each is therefore an exact column map -- the cheap way
        // to answer a column question. The expensive way is counting stores in
        // the server's own parser, which is how this project came to assume
        // leveldata was packed in column order. It is not.
        {"005339f0", "RefParse_atstructeffect",
         "Parses one atstructeffect.txt record (refdata type 57). Reads its columns as SEQUENTIAL "
         + "tokens and stores each at a fixed struct offset, so this function IS that file's "
         + "column map -- read it rather than counting stores in the server, and note that the "
         + "columns are NOT stored in offset order."},
        {"0062aba0", "RefParse_siegefortressreward",
         "Parses one siegefortressreward.txt record (refdata type 102). Reads its columns as SEQUENTIAL "
         + "tokens and stores each at a fixed struct offset, so this function IS that file's "
         + "column map -- read it rather than counting stores in the server, and note that the "
         + "columns are NOT stored in offset order."},
        {"0062c170", "RefParse_worldmap_mapinfo",
         "Parses one worldmap_mapinfo.txt record (refdata type 3). Reads its columns as SEQUENTIAL "
         + "tokens and stores each at a fixed struct offset, so this function IS that file's "
         + "column map -- read it rather than counting stores in the server, and note that the "
         + "columns are NOT stored in offset order."},
        {"006d5570", "RefParse_fmntidgroupmapdata",
         "Parses one fmntidgroupmapdata.txt record (refdata type 34). Reads its columns as SEQUENTIAL "
         + "tokens and stores each at a fixed struct offset, so this function IS that file's "
         + "column map -- read it rather than counting stores in the server, and note that the "
         + "columns are NOT stored in offset order."},
        {"00744bd0", "RefParse_gachaitemset",
         "Parses one gachaitemset.txt record (refdata type 30). Reads its columns as SEQUENTIAL "
         + "tokens and stores each at a fixed struct offset, so this function IS that file's "
         + "column map -- read it rather than counting stores in the server, and note that the "
         + "columns are NOT stored in offset order."},
        {"00745100", "RefParse_refgachatreeforclientuidata",
         "Parses one refgachatreeforclientuidata.txt record (refdata type 67). Reads its columns as SEQUENTIAL "
         + "tokens and stores each at a fixed struct offset, so this function IS that file's "
         + "column map -- read it rather than counting stores in the server, and note that the "
         + "columns are NOT stored in offset order."},
        {"00745530", "RefParse_gachanpcmap",
         "Parses one gachanpcmap.txt record (refdata type 31). Reads its columns as SEQUENTIAL "
         + "tokens and stores each at a fixed struct offset, so this function IS that file's "
         + "column map -- read it rather than counting stores in the server, and note that the "
         + "columns are NOT stored in offset order."},
        {"00750620", "RefParse_siegefortress",
         "Parses one siegefortress.txt record (refdata type 54). Reads its columns as SEQUENTIAL "
         + "tokens and stores each at a fixed struct offset, so this function IS that file's "
         + "column map -- read it rather than counting stores in the server, and note that the "
         + "columns are NOT stored in offset order."},
        {"00753400", "RefParse_gameworlddata",
         "Parses one gameworlddata.txt record (refdata type 56). Reads its columns as SEQUENTIAL "
         + "tokens and stores each at a fixed struct offset, so this function IS that file's "
         + "column map -- read it rather than counting stores in the server, and note that the "
         + "columns are NOT stored in offset order."},
        {"0096f280", "RefParse_worldmap_localinfo",
         "Parses one worldmap_localinfo.txt record (refdata type 4). Reads its columns as SEQUENTIAL "
         + "tokens and stores each at a fixed struct offset, so this function IS that file's "
         + "column map -- read it rather than counting stores in the server, and note that the "
         + "columns are NOT stored in offset order."},
        {"0096f680", "RefParse_worldmap_mapinfo_f680",
         "Parses one worldmap_mapinfo.txt record (refdata type 3). Reads its columns as SEQUENTIAL "
         + "tokens and stores each at a fixed struct offset, so this function IS that file's "
         + "column map -- read it rather than counting stores in the server, and note that the "
         + "columns are NOT stored in offset order."},
        {"0096fbf0", "RefParse_worldmapguidedata",
         "Parses one worldmapguidedata.txt record (refdata type 89). Reads its columns as SEQUENTIAL "
         + "tokens and stores each at a fixed struct offset, so this function IS that file's "
         + "column map -- read it rather than counting stores in the server, and note that the "
         + "columns are NOT stored in offset order."},
        {"00976840", "RefParse_teleportdata",
         "Parses one teleportdata.txt record (refdata type 18). Reads its columns as SEQUENTIAL "
         + "tokens and stores each at a fixed struct offset, so this function IS that file's "
         + "column map -- read it rather than counting stores in the server, and note that the "
         + "columns are NOT stored in offset order."},
        {"00976c80", "RefParse_teleportlink",
         "Parses one teleportlink.txt record (refdata type 19). Reads its columns as SEQUENTIAL "
         + "tokens and stores each at a fixed struct offset, so this function IS that file's "
         + "column map -- read it rather than counting stores in the server, and note that the "
         + "columns are NOT stored in offset order."},
        {"00976e60", "RefParse_actionwnddata",
         "Parses one actionwnddata.txt record (refdata type 9). Reads its columns as SEQUENTIAL "
         + "tokens and stores each at a fixed struct offset, so this function IS that file's "
         + "column map -- read it rather than counting stores in the server, and note that the "
         + "columns are NOT stored in offset order."},
        {"00976fc0", "RefParse_dg",
         "Parses one dg.txt record (refdata type 28). Reads its columns as SEQUENTIAL "
         + "tokens and stores each at a fixed struct offset, so this function IS that file's "
         + "column map -- read it rather than counting stores in the server, and note that the "
         + "columns are NOT stored in offset order."},
        {"00978020", "RefParse_gameguidedata",
         "Parses one gameguidedata.txt record (refdata type 6). Reads its columns as SEQUENTIAL "
         + "tokens and stores each at a fixed struct offset, so this function IS that file's "
         + "column map -- read it rather than counting stores in the server, and note that the "
         + "columns are NOT stored in offset order."},
        {"0097aab0", "RefParse_leveldata",
         "Parses one leveldata.txt record (refdata type 8). Reads its columns as SEQUENTIAL "
         + "tokens and stores each at a fixed struct offset, so this function IS that file's "
         + "column map -- read it rather than counting stores in the server, and note that the "
         + "columns are NOT stored in offset order."},
        {"0097aba0", "RefParse_levelgold",
         "Parses one levelgold.txt record (refdata type 32). Reads its columns as SEQUENTIAL "
         + "tokens and stores each at a fixed struct offset, so this function IS that file's "
         + "column map -- read it rather than counting stores in the server, and note that the "
         + "columns are NOT stored in offset order."},
        {"0097acc0", "RefParse_magicoptionassign",
         "Parses one magicoptionassign.txt record (refdata type 66). Reads its columns as SEQUENTIAL "
         + "tokens and stores each at a fixed struct offset, so this function IS that file's "
         + "column map -- read it rather than counting stores in the server, and note that the "
         + "columns are NOT stored in offset order."},
        {"0097aeb0", "RefParse_refmagicoptgroup",
         "Parses one refmagicoptgroup.txt record (refdata type 91). Reads its columns as SEQUENTIAL "
         + "tokens and stores each at a fixed struct offset, so this function IS that file's "
         + "column map -- read it rather than counting stores in the server, and note that the "
         + "columns are NOT stored in offset order."},
        {"0097b0b0", "RefParse_magicoption",
         "Parses one magicoption.txt record (refdata type 24). Reads its columns as SEQUENTIAL "
         + "tokens and stores each at a fixed struct offset, so this function IS that file's "
         + "column map -- read it rather than counting stores in the server, and note that the "
         + "columns are NOT stored in offset order."},
        {"0097f2e0", "RefParse_refeventreward",
         "Parses one refeventreward.txt record (refdata type 101). Reads its columns as SEQUENTIAL "
         + "tokens and stores each at a fixed struct offset, so this function IS that file's "
         + "column map -- read it rather than counting stores in the server, and note that the "
         + "columns are NOT stored in offset order."},
        {"0097fbe0", "RefParse_mallitemmenulistdata",
         "Parses one mallitemmenulistdata.txt record (refdata type 85). Reads its columns as SEQUENTIAL "
         + "tokens and stores each at a fixed struct offset, so this function IS that file's "
         + "column map -- read it rather than counting stores in the server, and note that the "
         + "columns are NOT stored in offset order."},
        {"0097fe30", "RefParse_refaccesspermissionofshop",
         "Parses one refaccesspermissionofshop.txt record (refdata type 43). Reads its columns as SEQUENTIAL "
         + "tokens and stores each at a fixed struct offset, so this function IS that file's "
         + "column map -- read it rather than counting stores in the server, and note that the "
         + "columns are NOT stored in offset order."},
        {"00980030", "RefParse_refconditiontobuyscrapitem",
         "Parses one refconditiontobuyscrapitem.txt record (refdata type 49). Reads its columns as SEQUENTIAL "
         + "tokens and stores each at a fixed struct offset, so this function IS that file's "
         + "column map -- read it rather than counting stores in the server, and note that the "
         + "columns are NOT stored in offset order."},
        {"009802b0", "RefParse_refconditiontosellpackageitem",
         "Parses one refconditiontosellpackageitem.txt record (refdata type 48). Reads its columns as SEQUENTIAL "
         + "tokens and stores each at a fixed struct offset, so this function IS that file's "
         + "column map -- read it rather than counting stores in the server, and note that the "
         + "columns are NOT stored in offset order."},
        {"009804b0", "RefParse_refconditiontosellscrapitem",
         "Parses one refconditiontosellscrapitem.txt record (refdata type 50). Reads its columns as SEQUENTIAL "
         + "tokens and stores each at a fixed struct offset, so this function IS that file's "
         + "column map -- read it rather than counting stores in the server, and note that the "
         + "columns are NOT stored in offset order."},
        {"009811f0", "RefParse_refpackageitem",
         "Parses one refpackageitem.txt record (refdata type 39). Reads its columns as SEQUENTIAL "
         + "tokens and stores each at a fixed struct offset, so this function IS that file's "
         + "column map -- read it rather than counting stores in the server, and note that the "
         + "columns are NOT stored in offset order."},
        {"00981ba0", "RefParse_refpricepolicyofitem",
         "Parses one refpricepolicyofitem.txt record (refdata type 42). Reads its columns as SEQUENTIAL "
         + "tokens and stores each at a fixed struct offset, so this function IS that file's "
         + "column map -- read it rather than counting stores in the server, and note that the "
         + "columns are NOT stored in offset order."},
        {"00981ce0", "RefParse_refrewardpolicytobuyscrapitem",
         "Parses one refrewardpolicytobuyscrapitem.txt record (refdata type 45). Reads its columns as SEQUENTIAL "
         + "tokens and stores each at a fixed struct offset, so this function IS that file's "
         + "column map -- read it rather than counting stores in the server, and note that the "
         + "columns are NOT stored in offset order."},
        {"00981f40", "RefParse_refrewardpolicytosellpackageitem",
         "Parses one refrewardpolicytosellpackageitem.txt record (refdata type 46). Reads its columns as SEQUENTIAL "
         + "tokens and stores each at a fixed struct offset, so this function IS that file's "
         + "column map -- read it rather than counting stores in the server, and note that the "
         + "columns are NOT stored in offset order."},
        {"00982150", "RefParse_refrewardpolicytosellscrapitem",
         "Parses one refrewardpolicytosellscrapitem.txt record (refdata type 47). Reads its columns as SEQUENTIAL "
         + "tokens and stores each at a fixed struct offset, so this function IS that file's "
         + "column map -- read it rather than counting stores in the server, and note that the "
         + "columns are NOT stored in offset order."},
        {"009824e0", "RefParse_refscrapofpackageitem",
         "Parses one refscrapofpackageitem.txt record (refdata type 41). Reads its columns as SEQUENTIAL "
         + "tokens and stores each at a fixed struct offset, so this function IS that file's "
         + "column map -- read it rather than counting stores in the server, and note that the "
         + "columns are NOT stored in offset order."},
        {"00983000", "RefParse_refshop",
         "Parses one refshop.txt record (refdata type 35). Reads its columns as SEQUENTIAL "
         + "tokens and stores each at a fixed struct offset, so this function IS that file's "
         + "column map -- read it rather than counting stores in the server, and note that the "
         + "columns are NOT stored in offset order."},
        {"00983b70", "RefParse_refshopgoods",
         "Parses one refshopgoods.txt record (refdata type 40). Reads its columns as SEQUENTIAL "
         + "tokens and stores each at a fixed struct offset, so this function IS that file's "
         + "column map -- read it rather than counting stores in the server, and note that the "
         + "columns are NOT stored in offset order."},
        {"009842e0", "RefParse_refshopgroup",
         "Parses one refshopgroup.txt record (refdata type 52). Reads its columns as SEQUENTIAL "
         + "tokens and stores each at a fixed struct offset, so this function IS that file's "
         + "column map -- read it rather than counting stores in the server, and note that the "
         + "columns are NOT stored in offset order."},
        {"00986700", "RefParse_reftreatitemofshop",
         "Parses one reftreatitemofshop.txt record (refdata type 44). Reads its columns as SEQUENTIAL "
         + "tokens and stores each at a fixed struct offset, so this function IS that file's "
         + "column map -- read it rather than counting stores in the server, and note that the "
         + "columns are NOT stored in offset order."},
        {"009869f0", "RefParse_refshopitemstockperiod",
         "Parses one refshopitemstockperiod.txt record (refdata type 86). Reads its columns as SEQUENTIAL "
         + "tokens and stores each at a fixed struct offset, so this function IS that file's "
         + "column map -- read it rather than counting stores in the server, and note that the "
         + "columns are NOT stored in offset order."},
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
