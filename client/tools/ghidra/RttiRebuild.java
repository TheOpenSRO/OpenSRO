// Rebuild the MSVC RTTI chain by hand, and with it every class name the
// binary knows about itself.
//
// This lever was recorded CLOSED -- "1,871 type descriptors survive and zero
// are referenced, so the COL/vftable chain was stripped". That conclusion came
// from a probe fired at the wrong address. An MSVC TypeDescriptor is
//
//     struct TypeDescriptor { void *pVFTable; void *spare; char name[]; };
//
// so the ".?AVCGObjPC@@" string sits at offset +8 INSIDE the descriptor, and
// the RTTICompleteObjectLocator points at the descriptor's START. Asking for
// references to the string's own address returns zero no matter how intact the
// chain is. Nothing was stripped; the question was asked 8 bytes too late.
//
// The chain this walks, all absolute addresses because these are 32-bit PEs:
//
//     vftable[-1]                 -> COL
//     COL + 0x00                  == 0            (signature, x86)
//     COL + 0x0C                  -> TypeDescriptor
//     TypeDescriptor + 0x08       == ".?AV<name>@@"
//
// So: find the descriptors, find what points at them (those are COLs), find
// what points at the COLs (that word is vftable[-1], and the vftable starts
// one word later). Two linear passes over initialised memory with a target
// set, rather than 1,871 whole-image byte searches.
//
// Ghidra's own RTTI analyser finds one vftable here, which is why this is done
// by hand. It reports before it writes, and `apply` only ever ADDS: a class
// namespace per recovered vftable and a name for each slot that is still
// FUN_. Anything already named by a hand-proven pass is left exactly as it is
// -- a recovered name is evidence, but it is weaker evidence than a function
// somebody reasoned about one at a time.
//
// Usage: -postScript RttiRebuild.java [apply] [maxReport]
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Data;
import ghidra.program.model.listing.DataIterator;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionManager;
import ghidra.program.model.mem.MemoryBlock;
import ghidra.program.model.symbol.Namespace;
import ghidra.program.model.symbol.SourceType;
import ghidra.program.model.symbol.SymbolTable;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;

public class RttiRebuild extends GhidraScript {

    /** Where the name sits inside a TypeDescriptor. */
    private static final int TD_NAME_OFFSET = 8;
    /** Where the TypeDescriptor pointer sits inside a COL. */
    private static final int COL_TYPE_OFFSET = 0x0C;

    /** Every 4-byte aligned word in initialised memory whose value is in targets. */
    private Map<Long, List<Long>> pointersTo(Set<Long> targets) throws Exception {
        Map<Long, List<Long>> out = new HashMap<>();
        for (MemoryBlock b : currentProgram.getMemory().getBlocks()) {
            if (!b.isInitialized() || monitor.isCancelled()) continue;
            int size = (int) b.getSize();
            if (size <= 4) continue;
            byte[] buf = new byte[size];
            try {
                b.getBytes(b.getStart(), buf);
            } catch (Exception e) {
                continue;
            }
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

    private int readInt(long addr) {
        try {
            return currentProgram.getMemory().getInt(toAddr(addr));
        } catch (Exception e) {
            return -1;
        }
    }

    /** Does this word point into executable memory? */
    private boolean isCode(int word) {
        if (word == 0 || word == -1) return false;
        Address a;
        try { a = toAddr(word & 0xffffffffL); } catch (Exception e) { return false; }
        MemoryBlock b = currentProgram.getMemory().getBlock(a);
        return b != null && b.isInitialized() && b.isExecute();
    }

    /** ".?AVCGObjPC@@" -> "CGObjPC"; ".?AVFoo@Bar@@" -> "Bar::Foo". */
    private String demangle(String raw) {
        String s = raw;
        if (s.startsWith(".?A")) s = s.substring(3);
        // The next char is the kind: V class, U struct, W enum.
        if (!s.isEmpty() && (s.charAt(0) == 'V' || s.charAt(0) == 'U' || s.charAt(0) == 'W')) {
            s = s.substring(1);
        }
        if (s.endsWith("@@")) s = s.substring(0, s.length() - 2);
        String[] parts = s.split("@");
        StringBuilder sb = new StringBuilder();
        for (int i = parts.length - 1; i >= 0; i--) {   // MSVC stores them inside-out
            if (parts[i].isEmpty()) continue;
            if (sb.length() > 0) sb.append("::");
            sb.append(parts[i]);
        }
        String name = sb.toString().replaceAll("[^A-Za-z0-9_:]", "_");
        return name.isEmpty() ? null : name;
    }

    public void run() throws Exception {
        String[] args = getScriptArgs();
        boolean apply = args.length > 0 && args[0].equalsIgnoreCase("apply");
        boolean probe = args.length > 1 && args[0].equalsIgnoreCase("probe");
        long probeAt = probe ? Long.parseLong(args[1].replaceFirst("^0x", ""), 16) : 0;
        int maxReport = (!probe && args.length > 1) ? Integer.parseInt(args[1]) : 12;

        // --- 1. the type descriptors ---------------------------------------
        // Scanned out of RAW BYTES, not read off defined data. Ghidra has only
        // typed a fraction of these as strings -- on the client it had defined
        // 1,088 of the 1,882 that are really there -- and a descriptor missed
        // here costs its whole class, its vftable and every slot in it. The
        // known CGObjPC-side table at 0x00af59fc was one of the casualties.
        Map<Long, String> descriptors = new HashMap<>();   // descriptor start -> raw name
        int fromDefined = 0;
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
        DataIterator di = currentProgram.getListing().getDefinedData(true);
        while (di.hasNext() && !monitor.isCancelled()) {
            Data d = di.next();
            Object v = d.getValue();
            if (!(v instanceof String)) continue;
            String s = ((String) v).trim();
            if (!s.startsWith(".?A")) continue;
            if (descriptors.put(d.getAddress().getOffset() - TD_NAME_OFFSET, s) == null) fromDefined++;
        }
        println("===RTTIREBUILD===");
        println("  type descriptors            : " + descriptors.size()
                + "  (raw byte scan; " + fromDefined + " extra that only defined data had)");
        if (descriptors.isEmpty()) {
            println("===RTTIREBUILDDONE===");
            return;
        }

        // --- 2. what points at them = the COLs ------------------------------
        Map<Long, List<Long>> toDescriptor = pointersTo(descriptors.keySet());
        int descriptorsPointedAt = toDescriptor.size();

        // A real COL has its TypeDescriptor pointer at +0x0C and signature 0.
        Map<Long, Long> colToDescriptor = new TreeMap<>();
        int wrongOffset = 0, badSignature = 0;
        for (Map.Entry<Long, List<Long>> e : toDescriptor.entrySet()) {
            for (long site : e.getValue()) {
                long col = site - COL_TYPE_OFFSET;
                if (readInt(col) != 0) {
                    if (readInt(col) == -1) wrongOffset++; else badSignature++;
                    continue;
                }
                colToDescriptor.put(col, e.getKey());
            }
        }
        println("  descriptors pointed at      : " + descriptorsPointedAt
                + "  (the earlier probe asked about the NAME string, 8 bytes in, and got 0)");
        println("  complete object locators    : " + colToDescriptor.size()
                + "  (signature 0 at -0x0C)");
        println("    rejected, bad signature   : " + badSignature);
        println("    rejected, unreadable      : " + wrongOffset);
        if (colToDescriptor.isEmpty()) {
            println("===RTTIREBUILDDONE===");
            return;
        }

        // --- 3. what points at the COLs = vftable[-1] -----------------------
        Map<Long, List<Long>> toCol = pointersTo(colToDescriptor.keySet());
        FunctionManager fm = currentProgram.getFunctionManager();

        // vftable -> class name, plus how many slots really resolve to code.
        Map<Long, String> vftables = new TreeMap<>();
        Map<String, Integer> slotsByClass = new TreeMap<>();
        int totalSlots = 0, emptyTables = 0, undefinedSlots = 0;
        for (Map.Entry<Long, List<Long>> e : toCol.entrySet()) {
            String raw = descriptors.get(colToDescriptor.get(e.getKey()));
            String name = raw == null ? null : demangle(raw);
            if (name == null) continue;
            for (long site : e.getValue()) {
                long vft = site + 4;
                // Walk while the words point into EXECUTABLE memory, not while
                // Ghidra happens to have defined a function there. The first
                // version of this used getFunctionAt as the loop condition and
                // stopped at the first undefined entry, which cut the average
                // table to 1.4 slots -- an artefact of Ghidra's coverage, not
                // of the binary. Two vftables are always separated by their
                // COL pointer, which is .rdata and not executable, so the
                // walk still terminates on its own at the right place.
                int slots = 0, defined = 0;
                for (long a = vft; ; a += 4) {
                    int p = readInt(a);
                    if (!isCode(p)) break;
                    slots++;
                    if (fm.getFunctionAt(toAddr(p & 0xffffffffL)) != null) defined++;
                    if (slots > 4096) break;
                }
                if (slots == 0) { emptyTables++; continue; }
                vftables.put(vft, name);
                slotsByClass.merge(name, slots, Integer::sum);
                totalSlots += slots;
                undefinedSlots += slots - defined;
            }
        }
        // A walk this productive has to be checked against something it did
        // not produce. `probe <hex>` prints one recovered table in full, so a
        // vftable whose slots this project derived BY HAND -- 0x00af59fc on
        // the server, where slot 73 is GetLevel, 92 exp-gain, 93 the SP adder
        // and 421 GiveExp -- either reproduces those four or does not. If the
        // walk over-ran into the next table, or the slot numbering is off by
        // the COL word, this is where it shows.
        if (probeAt != 0) {
            String cls = vftables.get(probeAt);
            println("  PROBE " + toAddr(probeAt) + " class=" + (cls == null ? "(not a recovered vftable)" : cls));
            int slot = 0;
            for (long a = probeAt; ; a += 4, slot++) {
                int p = readInt(a);
                if (!isCode(p)) break;
                Function f = fm.getFunctionAt(toAddr(p & 0xffffffffL));
                if (slot == 73 || slot == 92 || slot == 93 || slot == 421) {
                    println(String.format("    slot %3d -> %s  %s", slot,
                            toAddr(p & 0xffffffffL), f == null ? "(no function defined)" : f.getName()));
                }
            }
            println("    slots in this table       : " + slot);
        }

        println("  vftables recovered          : " + vftables.size());
        println("    (candidates with no code) : " + emptyTables);
        println("  distinct classes            : " + slotsByClass.size());
        println("  virtual slots pointing at code: " + totalSlots);
        println("    of those, no function yet : " + undefinedSlots
                + "  (real virtuals Ghidra never defined; naming them needs a re-dump)");

        // --- 4. apply -------------------------------------------------------
        // Which classes claim each function, and at which slot. A C++ base
        // class's implementation appears in EVERY derived class's table, so
        // "the first table wins" would confidently file a base method under
        // some arbitrary subclass. Collect all the claims first and let the
        // evidence decide.
        Map<Long, List<String>> claims = new HashMap<>();   // function entry -> "Class#slot"
        Map<Long, Set<String>> claimClasses = new HashMap<>();
        Map<Long, Integer> claimSlot = new HashMap<>();
        for (Map.Entry<Long, String> e : vftables.entrySet()) {
            int slot = 0;
            for (long a = e.getKey(); ; a += 4, slot++) {
                int p = readInt(a);
                if (!isCode(p)) break;
                long entry = p & 0xffffffffL;
                claims.computeIfAbsent(entry, k -> new ArrayList<>()).add(e.getValue() + "#" + slot);
                claimClasses.computeIfAbsent(entry, k -> new HashSet<>()).add(e.getValue());
                claimSlot.putIfAbsent(entry, slot);
            }
        }
        int single = 0, shared = 0;
        for (Map.Entry<Long, Set<String>> e : claimClasses.entrySet()) {
            if (e.getValue().size() == 1) single++; else shared++;
        }
        println("  slot targets, ONE class each: " + single + "  (nameable)");
        println("  slot targets, several classes: " + shared
                + "  (inherited -- commented with every claim, not named)");

        int namedFns = 0, alreadyNamed = 0, nsFailed = 0, commented = 0, undefined = 0;
        if (apply) {
            SymbolTable st = currentProgram.getSymbolTable();
            Map<String, Namespace> cache = new HashMap<>();
            for (Map.Entry<Long, List<String>> e : claims.entrySet()) {
                if (monitor.isCancelled()) break;
                Function f = fm.getFunctionAt(toAddr(e.getKey()));
                if (f == null) { undefined++; continue; }

                // The claim list is pure fact and always goes on, whatever the
                // function is already called -- it is the class and slot the
                // binary itself files this code under.
                List<String> all = e.getValue();
                StringBuilder note = new StringBuilder("RTTI: reached as");
                int shown = 0;
                for (String c : all) {
                    note.append(shown == 0 ? " " : ", ").append(c.replace("#", " slot "));
                    if (++shown >= 8) { note.append(", and ").append(all.size() - shown).append(" more"); break; }
                }
                note.append(".\nRecovered by walking the MSVC chain vftable[-1] -> COL ->")
                    .append(" TypeDescriptor; the class names are the binary's own.");
                String had = f.getComment();
                if (had == null || !had.contains("RTTI: reached as")) {
                    f.setComment(had == null || had.isEmpty() ? note.toString() : had + "\n" + note);
                    commented++;
                }

                // A name only where exactly one class claims it, and only over
                // a blank. A hand-proven name outranks a recovered one.
                Set<String> classes = claimClasses.get(e.getKey());
                if (classes.size() != 1) continue;
                if (!f.getName().startsWith("FUN_")) { alreadyNamed++; continue; }
                String cls = classes.iterator().next();
                Namespace ns = cache.get(cls);
                if (ns == null) {
                    try {
                        ns = st.getNamespace(cls, null);
                        if (ns == null) ns = st.createNameSpace(null, cls, SourceType.ANALYSIS);
                        cache.put(cls, ns);
                    } catch (Exception ex) {
                        nsFailed++;
                        continue;
                    }
                }
                try {
                    f.setParentNamespace(ns);
                    f.setName(String.format("vslot_%03d", claimSlot.get(e.getKey())), SourceType.ANALYSIS);
                    namedFns++;
                } catch (Exception ex) {
                    // a duplicate name inside the class, or a thunk -- skip
                }
            }
            println("  functions named             : " + namedFns);
            println("    commented with their class: " + commented);
            println("    left alone, already named : " + alreadyNamed);
            println("    no function defined yet   : " + undefined);
            println("    namespaces refused        : " + nsFailed);
        } else {
            println("  (report only -- pass 'apply' to write)");
        }

        List<Map.Entry<String, Integer>> top = new ArrayList<>(slotsByClass.entrySet());
        top.sort((a, b) -> Integer.compare(b.getValue(), a.getValue()));
        int shown = 0;
        for (Map.Entry<String, Integer> m : top) {
            println(String.format("    %-46s %d slots", m.getKey(), m.getValue()));
            if (++shown >= maxReport) { println("    ... " + (top.size() - shown) + " more"); break; }
        }
        println("===RTTIREBUILDDONE===");
    }
}
