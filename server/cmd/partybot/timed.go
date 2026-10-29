package main

import (
	"fmt"
	"strings"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/session"
)

// Round 842 (QA aids): -gm-timed runs GM lines at set times after the bot
// is in the world ("20s=/union Alpha;60s=/union leave"), so a live run can
// change a union or a guild while a rendered client watches; -guild-delay
// waits before the guild steps, so several bots found their guilds in a
// known order (the in-memory store numbers guilds as they are founded).
var (
	botGMTimed    string
	botGuildDelay time.Duration
)

// timedGMLines starts -gm-timed's lines.
func (b *bot) timedGMLines(name string) {
	start := time.Now()
	for _, item := range strings.Split(botGMTimed, ";") {
		item = strings.TrimSpace(item)
		at, line, ok := strings.Cut(item, "=")
		if !ok {
			continue
		}
		d, err := time.ParseDuration(strings.TrimSpace(at))
		if err != nil {
			fmt.Printf("[%s] -gm-timed: bad time %q\n", name, at)
			continue
		}
		line = strings.TrimSpace(line)
		go func() {
			time.Sleep(time.Until(start.Add(d)))
			b.send(session.OpGMCommand, (&session.GMCommandRequest{Name: name, Line: line}).Encode())
			fmt.Printf("[%s] GM (at %s) %s\n", name, d, line)
		}()
	}
}
