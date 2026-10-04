package main

// The round-713 party-match acceptance run (-mode match).

import (
	"fmt"
	"strings"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/party"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
)

type matchPage struct {
	pages, at uint8
	rows      []party.ListEntry
}

// decodePage reads a 0xb06c success.
func decodePage(b []byte) (matchPage, error) {
	if len(b) < 4 || b[0] != party.ResultOK {
		return matchPage{}, fmt.Errorf("not a page: % x", b)
	}
	pg := matchPage{pages: b[1], at: b[2]}
	rest := b[4:]
	for i := 0; i < int(b[3]); i++ {
		r, more, err := party.ReadListEntry(rest)
		if err != nil {
			return matchPage{}, err
		}
		pg.rows = append(pg.rows, r)
		rest = more
	}
	return pg, nil
}

func joinAck(ok bool, v uint16) func(*proto.Packet) bool {
	return func(p *proto.Packet) bool {
		if p.Opcode != party.OpMatchJoinAck || len(p.Data) != 3 {
			return false
		}
		res := party.ResultError
		if ok {
			res = party.ResultOK
		}
		return p.Data[0] == res && uint16(p.Data[1])|uint16(p.Data[2])<<8 == v
	}
}

func matchScenario(addr, prefix string) error {
	type who struct {
		name  string
		level int
	}
	cast := []who{{"Lia", 10}, {"Rex", 10}, {"Sam", 10}, {"Tia", 1}}
	bots := map[string]*bot{}
	for _, w := range cast {
		full := prefix + w.name
		b, err := connect(addr, strings.ToLower(full), full, w.level)
		if err != nil {
			return err
		}
		bots[w.name] = b
		fmt.Printf("[%s] in the world, character %d, JID %d, level %d\n", full, b.id, b.jid(), w.level)
	}
	lia, rex, sam, tia := bots["Lia"], bots["Rex"], bots["Sam"], bots["Tia"]
	flags := party.FlagExpShare | party.FlagItemShare
	var entry uint32
	var job *party.JoinRequest
	page := func(b *bot) (matchPage, error) {
		b.send(party.OpMatchList, []byte{0})
		var pg matchPage
		err := b.expect("0xb06c", func(p *proto.Packet) bool {
			if p.Opcode != party.OpMatchListAck {
				return false
			}
			var err error
			pg, err = decodePage(p.Data)
			return err == nil
		})
		return pg, err
	}
	toLeader := func(requester *bot) error {
		return lia.expect("0x706d from "+requester.name, func(p *proto.Packet) bool {
			if p.Opcode != party.OpMatchJoin {
				return false
			}
			j, err := party.DecodeJoinRequest(p.Data)
			if err != nil || j.Requester != requester.jid() || j.Entry != entry || j.Record.Name != requester.name {
				return false
			}
			job = j
			return true
		})
	}
	steps := []step{
		{"Lia registers a party-less entry: Exp+Item Auto Share, Hunting, levels 5..20", func() error {
			lia.send(party.OpMatchRegister, party.AppendEntry(nil, &party.Entry{Flags: flags, Purpose: party.PurposeHunting, MinLevel: 5, MaxLevel: 20, Title: "For open hunting"}))
			return lia.expect("0xb069 [1] with a number", func(p *proto.Packet) bool {
				if p.Opcode != party.OpMatchRegAck || len(p.Data) < 1 || p.Data[0] != party.ResultOK {
					return false
				}
				e, _, err := party.ReadEntry(p.Data[1:])
				if err != nil || e.Number == 0 || e.Flags != flags || e.MinLevel != 5 || e.MaxLevel != 20 {
					return false
				}
				entry = e.Number
				return true
			})
		}},
		{"Rex pages: Lia's entry, 1 member", func() error {
			pg, err := page(rex)
			if err != nil {
				return err
			}
			for _, r := range pg.rows {
				if r.Number == entry {
					if r.Name != lia.name || r.Count != 1 || r.Flags != flags {
						return fmt.Errorf("row %+v", r)
					}
					return nil
				}
			}
			return fmt.Errorf("entry %d not on page 0: %+v", entry, pg)
		}},
		{"Tia (level 1) asks: refused 0x2c1e, the leader hears nothing", func() error {
			tia.send(party.OpMatchJoin, party.EncodeTarget(entry))
			if err := tia.expect("0xb06d [2] 0x2c1e", joinAck(false, party.CodeJoinLevel)); err != nil {
				return err
			}
			return lia.quiet()
		}},
		{"Rex asks: Lia gets the 0x706d", func() error {
			rex.send(party.OpMatchJoin, party.EncodeTarget(entry))
			return toLeader(rex)
		}},
		{"Sam asks while Rex's request is pending: refused 0x2c1f", func() error {
			sam.send(party.OpMatchJoin, party.EncodeTarget(entry))
			return sam.expect("0xb06d [2] 0x2c1f", joinAck(false, party.CodeDuplicate))
		}},
		{"Lia confirms: Rex gets 0xb06d [1][1] twice, then the formation with the entry's flags", func() error {
			lia.send(party.OpMatchAnswer, party.EncodeJoinAnswer(job.JobID, job.Requester, party.AnswerConfirm))
			for _, x := range []struct {
				b    *bot
				what string
				ok   func(*proto.Packet) bool
			}{
				{rex, "0xb06d [1][1]", joinAck(true, party.JoinJoined)},
				{rex, "0xb06d [1][1] again", joinAck(true, party.JoinJoined)},
				{lia, "0xb060 [1] Lia's JID", ack(party.OpCreateAck, true, lia.jid())},
				{lia, "0x3065 of Lia alone", info(1)},
				{lia, "kind 2 Rex", event(party.EventJoined, rex.jid(), nil)},
				{rex, "0xb067 [1] Rex's JID", ack(party.OpJoinAck, true, rex.jid())},
				{rex, "0x3065 of both, flags 0x03", func(p *proto.Packet) bool {
					if p.Opcode != party.OpInfo {
						return false
					}
					in, err := party.DecodeInfo(p.Data)
					return err == nil && len(in.Members) == 2 && in.Flags == flags && in.Leader == lia.jid()
				}},
			} {
				if err := x.b.expect(x.what, x.ok); err != nil {
					return err
				}
			}
			return nil
		}},
		{"Sam pages: Lia's entry now shows 2 members", func() error {
			pg, err := page(sam)
			if err != nil {
				return err
			}
			for _, r := range pg.rows {
				if r.Number == entry && r.Count == 2 {
					return nil
				}
			}
			return fmt.Errorf("entry %d with 2 members not on the page: %+v", entry, pg)
		}},
		{"Sam asks and Lia never answers: the 15 s backstop gives Sam 0xb06d [1][2]", func() error {
			sam.send(party.OpMatchJoin, party.EncodeTarget(entry))
			if err := toLeader(sam); err != nil {
				return err
			}
			select {
			case p, open := <-sam.in:
				if !open {
					return fmt.Errorf("Sam's connection closed")
				}
				if !joinAck(true, party.JoinNoReply)(p) {
					return fmt.Errorf("Sam got %s, want 0xb06d [1][2]", describe(p))
				}
				return nil
			case <-time.After(17 * time.Second):
				return fmt.Errorf("no backstop answer within 17 s")
			}
		}},
		{"Lia deletes the entry: 0xb06b [1][entry]; Rex's page no longer has it", func() error {
			lia.send(party.OpMatchDelete, party.EncodeTarget(entry))
			if err := lia.expect("0xb06b [1]", ack(party.OpMatchDelAck, true, entry)); err != nil {
				return err
			}
			pg, err := page(rex)
			if err != nil {
				return err
			}
			for _, r := range pg.rows {
				if r.Number == entry {
					return fmt.Errorf("entry %d still listed", entry)
				}
			}
			return nil
		}},
	}
	for i, s := range steps {
		fmt.Printf("--- step %d: %s\n", i+1, s.what)
		if err := s.do(); err != nil {
			return fmt.Errorf("step %d (%s): %w", i+1, s.what, err)
		}
	}
	fmt.Println("--- all steps passed")
	return nil
}
