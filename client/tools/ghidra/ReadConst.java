// Read the .rdata constants the decompiler prints as bare _DAT_ symbols.
//
// A float constant shows up in decompiled C as "_DAT_00b462ac" and nothing
// else. The value is right there in the file, but the C never shows it, so a
// formula recovered from the code stops one step short of being a number. This
// prints each address as every plausible width, because the decompiler's choice
// of FLD vs FLD qword is not always visible in the C -- reading all of them and
// picking the one that is a sane game constant is honest, and the printout
// shows what was rejected.
//
// Usage: -postScript ReadConst.java <addr[,addr...]>
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;

public class ReadConst extends GhidraScript {

    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length < 1) { println("need addresses"); return; }
        println("===READCONST===");
        for (String one : args[0].split(",")) {
            Address a = currentProgram.getAddressFactory().getAddress(one.trim());
            if (a == null) { println("  " + one + " : bad address"); continue; }
            StringBuilder sb = new StringBuilder();
            sb.append("  ").append(one.trim()).append(" : ");
            try {
                int i = getInt(a);
                sb.append(String.format("int=%d (0x%x)  ", i, i));
                sb.append(String.format("float=%s  ", Float.intBitsToFloat(i)));
            } catch (Exception e) { sb.append("int/float=?  "); }
            try {
                long l = getLong(a);
                sb.append(String.format("double=%s", Double.longBitsToDouble(l)));
            } catch (Exception e) { sb.append("double=?"); }
            println(sb.toString());
        }
        println("===READCONSTDONE===");
    }
}
