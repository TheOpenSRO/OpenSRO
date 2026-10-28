package main

// Round 838 (QA): the bot uses items from its bag and logs the buffs it is
// told of. -use-items "<item id>,..." uses the first bag slot holding each
// item, -use-items-every apart, once in the world (after -gm-lines, which
// /give them); -watch-buffs prints every OpBuffStart / OpBuffEnd the bot is
// sent -- its own and, with a spawn's buff frames, the other players' -- and
// the monster blows it takes, so a live run sees what everyone in view is
// told about a visual or a scroll, and what a scroll does to the damage.

import (
	"fmt"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/session"
)

var botUse struct {
	items      string // -use-items
	every      time.Duration
	watchBuffs bool // -watch-buffs
	mu         sync.Mutex
	pending    []int64 // the items still to use, in order
}

func useLog(b *bot, format string, args ...any) {
	fmt.Printf("%s [%s] ITEM %s\n", time.Now().Format("15:04:05.000"), b.name, fmt.Sprintf(format, args...))
}

// useSteps asks for the bag once per item, -use-items-every apart; noteUse
// answers each list with the use.
func (b *bot) useSteps() {
	if botUse.items == "" {
		return
	}
	var ids []int64
	for _, f := range strings.Split(botUse.items, ",") {
		if n, err := strconv.ParseInt(strings.TrimSpace(f), 10, 64); err == nil {
			ids = append(ids, n)
		}
	}
	go func() {
		for _, id := range ids {
			time.Sleep(botUse.every)
			botUse.mu.Lock()
			botUse.pending = append(botUse.pending, id)
			botUse.mu.Unlock()
			useLog(b, "-> bag list to use item %d", id)
			_ = b.send(session.OpInventoryList, (&session.CharacterNameRequest{Name: b.name}).Encode())
		}
	}()
}

// noteUse uses the pending item from a bag list and logs the replies and,
// with -watch-buffs, the buffs.
func (b *bot) noteUse(op uint16, data []byte) {
	switch op {
	case session.OpInventoryListResult:
		botUse.mu.Lock()
		if len(botUse.pending) == 0 {
			botUse.mu.Unlock()
			return
		}
		id := botUse.pending[0]
		botUse.pending = botUse.pending[1:]
		botUse.mu.Unlock()
		list, err := session.DecodeInventoryListResult(data)
		if err != nil {
			useLog(b, "bag list: %v", err)
			return
		}
		for _, s := range list.Slots {
			if s.ItemID == id {
				useLog(b, "-> use item %d at bag slot %d", id, s.Slot)
				_ = b.send(session.OpUseItem, (&session.UseItemRequest{CharacterName: b.name, InventorySlot: int32(s.Slot)}).Encode())
				return
			}
		}
		useLog(b, "item %d is not in the bag", id)
	case session.OpUseItemResult:
		if r, err := session.DecodeUseItemResult(data); err == nil {
			useLog(b, "<- use result error=%q remaining %d", r.Error, r.Remaining)
		}
	case session.OpBuffStart:
		if botUse.watchBuffs {
			if s, err := session.DecodeBuffStart(data); err == nil {
				useLog(b, "<- BUFF START owner %d (kind %d) skill %d token %d duration %d ms remaining %d ms speed %d",
					s.OwnerID, s.OwnerKind, s.SkillID, s.Token, s.DurationMs, s.RemainingMs, s.RunSpeed)
			}
		}
	case session.OpMonsterAttacked:
		// The blows the bot itself takes (the absorption scroll's check).
		if botUse.watchBuffs {
			if m, err := session.DecodeMonsterAttacked(data); err == nil && m.TargetCharacterID == b.id && !m.StatusTick {
				useLog(b, "<- HIT by monster %d damage %d critical %v blocked %v hp %d", m.MonsterID, m.Damage, m.Critical, m.Blocked, m.TargetHP)
			}
		}
	case session.OpBuffEnd:
		if botUse.watchBuffs {
			if e, err := session.DecodeBuffEnd(data); err == nil {
				useLog(b, "<- BUFF END owner %d tokens %v speed %d", e.OwnerID, e.Tokens, e.RunSpeed)
			}
		}
	}
}
