package jobs

import (
	"encoding/binary"
	"errors"
)

// The job guild's messages (READ both sides; docs/protocol/jobs.md "The job
// guild's wire"). Every reply opens with u8 1 (ok) or u8 2 then a u16 code.
// Strings are retail's u16 length + bytes.
const (
	OpJoin          uint16 = 0x70E1 // u32 npc, u8 kind
	OpJoinResult    uint16 = 0xB0E1 // {1, u8 kind, u8 level, u32 exp} | {2, u16}
	OpWithdraw      uint16 = 0x70E2 // u32 npc
	OpWithdrawAck   uint16 = 0xB0E2 // {1} | {2, u16}
	OpAlias         uint16 = 0x70E3 // u32 npc, u8 op (0 check, 1 set), string
	OpAliasResult   uint16 = 0xB0E3 // {1, u8 op, string} | {2, u16, u8 op, string}
	OpRanking       uint16 = 0x70E4 // u32 npc, u8 kind, u8 type
	OpRankingResult uint16 = 0xB0E4 // {1, u8 kind, u8 type, table} | {2, u16, u8 kind, u8 type}
	OpReward        uint16 = 0x70E5 // u32 npc, u8 op (0 query, 1 collect)
	OpRewardResult  uint16 = 0xB0E5 // {1, u8 op, u32 gold} | {2, u16, u8 op}
	OpPrevJob       uint16 = 0x70E6 // u32 npc
	OpPrevJobResult uint16 = 0xB0E6 // {1, (u8 level, u32 exp) x trader, robber, hunter} | {2, u16}
	OpJobExp        uint16 = 0x30E6 // u8 kind, u8 level, u32 exp
)

// OpJobInfo is OURS (round 799): the job section of retail's 0x3013 (the
// character's own data, which OpenSRO's server does not send), READ
// CGObjPC::vslot_293 mode 1 (s:0x4e5b00) and the client's reader
// (c:0x9ddc40): the alias, then u8 kind, u8 level, u32 exp, u32
// contribution, u32 reward. Sent at world entry and after a reconnect.
const OpJobInfo uint16 = 0x00BC

// Alias rules (READ): the server's op-1 length test is 2..12 bytes
// (GObjPC_HandleAliasMsg_0e3), the client's 2..12 too (UI_ALIAS::FUN_0074ae10
// `iVar4 - 2U < 0xb`).
const (
	AliasMinLen = 2
	AliasMaxLen = 12
)

// ErrShort is a truncated request.
var ErrShort = errors.New("jobs: truncated request")

// Request is a decoded 0x70E1..0x70E6.
type Request struct {
	NPC   uint32
	Kind  Kind     // 0x70E1, 0x70E4
	Op    uint8    // 0x70E3, 0x70E5
	Type  RankType // 0x70E4
	Alias string   // 0x70E3
}

// DecodeRequest reads one job request by its opcode.
func DecodeRequest(op uint16, b []byte) (Request, error) {
	var r Request
	if len(b) < 4 {
		return r, ErrShort
	}
	r.NPC = binary.LittleEndian.Uint32(b)
	b = b[4:]
	switch op {
	case OpJoin:
		if len(b) < 1 {
			return r, ErrShort
		}
		r.Kind = Kind(b[0])
	case OpAlias:
		if len(b) < 3 {
			return r, ErrShort
		}
		r.Op = b[0]
		n := int(binary.LittleEndian.Uint16(b[1:]))
		if len(b) < 3+n {
			return r, ErrShort
		}
		r.Alias = string(b[3 : 3+n])
	case OpRanking:
		if len(b) < 2 {
			return r, ErrShort
		}
		r.Kind, r.Type = Kind(b[0]), RankType(b[1])
	case OpReward:
		if len(b) < 1 {
			return r, ErrShort
		}
		r.Op = b[0]
	}
	return r, nil
}

func appendString(out []byte, s string) []byte {
	out = binary.LittleEndian.AppendUint16(out, uint16(len(s)))
	return append(out, s...)
}

func appendU32(out []byte, v int64) []byte {
	return binary.LittleEndian.AppendUint32(out, uint32(v))
}

// Fail is {2, u16 code}: 0xB0E1, 0xB0E2, 0xB0E6.
func Fail(code uint16) []byte { return binary.LittleEndian.AppendUint16([]byte{2}, code) }

// JoinOK is 0xB0E1's success (READ s:0x4e7bd4..0x4e7c3b).
func JoinOK(kind Kind, level int, exp int64) []byte {
	return appendU32([]byte{1, byte(kind), byte(level)}, exp)
}

// WithdrawOK is 0xB0E2's success.
func WithdrawOK() []byte { return []byte{1} }

// AliasOK and AliasFail are 0xB0E3 (READ s:0x4e7dfa.., the string appended
// by s:0x426040 on every path, s:0x512540's refusals included).
func AliasOK(op uint8, alias string) []byte { return appendString([]byte{1, op}, alias) }
func AliasFail(code uint16, op uint8, alias string) []byte {
	return appendString(append(binary.LittleEndian.AppendUint16([]byte{2}, code), op), alias)
}

// RankingOK is 0xB0E4's success: {1, kind, type} then the table
// (s:0x512d6c..0x512dd3; the table is built by s:0x6ba260 / s:0x6ba570): u8
// count, then per row u8 rank, string alias, u8 level, and u32 exp + u8
// country (activity) or u32 contribution.
func RankingOK(kind Kind, t RankType, rows []RankRow) []byte {
	out := []byte{1, byte(kind), byte(t), byte(len(rows))}
	for _, r := range rows {
		out = append(out, byte(r.Rank))
		out = appendString(out, r.Alias)
		out = append(out, byte(r.Level))
		if t == RankActivity {
			out = appendU32(out, r.Exp)
			out = append(out, r.Country)
		} else {
			out = appendU32(out, r.Contribution)
		}
	}
	return out
}

// RankingFail is {2, u16, u8 kind, u8 type}.
func RankingFail(code uint16, kind Kind, t RankType) []byte {
	return append(binary.LittleEndian.AppendUint16([]byte{2}, code), byte(kind), byte(t))
}

// RewardOK and RewardFail are 0xB0E5.
func RewardOK(op uint8, gold int64) []byte { return appendU32([]byte{1, op}, gold) }
func RewardFail(code uint16, op uint8) []byte {
	return append(binary.LittleEndian.AppendUint16([]byte{2}, code), op)
}

// PrevJobOK is 0xB0E6's success (READ s:0x4e805a..0x4e80d7): the three
// (level, exp) pairs in _GetOldTrijobData's order, trader, robber, hunter.
func PrevJobOK(o OldJob) []byte {
	out := []byte{1}
	for i := 0; i < 3; i++ {
		out = append(out, byte(o.Level[i]))
		out = appendU32(out, o.Exp[i])
	}
	return out
}

// JobExp is 0x30E6 (READ s:0x4e2885..0x4e28d9).
func JobExp(r Record) []byte {
	return appendU32([]byte{byte(r.Kind), byte(r.Level)}, r.Exp)
}

// JobInfo is OpJobInfo's body.
func JobInfo(r Record) []byte {
	out := appendString(nil, r.Alias)
	out = append(out, byte(r.Kind), byte(r.Level))
	out = appendU32(out, r.Exp)
	out = appendU32(out, r.Contribution)
	return appendU32(out, r.Reward)
}
