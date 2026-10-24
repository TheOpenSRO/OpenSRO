package session

import (
	"encoding/binary"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/npctalk"
	"github.com/TheOpenSRO/OpenSRO/server/internal/party"
	"github.com/TheOpenSRO/OpenSRO/server/internal/quest"
)

// Round 819: the quest conversation as the original's (CBasicQuest's
// s:0x920110, READ): list pages with SN_TALK_COMMON_* lines, the closing
// pages' OK ending the talk, and its refusals.

// quest819Catalog is the test catalogue with one more quest, QT_SOLO, that
// the round's cases reshape.
func quest819Catalog(shape func(*quest.Quest)) *quest.Catalog {
	base := testQuestCatalog()
	solo := &quest.Quest{ID: 904, Code: "QT_SOLO", Level: 1, Source: quest.SourceScript, Race: -1, TextName: "SN_QT_SOLO",
		StartNPCs: []string{"NPC_T_GIVER"}, CompleteNPCs: []string{"NPC_T_GIVER"},
		Missions: []quest.Mission{{Index: 0, Type: quest.MissionKillMonster, Text: "SN_CON_QT_SOLO", Targets: []string{"MOB_S"}, Count: 1, MonsterClass: -1}},
		Menus: map[string][]quest.MenuText{"NPC_T_GIVER": {
			{Key: "BASIC_MENUSTRING_REQUEST_ACCEPT_QUEST", Text: "SN_TALK_QT_SOLO_01"},
			{Key: "BASIC_MENUSTRING_AT_DENY", Text: "SN_TALK_QT_SOLO_03"},
			{Key: "BASIC_MENUSTRING_COUNT_LIMIT", Text: "SN_TALK_QT_SOLO_LIMIT"},
			{Key: "BASIC_MENUSTRING_ACCEPT_AFTER_ONE_CLEAR", Text: "SN_TALK_QT_SOLO_AGAIN"},
			{Key: "BASIC_MENUSTRING_NOT_PARTY", Text: "SN_TALK_QT_SOLO_PARTY"},
		}},
	}
	if shape != nil {
		shape(solo)
	}
	qs := []*quest.Quest{solo}
	for _, q := range base.ByID {
		qs = append(qs, q)
	}
	return quest.NewCatalog(qs)
}

// pickSolo opens the giver's list and picks QT_SOLO: the page it answers.
func (w *reviewQuestWorld) pickSolo(t *testing.T) (string, []string) {
	t.Helper()
	pg := w.openTalk(t)
	_, rest := readString(pg[1:])
	n := int(rest[0])
	rest = rest[1:]
	pick := -1
	for i := 0; i < n; i++ {
		var line string
		line, rest = readString(rest)
		if line == "SN_QT_SOLO" {
			pick = i
		}
	}
	if pick < 0 {
		t.Fatalf("QT_SOLO is not on the list % x", pg)
	}
	w.cl.send(quest.OpTalkAnswer, []byte{byte(quest.RespListBase + pick)})
	return pageOf(t, w.cl.next(quest.OpTalkPage).Data)
}

func pageOf(t *testing.T, pg []byte) (string, []string) {
	t.Helper()
	if pg[0] != quest.PageList {
		t.Fatalf("page type %d, want the list page (4): % x", pg[0], pg)
	}
	text, rest := readString(pg[1:])
	var lines []string
	n := int(rest[0])
	rest = rest[1:]
	for i := 0; i < n; i++ {
		var l string
		l, rest = readString(rest)
		lines = append(lines, l)
	}
	return text, lines
}

func TestQuest819RefuseEndsOnOK(t *testing.T) {
	w := startQuestWorld(t, quest.NewMemStore(), quest819Catalog(nil), nil)
	text, lines := w.pickSolo(t)
	if text != "SN_TALK_QT_SOLO_01" || len(lines) != 2 || lines[0] != quest.LineAccept || lines[1] != quest.LineDeny {
		t.Fatalf("offer %q %q", text, lines)
	}
	w.cl.send(quest.OpTalkAnswer, []byte{quest.RespDeny})
	text, lines = pageOf(t, w.cl.next(quest.OpTalkPage).Data)
	if text != "SN_TALK_QT_SOLO_03" || len(lines) != 1 || lines[0] != quest.LineOK {
		t.Fatalf("refused %q %q", text, lines)
	}
	// The OK ends the talk; nothing was taken, so no notice.
	w.cl.send(quest.OpTalkAnswer, []byte{quest.RespListBase})
	if end := w.cl.next(npctalk.OpEndResult).Data; end[0] != 1 {
		t.Fatalf("end % x", end)
	}
	w.cl.none(quest.OpEventMessage)
	ql, _ := questRT.Load().logOf(w.ctx, w.id)
	if ql.log.Active(904) {
		t.Fatal("a refused quest was started")
	}
}

func TestQuest819PartyOnly(t *testing.T) {
	parties := party.NewHub()
	w := startQuestWorld(t, quest.NewMemStore(), quest819Catalog(func(q *quest.Quest) { q.DivideType = 1 }), parties)
	// Alone: NOT_PARTY, with OK.
	text, lines := w.pickSolo(t)
	if text != "SN_TALK_QT_SOLO_PARTY" || len(lines) != 1 || lines[0] != quest.LineOK {
		t.Fatalf("alone %q %q", text, lines)
	}
	w.cl.send(quest.OpTalkAnswer, []byte{quest.RespListBase})
	w.cl.next(npctalk.OpEndResult)
	// A party sharing EXP but not items: still NOT_PARTY (s:0x9261d0 tests both bits).
	if _, err := parties.Form(party.Member{CharacterID: w.id, Name: "Aria", Level: 30},
		party.Member{CharacterID: w.id + 1000, Name: "Bea", Level: 30}, party.FlagExpShare); err != nil {
		t.Fatal(err)
	}
	if text, _ := w.pickSolo(t); text != "SN_TALK_QT_SOLO_PARTY" {
		t.Fatalf("EXP share only %q", text)
	}
	w.cl.send(quest.OpTalkAnswer, []byte{quest.RespListBase})
	w.cl.next(npctalk.OpEndResult)
	_, _ = parties.Remove(w.id+1000, 0)
	_, _ = parties.Remove(w.id, 0)
	if _, err := parties.Form(party.Member{CharacterID: w.id, Name: "Aria", Level: 30},
		party.Member{CharacterID: w.id + 1000, Name: "Bea", Level: 30}, party.FlagExpShare|party.FlagItemShare); err != nil {
		t.Fatal(err)
	}
	if text, lines := w.pickSolo(t); text != "SN_TALK_QT_SOLO_01" || len(lines) != 2 {
		t.Fatalf("both shared %q %q", text, lines)
	}
}

func TestQuest819RepeatLimitAndAfterOneClear(t *testing.T) {
	store := quest.NewMemStore()
	w := startQuestWorld(t, store, quest819Catalog(func(q *quest.Quest) {
		q.ConditionMask |= quest.CondRealTime
		q.AchievementLimit = 2
		q.DifferentString = true
	}), nil)
	ql, _ := questRT.Load().logOf(w.ctx, w.id)
	// Cleared once: offered again, with the after-one-clear text.
	ql.mu.Lock()
	ql.log[904] = &quest.State{QuestID: 904, Status: quest.StatusAchieved, Achieved: 1}
	ql.mu.Unlock()
	if text, lines := w.pickSolo(t); text != "SN_TALK_QT_SOLO_AGAIN" || len(lines) != 2 {
		t.Fatalf("after one clear %q %q", text, lines)
	}
	w.cl.send(npctalk.OpEnd, npctalk.EncodeEntity(w.giver.UID))
	w.cl.next(npctalk.OpEndResult)
	// At its limit the offer, if picked, says COUNT_LIMIT. The list's own
	// rule is OPEN; here the quest is put on the list by hand.
	ql.mu.Lock()
	ql.log[904].Achieved = 2
	ql.mu.Unlock()
	w.openTalk(t)
	rt := questRT.Load()
	rt.mu.Lock()
	tk := rt.talks[mustSession(t, w).ID()]
	tk.list = []talkEntry{{questID: 904, offer: true}}
	rt.mu.Unlock()
	w.cl.send(quest.OpTalkAnswer, []byte{quest.RespListBase})
	if text, lines := pageOf(t, w.cl.next(quest.OpTalkPage).Data); text != "SN_TALK_QT_SOLO_LIMIT" || len(lines) != 1 {
		t.Fatalf("at the limit %q %q", text, lines)
	}
}

func TestQuest819MaxQuestLine(t *testing.T) {
	w := startQuestWorld(t, quest.NewMemStore(), quest819Catalog(nil), nil)
	ql, _ := questRT.Load().logOf(w.ctx, w.id)
	ql.mu.Lock()
	for i := int64(0); i < quest.MaxQuests; i++ {
		ql.log[5000+i] = &quest.State{QuestID: 5000 + i, Status: quest.StatusAchieving}
	}
	// Not counted: an id over 10000, a status 4, 5 or 6.
	ql.log[20000] = &quest.State{QuestID: 20000, Status: quest.StatusAchieving}
	ql.log[6000] = &quest.State{QuestID: 6000, Status: quest.StatusLockedByAbort}
	if n := heldQuests(ql.log); n != quest.MaxQuests {
		ql.mu.Unlock()
		t.Fatalf("held %d", n)
	}
	ql.mu.Unlock()
	_, lines := w.pickSolo(t)
	if len(lines) != 2 || lines[0] != quest.LineMaxQuest || lines[1] != quest.LineDeny {
		t.Fatalf("at 33 quests %q", lines)
	}
	// The line still accepts (nothing else reads the count, s:0x4ec930).
	w.cl.send(quest.OpTalkAnswer, []byte{quest.RespAccept})
	if up := w.cl.next(quest.OpUpdate).Data; up[0] != quest.UpdateAdd {
		t.Fatalf("add % x", up)
	}
}

func TestQuest819UpdateHeader(t *testing.T) {
	w := startQuestWorld(t, quest.NewMemStore(), quest819Catalog(func(q *quest.Quest) { q.DivideType = 5 }), nil)
	w.pickSolo(t)
	w.cl.send(quest.OpTalkAnswer, []byte{quest.RespAccept})
	up := w.cl.next(quest.OpUpdate).Data
	// kind, u32 id, counter, divide type (+9), flags, status, n missions, then
	// the first mission's index.
	if up[0] != quest.UpdateAdd || binary.LittleEndian.Uint32(up[1:]) != 904 {
		t.Fatalf("add % x", up)
	}
	if up[6] != 5 {
		t.Fatalf("the divide byte %d, want 5", up[6])
	}
	if up[9] != 1 || up[10] != 1 {
		t.Fatalf("missions %d, first index %d (want the mission's +1)", up[9], up[10])
	}
}

func TestQuest819InventoryFull(t *testing.T) {
	w := startReviewQuestWorld(t, quest.NewMemStore())
	ql, _ := questRT.Load().logOf(w.ctx, w.id)
	ql.mu.Lock()
	ql.log[901] = &quest.State{QuestID: 901, Status: quest.StatusAchievedButNotPaid, Counts: []int{2, 1}}
	ql.mu.Unlock()
	for slot := 0; slot < 200; slot++ {
		if !fillOneSlot(w, slot) {
			break
		}
	}
	w.openTalk(t)
	w.cl.send(quest.OpTalkAnswer, []byte{quest.RespListBase})
	text, lines := pageOf(t, w.cl.next(quest.OpTalkPage).Data)
	if len(lines) != 1 || lines[0] != quest.LineOK {
		t.Fatalf("full bag %q %q", text, lines)
	}
	w.cl.none(quest.OpRewardWindow)
}

func mustSession(t *testing.T, w *reviewQuestWorld) interface{ ID() uint64 } {
	t.Helper()
	e, ok := w.hub.FindByName("Aria")
	if !ok {
		t.Fatal("no Aria")
	}
	return e.Session
}

// fillOneSlot puts a prize (stack 1) into the bag; false once it is full.
func fillOneSlot(w *reviewQuestWorld, _ int) bool {
	return questRT.Load().addItem(w.ctx, w.id, "ITEM_T_PRIZE", 1)
}

// A party-only quest's kills count only in a party sharing EXP and items
// (s:0x9210a0 runs the party check before any mission).
func TestQuest819PartyOnlyKills(t *testing.T) {
	parties := party.NewHub()
	w := startQuestWorld(t, quest.NewMemStore(), quest819Catalog(func(q *quest.Quest) { q.DivideType = 1 }), parties)
	ql, _ := questRT.Load().logOf(w.ctx, w.id)
	ql.mu.Lock()
	ql.log[904] = &quest.State{QuestID: 904, Status: quest.StatusAchieving, Counts: []int{0}}
	ql.mu.Unlock()
	e, _ := w.hub.FindByName("Aria")
	mob := combat.Monster{ID: 1, CodeName: "MOB_S"}
	questOnKill(w.ctx, e.Session, w.id, mob)
	w.cl.none(quest.OpUpdate)
	if _, err := parties.Form(party.Member{CharacterID: w.id, Name: "Aria", Level: 30},
		party.Member{CharacterID: w.id + 1000, Name: "Bea", Level: 30}, party.FlagExpShare|party.FlagItemShare); err != nil {
		t.Fatal(err)
	}
	questOnKill(w.ctx, e.Session, w.id, mob)
	if up := w.cl.next(quest.OpUpdate).Data; up[0] != quest.UpdateChange {
		t.Fatalf("change % x", up)
	}
}
