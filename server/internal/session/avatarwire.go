package session

// The avatar messages (round 789; docs/protocol/avatars.md). Every layout is
// READ (AVATAR_RESEARCH.md, AVATAR_ALCHEMY_RESEARCH.md) except the list's
// carrier, which is OURS; client/scripts/net/testdata/avatar_golden.json pins
// the bytes both sides encode and decode.

import (
	"encoding/binary"
	"errors"
	"fmt"
)

const (
	// ItemMoveAvatarToBag and ItemMoveBagToAvatar are the two avatar types of
	// 0x7034 (READ: the type table filled at s:0x50ce80 sends both to
	// s:0x526ed0, which asserts '#' or '$'; the client's c:0x7950b0).
	ItemMoveAvatarToBag byte = 0x23
	ItemMoveBagToAvatar byte = 0x24

	// OpAvatarList and OpAvatarListResult carry the avatar inventory to its
	// owner (OURS: OpenSRO has no 0x3013, so the client asks for it as it
	// asks for the bag and the worn list). The reply's payload is exactly
	// 0x3013's avatar section (READ c:0x9d9c39, s:0x4ba720 mode 1). 0x0044
	// and 0x0045 were free in server/ and client/scripts (grep, 2026-10-16).
	OpAvatarList       uint16 = 0x0044
	OpAvatarListResult uint16 = 0x0045

	// OpAvatarGrant and OpAvatarGrantResult are the blacksmith's grant
	// (READ: the client's sender c:0x822a30, the server's handler
	// gs:0x5079c0, the client's reader c:0x899f40).
	OpAvatarGrant       uint16 = 0x34A9
	OpAvatarGrantResult uint16 = 0x34AA

	// OpAvatarEnchant and OpAvatarEnchantResult are alchemy op 7's own pair
	// (READ gs:0x507910; the retail client has no sender of 0x34A7 and no
	// handler of 0x34A8).
	OpAvatarEnchant       uint16 = 0x34A7
	OpAvatarEnchantResult uint16 = 0x34A8

	// OpItemStateNotice is 0x3078, the owner's notice of an item's state;
	// kind 3 is a worn devil's spirit that expired: `u8 3, u8 avatar slot`
	// (READ s:0x4bbd60).
	OpItemStateNotice     uint16 = 0x3078
	ItemStateSpiritExpiry byte   = 3
)

// ErrAvatarMoveShape is a 0x23/0x24 body that is not exactly its two bytes.
var ErrAvatarMoveShape = errors.New("session: an avatar move is u8 type, u8 src, u8 dst")

// AvatarMove is a decoded 0x7034 of type 0x23 or 0x24, the slots as the wire
// has them: a bag slot is the bag index + 13, an avatar slot 0..4 (READ, the
// parser s:0x4d8bf0 index 15 reads `u8 -> +3, u8 -> +4`).
type AvatarMove struct {
	Type byte
	Src  byte
	Dst  byte
}

// DecodeAvatarMove reads one: the type and exactly two bytes.
func DecodeAvatarMove(b []byte) (*AvatarMove, error) {
	if len(b) != 3 || (b[0] != ItemMoveAvatarToBag && b[0] != ItemMoveBagToAvatar) {
		return nil, ErrAvatarMoveShape
	}
	return &AvatarMove{Type: b[0], Src: b[1], Dst: b[2]}, nil
}

// Encode is the client's form (c:0x7923a0).
func (m *AvatarMove) Encode() []byte { return []byte{m.Type, m.Src, m.Dst} }

// AvatarSubOp is one sub-operation of a reply: the attachment that came off
// with its dress (READ s:0x525c50; the type byte is the OUTER op's, s:0x4f80cc).
type AvatarSubOp struct {
	Type byte
	Src  byte
	Dst  byte
	Qty  uint16
}

// AvatarMoveResult is 0xB034 for an avatar move (READ s:0x4f76e0 index 21 =
// 0x4f804d; the client c:0x87eb50): success `u8 1, u8 type, u8 src, u8 dst,
// u16 qty, u8 n, n x (u8 type, u8 src, u8 dst, u16 qty)`; failure `u8 2, u16
// code`.
type AvatarMoveResult struct {
	OK   bool
	Code uint16
	Type byte
	Src  byte
	Dst  byte
	// Qty is op+6, which nothing in the 0x23/0x24 path writes: 0 (READ the
	// op's constructor s:0x42fae0).
	Qty  uint16
	Subs []AvatarSubOp
}

// Encode writes the reply.
func (r *AvatarMoveResult) Encode() []byte {
	if !r.OK {
		return EncodeItemFail(r.Code)
	}
	out := []byte{itemOpOK, r.Type, r.Src, r.Dst}
	out = binary.LittleEndian.AppendUint16(out, r.Qty)
	out = append(out, byte(len(r.Subs)))
	for _, s := range r.Subs {
		out = append(out, s.Type, s.Src, s.Dst)
		out = binary.LittleEndian.AppendUint16(out, s.Qty)
	}
	return out
}

// DecodeAvatarMoveResult reads one, as the client does; the bytes must be
// exactly the reply.
func DecodeAvatarMoveResult(b []byte) (*AvatarMoveResult, error) {
	if len(b) < 1 {
		return nil, errors.New("session: empty avatar move result")
	}
	switch b[0] {
	case itemOpFail:
		if len(b) != 3 {
			return nil, fmt.Errorf("session: avatar move refusal of %d bytes", len(b))
		}
		return &AvatarMoveResult{Code: binary.LittleEndian.Uint16(b[1:])}, nil
	case itemOpOK:
	default:
		return nil, fmt.Errorf("session: avatar move result %d", b[0])
	}
	if len(b) < 7 {
		return nil, errors.New("session: avatar move result truncated")
	}
	r := &AvatarMoveResult{OK: true, Type: b[1], Src: b[2], Dst: b[3], Qty: binary.LittleEndian.Uint16(b[4:])}
	n := int(b[6])
	rest := b[7:]
	if len(rest) != 5*n {
		return nil, fmt.Errorf("session: %d sub-ops in %d bytes", n, len(rest))
	}
	for i := 0; i < n; i++ {
		s := rest[5*i:]
		r.Subs = append(r.Subs, AvatarSubOp{Type: s[0], Src: s[1], Dst: s[2], Qty: binary.LittleEndian.Uint16(s[3:])})
	}
	if r.Subs == nil {
		r.Subs = []AvatarSubOp{}
	}
	return r, nil
}

// AvatarListItem is one entry of the avatar section: the storage slot and
// the item's record (the round-732 record; Slot of the ItemInfo is unused).
type AvatarListItem struct {
	Slot byte
	Info ItemInfo
}

// AvatarList is 0x3013's avatar section (READ c:0x9d9c39..0x9d9cfe, s:0x4ba720
// mode 1): `u8 size (5), u8 count, count x (u8 slot, item record)`. The
// client reads the size into the count's local and discards it (c:0x9d9c45).
type AvatarList struct {
	Size  byte
	Items []AvatarListItem
}

// Encode writes the section.
func (l *AvatarList) Encode() []byte {
	out := []byte{l.Size, byte(len(l.Items))}
	for _, it := range l.Items {
		out = append(out, it.Slot)
		out = AppendItemRecord(out, it.Info)
	}
	return out
}

// DecodeAvatarList reads a section; it must be exactly the bytes.
func DecodeAvatarList(b []byte) (*AvatarList, error) {
	if len(b) < 2 {
		return nil, errors.New("session: avatar list truncated")
	}
	l := &AvatarList{Size: b[0], Items: []AvatarListItem{}}
	n := int(b[1])
	rest := b[2:]
	for i := 0; i < n; i++ {
		if len(rest) < 1 {
			return nil, fmt.Errorf("session: avatar list entry %d: truncated", i)
		}
		slot := rest[0]
		ii, r, err := ReadItemRecord(rest[1:])
		if err != nil {
			return nil, fmt.Errorf("session: avatar list entry %d: %w", i, err)
		}
		l.Items = append(l.Items, AvatarListItem{Slot: slot, Info: ii})
		rest = r
	}
	if len(rest) != 0 {
		return nil, fmt.Errorf("session: avatar list: %d trailing bytes", len(rest))
	}
	return l, nil
}

// AvatarGrantRequest is 0x34A9 (READ c:0x822a30): `u8 slot (bag index + 13),
// u16 n, n x ASCII` -- the MATTR_ code of the chosen row.
type AvatarGrantRequest struct {
	Slot byte
	Code string
}

// DecodeAvatarGrantRequest reads one. The server's string reader clamps the
// length to what is left (READ FUN_00404b60); this decoder refuses a short
// string instead (the golden's), and the handler answers it as the clamped
// name would be answered: no such option.
func DecodeAvatarGrantRequest(b []byte) (*AvatarGrantRequest, error) {
	if len(b) < 3 {
		return nil, errors.New("session: avatar grant truncated")
	}
	n := int(binary.LittleEndian.Uint16(b[1:]))
	if len(b) != 3+n {
		return nil, fmt.Errorf("session: avatar grant: a %d-byte name in %d bytes", n, len(b)-3)
	}
	return &AvatarGrantRequest{Slot: b[0], Code: string(b[3:])}, nil
}

// Encode is the client's form.
func (r *AvatarGrantRequest) Encode() []byte {
	out := []byte{r.Slot}
	out = binary.LittleEndian.AppendUint16(out, uint16(len(r.Code)))
	return append(out, r.Code...)
}

// AvatarGrantResult is 0x34AA (READ gs:0x507b5c..0x507c12, c:0x899f40):
// success `u8 1, u8 flag (1), u8 slot, item record`; refusal `u8 2, u16
// code`.
type AvatarGrantResult struct {
	OK   bool
	Code uint16
	Flag byte
	Slot byte
	Item ItemInfo
}

// Encode writes the reply.
func (r *AvatarGrantResult) Encode() []byte {
	if !r.OK {
		return EncodeItemFail(r.Code)
	}
	return AppendItemRecord([]byte{itemOpOK, r.Flag, r.Slot}, r.Item)
}

// DecodeAvatarGrantResult reads one; it must be exactly the bytes. The
// client parses the record only when the flag is non-zero (c:0x899f40).
func DecodeAvatarGrantResult(b []byte) (*AvatarGrantResult, error) {
	if len(b) < 1 {
		return nil, errors.New("session: empty avatar grant result")
	}
	if b[0] == itemOpFail {
		if len(b) != 3 {
			return nil, fmt.Errorf("session: avatar grant refusal of %d bytes", len(b))
		}
		return &AvatarGrantResult{Code: binary.LittleEndian.Uint16(b[1:])}, nil
	}
	if b[0] != itemOpOK || len(b) < 3 {
		return nil, errors.New("session: avatar grant result malformed")
	}
	r := &AvatarGrantResult{OK: true, Flag: b[1], Slot: b[2]}
	if r.Flag == 0 {
		if len(b) != 3 {
			return nil, errors.New("session: avatar grant result: trailing bytes")
		}
		return r, nil
	}
	ii, rest, err := ReadItemRecord(b[3:])
	if err != nil {
		return nil, err
	}
	if len(rest) != 0 {
		return nil, fmt.Errorf("session: avatar grant result: %d trailing bytes", len(rest))
	}
	r.Item = ii
	return r, nil
}
