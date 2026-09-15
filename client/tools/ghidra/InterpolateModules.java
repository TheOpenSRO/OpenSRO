// Fill the small gaps between same-module neighbours.
//
// MSVC emits a translation unit's functions contiguously, so if the nearest
// attributed function below an unknown one and the nearest above it are BOTH in
// module M, the unknown one is almost certainly M as well. That is the whole
// idea, and the whole risk is in how far "nearest" is allowed to reach.
//
// A tempting stronger version was measured and rejected. Taking each module's
// full address span and claiming everything inside it looked like it would
// attribute 1,781 server functions -- until you look at which: the biggest
// contributor was RefInstanceGenerator, 16 confirmed members spanning 1,207
// functions. A span being "clean" (no OTHER module has a member inside) means
// almost nothing when 97% of functions are unattributed; that is extrapolation
// across a void, not evidence. This script interpolates between near
// neighbours instead, which is a different and much smaller claim.
//
// The gap limit is the honesty dial. At maxGap=3 this attributes 218 server and
// 1,068 client functions; at 8 it would take 478 and 2,549, and each step out
// makes the claim weaker. 3 is the default because a run of three unknowns
// bracketed by the same module on both sides is about as safe as this gets
// without reading the code.
//
// Every function it touches records WHY in a plate comment -- both bracketing
// addresses and the module -- so the inference can be audited or reversed. This
// is attribution, never naming: it says which part of the game a function
// belongs to, not what it does.
//
// Usage: -postScript InterpolateModules.java [apply] [maxGap]
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
import java.util.TreeMap;

public class InterpolateModules extends GhidraScript {

    public void run() throws Exception {
        String[] args = getScriptArgs();
        boolean apply = args.length > 0 && args[0].equalsIgnoreCase("apply");
        int maxGap = args.length > 1 ? Integer.parseInt(args[1]) : 3;

        SymbolTable st = currentProgram.getSymbolTable();

        // Functions in address order, with their module (null when unattributed).
        List<Function> fns = new ArrayList<>();
        List<String> mods = new ArrayList<>();
        FunctionIterator it = currentProgram.getFunctionManager().getFunctions(true);
        while (it.hasNext() && !monitor.isCancelled()) {
            Function f = it.next();
            Namespace ns = f.getParentNamespace();
            fns.add(f);
            mods.add(ns != null && !ns.isGlobal() ? ns.getName() : null);
        }

        Map<String, Namespace> cache = new HashMap<>();
        Map<String, Integer> gained = new TreeMap<>();
        int filled = 0;

        int i = 0;
        while (i < fns.size() && !monitor.isCancelled()) {
            if (mods.get(i) == null) { i++; continue; }
            int j = i + 1;
            while (j < fns.size() && mods.get(j) == null) j++;
            if (j >= fns.size()) break;

            int gap = j - i - 1;
            if (gap > 0 && gap <= maxGap && mods.get(i).equals(mods.get(j))) {
                String mod = mods.get(i);
                for (int k = i + 1; k < j; k++) {
                    Function f = fns.get(k);
                    gained.merge(mod, 1, Integer::sum);
                    filled++;
                    if (!apply) continue;
                    try {
                        Namespace ns = cache.get(mod);
                        if (ns == null) {
                            ns = st.getNamespace(mod, null);
                            if (ns == null) ns = st.createNameSpace(null, mod, SourceType.ANALYSIS);
                            cache.put(mod, ns);
                        }
                        f.setParentNamespace(ns);
                        String note = String.format(
                            "Module INTERPOLATED, not asserted: the nearest attributed function "
                            + "below (%s) and above (%s) are both in %s, with only %d function(s) "
                            + "between. MSVC emits a translation unit contiguously, so this is very "
                            + "likely the same file -- but it is an inference, unlike the __FILE__ "
                            + "asserts that seeded it.",
                            fns.get(i).getEntryPoint(), fns.get(j).getEntryPoint(), mod, gap);
                        String had = f.getComment();
                        if (had == null || !had.contains("Module INTERPOLATED")) {
                            f.setComment(had == null || had.isEmpty() ? note : had + "\n" + note);
                        }
                    } catch (Exception ex) {
                        println("  (could not attribute " + f.getEntryPoint() + ": " + ex.getMessage() + ")");
                    }
                }
            }
            i = j;
        }

        println("===INTERPOLATE===");
        println("  maxGap                 : " + maxGap);
        println("  functions interpolated : " + filled
                + (apply ? "" : " (report only, pass 'apply')"));
        List<Map.Entry<String, Integer>> top = new ArrayList<>(gained.entrySet());
        top.sort((a, b) -> Integer.compare(b.getValue(), a.getValue()));
        int shown = 0;
        for (Map.Entry<String, Integer> g : top) {
            println(String.format("    %-32s +%d", g.getKey(), g.getValue()));
            if (++shown >= 20) { println("    ... " + (top.size() - shown) + " more"); break; }
        }
        println("===INTERPOLATEDONE===");
    }
}
