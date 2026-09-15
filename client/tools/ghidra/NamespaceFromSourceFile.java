// Put functions into a namespace named after the source file they came from.
//
// These binaries assert with __FILE__: a function that fails a check calls the
// assert helper with "D:\vss-od\Silkroad\Client\client\IFSkillMastery.cpp".
// That does not give the function's name, but it gives something almost as
// useful for reading code -- the module it belongs to. 560 functions across the
// two binaries carry one.
//
// Namespacing rather than renaming, deliberately. The address stays the primary
// identity, nothing is overwritten, and because DecompAll prints getName(true)
// the dumped C shows "IFSkillMastery::FUN_0069f860" -- the reader immediately
// knows this is skill-window code without a name having been invented for it.
// A file attribution is a fact the binary states about itself; a name would be
// a guess, and this project does not ship guesses dressed as facts.
//
// Usage: -postScript NamespaceFromSourceFile.java [apply]
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Data;
import ghidra.program.model.listing.DataIterator;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionManager;
import ghidra.program.model.symbol.Namespace;
import ghidra.program.model.symbol.ReferenceIterator;
import ghidra.program.model.symbol.ReferenceManager;
import ghidra.program.model.symbol.SourceType;
import ghidra.program.model.symbol.SymbolTable;

import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public class NamespaceFromSourceFile extends GhidraScript {

    // ...\Something.cpp or .h -- the last path element of a __FILE__ string.
    private static final Pattern FILE =
        Pattern.compile("([A-Za-z0-9_]+)\\.(cpp|h)\"?$|\\\\([A-Za-z0-9_]+)\\.(cpp|h)");

    public void run() throws Exception {
        String[] args = getScriptArgs();
        boolean apply = args.length > 0 && args[0].equalsIgnoreCase("apply");

        ReferenceManager rm = currentProgram.getReferenceManager();
        FunctionManager fm = currentProgram.getFunctionManager();
        SymbolTable st = currentProgram.getSymbolTable();

        Map<Address, Set<String>> perFunc = new LinkedHashMap<>();

        DataIterator di = currentProgram.getListing().getDefinedData(true);
        while (di.hasNext() && !monitor.isCancelled()) {
            Data d = di.next();
            Object v = d.getValue();
            if (!(v instanceof String)) continue;
            String s = (String) v;
            if (!s.contains(".cpp") && !s.contains(".h")) continue;
            Matcher m = FILE.matcher(s.trim());
            if (!m.find()) continue;
            String base = m.group(1) != null ? m.group(1) : m.group(3);
            if (base == null || base.length() < 3) continue;

            ReferenceIterator it = rm.getReferencesTo(d.getAddress());
            while (it.hasNext()) {
                Function f = fm.getFunctionContaining(it.next().getFromAddress());
                if (f == null) continue;
                perFunc.computeIfAbsent(f.getEntryPoint(), k -> new HashSet<>()).add(base);
            }
        }

        Map<String, Namespace> cache = new HashMap<>();
        int single = 0, multi = 0, moved = 0, already = 0;
        for (Map.Entry<Address, Set<String>> e : perFunc.entrySet()) {
            // A function citing two different files is inlined code or a shared
            // helper -- its module is genuinely ambiguous, so leave it alone.
            if (e.getValue().size() != 1) { multi++; continue; }
            single++;
            Function f = fm.getFunctionAt(e.getKey());
            if (f == null) continue;
            if (f.getParentNamespace() != null && !f.getParentNamespace().isGlobal()) { already++; continue; }
            if (!apply) continue;
            String file = e.getValue().iterator().next();
            try {
                Namespace ns = cache.get(file);
                if (ns == null) {
                    ns = st.getNamespace(file, null);
                    if (ns == null) ns = st.createNameSpace(null, file, SourceType.ANALYSIS);
                    cache.put(file, ns);
                }
                f.setParentNamespace(ns);
                moved++;
            } catch (Exception ex) {
                println("  (could not namespace " + e.getKey() + ": " + ex.getMessage() + ")");
            }
        }

        println("===NSFROMFILE===");
        println("  functions citing a source file : " + perFunc.size());
        println("    exactly one file             : " + single);
        println("    several files (left alone)   : " + multi);
        println("    already namespaced           : " + already);
        println("  moved into a file namespace    : " + moved + (apply ? "" : " (report only, pass 'apply')"));
        println("  distinct modules               : " + cache.size());
        println("===NSFROMFILEDONE===");
    }
}
