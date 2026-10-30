package main

import (
	"encoding/binary"
	"flag"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/npctalk"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/session"
)

// Round 844 lane H (OURS, a QA aid): -gstore runs guild storage steps, in
// order, once the bot is in the world, against the guild manager whose
// reference id is -gstore-ref (NPC_CH_GENARAL_SP, 2021, by default):
//
//	wait:<dur>              sleep
//	waitseen:<name>         until that character is in view
//	talk                    0x7045 select and 0x7046 {npc, 0x0f} (INTERACTMODE 6)
//	open / list / close     0x7250 / 0x7252 / 0x7251 {npc}
//	deposit:<bag>:<dst>     0x7034 type 0x1e (bag index, storage slot)
//	take:<slot>:<bag>       0x7034 type 0x1f
//	move:<src>:<dst>:<n>    0x7034 type 0x1d
//	gold:<n> / goldout:<n>  0x7034 types 0x20 / 0x21
//	gm:<line>               a GM console line
//
// Every reply is printed as "GSTORE <opcode> <bytes>" (noteGStore).
var (
	botGStore    = flag.String("gstore", "", "bot (round 844): guild storage steps, ';'-separated (see gstore.go)")
	botGStoreRef = flag.Uint("gstore-ref", 2021, "bot -gstore: the guild manager's reference id")
)

func (b *bot) gstoreNPC() uint32 {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.uidByRef[uint32(*botGStoreRef)]
}

// gstoreSteps runs -gstore in its own goroutine.
func (b *bot) gstoreSteps(name string) {
	if *botGStore == "" {
		return
	}
	go func() {
		for _, step := range strings.Split(*botGStore, ";") {
			step = strings.TrimSpace(step)
			if step == "" {
				continue
			}
			parts := strings.Split(step, ":")
			n := func(i int) int {
				if i >= len(parts) {
					return 0
				}
				v, _ := strconv.Atoi(parts[i])
				return v
			}
			npc := b.gstoreNPC()
			u32 := binary.LittleEndian.AppendUint32(nil, npc)
			switch parts[0] {
			case "wait":
				d, _ := time.ParseDuration(parts[1])
				time.Sleep(d)
				continue
			case "waitseen":
				// Until that character is in view (its spawn reached this bot).
				for {
					if _, ok := b.idOf(parts[1]); ok {
						break
					}
					time.Sleep(500 * time.Millisecond)
				}
				fmt.Printf("[%s] GSTORE %s is in view\n", name, parts[1])
				continue
			case "talk":
				b.send(npctalk.OpSelect, npctalk.EncodeEntity(npc))
				time.Sleep(300 * time.Millisecond)
				b.send(npctalk.OpOpen, npctalk.EncodeOpen(npc, 0x0f))
			case "end":
				b.send(npctalk.OpEnd, npctalk.EncodeEntity(npc))
			case "open":
				b.send(session.OpGuildStorageOpen, u32)
			case "list":
				b.send(session.OpGuildStorageList, u32)
			case "close":
				b.send(session.OpGuildStorageClose, u32)
			case "deposit":
				b.send(session.OpItemMove, binary.LittleEndian.AppendUint32([]byte{session.ItemMoveGuildDeposit,
					byte(n(1) + session.ItemWireBagOffset), byte(n(2))}, npc))
			case "take":
				b.send(session.OpItemMove, binary.LittleEndian.AppendUint32([]byte{session.ItemMoveGuildWithdraw,
					byte(n(1)), byte(n(2) + session.ItemWireBagOffset)}, npc))
			case "move":
				out := binary.LittleEndian.AppendUint16([]byte{session.ItemMoveGuildInside, byte(n(1)), byte(n(2))}, uint16(n(3)))
				b.send(session.OpItemMove, binary.LittleEndian.AppendUint32(out, npc))
			case "gold", "goldout":
				t := session.ItemMoveGuildGoldIn
				if parts[0] == "goldout" {
					t = session.ItemMoveGuildGoldOut
				}
				b.send(session.OpItemMove, binary.LittleEndian.AppendUint64([]byte{t}, uint64(n(1))))
			case "gm":
				b.send(session.OpGMCommand, (&session.GMCommandRequest{Name: name, Line: strings.Join(parts[1:], ":")}).Encode())
			default:
				fmt.Printf("[%s] GSTORE unknown step %q\n", name, step)
				continue
			}
			fmt.Printf("[%s] GSTORE -> %s (npc %d)\n", name, step, npc)
			time.Sleep(700 * time.Millisecond)
		}
		fmt.Printf("[%s] GSTORE steps done\n", name)
	}()
}

// noteGStore prints the guild storage's replies and the item operation's.
func (b *bot) noteGStore(p *proto.Packet) {
	switch p.Opcode {
	case session.OpGuildStorageOpenResult, session.OpGuildStorageCloseResult, session.OpGuildStorageListResult,
		session.OpGuildStorageBegin, session.OpGuildStorageData, session.OpGuildStorageEnd, session.OpItemMoveResult,
		npctalk.OpOpenResult, npctalk.OpEndResult:
		fmt.Printf("[%s] GSTORE %#04x % x\n", b.name, p.Opcode, p.Data)
	}
}
