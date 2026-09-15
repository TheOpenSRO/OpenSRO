// Name virtual methods by letting the base class tell you what a slot IS.
//
// This is the lever that found berserk. `IGObj::UpdateHwanLevel`'s base
// implementation is a stub that does nothing but log its own name:
//
//     "## Illegal ##  IGObj::UpdateHwanLevel TypeID: %u"
//
// RTTI says that stub sits at slot 197. Those two facts together do not name
// one function -- they name SLOT 197 IN EVERY CLASS THAT INHERITS IT. The
// override in CGObjChar's table at 197 is CGObjChar::UpdateHwanLevel, and so
// on down the hierarchy, without reading any of them.
//
// 268 such (class, slot, method) triples are sitting in the server's own
// strings, and they are the game's own spelling: CGStorageOP::PushItem,
// CGStorageOP::RandomSelectNonEmptySlotForDeathPenalty,
// CGItemCOSSummoner::SetEngagedCOSforOpenMarket, CBasicQuest::SetupMissionNPC.
//
// The rule that keeps this honest: the STRING names the declaring class, so
// the seed is (class named in the string, slot) -> method, and it propagates
// only to vtables whose class IS that class or has it in its base chain. Slot
// numbers are meaningless across unrelated hierarchies -- CGStorageOP slot 38
// and CGObjChar slot 38 are different methods -- and keying on the string's
// own class is what prevents mixing them.
//
// Overwrites `FUN_*` and the `vslot_NNN` placeholders RttiRebuild leaves,
// because a real method name strictly beats a slot number. Never overwrites a
// name somebody reasoned about one at a time.
//
// Usage: -postScript NameVtableSlotsFromAsserts.java [apply] [maxReport]
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Data;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionIterator;
import ghidra.program.model.listing.FunctionManager;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.InstructionIterator;
import ghidra.program.model.mem.MemoryBlock;
import ghidra.program.model.scalar.Scalar;
import ghidra.program.model.symbol.Namespace;
import ghidra.program.model.symbol.SourceType;
import ghidra.program.model.symbol.SymbolTable;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public class NameVtableSlotsFromAsserts extends GhidraScript {

    private static final int TD_NAME_OFFSET = 8;
    private static final int COL_TYPE_OFFSET = 0x0C;
    private static final int COL_HIERARCHY_OFFSET = 0x10;

    /** Class::Method inside a string literal. */
    private static final Pattern QUALIFIED =
        Pattern.compile("([A-Z][A-Za-z0-9_]{2,60})::(~?[A-Za-z_][A-Za-z0-9_]{2,60})");

    private int readInt(long a) {
        try { return currentProgram.getMemory().getInt(toAddr(a)); } catch (Exception e) { return -1; }
    }

    private boolean readable(long a) {
        try {
            MemoryBlock b = currentProgram.getMemory().getBlock(toAddr(a));
            return b != null && b.isInitialized();
        } catch (Exception e) { return false; }
    }

    private boolean isCode(int w) {
        if (w == 0 || w == -1) return false;
        try {
            MemoryBlock b = currentProgram.getMemory().getBlock(toAddr(w & 0xffffffffL));
            return b != null && b.isInitialized() && b.isExecute();
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
        if (!s.isEmpty() && (s.charAt(0) == 'V' || s.charAt(0) == 'U' || s.charAt(0) == 'W')) s = s.substring(1);
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

    /** Every string literal this function references. */
    private List<String> stringsOf(Function f) {
        List<String> out = new ArrayList<>();
        InstructionIterator it = currentProgram.getListing().getInstructions(f.getBody(), true);
        while (it.hasNext()) {
            Instruction ins = it.next();
            for (int i = 0; i < ins.getNumOperands(); i++) {
                for (Object o : ins.getOpObjects(i)) {
                    if (!(o instanceof Scalar)) continue;
                    long v = ((Scalar) o).getUnsignedValue();
                    Address a;
                    try { a = toAddr(v); } catch (Exception e) { continue; }
                    Data d = getDataAt(a);
                    if (d == null) continue;
                    Object val = d.getValue();
                    if (val instanceof String) out.add((String) val);
                }
            }
        }
        return out;
    }

    public void run() throws Exception {
        String[] args = getScriptArgs();
        boolean apply = args.length > 0 && args[0].equalsIgnoreCase("apply");
        int maxReport = args.length > 1 ? Integer.parseInt(args[1]) : 30;

        // --- RTTI: descriptors, COLs, vftables, hierarchies -----------------
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
        Map<Long, List<Long>> toDescriptor = pointersTo(descriptors.keySet());
        Map<Long, Long> colToDescriptor = new TreeMap<>();
        for (Map.Entry<Long, List<Long>> e : toDescriptor.entrySet()) {
            for (long site : e.getValue()) {
                long col = site - COL_TYPE_OFFSET;
                if (readable(col) && readInt(col) == 0) colToDescriptor.put(col, e.getKey());
            }
        }
        // class -> its base chain
        Map<String, Set<String>> basesOf = new HashMap<>();
        for (Map.Entry<Long, Long> e : colToDescriptor.entrySet()) {
            String self = demangle(descriptors.get(e.getValue()));
            if (self == null) continue;
            long chd = readInt(e.getKey() + COL_HIERARCHY_OFFSET) & 0xffffffffL;
            if (!readable(chd)) continue;
            int n = readInt(chd + 8);
            long arr = readInt(chd + 0x0C) & 0xffffffffL;
            if (n <= 0 || n > 64 || !readable(arr)) continue;
            Set<String> chain = new LinkedHashSet<>();
            for (int i = 0; i < n; i++) {
                long bcd = readInt(arr + 4L * i) & 0xffffffffL;
                if (!readable(bcd)) break;
                String nm = descriptors.get(readInt(bcd) & 0xffffffffL);
                if (nm == null) break;
                String d = demangle(nm);
                if (d != null) chain.add(d);
            }
            if (!chain.isEmpty()) basesOf.put(self, chain);
        }
        // vftable -> class, and (class,slot) -> function entry
        Map<Long, List<Long>> toCol = pointersTo(colToDescriptor.keySet());
        Map<String, Map<Integer, Long>> slotOf = new HashMap<>();
        Map<Long, List<String>> classesAtEntry = new HashMap<>();
        Map<Long, Integer> slotAtEntry = new HashMap<>();
        for (Map.Entry<Long, List<Long>> e : toCol.entrySet()) {
            String cls = demangle(descriptors.get(colToDescriptor.get(e.getKey())));
            if (cls == null) continue;
            for (long site : e.getValue()) {
                int slot = 0;
                for (long a = site + 4; ; a += 4, slot++) {
                    int p = readInt(a);
                    if (!isCode(p)) break;
                    long entry = p & 0xffffffffL;
                    slotOf.computeIfAbsent(cls, k -> new HashMap<>()).put(slot, entry);
                    classesAtEntry.computeIfAbsent(entry, k -> new ArrayList<>()).add(cls);
                    slotAtEntry.putIfAbsent(entry, slot);
                }
            }
        }

        // --- the seeds: a function whose own string names a class::method ---
        // keyed (declaringClass, slot) -> method
        Map<String, String> seeds = new TreeMap<>();
        FunctionManager fm = currentProgram.getFunctionManager();
        FunctionIterator fit = fm.getFunctions(true);
        int candidates = 0, rejectedNoSlot = 0, rejectedClassMismatch = 0, rejectedNotMethod = 0;
        List<String> seedReport = new ArrayList<>();
        while (fit.hasNext() && !monitor.isCancelled()) {
            Function f = fit.next();
            long entry = f.getEntryPoint().getOffset();
            Integer slot = slotAtEntry.get(entry);
            List<String> cls = classesAtEntry.get(entry);
            for (String s : stringsOf(f)) {
                Matcher m = QUALIFIED.matcher(s);
                while (m.find()) {
                    String c = m.group(1), meth = m.group(2);
                    candidates++;
                    // `Class::member` is not a method. The client's
                    // "CObjChild::m_pGfxDevice is null" would otherwise seed
                    // slot 15 of the root of the entire UI hierarchy and
                    // mis-name a few hundred functions from one string. m_ is
                    // this codebase's member prefix; an ALL_CAPS tail is a
                    // constant or enumerator, not a call either.
                    if (meth.startsWith("m_") || meth.equals(meth.toUpperCase())) {
                        rejectedNotMethod++;
                        continue;
                    }
                    if (slot == null || cls == null) { rejectedNoSlot++; continue; }
                    // The string's class must actually be one this function is
                    // reached through, or a base of one. Otherwise the string
                    // is talking about somebody else -- an assert naming the
                    // function it CALLED, which is how an earlier pass here
                    // produced eight wrong names out of 29.
                    boolean related = false;
                    for (String c2 : cls) {
                        if (c2.equals(c)) { related = true; break; }
                        Set<String> b = basesOf.get(c2);
                        if (b != null && b.contains(c)) { related = true; break; }
                    }
                    if (!related) { rejectedClassMismatch++; continue; }
                    String key = c + "#" + slot;
                    if (seeds.putIfAbsent(key, meth) == null) {
                        seedReport.add(String.format("  %-44s slot %-4d %s", c, slot, meth));
                    }
                }
            }
        }

        println("===VSLOTASSERTS===");
        println("  Class::Method strings seen  : " + candidates);
        println("    no vtable slot for the fn : " + rejectedNoSlot);
        println("    string names another class: " + rejectedClassMismatch + "  (rejected)");
        println("    not a method (m_ / CAPS)  : " + rejectedNotMethod + "  (rejected)");
        println("  seeds (class, slot -> method): " + seeds.size());

        // --- propagate: every class that inherits the declaring class -------
        // Counted as DISTINCT FUNCTIONS, not (seed, class) pairs. An
        // inherited implementation is one function reached through every
        // derived class's table, so the pair count reads about thirteen times
        // higher than the number of functions that actually get a name -- a
        // report saying "6,325 nameable" ahead of an apply that names 474.
        Set<Long> wouldNameSet = new HashSet<>();
        int named = 0, skippedNamed = 0, clash = 0;
        SymbolTable st = currentProgram.getSymbolTable();
        Map<String, Namespace> nsCache = new HashMap<>();
        for (Map.Entry<String, String> seed : seeds.entrySet()) {
            if (monitor.isCancelled()) break;
            int hash = seed.getKey().lastIndexOf('#');
            String declaring = seed.getKey().substring(0, hash);
            int slot = Integer.parseInt(seed.getKey().substring(hash + 1));
            String meth = seed.getValue();

            for (Map.Entry<String, Map<Integer, Long>> e : slotOf.entrySet()) {
                String cls = e.getKey();
                if (!cls.equals(declaring)) {
                    Set<String> b = basesOf.get(cls);
                    if (b == null || !b.contains(declaring)) continue;
                }
                Long entry = e.getValue().get(slot);
                if (entry == null) continue;
                Function f = fm.getFunctionAt(toAddr(entry));
                if (f == null) continue;
                String cur = f.getName();
                // Only a blank or RttiRebuild's slot-number placeholder.
                if (!cur.startsWith("FUN_") && !cur.startsWith("vslot_")) { skippedNamed++; continue; }
                wouldNameSet.add(entry);
                if (!apply) continue;
                try {
                    Namespace ns = nsCache.get(cls);
                    if (ns == null) {
                        ns = st.getNamespace(cls, null);
                        if (ns == null) ns = st.createNameSpace(null, cls, SourceType.ANALYSIS);
                        nsCache.put(cls, ns);
                    }
                    f.setParentNamespace(ns);
                    f.setName(meth, SourceType.ANALYSIS);
                    String had = f.getComment();
                    String note = "Named from the base class's own assert: " + declaring + "::" + meth
                            + " is vtable slot " + slot + ", so this override is " + cls + "::" + meth + ".";
                    if (had == null || !had.contains("Named from the base class's own assert")) {
                        f.setComment(had == null || had.isEmpty() ? note : had + "\n" + note);
                    }
                    named++;
                } catch (Exception ex) {
                    clash++;
                }
            }
        }
        println("  DISTINCT functions nameable : " + wouldNameSet.size()
                + (apply ? "" : "  (report only, pass 'apply')"));
        if (apply) {
            println("    named                     : " + named);
            println("    name clash inside class   : " + clash);
        }
        println("    already named, left alone : " + skippedNamed);
        int shown = 0;
        for (String s : seedReport) {
            println(s);
            if (++shown >= maxReport) { println("  ... " + (seedReport.size() - shown) + " more seeds"); break; }
        }
        println("===VSLOTASSERTSDONE===");
    }
}
