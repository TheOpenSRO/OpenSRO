package party

// The party and party-match messages, byte for byte (round 710). Every layout
// is docs/protocol/party_protocol.md's (round 709), READ in the client's
// parsers and senders and in the GameServer/ShardManager writers and readers;
// the golden fixtures in client/scripts/net/fixtures/party/ were built from
// those tables, independently of this file, and wire_test.go checks this file
// against them. The GDScript side (client/scripts/net/party.gd) is tested
// against the same fixtures.
//
// Integers are little-endian. A string is a u16 length and that many bytes
// (the client's NetProcessInInner::FUN_00873560).

import (
	"encoding/binary"
	"errors"
)

// The opcodes (READ, party_protocol.md "Opcode table"). C->S from the client,
// S->C to it.
const (
	OpCreate        uint16 = 0x7060 // C->S u32 target world id, u8 flags
	OpCreateAck     uint16 = 0xb060 // S->C to the inviter: [1][u32 own JID] or [2][u16 code]
	OpLeave         uint16 = 0x7061 // C->S empty
	OpInvite        uint16 = 0x7062 // C->S u32 target world id
	OpInviteAck     uint16 = 0xb062 // S->C to the inviter, errors only: [2][u16 code]
	OpKick          uint16 = 0x7063 // C->S u32 member JID
	OpInfo          uint16 = 0x3065 // S->C the full party, to a member who just joined
	OpJoinAck       uint16 = 0xb067 // S->C to the invitee: [1][u32 own JID] or [2][u16 code]
	OpInvitation    uint16 = 0x3080 // S->C the invitation; C->S its answer (same opcode both ways)
	OpEvent         uint16 = 0x3864 // S->C party events (kinds below)
	OpMatchRegister uint16 = 0x7069 // C->S party match: register ("Form party")
	OpMatchRegAck   uint16 = 0xb069
	OpMatchChange   uint16 = 0x706a // C->S party match: change entry
	OpMatchChgAck   uint16 = 0xb06a
	OpMatchDelete   uint16 = 0x706b // C->S u32 entry number
	OpMatchDelAck   uint16 = 0xb06b
	OpMatchList     uint16 = 0x706c // C->S u8 page
	OpMatchListAck  uint16 = 0xb06c
	OpMatchJoin     uint16 = 0x706d // C->S u32 entry; S->C the request shown to the leader
	OpMatchJoinAck  uint16 = 0xb06d // S->C to the requester
	OpMatchAnswer   uint16 = 0x306e // C->S the leader's answer
)

// The 0x3864 kinds (READ, c:0x886b10 and the GS writers).
const (
	EventDissolved byte = 1
	EventJoined    byte = 2
	EventLeft      byte = 3
	EventUpdate    byte = 6
	EventLeader    byte = 9
)

// The result byte of every ack.
const (
	ResultOK    byte = 1
	ResultError byte = 2
)

// The member record's mask bits (READ, writer GS 0x470ba0, reader c:0x883620,
// cross-binary exact).
const (
	MaskName     byte = 0x01 // name and RefObjID
	MaskLevel    byte = 0x02
	MaskHPMP     byte = 0x04
	MaskMastery  byte = 0x08
	MaskJID      byte = 0x10
	MaskPosition byte = 0x20 // region, x, y, z, world id
	MaskGuild    byte = 0x40
	MaskJob      byte = 0x80
	MaskFull     byte = 0xff
)

// ErrShort is returned when a payload ends before its layout does.
var ErrShort = errors.New("party: payload too short")

// Record is the party member record, shared by 0x3065, 0x3864 kinds 2 and 6,
// and the 0x706d request. Only the fields Mask names are written or read, in
// the record's own order: JID, name+model, level, HP/MP, position, guild, job,
// masteries.
type Record struct {
	Mask     byte
	JID      uint32
	Name     string
	RefObjID uint32
	Level    uint8
	// HPMP is the tenths byte: low nibble HP, high nibble MP (HPMPFull and
	// HPMPUpdate compute it).
	HPMP   uint8
	Region uint16
	// X, Y, Z are the position truncated to integers (ftol of pc+0x88/+0x8c/
	// +0x90). A field region (bit 15 clear) carries each as a u16; a dungeon
	// region (bit 15 set) as a u32. Decoding a u16 zero-extends it, as the
	// client does.
	X, Y, Z  int32
	WorldID  uint32
	Guild    string
	Job      uint8
	Mastery1 uint32
	Mastery2 uint32
}

// AppendRecord writes r after b.
func AppendRecord(b []byte, r *Record) []byte {
	m := r.Mask
	b = append(b, m)
	if m&MaskJID != 0 {
		b = appendU32(b, r.JID)
	}
	if m&MaskName != 0 {
		b = appendStr(b, r.Name)
		b = appendU32(b, r.RefObjID)
	}
	if m&MaskLevel != 0 {
		b = append(b, r.Level)
	}
	if m&MaskHPMP != 0 {
		b = append(b, r.HPMP)
	}
	if m&MaskPosition != 0 {
		b = appendU16(b, r.Region)
		if r.Region&0x8000 != 0 {
			b = appendU32(b, uint32(r.X))
			b = appendU32(b, uint32(r.Y))
			b = appendU32(b, uint32(r.Z))
		} else {
			b = appendU16(b, uint16(r.X))
			b = appendU16(b, uint16(r.Y))
			b = appendU16(b, uint16(r.Z))
		}
		b = appendU32(b, r.WorldID)
	}
	if m&MaskGuild != 0 {
		b = appendStr(b, r.Guild)
	}
	if m&MaskJob != 0 {
		b = append(b, r.Job)
	}
	if m&MaskMastery != 0 {
		b = appendU32(b, r.Mastery1)
		b = appendU32(b, r.Mastery2)
	}
	return b
}

// ReadRecord reads one record off the front of b.
func ReadRecord(b []byte) (Record, []byte, error) {
	var r Record
	rd := reader{b: b}
	r.Mask = rd.u8()
	m := r.Mask
	if m&MaskJID != 0 {
		r.JID = rd.u32()
	}
	if m&MaskName != 0 {
		r.Name = rd.str()
		r.RefObjID = rd.u32()
	}
	if m&MaskLevel != 0 {
		r.Level = rd.u8()
	}
	if m&MaskHPMP != 0 {
		r.HPMP = rd.u8()
	}
	if m&MaskPosition != 0 {
		r.Region = rd.u16()
		if r.Region&0x8000 != 0 {
			r.X, r.Y, r.Z = int32(rd.u32()), int32(rd.u32()), int32(rd.u32())
		} else {
			r.X, r.Y, r.Z = int32(rd.u16()), int32(rd.u16()), int32(rd.u16())
		}
		r.WorldID = rd.u32()
	}
	if m&MaskGuild != 0 {
		r.Guild = rd.str()
	}
	if m&MaskJob != 0 {
		r.Job = rd.u8()
	}
	if m&MaskMastery != 0 {
		r.Mastery1 = rd.u32()
		r.Mastery2 = rd.u32()
	}
	if rd.err != nil {
		return Record{}, nil, rd.err
	}
	return r, rd.b, nil
}

// HPMPFull is the tenths byte of a full record (READ, GS 0x5baf96..0x5bb029):
// each nibble is trunc(cur / max x 10), the FPU set to chop, the 10.0 the
// double at 0xb45c60. A max of 0 gives 0 (OURS: the engine would divide by
// zero).
func HPMPFull(hp, maxHP, mp, maxMP int) uint8 {
	return uint8(tenthFull(mp, maxMP)<<4) | uint8(tenthFull(hp, maxHP)&0xf)
}

func tenthFull(cur, max int) int {
	if max <= 0 {
		return 0
	}
	return int(float64(cur) / float64(max) * 10.0)
}

// HPMPUpdate is the tenths byte an update computes, and whether it differs
// from prev, the byte last sent (READ, GS CGObjPC::FUN_005bb0c0,
// 0x5bb0ea..0x5bb1c8). It is NOT the full record's formula:
//
//   - HP: 0 when HP is 0, else 1 - ftol(r x -10.0), r = float32(HP / MaxHP)
//     and -10.0 the double at 0xb45f78, so 1 + trunc(10 r): 1..11, 11 at full
//     HP.
//   - MP: ftol(float32(MP / MaxMP) x 10.0), 0..10.
//
// The byte is rewritten, and the update sent, only when either nibble
// changed. ftol truncates toward zero (0x9fbb40, cvttsd2si). A max of 0 gives
// a nibble of 0 (OURS).
func HPMPUpdate(prev uint8, hp, maxHP, mp, maxMP int) (uint8, bool) {
	hpStep := 0
	if hp != 0 && maxHP > 0 {
		r := float32(float64(hp) / float64(maxHP))
		hpStep = 1 - int(float64(r)*-10.0)
	}
	mpStep := 0
	if maxMP > 0 {
		r := float32(float64(mp) / float64(maxMP))
		mpStep = int(float64(r) * 10.0)
	}
	if int(prev&0xf) == hpStep && int(prev>>4) == mpStep {
		return prev, false
	}
	return uint8(mpStep<<4) | uint8(hpStep&0xf), true
}

// EncodeCreate is the 0x7060 request.
func EncodeCreate(target uint32, flags Flags) []byte {
	return append(appendU32(nil, target), byte(flags))
}

// DecodeCreate reads a 0x7060 request.
func DecodeCreate(b []byte) (target uint32, flags Flags, err error) {
	rd := reader{b: b}
	target = rd.u32()
	flags = Flags(rd.u8())
	return target, flags, rd.err
}

// EncodeTarget is a request carrying one u32: 0x7062's target, 0x7063's
// member JID.
func EncodeTarget(id uint32) []byte { return appendU32(nil, id) }

// DecodeTarget reads a one-u32 request.
func DecodeTarget(b []byte) (uint32, error) {
	rd := reader{b: b}
	v := rd.u32()
	return v, rd.err
}

// EncodeOKID is [1][u32]: the 0xb060/0xb067 success with the receiver's own
// JID, and the 0xb06b success with the entry number.
func EncodeOKID(id uint32) []byte { return appendU32([]byte{ResultOK}, id) }

// EncodeRefusal is [2][u16 code] (GS Msg_SendTwoFieldReply 0x4e7250).
func EncodeRefusal(code uint16) []byte { return appendU16([]byte{ResultError}, code) }

// Ack is a decoded [1][...] / [2][u16 code] reply.
type Ack struct {
	OK   bool
	Code uint16
	// ID is the u32 after a [1] of 0xb060/0xb067/0xb06b.
	ID uint32
}

// DecodeIDAck reads a 0xb060/0xb062/0xb067/0xb06b reply.
func DecodeIDAck(b []byte) (Ack, error) {
	rd := reader{b: b}
	var a Ack
	switch rd.u8() {
	case ResultOK:
		a.OK = true
		a.ID = rd.u32()
	case ResultError:
		a.Code = rd.u16()
	default:
		if rd.err == nil {
			return Ack{}, errors.New("party: unknown result byte")
		}
	}
	return a, rd.err
}

// EncodeInvitation is the 0x3080 the invitee receives: kind, the inviter's
// world id, the flags (READ, c:0x88aa60; GS 0x46c8e0).
func EncodeInvitation(kind InviteKind, inviter uint32, flags Flags) []byte {
	b := appendU32([]byte{byte(kind)}, inviter)
	return append(b, byte(flags))
}

// DecodeInvitation reads the S->C 0x3080 for kinds 2 and 3.
func DecodeInvitation(b []byte) (kind InviteKind, inviter uint32, flags Flags, err error) {
	rd := reader{b: b}
	kind = InviteKind(rd.u8())
	inviter = rd.u32()
	flags = Flags(rd.u8())
	return kind, inviter, flags, rd.err
}

// EncodeAnswerYes is the client's "yes": [1][1] (READ, c:0x81cc30/0x81ce00).
func EncodeAnswerYes() []byte { return []byte{1, 1} }

// EncodeAnswerNo is the client's "no": [2][u16 code], 0x2c0c for a formation,
// 0x2c17 for a join (READ, c:0x81cd20/0x81cef0).
func EncodeAnswerNo(code uint16) []byte { return appendU16([]byte{2}, code) }

// DecodeAnswer reads the C->S 0x3080: only the first byte decides (READ, GS
// trs_wait_response::vslot_002 reads one u8 at 0x46cbef and hands it to
// 0x5be350 in AL). Accepting on 1 alone is OURS for a formation: this
// GameServer accepts a join on `cmp bl,1; jne` (0x5be39f, READ) but a
// formation on `test bl,bl; jne` (0x5be41c), so any non-zero byte -- the stock
// client's "no", [2][0x2c0c] (c:0x81cd9b) -- would form the party. That is the
// private-server build's bug or a 0 the client never sends; copying it would
// turn every "No" into a "Yes", so OpenSRO declines everything but 1 for both
// kinds.
func DecodeAnswer(b []byte) (accept bool, err error) {
	if len(b) < 1 {
		return false, ErrShort
	}
	return b[0] == 1, nil
}

// Info is the 0x3065 full party.
type Info struct {
	PartyID uint32
	Leader  uint32
	Flags   Flags
	Members []Record
}

// EncodeInfo writes 0x3065 with mask 0xff: mask, party id, leader JID, flags,
// count, the members' full records (READ, GS 0x5bc650; c:0x883cc0 reads the
// party id before it tests the mask, which agrees because the mask is always
// 0xff).
func EncodeInfo(in *Info) []byte {
	b := []byte{0xff}
	b = appendU32(b, in.PartyID)
	b = appendU32(b, in.Leader)
	b = append(b, byte(in.Flags))
	b = append(b, byte(len(in.Members)))
	for i := range in.Members {
		b = AppendRecord(b, &in.Members[i])
	}
	return b
}

// DecodeInfo reads 0x3065 the way the client does.
func DecodeInfo(b []byte) (*Info, error) {
	rd := reader{b: b}
	mask := rd.u8()
	in := &Info{PartyID: rd.u32()}
	if mask&1 != 0 {
		in.Leader = rd.u32()
		in.Flags = Flags(rd.u8())
	}
	if rd.err != nil {
		return nil, rd.err
	}
	if mask&2 != 0 {
		n := int(rd.u8())
		if rd.err != nil {
			return nil, rd.err
		}
		rest := rd.b
		for i := 0; i < n; i++ {
			r, more, err := ReadRecord(rest)
			if err != nil {
				return nil, err
			}
			in.Members = append(in.Members, r)
			rest = more
		}
	}
	return in, nil
}

// EncodeDissolved is 0x3864 kind 1 with its code (0x2c0b from the ShardManager's
// dissolution; the client reads and ignores it).
func EncodeDissolved(code uint16) []byte { return appendU16([]byte{EventDissolved}, code) }

// EncodeJoined is 0x3864 kind 2: the joiner's full record.
func EncodeJoined(r *Record) []byte { return AppendRecord([]byte{EventJoined}, r) }

// EncodeLeft is 0x3864 kind 3: the member's JID and the reason.
func EncodeLeft(jid uint32, reason uint8) []byte {
	return append(appendU32([]byte{EventLeft}, jid), reason)
}

// EncodeUpdate is 0x3864 kind 6: the member's JID, then a record carrying only
// the changed fields (an update never carries MaskJID or MaskJob).
func EncodeUpdate(jid uint32, r *Record) []byte {
	return AppendRecord(appendU32([]byte{EventUpdate}, jid), r)
}

// EncodeLeader is 0x3864 kind 9: the new leader's JID.
func EncodeLeader(jid uint32) []byte { return appendU32([]byte{EventLeader}, jid) }

// Event is a decoded 0x3864.
type Event struct {
	Kind   byte
	Code   uint16 // kind 1
	JID    uint32 // kinds 3, 6, 9
	Reason uint8  // kind 3
	Record Record // kinds 2, 6
}

// DecodeEvent reads a 0x3864.
func DecodeEvent(b []byte) (Event, error) {
	rd := reader{b: b}
	e := Event{Kind: rd.u8()}
	if rd.err != nil {
		return e, rd.err
	}
	switch e.Kind {
	case EventDissolved:
		e.Code = rd.u16()
	case EventJoined:
		r, _, err := ReadRecord(rd.b)
		if err != nil {
			return e, err
		}
		e.Record = r
	case EventLeft:
		e.JID = rd.u32()
		e.Reason = rd.u8()
	case EventUpdate:
		e.JID = rd.u32()
		if rd.err != nil {
			return e, rd.err
		}
		r, _, err := ReadRecord(rd.b)
		if err != nil {
			return e, err
		}
		e.Record = r
	case EventLeader:
		e.JID = rd.u32()
	default:
		return e, errors.New("party: unknown 0x3864 kind")
	}
	return e, rd.err
}

// Entry is the party-match entry of 0x7069/0x706a and their successes
// 0xb069/0xb06a (READ, c:0x823c20 = GS 0x470e70; GS 0x5c2e10 = c:0x883780).
type Entry struct {
	Number   uint32
	PartyID  uint32
	Flags    Flags
	Purpose  uint8
	MinLevel uint8
	MaxLevel uint8
	Title    string
}

// AppendEntry writes e after b.
func AppendEntry(b []byte, e *Entry) []byte {
	b = appendU32(b, e.Number)
	b = appendU32(b, e.PartyID)
	b = append(b, byte(e.Flags), e.Purpose, e.MinLevel, e.MaxLevel)
	return appendStr(b, e.Title)
}

// ReadEntry reads one entry off the front of b.
func ReadEntry(b []byte) (Entry, []byte, error) {
	rd := reader{b: b}
	e := Entry{Number: rd.u32(), PartyID: rd.u32(), Flags: Flags(rd.u8()), Purpose: rd.u8(), MinLevel: rd.u8(), MaxLevel: rd.u8()}
	e.Title = rd.str()
	return e, rd.b, rd.err
}

// ListEntry is one row of the 0xb06c list page (READ, SM 0x44f640 and
// c:0x8841f0).
type ListEntry struct {
	Number uint32
	// Time is the second u32, the entry's registration or change time
	// (SM _time32 into entry+0x30; INFERRED a timestamp, its client use OPEN).
	Time     uint32
	Name     string
	Race     uint8
	Count    uint8
	Flags    Flags
	Purpose  uint8
	MinLevel uint8
	MaxLevel uint8
	Title    string
}

// AppendListEntry writes e after b.
func AppendListEntry(b []byte, e *ListEntry) []byte {
	b = appendU32(b, e.Number)
	b = appendU32(b, e.Time)
	b = appendStr(b, e.Name)
	b = append(b, e.Race, e.Count, byte(e.Flags), e.Purpose, e.MinLevel, e.MaxLevel)
	return appendStr(b, e.Title)
}

// ReadListEntry reads one list row off the front of b.
func ReadListEntry(b []byte) (ListEntry, []byte, error) {
	rd := reader{b: b}
	e := ListEntry{Number: rd.u32(), Time: rd.u32()}
	e.Name = rd.str()
	e.Race, e.Count, e.Flags, e.Purpose, e.MinLevel, e.MaxLevel = rd.u8(), rd.u8(), Flags(rd.u8()), rd.u8(), rd.u8(), rd.u8()
	e.Title = rd.str()
	return e, rd.b, rd.err
}

// EncodeListPage is the 0xb06c success: [1][u8 page count][u8 page index]
// [u8 n] and n rows.
func EncodeListPage(pages, index uint8, rows []ListEntry) []byte {
	b := []byte{ResultOK, pages, index, byte(len(rows))}
	for i := range rows {
		b = AppendListEntry(b, &rows[i])
	}
	return b
}

// JoinRequest is the S->C 0x706d the entry's leader receives (READ, c:0x884660
// reads 4, 4, 4, 4, 4, 1, record; GS 0x5c2db0 writes the last five, SM
// 0x422230 prepends the job id and the requester's JID).
type JoinRequest struct {
	JobID     uint32
	Requester uint32
	Entry     uint32
	Mastery1  uint32
	Mastery2  uint32
	Job       uint8
	Record    Record // mask 0xff
}

// EncodeJoinRequest writes the S->C 0x706d.
func EncodeJoinRequest(j *JoinRequest) []byte {
	b := appendU32(nil, j.JobID)
	b = appendU32(b, j.Requester)
	b = appendU32(b, j.Entry)
	b = appendU32(b, j.Mastery1)
	b = appendU32(b, j.Mastery2)
	b = append(b, j.Job)
	return AppendRecord(b, &j.Record)
}

// DecodeJoinRequest reads the S->C 0x706d.
func DecodeJoinRequest(b []byte) (*JoinRequest, error) {
	rd := reader{b: b}
	j := &JoinRequest{JobID: rd.u32(), Requester: rd.u32(), Entry: rd.u32(), Mastery1: rd.u32(), Mastery2: rd.u32(), Job: rd.u8()}
	if rd.err != nil {
		return nil, rd.err
	}
	r, _, err := ReadRecord(rd.b)
	if err != nil {
		return nil, err
	}
	j.Record = r
	return j, nil
}

// The leader's answers to a join request (READ, c:0x73fc68 pushes 1,
// c:0x73fca6 0, c:0x73fb8d 2 when the popup's 10 s timer fires).
const (
	AnswerCancel  uint8 = 0
	AnswerConfirm uint8 = 1
	AnswerClosed  uint8 = 2
)

// EncodeJoinAnswer is the 0x306e: the job id, the requester's JID, the answer.
func EncodeJoinAnswer(jobID, requester uint32, answer uint8) []byte {
	return append(appendU32(appendU32(nil, jobID), requester), answer)
}

// DecodeJoinAnswer reads a 0x306e.
func DecodeJoinAnswer(b []byte) (jobID, requester uint32, answer uint8, err error) {
	rd := reader{b: b}
	jobID, requester, answer = rd.u32(), rd.u32(), rd.u8()
	return jobID, requester, answer, rd.err
}

// The 0xb06d success outcomes (READ, c:0x8847d0).
const (
	JoinRefused uint16 = 0
	JoinJoined  uint16 = 1
	JoinNoReply uint16 = 2
)

// EncodeJoinResult is the 0xb06d success: [1][u16 outcome].
func EncodeJoinResult(outcome uint16) []byte { return appendU16([]byte{ResultOK}, outcome) }

func appendU16(b []byte, v uint16) []byte { return binary.LittleEndian.AppendUint16(b, v) }
func appendU32(b []byte, v uint32) []byte { return binary.LittleEndian.AppendUint32(b, v) }
func appendStr(b []byte, s string) []byte {
	b = appendU16(b, uint16(len(s)))
	return append(b, s...)
}

type reader struct {
	b   []byte
	err error
}

func (r *reader) need(n int) bool {
	if r.err != nil {
		return false
	}
	if len(r.b) < n {
		r.err = ErrShort
		return false
	}
	return true
}

func (r *reader) u8() uint8 {
	if !r.need(1) {
		return 0
	}
	v := r.b[0]
	r.b = r.b[1:]
	return v
}

func (r *reader) u16() uint16 {
	if !r.need(2) {
		return 0
	}
	v := binary.LittleEndian.Uint16(r.b)
	r.b = r.b[2:]
	return v
}

func (r *reader) u32() uint32 {
	if !r.need(4) {
		return 0
	}
	v := binary.LittleEndian.Uint32(r.b)
	r.b = r.b[4:]
	return v
}

func (r *reader) str() string {
	n := int(r.u16())
	if !r.need(n) {
		return ""
	}
	s := string(r.b[:n])
	r.b = r.b[n:]
	return s
}
