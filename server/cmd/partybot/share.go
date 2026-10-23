package main

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/party"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/session"
)

// awaitOther waits for the next reply of op on the side channel.
func (b *bot) awaitOther(op uint16, d time.Duration) (*proto.Packet, error) {
	deadline := time.After(d)
	for {
		select {
		case p := <-b.other:
			if p.Opcode == op {
				return p, nil
			}
		case <-deadline:
			return nil, fmt.Errorf("%s: no 0x%04x within %s", b.name, op, d)
		}
	}
}

func (b *bot) gm(line string) (*session.GMCommandResult, error) {
	b.send(session.OpGMCommand, (&session.GMCommandRequest{Name: b.name, Line: line}).Encode())
	p, err := b.awaitOther(session.OpGMCommandResult, 5*time.Second)
	if err != nil {
		return nil, err
	}
	r, err := session.DecodeGMCommandResult(p.Data)
	if err != nil {
		return nil, err
	}
	if r.Refused {
		return r, fmt.Errorf("%s: %s refused: %s", b.name, line, r.Text)
	}
	return r, nil
}

func (b *bot) exp() (int64, error) {
	b.send(session.OpCharacterStats, (&session.CharacterNameRequest{Name: b.name}).Encode())
	p, err := b.awaitOther(session.OpCharacterStatsResult, 5*time.Second)
	if err != nil {
		return 0, err
	}
	r, err := session.DecodeCharacterStatsResult(p.Data)
	if err != nil {
		return 0, err
	}
	return r.Exp, nil
}

var (
	spawnIDs  = regexp.MustCompile(`ids (\d+)`)
	monsterHP = regexp.MustCompile(`HP (\d+)\)`)
)

// kill spawns one monster beside b, wounds it to 1 HP with /damage (booked to
// b on the monster's damage list, paying nothing itself) and swings until a
// blow kills it. It returns the killing blow's attack result.
func (b *bot) kill(species string) (*session.AttackResult, error) {
	r, err := b.gm("/spawn " + species + " 1")
	if err != nil {
		return nil, err
	}
	m := spawnIDs.FindStringSubmatch(r.Text)
	h := monsterHP.FindStringSubmatch(r.Text)
	if m == nil || h == nil {
		return nil, fmt.Errorf("%s: cannot read the spawn: %q", b.name, r.Text)
	}
	id, _ := strconv.ParseInt(m[1], 10, 64)
	hp, _ := strconv.Atoi(h[1])
	if hp > 1 {
		if _, err := b.gm(fmt.Sprintf("/damage %d %d", hp-1, id)); err != nil {
			return nil, err
		}
	}
	for i := 0; i < 40; i++ {
		b.send(session.OpAttack, (&session.AttackRequest{CharacterName: b.name, TargetMonsterID: id}).Encode())
		p, err := b.awaitOther(session.OpAttackResult, 5*time.Second)
		if err != nil {
			return nil, err
		}
		ar, err := session.DecodeAttackResult(p.Data)
		if err != nil {
			return nil, err
		}
		if ar.MonsterDied {
			fmt.Printf("[%s] killed %s #%d (HP %d): EXP +%d, SP +%d\n", b.name, species, id, hp, ar.ExpGained, ar.SkillExpGained)
			return ar, nil
		}
		time.Sleep(700 * time.Millisecond)
	}
	return nil, fmt.Errorf("%s: monster %d did not die", b.name, id)
}

// form makes a from-led party of two with flags.
func form(from, to *bot, flags party.Flags) error {
	from.send(party.OpCreate, party.EncodeCreate(to.jid(), flags))
	if err := to.expect("0x3080 kind 2", invitation(party.InviteForm, from.jid())); err != nil {
		return err
	}
	to.send(party.OpInvitation, party.EncodeAnswerYes())
	time.Sleep(500 * time.Millisecond)
	drain(from)
	drain(to)
	return nil
}

func drain(b *bot) {
	for {
		select {
		case <-b.in:
		default:
			return
		}
	}
}

func shareScenario(addr, prefix, species string, level int) error {
	names := []string{"Solo", "Kill", "Mate", "Ffa", "Idle"}
	bots := map[string]*bot{}
	for _, n := range names {
		full := prefix + n
		b, err := connect(addr, strings.ToLower(full), full, level)
		if err != nil {
			return err
		}
		bots[n] = b
	}
	solo, killer, mate, ffa, idle := bots["Solo"], bots["Kill"], bots["Mate"], bots["Ffa"], bots["Idle"]
	for i, b := range []*bot{killer, mate, ffa, idle} {
		if b.zone != solo.zone {
			return fmt.Errorf("%s entered %s, %s %s: one zone needed", b.name, b.zone, solo.name, solo.zone)
		}
		b.moveTo(solo.x+float32(10*(i+1)), solo.y, solo.z)
	}
	time.Sleep(300 * time.Millisecond)

	fmt.Println("--- 1: the baseline, a solo kill (multiplier 1)")
	base, err := solo.kill(species)
	if err != nil {
		return err
	}
	if base.ExpGained <= 0 {
		return fmt.Errorf("the solo kill paid no EXP")
	}
	share := int64(float64(float32(base.ExpGained)) * float64(float32(0.55)))
	ffaWant := int64(float64(float32(base.ExpGained)) * float64(float32(1.03)))

	fmt.Println("--- 2: an Exp Auto Share party of two; one member kills")
	if err := form(killer, mate, party.FlagExpShare|party.FlagItemShare); err != nil {
		return err
	}
	before, err := mate.exp()
	if err != nil {
		return err
	}
	ar, err := killer.kill(species)
	if err != nil {
		return err
	}
	after, err := mate.exp()
	if err != nil {
		return err
	}
	fmt.Printf("    killer +%d EXP, mate +%d EXP; want both trunc(%d x 0.55) = %d\n", ar.ExpGained, after-before, base.ExpGained, share)
	if ar.ExpGained != share || after-before != share {
		return fmt.Errorf("party share: killer %d, mate %d, want %d each", ar.ExpGained, after-before, share)
	}
	// Round 716: both receivers are told with retail 0x3056 -- the mate, who
	// never hit, included -- each with what its row rose by.
	kg, _ := killer.lastGain()
	mg, mn := mate.lastGain()
	fmt.Printf("    0x3056: killer %d EXP / %d skill EXP, mate %d EXP / %d skill EXP (source %d)\n", kg.Exp, kg.SkillExp, mg.Exp, mg.SkillExp, mg.Source)
	if mn == 0 || mg.Exp != after-before || kg.Exp != ar.ExpGained || mg.SkillExp <= 0 || mg.Source == 0 || mg.Source != kg.Source {
		return fmt.Errorf("0x3056: killer %+v, mate %+v (%d sent); want each the EXP its row rose by, one source", kg, mg, mn)
	}

	fmt.Println("--- 3: an Exp Free-For-All party of two; one member kills")
	if err := form(ffa, idle, party.FlagItemShare); err != nil {
		return err
	}
	before, err = idle.exp()
	if err != nil {
		return err
	}
	ar, err = ffa.kill(species)
	if err != nil {
		return err
	}
	after, err = idle.exp()
	if err != nil {
		return err
	}
	fmt.Printf("    killer +%d EXP, idle member +%d EXP; want trunc(%d x 1.03) = %d and 0\n", ar.ExpGained, after-before, base.ExpGained, ffaWant)
	if ar.ExpGained != ffaWant || after != before {
		return fmt.Errorf("free-for-all: killer %d (want %d), idle member %d (want 0)", ar.ExpGained, ffaWant, after-before)
	}
	if _, n := idle.lastGain(); n != 0 {
		return fmt.Errorf("free-for-all: the idle member, paid nothing, was sent %d 0x3056", n)
	}
	if fg, _ := ffa.lastGain(); fg.Exp != ar.ExpGained {
		return fmt.Errorf("free-for-all: the killer's 0x3056 says %d EXP, its result %d", fg.Exp, ar.ExpGained)
	}
	fmt.Println("--- all share steps passed")
	return nil
}
