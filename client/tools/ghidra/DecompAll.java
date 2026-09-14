// Decompile EVERY function in a program to disk, once, so that afterwards any
// question about the binary is a grep instead of a Ghidra round trip.
//
// This exists because the per-function workflow (StrXref/FnXref to find an
// address, DecompDump to read it) costs ~25s of project-open per question, and
// the questions come in long chains -- a parser leads to a field, a field leads
// to its readers, a reader leads to a vtable slot. Dumping the whole program
// turns that chain into `grep -n` over local text, and makes the searches that
// are otherwise impractical possible at all: every call site of a virtual slot,
// every reader of a struct offset, every use of a constant.
//
// Usage: -postScript DecompAll.java <outDir> [timeoutSec] [shardSize]
//   <outDir>      directory to write into (created if missing)
//   [timeoutSec]  per-function decompiler timeout, default 30
//   [shardSize]   functions per output file, default 2000
//
// Writes:
//   funcs_NNN.c  the decompiled C, each function preceded by
//                "===FUNC=== <entry> <name> size=<bytes>"
//   index.txt    "<entry>\t<name>\t<size>\t<shard file>" for every function
//   DONE         written last, with counts -- poll for THIS rather than for a
//                process, because `pgrep -f <pattern>` over ssh matches its own
//                command line and never exits.
import ghidra.app.script.GhidraScript;
import ghidra.app.decompiler.DecompInterface;
import ghidra.app.decompiler.DecompileResults;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionIterator;

import java.io.BufferedWriter;
import java.io.File;
import java.io.FileWriter;
import java.io.PrintWriter;

public class DecompAll extends GhidraScript {

    public void run() throws Exception {
        String[] args = getScriptArgs();
        String outDir = args.length > 0 ? args[0] : "/var/tmp/decomp";
        int timeout = args.length > 1 ? Integer.parseInt(args[1]) : 30;
        int shardSize = args.length > 2 ? Integer.parseInt(args[2]) : 2000;

        File dir = new File(outDir);
        if (!dir.exists() && !dir.mkdirs()) {
            println("DECOMPALL: cannot create " + outDir);
            return;
        }

        DecompInterface d = new DecompInterface();
        d.openProgram(currentProgram);

        PrintWriter index = new PrintWriter(new BufferedWriter(new FileWriter(new File(dir, "index.txt"))));
        PrintWriter out = null;
        int shard = -1, done = 0, failed = 0, skipped = 0;
        long started = System.currentTimeMillis();

        FunctionIterator it = currentProgram.getFunctionManager().getFunctions(true);
        while (it.hasNext()) {
            if (monitor.isCancelled()) { println("DECOMPALL: cancelled"); break; }
            Function f = it.next();
            if (f.isExternal()) { skipped++; continue; }

            int want = done / shardSize;
            if (want != shard) {
                if (out != null) out.close();
                shard = want;
                String name = String.format("funcs_%03d.c", shard);
                out = new PrintWriter(new BufferedWriter(new FileWriter(new File(dir, name)), 1 << 20));
                println("DECOMPALL: opening shard " + name + " after " + done + " functions");
            }
            String shardName = String.format("funcs_%03d.c", shard);

            long size = f.getBody().getNumAddresses();
            out.println("===FUNC=== " + f.getEntryPoint() + " " + f.getName(true) + " size=" + size);
            index.println(f.getEntryPoint() + "\t" + f.getName(true) + "\t" + size + "\t" + shardName);

            String c = null;
            try {
                DecompileResults r = d.decompileFunction(f, timeout, monitor);
                if (r != null && r.decompileCompleted() && r.getDecompiledFunction() != null) {
                    c = r.getDecompiledFunction().getC();
                }
            } catch (Exception e) {
                c = null;
            }
            if (c == null) {
                out.println("  (decompile failed)");
                failed++;
            } else {
                out.println(c);
            }
            done++;

            if (done % 500 == 0) {
                long secs = (System.currentTimeMillis() - started) / 1000;
                println("DECOMPALL: " + done + " functions in " + secs + "s (" + failed + " failed)");
                out.flush();
                index.flush();
            }
        }
        if (out != null) out.close();
        index.close();

        long secs = (System.currentTimeMillis() - started) / 1000;
        PrintWriter marker = new PrintWriter(new FileWriter(new File(dir, "DONE")));
        marker.println("functions=" + done + " failed=" + failed + " skippedExternal=" + skipped
                + " seconds=" + secs + " shards=" + (shard + 1));
        marker.close();
        println("DECOMPALL: DONE functions=" + done + " failed=" + failed + " seconds=" + secs);
    }
}
