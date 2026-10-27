package gm

import (
	"context"
	"fmt"
	"strconv"
	"strings"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
)

// silkUsage is /silk's (round 837, OURS: a test tool). The balances are the
// account's (account.SilkStore): own silk unless a kind is named.
const silkUsage = "usage: /silk <amount> [own|gift|point] (a negative amount subtracts, never below 0)"

// The 0x3154 reasons /silk reports with (OURS, the choice: retail's change
// comes from its billing side through 0xAA00, item_mall_wire.md §2.3, whose
// reasons name a purchase of silk, a cancel, a receipt, ...). An addition is
// 2, UIIT_STT_SILK_BUY_RECEIVE; a subtraction 1, UIIT_STT_SILK_BUY_CANCLE.
const (
	silkReasonAdd byte = 2
	silkReasonSub byte = 1
)

var silkKinds = map[string]struct {
	kind account.SilkKind
	cash byte // 0x3154's cash type: 0 own, 1 gift, 2 point (s:0x4f0750)
}{
	"own": {account.SilkOwn, 0}, "gift": {account.SilkGift, 1}, "point": {account.SilkPoint, 2},
	"points": {account.SilkPoint, 2},
}

// silk adds to (or takes from) one of the actor's account's balances.
func (d *Deps) silk(ctx context.Context, actor Actor, args []string) Result {
	if d.Silk == nil {
		return refuse("no silk store")
	}
	if len(args) < 1 || len(args) > 2 {
		return refuse(silkUsage)
	}
	n, err := strconv.ParseInt(args[0], 10, 64)
	if err != nil {
		return refuse(silkUsage)
	}
	name := "own"
	if len(args) == 2 {
		name = strings.ToLower(args[1])
	}
	k, ok := silkKinds[name]
	if !ok {
		return refuse(silkUsage)
	}
	before, err := d.Silk.Silk(ctx, actor.AccountID)
	if err != nil {
		return refuse("reading the silk failed: " + err.Error())
	}
	after, err := d.Silk.AddSilk(ctx, actor.AccountID, k.kind, n)
	if err != nil {
		return refuse("changing the silk failed: " + err.Error())
	}
	moved := balanceOf(after, k.kind) - balanceOf(before, k.kind)
	reason := silkReasonAdd
	if moved < 0 {
		reason, moved = silkReasonSub, -moved
	}
	return Result{
		Text: fmt.Sprintf("silk: own %d, gift %d, point %d", after.Own, after.Gift, after.Point),
		Silk: &SilkChange{Reason: reason, CashType: k.cash, Offset: moved, After: after},
	}
}

func balanceOf(s account.Silk, k account.SilkKind) int64 {
	switch k {
	case account.SilkGift:
		return s.Gift
	case account.SilkPoint:
		return s.Point
	}
	return s.Own
}
