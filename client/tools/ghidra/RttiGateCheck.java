// Evaluate, one clause at a time, the exact condition Ghidra's RTTI class
// recovery gates on -- because its refusal message ("This script will not work
// on this program type") is printed from two different places and names
// neither clause, so it tells you nothing about which one failed.
//
// RTTIWindowsClassRecoverer.isValidProgramType() is:
//     executableFormat.equals(PeLoader.PE_NAME)
//       && (compiler.equals("VisualStudio") || compiler.equals("Clang"))
//
// Values are printed delimited, because a trailing space in a format name
// would look identical in an undelimited log line and fail .equals() silently.
import ghidra.app.script.GhidraScript;
import ghidra.app.util.opinion.PeLoader;

public class RttiGateCheck extends GhidraScript {

    public void run() throws Exception {
        String fmt = currentProgram.getExecutableFormat();
        String comp = currentProgram.getCompiler();

        println("===RTTIGATE===");
        println("  executableFormat  = [" + fmt + "]  len=" + (fmt == null ? -1 : fmt.length()));
        println("  PeLoader.PE_NAME  = [" + PeLoader.PE_NAME + "]  len=" + PeLoader.PE_NAME.length());
        println("  format matches    : " + PeLoader.PE_NAME.equals(fmt));
        println("  compiler          = [" + comp + "]  len=" + (comp == null ? -1 : comp.length()));
        println("  compiler matches  : " + ("VisualStudio".equals(comp) || "Clang".equals(comp)));
        boolean valid = PeLoader.PE_NAME.equals(fmt)
                && ("VisualStudio".equals(comp) || "Clang".equals(comp));
        println("  isValidProgramType: " + valid);

        // The other gate the script checks just before that one: whether the
        // RTTI analyser actually produced anything to work with.
        int typeInfo = 0, vftables = 0;
        var st = currentProgram.getSymbolTable();
        var it = st.getSymbolIterator();
        while (it.hasNext() && !monitor.isCancelled()) {
            String n = it.next().getName();
            if (n.contains("RTTI") || n.contains("type_info")) typeInfo++;
            if (n.contains("vftable")) vftables++;
        }
        println("  RTTI/type_info symbols: " + typeInfo);
        println("  vftable symbols       : " + vftables);
        println("===RTTIGATEDONE===");
    }
}
