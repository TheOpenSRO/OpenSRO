// Find code that touches a struct field at a given offset -- the missing piece
// when you know WHERE a field lives (say CRefObjChar+0x24c, from a parser) but
// not WHAT it means, and need the places that read or write it.
//
// A C++ member access compiles to a memory operand with a displacement:
//   MOV EAX, dword ptr [ECX + 0x24c]
// so this walks every instruction and reports the ones whose operand carries
// both a register and that exact scalar. Requiring a register in the same
// operand is what keeps plain immediates (MOV EAX, 0x24c) out of the results.
//
// Usage: -postScript FindOffsetRefs.java <offsets> [max] [mode]
//   <offsets>  one or a comma-separated list, hex (0x24c) or decimal (588)
//   [max]      cap on reported sites per offset (default 40)
//   [mode]     "all" (default) lists every site; "funcs" prints only the
//              per-function summary, which is usually what you want first
//
// Small offsets (0x4, 0x8, ...) appear in almost every function and will drown
// you -- this is a tool for the distinctive ones. The summary is ordered by
// hit count, and W/R marks whether the field was the destination operand.
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.lang.Register;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionManager;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.InstructionIterator;
import ghidra.program.model.scalar.Scalar;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

public class FindOffsetRefs extends GhidraScript {

    public void run() throws Exception {
        String[] args = getScriptArgs();
        String spec = args.length > 0 ? args[0] : "0x0";
        int max = args.length > 1 ? Integer.parseInt(args[1]) : 40;
        String mode = args.length > 2 ? args[2] : "all";
        immMode = mode.equals("imm");

        // One pass over the listing for every offset asked about. Mapping a
        // struct means asking about 20-30 at once, and re-walking a few million
        // instructions per offset turns that from seconds into many minutes.
        java.util.LinkedHashSet<Long> targets = new java.util.LinkedHashSet<>();
        for (String part : spec.split(",")) targets.add(parseOffset(part.trim()));
        scanAll(targets, max, mode);
        println("===OFFDONE=== spec=" + spec);
    }

    private long parseOffset(String s) {
        if (s.startsWith("0x") || s.startsWith("0X")) return Long.parseLong(s.substring(2), 16);
        return Long.parseLong(s);
    }

    private void scanAll(java.util.LinkedHashSet<Long> targets, int max, String mode) {
        FunctionManager fm = currentProgram.getFunctionManager();
        Map<Long, Map<String, int[]>> perFn = new LinkedHashMap<>();
        Map<Long, List<String>> sites = new LinkedHashMap<>();
        Map<Long, Integer> totals = new LinkedHashMap<>();
        for (Long t : targets) {
            perFn.put(t, new LinkedHashMap<String, int[]>());
            sites.put(t, new ArrayList<String>());
            totals.put(t, 0);
        }

        InstructionIterator it = currentProgram.getListing().getInstructions(true);
        while (it.hasNext() && !monitor.isCancelled()) {
            Instruction ins = it.next();
            for (Long t : targets) {
                int hitOp = matchingOperand(ins, t);
                if (hitOp < 0) continue;
                totals.put(t, totals.get(t) + 1);

                Address at = ins.getAddress();
                Function f = fm.getFunctionContaining(at);
                String key = (f == null) ? "(none)" : f.getEntryPoint().toString();
                Map<String, int[]> fnMap = perFn.get(t);
                int[] tally = fnMap.get(key);
                if (tally == null) { tally = new int[2]; fnMap.put(key, tally); }
                tally[0]++;
                boolean write = isStore(ins, hitOp);
                if (write) tally[1]++;

                List<String> ls = sites.get(t);
                if (ls.size() < max) {
                    ls.add("  " + at + " " + (write ? "W" : "R") + " fn=" + key + "  " + ins.toString());
                }
            }
        }

        for (Long t : targets) {
            int total = totals.get(t);
            Map<String, int[]> fnMap = perFn.get(t);
            println("===OFFSET=== 0x" + Long.toHexString(t) + " sites=" + total
                    + " functions=" + fnMap.size() + (total > max ? " (listing first " + max + ")" : ""));
            if (!mode.equals("funcs")) {
                for (String s : sites.get(t)) println(s);
            }
            // Summary, busiest function first -- the field's real users float up.
            List<Map.Entry<String, int[]>> rows = new ArrayList<>(fnMap.entrySet());
            rows.sort(Comparator.comparingInt((Map.Entry<String, int[]> e) -> e.getValue()[0]).reversed());
            int shown = 0;
            for (Map.Entry<String, int[]> e : rows) {
                println("  FN " + e.getKey() + " hits=" + e.getValue()[0] + " writes=" + e.getValue()[1]);
                if (++shown >= 25) { println("  ... " + (rows.size() - shown) + " more functions"); break; }
            }
        }
    }

    // Operand 0 is the destination on x86, but a compare/test reads it rather
    // than writing it -- counting those as stores made ExtractData look like it
    // wrote MaxHP twice, when the second one is the m_dwMaxHP > 0 assertion.
    private boolean isStore(Instruction ins, int hitOp) {
        if (hitOp != 0 || immMode) return false;
        String m = ins.getMnemonicString().toUpperCase();
        return !(m.startsWith("CMP") || m.startsWith("TEST") || m.startsWith("PUSH")
                || m.startsWith("FLD") || m.startsWith("FILD"));
    }

    // In "imm" mode the register requirement is dropped, so a bare constant
    // matches: CMP EAX, 0x6d70. That is how you find the code handling a param
    // identified by a C multi-char literal ('mp' == 0x6d70) rather than by a
    // struct offset -- a field lookup and a tag comparison need opposite rules.
    private boolean immMode = false;

    // Returns the operand index whose [reg + disp] displacement equals target,
    // or -1. Both a Register and the Scalar must appear in the same operand:
    // that is the shape of a member access, and it rejects bare immediates.
    private int matchingOperand(Instruction ins, long target) {
        int n = ins.getNumOperands();
        for (int i = 0; i < n; i++) {
            Object[] objs;
            try {
                objs = ins.getOpObjects(i);
            } catch (Exception e) {
                continue;
            }
            boolean reg = false, scalar = false;
            for (Object o : objs) {
                if (o instanceof Register) reg = true;
                else if (o instanceof Scalar) {
                    Scalar sc = (Scalar) o;
                    if (sc.getUnsignedValue() == target || sc.getValue() == target) scalar = true;
                }
            }
            if (scalar && (reg || immMode)) return i;
        }
        return -1;
    }
}
