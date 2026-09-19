package session

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"

	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/storage"
)

// Storage (warehouse) opcodes, our own protocol. Requires a prior OpLogin.
// The list result reuses InventoryListResult's wire shape (error + count +
// slots), since a warehouse is just another item container.
const (
	OpStorageList           uint16 = 0x0056 // client -> server
	OpStorageListResult     uint16 = 0x0057 // server -> client
	OpStorageDeposit        uint16 = 0x0058 // client -> server (bag -> warehouse)
	OpStorageDepositResult  uint16 = 0x0059 // server -> client
	OpStorageWithdraw       uint16 = 0x005A // client -> server (warehouse -> bag)
	OpStorageWithdrawResult uint16 = 0x005B // server -> client
	OpStorageGold           uint16 = 0x005C // client -> server (query/deposit/withdraw gold)
	OpStorageGoldResult     uint16 = 0x005D // server -> client
)

// Storage gold op codes (the Op field of StorageGoldRequest).
const (
	StorageGoldQuery    int32 = 0
	StorageGoldDeposit  int32 = 1
	StorageGoldWithdraw int32 = 2
)

// StorageGoldRequest queries or moves warehouse gold. Op is one of the
// StorageGold* constants; Amount is ignored for a query.
type StorageGoldRequest struct {
	CharacterName string
	Op            int32
	Amount        int64
}

func (r *StorageGoldRequest) Encode() []byte {
	out := encodeStrings(r.CharacterName)
	buf := make([]byte, 4)
	binary.LittleEndian.PutUint32(buf, uint32(r.Op))
	out = append(out, buf...)
	return append(out, encodeInt64(r.Amount)...)
}

func DecodeStorageGoldRequest(data []byte) (*StorageGoldRequest, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding StorageGoldRequest: %w", err)
	}
	if len(rest) < 4 {
		return nil, errors.New("session: decoding StorageGoldRequest: truncated op")
	}
	op := int32(binary.LittleEndian.Uint32(rest[0:4]))
	amount, _, err := decodeInt64(rest[4:])
	if err != nil {
		return nil, fmt.Errorf("session: decoding StorageGoldRequest: amount: %w", err)
	}
	return &StorageGoldRequest{CharacterName: fields[0], Op: op, Amount: amount}, nil
}

// StorageGoldResult reports the outcome plus both balances afterwards, so the
// window shows the truth (the server's own numbers).
type StorageGoldResult struct {
	OK      bool
	Reason  string
	Carried int64
	Stored  int64
}

func (r *StorageGoldResult) Encode() []byte {
	out := encodeOKReason(r.OK, r.Reason)
	out = append(out, encodeInt64(r.Carried)...)
	return append(out, encodeInt64(r.Stored)...)
}

func DecodeStorageGoldResult(data []byte) (*StorageGoldResult, error) {
	if len(data) < 1 {
		return nil, errors.New("session: decoding StorageGoldResult: empty payload")
	}
	ok := data[0] != 0
	fields, rest, err := decodeStringsPrefix(data[1:], 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding StorageGoldResult: %w", err)
	}
	r := &StorageGoldResult{OK: ok, Reason: reason(fields)}
	if len(rest) >= 16 {
		r.Carried, rest, _ = decodeInt64(rest)
		r.Stored, _, _ = decodeInt64(rest)
	}
	return r, nil
}

// StorageMoveRequest is the OpStorageDeposit / OpStorageWithdraw payload: move
// Quantity from Slot (a bag slot for deposit, a warehouse slot for withdraw).
type StorageMoveRequest struct {
	CharacterName string
	Slot          int32
	Quantity      int32
}

func (r *StorageMoveRequest) Encode() []byte {
	out := encodeStrings(r.CharacterName)
	buf := make([]byte, 8)
	binary.LittleEndian.PutUint32(buf[0:4], uint32(r.Slot))
	binary.LittleEndian.PutUint32(buf[4:8], uint32(r.Quantity))
	return append(out, buf...)
}

func DecodeStorageMoveRequest(data []byte) (*StorageMoveRequest, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding StorageMoveRequest: %w", err)
	}
	if len(rest) < 8 {
		return nil, errors.New("session: decoding StorageMoveRequest: truncated slot/quantity")
	}
	return &StorageMoveRequest{
		CharacterName: fields[0],
		Slot:          int32(binary.LittleEndian.Uint32(rest[0:4])),
		Quantity:      int32(binary.LittleEndian.Uint32(rest[4:8])),
	}, nil
}

// StorageMoveResult is the deposit/withdraw result payload.
type StorageMoveResult struct {
	OK     bool
	Reason string
}

func (r *StorageMoveResult) Encode() []byte { return encodeOKReason(r.OK, r.Reason) }

func DecodeStorageMoveResult(data []byte) (*StorageMoveResult, error) {
	ok, reason, err := decodeOKReason(data)
	if err != nil {
		return nil, fmt.Errorf("session: decoding StorageMoveResult: %w", err)
	}
	return &StorageMoveResult{OK: ok, Reason: reason}, nil
}

// StorageHandler returns a gateway.Handler for the warehouse ops, resolving
// the character against whichever account authenticated on the connection.
func StorageHandler(chars character.Store, svc *storage.Service) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		switch p.Opcode {
		case OpStorageList:
			return handleStorageList(ctx, sess, p, chars, svc)
		case OpStorageDeposit:
			return handleStorageMove(ctx, sess, p, chars, svc, true)
		case OpStorageWithdraw:
			return handleStorageMove(ctx, sess, p, chars, svc, false)
		case OpStorageGold:
			return handleStorageGold(ctx, sess, p, chars, svc)
		default:
			return nil
		}
	}
}

// StorageListResult is OpStorageListResult's payload: the warehouse as an
// InventoryListResult, then the container's CAPACITY as a trailing u16. The
// client needs it to page the authored 30-slot lattice (the original's
// CIFStorageRoom::Create builds 0x1e slot controls and addresses a warehouse
// slot as cell + page*0x1e -- client 0x6cd350 -- with the page count coming
// from the server). It follows the durability block, where an older client
// stops reading, so the list still decodes there.
type StorageListResult struct {
	InventoryListResult
	Capacity int
}

func (r *StorageListResult) Encode() []byte {
	out := r.InventoryListResult.Encode()
	return append(out, byte(r.Capacity), byte(r.Capacity>>8))
}

// DecodeStorageListResult reads the list and, when the sender was new enough
// to append it, the capacity (0 otherwise).
func DecodeStorageListResult(data []byte) (*StorageListResult, error) {
	inv, err := DecodeInventoryListResult(data)
	if err != nil {
		return nil, err
	}
	res := &StorageListResult{InventoryListResult: *inv}
	// Walk to the end of what DecodeInventoryListResult consumed: the error
	// string, the slots, then the durability block (2 + 12 per entry, when
	// present at all).
	off := 2 + len(inv.Error) + 2 + len(inv.Slots)*inventorySlotSnapshotSize
	if off+2 <= len(data) {
		off += 2 + 12*len(inv.Durabilities)
	}
	if off+2 <= len(data) {
		res.Capacity = int(binary.LittleEndian.Uint16(data[off:]))
	}
	return res, nil
}

func handleStorageList(ctx context.Context, sess *gateway.Session, p *proto.Packet, chars character.Store, svc *storage.Service) error {
	req, err := DecodeCharacterNameRequest(p.Data)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpStorageListResult, Data: (&InventoryListResult{Error: "malformed request"}).Encode()})
	}
	characterID, errStr := resolveCharacterID(ctx, sess, chars, req.Name)
	if errStr != "" {
		return sess.Send(&proto.Packet{Opcode: OpStorageListResult, Data: (&InventoryListResult{Error: errStr}).Encode()})
	}
	slots, err := svc.List(ctx, characterID)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpStorageListResult, Data: (&InventoryListResult{Error: "list failed"}).Encode()})
	}
	snaps := make([]InventorySlotSnapshot, len(slots))
	for i, sl := range slots {
		snaps[i] = InventorySlotSnapshot{Slot: sl.Index, ItemID: sl.ItemID, Quantity: sl.Quantity}
	}
	result := &StorageListResult{InventoryListResult: InventoryListResult{Slots: snaps}, Capacity: svc.Capacity()}
	return sess.Send(&proto.Packet{Opcode: OpStorageListResult, Data: result.Encode()})
}

func handleStorageMove(ctx context.Context, sess *gateway.Session, p *proto.Packet, chars character.Store, svc *storage.Service, deposit bool) error {
	resultOp := OpStorageWithdrawResult
	if deposit {
		resultOp = OpStorageDepositResult
	}
	req, err := DecodeStorageMoveRequest(p.Data)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: resultOp, Data: (&StorageMoveResult{Reason: "malformed request"}).Encode()})
	}
	characterID, errStr := resolveCharacterID(ctx, sess, chars, req.CharacterName)
	if errStr != "" {
		return sess.Send(&proto.Packet{Opcode: resultOp, Data: (&StorageMoveResult{Reason: errStr}).Encode()})
	}

	if deposit {
		err = svc.Deposit(ctx, characterID, int(req.Slot), int(req.Quantity))
	} else {
		err = svc.Withdraw(ctx, characterID, int(req.Slot), int(req.Quantity))
	}
	if err != nil {
		result := &StorageMoveResult{}
		switch {
		case errors.Is(err, storage.ErrSlotEmpty):
			result.Reason = "nothing there"
		case errors.Is(err, storage.ErrNothingToMove):
			result.Reason = "quantity must be positive"
		default:
			result.Reason = "move failed"
		}
		return sess.Send(&proto.Packet{Opcode: resultOp, Data: result.Encode()})
	}
	return sess.Send(&proto.Packet{Opcode: resultOp, Data: (&StorageMoveResult{OK: true}).Encode()})
}

func handleStorageGold(ctx context.Context, sess *gateway.Session, p *proto.Packet, chars character.Store, svc *storage.Service) error {
	req, err := DecodeStorageGoldRequest(p.Data)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpStorageGoldResult, Data: (&StorageGoldResult{Reason: "malformed request"}).Encode()})
	}
	characterID, errStr := resolveCharacterID(ctx, sess, chars, req.CharacterName)
	if errStr != "" {
		return sess.Send(&proto.Packet{Opcode: OpStorageGoldResult, Data: (&StorageGoldResult{Reason: errStr}).Encode()})
	}

	var bal storage.Balances
	switch req.Op {
	case StorageGoldDeposit:
		bal, err = svc.DepositGold(ctx, characterID, req.Amount)
	case StorageGoldWithdraw:
		bal, err = svc.WithdrawGold(ctx, characterID, req.Amount)
	default: // query
		bal, err = svc.GoldBalances(ctx, characterID)
	}
	if err != nil {
		result := &StorageGoldResult{}
		switch {
		case errors.Is(err, storage.ErrNothingToMove):
			result.Reason = "amount must be positive"
		case errors.Is(err, character.ErrInsufficientGold):
			result.Reason = "not enough gold"
		default:
			result.Reason = "gold move failed"
		}
		// Even on failure, report the current balances so the window stays right.
		if cur, e := svc.GoldBalances(ctx, characterID); e == nil {
			result.Carried, result.Stored = cur.Carried, cur.Stored
		}
		return sess.Send(&proto.Packet{Opcode: OpStorageGoldResult, Data: result.Encode()})
	}
	return sess.Send(&proto.Packet{Opcode: OpStorageGoldResult, Data: (&StorageGoldResult{OK: true, Carried: bal.Carried, Stored: bal.Stored}).Encode()})
}
