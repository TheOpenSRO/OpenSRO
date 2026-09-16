# Apply docs/protocol/recovered_names.tsv to a Ghidra project.
#
# WHY THIS EXISTS. Naming coverage on this project sat at exactly 7,386 named
# server functions (21.7%) across fifteen ticks of active reverse engineering,
# and the reason was not that nothing was recovered. It was that every name went
# into srrevamp's comments and docs and **nothing wrote it back into the Ghidra
# project the metric reads**. The dump tick runs analyzeHeadless with
# `-readOnly`, so it structurally cannot. See the RE_COMPLETION entry
# "the metric that could not move".
#
# This is a Ghidra script (Jython), not a standalone one. It must run in a
# NON-readOnly analyzeHeadless invocation:
#
#     analyzeHeadless /home/ghidra/re_server SR_GameServer.exe \
#         -noanalysis -process SR_GameServer.exe \
#         -scriptPath /var/tmp -postScript ApplyRecoveredNames.py \
#         /path/to/recovered_names.tsv server
#
# and again with `re_client sro_client.exe ... client`. Drop the `-readOnly`
# the dump tick uses, or every rename is silently discarded.
#
# IT REFUSES TO GUESS. A row whose address holds no function, or whose function
# already carries a name that is not FUN_/thunk_FUN_/vslot_, is reported and
# skipped rather than overwritten -- an existing name may be the engine's own
# and better than the one offered here. Nothing is renamed twice, and the script
# is safe to re-run.
#
# @category srrevamp

import os

from ghidra.program.model.symbol import SourceType

UNNAMED_PREFIXES = ("FUN_", "thunk_FUN_", "vslot_")


def leaf(name):
    return name.rsplit("::", 1)[-1]


def is_unnamed(name):
    return leaf(name).startswith(UNNAMED_PREFIXES)


def main():
    args = getScriptArgs()
    if len(args) < 2:
        print("usage: ApplyRecoveredNames.py <recovered_names.tsv> <server|client>")
        return
    path, want_binary = args[0], args[1]
    if not os.path.exists(path):
        print("no such file: %s" % path)
        return

    fm = currentProgram.getFunctionManager()
    space = currentProgram.getAddressFactory().getDefaultAddressSpace()

    applied = skipped_other = skipped_named = missing = 0
    for line in open(path):
        line = line.rstrip("\n")
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) < 4:
            continue
        addr_s, binary, name, origin = parts[0], parts[1], parts[2], parts[3]
        if binary != want_binary:
            skipped_other += 1
            continue

        addr = space.getAddress(long(addr_s, 16))
        fn = fm.getFunctionAt(addr)
        if fn is None:
            print("MISSING  %s  no function at that address" % addr_s)
            missing += 1
            continue

        current = fn.getName()
        if not is_unnamed(current):
            if leaf(current) != leaf(name):
                print("KEEP     %s  already named %s (offered %s, origin=%s)"
                      % (addr_s, current, name, origin))
            skipped_named += 1
            continue

        # The TSV carries Class::Method; Ghidra holds the class as the function's
        # namespace, so set only the leaf and leave the namespace as found.
        fn.setName(leaf(name), SourceType.USER_DEFINED)
        print("RENAMED  %s  %s -> %s  (origin=%s)" % (addr_s, current, leaf(name), origin))
        applied += 1

    print("")
    print("applied %d, already named %d, no function %d, other binary %d"
          % (applied, skipped_named, missing, skipped_other))


main()
