#!/usr/bin/env python3
"""Builds the party golden fixtures from docs/protocol/party_protocol.md's tables.

Round 710. This assembler is written from the spec tables, independently of
server/internal/party/wire.go and client/scripts/net/party.gd; both of those are
tested against the files it writes, so the two sides cannot drift apart or drift
from the spec together.

Run from this directory: python3 gen_fixtures.py
It rewrites every *.hex here and README.md's case table.
"""
import os
import struct

HERE = os.path.dirname(os.path.abspath(__file__))


def u8(v):
    return struct.pack("<B", v)


def u16(v):
    return struct.pack("<H", v)


def u32(v):
    return struct.pack("<I", v & 0xFFFFFFFF)


def s(text):
    raw = text.encode("ascii")
    return u16(len(raw)) + raw


def record(mask, f):
    """party_protocol.md "The party member record": mask, then by bit in the
    record's order -- 0x10 JID; 0x01 name, RefObjID; 0x02 level; 0x04 HP/MP;
    0x20 region, x, y, z (u16 each, u32 each when region & 0x8000), world id;
    0x40 guild; 0x80 job; 0x08 mastery 1, mastery 2."""
    b = u8(mask)
    if mask & 0x10:
        b += u32(f["jid"])
    if mask & 0x01:
        b += s(f["name"]) + u32(f["refobj"])
    if mask & 0x02:
        b += u8(f["level"])
    if mask & 0x04:
        b += u8(f["hpmp"])
    if mask & 0x20:
        b += u16(f["region"])
        if f["region"] & 0x8000:
            b += u32(f["x"]) + u32(f["y"]) + u32(f["z"])
        else:
            b += u16(f["x"] & 0xFFFF) + u16(f["y"] & 0xFFFF) + u16(f["z"] & 0xFFFF)
        b += u32(f["world"])
    if mask & 0x40:
        b += s(f["guild"])
    if mask & 0x80:
        b += u8(f["job"])
    if mask & 0x08:
        b += u32(f["m1"]) + u32(f["m2"])
    return b


# The characters every case uses. JIDs are OpenSRO's (OURS): the low 32 bits of
# the character id. Region 0x61a8 is 97/168 (x high byte, y low byte), Jangan.
ARIA = dict(jid=101, name="Aria", refobj=1907, level=10, hpmp=0x5A, region=0x61A8,
            x=1002, y=30, z=1020, world=1, guild="", job=4, m1=257, m2=258)
BRAM = dict(jid=201, name="Bram", refobj=1908, level=7, hpmp=0xAA, region=0x61A8,
            x=990, y=31, z=1011, world=1, guild="Wolves", job=4, m1=0, m2=0)
DUNGEON = dict(ARIA, region=0x8001, x=70000, y=-5, z=12)

CASES = []  # (file, opcode, direction, description, bytes)


def case(name, opcode, direction, desc, data):
    CASES.append((name, opcode, direction, desc, data))


# --- S1: create, invite, answer, acks -----------------------------------------
case("7060_create_exp_item", 0x7060, "C->S", "create + invite target 201, flags 0x03 (exp share, item share)",
     u32(201) + u8(0x03))
case("7060_create_all", 0x7060, "C->S", "target 201, flags 0x07 (exp, item, anyone may invite)",
     u32(201) + u8(0x07))
case("7060_create_ffa", 0x7060, "C->S", "target 201, flags 0x00 (both free-for-all: a 4-member party)",
     u32(201) + u8(0x00))
case("b060_ok", 0xB060, "S->C", "inviter's ack: [1][own JID 101]", u8(1) + u32(101))
case("b060_err_too_far", 0xB060, "S->C", "refused: target out of range, bare code 4", u8(2) + u16(4))
case("b060_err_low_level", 0xB060, "S->C", "refused 0x2c0a, creator below level 5", u8(2) + u16(0x2C0A))
case("b060_err_post_failed", 0xB060, "S->C", "the 0x7062 quirk: posting failed, [2][2] on 0xb060", u8(2) + u16(2))
case("b060_err_timeout", 0xB060, "S->C", "invitation timed out, 0x2c10", u8(2) + u16(0x2C10))
case("7062_invite", 0x7062, "C->S", "invite target 301 into my party", u32(301))
case("b062_err_full_exp", 0xB062, "S->C", "refused 0x2c13, exp-shared party full", u8(2) + u16(0x2C13))
case("b062_err_full_ffa", 0xB062, "S->C", "refused 0x2c14, non-shared party full", u8(2) + u16(0x2C14))
case("b062_err_declined", 0xB062, "S->C", "the invitee declined a join invitation, 0x2c17", u8(2) + u16(0x2C17))
case("3080_invite_new", 0x3080, "S->C", "invitation kind 2 (form a party) from 101, flags 0x03",
     u8(2) + u32(101) + u8(0x03))
case("3080_invite_existing", 0x3080, "S->C", "invitation kind 3 (join my party) from 101, flags 0x07",
     u8(3) + u32(101) + u8(0x07))
case("3080_answer_yes", 0x3080, "C->S", "yes: [1][1]", u8(1) + u8(1))
case("3080_answer_no_form", 0x3080, "C->S", "no to a kind-2: [2][0x2c0c]", u8(2) + u16(0x2C0C))
case("3080_answer_no_join", 0x3080, "C->S", "no to a kind-3: [2][0x2c17]", u8(2) + u16(0x2C17))
case("b067_ok", 0xB067, "S->C", "invitee's ack: [1][own JID 201]", u8(1) + u32(201))
case("b067_err_timeout", 0xB067, "S->C", "invitation timed out, 0x2c10", u8(2) + u16(0x2C10))
case("b067_err_mismatch", 0xB067, "S->C", "formation refused, job mismatch 0x2c23", u8(2) + u16(0x2C23))
case("7061_leave", 0x7061, "C->S", "leave: no payload", b"")
case("7063_kick", 0x7063, "C->S", "kick member JID 201", u32(201))

# --- S1: the member record and the party ---------------------------------------
case("record_full_aria", None, "both", "Aria's full record, mask 0xff", record(0xFF, ARIA))
case("record_full_bram", None, "both", "Bram's full record, mask 0xff (guild Wolves, no masteries)", record(0xFF, BRAM))
case("record_full_dungeon", None, "both", "Aria in dungeon region 0x8001: x, y, z as u32 (y = -5)",
     record(0xFF, DUNGEON))
case("3065_two_members", 0x3065, "S->C",
     "party 7, leader 101, flags 0x03, Aria then Bram (full records)",
     u8(0xFF) + u32(7) + u32(101) + u8(0x03) + u8(2) + record(0xFF, ARIA) + record(0xFF, BRAM))
case("3065_one_member", 0x3065, "S->C",
     "party 7 as the inviter first sees it: leader 101, flags 0x03, Aria alone",
     u8(0xFF) + u32(7) + u32(101) + u8(0x03) + u8(1) + record(0xFF, ARIA))

# --- S1: 0x3864 events --------------------------------------------------------
case("3864_k1_dissolved", 0x3864, "S->C", "kind 1, party dissolved, code 0x2c0b", u8(1) + u16(0x2C0B))
case("3864_k2_joined", 0x3864, "S->C", "kind 2, Bram joined (full record)", u8(2) + record(0xFF, BRAM))
case("3864_k3_logout", 0x3864, "S->C", "kind 3, 201 left, reason 1 logout", u8(3) + u32(201) + u8(1))
case("3864_k3_left", 0x3864, "S->C", "kind 3, 201 left, reason 2 secede", u8(3) + u32(201) + u8(2))
case("3864_k3_kicked", 0x3864, "S->C", "kind 3, 201 left, reason 4 booted", u8(3) + u32(201) + u8(4))
case("3864_k6_hpmp", 0x3864, "S->C", "kind 6, 101's HP/MP: mask 0x04, byte 0x5b (HP step 11, MP 5)",
     u8(6) + u32(101) + record(0x04, dict(ARIA, hpmp=0x5B)))
case("3864_k6_level", 0x3864, "S->C", "kind 6, 101 reached level 11: mask 0x02",
     u8(6) + u32(101) + record(0x02, dict(ARIA, level=11)))
case("3864_k6_position", 0x3864, "S->C", "kind 6, 101 moved: mask 0x20, region 0x61a8, 1100, 30, 900, world 1",
     u8(6) + u32(101) + record(0x20, dict(ARIA, x=1100, z=900)))
case("3864_k6_position_dungeon", 0x3864, "S->C", "kind 6, 101 in dungeon region 0x8001: u32 coordinates",
     u8(6) + u32(101) + record(0x20, DUNGEON))
case("3864_k6_guild", 0x3864, "S->C", "kind 6, 101 joined guild Wolves: mask 0x40",
     u8(6) + u32(101) + record(0x40, dict(ARIA, guild="Wolves")))
case("3864_k6_masteries", 0x3864, "S->C", "kind 6, 101's masteries 257 and 259: mask 0x08",
     u8(6) + u32(101) + record(0x08, dict(ARIA, m2=259)))
case("3864_k6_name_model", 0x3864, "S->C", "kind 6, 101's name and model: mask 0x01, Aria, 1910",
     u8(6) + u32(101) + record(0x01, dict(ARIA, refobj=1910)))
case("3864_k6_hpmp_level", 0x3864, "S->C", "kind 6, two fields at once: mask 0x06, level 11 then HP/MP 0xab",
     u8(6) + u32(101) + record(0x06, dict(ARIA, level=11, hpmp=0xAB)))
case("3864_k9_leader", 0x3864, "S->C", "kind 9, the new leader is 201", u8(9) + u32(201))

# --- S3 / C2: party matching -------------------------------------------------
ENTRY = u32(0) + u32(0) + u8(0x03) + u8(0) + u8(1) + u8(110) + s("For open hunting")
case("7069_register", 0x7069, "C->S",
     "register: entry 0, party 0, flags 0x03, purpose 0 hunting, levels 1..110, title 'For open hunting'", ENTRY)
case("b069_ok", 0xB069, "S->C",
     "registered: [1] entry 12, party 7, flags 0x03, purpose 0, 1..110, title",
     u8(1) + u32(12) + u32(7) + u8(0x03) + u8(0) + u8(1) + u8(110) + s("For open hunting"))
case("706a_change", 0x706A, "C->S", "change entry 12: purpose 1 quest, levels 5..20, title 'Quests'",
     u32(12) + u32(0) + u8(0x03) + u8(1) + u8(5) + u8(20) + s("Quests"))
case("706b_delete", 0x706B, "C->S", "delete entry 12", u32(12))
case("b06b_ok", 0xB06B, "S->C", "deleted: [1][12]", u8(1) + u32(12))
case("706c_page", 0x706C, "C->S", "list page 0", u8(0))
ROW1 = u32(12) + u32(1759500000) + s("Aria") + u8(0) + u8(2) + u8(0x03) + u8(0) + u8(1) + u8(110) + s("For open hunting")
ROW2 = u32(15) + u32(1759500300) + s("Bram") + u8(1) + u8(1) + u8(0x00) + u8(2) + u8(20) + u8(40) + s("Traders")
case("b06c_page", 0xB06C, "S->C",
     "page: [1] 3 pages, index 0, 2 rows: entry 12 Aria race 0 2 members flags 0x03 purpose 0 1..110; "
     "entry 15 Bram race 1 1 member flags 0x00 purpose 2 20..40",
     u8(1) + u8(3) + u8(0) + u8(2) + ROW1 + ROW2)
case("b06c_empty", 0xB06C, "S->C", "no entries: [1][0][0][0]", u8(1) + u8(0) + u8(0) + u8(0))
case("706d_request", 0x706D, "C->S", "join request for entry 12", u32(12))
case("706d_to_leader", 0x706D, "S->C",
     "request shown to the leader: job 0x41, requester 201, entry 12, masteries 257/258, job 4, Bram's full record",
     u32(0x41) + u32(201) + u32(12) + u32(257) + u32(258) + u8(4) + record(0xFF, BRAM))
case("306e_confirm", 0x306E, "C->S", "leader confirms: job 0x41, requester 201, answer 1",
     u32(0x41) + u32(201) + u8(1))
case("306e_closed", 0x306E, "C->S", "the popup's 10 s timer: answer 2", u32(0x41) + u32(201) + u8(2))
case("b06d_joined", 0xB06D, "S->C", "[1][1] joined", u8(1) + u16(1))
case("b06d_refused", 0xB06D, "S->C", "[1][0] refused by the leader", u8(1) + u16(0))
case("b06d_noreply", 0xB06D, "S->C", "[1][2] no reply", u8(1) + u16(2))
case("b06d_err_level", 0xB06D, "S->C", "[2][0x2c1e] level outside the entry's range", u8(2) + u16(0x2C1E))


def main():
    for name in os.listdir(HERE):
        if name.endswith(".hex"):
            os.remove(os.path.join(HERE, name))
    rows = []
    for name, opcode, direction, desc, data in CASES:
        with open(os.path.join(HERE, name + ".hex"), "w") as f:
            f.write(" ".join("%02x" % c for c in data) + "\n")
        op = "0x%04x" % opcode if opcode is not None else "(record)"
        rows.append("| `%s.hex` | %s | %s | %d | %s |" % (name, op, direction, len(data), desc))
    readme = os.path.join(HERE, "README.md")
    with open(readme) as f:
        text = f.read()
    start = text.index("<!-- cases -->")
    end = text.index("<!-- /cases -->")
    table = "<!-- cases -->\n| file | opcode | dir | bytes | case |\n|---|---|---|---|---|\n" + "\n".join(rows) + "\n"
    with open(readme, "w") as f:
        f.write(text[:start] + table + text[end:])
    print("%d fixtures written" % len(CASES))


if __name__ == "__main__":
    main()
