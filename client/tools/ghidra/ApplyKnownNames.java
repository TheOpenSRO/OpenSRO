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

        // Pick the table that belongs to the program being processed.
        String prog = currentProgram.getName().toLowerCase();
        String[][] table = prog.contains("client") ? KNOWN_CLIENT : KNOWN;
        println("  program=" + currentProgram.getName() + " entries=" + table.length);

        int done = 0, missing = 0, skipped = 0;
        for (String[] k : table) {
            Address a = currentProgram.getAddressFactory().getAddress(k[0]);
            Function f = a == null ? null : currentProgram.getFunctionManager().getFunctionAt(a);
            if (f == null) { println("  no function at " + k[0]); missing++; continue; }
            // Never clobber a name that came from the binary's own assert string.
            if (!f.getName().startsWith("FUN_")) {
                println("  " + k[0] + " already named " + f.getName() + " -- leaving it");
                skipped++;
                continue;
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
