// Decompile a single function with a generous timeout, and write it to a file.
//
// DecompAll gives every function the same modest budget, which is right for
// 30,000 of them and wrong for the handful that are enormous. The client's
// GlobalDataManager::Client_LoadRefDataFile is 27,045 bytes -- one giant switch
// over every refdata file type with the per-column parsing inlined into each
// branch -- and it is the ONLY function in either binary that DecompAll has
// ever failed on. It is also exactly where the column maps live, so "it timed
// out" is not an acceptable answer for it.
//
// Writes to a file rather than stdout because the result is far too large for
// the headless log's line prefixing to survive intact.
//
// Usage: -postScript DecompOne.java <entryAddr> <outFile> [timeoutSec]
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;

import java.io.PrintWriter;

public class DecompOne extends GhidraScript {

    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length < 2) { println("usage: <entryAddr> <outFile> [timeoutSec]"); return; }
        Address a = currentProgram.getAddressFactory().getAddress(args[0]);
        int timeout = args.length > 2 ? Integer.parseInt(args[2]) : 600;

        Function f = currentProgram.getFunctionManager().getFunctionAt(a);
        if (f == null) { println("no function at " + args[0]); return; }

        DecompInterface di = new DecompInterface();
        di.openProgram(currentProgram);
        println("===DECOMPONE=== " + f.getName(true) + " size=" + f.getBody().getNumAddresses()
                + " timeout=" + timeout + "s");
        long t0 = System.currentTimeMillis();
        DecompileResults r = di.decompileFunction(f, timeout, monitor);
        long secs = (System.currentTimeMillis() - t0) / 1000;

        if (r == null || !r.decompileCompleted() || r.getDecompiledFunction() == null) {
            println("  FAILED after " + secs + "s: " + (r == null ? "null" : r.getErrorMessage()));
            di.dispose();
            return;
        }
        String c = r.getDecompiledFunction().getC();
        try (PrintWriter w = new PrintWriter(args[1])) { w.print(c); }
        println("  OK in " + secs + "s, " + c.length() + " chars -> " + args[1]);
        di.dispose();
        println("===DECOMPONEDONE===");
    }
}
