// Check interpolated module attribution against the call graph.
//
// InterpolateModules assigns a module from ADDRESS ADJACENCY: an unattributed
// function bracketed by the same module on both sides is taken to be that
// module too. That is a sound heuristic -- MSVC emits a translation unit
// contiguously -- but it is still a heuristic applied ~1,000 times per pass
// without anything re-reading the individual cases.
//
// The call graph is an independent signal. A function really belonging to
// module M usually calls, or is called by, other functions in M. One with NO
// call-graph connection to its assigned module is not necessarily wrong -- a
// leaf helper called only through a vtable would look like that -- but it is
// the population worth looking at, and a high rate of them would mean the
// address heuristic is reaching too far.
//
// Reports rather than reverts. The point is to learn whether the heuristic is
// sound at the gap size in use, not to churn names.
//
// Usage: -postScript ValidateAttribution.java [maxReport]
import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionIterator;
import ghidra.program.model.symbol.Namespace;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;

public class ValidateAttribution extends GhidraScript {

    private String mod(Function f) {
        if (f == null) return null;
        Namespace ns = f.getParentNamespace();
        return (ns == null || ns.isGlobal()) ? null : ns.getName();
    }

    public void run() throws Exception {
        String[] args = getScriptArgs();
        int maxReport = args.length > 0 ? Integer.parseInt(args[0]) : 25;

        int checked = 0, agree = 0, isolated = 0, disagree = 0, weak = 0;
        Map<String, Integer> disagreeBy = new TreeMap<>();
        List<String> examples = new ArrayList<>();

        FunctionIterator it = currentProgram.getFunctionManager().getFunctions(true);
        while (it.hasNext() && !monitor.isCancelled()) {
            Function f = it.next();
            String c = f.getComment();
            if (c == null || !c.contains("Module INTERPOLATED")) continue;
            String m = mod(f);
            if (m == null) continue;
            checked++;

            int same = 0, other = 0;
            for (Function n : f.getCallingFunctions(monitor)) {
                String nm = mod(n);
                if (nm == null) continue;
                if (nm.equals(m)) same++; else other++;
            }
            for (Function n : f.getCalledFunctions(monitor)) {
                String nm = mod(n);
                if (nm == null) continue;
                if (nm.equals(m)) same++; else other++;
            }

            if (same > 0) {
                agree++;
            } else if (other == 0) {
                isolated++;                    // nothing attributed nearby in the graph
            } else if (other == 1) {
                weak++;                        // one dissenting neighbour proves very little
            } else {
                disagree++;                    // SEVERAL attributed neighbours, none in M
                disagreeBy.merge(m, 1, Integer::sum);
                if (examples.size() < maxReport) {
                    examples.add(String.format("  %s  %s  (%d attributed neighbours, none in %s)",
                            f.getEntryPoint(), m, other, m));
                }
            }
        }

        println("===VALIDATEATTR===");
        println("  interpolated functions checked : " + checked);
        println(String.format("    call graph AGREES            : %d  (%.1f%%)",
                agree, 100.0 * agree / Math.max(1, checked)));
        println(String.format("    isolated (no signal)         : %d  (%.1f%%)",
                isolated, 100.0 * isolated / Math.max(1, checked)));
        println(String.format("    one dissenting neighbour     : %d  (%.1f%%)  -- weak",
                weak, 100.0 * weak / Math.max(1, checked)));
        println(String.format("    SEVERAL dissenting, none agree: %d  (%.1f%%)  -- real suspects",
                disagree, 100.0 * disagree / Math.max(1, checked)));
        for (Map.Entry<String, Integer> e : disagreeBy.entrySet()) {
            println("      " + e.getKey() + " : " + e.getValue());
        }
        for (String e : examples) println(e);
        println("===VALIDATEATTRDONE===");
    }
}
