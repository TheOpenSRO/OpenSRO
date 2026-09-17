# The RE loop — operating notes

Written for whoever runs the next tick, including me. `docs/SYSTEMS.md` says
*what* is left; this says *how*, so the loop stops re-deriving its own method
every time.

The unit of work is **one system from `docs/SYSTEMS.md`**, taken from its own
"Next probe" column, ending in a spec under `docs/protocol/`, names in
`docs/protocol/recovered_names.tsv`, a Go package with a test, a tracker update
and a tag.

## The toolkit

`/var/tmp/rebox.py` on the RE box. It exists because every command in it was a
throwaway script in some earlier tick.

	python3 /var/tmp/rebox.py classes <regex>   RTTI classes matching
	python3 /var/tmp/rebox.py fns <regex>       named functions matching, largest first
	python3 /var/tmp/rebox.py read <addr>       one function body
	python3 /var/tmp/rebox.py slots <Class>     vtable slots, who overrides what
	python3 /var/tmp/rebox.py strings <regex>   string literals with their owning function
	python3 /var/tmp/rebox.py callers <addr>    call sites
	python3 /var/tmp/rebox.py params <addr>     param reads (both GetParam paths)
	python3 /var/tmp/rebox.py walk <addr> [n]   transitive callees + their params
	python3 /var/tmp/rebox.py pk2 <substr>      list Media.pk2
	python3 /var/tmp/rebox.py table <name>      extract + column-census a textdata table

It is importable — `sys.path.insert(0, "/var/tmp"); import rebox as X` — which
is how every one-off analysis below is written. **Do not name a file
`/var/tmp/re.py`**: it shadows the standard library's `re` and nothing on the
box will import.

Write the one-off locally in the scratchpad, then:

	scp -q scratchpad/probe.py root@192.168.5.78:/var/tmp/ && \
	  ssh root@192.168.5.78 'cd /var/tmp && python3 probe.py'

Never inline Python in an ssh heredoc. Quoting collisions between the local
shell, ssh and the heredoc have cost this project four separate debugging
detours.

## The highest-yield lever: read the vtables out of `.rdata`

This is what made the AI system fall in one sitting, and it generalises to every
class family in either binary.

The dumps' `RTTI: reached as <Class> slot <N>` plates are **incomplete** —
they only tag functions the propagation pass actually reached. Reading the
vtable directly is complete, and it is the only way to see a slot whose function
is COMDAT-folded.

The recipe, in `scratchpad/vt2.py` and `vt3.py`:

1. Parse the PE section table for the image base and the `.rdata` mapping.
2. For each dword-aligned address in `.rdata`, read the dword **before** it as a
   candidate RTTI complete-object locator; its `+12` is the type descriptor;
   the descriptor's `+8` is the mangled name. If it starts with `.?A`, demangle
   it and you have found that class's vtable, at that address.
3. Read slots forward until a null. That is the class's whole interface.
4. **Diff the derived classes against the base**, slot by slot. The slots that
   differ are the overrides; the slots that do not are the interface's defaults,
   and reading a default tells you what the slot *means*.

Step 4 is the part that pays. `CAIState`'s base slot 3 is seven instructions and
it explained the dwell timer for all sixteen states at once.

## Traps, each of which has cost real time

**COMDAT folding — check the reference count before attaching a name.** The
compiler keeps one copy of `return 1` and points nine unrelated vtables at it.
`0x00506380` is IDLE's `GetStateID` *and* eight other classes'. `0x005599a0` is
shared by 89 call sites. Naming either after one class would be a lie in the
project's own dump.

Count data references before naming anything small:

	for off in range(0, len(data)-4, 4):
	    if struct.unpack_from("<I", data, off)[0] == target: n += 1

A count above the class's own vtable count means folded. **The vtable slot is
still valid evidence for the value** — it is only the function name that must
not be attached.

**`lea edi,[ebx+N]` is `mov edi, N`.** MSVC zeroes a register once and reuses it
for both an argument and a return value (`xor ebx,ebx` … `lea edi,[ebx+0x3]` …
`lea eax,[ebx+0x2]`). A backward scan looking only for `mov reg,imm` resolves 3
of 40 call sites; one that resolves `lea` recursively against a proven-zero base
resolves 36. `scratchpad/ai7.py` has the working version — it walks back
resolving each register, and bails on `call` or any other write to the target.

**The RE box's lock file always exists.** `re_tick.sh` uses `flock`, not a
pidfile, so `/opt/srrevamp-re/lock` is present whether or not a tick is running.
`ls`-ing it proves nothing. Check `STATUS` for a `finished=` line newer than
`last_tick=`, or `pgrep -af analyzeHeadless`.

**`/var/tmp` on the box is owned by `ghidra` and sticky.** `scp` over an
existing file fails with "Permission denied" even as root. Delete first, or
pipe:

	ssh root@192.168.5.78 'cat > /var/tmp/f' < local_f
	ssh root@192.168.5.78 'chown ghidra:ghidra /var/tmp/f'

**There is no `sudo` on the box.** Use `su ghidra -s /bin/bash -c "…"`.

**`/tmp` on the box is tmpfs.** Frames and dumps go in `/var/tmp`.

**`cd server && …` fails when the shell is already in `server/`.** Use absolute
paths. This has been hit twice.

**`docs/SYSTEMS.md` writes empty cells as `|  |` — two spaces.** A regex
requiring exactly one space silently dropped 21 of 33 rows. Split on `|` and
trim; never pattern-match the row shape.

## Applying names

The dump tick runs `-readOnly`, so **it cannot write names**. Applying a name
and rebuilding the dump are separate steps, and a name that is only in a commit
message does not exist.

	ssh root@192.168.5.78 'rm -f /var/tmp/recovered_names.tsv'
	ssh root@192.168.5.78 'cat > /var/tmp/recovered_names.tsv' < docs/protocol/recovered_names.tsv
	ssh root@192.168.5.78 'chown ghidra:ghidra /var/tmp/recovered_names.tsv'
	ssh root@192.168.5.78 'cd /var/tmp && su ghidra -s /bin/bash -c \
	  "/opt/ghidra_12.1.3_PUBLIC/support/analyzeHeadless /home/ghidra/re_server \
	   SR_GameServer_re -noanalysis -process SR_GameServer.exe -scriptPath /var/tmp \
	   -postScript ApplyRecoveredNames.java /var/tmp/recovered_names.tsv server"'

Expect a final `applied N, forced N, … failed 0` line. `other binary N` counts
the client rows it correctly skipped. The next `re_tick.sh` run notices the
project changed and rebuilds the dumps.

Ghidra 12.1.3 **will not run `.py` scripts** — it needs PyGhidra, which is not
enabled. Java only.

TSV format, tab-separated:

	address  binary  name  origin  evidence  [force]

`force` overwrites a name **this project** got wrong; never the engine's own
word.

## Extracting a data table

Several tables assumed missing were in `Media.pk2` all along under
`server_dep\silkroad\textdata\`. Check before concluding a table has no file:

	/var/tmp/pk2list -pk2 /opt/sro-files/client/Media.pk2 -filter <substr>
	/var/tmp/pk2list -pk2 /opt/sro-files/client/Media.pk2 \
	  -extract "server_dep\\silkroad\\textdata\\<name>.txt" -out /var/tmp/<name>.txt

`rebox.py table <name>` does both and prints a per-column census. Rows are
tab-separated, UTF-16LE or CP949, `//` comments, and a leading `0` in column 0
means disabled.

Some tables have **no file at all** and are database-only — `TAB_REFTACTICS`
and its three siblings are the worked example. A `TAB_*` string in the binary
with no `Media.pk2` counterpart is that case, not a failed search.

## The evidence bar

From `AGENTS.md`, and every one of these has been violated once and cost a
correction:

- **A use-site settles meaning; a suggestive shape does not.** `characterdata`
  column 79 was promoted twice on shape and was wrong twice. The `0x30` beside
  each reference-table loader looked exactly like a record size and is not.
- **When a negative result comes back, check the probe.** "No callers" usually
  means the function is reached through a vtable.
- **Say which values are the engine's and which are ours.** The eleven AI
  message ids are the engine's; their names are not, and `monster_ai.md` says so
  in those words.

## Finishing a system

1. Spec in `docs/protocol/<system>.md` — ordered, addresses cited, every
   constant either grounded or explicitly flagged as inferred.
2. Names appended to `docs/protocol/recovered_names.tsv` and **applied**.
3. A Go package under `server/internal/` with a test that would fail if the
   recovered values were changed. Wiring it into a live path is a separate
   decision; the package plus test is the deliverable.
4. `docs/SYSTEMS.md`: move the row, update the anchors, update the **headline
   counts** — a test checks they match the table.
5. `cd /root/srrevamp/server && go test -p 1 ./...`
6. Commit on `dev`, tag `vX.Y.Z`, push both.

Mark a row SPECIFIED only when nothing material is outstanding. Quest scripting
went SPECIFIED and straight back to PARTIAL in one session for want of that
discipline; Monster AI is PARTIAL on purpose, because the machine is whole but
the tables that configure it are unread.
