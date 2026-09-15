// How much of this binary is actually the game?
//
// Naming coverage is quoted against the total function count -- 70,773 across
// the two binaries -- and that denominator is wrong in a way that matters. Most
// of a stripped MSVC binary is not game logic: it is the C runtime, the STL
// instantiated once per type it was used with, exception and RTTI scaffolding,
// thunks and adjustor stubs. Measuring "8.6% named" against all of it says
// almost nothing about how much of the GAME is understood, and it makes the
// remaining work look larger and more uniform than it is.
//
// So classify, using only signals that are checkable rather than guessed, and
// report each separately so a reader can disagree with any one of them:
//
//   THUNK      Ghidra says so.
//   TINY       under 16 bytes -- a stub, a getter, or an adjustor.
//   LIBRARY    named like CRT/STL by the signature database or the demangler:
//              std::/`anonymous namespace'/operator/`vector deleting
//              destructor'/_malloc-style leading-underscore CRT names. These
//              names came from Ghidra's FID, not from us.
//   GAME       everything else -- the real denominator.
//
// "Has no caller" is NOT an exclusion, and an earlier version of this script
// wrongly made it one. A virtual function has no direct caller at all: it is
// reached only through a vtable slot, and Ghidra does not resolve those. That
// bucket held 6,032 server functions and 12,423 client ones, and it contains
// some of the most important game code in the binary -- GObjPC_GainExpAndLevel,
// the exp-gain entry point, is in it. Excluding them would have thrown away
// real game logic and flattered the coverage number. They are counted as GAME
// and reported separately as a caveat, because the bucket genuinely does also
// hold dead code, and nothing here can separate the two.
//
// The buckets are exclusive and tested in order, so a tiny thunk counts once.
// The point is not a single number: it is that the GAME line is the denominator
// worth quoting, and that it comes with its method and its uncertainty.
//
// Usage: -postScript CodeCensus.java [maxExamples]
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.listing.FunctionIterator;
import ghidra.program.model.symbol.Namespace;
import ghidra.program.model.symbol.SourceType;

import java.util.ArrayList;
import java.util.List;

public class CodeCensus extends GhidraScript {

    /** Name shapes that only the CRT, the STL or the compiler produce. */
    private static boolean looksLibrary(String n) {
        // NOT a bare "contains __" test: this project's own assert-derived
        // names use __ where the source had :: (CMainProcess__EnterGame,
        // AQ_StorageUpdater__Init), and an earlier version of this check threw
        // 951 of the server's 1,052 named functions into the library bucket --
        // including our own findings. Only a LEADING double underscore is the
        // compiler's (__scrt_, __security_check_cookie).
        if (n.contains("std::") || n.startsWith("__") || n.startsWith("operator")
                || n.contains("`vector") || n.contains("`scalar")
                || n.contains("anonymous namespace") || n.contains("type_info")
                || n.contains("bad_alloc") || n.contains("exception")) {
            return true;
        }
        // CRT entry points keep their leading underscore: _memchr, _strlen,
        // _malloc. A single leading underscore plus all-lowercase is the shape.
        return n.length() > 1 && n.charAt(0) == '_' && n.substring(1).equals(n.substring(1).toLowerCase());
    }

    public void run() throws Exception {
        String[] args = getScriptArgs();
        int maxEx = args.length > 0 ? Integer.parseInt(args[0]) : 10;

        int total = 0, thunk = 0, tiny = 0, library = 0, noCaller = 0, game = 0;
        int gameNamed = 0, gameAttributed = 0, gameUnknown = 0;
        long gameBytes = 0;
        List<String> examples = new ArrayList<>();

        FunctionIterator it = currentProgram.getFunctionManager().getFunctions(true);
        while (it.hasNext() && !monitor.isCancelled()) {
            Function f = it.next();
            total++;
            String n = f.getName();
            long size = f.getBody().getNumAddresses();

            if (f.isThunk()) { thunk++; continue; }
            if (size < 16) { tiny++; continue; }
            if (looksLibrary(n)) { library++; continue; }
            // Counted as game logic, but tracked: no DIRECT caller usually
            // means virtual (vtable-only) rather than dead.
            if (f.getCallingFunctions(monitor).isEmpty()) noCaller++;

            game++;
            gameBytes += size;

            SourceType st = f.getSymbol() == null ? SourceType.DEFAULT : f.getSymbol().getSource();
            boolean hasName = !(st == SourceType.DEFAULT || n.startsWith("FUN_"));
            Namespace ns = f.getParentNamespace();
            boolean hasModule = ns != null && !ns.isGlobal();
            if (hasName) gameNamed++;
            else if (hasModule) gameAttributed++;
            else {
                gameUnknown++;
                if (examples.size() < maxEx && size > 400) {
                    examples.add(String.format("%s  %5d bytes", f.getEntryPoint(), size));
                }
            }
        }

        int identified = gameNamed + gameAttributed;
        println("===CODECENSUS===");
        println("  total functions        : " + total);
        println("  -- not game logic --");
        println("    thunks               : " + thunk);
        println("    tiny (<16 bytes)     : " + tiny);
        println("    CRT/STL by name      : " + library);
        println("  GAME-LOGIC FUNCTIONS   : " + game + String.format("   (%.1f%% of total)",
                100.0 * game / Math.max(1, total)));
        println("    total bytes          : " + gameBytes);
        println("    of which no direct caller (vtable-only, or dead) : " + noCaller);
        println("    named                : " + gameNamed);
        println("    attributed (module)  : " + gameAttributed);
        println("    unknown              : " + gameUnknown);
        println(String.format("    IDENTIFIED           : %d  (%.1f%% of game logic)",
                identified, 100.0 * identified / Math.max(1, game)));
        println("  -- biggest unknown game functions --");
        for (String e : examples) println("    " + e);
        println("===CODECENSUSDONE===");
    }
}
