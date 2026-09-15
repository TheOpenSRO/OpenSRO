// Attribute client UI code from the authored string ids it references.
//
// The client does not name its UI functions, but it does name its TEXT: every
// label, message and control caption is looked up by an authored id --
// UIIT_STT_ALCHEMYBOX_TIP_DISMANTLING_BUTTON, UIIT_MSG_..., UIIT_CTL_..., UIO...
// -- and those ids are in the binary as wide string literals. A function that
// asks for one is, with certainty, the code behind that piece of interface.
// 328 functions reference a UIIT_STT_ id alone; the other families add more.
//
// This is the same move as NamespaceFromSourceFile, on a different fact the
// binary states about itself. It produces two things, with different
// confidence, and keeps them apart:
//
//   COMMENT  every function gets a plate comment listing the ids it references,
//            verbatim. That is pure fact and carries no interpretation -- a
//            reader of the dump immediately knows which window they are in.
//
//   MODULE   a namespace, but ONLY when the evidence is a pattern rather than a
//            coincidence: at least two DISTINCT ids sharing a first segment,
//            and no id disagreeing with it. A function citing one
//            UIIT_STT_ACCEPT gets no module, because "ACCEPT" is a word, not a
//            window; a function citing three UIIT_STT_ALCHEMYBOX_* ids gets
//            UI_ALCHEMYBOX, because that is a place.
//
// Deliberately NOT done: naming a function after its label. "the function that
// mentions UIIT_STT_ACCEPT" is not the same claim as "the accept handler", and
// this project does not ship the second when it has only measured the first.
//
// Usage: -postScript LabelFromUIStrings.java [apply] [minIdsForModule]
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Data;
import ghidra.program.model.listing.DataIterator;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionManager;
import ghidra.program.model.symbol.Namespace;
import ghidra.program.model.symbol.ReferenceIterator;
import ghidra.program.model.symbol.ReferenceManager;
import ghidra.program.model.symbol.SourceType;
import ghidra.program.model.symbol.SymbolTable;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;
import java.util.TreeSet;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

public class LabelFromUIStrings extends GhidraScript {

    /** The authored-id families this client uses. */
    private static final Pattern ID =
        Pattern.compile("\\b(UIIT_[A-Z]+_[A-Z0-9_]+|UIO[A-Z0-9_]+)\\b");

    public void run() throws Exception {
        String[] args = getScriptArgs();
        boolean apply = args.length > 0 && args[0].equalsIgnoreCase("apply");
        int minIds = args.length > 1 ? Integer.parseInt(args[1]) : 2;

        ReferenceManager rm = currentProgram.getReferenceManager();
        FunctionManager fm = currentProgram.getFunctionManager();
        SymbolTable st = currentProgram.getSymbolTable();

        Map<Address, Set<String>> perFunc = new LinkedHashMap<>();

        DataIterator di = currentProgram.getListing().getDefinedData(true);
        while (di.hasNext() && !monitor.isCancelled()) {
            Data d = di.next();
            Object v = d.getValue();
            if (!(v instanceof String)) continue;
            String s = ((String) v).trim();
            Matcher m = ID.matcher(s);
            if (!m.matches()) continue;          // the whole literal IS an id

            ReferenceIterator it = rm.getReferencesTo(d.getAddress());
            while (it.hasNext()) {
                Function f = fm.getFunctionContaining(it.next().getFromAddress());
                if (f == null) continue;
                perFunc.computeIfAbsent(f.getEntryPoint(), k -> new TreeSet<>()).add(s);
            }
        }

        Map<String, Namespace> cache = new HashMap<>();
        Map<String, Integer> modules = new TreeMap<>();
        int commented = 0, moduled = 0, alreadyNs = 0, noModule = 0;

        for (Map.Entry<Address, Set<String>> e : perFunc.entrySet()) {
            Function f = fm.getFunctionAt(e.getKey());
            if (f == null) continue;
            Set<String> ids = e.getValue();

            if (apply) {
                StringBuilder note = new StringBuilder(
                    "Client UI code, identified by the authored string ids it asks for.\n"
                    + "These are facts the binary states about itself, not an interpretation:\n");
                int shown = 0;
                for (String id : ids) {
                    note.append("  ").append(id).append('\n');
                    if (++shown >= 12) {
                        note.append("  ... and ").append(ids.size() - shown).append(" more\n");
                        break;
                    }
                }
                String had = f.getComment();
                if (had == null || !had.contains("authored string ids")) {
                    f.setComment(had == null || had.isEmpty() ? note.toString() : had + "\n" + note);
                }
                commented++;
            } else {
                commented++;
            }

            // A module needs a pattern, not one word: several distinct ids that
            // agree on a first segment.
            String seg = null;
            boolean agree = true;
            for (String id : ids) {
                String tail = id.startsWith("UIO") ? id.substring(3) : id.replaceFirst("^UIIT_[A-Z]+_", "");
                int cut = tail.indexOf('_');
                String s0 = cut < 0 ? tail : tail.substring(0, cut);
                if (s0.isEmpty()) { agree = false; break; }
                if (seg == null) seg = s0;
                else if (!seg.equals(s0)) { agree = false; break; }
            }
            if (!agree || seg == null || ids.size() < minIds) { noModule++; continue; }
            if (f.getParentNamespace() != null && !f.getParentNamespace().isGlobal()) {
                alreadyNs++;
                continue;
            }
            modules.merge(seg, 1, Integer::sum);
            moduled++;
            if (!apply) continue;
            try {
                String nsName = "UI_" + seg;
                Namespace ns = cache.get(nsName);
                if (ns == null) {
                    ns = st.getNamespace(nsName, null);
                    if (ns == null) ns = st.createNameSpace(null, nsName, SourceType.ANALYSIS);
                    cache.put(nsName, ns);
                }
                f.setParentNamespace(ns);
            } catch (Exception ex) {
                println("  (could not attribute " + e.getKey() + ": " + ex.getMessage() + ")");
            }
        }

        println("===UILABELS===");
        println("  functions citing an authored id : " + perFunc.size());
        println("  commented                       : " + commented);
        println("  given a UI_<module> namespace   : " + moduled
                + (apply ? "" : " (report only, pass 'apply')"));
        println("    already namespaced, left alone: " + alreadyNs);
        println("    no agreeing module            : " + noModule);
        println("  distinct modules                : " + modules.size());
        List<Map.Entry<String, Integer>> top = new ArrayList<>(modules.entrySet());
        top.sort((a, b) -> Integer.compare(b.getValue(), a.getValue()));
        int shown = 0;
        for (Map.Entry<String, Integer> m : top) {
            println(String.format("    UI_%-28s %d", m.getKey(), m.getValue()));
            if (++shown >= 25) { println("    ... " + (top.size() - shown) + " more"); break; }
        }
        println("===UILABELSDONE===");
    }
}
