package session

import (
	"context"
	"fmt"
	"log/slog"
	"math/rand"
	"sort"
	"sync"
	"sync/atomic"

	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/charmsg"
	"github.com/OpenSRO/OpenSRO/server/internal/combat"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
	"github.com/OpenSRO/OpenSRO/server/internal/leveldata"
	"github.com/OpenSRO/OpenSRO/server/internal/mana"
	"github.com/OpenSRO/OpenSRO/server/internal/npcspawn"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/quest"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
	"github.com/OpenSRO/OpenSRO/server/internal/skill"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// The quest runtime (round 785): the real catalogue (internal/quest), each
// character's log, the NPC talk pages, the kill and drop credit, the rewards
// and the marks. docs/protocol/quests.md has the messages and the flow.
//
// The flow, READ from the client (quests.md "Messages") and the server
// script (quest.Apply):
//
//	0x7046 {npc, 2}   -> 0xB046 ok, then 0x30D4 list page: the NPC's greeting
//	                     and one line per quest it offers or is part of
//	0x70D4 {5+i}      -> an offer: 0x30D4 yes/no with the quest's request text
//	0x70D4 {2}        -> accepted: 0x30D5 add, items handed over, 0x30D4 the
//	                     accept text; {3}: the deny text
//	0x70D4 {5+i}      -> a quest under way here: its delivery or dialogue is
//	                     settled, or, done, 0x3514 opens the reward window
//	0x7515 {quest}    -> paid: gold, EXP, skill EXP, SP, items; 0x30D5 drop;
//	                     0xB515 {1}
//	0x70D9 {quest}    -> given up: 0xB0D9 {1, id}, 0x30D5 remove
//
// Kills count and drop quest items in announceKill (combat.go), for the
// killer.

// QuestItems is the item table lookups the runtime needs.
type QuestItems interface {
	GetItem(ctx context.Context, id int64) (*refdata.Item, error)
	GetItemByCode(ctx context.Context, code string) (*refdata.Item, error)
}

// QuestDeps are the stores the runtime pays and reads through.
type QuestDeps struct {
	Store  quest.Store
	Chars  character.Store
	Inv    inventory.Store
	Items  QuestItems
	Skills skill.Store
	Hub    *world.Hub
	MP     *mana.Tracker
	Logger *slog.Logger
	// Roll answers a gather mission's drop roll (rate in percent); nil uses
	// math/rand.
	Roll func(rate float64) bool
}

type questLog struct {
	mu  sync.Mutex
	log quest.Log
}

type talkEntry struct {
	questID int64
	offer   bool
}

const (
	talkList = iota
	talkAsk
	talkDone
	talkReward
)

type questTalk struct {
	npc     string
	entity  uint32
	stage   int
	list    []talkEntry
	pending int64
}

type questRuntime struct {
	cat  *quest.Catalog
	deps QuestDeps

	mu    sync.Mutex
	logs  map[int64]*questLog
	talks map[uint64]*questTalk
	marks map[uint64]map[uint32]byte // session -> NPC uid -> mark sent
	// markLevel is the level the session's marks were last worked out for:
	// a level-up opens new quests, so a kill by a character whose level
	// moved refreshes them.
	markLevel map[uint64]int

	npcOnce  sync.Once
	npcByCod map[string][]npcspawn.Record
}

var questRT atomic.Pointer[questRuntime]

// InstallQuests installs the quest runtime with cat (nil uninstalls it).
func InstallQuests(cat *quest.Catalog, d QuestDeps) {
	if cat == nil {
		questRT.Store(nil)
		return
	}
	if d.Logger == nil {
		d.Logger = slog.Default()
	}
	questRT.Store(&questRuntime{cat: cat, deps: d, logs: map[int64]*questLog{}, talks: map[uint64]*questTalk{},
		marks: map[uint64]map[uint32]byte{}, markLevel: map[uint64]int{}})
}

func (rt *questRuntime) roll(rate float64) bool {
	if rt.deps.Roll != nil {
		return rt.deps.Roll(rate)
	}
	return rand.Float64()*100 < rate
}

// logOf returns characterID's log, loading it from the store once.
func (rt *questRuntime) logOf(ctx context.Context, characterID int64) (*questLog, error) {
	rt.mu.Lock()
	l, ok := rt.logs[characterID]
	rt.mu.Unlock()
	if ok {
		return l, nil
	}
	states, err := rt.deps.Store.States(ctx, characterID)
	if err != nil {
		return nil, err
	}
	rt.mu.Lock()
	defer rt.mu.Unlock()
	if l, ok := rt.logs[characterID]; ok {
		return l, nil
	}
	l = &questLog{log: quest.NewLog(states)}
	rt.logs[characterID] = l
	return l, nil
}

// ForgetQuestSession drops a session's talk and mark state (its disconnect).
func ForgetQuestSession(sessionID uint64) {
	rt := questRT.Load()
	if rt == nil {
		return
	}
	rt.mu.Lock()
	delete(rt.talks, sessionID)
	delete(rt.marks, sessionID)
	delete(rt.markLevel, sessionID)
	rt.mu.Unlock()
}

// npcs returns the NPC records of code (all placements' unique ids).
func (rt *questRuntime) npcs(code string) []npcspawn.Record {
	rt.npcOnce.Do(func() {
		rt.npcByCod = map[string][]npcspawn.Record{}
		w := npcWorldRuntime.Load()
		if w == nil {
			return
		}
		seen := map[uint32]bool{}
		uids := make([]uint32, 0, len(w.byUID))
		for uid := range w.byUID {
			uids = append(uids, uid)
		}
		sort.Slice(uids, func(i, j int) bool { return uids[i] < uids[j] })
		for _, uid := range uids {
			for _, pl := range w.byUID[uid] {
				if pl.npc == nil || seen[uid] {
					continue
				}
				seen[uid] = true
				rt.npcByCod[pl.npc.Code] = append(rt.npcByCod[pl.npc.Code], pl.npc.Record)
			}
		}
	})
	return rt.npcByCod[code]
}

func (rt *questRuntime) refID(code string) uint32 {
	if recs := rt.npcs(code); len(recs) > 0 {
		return recs[0].RefID
	}
	return 0
}

func playerOf(ctx context.Context, chars character.Store, characterID int64, level int) quest.Player {
	p := quest.Player{Level: level}
	if chars != nil {
		if c, err := chars.GetByID(ctx, characterID); err == nil && c != nil {
			p.Race = character.RaceOf(c.Gender)
			if p.Level == 0 {
				p.Level = c.Level
			}
		}
	}
	return p
}

// view builds a quest's 0x30D5 body.
func (rt *questRuntime) view(q *quest.Quest, s *quest.State) quest.View {
	v := quest.View{State: 1, Status: byte(s.Status)}
	ach, lim := s.Achieved, q.AchievementLimit
	if ach > 15 {
		ach = 15
	}
	if lim > 15 {
		lim = 15
	}
	v.Counter = byte(lim<<4 | ach)
	npcSeen := map[string]bool{}
	addNPC := func(code string) {
		if code == "" || npcSeen[code] {
			return
		}
		npcSeen[code] = true
		if id := rt.refID(code); id != 0 {
			v.NPCs = append(v.NPCs, id)
		}
	}
	for i, m := range q.Missions {
		count := 0
		if i < len(s.Counts) {
			count = s.Counts[i]
		}
		open := count < quest.Required(m)
		v.Missions = append(v.Missions, quest.MissionView{Index: byte(m.Index), Open: open && s.Status == quest.StatusAchieving,
			Text: m.Text, Values: []uint32{uint32(count)}})
		if open && s.Status == quest.StatusAchieving {
			switch m.Type {
			case quest.MissionDeliverItem:
				addNPC(m.NPC)
			case quest.MissionDialog:
				addNPC(q.CompleteNPC())
			}
		}
	}
	if s.Status == quest.StatusAchievedButNotPaid {
		addNPC(q.CompleteNPC())
	}
	return v
}

func (rt *questRuntime) sendUpdate(sess *gateway.Session, kind byte, q *quest.Quest, s *quest.State) {
	if sess == nil {
		return
	}
	var v *quest.View
	if s != nil && (kind == quest.UpdateAdd || kind == quest.UpdateChange) {
		vv := rt.view(q, s)
		v = &vv
	}
	sess.Send(&proto.Packet{Opcode: quest.OpUpdate, Data: quest.EncodeUpdate(kind, uint32(q.ID), v)})
}

func (rt *questRuntime) persist(ctx context.Context, characterID int64, s *quest.State) {
	if err := rt.deps.Store.Put(ctx, characterID, s.Clone()); err != nil {
		rt.deps.Logger.Warn("quest: saving state failed", "character", characterID, "quest", s.QuestID, "err", err)
	}
}

// questAfterEnter sends the arriving character its quest log and marks.
func questAfterEnter(ctx context.Context, sess *gateway.Session, owned *character.Character) {
	rt := questRT.Load()
	if rt == nil || owned == nil {
		return
	}
	ql, err := rt.logOf(ctx, owned.ID)
	if err != nil {
		rt.deps.Logger.Warn("quest: loading the log failed", "character", owned.ID, "err", err)
		return
	}
	ql.mu.Lock()
	var completed []uint32
	var active []quest.ActiveQuest
	ids := make([]int64, 0, len(ql.log))
	for id := range ql.log {
		ids = append(ids, id)
	}
	sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })
	for _, id := range ids {
		s := ql.log[id]
		q := rt.cat.ByID[id]
		if q == nil {
			continue
		}
		if s.Achieved > 0 {
			completed = append(completed, uint32(id))
		}
		if ql.log.Active(id) {
			active = append(active, quest.ActiveQuest{ID: uint32(id), View: rt.view(q, s)})
		}
	}
	ql.mu.Unlock()
	sess.Send(&proto.Packet{Opcode: quest.OpLog, Data: quest.EncodeLog(completed, active)})
	rt.mu.Lock()
	delete(rt.marks, sess.ID())
	rt.mu.Unlock()
	rt.refreshMarks(ctx, sess, owned.ID, owned.Level)
}

// refreshMarks sends the marks the character's NPCs should carry now, and
// takes away the ones that no longer apply (OURS: retail's server decides
// the marks, GlobalDataManager::FUN_009c75e0 draws what it is sent; which
// rule it uses is not READ -- this one marks a quest to take, one under way
// and one to hand in).
func (rt *questRuntime) refreshMarks(ctx context.Context, sess *gateway.Session, characterID int64, level int) {
	if sess == nil {
		return
	}
	ql, err := rt.logOf(ctx, characterID)
	if err != nil {
		return
	}
	p := playerOf(ctx, rt.deps.Chars, characterID, level)
	want := map[uint32]byte{}
	recs := map[uint32]npcspawn.Record{}
	ql.mu.Lock()
	for npc := range rt.cat.ByNPC {
		mark := byte(0)
		for _, q := range rt.cat.AtNPC(ql.log, npc) {
			s := ql.log[q.ID]
			if s.Status == quest.StatusAchievedButNotPaid && q.CompleteNPC() == npc {
				mark = quest.MarkEnd
				break
			}
			if mark == 0 {
				mark = quest.MarkGoing
			}
		}
		if mark != quest.MarkEnd && len(rt.cat.Offers(p, ql.log, npc)) > 0 {
			mark = quest.MarkStart
		}
		if mark == 0 {
			continue
		}
		for _, r := range rt.npcs(npc) {
			want[r.UID] = mark
			recs[r.UID] = r
		}
	}
	ql.mu.Unlock()
	rt.mu.Lock()
	rt.markLevel[sess.ID()] = p.Level
	sent := rt.marks[sess.ID()]
	if sent == nil {
		sent = map[uint32]byte{}
		rt.marks[sess.ID()] = sent
	}
	var pkts []*proto.Packet
	for uid := range sent {
		if _, ok := want[uid]; !ok {
			pkts = append(pkts, &proto.Packet{Opcode: quest.OpUnmark, Data: npcEntityBytes(uid)})
			delete(sent, uid)
		}
	}
	uids := make([]uint32, 0, len(want))
	for uid := range want {
		uids = append(uids, uid)
	}
	sort.Slice(uids, func(i, j int) bool { return uids[i] < uids[j] })
	for _, uid := range uids {
		m := want[uid]
		if sent[uid] == m {
			continue
		}
		r := recs[uid]
		pkts = append(pkts, &proto.Packet{Opcode: quest.OpMark, Data: quest.EncodeMark(uid, m, r.Region, r.X, r.Y, r.Z)})
		sent[uid] = m
	}
	rt.mu.Unlock()
	for _, pk := range pkts {
		sess.Send(pk)
	}
}

func npcEntityBytes(uid uint32) []byte {
	return []byte{byte(uid), byte(uid >> 8), byte(uid >> 16), byte(uid >> 24)}
}

// questTalkAvailable reports whether npc has quest business with the
// character: the select's id 2 (npcspawn/questtalk.go's per-player filter,
// 0x4c9310, now with real quests).
func questTalkAvailable(ctx context.Context, characterID int64, level int, npc string) bool {
	rt := questRT.Load()
	if rt == nil || npc == "" {
		return false
	}
	ql, err := rt.logOf(ctx, characterID)
	if err != nil {
		return false
	}
	p := playerOf(ctx, rt.deps.Chars, characterID, level)
	ql.mu.Lock()
	defer ql.mu.Unlock()
	return len(rt.cat.Offers(p, ql.log, npc)) > 0 || len(rt.cat.AtNPC(ql.log, npc)) > 0
}

// questTalkOpen answers an opened talk (id 2) at npc: the list page, and
// true; false when the NPC has no quest business with the character.
func questTalkOpen(ctx context.Context, sess *gateway.Session, e world.Entity, entity uint32, npc string) bool {
	rt := questRT.Load()
	if rt == nil || npc == "" {
		return false
	}
	ql, err := rt.logOf(ctx, e.CharacterID)
	if err != nil {
		return false
	}
	p := playerOf(ctx, rt.deps.Chars, e.CharacterID, e.Level)
	ql.mu.Lock()
	var list []talkEntry
	for _, q := range rt.cat.AtNPC(ql.log, npc) {
		list = append(list, talkEntry{questID: q.ID})
	}
	for _, q := range rt.cat.Offers(p, ql.log, npc) {
		list = append(list, talkEntry{questID: q.ID, offer: true})
	}
	ql.mu.Unlock()
	if len(list) == 0 {
		return false
	}
	greeting := ""
	lines := make([]string, 0, len(list))
	for _, t := range list {
		q := rt.cat.ByID[t.questID]
		if greeting == "" {
			greeting = q.MenuText(npc, "BASIC_MENUSTRING_GREETING")
		}
		lines = append(lines, q.TextName)
	}
	if greeting == "" {
		// OURS: the scripts' greeting key is SN_<NPC>_QS (InsertQuestMenuStringList's
		// first pair at every quest NPC), used when none of the listed quests
		// names one at this NPC.
		greeting = "SN_" + npc + "_QS"
	}
	rt.mu.Lock()
	rt.talks[sess.ID()] = &questTalk{npc: npc, entity: entity, stage: talkList, list: list}
	rt.mu.Unlock()
	sess.Send(&proto.Packet{Opcode: quest.OpTalkPage, Data: quest.EncodeTalkPage(quest.PageList, greeting, lines)})
	return true
}

func questPage(sess *gateway.Session, kind byte, text string) {
	sess.Send(&proto.Packet{Opcode: quest.OpTalkPage, Data: quest.EncodeTalkPage(kind, text, nil)})
}

// QuestHandler answers the talk answer (0x70D4 / 0x30D4), the reward
// (0x7515), the give-up (0x70D9) and the window's reward button (0x70D8).
func QuestHandler() gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		rt := questRT.Load()
		if rt == nil {
			return nil
		}
		e, ok := rt.deps.Hub.EntityBySession(sess.ID())
		if !ok {
			return nil
		}
		switch p.Opcode {
		case quest.OpTalkAnswer, quest.OpTalkAnswerAlt:
			if len(p.Data) < 1 {
				return nil
			}
			rt.answer(ctx, sess, e, int(p.Data[0]))
		case quest.OpTakeReward:
			id, chosen, err := quest.DecodeTakeReward(p.Data)
			if err != nil {
				return nil
			}
			rt.takeReward(ctx, sess, e, int64(id), chosen)
		case quest.OpAbandon:
			id, err := quest.DecodeQuestID(p.Data)
			if err != nil {
				return nil
			}
			rt.abandon(ctx, sess, e, int64(id))
		case quest.OpClaim:
			id, err := quest.DecodeQuestID(p.Data)
			if err != nil {
				return nil
			}
			rt.claimFromWindow(ctx, sess, e, int64(id))
		}
		return nil
	}
}

func (rt *questRuntime) talkOf(sess *gateway.Session) *questTalk {
	rt.mu.Lock()
	defer rt.mu.Unlock()
	return rt.talks[sess.ID()]
}

func (rt *questRuntime) answer(ctx context.Context, sess *gateway.Session, e world.Entity, resp int) {
	t := rt.talkOf(sess)
	if t == nil {
		return
	}
	ql, err := rt.logOf(ctx, e.CharacterID)
	if err != nil {
		return
	}
	switch t.stage {
	case talkList:
		i := resp - quest.RespListBase
		if i < 0 || i >= len(t.list) {
			return
		}
		entry := t.list[i]
		q := rt.cat.ByID[entry.questID]
		if entry.offer {
			t.pending, t.stage = q.ID, talkAsk
			questPage(sess, quest.PageYesNo, q.MenuText(t.npc, "BASIC_MENUSTRING_REQUEST_ACCEPT_QUEST"))
			return
		}
		rt.atNPC(ctx, sess, e, t, ql, q)
	case talkAsk:
		q := rt.cat.ByID[t.pending]
		if q == nil {
			return
		}
		t.stage = talkDone
		if resp != quest.RespYes {
			questPage(sess, quest.PageConfirm, q.MenuText(t.npc, "BASIC_MENUSTRING_AT_DENY"))
			return
		}
		rt.accept(ctx, sess, e, t, ql, q)
	}
}

// accept opens q for the character at t's NPC.
func (rt *questRuntime) accept(ctx context.Context, sess *gateway.Session, e world.Entity, t *questTalk, ql *questLog, q *quest.Quest) {
	p := playerOf(ctx, rt.deps.Chars, e.CharacterID, e.Level)
	ql.mu.Lock()
	if r := rt.cat.CanStart(p, ql.log, q, t.npc); r != quest.OK {
		ql.mu.Unlock()
		rt.deps.Logger.Info("quest: refused", "character", e.CharacterID, "quest", q.Code, "why", r.String())
		questPage(sess, quest.PageConfirm, q.MenuText(t.npc, "BASIC_MENUSTRING_AT_DENY"))
		return
	}
	s, give := quest.Start(ql.log, q)
	st := s.Clone()
	ql.mu.Unlock()
	for _, it := range give {
		rt.addItem(ctx, e.CharacterID, it.Code, max(it.Count, 1))
	}
	rt.persist(ctx, e.CharacterID, &st)
	rt.deps.Logger.Info("quest: accepted", "character", e.CharacterID, "quest", q.Code, "id", q.ID, "npc", t.npc)
	rt.sendUpdate(sess, quest.UpdateAdd, q, &st)
	questPage(sess, quest.PageConfirm, q.MenuText(t.npc, "BASIC_MENUSTRING_AT_ACCEPT"))
	rt.refreshMarks(ctx, sess, e.CharacterID, e.Level)
}

// atNPC handles an open quest picked at t's NPC: deliveries and dialogues
// settle, a finished quest opens the reward window, an unfinished one says
// so.
func (rt *questRuntime) atNPC(ctx context.Context, sess *gateway.Session, e world.Entity, t *questTalk, ql *questLog, q *quest.Quest) {
	has := func(code string) int { return rt.countItem(ctx, e.CharacterID, code) }
	ql.mu.Lock()
	progress, take := rt.cat.OnTalk(ql.log, t.npc, has)
	s := ql.log[q.ID]
	var st quest.State
	if s != nil {
		st = s.Clone()
	}
	ql.mu.Unlock()
	for _, it := range take {
		rt.takeItem(ctx, e.CharacterID, it.Code, max(it.Count, 1))
	}
	talked := ""
	for _, pr := range progress {
		ps := ql.snapshot(pr.Quest.ID)
		rt.persist(ctx, e.CharacterID, &ps)
		rt.sendUpdate(sess, quest.UpdateChange, pr.Quest, &ps)
		if pr.Quest.ID == q.ID {
			m := q.Missions[pr.Mission]
			if len(m.Talk) > 0 {
				talked = m.Talk[0]
			}
			st = ps
		}
		rt.deps.Logger.Info("quest: talk mission", "character", e.CharacterID, "quest", pr.Quest.Code, "mission", pr.Mission, "finished", pr.Finished)
	}
	if s == nil {
		return
	}
	if st.Status == quest.StatusAchievedButNotPaid && (q.CompleteNPC() == t.npc) {
		t.pending, t.stage = q.ID, talkReward
		text := q.MenuText(t.npc, "BASIC_MENUSTRING_ACHIEVED")
		if text == "" {
			text = talked
		}
		sess.Send(&proto.Packet{Opcode: quest.OpRewardWindow, Data: quest.EncodeRewardWindow(uint32(q.ID), text)})
		rt.refreshMarks(ctx, sess, e.CharacterID, e.Level)
		return
	}
	t.stage = talkDone
	switch {
	case talked != "":
		questPage(sess, quest.PageConfirm, talked)
	case st.Status == quest.StatusAchievedButNotPaid:
		questPage(sess, quest.PageConfirm, q.MenuText(t.npc, "BASIC_MENUSTRING_MIDDLE_ACHIEVED"))
	default:
		questPage(sess, quest.PageConfirm, q.MenuText(t.npc, "BASIC_MENUSTRING_NOT_ACHIEVED"))
	}
	if len(progress) > 0 {
		rt.refreshMarks(ctx, sess, e.CharacterID, e.Level)
	}
}

func (ql *questLog) snapshot(id int64) quest.State {
	ql.mu.Lock()
	defer ql.mu.Unlock()
	if s := ql.log[id]; s != nil {
		return s.Clone()
	}
	return quest.State{QuestID: id}
}

// claimFromWindow is 0x70D8: the quest window's reward button. INFERRED: it
// opens the reward window for a quest whose missions are done; OURS: only
// when the quest names no complete NPC (otherwise the NPC pays, as the
// scripts' ACHIEVED lines say), refused {2, 1} otherwise.
func (rt *questRuntime) claimFromWindow(ctx context.Context, sess *gateway.Session, e world.Entity, id int64) {
	q := rt.cat.ByID[id]
	ql, err := rt.logOf(ctx, e.CharacterID)
	if q == nil || err != nil {
		sess.Send(&proto.Packet{Opcode: quest.OpClaimResult, Data: quest.EncodeFailWord(1)})
		return
	}
	st := ql.snapshot(id)
	if st.Status != quest.StatusAchievedButNotPaid || len(q.CompleteNPCs) > 0 {
		sess.Send(&proto.Packet{Opcode: quest.OpClaimResult, Data: quest.EncodeFailWord(1)})
		return
	}
	sess.Send(&proto.Packet{Opcode: quest.OpClaimResult, Data: quest.EncodeOKID(uint32(id))})
	rt.mu.Lock()
	rt.talks[sess.ID()] = &questTalk{stage: talkReward, pending: id}
	rt.mu.Unlock()
	sess.Send(&proto.Packet{Opcode: quest.OpRewardWindow, Data: quest.EncodeRewardWindow(uint32(id), q.TextPayCon)})
}

// takeReward is 0x7515: the reward window's take. The quest must be the one
// the window was opened for, done and unpaid.
func (rt *questRuntime) takeReward(ctx context.Context, sess *gateway.Session, e world.Entity, id int64, chosen []uint32) {
	fail := func() {
		sess.Send(&proto.Packet{Opcode: quest.OpTakeRewardResult, Data: quest.EncodeFailByte(quest.RewardError)})
	}
	t := rt.talkOf(sess)
	q := rt.cat.ByID[id]
	if t == nil || t.stage != talkReward || t.pending != id || q == nil {
		fail()
		return
	}
	ql, err := rt.logOf(ctx, e.CharacterID)
	if err != nil {
		fail()
		return
	}
	// The items first: a full bag refuses the reward and keeps the quest
	// (the scripts' BASIC_MENUSTRING_INVENTORY_FULL line).
	items := rewardItems(q, chosen, func(code string) int64 { return rt.itemID(ctx, code) })
	if !rt.roomFor(ctx, e.CharacterID, len(items)) {
		if text := q.MenuText(t.npc, "BASIC_MENUSTRING_INVENTORY_FULL"); text != "" {
			questPage(sess, quest.PageConfirm, text)
		}
		fail()
		return
	}
	ql.mu.Lock()
	ok, take := quest.Claim(ql.log, q, t.npc)
	var st quest.State
	if ok {
		st = ql.log[q.ID].Clone()
	}
	ql.mu.Unlock()
	if !ok {
		fail()
		return
	}
	t.stage = talkDone
	for _, it := range take {
		rt.takeItem(ctx, e.CharacterID, it.Code, -1)
	}
	rt.persist(ctx, e.CharacterID, &st)
	rt.pay(ctx, sess, e, q, items)
	rt.sendUpdate(sess, quest.UpdateDropped, q, nil)
	sess.Send(&proto.Packet{Opcode: quest.OpTakeRewardResult, Data: []byte{1}})
	rt.refreshMarks(ctx, sess, e.CharacterID, e.Level)
}

// rewardItems picks the items to give: every reward item, or, when the
// client chose some, the chosen ones that are reward items (OURS: the
// choice block of refqusetreward cols 6-10 is not READ).
func rewardItems(q *quest.Quest, chosen []uint32, idOf func(string) int64) []quest.RewardItem {
	if len(chosen) == 0 {
		return q.Reward.Items
	}
	want := map[int64]bool{}
	for _, c := range chosen {
		want[int64(c)] = true
	}
	var out []quest.RewardItem
	for _, it := range q.Reward.Items {
		if want[idOf(it.Code)] {
			out = append(out, it)
		}
	}
	if len(out) == 0 {
		return q.Reward.Items
	}
	return out
}

// pay grants q's reward: gold, EXP and skill EXP (with a level-up), SP and
// items, each through the paths a kill and a pick-up use.
func (rt *questRuntime) pay(ctx context.Context, sess *gateway.Session, e world.Entity, q *quest.Quest, items []quest.RewardItem) {
	r := q.Reward
	id := e.CharacterID
	log := rt.deps.Logger
	if r.Gold > 0 && rt.deps.Chars != nil {
		if err := rt.deps.Chars.AddGold(ctx, id, r.Gold); err != nil {
			log.Warn("quest: paying gold failed", "character", id, "quest", q.Code, "err", err)
		} else {
			tellGold(ctx, rt.deps.Chars, rt.deps.Hub, id, true)
		}
	}
	if (r.Exp > 0 || r.SPExp > 0) && rt.deps.Chars != nil {
		rt.payExp(ctx, sess, e, r.Exp, r.SPExp)
	}
	if r.SkillPoint > 0 && rt.deps.Skills != nil {
		if _, err := rt.deps.Skills.AddSkillPoints(ctx, id, int(r.SkillPoint)); err != nil {
			log.Warn("quest: paying SP failed", "character", id, "quest", q.Code, "err", err)
		}
	}
	var given []string
	for _, it := range items {
		if rt.addItem(ctx, id, it.Code, max(it.Count, 1)) {
			given = append(given, fmt.Sprintf("%s x%d", it.Code, max(it.Count, 1)))
		}
	}
	log.Info("quest: completed and paid", "character", id, "quest", q.Code, "id", q.ID,
		"gold", r.Gold, "exp", r.Exp, "spexp", r.SPExp, "sp", r.SkillPoint, "items", given, "fromTable", r.FromTable)
}

// payExp applies a quest's EXP as GainExpAndLevel does for a kill
// (killshare.go payAward): skill EXP first, then the EXP with its level-up,
// and the 0x3056 notice.
func (rt *questRuntime) payExp(ctx context.Context, sess *gateway.Session, e world.Entity, exp, sp int64) {
	id := e.CharacterID
	if rt.deps.Skills != nil && sp > 0 {
		if _, _, err := rt.deps.Skills.AddSkillExp(ctx, id, sp); err != nil {
			rt.deps.Logger.Warn("quest: paying skill EXP failed", "character", id, "err", err)
		}
	}
	if !levelTable.Loaded() || exp <= 0 {
		sendExpGainTo(sess, charmsg.ExpGain{Exp: 0, SkillExp: sp})
		return
	}
	unlock := character.LockLeveling(id)
	char, err := rt.deps.Chars.GetByID(ctx, id)
	if err != nil {
		unlock()
		return
	}
	newLevel, newExp, gained := levelTable.Advance(char.Level, char.Exp, exp)
	newStatPoints := char.StatPoints + gained*leveldata.StatPointsPerLevel
	newStr := char.Str + gained*character.StatGrowthPerLevel
	newInt := char.Int + gained*character.StatGrowthPerLevel
	if err := rt.deps.Chars.SetLeveling(ctx, id, newLevel, newExp, newStatPoints, newStr, newInt); err != nil {
		unlock()
		rt.deps.Logger.Warn("quest: paying EXP failed", "character", id, "err", err)
		return
	}
	var lu *LevelUp
	if gained > 0 {
		if rt.deps.Hub != nil {
			rt.deps.Hub.SetLevel(id, newLevel)
		}
		rt.deps.Chars.ResetHP(ctx, id)
		bonus := character.BonusOf(id)
		if rt.deps.MP != nil {
			rt.deps.MP.Refill(id, character.MaxMPFor(newInt+bonus.Int, newLevel)+bonus.MP)
		}
		lu = &LevelUp{NewLevel: int32(newLevel), StatPoints: int32(newStatPoints)}
	}
	unlock()
	g := charmsg.ExpGain{Exp: exp, SkillExp: sp}
	if lu != nil {
		sess.Send(&proto.Packet{Opcode: OpLevelUp, Data: lu.Encode()})
		g.LevelUp = true
		g.StatPoints = uint16(lu.StatPoints)
	}
	sendExpGainTo(sess, g)
}

// abandon is 0x70D9.
func (rt *questRuntime) abandon(ctx context.Context, sess *gateway.Session, e world.Entity, id int64) {
	q := rt.cat.ByID[id]
	ql, err := rt.logOf(ctx, e.CharacterID)
	if q == nil || err != nil {
		sess.Send(&proto.Packet{Opcode: quest.OpAbandonResult, Data: quest.EncodeFailByte(quest.AbandonNotAllowed)})
		return
	}
	ql.mu.Lock()
	active := ql.log.Active(id)
	var take []quest.ItemCount
	if active {
		take = quest.Abandon(ql.log, q)
	}
	s := ql.log[id]
	var st quest.State
	if s != nil {
		st = s.Clone()
	}
	ql.mu.Unlock()
	if !active {
		sess.Send(&proto.Packet{Opcode: quest.OpAbandonResult, Data: quest.EncodeFailByte(quest.AbandonNotAllowed)})
		return
	}
	for _, it := range take {
		rt.takeItem(ctx, e.CharacterID, it.Code, -1)
	}
	if s == nil {
		rt.deps.Store.Delete(ctx, e.CharacterID, id)
	} else {
		rt.persist(ctx, e.CharacterID, &st)
	}
	rt.deps.Logger.Info("quest: given up", "character", e.CharacterID, "quest", q.Code)
	sess.Send(&proto.Packet{Opcode: quest.OpAbandonResult, Data: quest.EncodeOKID(uint32(id))})
	rt.sendUpdate(sess, quest.UpdateRemove, q, nil)
	rt.refreshMarks(ctx, sess, e.CharacterID, e.Level)
}

// questOnKill credits characterID's kill of monster: kill counts and
// gather drops (the drop goes into the bag; a full bag drops nothing and
// counts nothing -- OURS).
func questOnKill(ctx context.Context, sess *gateway.Session, characterID int64, monster combat.Monster) {
	rt := questRT.Load()
	if rt == nil || monster.CodeName == "" {
		return
	}
	ql, err := rt.logOf(ctx, characterID)
	if err != nil {
		return
	}
	ql.mu.Lock()
	progress := rt.cat.OnKill(ql.log, monster.CodeName, rt.roll)
	ql.mu.Unlock()
	if len(progress) == 0 {
		// A level-up by this kill opens quests: the marks follow (OURS).
		if sess != nil && rt.deps.Hub != nil {
			if e, ok := entityOf(rt.deps.Hub, characterID); ok {
				rt.mu.Lock()
				lv, had := rt.markLevel[sess.ID()]
				rt.mu.Unlock()
				if had && lv != e.Level {
					rt.refreshMarks(ctx, sess, characterID, e.Level)
				}
			}
		}
		return
	}
	changed := map[int64]*quest.Quest{}
	finished := false
	for _, pr := range progress {
		if pr.Item != "" && !rt.addItem(ctx, characterID, pr.Item, 1) {
			ql.mu.Lock()
			if s := ql.log[pr.Quest.ID]; s != nil {
				s.Counts[pr.Mission]--
				if pr.Finished {
					s.Status = quest.StatusAchieving
				}
			}
			ql.mu.Unlock()
			continue
		}
		changed[pr.Quest.ID] = pr.Quest
		finished = finished || pr.Finished
		rt.deps.Logger.Info("quest: progress", "character", characterID, "quest", pr.Quest.Code, "mission", pr.Mission,
			"count", pr.Count, "of", quest.Required(pr.Quest.Missions[pr.Mission]), "monster", monster.CodeName, "item", pr.Item, "finished", pr.Finished)
	}
	ids := make([]int64, 0, len(changed))
	for id := range changed {
		ids = append(ids, id)
	}
	sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })
	for _, id := range ids {
		st := ql.snapshot(id)
		rt.persist(ctx, characterID, &st)
		rt.sendUpdate(sess, quest.UpdateChange, changed[id], &st)
	}
	if finished {
		level := 0
		if rt.deps.Hub != nil {
			if e, ok := entityOf(rt.deps.Hub, characterID); ok {
				level = e.Level
			}
		}
		rt.refreshMarks(ctx, sess, characterID, level)
	}
}

func (rt *questRuntime) itemID(ctx context.Context, code string) int64 {
	if rt.deps.Items == nil || code == "" {
		return 0
	}
	it, err := rt.deps.Items.GetItemByCode(ctx, code)
	if err != nil || it == nil {
		return 0
	}
	return it.ID
}

// addItem puts count of code in the bag; false when it cannot.
func (rt *questRuntime) addItem(ctx context.Context, characterID int64, code string, count int) bool {
	id := rt.itemID(ctx, code)
	if id == 0 || rt.deps.Inv == nil {
		rt.deps.Logger.Warn("quest: item not in the item table, not given", "item", code)
		return false
	}
	if err := rt.deps.Inv.AddItem(ctx, characterID, id, count); err != nil {
		rt.deps.Logger.Info("quest: item not given", "character", characterID, "item", code, "err", err)
		return false
	}
	return true
}

func (rt *questRuntime) countItem(ctx context.Context, characterID int64, code string) int {
	id := rt.itemID(ctx, code)
	if id == 0 || rt.deps.Inv == nil {
		return 0
	}
	slots, err := rt.deps.Inv.List(ctx, characterID)
	if err != nil {
		return 0
	}
	n := 0
	for _, s := range slots {
		if s.ItemID == id {
			n += s.Quantity
		}
	}
	return n
}

// takeItem removes count of code from the bag (-1: all of it).
func (rt *questRuntime) takeItem(ctx context.Context, characterID int64, code string, count int) {
	id := rt.itemID(ctx, code)
	if id == 0 || rt.deps.Inv == nil {
		return
	}
	slots, err := rt.deps.Inv.List(ctx, characterID)
	if err != nil {
		return
	}
	for _, s := range slots {
		if count == 0 {
			return
		}
		if s.ItemID != id {
			continue
		}
		n := s.Quantity
		if count > 0 && n > count {
			n = count
		}
		if err := rt.deps.Inv.RemoveItem(ctx, characterID, s.Index, n); err != nil {
			return
		}
		if count > 0 {
			count -= n
		}
	}
}

// roomFor reports whether the bag has n free slots.
func (rt *questRuntime) roomFor(ctx context.Context, characterID int64, n int) bool {
	if n == 0 || rt.deps.Inv == nil {
		return true
	}
	slots, err := rt.deps.Inv.List(ctx, characterID)
	if err != nil {
		return false
	}
	return rt.deps.Inv.Capacity()-len(slots) >= n
}
