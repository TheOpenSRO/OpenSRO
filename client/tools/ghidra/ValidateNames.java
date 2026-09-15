// Check bulk-applied names against a signal the name did NOT come from.
//
// Naming from a pattern is this project's highest-leverage technique and its
// most dangerous one, for the same reason: one inference is applied hundreds of
// times, and the per-name evidence is never re-read. That is not hypothetical.
// The opcode-tree pass named FUN_00964b60 `MsgHandler_7d1b`; it is the assert
// helper, with 10,357 call sites, the most-called function in either binary. It
// sat wrong for three ticks and was found by accident.
//
// The fix is cheap: every bulk pass has a property its members must have, which
// is INDEPENDENT of how they were named.
//
//   DB_Bind_*     must call the column-bind helper (0x00862e40).
//   MsgHandler_*  must have few callers. A packet handler has ~2; the assert
//                 helper had five thousand times more, which is the single
//                 check that would have caught it.
//   RefParse_*    must read several sequential refdata tokens (0x00b9cc80 /
//                 0x00b9ce10 on the client).
//   QuestHandler_*, Formula_*, ParamKeeper_*, GObj*  are hand-named with
//                 citations and are not checked here -- they were reasoned about
//                 one at a time, which is the thing bulk naming skips.
//
// Reports outliers rather than fixing them: a violation means the evidence needs
// re-reading, not that the name is automatically wrong.
//
// Usage: -postScript ValidateNames.java [maxReport]
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionIterator;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.InstructionIterator;

import java.util.ArrayList;
import java.util.List;

public class ValidateNames extends GhidraScript {

    private boolean calls(Function f, String targetHex) {
        Address t;
        try { t = currentProgram.getAddressFactory().getAddress(targetHex); }
        catch (Exception e) { return false; }
        if (t == null) return false;
        InstructionIterator it = currentProgram.getListing().getInstructions(f.getBody(), true);
        while (it.hasNext()) {
            Instruction ins = it.next();
            if (ins.getFlowType() == null || !ins.getFlowType().isCall()) continue;
            for (Address a : ins.getFlows()) if (a.equals(t)) return true;
        }
        return false;
    }

    private int countTokenReads(Function f) {
        int n = 0;
        InstructionIterator it = currentProgram.getListing().getInstructions(f.getBody(), true);
        while (it.hasNext()) {
            Instruction ins = it.next();
            if (ins.getFlowType() == null || !ins.getFlowType().isCall()) continue;
            for (Address a : ins.getFlows()) {
                String s = a.toString();
                if (s.endsWith("00b9cc80") || s.endsWith("00b9ce10")) n++;
            }
        }
        return n;
    }

    public void run() throws Exception {
        String[] args = getScriptArgs();
        int maxReport = args.length > 0 ? Integer.parseInt(args[0]) : 40;

        int dbOK = 0, dbBad = 0, msgOK = 0, msgBad = 0, parseOK = 0, parseBad = 0;
        List<String> bad = new ArrayList<>();

        FunctionIterator it = currentProgram.getFunctionManager().getFunctions(true);
        while (it.hasNext() && !monitor.isCancelled()) {
            Function f = it.next();
            String n = f.getName();

            if (n.startsWith("DB_Bind_")) {
                if (calls(f, "00862e40")) dbOK++;
                else { dbBad++; bad.add("  " + f.getEntryPoint() + "  " + n
                        + "   does NOT call the column-bind helper"); }

            } else if (n.startsWith("MsgHandler_")) {
                int callers = f.getCallingFunctions(monitor).size();
                if (callers <= 10) msgOK++;
                else { msgBad++; bad.add("  " + f.getEntryPoint() + "  " + n
                        + "   has " + callers + " callers -- far too many for a packet handler"); }

            } else if (n.startsWith("RefParse_")) {
                int t = countTokenReads(f);
                if (t >= 3) parseOK++;
                else { parseBad++; bad.add("  " + f.getEntryPoint() + "  " + n
                        + "   reads only " + t + " sequential tokens"); }
            }
        }

        println("===VALIDATENAMES===");
        println(String.format("  DB_Bind_*     ok %d   SUSPECT %d", dbOK, dbBad));
        println(String.format("  MsgHandler_*  ok %d   SUSPECT %d", msgOK, msgBad));
        println(String.format("  RefParse_*    ok %d   SUSPECT %d", parseOK, parseBad));
        if (bad.isEmpty()) println("  no outliers");
        int shown = 0;
        for (String b : bad) {
            println(b);
            if (++shown >= maxReport) { println("  ... " + (bad.size() - shown) + " more"); break; }
        }
        println("===VALIDATENAMESDONE===");
    }
}
