// Apply a table of (address, namespace) pairs from a file.
//
// Some attributions are derived by reasoning over the DECOMPILED C rather than
// over the program's own structures -- which a Ghidra script cannot easily
// redo, because it would have to decompile and parse 155KB of switch. The
// client's refdata layer is the case in point: the loader dispatches on a type
// id, each case parses one textdata file, and 421 functions appear in exactly
// one case. That makes them that file's parsing code, and the evidence lives in
// the C, not in a symbol.
//
// So the analysis happens outside and lands here as a table. The file is
// tab-separated `address<TAB>namespace`, one per line; lines starting with '#'
// are ignored. Existing namespaces are never overwritten -- a fact the binary
// states about itself (a __FILE__ assert) outranks anything derived.
//
// Usage: -postScript ApplyNamespaceTable.java <tsvPath> [apply]
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.symbol.Namespace;
import ghidra.program.model.symbol.SourceType;
import ghidra.program.model.symbol.SymbolTable;

import java.io.BufferedReader;
import java.io.FileReader;
import java.util.HashMap;
import java.util.Map;
import java.util.TreeMap;

public class ApplyNamespaceTable extends GhidraScript {

    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length < 1) { println("usage: <tsvPath> [apply]"); return; }
        boolean apply = args.length > 1 && args[1].equalsIgnoreCase("apply");

        SymbolTable st = currentProgram.getSymbolTable();
        Map<String, Namespace> cache = new HashMap<>();
        Map<String, Integer> gained = new TreeMap<>();
        int ok = 0, missing = 0, already = 0, bad = 0;

        try (BufferedReader r = new BufferedReader(new FileReader(args[0]))) {
            String line;
            while ((line = r.readLine()) != null && !monitor.isCancelled()) {
                line = line.trim();
                if (line.isEmpty() || line.charAt(0) == '#') continue;
                String[] p = line.split("\t");
                if (p.length < 2) { bad++; continue; }

                Address a = currentProgram.getAddressFactory().getAddress(p[0].trim());
                Function f = a == null ? null : currentProgram.getFunctionManager().getFunctionAt(a);
                if (f == null) { missing++; continue; }
                if (f.getParentNamespace() != null && !f.getParentNamespace().isGlobal()) {
                    already++;
                    continue;
                }
                gained.merge(p[1].trim(), 1, Integer::sum);
                ok++;
                if (!apply) continue;
                try {
                    Namespace ns = cache.get(p[1].trim());
                    if (ns == null) {
                        ns = st.getNamespace(p[1].trim(), null);
                        if (ns == null) ns = st.createNameSpace(null, p[1].trim(), SourceType.ANALYSIS);
                        cache.put(p[1].trim(), ns);
                    }
                    f.setParentNamespace(ns);
                } catch (Exception ex) {
                    println("  (could not attribute " + p[0] + ": " + ex.getMessage() + ")");
                }
            }
        }

        println("===NSTABLE===");
        println("  attributed        : " + ok + (apply ? "" : " (report only, pass 'apply')"));
        println("  already namespaced: " + already);
        println("  no function there : " + missing);
        println("  malformed lines   : " + bad);
        println("  distinct namespaces: " + gained.size());
        println("===NSTABLEDONE===");
    }
}
