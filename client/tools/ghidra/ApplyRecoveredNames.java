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
// IT CAN CORRECT ITS OWN MISTAKES, added 2026-09-17. A sixth TSV field of
// "force" overwrites a name that is already there, which is the only way to fix
// a name THIS project got wrong -- ten distinct storage functions all carrying
// "AQ_StorageUpdater__Init" was the case that motivated it. Use it only for
// that. A name the binary gave itself (a log label, an assert, an `## Illegal ##`
// stub) is better evidence than anything offered here, and force would silently
// discard it.
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
import ghidra.program.model.symbol.Namespace;
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

	// Move a function into the class the TSV names, creating that class
	// namespace if it does not exist yet.
	//
	// WHY THIS EXISTS. The script used to set only the leaf, deliberately --
	// "leave the namespace as found". That made one whole category of error
	// uncorrectable: a base class's method attributed to a derived class. The
	// `## Illegal ##` stubs are the clearest case. Each logs its own owner --
	// "## Illegal ##  IGObj::GetJID Entered!" -- and 30 vtables share the one
	// compiled copy, so the plate pass named it after an arbitrary one of the
	// 30. The method name was right every time; the owner was wrong 116 times.
	//
	// The same safety rule as renaming applies: an existing owner is only
	// replaced when the row says `force`, or when the function was unnamed.
	private boolean applyNamespace(Function fn, String name, String addrS, boolean force)
			throws Exception {
		int i = name.lastIndexOf("::");
		if (i < 0) {
			return false; // the row offers no owner, so there is nothing to set
		}
		String want = name.substring(0, i);
		Namespace cur = fn.getParentNamespace();
		String curName = cur == null || cur.isGlobal() ? "" : cur.getName(true);
		if (want.equals(curName)) {
			return false;
		}
		if (!curName.isEmpty() && !force) {
			println("KEEPOWNER " + addrS + "  owner is " + curName + ", offered " + want
					+ " (no force)");
			return false;
		}

		// Resolve or create the class namespace, one "::" segment at a time.
		Namespace ns = currentProgram.getGlobalNamespace();
		for (String seg : want.split("::")) {
			if (seg.length() == 0) {
				continue;
			}
			Namespace child = currentProgram.getSymbolTable().getNamespace(seg, ns);
			if (child == null) {
				child = currentProgram.getSymbolTable()
						.createClass(ns, seg, SourceType.USER_DEFINED);
			}
			ns = child;
		}
		try {
			fn.setParentNamespace(ns);
		}
		catch (Exception e) {
			println("FAILOWNER " + addrS + "  -> " + want + ": " + e);
			return false;
		}
		println("REOWNED  " + addrS + "  " + (curName.isEmpty() ? "<global>" : curName)
				+ "::" + fn.getName() + " -> " + want + "::" + fn.getName());
		return true;
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
				refreshed = 0, forced = 0, reowned = 0;

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
			// A sixth field of "force" overwrites a name that is already there.
			// See the header: this is for correcting THIS project's own bad
			// names, never for overwriting the engine's own word.
			boolean force = f.length > 5 && f[5].trim().equals("force");
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
					if (!force) {
						println("KEEP     " + addrS + "  already named " + current
								+ " (offered " + name + ", origin=" + origin + ")");
						skippedNamed++;
						continue;
					}
					println("FORCED   " + addrS + "  " + current + " -> " + leaf(name)
							+ "  (origin=" + origin + ")");
					forced++;
				}
				else {
					// Already carries the name this file offers -- almost
					// certainly a re-run. Refresh the evidence comment anyway,
					// so a row whose evidence was improved after the first
					// application still lands.
					comment(fn, origin, evidence);
					refreshed++;
					// The LEAF matching does not mean the OWNER does. An
					// inherited base stub is attributed by the RTTI plate pass
					// to whichever derived class it reached first, so
					// CGObjCOS_Summoned::GetJID and IGObj::GetJID have the same
					// leaf and different, and one wrong, owners. 116 functions
					// in this project were in exactly that state.
					if (applyNamespace(fn, name, addrS, force)) {
						reowned++;
					}
					continue;
				}
			}

			// The TSV carries Class::Method; Ghidra holds the class as the
			// function's namespace. The leaf is set here; the namespace is
			// handled separately below, because the two can need fixing
			// independently.
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
			if (applyNamespace(fn, name, addrS, force)) {
				reowned++;
			}
			if (!force || isUnnamed(current)) {
				// A forced row already logged its own FORCED line above;
				// printing RENAMED too would read as two changes.
				println("RENAMED  " + addrS + "  " + current + " -> " + leaf(name)
						+ "  (origin=" + origin + ")");
			}
			applied++;
		}
		in.close();

		println("");
		println("applied " + applied + ", forced " + forced
				+ ", reowned " + reowned
				+ ", evidence refreshed " + refreshed
				+ ", kept " + skippedNamed + ", no function " + missing
				+ ", failed " + failed + ", other binary " + skippedOther);
	}
}
