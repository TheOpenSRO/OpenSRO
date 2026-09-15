// Find vtables by shape, without RTTI.
//
// This binary's RTTI chain is gone -- 1,871 type-descriptor strings survive but
// nothing references them, so the Complete Object Locators that would bind a
// class name to a vtable were stripped (see RttiProbe.java). Ghidra's class
// recovery therefore cannot run, and no amount of coaxing changes that.
//
// The vtables themselves are still there, though: a C++ vtable is simply a run
// of consecutive pointers into executable code, sitting in read-only data. That
// shape is findable without any type information, and it is worth finding,
// because a vtable turns an unreachable virtual call -- `(**(code **)(*obj +
// 0x170))(...)`, which has no callers to grep for -- into a named slot. That is
// exactly how this project found the exp-gain entry (slot 92, offset 0x170) and
// the skill-point adder (slot 93, 0x174) after direct caller searches came back
// empty.
//
// What it reports is a *candidate*: a run of pointers to function entry points.
// Some runs are jump tables or arrays of callbacks rather than vtables, so the
// output is evidence to read, not a conclusion -- same rule as everywhere else
// here.
//
// Usage: -postScript VtableScan.java [minSlots] [maxReport]
//   minSlots  : shortest run to report (default 8; lower finds more noise)
//   maxReport : how many candidates to print (default 40)
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionManager;
import ghidra.program.model.mem.MemoryBlock;

import java.util.ArrayList;
import java.util.List;

public class VtableScan extends GhidraScript {

    public void run() throws Exception {
        String[] args = getScriptArgs();
        int minSlots = args.length > 0 ? Integer.parseInt(args[0]) : 8;
        int maxReport = args.length > 1 ? Integer.parseInt(args[1]) : 40;

        FunctionManager fm = currentProgram.getFunctionManager();
        int ptr = currentProgram.getDefaultPointerSize();

        List<long[]> found = new ArrayList<>();   // {start, slots, namedSlots}
        long totalSlots = 0;

        for (MemoryBlock b : currentProgram.getMemory().getBlocks()) {
            if (!b.isInitialized() || b.isExecute()) continue;   // data only
            Address a = b.getStart();
            Address end = b.getEnd();
            while (a.compareTo(end) < 0 && !monitor.isCancelled()) {
                int slots = 0, named = 0;
                Address runStart = a;
                // Walk while each word points at a real function entry.
                while (a.compareTo(end) < 0) {
                    long val;
                    try {
                        val = ptr == 8 ? getLong(a) : (getInt(a) & 0xffffffffL);
                    } catch (Exception e) {
                        break;
                    }
                    if (val == 0) break;
                    Address target;
                    try {
                        target = toAddr(val);
                    } catch (Exception e) {
                        break;
                    }
                    Function f = fm.getFunctionAt(target);
                    if (f == null) break;
                    slots++;
                    if (!f.getName().startsWith("FUN_")) named++;
                    a = a.add(ptr);
                }
                if (slots >= minSlots) {
                    found.add(new long[]{runStart.getOffset(), slots, named});
                    totalSlots += slots;
                } else if (slots == 0) {
                    a = a.add(ptr);   // nothing here, step on
                }
            }
        }

        println("===VTABLESCAN===");
        println("  candidate vtables (>= " + minSlots + " slots) : " + found.size());
        println("  total virtual slots covered        : " + totalSlots);
        found.sort((x, y) -> Long.compare(y[1], x[1]));
        int shown = 0;
        for (long[] v : found) {
            println(String.format("  vtable 0x%08x  slots=%d  named=%d", v[0], v[1], v[2]));
            if (++shown >= maxReport) {
                println("  ... " + (found.size() - shown) + " more");
                break;
            }
        }
        println("===VTABLESCANDONE===");
    }
}
