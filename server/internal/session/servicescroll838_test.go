package session

import (
	"bufio"
	"context"
	"encoding/binary"
	"errors"
	"net"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/guild"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/jobs"
	"github.com/TheOpenSRO/OpenSRO/server/internal/magicopt"
	"github.com/TheOpenSRO/OpenSRO/server/internal/mall"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/skill"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Round 838: the private-server service scrolls through the use-item handler
// on real sockets (servicescroll.go). Every row is synthetic, named as the
// archive names the scrolls (their code names are what the dispatch reads);
// no archive data.

// The fixture's item ids.
const (
	tidSilk100     = 9001
	tidDice        = 9002
	tidNameRed     = 9003
	tidNameReset   = 9004
	tidStatReset   = 9005
	tidStatSkill   = 9006
	tidNameChange  = 9007
	tidStarter     = 9008
	tidStarterAng  = 9009
	tidRedStats    = 9010
	tidLeveler     = 9011
	tidGuildRemove = 9012
	tidJobRemove   = 9013
	tidTitleSky    = 9014
	tidSword       = 9100
)

func svcItems() *refdata.MemStore {
	refs := refdata.NewMemStore()
	scroll := func(id int64, code string, t3, t4 int) refdata.Item {
		return refdata.Item{ID: id, CodeName: code, TypeID1: 3, TypeID2: 3, TypeID3: t3, TypeID4: t4, MaxStack: 1, CanUse: true}
	}
	items := []refdata.Item{
		scroll(tidSilk100, "ITEM_ANTHEIA_SILK_SCROLL_100", 13, 14),
		scroll(tidDice, "ITEM_SILK_LOTTERY", 13, 1),
		scroll(tidNameRed, "ITEM_NAME_COLOR_RED", 13, 14),
		scroll(tidNameReset, "ITEM_NAME_COLOR_RESET", 13, 14),
		scroll(tidStatReset, "ITEM_ANTHEIA_STATRESET", 13, 14),
		scroll(tidStatSkill, "ITEM_ETERNITY_STATSKILLRESET", 13, 14),
		scroll(tidNameChange, "ITEM_NAME_CHANGE", 13, 1),
		scroll(tidStarter, "ITEM_STARTER_PACKAGE", 3, 1),
		scroll(tidStarterAng, "ITEM_STARTER_PACKAGE_ANGEL", 13, 14),
		scroll(tidRedStats, "ITEM_DURABILITY_REMOVER", 3, 1),
		scroll(tidLeveler, "ITEM_ANTHEIA_MASTERY", 3, 1),
		scroll(tidGuildRemove, "ITEM_GUILD_REMOVER", 3, 1),
		scroll(tidJobRemove, "ITEM_JOB_REMOVER", 3, 1),
		scroll(tidTitleSky, "ITEM_TITLE_COLOR_SKY", 13, 14),
		{ID: tidSword, CodeName: "ITEM_T_SWORD", TypeID1: 3, TypeID2: 1, TypeID3: 6, TypeID4: 2, MaxStack: 1},
	}
	// The starter packages' contents, by the codes the mapping names.
	next := int64(9200)
	for _, c := range []struct {
		code  string
		stack int
	}{
		{"ITEM_MALL_PREMIUM_VIETNAM_GOLDTIME_PLUS", 1}, {"ITEM_MALL_AVATAR_M_NASRUN", 1}, {"ITEM_MALL_AVATAR_W_NASRUN", 1},
		{"ITEM_MALL_AVATAR_M_AMALRUN", 1}, {"ITEM_MALL_AVATAR_W_AMALRUN", 1}, {"ITEM_AVATAR_M_ANGEL_WING_DRESS", 1},
		{"ITEM_AVATAR_W_ANGEL_WING_DRESS", 1}, {"ITEM_COS_P_EXTENSION", 1}, {"ITEM_MALL_GLOBAL_CHATTING", 50},
		{"ITEM_MALL_REVERSE_RETURN_SCROLL", 50}, {"ITEM_MALL_RETURN_SCROLL_HIGH_SPEED", 50},
	} {
		items = append(items, refdata.Item{ID: next, CodeName: c.code, TypeID1: 3, TypeID2: 3, MaxStack: c.stack})
		next++
	}
	if err := refs.ImportItems(context.Background(), items); err != nil {
		panic(err)
	}
	// Mastery 257's rows: a chain of two, one that needs the chain's level
	// 2, and one past the mastery level the tests reach.
	sk := func(id, group int64, level, mlevel, sp int, code string) refdata.Skill {
		return refdata.Skill{ID: id, GroupID: group, BasicLevel: level, BasicCode: code, Mastery1: 257, MasteryLevel1: mlevel,
			ReqLearnSP: sp, ReqLearnRace: 3}
	}
	s2 := sk(503, 2, 1, 3, 30, "SKILL_CH_T_B_01")
	s2.ReqLearnSkill1, s2.ReqLearnSkillLevel1 = 1, 2
	if err := refs.ImportSkills(context.Background(), []refdata.Skill{
		sk(501, 1, 1, 1, 10, "SKILL_CH_T_A_01"), sk(502, 1, 2, 2, 20, "SKILL_CH_T_A_02"), s2,
		sk(504, 3, 1, 50, 40, "SKILL_CH_T_C_01"),
		{ID: 1, GroupID: 9, BasicLevel: 1, BasicCode: "SKILL_PUNCH_01"}, // a default: no learn cost
	}); err != nil {
		panic(err)
	}
	return refs
}

type svcFixture struct {
	t        *testing.T
	addr     string
	accounts *account.MemStore
	chars    *character.MemStore
	inv      *inventory.MemStore
	skills   *skill.MemStore
	store    *mall.MemStore
	hub      *world.Hub
	ariaID   int64
	bramID   int64
	roll     int64
	a, b     net.Conn
	ra, rb   *bufio.Reader
}

func setupService(t *testing.T) *svcFixture {
	t.Helper()
	ctx := context.Background()
	f := &svcFixture{t: t, accounts: account.NewMemStore(), chars: character.NewMemStore(), skills: skill.NewMemStore(),
		store: mall.NewMemStore(), hub: world.NewHub()}
	f.accounts.Add("alice", "pw1")
	f.accounts.Add("bob", "pw2")
	aria, _ := f.chars.Create(ctx, 1, "Aria")
	bram, _ := f.chars.Create(ctx, 2, "Bram")
	f.ariaID, f.bramID = aria.ID, bram.ID
	refs := svcItems()
	f.inv = inventory.NewMemStore(refs)
	opts := magicopt.New([]*magicopt.Row{{ID: 1, Code: "MATTR_DEC_MAXDUR", Sign: "-@"}, {ID: 2, Code: "MATTR_STR", Sign: "+"},
		{ID: 3, Code: "MATTR_NOT_REPARABLE", Sign: "-"}})
	guilds := guild.NewMemStore()
	handle := gateway.Chain(LoginHandler(f.accounts), WorldHandler(f.chars, nil, f.hub),
		UseItemHandler(f.chars, f.inv, refs, nil, nil, nil, f.hub, nil, nil, NewCompositeKeeper(), nil),
		MallHandler(MallDeps{Store: f.store, Chars: f.chars, Inv: f.inv, Items: refs, Hub: f.hub}),
		ServiceHandler(ServiceDeps{Chars: f.chars, Inv: f.inv, Items: refs, Refs: refs, Skills: f.skills, Hub: f.hub,
			Options: opts, Roll: func(n int64) int64 { return min(f.roll, n-1) }}),
		GuildHandler(f.chars, guilds, f.hub))
	srv := &gateway.Server{Addr: freeAddr(t), Handle: handle, OnDisconnect: WorldDisconnectHandler(f.hub, f.chars)}
	ctxSrv, cancel := context.WithCancel(context.Background())
	go srv.ListenAndServe(ctxSrv)
	t.Cleanup(func() {
		cancel()
		mallRT.Store(nil)
		serviceRT.Store(nil)
		guildOps.Store(nil)
	})
	f.addr = srv.Addr
	f.a, f.ra = f.enter("alice", "pw1", "Aria")
	f.b, f.rb = f.enter("bob", "pw2", "Bram")
	drainPlayerSpawn(t, f.a, f.ra)
	drainPlayerSpawn(t, f.b, f.rb)
	// The silk store after the entries, so they read no 0x3153 (as setupMall).
	mallRT.Load().Silk = f.accounts
	return f
}

// enter dials, logs in and enters the world as name.
func (f *svcFixture) enter(user, pass, name string) (net.Conn, *bufio.Reader) {
	f.t.Helper()
	var c net.Conn
	for i := 0; i < 50; i++ {
		var err error
		if c, err = net.Dial("tcp", f.addr); err == nil {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if c == nil {
		f.t.Fatal("no server")
	}
	c = &selfIDFilterConn{Conn: c}
	f.t.Cleanup(func() { c.Close() })
	r := bufio.NewReader(c)
	if lr, err := DecodeLoginResult(doSend(f.t, c, r, OpLogin, (&LoginRequest{Username: user, Password: pass}).Encode()).Data); err != nil || !lr.OK {
		f.t.Fatalf("%s login: %v %+v", user, err, lr)
	}
	if name != "" {
		if ewr, err := DecodeEnterWorldResult(nextOpAfter(f.t, c, r, OpEnterWorld, (&EnterWorldRequest{CharacterName: name}).Encode(), OpEnterWorldResult).Data); err != nil || !ewr.OK {
			f.t.Fatalf("%s enter world: %v %+v", name, err, ewr)
		}
	}
	return c, r
}

func nextOpAfter(t *testing.T, c net.Conn, r *bufio.Reader, op uint16, data []byte, want uint16) *proto.Packet {
	t.Helper()
	if err := proto.Write(c, &proto.Packet{Opcode: op, Data: data}, nil, nil); err != nil {
		t.Fatal(err)
	}
	return nextOp(t, c, r, want)
}

// give puts n of item into Aria's bag and answers the slot.
func (f *svcFixture) give(item int64, n int) int {
	f.t.Helper()
	if err := f.inv.AddItem(context.Background(), f.ariaID, item, n); err != nil {
		f.t.Fatal(err)
	}
	return f.slotOf(item)
}

func (f *svcFixture) slotOf(item int64) int {
	slots, _ := f.inv.List(context.Background(), f.ariaID)
	for _, s := range slots {
		if s.ItemID == item {
			return s.Index
		}
	}
	return -1
}

// use uses Aria's slot and answers the reply.
func (f *svcFixture) use(slot int) *UseItemResult {
	f.t.Helper()
	p := nextOpAfter(f.t, f.a, f.ra, OpUseItem, (&UseItemRequest{CharacterName: "Aria", InventorySlot: int32(slot)}).Encode(), OpUseItemResult)
	r, err := DecodeUseItemResult(p.Data)
	if err != nil {
		f.t.Fatal(err)
	}
	return r
}

func (f *svcFixture) line(c net.Conn, r *bufio.Reader) string {
	f.t.Helper()
	d := nextOp(f.t, c, r, OpServiceLine).Data
	return string(d[2 : 2+binary.LittleEndian.Uint16(d)])
}

func TestRound838ServiceScrollKinds(t *testing.T) {
	for code, want := range map[string]serviceKind{
		"ITEM_ANTHEIA_SILK_SCROLL_10": svcSilk, "ITEM_ANTHEIA_SILK_SCROLL_10000": svcSilk, "ITEM_SILK_LOTTERY": svcDice,
		"ITEM_JOB_REMOVER": svcJobPenalty, "ITEM_GUILD_REMOVER": svcGuildPenalty, "ITEM_REMOVEPREM": svcPremium,
		"ITEM_DURABILITY_REMOVER": svcRedStats, "ITEM_ANTHEIA_SKILLRESET": svcSkillReset, "ITEM_ANTHEIA_STATRESET": svcStatReset,
		"ITEM_ETERNITY_STATSKILLRESET": svcStatSkillReset, "ITEM_ANTHEIA_MASTERY": svcSkillLeveler, "ITEM_NAME_CHANGE": svcNameChange,
		"ITEM_NAME_COLOR_ANTIQUE": svcNameColour, "ITEM_NAME_COLOR_RESET": svcNameColour, "ITEM_TITLE_COLOR_WHITE": svcTitleColour,
		"ITEM_TITLE_COLOR_RESET": svcTitleColour, "ITEM_STARTER_PACKAGE_MOSTEXCLUSIVE_ANGEL": svcStarter, "ITEM_PET_LEVEL": svcPetLevel,
	} {
		got, ok := serviceScrollOf(&refdata.Item{CodeName: code, TypeID1: 3, TypeID2: 3, TypeID3: 3, TypeID4: 1})
		if !ok || got.kind != want {
			t.Errorf("%s: %+v %v, want kind %d", code, got, ok, want)
		}
	}
	// The return scrolls stay return scrolls; a name colour has no white.
	for _, code := range []string{"ITEM_ETC_SCROLL_RETURN_01", "ITEM_MALL_RETURN_SCROLL_HIGH_SPEED", "ITEM_NAME_COLOR_WHITE",
		"ITEM_LOTTERY_GOLD", "ITEM_ANTHEIA_SILK_SCROLL_X"} {
		if got, ok := serviceScrollOf(&refdata.Item{CodeName: code}); ok {
			t.Errorf("%s is a service scroll: %+v", code, got)
		}
	}
	if s, _ := serviceScrollOf(&refdata.Item{CodeName: "ITEM_ANTHEIA_SILK_SCROLL_2500"}); s.amount != 2500 {
		t.Errorf("2500 silk scroll: %+v", s)
	}
	if s, _ := serviceScrollOf(&refdata.Item{CodeName: "ITEM_TITLE_COLOR_RESET"}); s.colour != 0 {
		t.Errorf("the title reset stores the default: %+v", s)
	}
	// Every package line lists a gender pair or none; the elite has 14 lines.
	if n := len(starterPackages["ITEM_STARTER_PACKAGE_MOSTEXCLUSIVE"]); n != 14 {
		t.Errorf("the elite package has %d lines", n)
	}
	if n := len(starterPackages["ITEM_STARTER_PACKAGE_EXCLUSIVE_ANGEL"]); n != 12 {
		t.Errorf("the special package has %d lines", n)
	}
}

func TestRound838SilkScrollAndDice(t *testing.T) {
	f := setupService(t)
	slot := f.give(tidSilk100, 1)
	if r := f.use(slot); r.Error != "" || r.Remaining != 0 || r.ItemID != tidSilk100 {
		t.Fatalf("silk scroll: %+v", r)
	}
	if l := f.line(f.a, f.ra); l != "You have received 100 silk." {
		t.Fatalf("line %q", l)
	}
	if b := nextOp(t, f.a, f.ra, mall.OpSilk).Data; binary.LittleEndian.Uint32(b) != 100 {
		t.Fatalf("0x3153 % x", b)
	}
	if f.slotOf(tidSilk100) >= 0 {
		t.Fatal("the scroll was kept")
	}
	f.roll = 500
	slot = f.give(tidDice, 1)
	if r := f.use(slot); r.Error != "" {
		t.Fatalf("dice: %+v", r)
	}
	if l := f.line(f.a, f.ra); l != "The Lucky Dice rolled 500: you have received 500 silk." {
		t.Fatalf("line %q", l)
	}
	f.roll = 0
	slot = f.give(tidDice, 1)
	if r := f.use(slot); r.Error != "" {
		t.Fatalf("dice 0: %+v", r)
	}
	if l := f.line(f.a, f.ra); l != "The Lucky Dice rolled 0: no silk this time." {
		t.Fatalf("line %q", l)
	}
	if b, _ := f.accounts.Silk(context.Background(), 1); b != (account.Silk{Own: 600}) {
		t.Fatalf("balances %+v", b)
	}
}

func TestRound838PlateColours(t *testing.T) {
	f := setupService(t)
	slot := f.give(tidNameRed, 1)
	if r := f.use(slot); r.Error != "" {
		t.Fatalf("red: %+v", r)
	}
	want := encodePlateColours(f.ariaID, 0xFFFF2020, 0)
	for _, side := range []struct {
		c net.Conn
		r *bufio.Reader
	}{{f.a, f.ra}, {f.b, f.rb}} {
		if got := nextOp(t, side.c, side.r, OpPlateColours).Data; string(got) != string(want) {
			t.Fatalf("0x013B % x, want % x", got, want)
		}
	}
	if n, ti, _ := f.chars.PlateColours(context.Background(), f.ariaID); n != 0xFFFF2020 || ti != 0 {
		t.Fatalf("stored %08x %08x", n, ti)
	}
	// The same colour again is refused and the scroll kept.
	slot = f.give(tidNameRed, 1)
	if r := f.use(slot); r.Error != "Your name already has that colour." || f.slotOf(tidNameRed) < 0 {
		t.Fatalf("again: %+v", r)
	}
	// The title, and the spawn's frame carries both.
	slot = f.give(tidTitleSky, 1)
	if r := f.use(slot); r.Error != "" {
		t.Fatalf("title: %+v", r)
	}
	fr := plateColourFrame(f.ariaID)
	if fr == nil {
		t.Fatal("no spawn frame")
	}
	// The reset puts the name back to the default.
	slot = f.give(tidNameReset, 1)
	if r := f.use(slot); r.Error != "" {
		t.Fatalf("reset: %+v", r)
	}
	if got := nextOp(t, f.b, f.rb, OpPlateColours).Data; string(got) != string(encodePlateColours(f.ariaID, 0xFFFF2020, 0xFF87CEEB)) {
		t.Fatalf("Bram's title update % x", got)
	}
	if got := nextOp(t, f.b, f.rb, OpPlateColours).Data; string(got) != string(encodePlateColours(f.ariaID, 0, 0xFF87CEEB)) {
		t.Fatalf("Bram's reset % x", got)
	}
}

func TestRound838StatAndSkillResetAtNextLogin(t *testing.T) {
	f := setupService(t)
	ctx := context.Background()
	if err := f.chars.SetLeveling(ctx, f.ariaID, 10, 0, 1, 40, 22); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 3; i++ {
		f.skills.RaiseMastery(ctx, f.ariaID, 257, 0, 10)
	}
	for _, id := range []int64{1, 501, 502} {
		f.skills.Learn(ctx, f.ariaID, id)
	}
	f.skills.AddSkillPoints(ctx, f.ariaID, 5)
	slot := f.give(tidStatSkill, 1)
	if r := f.use(slot); r.Error != "" {
		t.Fatalf("use: %+v", r)
	}
	f.line(f.a, f.ra)
	// A second scroll while the first waits is refused.
	slot = f.give(tidStatReset, 1)
	if r := f.use(slot); r.Error != "A reset is already waiting for your next login." {
		t.Fatalf("second: %+v", r)
	}
	if c, _ := f.chars.GetByID(ctx, f.ariaID); c.Str != 40 {
		t.Fatal("the reset ran before the relog")
	}
	f.a.Close()
	time.Sleep(200 * time.Millisecond)
	f.a, f.ra = f.enter("alice", "pw1", "Aria")
	if l := f.line(f.a, f.ra); l != "Your stats have been reset: Str 29, Int 29, 27 stat points to spend." {
		t.Fatalf("line %q", l)
	}
	if l := f.line(f.a, f.ra); l != "Your skills have been reset: 30 SP returned." {
		t.Fatalf("line %q", l)
	}
	c, _ := f.chars.GetByID(ctx, f.ariaID)
	if c.Str != 29 || c.Int != 29 || c.StatPoints != 27 || c.Level != 10 {
		t.Fatalf("after %+v", c)
	}
	if sp, _ := f.skills.SkillPoints(ctx, f.ariaID); sp != 35 {
		t.Fatalf("SP %d", sp)
	}
	if known, _ := f.skills.KnownSkills(ctx, f.ariaID); len(known) != 1 || known[0] != 1 {
		t.Fatalf("known %v: the default must stay", known)
	}
	if p, _ := f.chars.ServicePending(ctx, f.ariaID); p != 0 {
		t.Fatalf("pending %b", p)
	}
}

func TestRound838SkillLeveler(t *testing.T) {
	f := setupService(t)
	ctx := context.Background()
	slot := f.give(tidLeveler, 1)
	if r := f.use(slot); r.Error != "There are no skills to open for your mastery levels." || f.slotOf(tidLeveler) < 0 {
		t.Fatalf("at mastery 0: %+v", r)
	}
	for i := 0; i < 3; i++ {
		f.skills.RaiseMastery(ctx, f.ariaID, 257, 0, 10)
	}
	if r := f.use(slot); r.Error != "" {
		t.Fatalf("use: %+v", r)
	}
	if l := f.line(f.a, f.ra); l != "3 skill level(s) have been opened for your masteries." {
		t.Fatalf("line %q", l)
	}
	known, _ := f.skills.KnownSkills(ctx, f.ariaID)
	got := map[int64]bool{}
	for _, id := range known {
		got[id] = true
	}
	if !got[501] || !got[502] || !got[503] || got[504] || len(known) != 3 {
		t.Fatalf("known %v", known)
	}
	if sp, _ := f.skills.SkillPoints(ctx, f.ariaID); sp != 0 {
		t.Fatalf("the leveler charged %d SP", sp)
	}
	if st := nextOp(t, f.a, f.ra, OpSkillStateResult); len(st.Data) == 0 {
		t.Fatal("no skill state")
	}
}

func TestRound838NameChange(t *testing.T) {
	f := setupService(t)
	ctx := context.Background()
	slot := f.give(tidNameChange, 1)
	if r := f.use(slot); r.Error != "" {
		t.Fatalf("use: %+v", r)
	}
	f.line(f.a, f.ra)
	// The session ends.
	f.a.SetReadDeadline(time.Now().Add(2 * time.Second))
	for {
		if _, err := proto.Read(f.ra, nil, nil); err != nil {
			var ne net.Error
			if errors.As(err, &ne) && ne.Timeout() {
				t.Fatal("the session was not ended")
			}
			break
		}
	}
	time.Sleep(200 * time.Millisecond)
	c, r := f.enter("alice", "pw1", "")
	start := func(name string) *StartResult {
		res, err := DecodeStartResult(nextOpAfter(t, c, r, OpStart, (&StartRequest{Name: name}).Encode(), OpStartResult).Data)
		if err != nil {
			t.Fatal(err)
		}
		return res
	}
	if res := start("Aria"); res.OK || res.Code != StartErrRenamePending {
		t.Fatalf("Start %+v", res)
	}
	rename := func(name, to string) []byte {
		return nextOpAfter(t, c, r, OpRename, (&RenameRequest{Name: name, NewName: to}).Encode(), OpRenameResult).Data
	}
	for _, tc := range []struct {
		to   string
		code uint16
	}{{"A", LobbyErrNameLength}, {"Bad Name", LobbyErrNameInvalid}, {"bram", LobbyErrNameExists}, {"ARIA", LobbyErrNameExists}} {
		if got := rename("Aria", tc.to); string(got) != string(EncodeRenameResult(false, tc.code, "")) {
			t.Fatalf("%q: % x", tc.to, got)
		}
	}
	if got := rename("Bram", "Bramble"); string(got) != string(EncodeRenameResult(false, LobbyErrNotOnAccount, "")) {
		t.Fatalf("another account's: % x", got)
	}
	if got := rename("Aria", "Arion"); string(got) != string(EncodeRenameResult(true, 0, "Arion")) {
		t.Fatalf("rename % x", got)
	}
	if got := rename("Arion", "Arionne"); string(got) != string(EncodeRenameResult(false, RenameErrNotPending, "")) {
		t.Fatalf("a second rename % x", got)
	}
	if ch, _ := f.chars.GetByID(ctx, f.ariaID); ch.Name != "Arion" {
		t.Fatalf("name %q", ch.Name)
	}
	if taken, _ := f.chars.NameTaken(ctx, "Aria"); taken {
		t.Fatal("the old name is still taken")
	}
	if res := start("Arion"); !res.OK {
		t.Fatalf("Start after the rename %+v", res)
	}
}

func TestRound838StarterPackage(t *testing.T) {
	f := setupService(t)
	ctx := context.Background()
	slot := f.give(tidStarter, 1)
	if r := f.use(slot); r.Error != "" {
		t.Fatalf("use: %+v", r)
	}
	f.line(f.a, f.ra)
	tally := func() (map[string]int, int) {
		es, _ := f.store.Chest(ctx, f.ariaID)
		out := map[string]int{}
		for _, e := range es {
			it, _ := serviceRT.Load().Items.GetItem(ctx, e.ItemID)
			out[it.CodeName] += e.Quantity
			if e.From != starterFrom {
				t.Fatalf("from %q", e.From)
			}
		}
		return out, len(es)
	}
	// Aria is the MemStore's default body, a man's: the man's spirit and dress.
	byCode, n := tally()
	want := map[string]int{"ITEM_MALL_PREMIUM_VIETNAM_GOLDTIME_PLUS": 1, "ITEM_MALL_AVATAR_M_NASRUN": 1,
		"ITEM_AVATAR_M_ANGEL_WING_DRESS": 1, "ITEM_COS_P_EXTENSION": 1, "ITEM_MALL_GLOBAL_CHATTING": 11,
		"ITEM_MALL_REVERSE_RETURN_SCROLL": 11, "ITEM_MALL_RETURN_SCROLL_HIGH_SPEED": 11}
	if len(byCode) != len(want) || n != 7 {
		t.Fatalf("chest %v (%d entries)", byCode, n)
	}
	for k, v := range want {
		if byCode[k] != v {
			t.Fatalf("chest %v, want %v", byCode, want)
		}
	}
	for i := 0; i < n; i++ {
		nextOp(t, f.a, f.ra, mall.OpChestReceived)
	}
	// A woman gets the woman's; the angel package the angel's spirit.
	if err := f.chars.SetGender(ctx, f.ariaID, character.GenderChinaWoman); err != nil {
		t.Fatal(err)
	}
	slot = f.give(tidStarterAng, 1)
	if r := f.use(slot); r.Error != "" {
		t.Fatalf("angel: %+v", r)
	}
	byCode, n = tally()
	if byCode["ITEM_MALL_AVATAR_W_AMALRUN"] != 1 || byCode["ITEM_AVATAR_W_ANGEL_WING_DRESS"] != 1 || n != 14 {
		t.Fatalf("after the angel package %v (%d entries)", byCode, n)
	}
}

func TestRound838RedStats(t *testing.T) {
	f := setupService(t)
	ctx := context.Background()
	// The scroll in slot 0 is refused: the item to clean belongs there.
	slot := f.give(tidRedStats, 1)
	if r := f.use(slot); r.Error != "Put the item to clean in the first slot of your inventory." {
		t.Fatalf("scroll first: %+v", r)
	}
	if err := f.inv.MoveItem(ctx, f.ariaID, slot, 5); err != nil {
		t.Fatal(err)
	}
	opts := []uint64{inventory.MagParam(2, 7), inventory.MagParam(1, 40), inventory.MagParam(3, 1)}
	if err := f.inv.AddItemInstance(ctx, f.ariaID, tidSword, 1, inventory.Instance{MagParams: opts}); err != nil {
		t.Fatal(err)
	}
	if f.slotOf(tidSword) != 0 {
		t.Fatalf("the sword is in slot %d", f.slotOf(tidSword))
	}
	if r := f.use(5); r.Error != "" {
		t.Fatalf("use: %+v", r)
	}
	if l := f.line(f.a, f.ra); l != "2 red stat(s) removed from the item in the first slot of your inventory." {
		t.Fatalf("line %q", l)
	}
	slots, _ := f.inv.List(ctx, f.ariaID)
	for _, s := range slots {
		if s.Index == 0 && (len(s.MagParams) != 1 || s.MagParams[0] != inventory.MagParam(2, 7)) {
			t.Fatalf("options %x", s.MagParams)
		}
	}
	slot = f.give(tidRedStats, 1)
	if r := f.use(slot); r.Error != "The item in the first slot of your inventory has no red stats." || f.slotOf(tidRedStats) < 0 {
		t.Fatalf("clean item: %+v", r)
	}
}

func TestRound838Penalties(t *testing.T) {
	f := setupService(t)
	ctx := context.Background()
	g := guildOps.Load()
	slot := f.give(tidGuildRemove, 1)
	if r := f.use(slot); r.Error != "You have no guild penalty to remove." {
		t.Fatalf("no penalty: %+v", r)
	}
	g.guilds.SetPenalty(ctx, f.ariaID, time.Now().Add(time.Hour))
	if _, err := g.guilds.Create(ctx, "Order", f.ariaID, "Aria"); err != nil {
		t.Fatal(err)
	}
	if r := f.use(slot); r.Error != "You must have left your guild already before using this scroll!" {
		t.Fatalf("in a guild: %+v", r)
	}
	if _, err := g.guilds.Disband(ctx, mustGuildOf(t, g.guilds, f.ariaID)); err != nil {
		t.Fatal(err)
	}
	if r := f.use(slot); r.Error != "" {
		t.Fatalf("use: %+v", r)
	}
	if g.penaltyLeft(ctx, f.ariaID) != 0 {
		t.Fatal("the guild penalty is still there")
	}
	// The job penalty.
	st := jobs.NewMemStore()
	SetJobDeps(JobDeps{Store: st, Chars: f.chars, Hub: f.hub})
	t.Cleanup(func() { jobRT.Store(nil); jobRecs.Delete(f.ariaID) })
	slot = f.give(tidJobRemove, 1)
	if r := f.use(slot); r.Error != "You have no job penalty to remove." {
		t.Fatalf("no job penalty: %+v", r)
	}
	rec := jobs.NewRecord(f.ariaID)
	rec.PenaltyUntil = time.Now().Add(time.Hour)
	if err := saveJobRecord(ctx, jobDepsNow(), rec); err != nil {
		t.Fatal(err)
	}
	if r := f.use(slot); r.Error != "" {
		t.Fatalf("use: %+v", r)
	}
	if got, _ := st.Get(ctx, f.ariaID); got.Penalized(time.Now()) {
		t.Fatal("the job penalty is still there")
	}
}

func mustGuildOf(t *testing.T, s guild.Store, cid int64) int64 {
	t.Helper()
	id, err := s.GuildIDOf(context.Background(), cid)
	if err != nil {
		t.Fatal(err)
	}
	return id
}

func TestRound838Lottery(t *testing.T) {
	es := []mall.LotteryEntry{{ID: 1, Silk: 50}, {ID: 2, Silk: 150}, {ID: 3, Silk: 100}}
	for roll, want := range map[int64]int64{0: 1, 49: 1, 50: 2, 199: 2, 200: 3, 299: 3} {
		if e, pot, ok := mall.LotteryPick(es, func(int64) int64 { return roll }); !ok || e.ID != want || pot != 300 {
			t.Errorf("roll %d: %+v %d %v", roll, e, pot, ok)
		}
	}
	ctx := context.Background()
	store := mall.NewMemStore()
	silk := account.NewMemStore()
	silk.Add("alice", "pw")
	chars := character.NewMemStore()
	c, _ := chars.Create(ctx, 1, "Aria")
	mallRT.Store(&MallDeps{Store: store, Silk: silk, Chars: chars})
	t.Cleanup(func() { mallRT.Store(nil) })
	plan := mall.Plan{Units: []mall.Unit{{Scrap: mall.Scrap{Item: mall.Item{Code: "ITEM_LOTTERY_GOLD"}}, Stack: 1}},
		Pay: mall.Payment{Own: 150}}
	if err := registerLottery(ctx, store, c.ID, 1, plan, time.Now()); err != nil {
		t.Fatal(err)
	}
	if err := registerLottery(ctx, store, c.ID, 1, mall.Plan{Units: []mall.Unit{{Scrap: mall.Scrap{Item: mall.Item{Code: "ITEM_T_POTION"}}}}}, time.Now()); err != nil {
		t.Fatal(err)
	}
	g := gmLottery{}
	if n, pot, err := g.LotteryStatus(ctx); n != 1 || pot != 150 || err != nil {
		t.Fatalf("status %d %d %v", n, pot, err)
	}
	name, paid, closed, err := g.LotteryDraw(ctx, -1)
	if err != nil || name != "Aria" || paid != 150 || closed != 1 {
		t.Fatalf("draw %q %d %d %v", name, paid, closed, err)
	}
	if b, _ := silk.Silk(ctx, 1); b.Own != 150 {
		t.Fatalf("paid %+v", b)
	}
	if _, _, _, err := g.LotteryDraw(ctx, -1); !errors.Is(err, mall.ErrNoLotteryEntries) {
		t.Fatalf("an empty draw: %v", err)
	}
}
