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
	// Round 850: -emotes, the action window's emotes at set times after
	// entry ("5s=0;12s=6"): 0x3091 [byte], so a watching client sees another
	// player's emote (and its weapon go and come back).
	botEmotes string
)

// timedEmotes starts -emotes' requests.
func (b *bot) timedEmotes(name string) {
	start := time.Now()
	for _, item := range strings.Split(botEmotes, ";") {
		item = strings.TrimSpace(item)
		at, val, ok := strings.Cut(item, "=")
		if !ok {
			continue
		}
		d, err := time.ParseDuration(strings.TrimSpace(at))
		if err != nil {
			fmt.Printf("[%s] -emotes: bad time %q\n", name, at)
			continue
		}
		var e int
		if _, err := fmt.Sscanf(strings.TrimSpace(val), "%d", &e); err != nil || e < 0 || e > 255 {
			fmt.Printf("[%s] -emotes: bad byte %q\n", name, val)
			continue
		}
		go func() {
			time.Sleep(time.Until(start.Add(d)))
			b.send(session.OpEmote, []byte{byte(e)})
			fmt.Printf("[%s] EMOTE (at %s) byte %d\n", name, d, e)
		}()
	}
}

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
