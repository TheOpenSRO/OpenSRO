package session

// Social events that change what every process holds (round 869 lane W2,
// OURS): a guild's or a union's new crest is filed in each process's plate
// cache (what its spawn records carry) and its 0x3257 sent to each process's
// players. The event travels, not the deliveries: every process applies it
// to its own.

import (
	"context"
	"errors"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/guild"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
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

// A GM's ban or unban (round 840's chat and trade restrictions) is cached
// per account on every process: each one forgets its copy.
const kindRestrictions = "account.restrictions"

// restrictionsEverywhere tells the other processes accountID's
// restrictions changed.
func restrictionsEverywhere(accountID int64) {
	cs := clusterRT.Load()
	if cs == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cs.node.Broadcast(ctx, kindRestrictions, accountBody{Account: accountID})
}

func onRestrictions(_ context.Context, m clusterMsg) (any, error) {
	var b accountBody
	if err := m.Decode(&b); err != nil {
		return nil, err
	}
	ForgetRestrictions(b.Account)
	return nil, nil
}

// A guild line's change (refreshGuildPlate) for a character on another
// process is redone there: that process re-reads the guild and tells the
// players who see the character.
const kindGuildPlate = "guild.plate"

type plateBody struct {
	Char int64 `json:"c"`
}

func guildPlateEverywhere(characterID int64) {
	cs := clusterRT.Load()
	if cs == nil {
		return
	}
	c, ok := cs.node.Lookup(characterID)
	if !ok || c.Host == cs.node.ID() {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cs.node.Send(ctx, c.Host, kindGuildPlate, plateBody{Char: characterID})
}

func onGuildPlate(_ context.Context, m clusterMsg) (any, error) {
	var b plateBody
	if err := m.Decode(&b); err != nil {
		return nil, err
	}
	// The guild is read off the bus's goroutine (a one-way message's
	// handler must not block the deliveries behind it).
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		refreshPlateFor(ctx, b)
	}()
	return nil, nil
}

func refreshPlateFor(ctx context.Context, b plateBody) (any, error) {
	hub, ok := world.Locate(b.Char)
	if !ok {
		return nil, nil
	}
	box := guildPlateStore.Load()
	if box == nil {
		return nil, nil
	}
	g, err := box.s.GetByCharacter(ctx, b.Char)
	if err != nil && !errors.Is(err, guild.ErrNotInGuild) {
		return nil, err
	}
	if errors.Is(err, guild.ErrNotInGuild) {
		g = nil
	}
	p := plateOf(g, b.Char)
	p.UnionID, p.UnionCrestRev = unionFieldsOf(ctx, g)
	if v, ok := guildPlates.Load(b.Char); ok && v.(guildPlate) == p {
		return nil, nil
	}
	guildPlates.Delete(b.Char)
	refreshGuildPlateHere(hub, b.Char, g)
	return nil, nil
}
