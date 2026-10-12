package session

import (
	"bufio"
	"context"
	"encoding/binary"
	"testing"

	"github.com/OpenSRO/OpenSRO/server/internal/account"
	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/combat"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
	"github.com/OpenSRO/OpenSRO/server/internal/npcspawn"
	"github.com/OpenSRO/OpenSRO/server/internal/npctalk"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/quest"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
	"github.com/OpenSRO/OpenSRO/server/internal/trade"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// Round 785: a quest over a real socket, end to end -- the NPC offers it on
// the talk page, the player accepts, kills and gathers count, the NPC opens
// the reward window, the reward is paid (gold, items) and the quest leaves
// the log; another quest is given up. The quests are made up (no retail data
// is a fixture); their shape is the server script's.

func testQuestCatalog() *quest.Catalog {
	q := &quest.Quest{ID: 901, Code: "QT_HUNT", Level: 1, Source: quest.SourceScript, Race: -1, TextName: "SN_QT_HUNT",
		StartNPCs: []string{"NPC_T_GIVER"}, CompleteNPCs: []string{"NPC_T_GIVER"}, AchievementLimit: 1,
		Missions: []quest.Mission{
			{Index: 0, Type: quest.MissionKillMonster, Text: "SN_CON_QT_HUNT", Targets: []string{"MOB_T"}, Count: 2, MonsterClass: -1},
			{Index: 1, Type: quest.MissionGatherFromMonster, Text: "SN_CON_QT_HUNT1", Targets: []string{"MOB_T"}, Rates: []float64{100},
				Count: 1, Item: "ITEM_T_PELT", NPC: "NPC_T_GIVER", MonsterClass: -1},
		},
		Menus: map[string][]quest.MenuText{"NPC_T_GIVER": {
			{Key: "BASIC_MENUSTRING_GREETING", Text: "SN_NPC_T_GIVER_QS"},
			{Key: "BASIC_MENUSTRING_REQUEST_ACCEPT_QUEST", Text: "SN_TALK_QT_HUNT_01"},
			{Key: "BASIC_MENUSTRING_AT_ACCEPT", Text: "SN_TALK_QT_HUNT_02"},
			{Key: "BASIC_MENUSTRING_AT_DENY", Text: "SN_TALK_QT_HUNT_03"},
			{Key: "BASIC_MENUSTRING_NOT_ACHIEVED", Text: "SN_TALK_QT_HUNT_04"},
			{Key: "BASIC_MENUSTRING_ACHIEVED", Text: "SN_TALK_QT_HUNT_06"},
		}},
		Reward: quest.Reward{Gold: 100, Items: []quest.RewardItem{{Code: "ITEM_T_PRIZE", Count: 1}}, FromTable: true},
	}
	other := &quest.Quest{ID: 902, Code: "QT_OTHER", Level: 1, Source: quest.SourceScript, Race: -1, TextName: "SN_QT_OTHER",
		StartNPCs: []string{"NPC_T_GIVER"}, CompleteNPCs: []string{"NPC_T_GIVER"},
		Missions: []quest.Mission{{Index: 0, Type: quest.MissionKillMonster, Text: "SN_CON_QT_OTHER", Targets: []string{"MOB_U"}, Count: 1, MonsterClass: -1}},
		Menus:    map[string][]quest.MenuText{"NPC_T_GIVER": {{Key: "BASIC_MENUSTRING_REQUEST_ACCEPT_QUEST", Text: "SN_TALK_QT_OTHER_01"}}},
	}
	high := &quest.Quest{ID: 903, Code: "QT_HIGH", Level: 50, Source: quest.SourceScript, Race: -1, TextName: "SN_QT_HIGH",
		StartNPCs: []string{"NPC_T_GIVER"}, Missions: []quest.Mission{{Type: quest.MissionKillMonster, Targets: []string{"MOB_T"}, Count: 1}}}
	return quest.NewCatalog([]*quest.Quest{q, other, high})
}

func readString(b []byte) (string, []byte) {
	n := int(binary.LittleEndian.Uint16(b))
	return string(b[2 : 2+n]), b[2+n:]
}

func TestQuestTalkKillRewardFlow(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	chars := character.NewMemStore()
	accounts.Add("Aria", "pw")
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatal(err)
	}
	ref := refdata.NewMemStore()
	ref.ImportItems(ctx, []refdata.Item{{ID: 7001, CodeName: "ITEM_T_PELT", MaxStack: 50}, {ID: 7002, CodeName: "ITEM_T_PRIZE", MaxStack: 1}})
	inv := inventory.NewMemStore(ref)
	store := quest.NewMemStore()
	hub := world.NewHub()
	giver := npcAt(7, 100, 0, npcspawn.FromNest)
	giver.Code = "NPC_T_GIVER"
	giver.Flags, giver.Interact = npcspawn.FlagInteractions, []byte{1}
	installNPCsForTest(t, giver)
	InstallQuests(testQuestCatalog(), QuestDeps{Store: store, Chars: chars, Inv: inv, Items: ref, Hub: hub})
	t.Cleanup(func() { InstallQuests(nil, QuestDeps{}); ForgetNPCInteraction(1); ForgetQuestSession(1) })

	handle := gateway.Chain(LoginHandler(accounts), WorldHandler(chars, nil, hub), NPCTalkHandler(hub, trade.NewHub()), QuestHandler())
	srv := &gateway.Server{Addr: freeAddr(t), Handle: handle}
	sctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go srv.ListenAndServe(sctx)
	conn := dialTestServer(t, srv.Addr)
	t.Cleanup(func() { conn.Close() })
	cl := &chatClient{t: t, conn: conn, r: bufio.NewReader(conn)}
	cl.send(OpLogin, (&LoginRequest{Username: "Aria", Password: "pw"}).Encode())
	cl.next(OpLoginResult)
	cl.send(OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode())
	cl.next(OpEnterWorldResult)
	// The log: nothing completed, nothing open.
	if got := cl.next(quest.OpLog).Data; string(got) != string([]byte{0, 0, 0, 0}) {
		t.Fatalf("log % x", got)
	}
	// The giver carries the start mark.
	mark := cl.next(quest.OpMark).Data
	if binary.LittleEndian.Uint32(mark) != giver.UID || mark[5] != quest.MarkStart {
		t.Fatalf("mark % x", mark)
	}
	e, _ := hub.FindByName("Aria")
	if e.Zone != "jangan" {
		t.Skipf("the test NPC stands in the jangan frame; the world put Aria in %q", e.Zone)
	}
	hub.Relocate(e.Session, world.Position{X: 50, Z: 0}, world.MoveRelocate, 0)

	// The select offers talk (2) now: the NPC has a quest for Aria.
	cl.send(npctalk.OpSelect, npctalk.EncodeEntity(giver.UID))
	sel, err := npctalk.DecodeSelectNPC(cl.next(npctalk.OpSelectResult).Data)
	if err != nil || string(sel.IDs) != string([]byte{1, 2}) {
		t.Fatalf("select %+v %v", sel, err)
	}
	cl.send(npctalk.OpOpen, npctalk.EncodeOpen(giver.UID, npctalk.IDTalk))
	cl.next(npctalk.OpOpenResult)
	pg := cl.next(quest.OpTalkPage).Data
	if pg[0] != quest.PageList {
		t.Fatalf("page % x", pg)
	}
	greet, rest := readString(pg[1:])
	if greet != "SN_NPC_T_GIVER_QS" || rest[0] != 2 { // QT_HUNT and QT_OTHER; QT_HIGH is level 50
		t.Fatalf("list %q % x", greet, rest)
	}
	first, _ := readString(rest[1:])
	if first != "SN_QT_HUNT" {
		t.Fatalf("first line %q", first)
	}
	cl.send(quest.OpTalkAnswer, []byte{quest.RespListBase})
	pg = cl.next(quest.OpTalkPage).Data
	if txt, _ := readString(pg[1:]); pg[0] != quest.PageYesNo || txt != "SN_TALK_QT_HUNT_01" {
		t.Fatalf("ask % x", pg)
	}
	cl.send(quest.OpTalkAnswer, []byte{quest.RespYes})
	up := cl.next(quest.OpUpdate).Data
	if up[0] != quest.UpdateAdd || binary.LittleEndian.Uint32(up[1:]) != 901 {
		t.Fatalf("add % x", up)
	}
	pg = cl.next(quest.OpTalkPage).Data
	if txt, _ := readString(pg[1:]); txt != "SN_TALK_QT_HUNT_02" {
		t.Fatalf("accept text %q", txt)
	}
	cl.send(npctalk.OpEnd, npctalk.EncodeEntity(giver.UID))
	cl.next(npctalk.OpEndResult)

	// Two kills: the kill count, and the pelt drops (rate 100) on the first.
	mob := combat.Monster{ID: 1, CodeName: "MOB_T"}
	questOnKill(ctx, e.Session, c.ID, mob)
	up = cl.next(quest.OpUpdate).Data
	if up[0] != quest.UpdateChange {
		t.Fatalf("change % x", up)
	}
	questOnKill(ctx, e.Session, c.ID, mob)
	cl.next(quest.OpUpdate)
	st, _ := store.States(ctx, c.ID)
	if len(st) != 1 || st[0].Status != quest.StatusAchievedButNotPaid || st[0].Counts[0] != 2 || st[0].Counts[1] != 1 {
		t.Fatalf("state %+v", st)
	}
	slots, _ := inv.List(ctx, c.ID)
	if len(slots) != 1 || slots[0].ItemID != 7001 {
		t.Fatalf("the pelt %+v", slots)
	}

	// Back at the giver: the reward window, then the reward.
	cl.send(npctalk.OpSelect, npctalk.EncodeEntity(giver.UID))
	cl.next(npctalk.OpSelectResult)
	cl.send(npctalk.OpOpen, npctalk.EncodeOpen(giver.UID, npctalk.IDTalk))
	pg = cl.next(quest.OpTalkPage).Data
	cl.send(quest.OpTalkAnswer, []byte{quest.RespListBase})
	rw := cl.next(quest.OpRewardWindow).Data
	if binary.LittleEndian.Uint32(rw) != 901 {
		t.Fatalf("reward window % x", rw)
	}
	gold0, _ := chars.GetByID(ctx, c.ID)
	cl.send(quest.OpTakeReward, append(binary.LittleEndian.AppendUint32(nil, 901), 0))
	up = cl.next(quest.OpUpdate).Data
	if up[0] != quest.UpdateDropped {
		t.Fatalf("drop % x", up)
	}
	if res := cl.next(quest.OpTakeRewardResult).Data; res[0] != 1 {
		t.Fatalf("reward result % x", res)
	}
	after, _ := chars.GetByID(ctx, c.ID)
	if after.Gold != gold0.Gold+100 {
		t.Fatalf("gold %d -> %d", gold0.Gold, after.Gold)
	}
	slots, _ = inv.List(ctx, c.ID)
	if len(slots) != 1 || slots[0].ItemID != 7002 {
		t.Fatalf("after the reward the bag holds %+v (the pelt taken, the prize given)", slots)
	}
	st, _ = store.States(ctx, c.ID)
	if st[0].Status != quest.StatusAchieved || st[0].Achieved != 1 {
		t.Fatalf("paid state %+v", st)
	}
	// Paid once: a second take is refused.
	cl.send(quest.OpTakeReward, append(binary.LittleEndian.AppendUint32(nil, 901), 0))
	if res := cl.next(quest.OpTakeRewardResult).Data; res[0] != 2 {
		t.Fatalf("second reward % x", res)
	}
	cl.send(npctalk.OpEnd, npctalk.EncodeEntity(giver.UID))
	cl.next(npctalk.OpEndResult)

	// QT_OTHER: taken and given up.
	cl.send(npctalk.OpSelect, npctalk.EncodeEntity(giver.UID))
	cl.next(npctalk.OpSelectResult)
	cl.send(npctalk.OpOpen, npctalk.EncodeOpen(giver.UID, npctalk.IDTalk))
	pg = cl.next(quest.OpTalkPage).Data
	if _, rest := readString(pg[1:]); rest[0] != 1 { // QT_HUNT is done (limit 1)
		t.Fatalf("the list after QT_HUNT % x", pg)
	}
	cl.send(quest.OpTalkAnswer, []byte{quest.RespListBase})
	cl.next(quest.OpTalkPage)
	cl.send(quest.OpTalkAnswer, []byte{quest.RespYes})
	cl.next(quest.OpUpdate)
	cl.send(quest.OpAbandon, binary.LittleEndian.AppendUint32(nil, 902))
	if res := cl.next(quest.OpAbandonResult).Data; res[0] != 1 || binary.LittleEndian.Uint32(res[1:]) != 902 {
		t.Fatalf("give up % x", res)
	}
	if up := cl.next(quest.OpUpdate).Data; up[0] != quest.UpdateRemove {
		t.Fatalf("remove % x", up)
	}
	st, _ = store.States(ctx, c.ID)
	if len(st) != 1 {
		t.Fatalf("given up state remains %+v", st)
	}
	cl.send(quest.OpAbandon, binary.LittleEndian.AppendUint32(nil, 902))
	if res := cl.next(quest.OpAbandonResult).Data; res[0] != 2 {
		t.Fatalf("give up twice % x", res)
	}
}

// The wire shapes the client reads (FUN_008812b0 / FUN_008b94d0).
func TestQuestUpdateEncoding(t *testing.T) {
	v := quest.View{Counter: 0x10, State: 1, Status: 1, Missions: []quest.MissionView{{Index: 0, Open: true, Text: "SN_X", Values: []uint32{3}}}, NPCs: []uint32{2001}}
	got := quest.EncodeUpdate(quest.UpdateAdd, 5, &v)
	want := []byte{1, 5, 0, 0, 0, 0x10, 1, 0x58, 1, 1, 0, 1, 4, 0, 'S', 'N', '_', 'X', 1, 3, 0, 0, 0, 1, 0xd1, 7, 0, 0}
	if string(got) != string(want) {
		t.Fatalf("% x\nwant % x", got, want)
	}
	if got := quest.EncodeUpdate(quest.UpdateRemove, 5, &v); len(got) != 5 {
		t.Fatalf("a remove carries no body: % x", got)
	}
	if got := quest.EncodeTalkPage(quest.PageList, "G", []string{"A"}); string(got) != string([]byte{4, 1, 0, 'G', 1, 1, 0, 'A'}) {
		t.Fatalf("page % x", got)
	}
	id, chosen, err := quest.DecodeTakeReward([]byte{9, 0, 0, 0, 1, 7, 0, 0, 0})
	if err != nil || id != 9 || len(chosen) != 1 || chosen[0] != 7 {
		t.Fatalf("take %d %v %v", id, chosen, err)
	}
	_ = proto.Packet{}
}
