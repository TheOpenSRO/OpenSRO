package session

// The account PIN, "Character Lock" (round 788, lane P). The feature is OURS
// throughout -- the retail game has none (charlock's package comment) -- and
// so are these opcodes, their payloads and the gate. docs/protocol/pin.md is
// the reference.

import (
	"context"
	"encoding/binary"
	"errors"
	"log/slog"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/charlock"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
)

// The PIN opcodes (OURS). 0x0118..0x011F were free on 2026-10-15 (the
// highest ops in server/internal and client/scripts/net were the auto potion
// pair, 0x0116 and 0x0117); they are left to round 788's other lanes, which
// were adding messages at the same time, and the PIN takes 0x0120..0x0124.
// The client pins them (client/scripts/net/character_lock_net.gd).
const (
	OpCharLockStatus uint16 = 0x0120 // client -> server: str device token ("" for none)
	OpCharLockReply  uint16 = 0x0121 // server -> client: u8 op, u8 code, u8 flags, u8 attempts left, u32 seconds locked
	OpCharLockCreate uint16 = 0x0122 // client -> server: str PIN
	OpCharLockVerify uint16 = 0x0123 // client -> server: str PIN, u8 remember, str device token
	OpCharLockRemove uint16 = 0x0124 // client -> server: str PIN
)

// The reply's op byte: which request it answers.
const (
	CharLockOpStatus uint8 = 0
	CharLockOpCreate uint8 = 1
	CharLockOpVerify uint8 = 2
	CharLockOpRemove uint8 = 3
)

// The reply's flags byte.
const (
	CharLockFlagHasPin   uint8 = 1
	CharLockFlagRequired uint8 = 2
	CharLockFlagUnlocked uint8 = 4
	CharLockFlagLocked   uint8 = 8
)

// CharLockReply is a 0x0121 payload.
type CharLockReply struct {
	Op           uint8
	Code         charlock.Code
	Flags        uint8
	AttemptsLeft uint8
	// LockedSeconds is what is left of the lock, rounded up; 0 for none. A
	// duration, not a time, so the two clocks need not agree.
	LockedSeconds uint32
}

func (r *CharLockReply) Encode() []byte {
	out := []byte{r.Op, uint8(r.Code), r.Flags, r.AttemptsLeft}
	return binary.LittleEndian.AppendUint32(out, r.LockedSeconds)
}

func DecodeCharLockReply(data []byte) (*CharLockReply, error) {
	if len(data) < 8 {
		return nil, errors.New("session: character lock reply: truncated")
	}
	return &CharLockReply{Op: data[0], Code: charlock.Code(data[1]), Flags: data[2], AttemptsLeft: data[3],
		LockedSeconds: binary.LittleEndian.Uint32(data[4:8])}, nil
}

// CharLockRequest is a 0x0120, 0x0122, 0x0123 or 0x0124 payload; each opcode
// carries only its own fields (see the constants).
type CharLockRequest struct {
	Pin      string
	Remember bool
	Token    string
}

// DecodeCharLockRequest reads op's fields. A status request with no payload
// at all is one with no token.
func DecodeCharLockRequest(op uint16, data []byte) (*CharLockRequest, error) {
	rd := lobbyReader{b: data}
	r := &CharLockRequest{}
	switch op {
	case OpCharLockStatus:
		if len(data) == 0 {
			return r, nil
		}
		r.Token = rd.str()
	case OpCharLockVerify:
		r.Pin = rd.str()
		r.Remember = rd.u8() != 0
		r.Token = rd.str()
	default:
		r.Pin = rd.str()
	}
	if rd.err != nil {
		return nil, rd.err
	}
	return r, nil
}

// charLockUnlockedKey holds the account id whose PIN this session has passed
// (keyed by account, so a second login on the connection starts locked).
const charLockUnlockedKey = "session.charlock_unlocked"

func charLockUnlocked(sess *gateway.Session, accountID int64) bool {
	v, ok := sess.Get(charLockUnlockedKey)
	id, isID := v.(int64)
	return ok && isID && id == accountID
}

func setCharLockUnlocked(sess *gateway.Session, accountID int64) {
	sess.Set(charLockUnlockedKey, accountID)
}

// CharacterLockGate answers the PIN opcodes and holds the lobby behind the
// PIN: Start (0x7001), the older OpEnterWorld (0x0020, the same way into the
// world), and 0x7007's delete (3) and restore (5) are refused, before next
// sees them, unless the session has unlocked the PIN -- or the account has
// none and the server does not require one (charlock.Service.Allows).
// Everything else goes to next. svc nil: no lock at all, every packet to next.
//
// The refusal (OURS): Start 0xB001 and delete/restore 0xB007 with 0x40e, the
// READ code for "an operation is pending" (ShardManager's Start refuses with
// it, charselect.md section 5) -- the PIN is that pending operation, and no
// retail code says more: the retail client shows "Failed to connect to
// server." for it. OpEnterWorld gets its own reason text. Our client never
// sees either: it asks for the status and the PIN first. A retail client has
// no PIN window, so on an account with a PIN it can list its characters and
// create one, but not start, delete or restore (docs/protocol/pin.md).
func CharacterLockGate(svc *charlock.Service, logger *slog.Logger, next gateway.Handler) gateway.Handler {
	if logger == nil {
		logger = slog.Default()
	}
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		if svc == nil {
			return next(ctx, sess, p)
		}
		switch p.Opcode {
		case OpCharLockStatus, OpCharLockCreate, OpCharLockVerify, OpCharLockRemove:
			return handleCharLock(ctx, svc, logger, sess, p)
		case OpStart, OpEnterWorld:
			if refused, err := charLockRefuses(ctx, svc, logger, sess, "start"); refused || err != nil {
				if err != nil {
					return err
				}
				if p.Opcode == OpStart {
					return sess.Send(&proto.Packet{Opcode: OpStartResult, Data: (&StartResult{Code: LobbyErrBusy}).Encode()})
				}
				return sess.Send(&proto.Packet{Opcode: OpEnterWorldResult,
					Data: (&EnterWorldResult{Reason: "the character lock is not open: enter the PIN first"}).Encode()})
			}
		case OpLobby:
			if len(p.Data) > 0 && (p.Data[0] == LobbyDelete || p.Data[0] == LobbyRestore) {
				what := "delete"
				if p.Data[0] == LobbyRestore {
					what = "restore"
				}
				if refused, err := charLockRefuses(ctx, svc, logger, sess, what); refused || err != nil {
					if err != nil {
						return err
					}
					return sendLobby(sess, &LobbyResult{Action: p.Data[0], Code: LobbyErrBusy})
				}
			}
		}
		return next(ctx, sess, p)
	}
}

// charLockRefuses reports whether the gate refuses this session now. A
// session not logged in passes: the handlers behind answer it (0x407). A
// store error refuses (fails closed) and is logged.
func charLockRefuses(ctx context.Context, svc *charlock.Service, logger *slog.Logger, sess *gateway.Session, what string) (bool, error) {
	accountID, ok := AuthenticatedAccountID(sess)
	if !ok {
		return false, nil
	}
	allowed, err := svc.Allows(ctx, accountID, charLockUnlocked(sess, accountID))
	if err != nil {
		logger.Warn("character lock: reading the lock failed; refused", "account", accountID, "action", what, "err", err)
		return true, nil
	}
	if !allowed {
		logger.Info("character lock: refused until the PIN is entered", "account", accountID, "action", what)
	}
	return !allowed, nil
}

func handleCharLock(ctx context.Context, svc *charlock.Service, logger *slog.Logger, sess *gateway.Session, p *proto.Packet) error {
	op := map[uint16]uint8{OpCharLockStatus: CharLockOpStatus, OpCharLockCreate: CharLockOpCreate,
		OpCharLockVerify: CharLockOpVerify, OpCharLockRemove: CharLockOpRemove}[p.Opcode]
	reply := func(code charlock.Code, st charlock.Status) error {
		return sess.Send(&proto.Packet{Opcode: OpCharLockReply, Data: charLockReplyOf(op, code, st).Encode()})
	}
	accountID, ok := AuthenticatedAccountID(sess)
	if !ok {
		return reply(charlock.NotLoggedIn, charlock.Status{})
	}
	unlocked := charLockUnlocked(sess, accountID)
	req, err := DecodeCharLockRequest(p.Opcode, p.Data)
	if err != nil || !charlock.ValidToken(req.Token) {
		st, _, _ := svc.Query(ctx, accountID, "", unlocked)
		return reply(charlock.BadFormat, st)
	}
	var code charlock.Code
	switch p.Opcode {
	case OpCharLockStatus:
		var st charlock.Status
		st, unlocked, err = svc.Query(ctx, accountID, req.Token, unlocked)
		if err != nil {
			logger.Warn("character lock: status", "account", accountID, "err", err)
			return reply(charlock.Failed, charlock.Status{Required: svc.Required})
		}
		if unlocked && !charLockUnlocked(sess, accountID) {
			setCharLockUnlocked(sess, accountID)
			logger.Info("character lock: unlocked by a remembered PC", "account", accountID)
		}
		return reply(charlock.OK, st)
	case OpCharLockCreate:
		code, err = svc.Create(ctx, accountID, req.Pin)
	case OpCharLockVerify:
		code, err = svc.Verify(ctx, accountID, req.Pin, req.Remember, req.Token)
	case OpCharLockRemove:
		code, err = svc.Remove(ctx, accountID, req.Pin)
	}
	if err != nil {
		logger.Warn("character lock: the store failed", "account", accountID, "op", op, "err", err)
	}
	// Create and verify open the lock for this login; so does remove (the
	// PIN was given). Nothing the player typed is logged.
	if code == charlock.OK {
		setCharLockUnlocked(sess, accountID)
		unlocked = true
	}
	logger.Info("character lock", "account", accountID, "op", []string{"status", "create", "verify", "remove"}[op],
		"code", code, "remember", req.Remember && op == CharLockOpVerify)
	st, _, qerr := svc.Query(ctx, accountID, "", unlocked)
	if qerr != nil {
		st = charlock.Status{Required: svc.Required}
	}
	return reply(code, st)
}

func charLockReplyOf(op uint8, code charlock.Code, st charlock.Status) *CharLockReply {
	r := &CharLockReply{Op: op, Code: code, AttemptsLeft: uint8(min(max(st.AttemptsLeft, 0), 255))}
	if st.HasPin {
		r.Flags |= CharLockFlagHasPin
	}
	if st.Required {
		r.Flags |= CharLockFlagRequired
	}
	if st.Unlocked {
		r.Flags |= CharLockFlagUnlocked
	}
	if st.LockedFor > 0 {
		r.Flags |= CharLockFlagLocked
		r.LockedSeconds = uint32((st.LockedFor + time.Second - 1) / time.Second)
	}
	return r
}
