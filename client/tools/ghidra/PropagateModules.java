// Spread module attribution along the call graph, conservatively.
//
// These binaries assert with __FILE__, which puts a few hundred functions into
// a namespace named after the source file they came from (see
// NamespaceFromSourceFile.java). That is a small seed -- 113 functions on the
// server, 463 on the client -- but it is a seed with a property worth
// exploiting: a function that is ONLY ever called from inside one module is,
// in practice, part of that module. Static helpers, per-class privates and
// one-call-site utilities all look like that.
//
// So: repeatedly attribute an unattributed function to module M when EVERY one
// of its callers is already attributed, and all of them agree on M. Newly
// attributed functions become seeds for the next round, and it runs to a
// fixpoint.
//
// The rule is deliberately the strict one. The tempting weaker version --
// "most callers agree" or "at least one caller is in M" -- would sweep in every
// shared utility the module happens to touch, and a wrong module is worse than
// no module: it reads like a fact and is not one. Requiring unanimity among ALL
// callers means a function shared by two modules is left alone, which is the
// correct answer for it. A function with no callers at all is also left alone;
// there is nothing to argue from.
//
// This is ATTRIBUTION, not naming, and SymbolReport.java counts it separately
// for exactly that reason. It says what area of the game a function belongs to,
// never what it does. Every function it touches gets a plate comment recording
// that the attribution was inferred from the call graph and from which module,
// so it can be audited or undone -- unlike the __FILE__ seeds, which are facts
// the binary states about itself.
//
// Usage: -postScript PropagateModules.java [apply] [maxRounds] [maxCallers]
//   maxCallers : skip functions with more than this many callers (default 16).
//                A function called from 200 places is infrastructure, and
//                unanimity there is an accident of the seed set, not evidence.
import ghidra.app.script.GhidraScript;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionIterator;
import ghidra.program.model.symbol.Namespace;
import ghidra.program.model.symbol.SourceType;
import ghidra.program.model.symbol.SymbolTable;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;

public class PropagateModules extends GhidraScript {

    public void run() throws Exception {
        String[] args = getScriptArgs();
        boolean apply = args.length > 0 && args[0].equalsIgnoreCase("apply");
        int maxRounds = args.length > 1 ? Integer.parseInt(args[1]) : 12;
        int maxCallers = args.length > 2 ? Integer.parseInt(args[2]) : 16;

        SymbolTable st = currentProgram.getSymbolTable();

        // Work on a local view of "which module is this function in", so a
        // report-only run behaves exactly like an applying one.
        Map<Function, String> module = new HashMap<>();
        List<Function> all = new ArrayList<>();
        FunctionIterator it = currentProgram.getFunctionManager().getFunctions(true);
        while (it.hasNext() && !monitor.isCancelled()) {
            Function f = it.next();
            all.add(f);
            Namespace ns = f.getParentNamespace();
            if (ns != null && !ns.isGlobal()) module.put(f, ns.getName());
        }
        int seeded = module.size();
        println("===PROPMODULES===");
        println("  functions          : " + all.size());
        println("  seeded from __FILE__: " + seeded);

        Map<String, Namespace> cache = new HashMap<>();
        Map<String, Integer> gained = new TreeMap<>();
        int totalNew = 0;

        for (int round = 1; round <= maxRounds && !monitor.isCancelled(); round++) {
            Map<Function, String> pending = new HashMap<>();
            for (Function f : all) {
                if (module.containsKey(f)) continue;
                if (f.isThunk()) continue;

                Set<Function> callers = f.getCallingFunctions(monitor);
                if (callers.isEmpty() || callers.size() > maxCallers) continue;

                String agreed = null;
                boolean ok = true;
                for (Function c : callers) {
                    if (c.equals(f)) continue;            // direct recursion proves nothing
                    String m = module.get(c);
                    if (m == null) { ok = false; break; } // an unattributed caller: no unanimity
                    if (agreed == null) agreed = m;
                    else if (!agreed.equals(m)) { ok = false; break; }
                }
                if (ok && agreed != null) pending.put(f, agreed);
            }
            if (pending.isEmpty()) {
                println("  round " + round + ": nothing new, fixpoint reached");
                break;
            }
            println("  round " + round + ": +" + pending.size());
            for (Map.Entry<Function, String> e : pending.entrySet()) {
                module.put(e.getKey(), e.getValue());
                gained.merge(e.getValue(), 1, Integer::sum);
                totalNew++;
                if (!apply) continue;
                try {
                    Namespace ns = cache.get(e.getValue());
                    if (ns == null) {
                        ns = st.getNamespace(e.getValue(), null);
                        if (ns == null) ns = st.createNameSpace(null, e.getValue(), SourceType.ANALYSIS);
                        cache.put(e.getValue(), ns);
                    }
                    e.getKey().setParentNamespace(ns);
                    String had = e.getKey().getComment();
                    String note = "Module inferred from the call graph: every caller of this "
                            + "function is in " + e.getValue() + ". Attribution, not a name -- it "
                            + "says which part of the game this belongs to, not what it does.";
                    e.getKey().setComment(had == null || had.isEmpty() ? note : had + "\n" + note);
                } catch (Exception ex) {
                    println("  (could not attribute " + e.getKey().getEntryPoint() + ": " + ex.getMessage() + ")");
                }
            }
        }

        println("  newly attributed   : " + totalNew + (apply ? "" : " (report only, pass 'apply')"));
        println("  attributed total   : " + (seeded + totalNew));
        println("  --- biggest gains ---");
        gained.entrySet().stream()
                .sorted((a, b) -> Integer.compare(b.getValue(), a.getValue()))
                .limit(20)
                .forEach(e -> println(String.format("  %-34s +%d", e.getKey(), e.getValue())));
        println("===PROPMODULESDONE===");
    }
}
