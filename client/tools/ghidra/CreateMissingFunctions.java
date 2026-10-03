// Create functions at an explicit, verified list of entry addresses.
//
// WHY THIS EXISTS. Game logic that Ghidra never turned into a function is
// invisible to every naming metric: it is in neither the named count nor the
// FUN_ count, and ApplyRecoveredNames cannot name it because that script -- by
// design -- refuses to create a function where none exists. Measured 2026-09-17:
// seven such functions raise named game refusals, including the academy invite
// routine at 0x00519230. See docs/RE_COMPLETION.md, "Code Ghidra never made into
// functions, measured".
//
// WHY A SEPARATE SCRIPT. Creating a function changes the boundaries of the code
// around it, which is a different kind of claim from naming one. Keeping it out
// of ApplyRecoveredNames preserves that script's refusal to guess, and makes this
// step something that is run deliberately against a reviewed address list.
//
// IT ALSO REFUSES TO GUESS. Each row is checked in Ghidra's own memory before
// anything is created, and skipped rather than forced when:
//
//   EXISTS            a function already starts at the address
//   INSIDE            the address lies inside an existing function; creating one
//                     there would split it
//   NOT_AT_BOUNDARY   the byte before the address is not 0xCC (int3). The list
//                     was built from MSVC's inter-function int3 padding, so an
//                     entry without it is not the kind of entry this script is
//                     entitled to create
//   NO_DISASSEMBLY    the bytes do not disassemble into an instruction
//
// Nothing is created twice, so the script is safe to re-run.
//
// TWO KINDS OF EVIDENCE, added 2026-09-17. A row's optional fourth column says
// how its entry was established, and it changes exactly one guard:
//
//   padding     (the default, and every three-column row) -- the entry was found
//               as the first instruction after MSVC int3 padding, so it MUST
//               follow an int3 byte; NOT_AT_BOUNDARY refuses it otherwise.
//   registered  the entry is a pointer the binary itself registers as a message
//               handler (docs/protocol/message_handlers.tsv). That is stronger
//               evidence than padding -- a registered handler IS a function
//               entry -- and client handlers need not follow padding, so the
//               int3 check is skipped for these rows and ONLY for these rows.
//               EXISTS, INSIDE and NO_DISASSEMBLY still apply.
//
// Any other kind is reported as MALFORMED and skipped, so a typo cannot quietly
// disable the boundary check.
//
// Run it in a NON-readOnly analyzeHeadless invocation, under re_tick.sh's lock so
// it cannot collide with a dump rebuild on the same project:
//
//   flock -w 600 /opt/opensro-re/lock su ghidra -s /bin/bash -c \
//     "analyzeHeadless /home/ghidra/re_server SR_GameServer_re -noanalysis \
//      -process SR_GameServer.exe -scriptPath /var/tmp \
//      -postScript CreateMissingFunctions.java /var/tmp/missing_functions.tsv server"
//
// then delete /var/tmp/decomp_server/PROJSTAMP so the next tick rebuilds the dump.
//
// Input: docs/protocol/missing_functions.tsv -- address, binary, evidence.
//
// @category OpenSRO

import java.io.BufferedReader;
import java.io.FileReader;

import ghidra.app.cmd.disassemble.DisassembleCommand;
import ghidra.app.cmd.function.CreateFunctionCmd;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.Address;
import ghidra.program.model.listing.Function;

public class CreateMissingFunctions extends GhidraScript {

	@Override
	public void run() throws Exception {
		String[] args = getScriptArgs();
		if (args.length < 2) {
			printerr("usage: CreateMissingFunctions.java <missing_functions.tsv> <server|client>");
			return;
		}
		String path = args[0];
		String want = args[1];

		int created = 0, exists = 0, inside = 0, notBoundary = 0, noDisasm = 0, failed = 0, other = 0;

		try (BufferedReader r = new BufferedReader(new FileReader(path))) {
			String line;
			while ((line = r.readLine()) != null) {
				if (line.isEmpty() || line.startsWith("#")) {
					continue;
				}
				String[] f = line.split("\t");
				if (f.length < 3) {
					printerr("MALFORMED  " + line);
					failed++;
					continue;
				}
				if (!f[1].equals(want)) {
					other++;
					continue;
				}
				Address addr = toAddr(Long.parseLong(f[0], 16));

				Function at = getFunctionAt(addr);
				if (at != null) {
					println("EXISTS           " + f[0] + "  " + at.getName());
					exists++;
					continue;
				}
				Function containing = getFunctionContaining(addr);
				if (containing != null) {
					println("INSIDE           " + f[0] + "  inside " + containing.getName()
							+ " @" + containing.getEntryPoint());
					inside++;
					continue;
				}
				String kind = f.length >= 4 ? f[3].trim() : "padding";
				if (!kind.equals("padding") && !kind.equals("registered")) {
					printerr("MALFORMED        " + f[0] + "  unknown kind '" + kind + "'");
					failed++;
					continue;
				}
				byte before = currentProgram.getMemory().getByte(addr.subtract(1));
				if (kind.equals("padding") && (before & 0xff) != 0xcc) {
					println(String.format("NOT_AT_BOUNDARY  %s  byte before is 0x%02x, not int3", f[0], before & 0xff));
					notBoundary++;
					continue;
				}

				if (getInstructionAt(addr) == null) {
					new DisassembleCommand(addr, null, true).applyTo(currentProgram, monitor);
				}
				if (getInstructionAt(addr) == null) {
					println("NO_DISASSEMBLY   " + f[0]);
					noDisasm++;
					continue;
				}

				CreateFunctionCmd cmd = new CreateFunctionCmd(addr);
				if (cmd.applyTo(currentProgram, monitor) && getFunctionAt(addr) != null) {
					Function fn = getFunctionAt(addr);
					println(String.format("CREATED          %s  %s  body %s..%s  %d bytes",
							f[0], fn.getName(), fn.getBody().getMinAddress(), fn.getBody().getMaxAddress(),
							fn.getBody().getNumAddresses()));
					created++;
				} else {
					println("FAILED           " + f[0] + "  " + cmd.getStatusMsg());
					failed++;
				}
			}
		}

		println(String.format(
				"created %d, exists %d, inside %d, not at boundary %d, no disassembly %d, failed %d, other binary %d",
				created, exists, inside, notBoundary, noDisasm, failed, other));
	}
}
