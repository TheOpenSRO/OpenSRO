// Print the string at an address, whether or not Ghidra ever defined it as data.
//
// StrXref only sees DEFINED strings, and in this client many literals are just
// bytes in .rdata that the analyser never typed -- so a search for a filename
// it plainly contains comes back empty. When the disassembly hands you the
// pointer (PUSH 0xdd3aa0), reading the bytes is the answer that cannot be wrong.
//
// Usage: -postScript ReadStr.java <addr[,addr...]> [maxLen]
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;

public class ReadStr extends GhidraScript {

    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length < 1) { println("need addresses"); return; }
        int max = args.length > 1 ? Integer.parseInt(args[1]) : 120;
        println("===READSTR===");
        for (String one : args[0].split(",")) {
            Address a = currentProgram.getAddressFactory().getAddress(one.trim());
            StringBuilder sb = new StringBuilder();
            try {
                for (int i = 0; i < max; i++) {
                    byte b = getByte(a.add(i));
                    if (b == 0) break;
                    sb.append((b >= 32 && b < 127) ? (char) b : '.');
                }
            } catch (Exception e) { sb.append("<unreadable>"); }
            println("  " + one.trim() + " : \"" + sb + "\"");
        }
        println("===READSTRDONE===");
    }
}
