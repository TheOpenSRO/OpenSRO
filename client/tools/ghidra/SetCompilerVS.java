// Report — and optionally set — the program's detected compiler.
//
// Ghidra's RTTI class recovery refuses to run unless program.getCompiler()
// is exactly "VisualStudio" (or "Clang"). Both of these binaries are MSVC
// (their own embedded paths say D:\WORK2005\..., and they link the MSVC CRT),
// but PE compiler detection is a heuristic and leaves it unset often enough
// that the recovery silently reports "This script will not work on this
// program type" -- which reads like the binary is unsuitable when the truth is
// that one metadata field is blank.
//
// Usage: -postScript SetCompilerVS.java [set]
//   no arg : report only
//   "set"  : set the compiler to VisualStudio (requires a writable, i.e. NOT
//            -readOnly, run) so RecoverClassesFromRTTIScript will proceed.
import ghidra.app.script.GhidraScript;

public class SetCompilerVS extends GhidraScript {

    public void run() throws Exception {
        String[] args = getScriptArgs();
        boolean doSet = args.length > 0 && args[0].equalsIgnoreCase("set");

        println("===COMPILER===");
        println("  executableFormat : " + currentProgram.getExecutableFormat());
        println("  compiler         : '" + currentProgram.getCompiler() + "'");
        println("  compilerSpecID   : " + currentProgram.getCompilerSpec().getCompilerSpecID());
        println("  languageID       : " + currentProgram.getLanguageID());

        if (doSet) {
            String before = currentProgram.getCompiler();
            if ("VisualStudio".equals(before)) {
                println("  already VisualStudio -- nothing to do");
            } else {
                currentProgram.setCompiler("VisualStudio");
                println("  set compiler: '" + before + "' -> '" + currentProgram.getCompiler() + "'");
            }
        }
        println("===COMPILERDONE===");
    }
}
