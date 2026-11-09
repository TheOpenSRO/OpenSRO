package session

// Friends (round 834): the messenger's friend list on the retail wire and
// rules. docs/protocol/friends.md has the whole reading; the addresses below
// are its, c: the client, gs: SR_GameServer.exe, sm: SR_ShardManager.exe.
//
// The original splits this between two processes: the GameServer checks the
// asker and keeps each player's copy, the ShardManager checks the target,
// holds the 30-second request and writes `_Friend`. OpenSRO is one process
// and plays both; the messages between the two (0x7C00, 0xBC00, 0x7B06,
// 0x3B07 on the server side) have no counterpart here.
//
// The client's messages (READ, sizes from the asm):
//
//	C->S 0x7302 {str name}                         ask (c:0x824c30; gs:0x5d7620)
//	S->C 0xB302 {2, u16 code}                      the ask failed; 0x640b adds {u8 reason, str name}
//	S->C 0x7302 {u32 job, u32 askerJID, str name}  the request, to the target (c:0x886000)
//	C->S 0x3303 {u32 job, u32 askerJID, u8 answer} 1 accepts, anything else refuses (c:0x820b20)
//	C->S 0x7304 {u32 charID}                       delete (c:0x820a60; gs:0x5d77d0)
//	S->C 0xB304 {1, u32 charID} | {2, u16 code}    (gs:0x5d8330)
//	S->C 0x3305 {u8 n, n x {u32 charID, str name, u32 RefObjID, u8 state}}  at world entry only
//	S->C 0x3B07 {u8 kind, ...}                     the pushes: 2 added {u32 id, str name, u32 ref},
//	                                               3 removed {u32 id}, 4 state {u32 id, u8 state}
//
// State 0 is in the game, 1 is not (sm:0x446490). Strings are a u16 length
// and single-byte characters.
//
// OURS, disclosed:
//
//   - The JID in the request is the asker's character id; retail's is its
//     world id, opaque to the client, which only echoes it.
//   - The answer is matched to its job by id and asker (sm:0x421ec0) and,
//     here, also to the player the request went to.
//   - The asker's string check (gs:0x7312f0, the abuse filter) is the quote
//     test only.
//   - The list is sent sorted by name (the stores'); retail's is `_Friend`'s
//     row order (friends.md OPEN 10).

import (
	"context"
	"encoding/binary"
	"errors"
	"log/slog"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/friend"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

const (
	OpFriendAsk          uint16 = 0x7302 // C->S the ask; S->C the request to the target
	OpFriendAskFailed    uint16 = 0xB302 // S->C
	OpFriendAnswer       uint16 = 0x3303 // C->S
	OpFriendDelete       uint16 = 0x7304 // C->S
	OpFriendDeleteResult uint16 = 0xB304 // S->C
	OpFriendList         uint16 = 0x3305 // S->C, once at world entry
	OpMessengerPush      uint16 = 0x3B07 // S->C
)

// The pushes' kinds the client handles (c:0x886310, jump table c:0x886778).
const (
	MessengerAdded   byte = 2
	MessengerRemoved byte = 3
	MessengerState   byte = 4
)

// Friend state bytes (sm:0x446490, c:0x5a7990).
const (
	FriendOnline  byte = 0
	FriendOffline byte = 1
)

// The friend codes this server sends (docs/protocol/error_codes.md; the
// client's category 0x13, c:0x7baad7). 2 and 3 show nothing.
const (
	friendCodeFail          uint16 = 2
	friendCodeBadName       uint16 = 3
	FriendCodeFullList      uint16 = 0x6408 // FRIENDERR_FULLLIST
	FriendCodeAlreadyFriend uint16 = 0x6409 // FRIENDERR_ALREADYFRIEND
	FriendCodeRefused       uint16 = 0x640b // FRIENDERR_REFUSAL, with the reason
	FriendCodeUnknownUser   uint16 = 0x640d // FRIENDERR_UNKNOWNUSER
	FriendCodeTargetFull    uint16 = 0x640f // FRIENDERR_TARGETLISTFULL
)

// The 0x640b reasons: the target's answer byte (0 for Refuse), or 2 for the
// request timing out (sm:0x420a00).
const (
	FriendReasonRefused byte = 0
	FriendReasonTimeout byte = 2
)

// FriendRequestWait is how long a request waits for its answer: float 30.0
// at sm:0x79b01c, the overlapped job's timeout (sm:0x447792). A var so tests
// can shorten it.
var FriendRequestWait = 30 * time.Second

// friendNameMax is the ask's longest name (gs:0x5d7662..0x5d7670).
const friendNameMax = 32

type friendJob struct {
	id                uint32
	askerID, targetID int64
	askerName         string
	targetName        string
	timer             *time.Timer
}

type friendRuntime struct {
	chars   character.Store
	friends friend.Store
	hub     *world.Hub

	mu   sync.Mutex
	next uint32
	jobs map[uint32]*friendJob
}

var friendRT atomic.Pointer[friendRuntime]

// FriendHandler serves the friend messages. It also installs the runtime the
// world entry (friendAfterEnter) and the logout (FriendDisconnectHandler)
// use.
func FriendHandler(chars character.Store, friends friend.Store, hub *world.Hub) gateway.Handler {
	rt := &friendRuntime{chars: chars, friends: friends, hub: hub, jobs: map[uint32]*friendJob{}}
	friendRT.Store(rt)
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		switch p.Opcode {
		case OpFriendAsk:
			rt.ask(ctx, sess, p.Data)
		case OpFriendAnswer:
			rt.answer(ctx, sess, p.Data)
		case OpFriendDelete:
			rt.remove(ctx, sess, p.Data)
		}
		return nil
	}
}

// --- encoding ---------------------------------------------------------------

func appendFriendStr(b []byte, s string) []byte {
	b = binary.LittleEndian.AppendUint16(b, uint16(len(s)))
	return append(b, s...)
}

func readFriendStr(b []byte) (string, []byte, bool) {
	if len(b) < 2 {
		return "", nil, false
	}
	n := int(binary.LittleEndian.Uint16(b))
	if len(b) < 2+n {
		return "", nil, false
	}
	return string(b[2 : 2+n]), b[2+n:], true
}

// EncodeFriendAskFailed is 0xB302 {2, code}; FriendCodeRefused carries the
// reason and a name after it (gs:0x5d7f35, c:0x885e50).
func EncodeFriendAskFailed(code uint16, reason byte, name string) []byte {
	out := binary.LittleEndian.AppendUint16([]byte{2}, code)
	if code == FriendCodeRefused {
		out = appendFriendStr(append(out, reason), name)
	}
	return out
}

// EncodeFriendRequest is the request the target receives, 0x7302.
func EncodeFriendRequest(job, askerJID uint32, askerName string) []byte {
	out := binary.LittleEndian.AppendUint32(nil, job)
	out = binary.LittleEndian.AppendUint32(out, askerJID)
	return appendFriendStr(out, askerName)
}

// FriendEntry is one row of 0x3305.
type FriendEntry struct {
	CharacterID uint32
	Name        string
	RefObjID    uint32
	State       byte
}

// EncodeFriendList is 0x3305.
func EncodeFriendList(list []FriendEntry) []byte {
	out := []byte{byte(len(list))}
	for _, f := range list {
		out = binary.LittleEndian.AppendUint32(out, f.CharacterID)
		out = appendFriendStr(out, f.Name)
		out = binary.LittleEndian.AppendUint32(out, f.RefObjID)
		out = append(out, f.State)
	}
	return out
}

// EncodeFriendAdded is 0x3B07 kind 2 (gs:0x5d6650).
func EncodeFriendAdded(id uint32, name string, ref uint32) []byte {
	out := binary.LittleEndian.AppendUint32([]byte{MessengerAdded}, id)
	out = appendFriendStr(out, name)
	return binary.LittleEndian.AppendUint32(out, ref)
}

// EncodeFriendRemoved is 0x3B07 kind 3 (gs:0x5d6a30).
func EncodeFriendRemoved(id uint32) []byte {
	return binary.LittleEndian.AppendUint32([]byte{MessengerRemoved}, id)
}

// EncodeFriendState is 0x3B07 kind 4 (gs:0x5d69b0).
func EncodeFriendState(id uint32, state byte) []byte {
	return append(binary.LittleEndian.AppendUint32([]byte{MessengerState}, id), state)
}

// EncodeFriendDeleteResult is 0xB304: {1, id} or {2, code}.
func EncodeFriendDeleteResult(id uint32, code uint16) []byte {
	if code == 0 {
		return binary.LittleEndian.AppendUint32([]byte{1}, id)
	}
	return binary.LittleEndian.AppendUint16([]byte{2}, code)
}

func sendTo(sess *gateway.Session, op uint16, data []byte) {
	if sess != nil {
		sendToPeer(sess, &proto.Packet{Opcode: op, Data: data})
	}
}

// --- the ask ----------------------------------------------------------------

// ask is 0x7302 from the asker: the GameServer's checks on the asker
// (gs:0x5d7620), then the ShardManager's on the target (sm:0x447650), each in
// its order, the first failure answered 0xB302 {2, code}; then the job and
// the request to the target. There is no success reply: an accept shows as
// the kind-2 push (gs:0x518000 answers failures only).
func (rt *friendRuntime) ask(ctx context.Context, sess *gateway.Session, data []byte) {
	me, ok := rt.hub.EntityBySession(sess.ID())
	if !ok {
		return
	}
	name, _, ok := readFriendStr(data)
	if !ok {
		return
	}
	fail := func(code uint16) { sendTo(sess, OpFriendAskFailed, EncodeFriendAskFailed(code, 0, "")) }
	switch {
	case len(name) == 0 || len(name) > friendNameMax:
		fail(friendCodeFail)
		return
	case name == me.Name: // CompareStringA with flags 0, case-sensitive (gs:0x426f30)
		fail(friendCodeBadName)
		return
	case strings.ContainsAny(name, `'"`):
		fail(friendCodeBadName)
		return
	}
	mine, err := rt.friends.ListFriends(ctx, me.CharacterID)
	if err != nil {
		fail(friendCodeFail)
		return
	}
	for _, f := range mine {
		if f.Name == name {
			fail(FriendCodeAlreadyFriend)
			return
		}
	}
	if len(mine) >= friend.MaxFriends {
		fail(FriendCodeFullList)
		return
	}
	target, ok := findByNameAnywhere(rt.hub, name)
	if !ok {
		fail(FriendCodeUnknownUser)
		return
	}
	theirs, err := rt.friends.ListFriends(ctx, target.CharacterID)
	if err != nil {
		fail(friendCodeFail)
		return
	}
	if len(theirs) >= friend.MaxFriends {
		fail(FriendCodeTargetFull)
		return
	}
	for _, f := range theirs {
		if f.CharacterID == me.CharacterID {
			fail(FriendCodeAlreadyFriend)
			return
		}
	}
	job := rt.open(me, target)
	sendTo(target.Session, OpFriendAsk, EncodeFriendRequest(job.id, uint32(me.CharacterID), me.Name))
}

func (rt *friendRuntime) open(asker, target world.Entity) *friendJob {
	rt.mu.Lock()
	defer rt.mu.Unlock()
	rt.next++
	if rt.next == 0 {
		rt.next = 1
	}
	job := &friendJob{id: rt.next, askerID: asker.CharacterID, targetID: target.CharacterID,
		askerName: asker.Name, targetName: target.Name}
	rt.jobs[job.id] = job
	job.timer = time.AfterFunc(FriendRequestWait, func() {
		if rt.take(job.id) != nil {
			rt.ended(job, FriendReasonTimeout)
		}
	})
	return job
}

// take removes a job once; nil when it is already answered or timed out.
func (rt *friendRuntime) take(id uint32) *friendJob {
	rt.mu.Lock()
	defer rt.mu.Unlock()
	job := rt.jobs[id]
	if job != nil {
		delete(rt.jobs, id)
		job.timer.Stop()
	}
	return job
}

// answer is 0x3303 from the target (sm:0x421ec0 -> sm:0x447850).
func (rt *friendRuntime) answer(ctx context.Context, sess *gateway.Session, data []byte) {
	me, ok := rt.hub.EntityBySession(sess.ID())
	if !ok || len(data) < 9 {
		return
	}
	id := binary.LittleEndian.Uint32(data)
	asker := binary.LittleEndian.Uint32(data[4:])
	answer := data[8]
	rt.mu.Lock()
	job := rt.jobs[id]
	match := job != nil && uint32(job.askerID) == asker && job.targetID == me.CharacterID
	rt.mu.Unlock()
	if !match || rt.take(id) == nil {
		return
	}
	if answer != 1 {
		rt.ended(job, answer)
		return
	}
	rt.accept(ctx, job)
}

// accept is sm:0x447320: both players must be in the game, neither may list
// the other and both lists must have room; then `_Friend_Add` and the
// kind-2 push to both. A failed check sends nothing (READ).
func (rt *friendRuntime) accept(ctx context.Context, job *friendJob) {
	a, aok := rt.hub.EntityByCharacterID(job.askerID)
	b, bok := rt.hub.EntityByCharacterID(job.targetID)
	if !aok || !bok {
		return
	}
	if err := rt.friends.AddFriendship(ctx, a.CharacterID, a.Name, b.CharacterID, b.Name); err != nil {
		if !errors.Is(err, friend.ErrAlreadyFriends) && !errors.Is(err, friend.ErrListFull) {
			slog.Warn("friend: adding failed", "asker", a.CharacterID, "target", b.CharacterID, "err", err)
		}
		return
	}
	sendTo(a.Session, OpMessengerPush, EncodeFriendAdded(uint32(b.CharacterID), b.Name, rt.refOf(ctx, b.CharacterID)))
	sendTo(b.Session, OpMessengerPush, EncodeFriendAdded(uint32(a.CharacterID), a.Name, rt.refOf(ctx, a.CharacterID)))
}

// ended is a refusal or the timeout: kind 5 to both players' GameServers,
// each turning it into 0xB302 {2, 0x640b, reason, name} (gs:0x5d7f35). The
// refuser gets it too (READ quirk, c:0x885e50 prints the refusal line
// without testing who it is).
func (rt *friendRuntime) ended(job *friendJob, reason byte) {
	msg := EncodeFriendAskFailed(FriendCodeRefused, reason, job.targetName)
	for _, id := range [2]int64{job.askerID, job.targetID} {
		if e, ok := rt.hub.EntityByCharacterID(id); ok {
			sendTo(e.Session, OpFriendAskFailed, msg)
		}
	}
}

func (rt *friendRuntime) refOf(ctx context.Context, characterID int64) uint32 {
	c, err := rt.chars.GetByID(ctx, characterID)
	if err != nil || c == nil {
		return 0
	}
	ref, _ := modelOf(c)
	return ref
}

// --- delete -----------------------------------------------------------------

// remove is 0x7304 (gs:0x5d77d0): 3 when the id is not on the list; then
// `_Friend_Remove`, both ways (sm:0x446930). The deleter gets the kind-3 push
// and then 0xB304 {1, id} (gs:0x5d8330); the other side, in the game, the
// kind-3 push.
func (rt *friendRuntime) remove(ctx context.Context, sess *gateway.Session, data []byte) {
	me, ok := rt.hub.EntityBySession(sess.ID())
	if !ok || len(data) < 4 {
		return
	}
	id := binary.LittleEndian.Uint32(data)
	mine, err := rt.friends.ListFriends(ctx, me.CharacterID)
	if err != nil {
		sendTo(sess, OpFriendDeleteResult, EncodeFriendDeleteResult(0, friendCodeFail))
		return
	}
	listed := false
	for _, f := range mine {
		listed = listed || f.CharacterID == int64(id)
	}
	if !listed {
		sendTo(sess, OpFriendDeleteResult, EncodeFriendDeleteResult(0, friendCodeBadName))
		return
	}
	if err := rt.friends.RemoveFriend(ctx, me.CharacterID, int64(id)); err != nil {
		sendTo(sess, OpFriendDeleteResult, EncodeFriendDeleteResult(0, friendCodeFail))
		return
	}
	sendTo(sess, OpMessengerPush, EncodeFriendRemoved(id))
	sendTo(sess, OpFriendDeleteResult, EncodeFriendDeleteResult(id, 0))
	if other, ok := rt.hub.EntityByCharacterID(int64(id)); ok {
		sendTo(other.Session, OpMessengerPush, EncodeFriendRemoved(uint32(me.CharacterID)))
	}
}

// --- log on and off ---------------------------------------------------------

// friendAfterEnter sends the arriving character its list, 0x3305, the only
// time it is sent (gs:0x5d6550 -> 0x5d6b10), each friend in the game with
// state 0; then tells those friends it logged on, kind 4 state 0
// (sm:0x447560(..., 0)).
func friendAfterEnter(ctx context.Context, sess *gateway.Session, owned *character.Character) {
	rt := friendRT.Load()
	if rt == nil || owned == nil {
		return
	}
	list, err := rt.friends.ListFriends(ctx, owned.ID)
	if err != nil {
		slog.Warn("friend: loading the list failed", "character_id", owned.ID, "err", err)
		return
	}
	if len(list) > friend.MaxFriends {
		list = list[:friend.MaxFriends] // gs:0x5d6b23 sends at most 20
	}
	entries := make([]FriendEntry, 0, len(list))
	var online []world.Entity
	for _, f := range list {
		state := FriendOffline
		if e, ok := rt.hub.EntityByCharacterID(f.CharacterID); ok {
			state = FriendOnline
			online = append(online, e)
		}
		entries = append(entries, FriendEntry{CharacterID: uint32(f.CharacterID), Name: f.Name,
			RefObjID: rt.refOf(ctx, f.CharacterID), State: state})
	}
	sendTo(sess, OpFriendList, EncodeFriendList(entries))
	for _, e := range online {
		sendTo(e.Session, OpMessengerPush, EncodeFriendState(uint32(owned.ID), FriendOnline))
	}
}

// FriendDisconnectHandler tells a leaving character's friends in the game it
// logged off, kind 4 state 1 (sm:0x447210 -> 0x447560(..., 1)). It must run
// before WorldDisconnectHandler, while the hub still knows the session.
func FriendDisconnectHandler(hub *world.Hub) func(sess *gateway.Session) {
	return func(sess *gateway.Session) {
		// Round 869: the session's own world (gameworlds.go).
		hub := hub.For(sess)
		rt := friendRT.Load()
		if rt == nil {
			return
		}
		me, ok := hub.EntityBySession(sess.ID())
		if !ok {
			return
		}
		list, err := rt.friends.ListFriends(context.Background(), me.CharacterID)
		if err != nil {
			return
		}
		for _, f := range list {
			if e, ok := hub.EntityByCharacterID(f.CharacterID); ok && e.Session != sess {
				sendTo(e.Session, OpMessengerPush, EncodeFriendState(uint32(me.CharacterID), FriendOffline))
			}
		}
	}
}
