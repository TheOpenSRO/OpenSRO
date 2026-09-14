// Find who calls a function -- the other half of FindOffsetRefs. Once a helper
// is identified (a formula, a setter), its call sites are usually the code you
// actually wanted, and in a stripped binary there is no symbol to grep for.
//
// Usage: -postScript FnXref.java <addrs> [max] [mode]
//   <addrs>  one or a comma-separated list of function addresses (hex, with or
//            without 0x), e.g. 0040f5f0,004106b0
//   [max]    cap on call sites listed per function (default 40)
//   [mode]   "all" (default) lists sites; "decomp" also decompiles each
//            distinct calling function (capped at [max])
//
// Prints the calling function's entry so it can be fed straight to
// DecompDump.java ... addr.
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionManager;
import ghidra.program.model.symbol.RefType;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.ReferenceIterator;
import ghidra.program.model.symbol.ReferenceManager;

import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;

public class FnXref extends GhidraScript {

    public void run() throws Exception {
        String[] args = getScriptArgs();
        String spec = args.length > 0 ? args[0] : "";
        int max = args.length > 1 ? Integer.parseInt(args[1]) : 40;
        String mode = args.length > 2 ? args[2] : "all";

        ReferenceManager rm = currentProgram.getReferenceManager();
        FunctionManager fm = currentProgram.getFunctionManager();
        LinkedHashSet<Function> callers = new LinkedHashSet<>();

        for (String part : spec.split(",")) {
            String s = part.trim();
            if (s.isEmpty()) continue;
            if (s.startsWith("0x") || s.startsWith("0X")) s = s.substring(2);
            Address target = currentProgram.getAddressFactory().getAddress(s);
            if (target == null) { println("  (bad address " + part + ")"); continue; }

            Function callee = fm.getFunctionContaining(target);
            String name = callee == null ? "(no function)" : callee.getName(true);
            List<String> sites = new ArrayList<>();
            int total = 0;

            ReferenceIterator it = rm.getReferencesTo(target);
            while (it.hasNext() && !monitor.isCancelled()) {
                Reference ref = it.next();
                RefType rt = ref.getReferenceType();
                // Calls and jumps into it; data refs (vtable slots) count too,
                // since a virtual method is reached through its table.
                if (!(rt.isCall() || rt.isJump() || rt.isData())) continue;
                total++;
                Address from = ref.getFromAddress();
                Function f = fm.getFunctionContaining(from);
                if (f != null) callers.add(f);
                if (sites.size() < max) {
                    sites.add("  " + from + " " + rt.getName()
                            + " fn=" + (f == null ? "(none)" : f.getEntryPoint().toString()));
                }
            }
            println("===CALLERS=== " + target + " (" + name + ") sites=" + total
                    + (total > max ? " (listing first " + max + ")" : ""));
            for (String s2 : sites) println(s2);
        }

        if (mode.equals("decomp")) {
            DecompInterface d = new DecompInterface();
            d.openProgram(currentProgram);
            int n = 0;
            for (Function f : callers) {
                println("===FUNC=== " + f.getName(true) + " @ " + f.getEntryPoint());
                DecompileResults r = d.decompileFunction(f, 90, monitor);
                if (r != null && r.decompileCompleted()) println(r.getDecompiledFunction().getC());
                else println("  (decompile failed)");
                if (++n >= max) break;
            }
        }
        println("===XREFDONE=== spec=" + spec + " distinctCallers=" + callers.size());
    }
}
