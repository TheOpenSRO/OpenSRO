// What RTTI did Ghidra actually build, and where are the type descriptors?
//
// This binary carries 1,882 ".?AV...@@" type-descriptor strings -- including
// bad_cast, bad_typeid and type_info, so RTTI is genuinely compiled in, not
// just exception metadata. Yet Ghidra's RTTI analyser reports one vftable, and
// class recovery therefore has nothing to work with. Before writing a bespoke
// vftable finder it is worth knowing whether the analyser built the structures
// under names a naive "vftable"/"RTTI" symbol grep would miss.
//
// Reports: how many type-descriptor strings exist, how many are referenced at
// all (a descriptor nothing points at cannot be reached from a vftable), a
// breakdown of symbol names that look class-related, and the namespaces in
// use -- which is where recovered classes would show up.
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Data;
import ghidra.program.model.listing.DataIterator;
import ghidra.program.model.symbol.Namespace;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.ReferenceIterator;
import ghidra.program.model.symbol.ReferenceManager;
import ghidra.program.model.symbol.Symbol;
import ghidra.program.model.symbol.SymbolIterator;

import java.util.HashMap;
import java.util.Map;

public class RttiProbe extends GhidraScript {

    public void run() throws Exception {
        ReferenceManager rm = currentProgram.getReferenceManager();

        int descriptors = 0, referenced = 0, unreferenced = 0;
        Address firstReferenced = null;
        DataIterator di = currentProgram.getListing().getDefinedData(true);
        while (di.hasNext() && !monitor.isCancelled()) {
            Data d = di.next();
            Object v = d.getValue();
            if (!(v instanceof String)) continue;
            String s = (String) v;
            if (!s.startsWith(".?A")) continue;
            descriptors++;
            ReferenceIterator it = rm.getReferencesTo(d.getAddress());
            if (it.hasNext()) {
                referenced++;
                if (firstReferenced == null) firstReferenced = d.getAddress();
            } else {
                unreferenced++;
            }
        }

        println("===RTTIPROBE===");
        println("  type-descriptor strings found as DATA : " + descriptors);
        println("    referenced by something             : " + referenced);
        println("    referenced by nothing               : " + unreferenced);
        if (firstReferenced != null) println("    first referenced at              : " + firstReferenced);

        // Namespaces are where recovered classes land.
        Map<String, Integer> ns = new HashMap<>();
        SymbolIterator si = currentProgram.getSymbolTable().getSymbolIterator();
        int symbols = 0, mangled = 0;
        while (si.hasNext() && !monitor.isCancelled()) {
            Symbol s = si.next();
            symbols++;
            if (s.getName().contains("@@")) mangled++;
            Namespace n = s.getParentNamespace();
            if (n != null && !n.isGlobal()) {
                ns.merge(n.getName(), 1, Integer::sum);
            }
        }
        println("  total symbols                         : " + symbols);
        println("  symbols still mangled (@@)            : " + mangled);
        println("  non-global namespaces                 : " + ns.size());
        int shown = 0;
        for (Map.Entry<String, Integer> e : ns.entrySet()) {
            println("    ns " + e.getKey() + " : " + e.getValue());
            if (++shown >= 12) break;
        }
        println("===RTTIPROBEDONE===");
    }
}
