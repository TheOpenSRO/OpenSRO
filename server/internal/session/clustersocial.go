package session

// Social events that change what every process holds (round 869 lane W2,
// OURS): a guild's or a union's new crest is filed in each process's plate
// cache (what its spawn records carry) and its 0x3257 sent to each process's
// players. The event travels, not the deliveries: every process applies it
// to its own.

import (
	"context"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
)

const kindCrest = "guild.crest"

type crestBody struct {
	ID    uint32 `json:"id"`
	Union bool   `json:"union"`
	Rev   uint32 `json:"rev"`
	// Frame is the 0x3257 the players hear.
	Frame []byte `json:"frame"`
}

// crestEverywhere tells the other processes a crest changed.
func crestEverywhere(id uint32, union bool, rev uint32, frame []byte) {
	cs := clusterRT.Load()
	if cs == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cs.node.Broadcast(ctx, kindCrest, crestBody{ID: id, Union: union, Rev: rev, Frame: frame})
}

func onCrest(_ context.Context, m clusterMsg) (any, error) {
	cs := clusterRT.Load()
	if cs == nil || m.From == cs.node.ID() {
		return nil, nil
	}
	var b crestBody
	if err := m.Decode(&b); err != nil {
		return nil, err
	}
	guildPlates.Range(func(k, v any) bool {
		p := v.(guildPlate)
		switch {
		case b.Union && p.UnionID == b.ID:
			p.UnionCrestRev = b.Rev
			guildPlates.Store(k, p)
		case !b.Union && p.ID == b.ID:
			p.CrestRev = b.Rev
			guildPlates.Store(k, p)
		}
		return true
	})
	pkt := &proto.Packet{Opcode: OpGuildCrestUpdate, Data: b.Frame}
	for _, e := range localEveryone() {
		if e.Session != nil {
			e.Session.Send(pkt)
		}
	}
	return nil, nil
}

// A friend request's answer from another process (OURS): the request's job
// lives on the asker's process, so an answer whose job is not here goes
// there.
const kindFriendAnswer = "friend.answer"

type friendAnswerBody struct {
	ID     uint32 `json:"id"`
	Asker  uint32 `json:"asker"`
	Target int64  `json:"target"`
	Answer byte   `json:"answer"`
}

// forwardFriendAnswer sends an answer to the asker's process when the asker
// plays on another; false when it does not (the answer is this one's).
func forwardFriendAnswer(id, asker uint32, target int64, answer byte) bool {
	cs := clusterRT.Load()
	if cs == nil {
		return false
	}
	c, ok := cs.node.Lookup(int64(asker))
	if !ok || c.Host == cs.node.ID() {
		return false
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	return cs.node.Send(ctx, c.Host, kindFriendAnswer, friendAnswerBody{ID: id, Asker: asker, Target: target, Answer: answer}) == nil
}

func onFriendAnswer(ctx context.Context, m clusterMsg) (any, error) {
	var b friendAnswerBody
	if err := m.Decode(&b); err != nil {
		return nil, err
	}
	if rt := friendRT.Load(); rt != nil {
		rt.answerJob(ctx, b.ID, b.Asker, b.Target, b.Answer)
	}
	return nil, nil
}
