// The class hierarchy, from the half of the RTTI chain RttiRebuild skipped.
//
// RttiRebuild walks vftable[-1] -> COL -> TypeDescriptor and stops, which
// recovers what a class is CALLED. The other pointer in the COL says what it
// IS:
//
//     COL + 0x10                      -> RTTIClassHierarchyDescriptor
//     CHD + 0x08                      == numBaseClasses
//     CHD + 0x0C                      -> RTTIBaseClassArray
//     BaseClassArray[i]               -> RTTIBaseClassDescriptor
//     BaseClassDescriptor + 0x00      -> TypeDescriptor  (the base's name)
//     BaseClassDescriptor + 0x08      == PMD.mdisp (where the base sits)
//
// Element 0 of the array is always the class itself, so elements 1..n-1 are
// its bases, in the order MSVC laid them out. That is the inheritance graph.
//
// This also explains a number RttiRebuild reported without using: the 2,014
// server and 1,207 client pointer sites it REJECTED for "bad COL signature"
// are BaseClassDescriptors, which point at TypeDescriptors from offset 0
// rather than 0x0C. They were never noise; they were the other half of the
// answer.
//
// Two products, kept apart by confidence, the way this project's other bulk
// passes do it:
//
//   COMMENT  every recovered vftable's class gets its base chain written onto
//            the functions that vftable names, verbatim. Pure fact.
//   REPORT   the roots, the deepest chains, and a census of what the vftable
//            slot targets actually are -- which is the input to deciding
//            whether defining functions at the undefined ones is worth a
//            re-dump.
//
// Usage: -postScript RttiBases.java [apply] [maxReport]
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionManager;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.mem.MemoryBlock;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;

public class RttiBases extends GhidraScript {

    private static final int TD_NAME_OFFSET = 8;
    private static final int COL_TYPE_OFFSET = 0x0C;
    private static final int COL_HIERARCHY_OFFSET = 0x10;

    private int readInt(long addr) {
        try { return currentProgram.getMemory().getInt(toAddr(addr)); }
        catch (Exception e) { return -1; }
    }

    private boolean isCode(int word) {
        if (word == 0 || word == -1) return false;
        Address a;
        try { a = toAddr(word & 0xffffffffL); } catch (Exception e) { return false; }
        MemoryBlock b = currentProgram.getMemory().getBlock(a);
        return b != null && b.isInitialized() && b.isExecute();
    }

    private boolean readable(long addr) {
        try {
            Address a = toAddr(addr);
            MemoryBlock b = currentProgram.getMemory().getBlock(a);
            return b != null && b.isInitialized();
        } catch (Exception e) { return false; }
    }

    private Map<Long, List<Long>> pointersTo(Set<Long> targets) throws Exception {
        Map<Long, List<Long>> out = new HashMap<>();
        for (MemoryBlock b : currentProgram.getMemory().getBlocks()) {
            if (!b.isInitialized() || monitor.isCancelled()) continue;
            int size = (int) b.getSize();
            if (size <= 4) continue;
            byte[] buf = new byte[size];
            try { b.getBytes(b.getStart(), buf); } catch (Exception e) { continue; }
            long base = b.getStart().getOffset();
            for (int i = 0; i + 4 <= buf.length; i += 4) {
                long v = (buf[i] & 0xffL) | ((buf[i + 1] & 0xffL) << 8)
                       | ((buf[i + 2] & 0xffL) << 16) | ((buf[i + 3] & 0xffL) << 24);
                if (v == 0 || !targets.contains(v)) continue;
                out.computeIfAbsent(v, k -> new ArrayList<>()).add(base + i);
            }
        }
        return out;
    }

    private String demangle(String raw) {
        String s = raw;
        if (s.startsWith(".?A")) s = s.substring(3);
        if (!s.isEmpty() && (s.charAt(0) == 'V' || s.charAt(0) == 'U' || s.charAt(0) == 'W')) {
            s = s.substring(1);
        }
        if (s.endsWith("@@")) s = s.substring(0, s.length() - 2);
        String[] parts = s.split("@");
        StringBuilder sb = new StringBuilder();
        for (int i = parts.length - 1; i >= 0; i--) {
            if (parts[i].isEmpty()) continue;
            if (sb.length() > 0) sb.append("::");
            sb.append(parts[i]);
        }
        String n = sb.toString().replaceAll("[^A-Za-z0-9_:]", "_");
        return n.isEmpty() ? null : n;
    }

    public void run() throws Exception {
        String[] args = getScriptArgs();
        // "apply" writes the base chains; "create" also defines a function at
        // every vftable slot target Ghidra never reached.
        boolean create = args.length > 0 && args[0].equalsIgnoreCase("create");
        boolean apply = create || (args.length > 0 && args[0].equalsIgnoreCase("apply"));
        int maxReport = args.length > 1 ? Integer.parseInt(args[1]) : 25;

        // 1. descriptors, from raw bytes (see RttiRebuild for why not defined data)
        Map<Long, String> descriptors = new HashMap<>();
        for (MemoryBlock b : currentProgram.getMemory().getBlocks()) {
            if (!b.isInitialized() || b.isExecute() || monitor.isCancelled()) continue;
            int size = (int) b.getSize();
            if (size <= 16) continue;
            byte[] buf = new byte[size];
            try { b.getBytes(b.getStart(), buf); } catch (Exception e) { continue; }
            long base = b.getStart().getOffset();
            for (int i = 0; i + 4 < buf.length; i++) {
                if (buf[i] != '.' || buf[i + 1] != '?' || buf[i + 2] != 'A') continue;
                int end = i;
                while (end < buf.length && buf[end] != 0) end++;
                if (end >= buf.length || end - i < 6 || end - i > 512) continue;
                String s = new String(buf, i, end - i, "ISO-8859-1");
                if (!s.endsWith("@@")) continue;
                descriptors.put(base + i - TD_NAME_OFFSET, s);
            }
        }

        // 2. COLs
        Map<Long, List<Long>> toDescriptor = pointersTo(descriptors.keySet());
        Map<Long, Long> colToDescriptor = new TreeMap<>();
        for (Map.Entry<Long, List<Long>> e : toDescriptor.entrySet()) {
            for (long site : e.getValue()) {
                long col = site - COL_TYPE_OFFSET;
                if (readable(col) && readInt(col) == 0) colToDescriptor.put(col, e.getKey());
            }
        }

        // 3. the hierarchy behind each COL
        Map<String, List<String>> bases = new TreeMap<>();
        int chdOK = 0, chdBad = 0, totalEdges = 0;
        for (Map.Entry<Long, Long> e : colToDescriptor.entrySet()) {
            if (monitor.isCancelled()) break;
            String self = demangle(descriptors.get(e.getValue()));
            if (self == null) continue;
            long chd = readInt(e.getKey() + COL_HIERARCHY_OFFSET) & 0xffffffffL;
            if (!readable(chd)) { chdBad++; continue; }
            int n = readInt(chd + 8);
            long arr = readInt(chd + 0x0C) & 0xffffffffL;
            if (n <= 0 || n > 64 || !readable(arr)) { chdBad++; continue; }
            List<String> chain = new ArrayList<>();
            boolean ok = true;
            for (int i = 0; i < n; i++) {
                long bcd = readInt(arr + 4L * i) & 0xffffffffL;
                if (!readable(bcd)) { ok = false; break; }
                long td = readInt(bcd) & 0xffffffffL;
                String nm = descriptors.get(td);
                if (nm == null) { ok = false; break; }
                String d = demangle(nm);
                if (d == null) { ok = false; break; }
                chain.add(d);
            }
            if (!ok || chain.isEmpty()) { chdBad++; continue; }
            chdOK++;
            // element 0 is the class itself; the rest are its bases
            List<String> onlyBases = chain.subList(1, chain.size());
            List<String> had = bases.get(self);
            if (had == null || had.size() < onlyBases.size()) bases.put(self, new ArrayList<>(onlyBases));
            totalEdges += onlyBases.size();
        }

        println("===RTTIBASES===");
        println("  complete object locators    : " + colToDescriptor.size());
        println("  hierarchy descriptors read  : " + chdOK + "   unreadable/rejected: " + chdBad);
        println("  classes with a base chain   : " + bases.size());
        println("  inheritance edges           : " + totalEdges);

        int roots = 0, deepest = 0;
        String deepestName = "";
        for (Map.Entry<String, List<String>> e : bases.entrySet()) {
            if (e.getValue().isEmpty()) roots++;
            if (e.getValue().size() > deepest) { deepest = e.getValue().size(); deepestName = e.getKey(); }
        }
        println("    root classes (no base)    : " + roots);
        println("    deepest chain             : " + deepest + "  (" + deepestName + ")");

        // 4. what the vftable slot targets actually are -- the input to
        // deciding whether defining functions at them is worth a re-dump.
        Map<Long, List<Long>> toCol = pointersTo(colToDescriptor.keySet());
        FunctionManager fm = currentProgram.getFunctionManager();
        Set<Long> targets = new LinkedHashSet<>();
        for (Map.Entry<Long, List<Long>> e : toCol.entrySet()) {
            for (long site : e.getValue()) {
                for (long a = site + 4; ; a += 4) {
                    int p = readInt(a);
                    if (!isCode(p)) break;
                    targets.add(p & 0xffffffffL);
                }
            }
        }
        int isEntry = 0, insideOther = 0, disassembled = 0, raw = 0;
        for (long t : targets) {
            Address a = toAddr(t);
            if (fm.getFunctionAt(a) != null) { isEntry++; continue; }
            if (fm.getFunctionContaining(a) != null) { insideOther++; continue; }
            Instruction ins = currentProgram.getListing().getInstructionAt(a);
            if (ins != null) disassembled++; else raw++;
        }
        println("  distinct slot targets       : " + targets.size());
        println("    already a function entry  : " + isEntry);
        println("    inside another function   : " + insideOther + "   <- would NOT be safe to split");
        println("    disassembled, no function : " + disassembled + "   <- createFunction should work");
        println("    not even disassembled     : " + raw + "   <- needs disassembly first");

        // A vftable slot target IS a function entry -- the binary says so by
        // putting it in a vftable. Ghidra simply never got there: it reaches
        // functions by following calls, and a virtual has no direct caller.
        // That is the same blind spot VtableAttribute was written for, and
        // this is the stronger fix, because a defined function gets
        // DECOMPILED into the dumps every later grep reads.
        //
        // Only where it is safe: a target already inside another function is
        // left alone (splitting one would corrupt an existing, probably
        // correct, body), and a target that will not disassemble is skipped
        // rather than forced.
        if (create) {
            int created = 0, disasmFirst = 0, failedCreate = 0, skippedInside = 0;
            for (long t : targets) {
                if (monitor.isCancelled()) break;
                Address a = toAddr(t);
                if (fm.getFunctionAt(a) != null) continue;
                if (fm.getFunctionContaining(a) != null) { skippedInside++; continue; }
                if (currentProgram.getListing().getInstructionAt(a) == null) {
                    try { disassemble(a); disasmFirst++; } catch (Exception ex) { }
                }
                if (currentProgram.getListing().getInstructionAt(a) == null) { failedCreate++; continue; }
                try {
                    Function f = createFunction(a, null);
                    if (f != null) created++; else failedCreate++;
                } catch (Exception ex) { failedCreate++; }
            }
            println("  functions CREATED at slots  : " + created);
            println("    disassembled first        : " + disasmFirst);
            println("    left alone (inside another): " + skippedInside);
            println("    could not create          : " + failedCreate);
        }

        if (apply) {
            int commented = 0;
            for (Map.Entry<Long, List<Long>> e : toCol.entrySet()) {
                if (monitor.isCancelled()) break;
                String self = demangle(descriptors.get(colToDescriptor.get(e.getKey())));
                List<String> chain = self == null ? null : bases.get(self);
                if (chain == null || chain.isEmpty()) continue;
                String note = "RTTI hierarchy: " + self + " : " + String.join(" : ", chain)
                        + "\nRecovered from the COL's ClassHierarchyDescriptor; the base order is"
                        + " MSVC's own layout order.";
                for (long site : e.getValue()) {
                    for (long a = site + 4; ; a += 4) {
                        int p = readInt(a);
                        if (!isCode(p)) break;
                        Function f = fm.getFunctionAt(toAddr(p & 0xffffffffL));
                        if (f == null) continue;
                        String had = f.getComment();
                        if (had != null && had.contains("RTTI hierarchy:")) continue;
                        f.setComment(had == null || had.isEmpty() ? note : had + "\n" + note);
                        commented++;
                    }
                }
            }
            println("  functions given a base chain: " + commented);
        } else {
            println("  (report only -- pass 'apply' to write)");
        }

        List<Map.Entry<String, List<String>>> deep = new ArrayList<>(bases.entrySet());
        deep.sort((a, b) -> Integer.compare(b.getValue().size(), a.getValue().size()));
        int shown = 0;
        for (Map.Entry<String, List<String>> e : deep) {
            if (e.getValue().isEmpty()) continue;
            println("    " + e.getKey() + " : " + String.join(" : ", e.getValue()));
            if (++shown >= maxReport) break;
        }
        println("===RTTIBASESDONE===");
    }
}
