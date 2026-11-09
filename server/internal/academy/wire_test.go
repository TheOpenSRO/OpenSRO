package academy

import (
	"bytes"
	"encoding/hex"
	"strings"
	"testing"
	"time"
)

// The golden bytes are section 6's measured sequences (docs/protocol/
// academy.md) with every identifier replaced by a synthetic one of the same
// width, the values the client's fixtures (client/scripts/net/fixtures/
// academy) use: the camp 101 (0x65); the characters 0x101 "Guardian1" (a job
// alias "Trader7"), 0x102 "Novice001", 0x103 "Assist40"; every date
// 2026-01-01 00:00; the open world 0x00010001 (a constant), region 0x0101 and
// x, y, z 0x10.. / 0x11.. / 0x12.. by character. The layouts, the field
// values that are not identifiers and the order are the measured ones.

func h(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(strings.ReplaceAll(s, " ", ""))
	if err != nil {
		t.Fatalf("bad hex %q: %v", s, err)
	}
	return b
}

func hs(s string) string { return hex.EncodeToString([]byte(s)) }

func same(t *testing.T, what string, got, want []byte) {
	t.Helper()
	if !bytes.Equal(got, want) {
		t.Errorf("%s:\n got % x\nwant % x", what, got, want)
	}
}

var day = time.Date(2026, 1, 1, 0, 0, 0, 0, time.Local)

const (
	tsDay   = "ea07 0100 0100 0000 0000 0000 00000000"
	camp    = "65000000"
	gID     = "01010000"
	nID     = "02010000"
	aID     = "03010000"
	refObj  = "73070000"
	world   = "01000100"
	region  = "0101"
	gPlace  = world + region + " 1000 2000 3000"
	nPlace  = world + region + " 1100 2100 3100"
	aPlace  = world + region + " 1200 2200 3200"
	noPlace = "00000000 0000 0000 0000 0000"
	notice  = "0d00" + "48656c6c6f2041636164656d79" + " 1000" + "54657374206e6f74696365206c696e65"
)

func gMember() Member {
	return Member{CampID: 0x65, CharID: 0x101, RefObjID: 0x773, Name: "Guardian1", JoinDate: day, Class: 0, JoinedLevel: 70, CurLevel: 70, MaxLevel: 70}
}

func nMember() Member {
	return Member{CampID: 0x65, CharID: 0x102, RefObjID: 0x773, Name: "Novice001", JoinDate: day, Class: 2, JoinedLevel: 1, CurLevel: 1, MaxLevel: 1}
}

func aMember() Member {
	return Member{CampID: 0x65, CharID: 0x103, RefObjID: 0x773, Name: "Assist40", JoinDate: day, Class: 1, JoinedLevel: 40, CurLevel: 40, MaxLevel: 40}
}

func goldenCamp(withNotice bool, ms ...Member) *Camp {
	c := &Camp{ID: 0x65, CreationDate: day, Rank: RankNone, LatestEvaluationDate: day, Members: ms}
	if withNotice {
		c.NoticeTitle, c.Notice = "Hello Academy", "Test notice line"
	}
	return c
}

func gLive(state byte) Live {
	return Live{PlayState: state, World: WorldOpen, Region: 0x0101, X: 0x10, Y: 0x20, Z: 0x30, Display: "Trader7"}
}

func nLive(state byte, name string) Live {
	return Live{PlayState: state, World: WorldOpen, Region: 0x0101, X: 0x11, Y: 0x21, Z: 0x31, Display: name}
}

func aLive(state byte) Live {
	return Live{PlayState: state, World: WorldOpen, Region: 0x0101, X: 0x12, Y: 0x22, Z: 0x32, Display: "Assist40"}
}

const (
	gEntry = camp + gID + refObj + " 0900" + "477561726469616e31" + " 00 46 " + tsDay + " 46 46 00000000"
	nEntry = camp + nID + refObj + " 0900" + "4e6f76696365303031" + " 02 01 " + tsDay + " 01 01 00000000"
	aEntry = camp + aID + refObj + " 0800" + "4173736973743430" + " 01 28 " + tsDay + " 28 28 00000000"
)

func TestWireTimestamp(t *testing.T) {
	same(t, "the day", AppendTS(nil, day), h(t, tsDay))
	same(t, "a minute-rounded join", AppendTS(nil, Minute(time.Date(2026, 1, 1, 0, 16, 41, 0, time.Local))),
		h(t, "ea07 0100 0100 0000 1100 0000 00000000"))
}

// 0xB470 {1, CampInfo}: the founder's own entry at play state 1 with its
// place and its name (fixture b470_founded).
func TestWireFounded(t *testing.T) {
	c := goldenCamp(false, gMember())
	live := func(Member) Live { return gLive(PlayOffline) }
	want := "01 " + camp + tsDay + " 05 0000 0000 01 " + gEntry + " 01 " + gPlace + " 0700" + hs("Trader7")
	same(t, "B470", EncodeCampOK(c, live), h(t, want))
}

// The joiner's 0x3C80 {0a 01, CampInfo} (fixture 3c80_0a_joined): the
// guardian online in a job suit (its alias as the display name), the
// joiner's own copy at play state 1 with its place and its name.
func TestWireJoinOK(t *testing.T) {
	live := func(m Member) Live {
		if m.CharID == 0x101 {
			return gLive(PlayOnline)
		}
		return nLive(PlayOffline, "Novice001")
	}
	want := "0a 01 " + camp + tsDay + " 05 0000 0000 02 " +
		gEntry + " 00 " + gPlace + " 0700" + hs("Trader7") +
		nEntry + " 01 " + nPlace + " 0900" + hs("Novice001")
	same(t, "0a 01", EncodeJoinOK(goldenCamp(false, gMember(), nMember()), live), h(t, want))
}

// The assistant's 0a 01 with the notice and three members (fixture
// 3c80_0a_joined_asst): the apprentice online, the joiner at play state 1.
func TestWireJoinOKAssistant(t *testing.T) {
	live := func(m Member) Live {
		switch m.CharID {
		case 0x101:
			return gLive(PlayOnline)
		case 0x102:
			return nLive(PlayOnline, "Novice001")
		}
		return aLive(PlayOffline)
	}
	want := "0a 01 " + camp + tsDay + " 05 " + notice + " 03 " +
		gEntry + " 00 " + gPlace + " 0700" + hs("Trader7") +
		nEntry + " 00 " + nPlace + " 0900" + hs("Novice001") +
		aEntry + " 01 " + aPlace + " 0800" + hs("Assist40")
	same(t, "0a 01 (assistant)", EncodeJoinOK(goldenCamp(true, gMember(), nMember(), aMember()), live), h(t, want))
}

// The 0x3C80 {02, MemberEntry} the existing members get: play state 1, no
// place, no name (fixtures 3c80_02_joined, 3c80_02_joined_asst).
func TestWireJoined(t *testing.T) {
	same(t, "02 apprentice", EncodeJoined(nMember(), Unplaced), h(t, "02 "+nEntry+" 01 "+noPlace+" 0000"))
	same(t, "02 assistant", EncodeJoined(aMember(), Unplaced), h(t, "02 "+aEntry+" 01 "+noPlace+" 0000"))
}

// 0x3C81 at a teleport (fixture 3c81_world): the notice, the member's own
// entry online at its place, an offline member at its last-known place with
// no name.
func TestWireCampInfoAtWorldEntry(t *testing.T) {
	live := func(m Member) Live {
		if m.CharID == 0x101 {
			return gLive(PlayOnline)
		}
		return nLive(PlayOffline, "")
	}
	want := camp + tsDay + " 05 " + notice + " 02 " +
		gEntry + " 00 " + gPlace + " 0700" + hs("Trader7") +
		nEntry + " 01 " + nPlace + " 0000"
	same(t, "3C81", EncodeCampInfo(goldenCamp(true, gMember(), nMember()), live), h(t, want))
}

func TestWirePushes(t *testing.T) {
	same(t, "05 online", EncodeFieldU8(0x101, FieldPlayState, PlayOnline), h(t, "05 "+gID+" 01 00"))
	same(t, "05 offline", EncodeFieldU8(0x102, FieldPlayState, PlayOffline), h(t, "05 "+nID+" 01 01"))
	same(t, "05 honor", EncodeFieldU32(0x101, FieldHonor, 39), h(t, "05 "+gID+" 03 27000000"))
	same(t, "05 name", EncodeFieldStr(0x101, FieldName, "Ab"), h(t, "05 "+gID+" 05 0200 4162"))
	same(t, "0d", EncodePosition(0x102, nLive(0, "Novice001")), h(t, "0d "+nID+" 0900"+hs("Novice001")+nPlace))
	same(t, "07", EncodeNotice("Hello Academy", "Test notice line"), h(t, "07 "+notice))
	same(t, "0a 02 timeout", EncodeJoinFail(ErrInviteTimeout), h(t, "0a 02 0e00"))
	same(t, "0a 02 refused", EncodeJoinFail(ErrInviteRejection), h(t, "0a 02 1168"))
	same(t, "01", EncodeDisbanded(), h(t, "01"))
	same(t, "03", EncodeRemoved(0x102, RemoveBanned), h(t, "03 "+nID+" 02"))
	same(t, "04", EncodeGraduated(0x102, 1), h(t, "04 "+nID+" 01"))
	same(t, "0c", EncodeRank(4), h(t, "0c 04"))
	// 0x3080 kind 9 {09, u32 inviter, str name} (fixture 3080_invite).
	same(t, "3080 kind 9", EncodeInvitation(0x101, "Guardian1"), h(t, "09 "+gID+" 0900"+hs("Guardian1")))
}

func TestWireReplies(t *testing.T) {
	same(t, "B471 0x681d", EncodeFailSeconds(ErrNotDisorganization7D, 603589), h(t, "02 1d68 c5350900"))
	same(t, "B472 timeout", EncodeFail(ErrInviteTimeout), h(t, "02 0e00"))
	same(t, "B472 level 60", EncodeFail(InviteRefused), h(t, "02 0300"))
	same(t, "B473 leave", EncodeFail(ErrNotOut24T), h(t, "02 2168"))
	same(t, "B473 ban", EncodeFail(ErrNotBan24T), h(t, "02 2068"))
	same(t, "B477", EncodeOK(), h(t, "01"))
	same(t, "B478 empty", EncodeHonorList(nil), h(t, "01 00"))
	same(t, "B47D empty", EncodeMatchList(0, 0, nil), h(t, "01 00 00 00"))
	same(t, "B47A", EncodeMatchEntryOK(MatchEntry{ID: 1, CampID: 0x65, Flags: MatchApprentices, Title: "Join us"}, 0),
		h(t, "01 01000000 "+camp+" 01 0700"+hs("Join us")+" 00000000"))
	same(t, "B47A with graduates", EncodeMatchEntryOK(MatchEntry{ID: 1, CampID: 0x65, Flags: MatchAssistants, Title: "x"}, 3),
		h(t, "01 01000000 "+camp+" 02 0100 78 03000000"))
	same(t, "B47B", EncodeMatchModifyOK(MatchEntry{ID: 1, CampID: 0x65, Flags: MatchApprentices, Title: "x"}),
		h(t, "01 01000000 "+camp+" 01 0100 78"))
	same(t, "B47C", EncodeMatchDeleteOK(1), h(t, "01 01000000"))
	same(t, "B478 row", EncodeHonorList([]HonorRow{{Ranking: 1, Rank: 1, Guardian: "Ab", CurLevel: 70, MaxLevel: 70, GraduateCount: 3, GuildName: ""}}),
		h(t, "01 01 01000000 01 0200 4162 46 46 03000000 0000"))
	same(t, "B47D one row (page count 1, page 0)", EncodeMatchList(1, 0, []MatchRow{{
		Entry: MatchEntry{ID: 1, CampID: 0x65, Flags: 1, Title: "x", Registered: 0x6a000000}, Level: 70, MaxLevel: 70, RefObjID: 0x773,
		Guardian: "Ab", GraduateCount: 2, Rank: 5, Assistants: 1, Apprentices: 3}}),
		h(t, "01 01 00 01 01000000 "+camp+" 01 0100 78 0000006a 46 46 "+refObj+" 0200 4162 02000000 05 01000000 03000000"))
	same(t, "B47E", EncodeMatchJoinResult(MatchJoinNoReply), h(t, "01 02"))
	same(t, "B47E refused", EncodeMatchJoinResult(MatchJoinRefused), h(t, "01 00"))
	same(t, "B47E joined", EncodeMatchJoinResult(MatchJoinDone), h(t, "01 01"))
	// Round 866: the question to the guardian, the MEASURED layout with
	// synthetic values (job 0x123, requester key 0x101, entry 2, a level-30
	// requester).
	same(t, "747E down", EncodeMatchJoinAsk(MatchJoinAsk{JobID: 0x123, Requester: 0x101, Entry: 2, Level: 30, MaxLevel: 30,
		RefObjID: 0x773, Name: "Ab"}), h(t, "23010000 01010000 02000000 01010000 1e 1e "+refObj+" 0200 4162"))
}

func TestMatchJoinAnswerDecode866(t *testing.T) {
	job, req, ans, err := DecodeMatchJoinAnswer(h(t, "23010000 01010000 01"))
	if err != nil || job != 0x123 || req != 0x101 || ans != 1 {
		t.Errorf("347F yes: %x %x %d %v", job, req, ans, err)
	}
	if _, _, ans, err := DecodeMatchJoinAnswer(h(t, "23010000 01010000 00")); err != nil || ans != 0 {
		t.Errorf("347F no: %d %v", ans, err)
	}
	if _, _, _, err := DecodeMatchJoinAnswer(h(t, "23010000 0101")); err == nil {
		t.Error("347F short: no error")
	}
}

func TestWireDecoders(t *testing.T) {
	if v, err := DecodeU32(h(t, "d1000000")); err != nil || v != 0xd1 {
		t.Errorf("7470: %v %v", v, err)
	}
	if v, err := DecodeU32(h(t, nID)); err != nil || v != 0x102 {
		t.Errorf("7472: %x %v", v, err)
	}
	if v, err := DecodeName(h(t, "0900"+hs("Novice001"))); err != nil || v != "Novice001" {
		t.Errorf("7473: %q %v", v, err)
	}
	if a, b, err := DecodeNotice(h(t, notice)); err != nil || a != "Hello Academy" || b != "Test notice line" {
		t.Errorf("7477: %q %q %v", a, b, err)
	}
	// 0x747A {u32 0, u32 camp, u8 type, str title} (fixture 747a_register).
	e, err := DecodeMatchEntry(h(t, "00000000 "+camp+" 01 0700"+hs("Join us")))
	if err != nil || e.ID != 0 || e.CampID != 0x65 || e.Flags != 1 || e.Title != "Join us" {
		t.Errorf("747A: %+v %v", e, err)
	}
	if v, err := DecodeU32(h(t, "01000000")); err != nil || v != 1 {
		t.Errorf("747C: %v %v", v, err)
	}
	if v, err := DecodeU8(h(t, "00")); err != nil || v != 0 {
		t.Errorf("747D: %v %v", v, err)
	}
	if _, err := DecodeName(h(t, "0900 41")); err == nil {
		t.Error("a short name must fail")
	}
	if _, err := DecodeU32(nil); err == nil {
		t.Error("an empty u32 must fail")
	}
}
