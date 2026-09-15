// Recover a register-passed argument at every call site, undoing the LEA chains.
//
// Why this exists. ParamKeeper_SetParam takes the parameter's IDENTITY in DI --
// `MOVZX EDX,DI` then `MOV ECX,[ESI + EDX*4 + 4]` indexes the keeper's array of
// per-param objects. Ghidra never assigned EDI to a parameter, so all 299 call
// sites decompile to SetParam(slot, 0, value) with the identity silently
// missing. The C reads fine and tells you nothing.
//
// Worse, the callers do not load the id with MOV. The optimiser materialises
// each constant from whichever register already holds a nearby one:
//
//     MOV  EDI,0x3
//     LEA  EBX,[EDI + 0x33]      ; EBX = 0x36
//     LEA  EDI,[EBX + -0x32]     ; EDI = 0x04
//     LEA  EBX,[EDI + 0x33]      ; EBX = 0x37
//     LEA  EDI,[EBX + -0x1]      ; EDI = 0x36  <- the id this call actually uses
//
// LEA is three bytes where MOV imm32 is five, so a long run of small constants
// comes out as a ping-pong between two registers and no constant is ever
// written down. Grepping for "MOV EDI" finds a handful of the 299 and misses
// the rest -- and, worse, the ones it finds are stale by the time of the call.
//
// So: walk each calling function forwards in address order, keeping a tiny
// abstract state over the general registers, and read the argument register off
// that state at each call. Only the moves that actually appear in these chains
// are modelled -- MOV reg,imm / MOV reg,reg / LEA reg,[reg+imm] / XOR reg,reg --
// and anything else that writes a register makes it UNKNOWN rather than
// guessing. Unknown is reported as unknown; this project does not ship a number
// it cannot show the derivation for.
//
// Two soundness rules, both deliberately conservative:
//   - any instruction that is a branch target clears the whole state, since the
//     value arriving there depends on which edge was taken;
//   - a CALL clears only the caller-saved registers (EAX/ECX/EDX). EBX, ESI,
//     EDI and EBP survive a call under both cdecl and stdcall, which is exactly
//     why the optimiser parks the chain in them, and why the chains span calls.
//
// With 'annotate' the resolved value is written back as a pre-comment on the
// call instruction. That is the point of the whole exercise: the decompiler
// prints pre-comments into the C, so after the next dump every one of the 297
// call sites reads
//
//     /* ParamKeeper param id = 0x36 (54) */
//     ParamKeeper_SetParam(3,0,(float)fVar6 * fVar1);
//
// and the identity that the calling convention threw away is back in the source
// for good -- in the binary, not in a commit message.
//
// Several registers can be resolved at once. ParamKeeper_BindDerived needs it:
// it takes TWO ids, EBX and EDI, calls EnsureParam on each and then binds one
// into a slot of the other -- so resolving only one register would show half of
// a dependency edge, which is worse than showing none.
//
// Usage: -postScript ResolveRegArg.java <addr[,addr...]> <REG[,REG...]> [maxReport] [annotate] [label]
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.lang.Register;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionManager;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.InstructionIterator;
import ghidra.program.model.scalar.Scalar;
import ghidra.program.model.symbol.FlowType;
import ghidra.program.model.symbol.Reference;
import ghidra.program.model.symbol.ReferenceIterator;
import ghidra.program.model.symbol.ReferenceManager;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;

public class ResolveRegArg extends GhidraScript {

    /** Registers the ABI lets a call destroy. The chains live in the others. */
    private static final String[] CALLER_SAVED = {"EAX", "ECX", "EDX"};

    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length < 2) { println("usage: <calleeAddr> <REG> [maxReport]"); return; }
        String[] wantRegs = args[1].toUpperCase().split(",");
        int maxReport = args.length > 2 ? Integer.parseInt(args[2]) : 500;
        boolean annotate = args.length > 3 && args[3].equalsIgnoreCase("annotate");
        String label = args.length > 4 ? args[4] : "param id";

        FunctionManager fm = currentProgram.getFunctionManager();
        List<Address> callees = new ArrayList<>();
        for (String one : args[0].split(",")) {
            Address c = currentProgram.getAddressFactory().getAddress(one.trim());
            if (c == null || fm.getFunctionAt(c) == null) { println("no function at " + one); continue; }
            callees.add(c);
        }
        if (callees.isEmpty()) return;

        // Group the call sites by the function they sit in, so each caller is
        // simulated once no matter how many times it calls.
        ReferenceManager rm = currentProgram.getReferenceManager();
        Map<Address, Set<Address>> byCaller = new TreeMap<>();
        StringBuilder names = new StringBuilder();
        int callSites = 0;
        for (Address callee : callees) {
            if (names.length() > 0) names.append(", ");
            names.append(fm.getFunctionAt(callee).getName(true));
            ReferenceIterator it = rm.getReferencesTo(callee);
            while (it.hasNext() && !monitor.isCancelled()) {
                Reference r = it.next();
                if (!r.getReferenceType().isCall()) continue;
                Function f = fm.getFunctionContaining(r.getFromAddress());
                if (f == null) continue;
                byCaller.computeIfAbsent(f.getEntryPoint(), k -> new HashSet<>())
                        .add(r.getFromAddress());
                callSites++;
            }
        }

        println("===RESOLVEREGARG=== callee=" + names + " reg=" + String.join(",", wantRegs));
        println("  call sites : " + callSites + " in " + byCaller.size() + " functions");

        List<String> lines = new ArrayList<>();
        Map<String, Map<Long, Integer>> histogram = new TreeMap<>();
        int resolved = 0, partial = 0, unknown = 0;

        for (Map.Entry<Address, Set<Address>> e : byCaller.entrySet()) {
            Function caller = fm.getFunctionAt(e.getKey());
            if (caller == null) continue;
            Map<Address, Map<String, Long>> at = simulate(caller, wantRegs, e.getValue());
            for (Address site : sorted(e.getValue())) {
                Map<String, Long> vals = at.getOrDefault(site, new HashMap<>());
                StringBuilder show = new StringBuilder();
                StringBuilder note = new StringBuilder();
                int have = 0;
                for (String r : wantRegs) {
                    Long v = vals.get(r);
                    if (show.length() > 0) { show.append("  "); note.append(", "); }
                    if (v == null) {
                        show.append(r).append(" = ?");
                    } else {
                        have++;
                        histogram.computeIfAbsent(r, k -> new TreeMap<>()).merge(v, 1, Integer::sum);
                        show.append(String.format("%s = 0x%x (%d)", r, v, v));
                        note.append(String.format("%s 0x%x (%d)", r, v, v));
                    }
                }
                if (have == wantRegs.length) resolved++;
                else if (have > 0) partial++;
                else unknown++;
                lines.add(String.format("  %s  %-44s  %s", site, caller.getName(true), show));
                // Annotate whatever was proved, even when only one of two
                // registers resolved -- half an edge, clearly labelled, still
                // beats nothing, and the "?" in the listing says which half.
                if (annotate && have > 0) setPreComment(site, label + ": " + note);
            }
        }

        println("  fully resolved: " + resolved + "   partial: " + partial + "   unknown: " + unknown
                + (annotate ? "   (annotated)" : ""));
        for (Map.Entry<String, Map<Long, Integer>> hr : histogram.entrySet()) {
            println("  --- distinct values of " + hr.getKey() + " ---");
            for (Map.Entry<Long, Integer> h : hr.getValue().entrySet()) {
                println(String.format("  id 0x%02x (%3d) used %d times",
                        h.getKey(), h.getKey(), h.getValue()));
            }
        }
        println("  --- call sites ---");
        int shown = 0;
        for (String l : lines) {
            println(l);
            if (++shown >= maxReport) { println("  ... " + (lines.size() - shown) + " more"); break; }
        }
        println("===RESOLVEREGARGDONE===");
    }

    private List<Address> sorted(Set<Address> s) {
        List<Address> l = new ArrayList<>(s);
        l.sort(Address::compareTo);
        return l;
    }

    /** Forward abstract interpretation of one function; returns reg values at each wanted site. */
    private Map<Address, Map<String, Long>> simulate(Function f, String[] wantRegs, Set<Address> sites) {
        Map<String, Long> regs = new HashMap<>();
        Map<Address, Map<String, Long>> out = new HashMap<>();
        ReferenceManager rm = currentProgram.getReferenceManager();

        InstructionIterator ii = currentProgram.getListing().getInstructions(f.getBody(), true);
        while (ii.hasNext() && !monitor.isCancelled()) {
            Instruction ins = ii.next();

            // A branch target's incoming value depends on the edge taken.
            if (rm.hasReferencesTo(ins.getAddress())) {
                boolean jumpedTo = false;
                ReferenceIterator ri = rm.getReferencesTo(ins.getAddress());
                while (ri.hasNext()) {
                    if (ri.next().getReferenceType().isJump()) { jumpedTo = true; break; }
                }
                if (jumpedTo) regs.clear();
            }

            if (sites.contains(ins.getAddress())) {
                Map<String, Long> snap = new HashMap<>();
                for (String r : wantRegs) {
                    Long v = regs.get(r);
                    if (v != null) snap.put(r, v);
                }
                out.put(ins.getAddress(), snap);
            }

            apply(ins, regs);
        }
        return out;
    }

    /** Model the handful of forms the constant chains actually use. */
    private void apply(Instruction ins, Map<String, Long> regs) {
        String m = ins.getMnemonicString().toUpperCase();
        FlowType ft = ins.getFlowType();

        if (ft != null && ft.isCall()) {
            for (String r : CALLER_SAVED) regs.remove(r);
            return;                       // callee-saved registers carry the chain
        }

        Register dst = ins.getRegister(0);

        if (m.equals("MOV") && dst != null && ins.getNumOperands() == 2) {
            Scalar s = ins.getScalar(1);
            Register src = ins.getRegister(1);
            if (s != null) { regs.put(dst.getName(), s.getUnsignedValue()); return; }
            if (src != null && regs.containsKey(src.getName())) {
                regs.put(dst.getName(), regs.get(src.getName())); return;
            }
            regs.remove(dst.getName());
            return;
        }

        if (m.equals("LEA") && dst != null) {
            // [base + disp] -- the only addressing form these chains produce.
            Object[] ops = ins.getOpObjects(1);
            Register base = null;
            long disp = 0;
            boolean ok = true;
            for (Object o : ops) {
                if (o instanceof Register) {
                    if (base != null) { ok = false; break; }   // [r1 + r2], not a constant
                    base = (Register) o;
                } else if (o instanceof Scalar) {
                    disp = ((Scalar) o).getSignedValue();
                } else { ok = false; break; }
            }
            if (ok && base != null && regs.containsKey(base.getName())) {
                regs.put(dst.getName(), (regs.get(base.getName()) + disp) & 0xffffffffL);
                return;
            }
            regs.remove(dst.getName());
            return;
        }

        if (m.equals("XOR") && dst != null) {
            Register src = ins.getRegister(1);
            if (src != null && src.getName().equals(dst.getName())) {
                regs.put(dst.getName(), 0L); return;
            }
        }

        // Anything else: whatever it writes becomes unknown. Never guessed.
        for (Object o : ins.getResultObjects()) {
            if (o instanceof Register) regs.remove(((Register) o).getName());
        }
    }
}
