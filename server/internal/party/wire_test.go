package party

import (
	"bytes"
	"encoding/hex"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// fixtureDir is the golden fixtures' home (round 710), under client/ so the
// render box's GDScript tests see the same files.
const fixtureDir = "../../../client/scripts/net/fixtures/party"

func fixture(t *testing.T, name string) []byte {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join(fixtureDir, name+".hex"))
	if err != nil {
		t.Fatalf("fixture %s: %v", name, err)
	}
	b, err := hex.DecodeString(strings.Join(strings.Fields(string(raw)), ""))
	if err != nil {
		t.Fatalf("fixture %s: %v", name, err)
	}
	return b
}

var (
	aria = Record{Mask: MaskFull, JID: 101, Name: "Aria", RefObjID: 1907, Level: 10, HPMP: 0x5a, Region: 0x61a8,
		X: 1002, Y: 30, Z: 1020, WorldID: 1, Guild: "", Job: 4, Mastery1: 257, Mastery2: 258}
	bram = Record{Mask: MaskFull, JID: 201, Name: "Bram", RefObjID: 1908, Level: 7, HPMP: 0xaa, Region: 0x61a8,
		X: 990, Y: 31, Z: 1011, WorldID: 1, Guild: "Wolves", Job: 4}
)

func with(r Record, mask byte, edit func(*Record)) *Record {
	r.Mask = mask
	if edit != nil {
		edit(&r)
	}
	return &r
}

// TestEncodersMatchTheFixtures checks every encoder against the bytes the
// spec-table assembler (gen_fixtures.py) wrote.
func TestEncodersMatchTheFixtures(t *testing.T) {
	dungeon := aria
	dungeon.Region, dungeon.X, dungeon.Y, dungeon.Z = 0x8001, 70000, -5, 12
	entry := Entry{Flags: 0x03, Purpose: PurposeHunting, MinLevel: 1, MaxLevel: 110, Title: "For open hunting"}
	registered := entry
	registered.Number, registered.PartyID = 12, 7
	rows := []ListEntry{
		{Number: 12, Time: 1759500000, Name: "Aria", Race: 0, Count: 2, Flags: 0x03, Purpose: 0, MinLevel: 1, MaxLevel: 110, Title: "For open hunting"},
		{Number: 15, Time: 1759500300, Name: "Bram", Race: 1, Count: 1, Flags: 0x00, Purpose: 2, MinLevel: 20, MaxLevel: 40, Title: "Traders"},
	}
	cases := map[string][]byte{
		"7060_create_exp_item":     EncodeCreate(201, FlagExpShare|FlagItemShare),
		"7060_create_all":          EncodeCreate(201, FlagExpShare|FlagItemShare|FlagAnyoneInvite),
		"7060_create_ffa":          EncodeCreate(201, 0),
		"b060_ok":                  EncodeOKID(101),
		"b060_err_too_far":         EncodeRefusal(CodeTooFar),
		"b060_err_low_level":       EncodeRefusal(CodeTooLowCreator),
		"b060_err_post_failed":     EncodeRefusal(CodePostFailed),
		"b060_err_timeout":         EncodeRefusal(CodeTimeout),
		"7062_invite":              EncodeTarget(301),
		"b062_err_full_exp":        EncodeRefusal(CodeFullExpShared),
		"b062_err_full_ffa":        EncodeRefusal(CodeFullNotShared),
		"b062_err_declined":        EncodeRefusal(CodeJoinRefused),
		"3080_invite_new":          EncodeInvitation(InviteForm, 101, 0x03),
		"3080_invite_existing":     EncodeInvitation(InviteJoin, 101, 0x07),
		"3080_answer_yes":          EncodeAnswerYes(),
		"3080_answer_no_form":      EncodeAnswerNo(CodeCreateRefused),
		"3080_answer_no_join":      EncodeAnswerNo(CodeJoinRefused),
		"b067_ok":                  EncodeOKID(201),
		"b067_err_timeout":         EncodeRefusal(CodeTimeout),
		"b067_err_mismatch":        EncodeRefusal(CodeUserMismatch),
		"7061_leave":               {},
		"7063_kick":                EncodeTarget(201),
		"record_full_aria":         AppendRecord(nil, &aria),
		"record_full_bram":         AppendRecord(nil, &bram),
		"record_full_dungeon":      AppendRecord(nil, &dungeon),
		"3065_two_members":         EncodeInfo(&Info{PartyID: 7, Leader: 101, Flags: 0x03, Members: []Record{aria, bram}}),
		"3065_one_member":          EncodeInfo(&Info{PartyID: 7, Leader: 101, Flags: 0x03, Members: []Record{aria}}),
		"3864_k1_dissolved":        EncodeDissolved(CodeDissolved),
		"3864_k2_joined":           EncodeJoined(&bram),
		"3864_k3_logout":           EncodeLeft(201, ReasonLogout),
		"3864_k3_left":             EncodeLeft(201, ReasonLeave),
		"3864_k3_kicked":           EncodeLeft(201, ReasonKicked),
		"3864_k6_hpmp":             EncodeUpdate(101, with(aria, MaskHPMP, func(r *Record) { r.HPMP = 0x5b })),
		"3864_k6_level":            EncodeUpdate(101, with(aria, MaskLevel, func(r *Record) { r.Level = 11 })),
		"3864_k6_position":         EncodeUpdate(101, with(aria, MaskPosition, func(r *Record) { r.X, r.Z = 1100, 900 })),
		"3864_k6_position_dungeon": EncodeUpdate(101, with(dungeon, MaskPosition, nil)),
		"3864_k6_guild":            EncodeUpdate(101, with(aria, MaskGuild, func(r *Record) { r.Guild = "Wolves" })),
		"3864_k6_masteries":        EncodeUpdate(101, with(aria, MaskMastery, func(r *Record) { r.Mastery2 = 259 })),
		"3864_k6_name_model":       EncodeUpdate(101, with(aria, MaskName, func(r *Record) { r.RefObjID = 1910 })),
		"3864_k6_hpmp_level":       EncodeUpdate(101, with(aria, MaskHPMP|MaskLevel, func(r *Record) { r.Level, r.HPMP = 11, 0xab })),
		"3864_k9_leader":           EncodeLeader(201),
		"7069_register":            AppendEntry(nil, &entry),
		"b069_ok":                  AppendEntry([]byte{ResultOK}, &registered),
		"706a_change":              AppendEntry(nil, &Entry{Number: 12, Flags: 0x03, Purpose: PurposeQuest, MinLevel: 5, MaxLevel: 20, Title: "Quests"}),
		"706b_delete":              EncodeTarget(12),
		"b06b_ok":                  EncodeOKID(12),
		"706c_page":                {0},
		"b06c_page":                EncodeListPage(3, 0, rows),
		"b06c_empty":               EncodeListPage(0, 0, nil),
		"706d_request":             EncodeTarget(12),
		"706d_to_leader":           EncodeJoinRequest(&JoinRequest{JobID: 0x41, Requester: 201, Entry: 12, Mastery1: 257, Mastery2: 258, Job: 4, Record: bram}),
		"306e_confirm":             EncodeJoinAnswer(0x41, 201, AnswerConfirm),
		"306e_closed":              EncodeJoinAnswer(0x41, 201, AnswerClosed),
		"b06d_joined":              EncodeJoinResult(JoinJoined),
		"b06d_refused":             EncodeJoinResult(JoinRefused),
		"b06d_noreply":             EncodeJoinResult(JoinNoReply),
		"b06d_err_level":           EncodeRefusal(0x2c1e),
	}
	files, _ := filepath.Glob(filepath.Join(fixtureDir, "*.hex"))
	if len(files) != len(cases) {
		t.Errorf("%d fixture files, %d cases: every fixture needs an encoder case", len(files), len(cases))
	}
	for name, got := range cases {
		if want := fixture(t, name); !bytes.Equal(got, want) {
			t.Errorf("%s:\n got % x\nwant % x", name, got, want)
		}
	}
}

// TestDecodersReadTheFixtures reads fixtures back the way the other side does.
func TestDecodersReadTheFixtures(t *testing.T) {
	in, err := DecodeInfo(fixture(t, "3065_two_members"))
	if err != nil {
		t.Fatal(err)
	}
	if in.PartyID != 7 || in.Leader != 101 || in.Flags != 0x03 || !reflect.DeepEqual(in.Members, []Record{aria, bram}) {
		t.Fatalf("3065: %+v", in)
	}
	dungeon, _, err := ReadRecord(fixture(t, "record_full_dungeon"))
	if err != nil || dungeon.X != 70000 || dungeon.Y != -5 || dungeon.Z != 12 {
		t.Fatalf("dungeon record: %+v %v", dungeon, err)
	}
	ev, err := DecodeEvent(fixture(t, "3864_k3_kicked"))
	if err != nil || ev.Kind != EventLeft || ev.JID != 201 || ev.Reason != ReasonKicked {
		t.Fatalf("kind 3: %+v %v", ev, err)
	}
	ev, err = DecodeEvent(fixture(t, "3864_k6_hpmp_level"))
	if err != nil || ev.Kind != EventUpdate || ev.JID != 101 || ev.Record.Mask != MaskHPMP|MaskLevel || ev.Record.Level != 11 || ev.Record.HPMP != 0xab {
		t.Fatalf("kind 6: %+v %v", ev, err)
	}
	ev, err = DecodeEvent(fixture(t, "3864_k2_joined"))
	if err != nil || !reflect.DeepEqual(ev.Record, bram) {
		t.Fatalf("kind 2: %+v %v", ev, err)
	}
	target, flags, err := DecodeCreate(fixture(t, "7060_create_all"))
	if err != nil || target != 201 || flags != 0x07 {
		t.Fatalf("0x7060: %d %d %v", target, flags, err)
	}
	kind, inviter, flags, err := DecodeInvitation(fixture(t, "3080_invite_existing"))
	if err != nil || kind != InviteJoin || inviter != 101 || flags != 0x07 {
		t.Fatalf("0x3080: %d %d %d %v", kind, inviter, flags, err)
	}
	if yes, _ := DecodeAnswer(fixture(t, "3080_answer_yes")); !yes {
		t.Fatal("yes read as no")
	}
	if yes, _ := DecodeAnswer(fixture(t, "3080_answer_no_join")); yes {
		t.Fatal("no read as yes")
	}
	// The stock client's "no" to a formation, [2][0x2c0c], declines (OURS:
	// this GameServer's kind-2 test, `test bl,bl` at 0x5be41c, would accept it).
	if yes, _ := DecodeAnswer(fixture(t, "3080_answer_no_form")); yes {
		t.Fatal("a formation's no read as yes")
	}
	a, err := DecodeIDAck(fixture(t, "b060_err_post_failed"))
	if err != nil || a.OK || a.Code != CodePostFailed {
		t.Fatalf("ack: %+v %v", a, err)
	}
	j, err := DecodeJoinRequest(fixture(t, "706d_to_leader"))
	if err != nil || j.JobID != 0x41 || j.Requester != 201 || j.Entry != 12 || j.Mastery1 != 257 || !reflect.DeepEqual(j.Record, bram) {
		t.Fatalf("0x706d: %+v %v", j, err)
	}
	e, rest, err := ReadEntry(fixture(t, "706a_change"))
	if err != nil || len(rest) != 0 || e.Number != 12 || e.Purpose != PurposeQuest || e.Title != "Quests" {
		t.Fatalf("entry: %+v %v", e, err)
	}
	page := fixture(t, "b06c_page")
	row, rest, err := ReadListEntry(page[4:])
	if err != nil || row.Number != 12 || row.Name != "Aria" || row.Count != 2 {
		t.Fatalf("row 1: %+v %v", row, err)
	}
	if row, rest, err = ReadListEntry(rest); err != nil || row.Number != 15 || row.Title != "Traders" || len(rest) != 0 {
		t.Fatalf("row 2: %+v %v", row, err)
	}
}

func TestShortPayloadsAreRefused(t *testing.T) {
	full := fixture(t, "3065_two_members")
	for n := 0; n < len(full); n++ {
		if _, err := DecodeInfo(full[:n]); err == nil {
			t.Fatalf("0x3065 cut to %d bytes decoded", n)
		}
	}
	if _, _, err := DecodeCreate([]byte{1, 2, 3, 4}); err == nil {
		t.Fatal("a 4-byte 0x7060 decoded")
	}
}

// TestHPMPFull is the full record's tenths: trunc(cur/max x 10) per nibble.
func TestHPMPFull(t *testing.T) {
	cases := []struct {
		hp, maxHP, mp, maxMP int
		want                 uint8
	}{
		{200, 200, 200, 200, 0xaa},
		{199, 200, 100, 200, 0x59},
		{0, 200, 0, 200, 0x00},
		{3, 10, 7, 10, 0x73}, // 0.3 x 10 and 0.7 x 10 land on 3.0 and 7.0 in doubles
		{1, 200, 19, 200, 0x00},
		{5, 0, 5, 0, 0x00},
	}
	for _, c := range cases {
		if got := HPMPFull(c.hp, c.maxHP, c.mp, c.maxMP); got != c.want {
			t.Errorf("HPMPFull(%d/%d, %d/%d) = %#x, want %#x", c.hp, c.maxHP, c.mp, c.maxMP, got, c.want)
		}
	}
}

// TestHPMPUpdate is FUN_005bb0c0's step: HP 1 + trunc(10 r) (11 at full),
// MP trunc(10 r), and nothing sent while neither nibble moves.
func TestHPMPUpdate(t *testing.T) {
	b, changed := HPMPUpdate(0xaa, 200, 200, 200, 200) // a full record's 0xa HP becomes the update's 0xb
	if !changed || b != 0xab {
		t.Fatalf("full HP from a full record: %#x %v, want 0xab true", b, changed)
	}
	if b2, changed := HPMPUpdate(b, 200, 200, 200, 200); changed || b2 != b {
		t.Fatalf("no change sent an update: %#x %v", b2, changed)
	}
	if b2, changed := HPMPUpdate(b, 199, 200, 200, 200); !changed || b2 != 0xaa {
		t.Fatalf("199/200 HP: %#x %v, want 0xaa (step 1 + 9)", b2, changed)
	}
	if b2, changed := HPMPUpdate(0xaa, 199, 200, 199, 200); !changed || b2 != 0x9a {
		t.Fatalf("MP 199/200: %#x %v, want 0x9a", b2, changed)
	}
	if b2, changed := HPMPUpdate(0x9a, 0, 200, 190, 200); !changed || b2 != 0x90 {
		t.Fatalf("dead: %#x %v, want 0x90 (HP 0 is step 0)", b2, changed)
	}
	if b2, _ := HPMPUpdate(0, 1, 200, 0, 200); b2 != 0x01 {
		t.Fatalf("1 HP: %#x, want 0x01", b2)
	}
}
