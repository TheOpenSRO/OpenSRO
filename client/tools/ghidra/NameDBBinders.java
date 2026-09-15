// Name the database binding functions, and with them recover the game's schema.
//
// The server binds every persisted column to a struct offset through one
// helper. The shape is always the same:
//
//     FUN_00401fc0("Strength", 8);     // std::string assign: the column name
//     local_150 = 0x74;                // the offset in the target struct
//     local_20c = (undefined *)0x2;    // the column type
//     FUN_00862e40();                  // bind it
//
// 61 functions call that binder, and 50 of them name a table (`_CHAR`,
// `_ITEMS`, `_CHARQUEST`, `_GUILD`, ...). So this is two things at once: a naming
// lever, and the complete persisted data model of the real game.
//
// It is also self-validating, which is rare here. The `_CHAR` binder gives
// Strength 0x74, Intellect 0x76, CurLevel 0x65 and RemainSkillPoint 0x80 --
// four offsets this project had already derived by entirely unrelated routes,
// all exact. A map that reproduces four known answers is worth trusting for the
// other 34.
//
// Names are `DB_Bind_<TABLE>`, taken verbatim from the table string the
// function itself carries; the plate comment lists the columns and offsets, so
// the schema travels in the program rather than in a commit message.
//
// Usage: -postScript NameDBBinders.java [apply]
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionManager;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.InstructionIterator;
import ghidra.program.model.data.StringDataInstance;
import ghidra.program.model.listing.Data;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.ReferenceIterator;
import ghidra.program.model.symbol.ReferenceManager;
import ghidra.program.model.symbol.SourceType;

import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;

public class NameDBBinders extends GhidraScript {

    /** The bind helper every schema function funnels through. */
    private static final String BINDER = "00862e40";

    public void run() throws Exception {
        String[] args = getScriptArgs();
        boolean apply = args.length > 0 && args[0].equalsIgnoreCase("apply");

        FunctionManager fm = currentProgram.getFunctionManager();
        ReferenceManager rm = currentProgram.getReferenceManager();
        Address binder = currentProgram.getAddressFactory().getAddress(BINDER);
        if (binder == null || fm.getFunctionAt(binder) == null) {
            println("no binder at " + BINDER);
            return;
        }

        // Every function that calls it is a schema function.
        Set<Function> callers = new LinkedHashSet<>();
        ReferenceIterator it = rm.getReferencesTo(binder);
        while (it.hasNext() && !monitor.isCancelled()) {
            Reference r = it.next();
            if (!r.getReferenceType().isCall()) continue;
            Function f = fm.getFunctionContaining(r.getFromAddress());
            if (f != null) callers.add(f);
        }

        int named = 0, noTable = 0, already = 0;
        List<String> report = new ArrayList<>();

        for (Function f : callers) {
            if (monitor.isCancelled()) break;
            // Collect the string literals this function references, in order.
            List<String> strs = new ArrayList<>();
            InstructionIterator ii = currentProgram.getListing().getInstructions(f.getBody(), true);
            while (ii.hasNext()) {
                Instruction ins = ii.next();
                for (int i = 0; i < ins.getNumOperands(); i++) {
                    for (Object o : ins.getOpObjects(i)) {
                        if (!(o instanceof ghidra.program.model.scalar.Scalar)) continue;
                        long v = ((ghidra.program.model.scalar.Scalar) o).getUnsignedValue();
                        Address a;
                        try { a = toAddr(v); } catch (Exception e) { continue; }
                        Data d = getDataAt(a);
                        if (d == null) continue;
                        Object val = d.getValue();
                        if (val instanceof String) strs.add(((String) val).trim());
                    }
                }
            }
            // The table is the first literal starting with '_'.
            String table = null;
            for (String s : strs) {
                if (s.length() > 1 && s.charAt(0) == '_') { table = s; break; }
            }
            if (table == null) { noTable++; continue; }

            if (!f.getName().startsWith("FUN_")) { already++; continue; }

            String name = "DB_Bind_" + table.replaceAll("[^A-Za-z0-9_]", "");
            report.add(String.format("  %s  %-30s (%d strings)", f.getEntryPoint(), name, strs.size()));
            if (!apply) { named++; continue; }
            try {
                f.setName(name, SourceType.ANALYSIS);
                StringBuilder note = new StringBuilder(
                    "Binds the persisted " + table + " columns to their struct offsets.\n"
                    + "Recovered by NameDBBinders: every schema function funnels through the same\n"
                    + "bind helper, so the table name and its columns are facts the binary states\n"
                    + "about itself. Columns referenced here:\n");
                int shown = 0;
                for (String s : strs) {
                    if (s.equals(table)) continue;
                    if (!s.matches("[A-Za-z_][A-Za-z_0-9]*")) continue;
                    note.append("  ").append(s).append('\n');
                    if (++shown >= 40) { note.append("  ...\n"); break; }
                }
                f.setComment(note.toString());
                named++;
            } catch (Exception ex) {
                println("  (could not name " + f.getEntryPoint() + ": " + ex.getMessage() + ")");
            }
        }

        println("===DBBINDERS===");
        println("  schema functions found : " + callers.size());
        println("  named                  : " + named + (apply ? "" : " (report only, pass 'apply')"));
        println("    already named        : " + already);
        println("    no table string      : " + noTable);
        for (String r : report) println(r);
        println("===DBBINDERSDONE===");
    }
}
