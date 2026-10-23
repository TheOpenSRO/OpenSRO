// Command retailgw is round 681's original-protocol gateway tool:
//
//	retailgw serve -listen 127.0.0.1:15779 -shards "Xian:120/1000:1,Test:0/500:0"
//	retailgw probe -gateway 127.0.0.1:15779 -content-id 22 -version 188
//	retailgw serve -login user:pass -captcha 1 -agent-listen 127.0.0.1:15884
//	retailgw login -gateway host:port -content-id 22 -version 188 -user u -pass p -shard Name
//
// serve runs a FAKE retail gateway (internal/retailgw.Server) that does the
// server side of the original handshake and answers 0x6100 and 0x6101 with
// the shards given, so the client's server list can be tried without anyone
// else's server. probe asks a gateway for its shard list the way the client
// does and prints it, then hangs up; it never logs in. The content id and
// version a real gateway expects are the player's own archive's
// (DIVISIONINFO.TXT's first byte and SV.T): pass them, they are not guessed.
//
// Round 788: serve -login plays the login too -- 0x6102, an image code
// (a test pattern; the code is in its log, OURS), 0xA102 naming the agent
// listener, 0x6103 / 0xA103 there and an empty character list -- and login
// logs in to a gateway the way the client does (RunLogin), writing each
// image code to a PNG and reading the code from stdin, then prints the
// character list's bytes.
package main

import (
	"bufio"
	"context"
	"encoding/hex"
	"flag"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"log"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/retailgw"
)

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	switch os.Args[1] {
	case "serve":
		serve(os.Args[2:])
	case "probe":
		probe(os.Args[2:])
	case "login":
		login(os.Args[2:])
	default:
		usage()
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "usage: retailgw serve [-listen addr] [-shards list] [-content-id n] [-version n] [-refuse code] [-fault name]")
	fmt.Fprintln(os.Stderr, "       retailgw serve ... [-login user:pass -captcha code -agent-listen addr]")
	fmt.Fprintln(os.Stderr, "       retailgw probe -gateway host:port -content-id n -version n")
	fmt.Fprintln(os.Stderr, "       retailgw login -gateway host:port -content-id n -version n -user u -pass p -shard name [-image file.png]")
	os.Exit(2)
}

var faults = map[string]retailgw.Fault{
	"":                retailgw.FaultNone,
	"stall":           retailgw.FaultStallAfterHello,
	"bad-signature":   retailgw.FaultBadSignature,
	"check-byte":      retailgw.FaultCheckByte,
	"truncated-list":  retailgw.FaultTruncatedList,
	"malformed-list":  retailgw.FaultMalformedList,
	"truncated-frame": retailgw.FaultTruncatedFrame,
	"oversize-frame":  retailgw.FaultOversizeFrame,
	"not-gateway":     retailgw.FaultNotGateway,
	"flood":           retailgw.FaultFlood,
	"flood-bytes":     retailgw.FaultFloodBytes,
}

// parseShards reads "Name:cur/max:state[:farm],...".
func parseShards(s string) (retailgw.ShardList, error) {
	l := retailgw.ShardList{Farms: []retailgw.Farm{{ID: 1, Name: "Farm"}}}
	for i, item := range strings.Split(s, ",") {
		parts := strings.Split(strings.TrimSpace(item), ":")
		if len(parts) < 3 || len(parts) > 4 {
			return l, fmt.Errorf("shard %q: want Name:cur/max:state[:farm]", item)
		}
		cm := strings.Split(parts[1], "/")
		if len(cm) != 2 {
			return l, fmt.Errorf("shard %q: want cur/max", item)
		}
		cur, err1 := strconv.ParseUint(cm[0], 10, 16)
		mx, err2 := strconv.ParseUint(cm[1], 10, 16)
		st, err3 := strconv.ParseUint(parts[2], 10, 8)
		farm := uint64(1)
		var err4 error
		if len(parts) == 4 {
			farm, err4 = strconv.ParseUint(parts[3], 10, 8)
		}
		if err1 != nil || err2 != nil || err3 != nil || err4 != nil {
			return l, fmt.Errorf("shard %q: numbers out of range", item)
		}
		l.Shards = append(l.Shards, retailgw.Shard{ID: uint16(64 + i), Name: parts[0], Current: uint16(cur), Capacity: uint16(mx), State: byte(st), Farm: byte(farm)})
	}
	return l, nil
}

func serve(args []string) {
	fs := flag.NewFlagSet("serve", flag.ExitOnError)
	listen := fs.String("listen", "127.0.0.1:15779", "address to listen on")
	shards := fs.String("shards", "Fake:120/1000:1", "Name:cur/max:state[:farm],... (state 0 = Check)")
	cid := fs.Uint("content-id", 22, "the content id 0x6100 must carry (0 = any); decides the farm byte")
	ver := fs.Uint("version", 0, "the version 0x6100 must carry (0 = any)")
	refuse := fs.Uint("refuse", 0, "answer 0x6100 with [2, code] (4 = not in service)")
	fault := fs.String("fault", "", "misbehave: stall, bad-signature, check-byte, truncated-list, malformed-list, truncated-frame, oversize-frame, not-gateway, flood")
	encList := fs.Bool("encrypt-list", false, "encrypt the 0xA101 (retail sends it plain)")
	loginAcct := fs.String("login", "", "round 788: user:pass -- play the login past the list for this one account")
	captcha := fs.String("captcha", "1", "round 788: the image code the login wants")
	agentListen := fs.String("agent-listen", "127.0.0.1:15884", "round 788: where the fake agent listens (with -login)")
	_ = fs.Parse(args)
	l, err := parseShards(*shards)
	if err != nil {
		log.Fatal(err)
	}
	f, ok := faults[*fault]
	if !ok {
		log.Fatalf("unknown fault %q", *fault)
	}
	if *cid > 255 || *refuse > 255 || *ver > 0xffffffff {
		log.Fatal("content-id and refuse are bytes, version a u32")
	}
	var fl *retailgw.FakeLogin
	var deadline time.Duration // the fake's 10 s for the list alone
	if *loginAcct != "" {
		deadline = 10 * time.Minute // OURS: a player types at the login and the image code
		fl = fakeLogin(*loginAcct, *captcha, *agentListen)
		agent, err := retailgw.Listen(*agentListen, retailgw.Config{ContentID: byte(*cid), Login: agentOnly(fl), Deadline: time.Hour})
		if err != nil {
			log.Fatal(err)
		}
		defer agent.Close()
		log.Printf("fake agent on %s; the login %s, image code %q", agent.Addr(), strings.SplitN(*loginAcct, ":", 2)[0], *captcha)
	}
	srv, err := retailgw.Listen(*listen, retailgw.Config{
		List: l, ContentID: byte(*cid), Version: uint32(*ver), Refuse: byte(*refuse), Fault: f, EncryptList: *encList, Login: fl, Deadline: deadline,
	})
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("fake retail gateway on %s: %d shard(s)", srv.Addr(), len(l.Shards))
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt)
	<-stop
	_ = srv.Close()
	log.Printf("fake retail gateway: %d connection(s) served", srv.Connections())
}

func probe(args []string) {
	fs := flag.NewFlagSet("probe", flag.ExitOnError)
	gw := fs.String("gateway", "", "host:port")
	cid := fs.Int("content-id", -1, "DIVISIONINFO.TXT's first byte (required)")
	ver := fs.Int64("version", -1, "SV.T's version (required)")
	_ = fs.Parse(args)
	if *gw == "" || *cid < 0 || *cid > 255 || *ver < 0 || *ver > 0xffffffff {
		usage()
	}
	l, err := retailgw.Probe(context.Background(), *gw, retailgw.DefaultProbeOptions(retailgw.ClientInfo{ContentID: byte(*cid), Version: uint32(*ver)}))
	if err != nil {
		log.Fatal(err)
	}
	for _, s := range l.Shards {
		fmt.Printf("%5d  %-20q %5d/%-5d state %d farm %d\n", s.ID, s.Name, s.Current, s.Capacity, s.State, s.Farm)
	}
}

// fakeLogin is serve -login's account: the token fixed, the agent the
// -agent-listen address, an empty character list (OURS, a test tool).
func fakeLogin(acct, code, agentAddr string) *retailgw.FakeLogin {
	up := strings.SplitN(acct, ":", 2)
	if len(up) != 2 {
		log.Fatal("-login wants user:pass")
	}
	host, portText, ok := strings.Cut(agentAddr, ":")
	port, err := strconv.ParseUint(portText, 10, 16)
	if !ok || err != nil {
		log.Fatalf("-agent-listen %q: want host:port", agentAddr)
	}
	img, err := retailgw.EncodeCaptchaBlob(200, 64, func(x, y int) bool { return (x/8+y/8)%2 == 0 })
	if err != nil {
		log.Fatal(err)
	}
	return &retailgw.FakeLogin{Username: up[0], Password: up[1], Captcha: code, Image: img,
		Token: 0x788, AgentHost: host, AgentPort: uint16(port), Lobby: []byte{2, 1, 0}, AgentFrom: -1}
}

func agentOnly(fl *retailgw.FakeLogin) *retailgw.FakeLogin {
	a := *fl
	a.AgentOnly = true
	return &a
}

func login(args []string) {
	fs := flag.NewFlagSet("login", flag.ExitOnError)
	gw := fs.String("gateway", "", "host:port")
	cid := fs.Int("content-id", -1, "DIVISIONINFO.TXT's first byte (required)")
	ver := fs.Int64("version", -1, "SV.T's version (required)")
	user := fs.String("user", "", "the ID")
	pass := fs.String("pass", "", "the password")
	shard := fs.String("shard", "", "the shard's name as the list has it")
	imgPath := fs.String("image", "imagecode.png", "where each image code is written")
	_ = fs.Parse(args)
	if *gw == "" || *cid < 0 || *cid > 255 || *ver < 0 || *ver > 0xffffffff || *user == "" {
		usage()
	}
	in := bufio.NewReader(os.Stdin)
	res, err := retailgw.RunLogin(context.Background(), *gw, retailgw.LoginOptions{
		Info:  retailgw.ClientInfo{ContentID: byte(*cid), Version: uint32(*ver)},
		Login: retailgw.LoginParams{Username: *user, Password: *pass, Shard: *shard},
		Captcha: func(c retailgw.CaptchaImage, attempt int) string {
			w, h, on, err := retailgw.DecodeCaptchaBlob(c.Blob)
			if err != nil {
				log.Printf("image code %d: %v", attempt, err)
				return ""
			}
			pic := image.NewGray(image.Rect(0, 0, w, h))
			for y := 0; y < h; y++ {
				for x := 0; x < w; x++ {
					if on(x, y) {
						pic.SetGray(x, y, color.Gray{Y: 255})
					}
				}
			}
			f, err := os.Create(*imgPath)
			if err == nil {
				_ = png.Encode(f, pic)
				_ = f.Close()
			}
			fmt.Printf("image code %d written to %s; type it: ", attempt, *imgPath)
			line, _ := in.ReadString('\n')
			return strings.TrimRight(line, "\r\n")
		},
	})
	for _, e := range res.Events {
		fmt.Printf("%-15s code %d max %d used %d %s\n", e.Kind, e.Code, e.Max, e.Used, hex.EncodeToString(e.Reply.Raw))
	}
	if err != nil {
		log.Fatal(err)
	}
	if res.Lobby != nil {
		fmt.Printf("0xB007: %s\n", hex.EncodeToString(res.Lobby))
	}
}
