// Dump the instructions of one function, with the decompiler kept out of it.
//
// The decompiler is the right tool almost always, but it models a calling
// convention and then hides anything that does not fit it. ParamKeeper_SetParam
// is the case in point: every one of its 299 call sites decompiles to
// SetParam(slot, 0, value) with the parameter *identity* missing, because the
// id travels in a register Ghidra did not assign to a parameter. The C is
// therefore lying by omission, and no amount of reading it would reveal that --
// only the instructions show the register being loaded.
//
// Usage: -postScript Disasm.java <entryAddr> [maxInstructions]
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.Instruction;
import ghidra.program.model.listing.InstructionIterator;

public class Disasm extends GhidraScript {

    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length < 1) { println("need an address"); return; }
        Address a = currentProgram.getAddressFactory().getAddress(args[0]);
        int max = args.length > 1 ? Integer.parseInt(args[1]) : 400;

        Function f = currentProgram.getFunctionManager().getFunctionAt(a);
        if (f == null) { println("no function at " + args[0]); return; }

        println("===DISASM=== " + f.getName(true) + " @ " + a);
        InstructionIterator it =
            currentProgram.getListing().getInstructions(f.getBody(), true);
        int n = 0;
        while (it.hasNext() && n < max && !monitor.isCancelled()) {
            Instruction ins = it.next();
            // Resolve call targets to names so the stream reads as a call graph.
            String extra = "";
            for (Address r : ins.getFlows()) {
                Function t = currentProgram.getFunctionManager().getFunctionAt(r);
                if (t != null) extra = "   ; -> " + t.getName(true);
            }
            println(String.format("  %s  %s%s", ins.getAddress(), ins.toString(), extra));
            n++;
        }
        println("===DISASMDONE=== instructions=" + n);
    }
}
