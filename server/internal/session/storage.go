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
)

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
		default:
			return nil
		}
	}
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
	return sess.Send(&proto.Packet{Opcode: OpStorageListResult, Data: (&InventoryListResult{Slots: snaps}).Encode()})
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
