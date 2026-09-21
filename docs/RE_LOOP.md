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

## The second lever: `docs/protocol/error_codes.md` names 609 refusals

Before deciding a system's error codes are anonymous, look here. It maps
609 numeric codes to the client's own `UIIT_MSG_*` / `UIIT_STT_*` names,
recovered from `UI_SILKMALL::FUN_007b8b40` — a 643-case switch whose message
pointers Ghidra drops from the decompilation but which are plain in the
disassembly.

**This is how a server-side check gets its meaning for free.** A refusal path
that returns `0x5408` is not "the third check"; it is
`ONLY_EQUIPITEM_CAN_BE_REINFORCED`, which says what the virtual it calls asks.
Three separate readings in the alchemy system were corrected this way, and one
inferred reading — that the optional second element boosts the rate — was
confirmed by the code's own name, `EQUIPCLASS_MISMATCH_PROB_UP`.

The table's coverage by system, which is also a rough map of where the protocol
is best documented:

	FORT/FORTRESS 111   STRGERR 93   GUILD* 63   TC_ERROR 27
	PARTY* 26           COS* 21      REINFORCERR 20   SKILL 18
	FLEAMARKET 15       SOCKETERR 12

**The failure this prevents, concretely.** `docs/protocol/alchemy.md` shipped in
v0.1.285 saying "no string in either binary names them" about fifteen codes,
fourteen of which were already in this file. The probe had searched only inside
the CEnchant functions. An empty grep is a fact about the grep — and the cheapest
second probe is usually a file this repository already has.

## Traps, each of which has cost real time

**COMDAT folding — check the reference count before attaching a name.** The
compiler keeps one copy of `return 1` and points nine unrelated vtables at it.
`0x00506380` is IDLE's `GetStateID` *and* eight other classes'. `0x005599a0` is
shared by 89 call sites. Naming either after one class would be a lie in the
project's own dump.

`vtq.py who <addr>` answers this in one command, and it flags anything in more
than four vtables. **This is not hypothetical and the dump already has the
problem:** 240 class-qualified names in it sit on a function shared by ten or
more vtables, and 19 functions of four bytes or fewer are shared by ten or
more. The worst is `0x0066b100`, a one-byte `ret` that 281 vtables point at,
carrying the name `CGObjCOS_Summoned::SaveCurPosAsLastTelPosition`.

Two different things are mixed in that 240, and they need different treatment:

- **A true fold** — a tiny function (`ret`, `return 1`, `return 0`) that the
  compiler emitted once. Even the method name is arbitrary. Do not attach a
  class-qualified name, and be suspicious of one that is already there.
- **An inherited base method** — e.g. the 37-byte `## Illegal ##` stubs, each
  in 30 vtables. Here the *method* name is right (it came from the stub's own
  string) and only the *class prefix* is wrong, naming an arbitrary derived
  class instead of the base that declares it.

`vtq.py owner <addr>` decides between the two. The rule it applies: among the
classes whose vtable holds the address, the declaring class is the most
base-like — the shortest vtable — **provided the function sits at the same slot
index in all of them and is at least ten bytes**.

**The obvious discriminator is the wrong one and was tried first.** Requiring
the sharing classes to agree on a vtable *prefix* up to the slot rejects real
hierarchies, because a derived class overriding an *earlier* slot is completely
normal — `CGItem` and `CGItemEquip` differ well before the slot they share. Slot
agreement plus size is what works: it resolved twelve mismatches twelve for
twelve, each confirming a reading this project had already made against the
plate pass's.

Size is the quick discriminator: under about 10 bytes, assume a fold.

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

**Two heredocs in one Bash call silently lose one of them.** A command shaped
`ssh … <<'EOF' … EOF && git commit -F - <<'EOF' … EOF` ran the commit and
swallowed the ssh's output *and* its effect — a name-apply reported success and
applied nothing, found only because the next dump still had the old name. One
heredoc per call.

**`pgrep -f <pattern>` over ssh matches its own command line**, exactly as
`pkill -f` does — `AGENTS.md` warns about the `pkill` half and the `pgrep` half
is the same bug with a worse symptom. A wait loop written as

	while pgrep -f "DecompAll.java" >/dev/null; do sleep 20; done

never exits: the ssh command that contains the loop also contains the string.
It spins silently, so it looks like the thing being waited on is slow. Match on
something the invocation does not contain, or split the literal — `"Dec""ompAll"`.
Hit twice on 2026-09-17, the second time while cleaning up after the first.

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

## Before the dump: `tools/known.sh`

**Run it on the ITEM, not just the topic — and treat an open list as a claim, not
a fact.** Rounds 373, 375, 376, 382 and 384 each began work on something this
file called open and found it already answered, four of the five in this same
file. An entry's "Still open from before" line is carried forward by hand and
nothing re-checks it, so it records what was open WHEN IT WAS WRITTEN. Round 384
swept every such line: of the items they carried, **four were already closed**
and had been repeated across up to four chain links each.

**The systems tracker goes stale the same way.** Round 390 found `docs/SYSTEMS.md`'s
Party row still saying "the invite and expulsion flows are only enumerated, and
party flag bit 2 has no probe known to name it" — four rounds after 354-360 read
both flows, named bit 2 from a use-site, closed the invitation state machine and
identified `0x2c06`. All of that reached `party.md` and none of it reached the
tracker, which is the "file answers where they are consumed" rule failing on the
one page a tick uses to CHOOSE work.

**Four trackers' claims have now been found stale, in four separate rounds** —
round 384 (the RE_COMPLETION open list carried four already-closed items), round
390 (SYSTEMS.md's Party row was four rounds behind), round 391 (its Shops probe
pointed at a SPECIFIED system) and round 400 (its Persistence probe was wrong on
*both* of its clauses). In every case the correct answer was already in this
project and one `known.sh` away. **Assume a tracker claim is a claim.**

A cheap staleness signal, measured in round 390: **17 of the 22 PARTIAL rows cite
a round number or a date in their next probe; five do not** — Shops and the goods
chain (a 26-character probe), Quest scripting, Battle arena, Persistence /
AsyncQuery, Siege and fortress war. Uncited is not the same as wrong — Quest
scripting is explicitly BLOCKED and parked — but it does mark the rows nobody has
revisited, and it is the cheapest prioritisation signal the tracker offers.

So: `tools/known.sh '<the item itself>'` before starting on it. Round 383's
failure is the sharper form — it ran the tool on the QUESTION and never on the
ANSWER, and `known.sh dttp` would have found the code in `paramblock.go` and
stopped the round.

**Run `tools/known.sh <term>` before going to the dump, the binary or the game
tables.** It greps every recovered-knowledge surface at once -- the prose docs,
the recovered-name and handler tables, and the Go sources' own citations, since
many findings live only in a doc comment beside the constant they justify.

This exists because the rule it implements kept being broken. Rounds 370, 371 and
372 each went to the dump first and each re-derived work already written down:
the player stat graph and GParamKeeper's slot-combination rules (both recorded
2026-09-15), and `magicoption.txt`'s packed tag vocabulary (recorded 2026-09-16).
The rule was not forgotten -- obeying it meant remembering which of ~60 docs to
grep, and that friction is what the script removes.

It exits 0 when something is known, so it reads the way the rule does:

	tools/known.sh 'stat graph' && echo "read that before digging"

**And when it finds nothing, LIST `docs/protocol` before believing it.** Round
331 wrote that rule down — "the file names are the index" — and it stayed in the
ledger where nobody hunting a fresh question would read it. Round 407 then
probed `known.sh 'log string naming'`, got nothing, went to the dump, and spent
most of a tick rebuilding a module map that `docs/protocol/source_files.tsv`
already held, with the original `D:\WORK2005\Source\SilkroadOnline\Server\`
paths the rebuild could not recover. `client_translation_units.tsv` is the
client's half of the same thing.

No phrase search saves that: nothing a person would type for "module map"
matches "source_files.tsv". Only reading the file names does. `known.sh` now
prints the whole index on a miss, so the rule is enforced by the tool instead of
by remembering a round number.

## Applying names

The dump tick runs `-readOnly`, so **it cannot write names**. Applying a name
and rebuilding the dump are separate steps, and a name that is only in a commit
message does not exist.

**Nor does a name that is only in `recovered_names.tsv`.** Filing a row touches
nothing until the applier below is RUN. On 2026-09-20 this had gone unrun since
2026-09-18 and **250 of the 2,079 server rows -- 12 % -- were still `FUN_` in
the dump**, including all four names round 302 had just filed specifically so
they would stop being invisible. Run this after any round that files a name.

**There is also a second name source**: `client/tools/ghidra/ApplyKnownNames.java`
holds 191 hardcoded names, 152 of them found nowhere else, applied by
`ApplyKnownNames.java` rather than by the script below.

	ssh root@192.168.5.78 'rm -f /var/tmp/recovered_names.tsv'
	ssh root@192.168.5.78 'cat > /var/tmp/recovered_names.tsv' < docs/protocol/recovered_names.tsv
	ssh root@192.168.5.78 'chown ghidra:ghidra /var/tmp/recovered_names.tsv'
	ssh root@192.168.5.78 'cd /var/tmp && su ghidra -s /bin/bash -c \
	  "/opt/ghidra_12.1.3_PUBLIC/support/analyzeHeadless /home/ghidra/re_server \
	   SR_GameServer_re -noanalysis -process SR_GameServer.exe -scriptPath /var/tmp \
	   -postScript ApplyRecoveredNames.java /var/tmp/recovered_names.tsv server"'

Expect a final `applied N, forced N, … failed 0` line. `other binary N` counts
the client rows it correctly skipped.

**Then invalidate the dump cache yourself:**

	ssh root@192.168.5.78 'rm -f /var/tmp/decomp_*/PROJSTAMP'

**A `-readOnly` run of your own still costs a rebuild (round 305).** Running
`SymbolReport.java` to measure coverage dirties the project exactly as an apply
does -- analyzeHeadless touches it whatever the script does -- so the next tick
sees the dump as stale and spends ~9 minutes rebuilding both. It is
self-correcting, because the rebuild re-stamps, but it costs a tick. **After any
read-only analyzeHeadless run, re-stamp instead of leaving it:**

	ssh root@192.168.5.78 'for d in server client; do find /home/ghidra/re_$d -type f \
	  -printf "%T@\n" | sort -rn | head -1 | cut -d. -f1 > /var/tmp/decomp_$d/PROJSTAMP; done'

Only do that when you have NOT changed the project -- after an apply the dump
genuinely is stale and must rebuild.

`re_tick.sh` stamps the project's newest mtime *after* a rebuild, so its own
`-readOnly` run does not look like a change. That is the only stable choice —
stamping *before* the run instead makes the tool's own touch newer than the
stamp, and both dumps then rebuild every tick forever, which starved this loop
for four consecutive ticks on 2026-09-17.

The cost of the stable choice is that a rename applied while a dump is building
is absorbed into the post-run stamp and missed. **Deleting `PROJSTAMP` after an
apply closes that**, and it puts the invalidation where the knowledge is: the
apply step is the only thing that meaningfully changes the project, so it is the
thing that should say so.

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

## Correcting an owner, not just a name

`ApplyRecoveredNames.java` used to set only the leaf and leave the namespace as
found. That was deliberate and it made one whole class of error uncorrectable:
a base class's method attributed to a derived class.

The `## Illegal ##` stubs are the clean case. Each one's entire body is

	Log(0x2000001, "## Illegal ##  IGObj::GetJID Entered! TypeID: %u", GetTypeID());
	Assert_BreakIfDebugger();

so **the engine states its own owner in the string**. One compiled copy serves
thirty vtables, and the RTTI plate pass named it after whichever of the thirty
it reached first. 116 functions were in that state, every one with the right
method name and the wrong class.

The script now fixes the owner too, under the same rule as renaming: an
existing owner is replaced only on a `force` row or an unnamed function. It
creates the class namespace if it does not exist, reports `REOWNED`, and is
idempotent — the second run reports `reowned 0`.

**A `leaf` match is not a name match.** The old run reported
`applied 1, evidence refreshed 252` over 116 pending corrections and looked
like a success. Read the counters: `refreshed` climbing while `applied` stays
flat means the rows are landing on functions that already have that leaf, which
is either a genuine re-run or an owner that nobody is checking.

Harvest the corrections with:

	pat = r"#+\s*Illegal\s*#+\s+([A-Za-z_][\w:]*)::(\w+)\s+Entered"

and require `Assert_BreakIfDebugger` in the body, so a real function that merely
mentions the string is not swept in. One was: `0x004eb390` is a 63-byte
predicate this project named `GObjPC::IsKilledByPlayer`, and its own evidence
column already explained that the `IsPC` string belongs to a stub it calls.
