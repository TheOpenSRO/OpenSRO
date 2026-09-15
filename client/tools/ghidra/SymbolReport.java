// What does this program actually know the names of, and what is left?
//
// "Understand every function" needs a denominator before it needs effort. A
// stripped MSVC binary is mostly not game logic: it is CRT and STL template
// instantiations, thunks and stubs. This counts what is already named, what is
// merely attributed to a module, and what is genuinely unknown -- so work goes
// at the last group.
//
// Three-way, deliberately, because two of these are different kinds of knowing:
//
//   NAMED     the function has a real name, from Ghidra's FID signatures, from
//             an assert string that spelled out Class::Method, or applied by
//             hand with evidence (ApplyKnownNames.java).
//   ATTRIBUTED the name is still FUN_xxxxxxxx, but the function sits in a
//             namespace taken from the __FILE__ string it asserts with -- so
//             the module is known and the identity is not. Real progress, and
//             not the same thing as a name; counting it as one would flatter
//             the number.
//   UNKNOWN   neither.
//
// An earlier version of this script reported "class-scoped (A::B): 0" while its
// own example lines printed GParamKeeper::... -- it tested getName(), which is
// the unqualified name, where the namespace lives on getParentNamespace(). The
// effect was to undercount coverage and mislabel every attributed function as
// untouched. Namespace and name are separate; check them separately.
//
// Usage: -postScript SymbolReport.java [maxExamples]
import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionIterator;
import ghidra.program.model.symbol.Namespace;
import ghidra.program.model.symbol.SourceType;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

public class SymbolReport extends GhidraScript {

    public void run() throws Exception {
        String[] args = getScriptArgs();
        int maxEx = args.length > 0 ? Integer.parseInt(args[0]) : 15;

        int total = 0, named = 0, attributed = 0, unknown = 0;
        int thunks = 0, tiny = 0, demangled = 0;
        int bodyUnknown = 0;   // unknown AND not a thunk AND not tiny
        Map<String, Integer> modules = new HashMap<>();
        List<String> examples = new ArrayList<>();

        FunctionIterator it = currentProgram.getFunctionManager().getFunctions(true);
        while (it.hasNext() && !monitor.isCancelled()) {
            Function f = it.next();
            total++;
            boolean isThunk = f.isThunk();
            boolean isTiny = f.getBody().getNumAddresses() < 16;
            if (isThunk) thunks++;
            if (isTiny) tiny++;

            String n = f.getName();
            SourceType st = f.getSymbol() == null ? SourceType.DEFAULT : f.getSymbol().getSource();
            boolean hasName = !(st == SourceType.DEFAULT || n.startsWith("FUN_"));

            Namespace ns = f.getParentNamespace();
            boolean hasModule = ns != null && !ns.isGlobal();
            if (hasModule) modules.merge(ns.getName(), 1, Integer::sum);

            if (hasName) {
                named++;
                if (n.startsWith("?") || n.contains("@@")) demangled++;
                if (examples.size() < maxEx) examples.add(f.getEntryPoint() + "  " + f.getName(true));
            } else if (hasModule) {
                attributed++;
            } else {
                unknown++;
                if (!isThunk && !isTiny) bodyUnknown++;
            }
        }

        int identified = named + attributed;
        println("===SYMREPORT===");
        println("  total functions        : " + total);
        println("  NAMED (real name)      : " + named);
        println("    mangled remnants     : " + demangled);
        println("  ATTRIBUTED (module only): " + attributed
                + "  across " + modules.size() + " modules");
        println("  UNKNOWN                : " + unknown);
        println(String.format("  identified             : %d  (%.1f%%)",
                identified, 100.0 * identified / Math.max(1, total)));
        println("  -- of the unknown --");
        println("    thunks               : " + thunks);
        println("    tiny (<16 bytes)     : " + tiny);
        println("    real bodies left     : " + bodyUnknown);
        for (String e : examples) println("  eg " + e);
        println("===SYMDONE===");
    }
}
