// Headless Ghidra decompiler dump.
// Usage (analyzeHeadless ... -postScript DecompDump.java <needle> [max] [mode]):
//   mode "name" (default): decompile functions whose name contains <needle>
//   mode "addr":           decompile the single function at address <needle>
// Prints each function's decompiled C between ===FUNC=== / ===DONE=== markers.
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionManager;

public class DecompDump extends GhidraScript {
    public void run() throws Exception {
        String[] args = getScriptArgs();
        String needle = args.length > 0 ? args[0] : "Skill";
        int max = args.length > 1 ? Integer.parseInt(args[1]) : 3;
        String mode = args.length > 2 ? args[2] : "name"; // name | addr | list
        String nl = needle.toLowerCase();

        FunctionManager fm = currentProgram.getFunctionManager();

        // Fast locate: print qualified names (Class::method) that match, no decompile.
        if (mode.equals("list")) {
            int c = 0;
            for (Function f : fm.getFunctions(true)) {
                String q = f.getName(true);
                if (q.toLowerCase().contains(nl)) {
                    println("FN " + f.getEntryPoint() + "  " + q);
                    if (++c >= max) break;
                }
            }
            println("===DONE=== list needle=" + needle + " count=" + c);
            return;
        }

        DecompInterface d = new DecompInterface();
        d.openProgram(currentProgram);
        int shown = 0;
        if (mode.equals("addr")) {
            for (String part : needle.split(",")) {
                Address a = currentProgram.getAddressFactory().getAddress(part.trim());
                Function f = fm.getFunctionContaining(a);
                if (f != null) { dump(d, f); shown++; }
                else println("  (no function containing " + part + ")");
            }
        } else {
            for (Function f : fm.getFunctions(true)) {
                if (f.getName(true).toLowerCase().contains(nl)) { // Class::method
                    dump(d, f);
                    if (++shown >= max) break;
                }
            }
        }
        println("===DONE=== needle=" + needle + " shown=" + shown);
    }

    private void dump(DecompInterface d, Function f) {
        println("===FUNC=== " + f.getName(true) + " @ " + f.getEntryPoint());
        DecompileResults r = d.decompileFunction(f, 90, monitor);
        if (r != null && r.decompileCompleted()) {
            println(r.getDecompiledFunction().getC());
        } else {
            println("  (decompile failed: " + (r == null ? "null" : r.getErrorMessage()) + ")");
        }
    }
}
