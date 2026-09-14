// Name functions from the strings they carry.
//
// These binaries assert with their own identity: RefObjChar::ExtractData emits
// "RefObjChar::ExtractData!!!! ..." on failure, CBasicQuest::PayQuest names
// itself, and hundreds more do the same. A function that references exactly one
// Class::Method string is almost certainly that method, so the name is sitting
// inside the function waiting to be read.
//
// Conservative on purpose. A wrong name is worse than FUN_00587630, because a
// wrong name is believed. So a function is renamed only when:
//   - it references exactly ONE distinct Class::Method string (a function that
//     mentions two is likely a dispatcher or an error reporter for others), and
//   - it has no real name already (never overwrite a demangled or RTTI name).
// Everything renamed is tagged SourceType.ANALYSIS and given a plate comment
// quoting the evidence, so every name in the program can be traced back to the
// string it came from, and a later pass can tell a recovered name from a guess.
//
// Usage: -postScript AutoNameFromStrings.java [apply]
//   no arg  : report what it would name (safe on a -readOnly run)
//   "apply" : actually rename (needs a writable run)
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.data.StringDataInstance;
import ghidra.program.model.listing.Data;
import ghidra.program.model.listing.DataIterator;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionManager;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.ReferenceIterator;
import ghidra.program.model.symbol.ReferenceManager;
import ghidra.program.model.symbol.SourceType;

import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public class AutoNameFromStrings extends GhidraScript {

    // Class::Method at the start of a string, which is how these asserts read.
    private static final Pattern METHOD =
        Pattern.compile("([A-Za-z_][A-Za-z0-9_]{2,63})::([A-Za-z_][A-Za-z0-9_]{2,63})");

    public void run() throws Exception {
        String[] args = getScriptArgs();
        boolean apply = args.length > 0 && args[0].equalsIgnoreCase("apply");

        ReferenceManager rm = currentProgram.getReferenceManager();
        FunctionManager fm = currentProgram.getFunctionManager();

        // function entry -> set of distinct Class::Method strings it references
        Map<Address, Set<String>> candidates = new LinkedHashMap<>();
        Map<Address, String> evidence = new HashMap<>();

        DataIterator di = currentProgram.getListing().getDefinedData(true);
        while (di.hasNext() && !monitor.isCancelled()) {
            Data data = di.next();
            Object v = data.getValue();
            if (!(v instanceof String)) continue;
            String s = (String) v;
            Matcher m = METHOD.matcher(s);
            if (!m.find()) continue;
            String name = m.group(1) + "::" + m.group(2);

            ReferenceIterator it = rm.getReferencesTo(data.getAddress());
            while (it.hasNext()) {
                Function f = fm.getFunctionContaining(it.next().getFromAddress());
                if (f == null) continue;
                candidates.computeIfAbsent(f.getEntryPoint(), k -> new HashSet<>()).add(name);
                evidence.putIfAbsent(f.getEntryPoint(), s.length() > 90 ? s.substring(0, 90) : s);
            }
        }

        int unique = 0, skippedMulti = 0, skippedNamed = 0, renamed = 0;
        for (Map.Entry<Address, Set<String>> e : candidates.entrySet()) {
            if (e.getValue().size() != 1) { skippedMulti++; continue; }
            Function f = fm.getFunctionAt(e.getKey());
            if (f == null) continue;
            boolean isDefault = f.getSymbol() == null
                || f.getSymbol().getSource() == SourceType.DEFAULT
                || f.getName().startsWith("FUN_");
            if (!isDefault) { skippedNamed++; continue; }
            unique++;
            String name = e.getValue().iterator().next().replace("::", "__");
            if (apply) {
                try {
                    f.setName(name, SourceType.ANALYSIS);
                    f.setComment("Named from its own assert string:\n  \"" + evidence.get(e.getKey()) + "\"");
                    renamed++;
                } catch (Exception ex) {
                    println("  (could not rename " + e.getKey() + ": " + ex.getMessage() + ")");
                }
            } else if (unique <= 15) {
                println("  would name " + e.getKey() + " -> " + name);
            }
        }

        println("===AUTONAME===");
        println("  functions referencing a Class::Method string : " + candidates.size());
        println("  of those, exactly one distinct name          : " + unique);
        println("  skipped (several names -- dispatcher/reporter): " + skippedMulti);
        println("  skipped (already had a real name)            : " + skippedNamed);
        println("  renamed                                      : " + renamed + (apply ? "" : " (report only, pass 'apply')"));
        println("===AUTONAMEDONE===");
    }
}
