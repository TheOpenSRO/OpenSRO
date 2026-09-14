// What does this program actually know the names of, and what is left?
//
// "Understand every function" needs a denominator before it needs effort. A
// stripped MSVC binary is mostly not game logic: it is CRT and STL template
// instantiations, thunks and stubs. This counts what is already named, what
// Ghidra's own analysers can name (RTTI classes, demangled symbols), and what
// is genuinely unknown game code -- so work goes at the last group.
//
// Usage: -postScript SymbolReport.java [maxExamples]
import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionIterator;
import ghidra.program.model.symbol.SourceType;

import java.util.ArrayList;
import java.util.List;

public class SymbolReport extends GhidraScript {

    public void run() throws Exception {
        String[] args = getScriptArgs();
        int maxEx = args.length > 0 ? Integer.parseInt(args[0]) : 15;

        int total = 0, defaultNamed = 0, realNamed = 0, thunks = 0, tiny = 0;
        int demangled = 0, classScoped = 0;
        List<String> examples = new ArrayList<>();

        FunctionIterator it = currentProgram.getFunctionManager().getFunctions(true);
        while (it.hasNext() && !monitor.isCancelled()) {
            Function f = it.next();
            total++;
            if (f.isThunk()) thunks++;
            long size = f.getBody().getNumAddresses();
            if (size < 16) tiny++;

            String n = f.getName();
            SourceType st = f.getSymbol() == null ? SourceType.DEFAULT : f.getSymbol().getSource();
            boolean isDefault = st == SourceType.DEFAULT || n.startsWith("FUN_");
            if (isDefault) {
                defaultNamed++;
            } else {
                realNamed++;
                // A demangled MSVC symbol keeps its scope, so "A::B" means the
                // class structure survived rather than just a guessed label.
                if (n.contains("::")) classScoped++;
                if (n.startsWith("?") || n.contains("@@")) demangled++;
                if (examples.size() < maxEx) examples.add(f.getEntryPoint() + "  " + f.getName(true));
            }
        }

        println("===SYMREPORT===");
        println("  total functions      : " + total);
        println("  already named        : " + realNamed);
        println("    class-scoped (A::B): " + classScoped);
        println("    mangled remnants   : " + demangled);
        println("  default FUN_ names   : " + defaultNamed);
        println("  thunks               : " + thunks);
        println("  tiny (<16 bytes)     : " + tiny);
        for (String e : examples) println("  eg " + e);
        println("===SYMDONE===");
    }
}
