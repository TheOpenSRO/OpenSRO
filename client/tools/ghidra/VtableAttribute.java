// Reach the virtual functions, which nothing else can.
//
// CodeCensus found 18,522 game-logic functions with no direct caller across the
// two binaries. They are not dead: a virtual is reached only through a vtable
// slot, and Ghidra does not resolve those, so every lever that works from the
// call graph -- PropagateModules most of all -- steps straight past them. They
// are also disproportionately important: GObjPC_GainExpAndLevel, GObjPC_GiveExp
// and Char_GetLevel are all in that population, and each one took a manual
// vtable read to find (slot 92, slot 421, slot 73).
//
// The vtables themselves are findable without RTTI -- which is just as well,
// because this binary's RTTI is stripped (RttiProbe: 1,871 type descriptors,
// zero referenced). A C++ vtable is a run of consecutive pointers into
// executable code sitting in read-only data, and that shape is unmistakable.
//
// Two outputs, again kept apart by how certain they are:
//
//   COMMENT  every function found in such a table gets a plate comment naming
//            the table and the slot. That is the fact this project has had to
//            re-derive by hand four times now, and it makes "which slot is
//            this?" a grep instead of an afternoon.
//
//   MODULE   a namespace, only when the table's OWN slots vote for one: at
//            least `minAgree` already-attributed slots, and at least two thirds
//            of the attributed ones agreeing. A class's vtable is mostly its
//            own methods, so a clear majority is real evidence; a scattering is
//            inherited base-class slots and earns nothing.
//
// The comment says "pointer table" rather than "vtable" because the shape alone
// cannot tell a vtable from an array of callbacks. The distinction does not
// matter for finding the code, and overstating it would be the usual mistake.
//
// Usage: -postScript VtableAttribute.java [apply] [minSlots] [minAgree]
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionManager;
import ghidra.program.model.mem.MemoryBlock;
import ghidra.program.model.symbol.Namespace;
import ghidra.program.model.symbol.SourceType;
import ghidra.program.model.symbol.SymbolTable;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;

public class VtableAttribute extends GhidraScript {

    /** One slot: which table, which index. */
    private static final class Slot {
        final long table; final int index;
        Slot(long t, int i) { table = t; index = i; }
    }

    public void run() throws Exception {
        String[] args = getScriptArgs();
        boolean apply = args.length > 0 && args[0].equalsIgnoreCase("apply");
        int minSlots = args.length > 1 ? Integer.parseInt(args[1]) : 4;
        int minAgree = args.length > 2 ? Integer.parseInt(args[2]) : 3;

        FunctionManager fm = currentProgram.getFunctionManager();
        SymbolTable st = currentProgram.getSymbolTable();
        int ptr = currentProgram.getDefaultPointerSize();

        // table start -> the functions in it, by slot
        Map<Long, List<Function>> tables = new LinkedHashMap<>();
        Map<Address, List<Slot>> perFunc = new LinkedHashMap<>();

        for (MemoryBlock b : currentProgram.getMemory().getBlocks()) {
            if (!b.isInitialized() || b.isExecute()) continue;
            Address a = b.getStart();
            Address end = b.getEnd();
            while (a.compareTo(end) < 0 && !monitor.isCancelled()) {
                List<Function> run = new ArrayList<>();
                Address runStart = a;
                while (a.compareTo(end) < 0) {
                    long val;
                    try { val = ptr == 8 ? getLong(a) : (getInt(a) & 0xffffffffL); }
                    catch (Exception e) { break; }
                    if (val == 0) break;
                    Address target;
                    try { target = toAddr(val); } catch (Exception e) { break; }
                    MemoryBlock tb = currentProgram.getMemory().getBlock(target);
                    if (tb == null || !tb.isExecute()) break;
                    run.add(fm.getFunctionAt(target));   // may be null: not a defined function
                    a = a.add(ptr);
                }
                if (run.size() >= minSlots) {
                    tables.put(runStart.getOffset(), run);
                    for (int i = 0; i < run.size(); i++) {
                        Function f = run.get(i);
                        if (f == null) continue;
                        perFunc.computeIfAbsent(f.getEntryPoint(), k -> new ArrayList<>())
                               .add(new Slot(runStart.getOffset(), i));
                    }
                } else if (run.isEmpty()) {
                    a = a.add(ptr);
                }
            }
        }

        // Which module does each table vote for?
        Map<Long, String> tableModule = new HashMap<>();
        for (Map.Entry<Long, List<Function>> e : tables.entrySet()) {
            Map<String, Integer> votes = new HashMap<>();
            int attributed = 0;
            for (Function f : e.getValue()) {
                if (f == null) continue;
                Namespace ns = f.getParentNamespace();
                if (ns == null || ns.isGlobal()) continue;
                votes.merge(ns.getName(), 1, Integer::sum);
                attributed++;
            }
            if (attributed < minAgree) continue;
            String best = null; int bestN = 0;
            for (Map.Entry<String, Integer> v : votes.entrySet()) {
                if (v.getValue() > bestN) { bestN = v.getValue(); best = v.getKey(); }
            }
            // Two thirds of the attributed slots must agree.
            if (best != null && bestN * 3 >= attributed * 2) tableModule.put(e.getKey(), best);
        }

        Map<String, Namespace> cache = new HashMap<>();
        Map<String, Integer> gained = new TreeMap<>();
        int commented = 0, moduled = 0, alreadyNs = 0;

        for (Map.Entry<Address, List<Slot>> e : perFunc.entrySet()) {
            Function f = fm.getFunctionAt(e.getKey());
            if (f == null) continue;
            List<Slot> slots = e.getValue();

            if (apply) {
                StringBuilder note = new StringBuilder(
                    "Virtual: reached through a pointer table, not by a direct call.\n"
                    + "(The shape -- a run of pointers into executable memory in read-only data --\n"
                    + " identifies a vtable or a callback array; it cannot tell the two apart.)\n");
                int shown = 0;
                for (Slot s : slots) {
                    note.append(String.format("  table 0x%08x  slot %d  (offset 0x%x)%n",
                            s.table, s.index, s.index * ptr));
                    if (++shown >= 8) {
                        note.append("  ... and ").append(slots.size() - shown).append(" more\n");
                        break;
                    }
                }
                String had = f.getComment();
                if (had == null || !had.contains("reached through a pointer table")) {
                    f.setComment(had == null || had.isEmpty() ? note.toString() : had + "\n" + note);
                }
            }
            commented++;

            if (f.getParentNamespace() != null && !f.getParentNamespace().isGlobal()) {
                alreadyNs++;
                continue;
            }
            // Take a module only if every table this function sits in agrees.
            String mod = null;
            boolean agree = true;
            for (Slot s : slots) {
                String m = tableModule.get(s.table);
                if (m == null) continue;
                if (mod == null) mod = m;
                else if (!mod.equals(m)) { agree = false; break; }
            }
            if (!agree || mod == null) continue;
            gained.merge(mod, 1, Integer::sum);
            moduled++;
            if (!apply) continue;
            try {
                Namespace ns = cache.get(mod);
                if (ns == null) {
                    ns = st.getNamespace(mod, null);
                    if (ns == null) ns = st.createNameSpace(null, mod, SourceType.ANALYSIS);
                    cache.put(mod, ns);
                }
                f.setParentNamespace(ns);
            } catch (Exception ex) {
                println("  (could not attribute " + e.getKey() + ": " + ex.getMessage() + ")");
            }
        }

        println("===VTABLEATTR===");
        println("  pointer tables (>= " + minSlots + " slots) : " + tables.size());
        println("  tables with a voted module        : " + tableModule.size());
        println("  functions in a table              : " + perFunc.size());
        println("    commented with table+slot       : " + commented
                + (apply ? "" : " (report only, pass 'apply')"));
        println("    already namespaced              : " + alreadyNs);
        println("    newly given a module            : " + moduled);
        List<Map.Entry<String, Integer>> top = new ArrayList<>(gained.entrySet());
        top.sort((a, b) -> Integer.compare(b.getValue(), a.getValue()));
        int shown = 0;
        for (Map.Entry<String, Integer> g : top) {
            println(String.format("      %-30s +%d", g.getKey(), g.getValue()));
            if (++shown >= 20) { println("      ... " + (top.size() - shown) + " more"); break; }
        }
        println("===VTABLEATTRDONE===");
    }
}
