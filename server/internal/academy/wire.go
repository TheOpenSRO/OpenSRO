package academy

import (
	"encoding/binary"
	"errors"
	"time"
)

// Round 865 stage 2: the academy's wire, docs/protocol/academy.md sections
// 1, 4, 5 and 6. Every layout is READ from both binaries and MEASURED on the
// wire unless a comment says otherwise; wire_test.go holds the golden bytes.

// Replies (READ s:0x4e7250): 1 success, 2 failure + u16 code.
const (
	ResultOK   byte = 1
	ResultFail byte = 2
)

// The 0x3C80 push's sub-types (READ s:0x5dd4f0.., c:0x8a2110).
const (
	PushDisbanded byte = 0x01
	PushJoined    byte = 0x02
	PushRemoved   byte = 0x03
	PushGraduated byte = 0x04
	PushField     byte = 0x05
	PushNotice    byte = 0x07
	PushJoin      byte = 0x0a
	PushRank      byte = 0x0c
	PushPosition  byte = 0x0d
)

// Sub 5's fields (READ s:0x5dd580: 1, 2 and 6 a u8, 3 and 7 a u32, 5 a str).
const (
	FieldPlayState = 1
	FieldMaxLevel  = 2
	FieldHonor     = 3
	FieldName      = 5
	FieldCurLevel  = 6
	FieldRefObj    = 7
)

// Play states (MEASURED: a logout pushes 1, a world entry 0).
const (
	PlayOnline  byte = 0
	PlayOffline byte = 1
)

// WorldOpen is the world id a member in the open world carries (MEASURED
// 0x00010001).
const WorldOpen uint32 = 0x00010001

// Live is a member's run-time part of its entry (fields 11-17): what it was
// last known as. The zero Live is a member never placed: play state 0,
// world 0, no position, no name -- PlayState must be set explicitly.
type Live struct {
	PlayState byte
	World     uint32
	Region    uint16
	X, Y, Z   int16
	// Display is the character name, or its job alias in a job suit, while
	// its character is in the world; "" otherwise.
	Display string
}

// Unplaced is a member the server holds no character for yet: play state 1
// (MEASURED: the entry the other members get when someone joins, and an
// offline member never seen this run), world 0, no position, no name.
var Unplaced = Live{PlayState: PlayOffline}

// appendStr is a u16 length and the bytes, no NUL (READ s:0x426040).
func appendStr(out []byte, s string) []byte {
	out = binary.LittleEndian.AppendUint16(out, uint16(len(s)))
	return append(out, s...)
}

// AppendTS is a 16-byte TIMESTAMP_STRUCT of t in the server's local time
// (READ s:0x5e7400): i16 year, u16 month, day, hour, minute, second, u32
// fraction.
func AppendTS(out []byte, t time.Time) []byte {
	t = t.In(time.Local)
	for _, v := range []int{t.Year(), int(t.Month()), t.Day(), t.Hour(), t.Minute(), t.Second()} {
		out = binary.LittleEndian.AppendUint16(out, uint16(v))
	}
	return binary.LittleEndian.AppendUint32(out, uint32(t.Nanosecond()))
}

// AppendMember is a MemberEntry (READ s:0x5e3620, c:0x997900; section 5).
func AppendMember(out []byte, m Member, l Live) []byte {
	out = binary.LittleEndian.AppendUint32(out, uint32(m.CampID))
	out = binary.LittleEndian.AppendUint32(out, uint32(m.CharID))
	out = binary.LittleEndian.AppendUint32(out, uint32(m.RefObjID))
	out = appendStr(out, m.Name)
	out = append(out, byte(m.Class), byte(m.JoinedLevel))
	out = AppendTS(out, m.JoinDate)
	out = append(out, byte(m.CurLevel), byte(m.MaxLevel))
	out = binary.LittleEndian.AppendUint32(out, uint32(int32(m.Honor)))
	out = append(out, l.PlayState)
	out = binary.LittleEndian.AppendUint32(out, l.World)
	out = binary.LittleEndian.AppendUint16(out, l.Region)
	out = binary.LittleEndian.AppendUint16(out, uint16(l.X))
	out = binary.LittleEndian.AppendUint16(out, uint16(l.Y))
	out = binary.LittleEndian.AppendUint16(out, uint16(l.Z))
	return appendStr(out, l.Display)
}

// AppendCampInfo is a CampInfo (READ s:0x5e4230 mask 0xff): the camp, then
// the members in c's order with their Live from live.
func AppendCampInfo(out []byte, c *Camp, live func(Member) Live) []byte {
	out = binary.LittleEndian.AppendUint32(out, uint32(c.ID))
	out = AppendTS(out, c.CreationDate)
	out = append(out, byte(c.Rank))
	out = appendStr(out, c.NoticeTitle)
	out = appendStr(out, c.Notice)
	out = append(out, byte(len(c.Members)))
	for _, m := range c.Members {
		out = AppendMember(out, m, live(m))
	}
	return out
}

// EncodeOK is {1}.
func EncodeOK() []byte { return []byte{ResultOK} }

// EncodeFail is {2, u16 code}.
func EncodeFail(code uint16) []byte {
	return binary.LittleEndian.AppendUint16([]byte{ResultFail}, code)
}

// EncodeFailSeconds is {2, u16 code, u32 seconds}: 0xB470's 0x681c and
// 0xB471's 0x681d (READ s:0x519018..0x519068; MEASURED 0xB471).
func EncodeFailSeconds(code uint16, seconds uint32) []byte {
	return binary.LittleEndian.AppendUint32(EncodeFail(code), seconds)
}

// EncodeCampOK is {1, CampInfo}: 0xB470's success.
func EncodeCampOK(c *Camp, live func(Member) Live) []byte {
	return AppendCampInfo([]byte{ResultOK}, c, live)
}

// EncodeCampInfo is 0x3C81: the CampInfo with no leading byte.
func EncodeCampInfo(c *Camp, live func(Member) Live) []byte {
	return AppendCampInfo(nil, c, live)
}

// The 0x3C80 pushes.

func EncodeDisbanded() []byte { return []byte{PushDisbanded} }

func EncodeJoined(m Member, l Live) []byte { return AppendMember([]byte{PushJoined}, m, l) }

func EncodeRemoved(charID int64, reason int) []byte {
	return append(binary.LittleEndian.AppendUint32([]byte{PushRemoved}, uint32(charID)), byte(reason))
}

// EncodeGraduated is {04, u32 CharID, u8 kind}. kind is the graduation's self
// flag, 1 for 0x7475 and 0 for 0x7476 (INFERRED: the only byte the game
// server's job 4 carries, s:0x5def20, and the client prints the same text for
// both; which value is which is OPEN in the spec).
func EncodeGraduated(charID int64, kind byte) []byte {
	return append(binary.LittleEndian.AppendUint32([]byte{PushGraduated}, uint32(charID)), kind)
}

func fieldHead(charID int64, field byte) []byte {
	return append(binary.LittleEndian.AppendUint32([]byte{PushField}, uint32(charID)), field)
}

// EncodeFieldU8 is sub 5 for fields 1, 2 and 6.
func EncodeFieldU8(charID int64, field, v byte) []byte { return append(fieldHead(charID, field), v) }

// EncodeFieldU32 is sub 5 for fields 3 and 7.
func EncodeFieldU32(charID int64, field byte, v uint32) []byte {
	return binary.LittleEndian.AppendUint32(fieldHead(charID, field), v)
}

// EncodeFieldStr is sub 5 for field 5.
func EncodeFieldStr(charID int64, field byte, v string) []byte {
	return appendStr(fieldHead(charID, field), v)
}

func EncodeNotice(title, content string) []byte {
	return appendStr(appendStr([]byte{PushNotice}, title), content)
}

// EncodeJoinOK is {0a, 01, CampInfo}, EncodeJoinFail {0a, 02, u16 code}.
func EncodeJoinOK(c *Camp, live func(Member) Live) []byte {
	return AppendCampInfo([]byte{PushJoin, ResultOK}, c, live)
}

func EncodeJoinFail(code uint16) []byte {
	return binary.LittleEndian.AppendUint16([]byte{PushJoin, ResultFail}, code)
}

func EncodeRank(rank int) []byte { return []byte{PushRank, byte(rank)} }

// EncodePosition is {0d, u32 CharID, str display, u32 world, u16 region, i16
// x, y, z}.
func EncodePosition(charID int64, l Live) []byte {
	out := binary.LittleEndian.AppendUint32([]byte{PushPosition}, uint32(charID))
	out = appendStr(out, l.Display)
	out = binary.LittleEndian.AppendUint32(out, l.World)
	out = binary.LittleEndian.AppendUint16(out, l.Region)
	out = binary.LittleEndian.AppendUint16(out, uint16(l.X))
	out = binary.LittleEndian.AppendUint16(out, uint16(l.Y))
	return binary.LittleEndian.AppendUint16(out, uint16(l.Z))
}

// EncodeInvitation is 0x3080 kind 9 {09, u32 inviter unique id, str name}
// (READ s:0x46c94f; MEASURED).
func EncodeInvitation(inviterUID uint32, name string) []byte {
	return appendStr(binary.LittleEndian.AppendUint32([]byte{InviteKind}, inviterUID), name)
}

// HonorRow is one 0xB478 row (READ s:0x5dd29a..0x5dd2f4, c:0x993230).
type HonorRow struct {
	Ranking       uint32
	Rank          byte
	Guardian      string
	CurLevel      byte
	MaxLevel      byte
	GraduateCount uint32
	GuildName     string
}

// EncodeHonorList is 0xB478 {01, u8 n, n x HonorRow}.
func EncodeHonorList(rows []HonorRow) []byte {
	out := []byte{ResultOK, byte(len(rows))}
	for _, r := range rows {
		out = binary.LittleEndian.AppendUint32(out, r.Ranking)
		out = append(out, r.Rank)
		out = appendStr(out, r.Guardian)
		out = append(out, r.CurLevel, r.MaxLevel)
		out = binary.LittleEndian.AppendUint32(out, r.GraduateCount)
		out = appendStr(out, r.GuildName)
	}
	return out
}

// The matching board's records.

// MatchEntry is a board entry (READ s:0x470ef0: u32 entry id, u32 CampID, u8
// type, str title). The client sends a TYPE, 1 apprentices or 2 assistants
// (READ c:0x63c1c0, its two checkboxes exclusive); the shard tests it as bits
// (READ m:0x45a0dc / m:0x45a10a), so the two readings agree. Flags keeps the
// byte.
type MatchEntry struct {
	ID     uint32
	CampID uint32
	Flags  byte
	Title  string
}

const (
	MatchApprentices byte = 1
	MatchAssistants  byte = 2
)

// EncodeMatchEntryOK is 0xB47A's success {01, u32 entry, u32 camp, u8 type,
// str title, u32 graduates} (MEASURED with a camp of no graduates; the client
// stores the last u32 as its own entry's Graduate count, READ c:0x7738e0).
func EncodeMatchEntryOK(e MatchEntry, graduates uint32) []byte {
	return binary.LittleEndian.AppendUint32(EncodeMatchModifyOK(e), graduates)
}

// EncodeMatchModifyOK is 0xB47B's success {01, u32 entry, u32 camp, u8 type,
// str title} (READ c:0x890960).
func EncodeMatchModifyOK(e MatchEntry) []byte {
	out := binary.LittleEndian.AppendUint32([]byte{ResultOK}, e.ID)
	out = binary.LittleEndian.AppendUint32(out, e.CampID)
	out = append(out, e.Flags)
	return appendStr(out, e.Title)
}

// EncodeMatchDeleteOK is 0xB47C {01, u32 entry} (MEASURED).
func EncodeMatchDeleteOK(id uint32) []byte {
	return binary.LittleEndian.AppendUint32([]byte{ResultOK}, id)
}

// MatchRow is one 0xB47D row (READ c:0x890ab0).
type MatchRow struct {
	Entry         MatchEntry
	Level         byte
	MaxLevel      byte
	RefObjID      uint32
	Guardian      string
	GraduateCount uint32
	Rank          byte
	Assistants    uint32
	Apprentices   uint32
}

// EncodeMatchList is 0xB47D {01, u8 page count, u8 page, u8 n, rows} (READ
// c:0x7738c0 stores the two crossed: the second byte is the page index
// c:0x769550 passes to the page store c:0x775b00). A row is the entry record
// (the u32 after the entry id the camp id, the u32 after the title the
// graduate count, as 0xB47A's record: INFERRED, the client reads neither),
// then the guardian's levels, body, name, the graduate count, the
// honor rank and the assistant and apprentice counts.
func EncodeMatchList(pages, page byte, rows []MatchRow) []byte {
	out := []byte{ResultOK, pages, page, byte(len(rows))}
	for _, r := range rows {
		out = binary.LittleEndian.AppendUint32(out, r.Entry.ID)
		out = binary.LittleEndian.AppendUint32(out, r.Entry.CampID)
		out = append(out, r.Entry.Flags)
		out = appendStr(out, r.Entry.Title)
		out = binary.LittleEndian.AppendUint32(out, r.GraduateCount)
		out = append(out, r.Level, r.MaxLevel)
		out = binary.LittleEndian.AppendUint32(out, r.RefObjID)
		out = appendStr(out, r.Guardian)
		out = binary.LittleEndian.AppendUint32(out, r.GraduateCount)
		out = append(out, r.Rank)
		out = binary.LittleEndian.AppendUint32(out, r.Assistants)
		out = binary.LittleEndian.AppendUint32(out, r.Apprentices)
	}
	return out
}

// EncodeMatchJoinResult is 0xB47E {01, u8 s}: 1 joined, 0 refused, 2 no
// reply (READ c:0x892c50).
func EncodeMatchJoinResult(s byte) []byte { return []byte{ResultOK, s} }

// The matching join's results.
const (
	MatchJoinRefused byte = 0
	MatchJoinDone    byte = 1
	MatchJoinNoReply byte = 2
)

// Request decoders.

var errShort = errors.New("academy: short request")

// reader reads a request body.
type reader struct {
	b   []byte
	err error
}

func (r *reader) take(n int) []byte {
	if r.err != nil || len(r.b) < n {
		r.err = errShort
		return make([]byte, n)
	}
	out := r.b[:n]
	r.b = r.b[n:]
	return out
}

func (r *reader) u8() byte    { return r.take(1)[0] }
func (r *reader) u32() uint32 { return binary.LittleEndian.Uint32(r.take(4)) }
func (r *reader) str() string {
	n := int(binary.LittleEndian.Uint16(r.take(2)))
	return string(r.take(n))
}

// DecodeU32 is a request of one u32 (0x7470, 0x7472, 0x7478, 0x747C, 0x747E).
func DecodeU32(b []byte) (uint32, error) {
	r := &reader{b: b}
	v := r.u32()
	return v, r.err
}

// DecodeU8 is a request of one u8 (0x7475, 0x747D).
func DecodeU8(b []byte) (byte, error) {
	r := &reader{b: b}
	v := r.u8()
	return v, r.err
}

// DecodeName is a request of one str (0x7473, 0x7476).
func DecodeName(b []byte) (string, error) {
	r := &reader{b: b}
	v := r.str()
	return v, r.err
}

// DecodeNotice is 0x7477 {str title, str content}.
func DecodeNotice(b []byte) (title, content string, err error) {
	r := &reader{b: b}
	title, content = r.str(), r.str()
	return title, content, r.err
}

// DecodeMatchEntry is 0x747A / 0x747B {u32, u32, u8 flags, str title}: the
// first u32 is the entry id for a modify (any value for a register), the
// second any value (READ s:0x5e2cf0: the server overwrites both for a
// register).
func DecodeMatchEntry(b []byte) (MatchEntry, error) {
	r := &reader{b: b}
	e := MatchEntry{ID: r.u32(), CampID: r.u32(), Flags: r.u8(), Title: r.str()}
	return e, r.err
}
