# The RE toolkit

Three scripts that live on the RE box at `/var/tmp/`, vendored here so they are
not lost when `/var/tmp` is cleaned. `docs/RE_LOOP.md` is the operating manual;
this is just what each file is.

| file | what |
|---|---|
| `rebox.py` | the dump/disassembly reader — classes, functions, vtable slots, strings, callers, param reads, pk2 extraction, textdata census |
| `vtindex.py` | builds the class → vtable index from a PE's RTTI, cached as JSON (1,189 classes and 38,634 slots from the server binary in half a second) |
| `vtq.py` | queries that index — one class's vtable, a base/derived diff, and `who <addr>`, which is the COMDAT-folding check to run **before** attaching any name |

## Deploying them

    for f in rebox.py vtindex.py vtq.py; do
      ssh root@192.168.5.78 "rm -f /var/tmp/$f"
      ssh root@192.168.5.78 "cat > /var/tmp/$f" < client/tools/re/$f
      ssh root@192.168.5.78 "chown ghidra:ghidra /var/tmp/$f"
    done
    ssh root@192.168.5.78 'cd /var/tmp && python3 vtindex.py build \
      /var/tmp/SR_GameServer.exe /var/tmp/vt_server.json'

`/var/tmp` on the box is owned by `ghidra` and sticky, so `scp` over an existing
file fails even as root — delete first, or pipe through `cat` as above.

**Do not rename `rebox.py` to `re.py`.** It shadows the standard library's `re`
and nothing on the box will import.
