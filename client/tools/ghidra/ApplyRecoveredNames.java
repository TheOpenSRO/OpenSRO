// Apply docs/protocol/recovered_names.tsv to a Ghidra project.
//
// WHY THIS EXISTS. Naming coverage on this project sat at exactly 7,386 named
// server functions (21.7%) across fifteen ticks of active reverse engineering,
// and the reason was not that nothing was recovered. It was that every name
// went into srrevamp's comments and docs and NOTHING WROTE IT BACK into the
// Ghidra project the metric reads. The dump tick runs analyzeHeadless with
// `-readOnly`, so it structurally cannot. See the RE_COMPLETION entry
// "the metric that could not move".
//
// WHY JAVA AND NOT PYTHON. This was written in Python first and it does not
// run. Ghidra 12.1.3 serves .py scripts only through PyGhidra, which is not
// enabled on the RE box:
//
//     SCRIPT ERROR: Ghidra was not started with PyGhidra. Python is not available
//
// The dump pipeline's own DecompAll.java is the proof that Java scripts work,
// so this matches the path already known to run. The Python version was
// deleted rather than kept as a reference: a script that looks runnable and
// is not costs the next reader the same ten minutes it cost this one.
//
// Run it in a NON-readOnly analyzeHeadless invocation:
//
//   analyzeHeadless /home/ghidra/re_server SR_GameServer_re \
//       -noanalysis -process SR_GameServer.exe \
//       -scriptPath /var/tmp -postScript ApplyRecoveredNames.java \
//       /var/tmp/recovered_names.tsv server
//
// and again with `re_client sro_client_re ... sro_client.exe ... client`.
// Drop the `-readOnly` the dump tick uses, or every rename is silently
// discarded.
//
// IT REFUSES TO GUESS. A row whose address holds no function, or whose function
// already carries a name that is not FUN_/thunk_FUN_/vslot_, is reported and
// skipped rather than overwritten -- an existing name may be the engine's own
// and better than the one offered here. Nothing is renamed twice, so the script
// is safe to re-run.
//
// @category srrevamp

import java.io.BufferedReader;
import java.io.FileReader;

import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;
import ghidra.program.model.symbol.SourceType;

public class ApplyRecoveredNames extends GhidraScript {

	private static String leaf(String name) {
		int i = name.lastIndexOf("::");
		return i < 0 ? name : name.substring(i + 2);
	}

	private static boolean isUnnamed(String name) {
		String l = leaf(name);
		return l.startsWith("FUN_") || l.startsWith("thunk_FUN_") || l.startsWith("vslot_");
	}

	// The evidence goes into the function comment, the same convention
	// ApplyKnownNames.java established: a name a later reader can audit beats a
	// name they have to trust. The origin is carried too, because a descriptive
	// name and the engine's own word are not the same kind of claim.
	private void comment(Function fn, String origin, String evidence) {
		if (evidence.length() == 0) {
			return;
		}
		fn.setComment("Identified by srrevamp RE (origin=" + origin + ").\n" + evidence);
	}

	@Override
	public void run() throws Exception {
		String[] args = getScriptArgs();
		if (args.length < 2) {
			println("usage: ApplyRecoveredNames.java <recovered_names.tsv> <server|client>");
			return;
		}
		String path = args[0];
		String wantBinary = args[1];

		int applied = 0, skippedOther = 0, skippedNamed = 0, missing = 0, failed = 0,
				refreshed = 0;

		BufferedReader in = new BufferedReader(new FileReader(path));
		String line;
		while ((line = in.readLine()) != null) {
			if (line.length() == 0 || line.startsWith("#")) {
				continue;
			}
			String[] f = line.split("\t");
			if (f.length < 4) {
				continue;
			}
			String addrS = f[0], binary = f[1], name = f[2], origin = f[3];
			String evidence = f.length > 4 ? f[4] : "";
			if (!binary.equals(wantBinary)) {
				skippedOther++;
				continue;
			}

			Address addr = currentProgram.getAddressFactory()
					.getDefaultAddressSpace().getAddress(Long.parseLong(addrS, 16));
			Function fn = currentProgram.getFunctionManager().getFunctionAt(addr);
			if (fn == null) {
				println("MISSING  " + addrS + "  no function at that address");
				missing++;
				continue;
			}

			String current = fn.getName();
			if (!isUnnamed(current)) {
				if (!leaf(current).equals(leaf(name))) {
					println("KEEP     " + addrS + "  already named " + current
							+ " (offered " + name + ", origin=" + origin + ")");
					skippedNamed++;
					continue;
				}
				// Already carries the name this file offers -- almost certainly
				// a re-run. Refresh the evidence comment anyway, so a row whose
				// evidence was improved after the first application still lands.
				comment(fn, origin, evidence);
				refreshed++;
				continue;
			}

			// The TSV carries Class::Method; Ghidra holds the class as the
			// function's namespace, so set only the leaf and leave the
			// namespace as found.
			//
			// setName throws on a duplicate or an invalid identifier. Catching
			// it matters because an uncaught exception aborts the whole script,
			// which would leave the project half-renamed and the run's output
			// misleading about what was applied.
			try {
				fn.setName(leaf(name), SourceType.USER_DEFINED);
			}
			catch (Exception e) {
				println("FAILED   " + addrS + "  " + current + " -> " + leaf(name) + ": " + e);
				failed++;
				continue;
			}
			comment(fn, origin, evidence);
			println("RENAMED  " + addrS + "  " + current + " -> " + leaf(name)
					+ "  (origin=" + origin + ")");
			applied++;
		}
		in.close();

		println("");
		println("applied " + applied + ", evidence refreshed " + refreshed
				+ ", kept " + skippedNamed + ", no function " + missing
				+ ", failed " + failed + ", other binary " + skippedOther);
	}
}
