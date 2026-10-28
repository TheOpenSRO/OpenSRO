package gm

import (
	"context"
	"fmt"
	"strconv"
	"strings"
)

// lotteryUsage is /lottery's (round 838, OURS: the Silk Lottery's operator
// side; mall/lottery.go has the rules).
const lotteryUsage = "usage: /lottery (the open entries and the pot), /lottery draw [prize] (draw a winner; the prize defaults to the pot)"

// LotteryControl is the Silk Lottery's GM hooks (round 838, OURS).
type LotteryControl interface {
	// LotteryStatus answers the open entries and the pot (their silk).
	LotteryStatus(ctx context.Context) (entries int, pot int64, err error)
	// LotteryDraw draws one winner among the open entries, pays it prize
	// silk (the pot when prize < 0), closes the entries and tells the winner
	// if online. It answers the winner's character name and what was paid.
	LotteryDraw(ctx context.Context, prize int64) (winner string, paid int64, entries int, err error)
}

// lottery reads or draws the Silk Lottery.
func (d *Deps) lottery(ctx context.Context, args []string) Result {
	if d.Lottery == nil {
		return refuse("no lottery")
	}
	if len(args) == 0 {
		n, pot, err := d.Lottery.LotteryStatus(ctx)
		if err != nil {
			return refuse("reading the lottery failed: " + err.Error())
		}
		return Result{Text: fmt.Sprintf("lottery: %d open entries, pot %d silk", n, pot)}
	}
	if strings.ToLower(args[0]) != "draw" || len(args) > 2 {
		return refuse(lotteryUsage)
	}
	prize := int64(-1)
	if len(args) == 2 {
		n, err := strconv.ParseInt(args[1], 10, 64)
		if err != nil || n < 0 {
			return refuse(lotteryUsage)
		}
		prize = n
	}
	winner, paid, n, err := d.Lottery.LotteryDraw(ctx, prize)
	if err != nil {
		return refuse("the draw failed: " + err.Error())
	}
	return Result{
		Text:   fmt.Sprintf("lottery: %s won %d silk (%d entries closed)", winner, paid, n),
		Notice: fmt.Sprintf("Silk Lottery: %s has won %d silk!", winner, paid),
	}
}
