// Find defined strings containing <needle>, print each with the functions that
// reference it; optionally decompile the top referencing functions.
// Usage: -postScript StrXref.java <needle> [maxStrings] [decomp] [maxDecomp]
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Data;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionManager;
import ghidra.program.model.listing.DataIterator;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.ReferenceIterator;
import ghidra.program.model.symbol.ReferenceManager;

public class StrXref extends GhidraScript {
    public void run() throws Exception {
        String[] args = getScriptArgs();
        String needle = args.length > 0 ? args[0] : "skill";
        int maxStr = args.length > 1 ? Integer.parseInt(args[1]) : 40;
        boolean decomp = args.length > 2 && args[2].equals("decomp");
        int maxDecomp = args.length > 3 ? Integer.parseInt(args[3]) : 2;
        String nl = needle.toLowerCase();

        ReferenceManager rm = currentProgram.getReferenceManager();
        FunctionManager fm = currentProgram.getFunctionManager();

        int found = 0;
        java.util.LinkedHashSet<Function> targets = new java.util.LinkedHashSet<>();
        DataIterator di = currentProgram.getListing().getDefinedData(true);
        while (di.hasNext()) {
            Data data = di.next();
            Object v = data.getValue();
            if (!(v instanceof String)) continue;
            String s = (String) v;
            if (!s.toLowerCase().contains(nl)) continue;
            Address sa = data.getAddress();
            StringBuilder sb = new StringBuilder();
            ReferenceIterator it = rm.getReferencesTo(sa);
            int rc = 0;
            while (it.hasNext()) {
                Reference ref = it.next();
                Address from = ref.getFromAddress();
                Function f = fm.getFunctionContaining(from);
                sb.append(" ").append(from);
                if (f != null) { sb.append("[").append(f.getEntryPoint()).append("]"); targets.add(f); }
                if (++rc >= 6) { sb.append(" ..."); break; }
            }
            if (rc > 0) { // only strings actually referenced by code
                println("STR " + sa + " refs:" + sb + "  \"" + s.replace("\n","\\n") + "\"");
                found++;
            }
            if (found >= maxStr) break;
        }
        println("===STRDONE=== needle=" + needle + " referencedStrings=" + found + " targetFns=" + targets.size());

        if (decomp) {
            DecompInterface d = new DecompInterface();
            d.openProgram(currentProgram);
            int dc = 0;
            for (Function f : targets) {
                println("===FUNC=== " + f.getEntryPoint() + " size=" + f.getBody().getNumAddresses());
                DecompileResults r = d.decompileFunction(f, 120, monitor);
                if (r != null && r.decompileCompleted()) println(r.getDecompiledFunction().getC());
                else println("  (decompile failed)");
                if (++dc >= maxDecomp) break;
            }
        }
    }
}
