// Command swarm puts a crowd of bot players on a running server and takes
// it away again.
//
//	swarm up     -addr HOST:PORT -pg DSN [-n 1000] [-prefix swarm] [-rate 20] [-walk 10] [-probe]
//	swarm probe  -addr HOST:PORT -pg DSN [-prefix probe] [-probe-region 98/171]
//	swarm status [-prefix swarm] [-addr HOST:PORT] [-pg DSN]
//	swarm down   -pg DSN [-prefix swarm]
//	swarm items  -pg DSN [-n 10]
//
// up makes the accounts prefix0000.. exist (in Postgres, with a cheap bcrypt:
// see ensureAccounts), logs each bot in through the normal login, creates its
// character through the retail lobby (0x7007) the first time -- a mixed crowd
// of China and Europe, men and women, any figure, height and volume -- writes
// its worn gear (seal and plus items from the database's own items table,
// gear.go), its level and its start spot on Jangan's plaza deck (at the
// deck's measured height, db.go) into Postgres, and starts it into the world
// (0x7001). Logins are paced (-rate a second) and capped at the room the
// server's -max-players leaves. About -walk percent of the bots click-move
// (retail 0x7021) to a nearby plaza point every -walk-every (3..7 s at 5 s).
// Each bot lists a party-match entry (0x7069), keeps it listed (relist.go:
// the server sends nothing when an entry expires after an hour, so the bot
// renews it every 55 minutes and lists again when it learns it is gone), and
// confirms every join request and accepts every invitation (-party). A bot
// that drops reconnects. A summary is logged every 30 s and the state file
// (-state) rewritten every 5 s. It runs until SIGINT or SIGTERM (`swarm down`
// sends the latter), then logs every bot out. With -probe it also runs the
// latency probe (below) as -probe-prefix0000.
//
// probe logs one bot (prefix0000, default prefix "probe") in somewhere quiet
// and times the server's answer to a click four times a second (probe.go):
// p50 / p99 / max every 10 s, and every round trip over 200 ms with its
// timestamps.
//
// down stops a running up (its pid from the state file), then deletes every
// bot account and character and every row that names them (db.go cleanup).
// It refuses a prefix under 5 letters and touches only accounts named exactly
// ^prefix[0-9]{4}$.
//
// Bots are never GMs: the tool sends no GM command and changes no server
// setting. A server counts them against -max-players (default 1000; a full
// server turns non-GM logins away).
package main

import (
	"bufio"
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/pcspawn"
	"github.com/TheOpenSRO/OpenSRO/server/internal/session"
)

type config struct {
	addr, pg, prefix, state string
	n, walkPct              int
	rate                    float64
	seed                    int64
	radius                  float64
	headroom                int
	y                       float64
	walkEvery               time.Duration
	party                   bool
	summaryEvery            time.Duration
	probe                   bool
	probeCfg                probeConfig
}

// stats are the run's counters.
type stats struct {
	entries, creates, seeded, drops, reconnects    atomic.Int64
	clicks, echoes, noEcho, corrections, walkersOn atomic.Int64
	packetsIn, bytesIn                             atomic.Int64
	listed, joinsAccepted, invitesAccepted         atomic.Int64
	relistChecks, renewed, relisted                atomic.Int64
	firstZone                                      atomic.Pointer[string]
	errMu                                          sync.Mutex
	errs                                           map[string]int
	lastErr                                        string
}

func (s *stats) noteErr(err error) {
	if err == nil {
		return
	}
	// Grouped by the message with its numbers masked (addresses, ports, ids).
	k := strings.Map(func(r rune) rune {
		if r >= '0' && r <= '9' {
			return '#'
		}
		return r
	}, err.Error())
	if len(k) > 80 {
		k = k[:80]
	}
	s.errMu.Lock()
	if s.errs == nil {
		s.errs = map[string]int{}
	}
	s.errs[k]++
	s.lastErr = err.Error()
	s.errMu.Unlock()
}

// pacer spaces connection attempts evenly at its rate.
type pacer struct {
	mu    sync.Mutex
	next  time.Time
	every time.Duration
}

func (p *pacer) wait(ctx context.Context) error {
	p.mu.Lock()
	now := time.Now()
	t := p.next
	if t.Before(now) {
		t = now
	}
	p.next = t.Add(p.every)
	p.mu.Unlock()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-time.After(time.Until(t)):
		return nil
	}
}

type swarm struct {
	cfg      config
	db       *sql.DB
	cat      *catalogue
	pace     *pacer
	password string
	bots     []*bot
	st       stats
	obs      *observer
	started  time.Time
	gearMu   sync.Mutex
	gearIDs  map[int64]int
	plaza    plaza
	plusHist [15]int
}

func (sw *swarm) gearSeen(rows []gearRow) {
	sw.gearMu.Lock()
	defer sw.gearMu.Unlock()
	for _, g := range rows {
		sw.gearIDs[g.Item.ID]++
		if g.Item.isWeapon && g.Plus() < len(sw.plusHist) {
			sw.plusHist[g.Plus()]++
		}
	}
}

// stateFile is what up writes and status / down read.
type stateFile struct {
	PID         int            `json:"pid"`
	Prefix      string         `json:"prefix"`
	Addr        string         `json:"addr"`
	Started     time.Time      `json:"started"`
	Updated     time.Time      `json:"updated"`
	Stopped     bool           `json:"stopped"`
	Bots        int            `json:"bots"`
	Walkers     int            `json:"walkers"`
	Connected   int            `json:"connected"`
	InWorld     int            `json:"in_world"`
	Entries     int64          `json:"entries"`
	Creates     int64          `json:"creates"`
	Seeded      int64          `json:"seeded"`
	Drops       int64          `json:"drops"`
	Reconnects  int64          `json:"reconnects"`
	Clicks      int64          `json:"clicks"`
	Echoes      int64          `json:"echoes"`
	NoEcho      int64          `json:"no_echo"`
	Corrections int64          `json:"corrections"`
	Listed      int64          `json:"party_match_listed"`
	Checks      int64          `json:"party_match_checks"`
	Renewed     int64          `json:"party_match_renewed"`
	Relisted    int64          `json:"party_match_relisted"`
	JoinsOK     int64          `json:"party_joins_accepted"`
	InvitesOK   int64          `json:"party_invites_accepted"`
	PacketsIn   int64          `json:"packets_in"`
	MBIn        float64        `json:"mb_in"`
	Errors      map[string]int `json:"errors,omitempty"`
	LastError   string         `json:"last_error,omitempty"`
	Observer    census         `json:"observer"`
	CPUSeconds  float64        `json:"cpu_seconds"`
	RSSMB       float64        `json:"rss_mb"`
	Goroutines  int            `json:"goroutines"`
}

func defaultState(prefix string) string {
	return filepath.Join(os.TempDir(), "opensro-swarm-"+prefix+".json")
}

func readState(path string) (stateFile, error) {
	var s stateFile
	b, err := os.ReadFile(path)
	if err != nil {
		return s, err
	}
	return s, json.Unmarshal(b, &s)
}

func writeState(path string, s stateFile) error {
	b, _ := json.MarshalIndent(s, "", "  ")
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// alive reports whether pid is a running `swarm up` (its command line read
// from /proc), so a pid the system has since given to another process is
// never signalled.
func alive(pid int) bool {
	if pid <= 0 || probe(pid) != nil {
		return false
	}
	b, err := os.ReadFile(fmt.Sprintf("/proc/%d/cmdline", pid))
	if err != nil {
		return true // no /proc: trust the signal probe
	}
	args := strings.Split(string(b), "\x00")
	return len(args) > 1 && strings.Contains(filepath.Base(args[0]), "swarm") && args[1] == "up"
}

func (sw *swarm) snapshot(stopped bool) stateFile {
	s := stateFile{PID: os.Getpid(), Prefix: sw.cfg.prefix, Addr: sw.cfg.addr, Started: sw.started, Updated: time.Now(), Stopped: stopped,
		Bots: len(sw.bots), Entries: sw.st.entries.Load(), Creates: sw.st.creates.Load(), Seeded: sw.st.seeded.Load(),
		Drops: sw.st.drops.Load(), Reconnects: sw.st.reconnects.Load(), Clicks: sw.st.clicks.Load(), Echoes: sw.st.echoes.Load(),
		NoEcho: sw.st.noEcho.Load(), Corrections: sw.st.corrections.Load(),
		Listed: sw.st.listed.Load(), Checks: sw.st.relistChecks.Load(), Renewed: sw.st.renewed.Load(), Relisted: sw.st.relisted.Load(),
		JoinsOK: sw.st.joinsAccepted.Load(), InvitesOK: sw.st.invitesAccepted.Load(), PacketsIn: sw.st.packetsIn.Load(),
		MBIn: float64(sw.st.bytesIn.Load()) / (1 << 20)}
	for _, b := range sw.bots {
		if b.walker {
			s.Walkers++
		}
		switch b.state.Load() {
		case stInWorld:
			s.InWorld++
			s.Connected++
		case stConnected:
			s.Connected++
		}
	}
	sw.st.errMu.Lock()
	s.Errors = map[string]int{}
	for k, v := range sw.st.errs {
		s.Errors[k] = v
	}
	s.LastError = sw.st.lastErr
	sw.st.errMu.Unlock()
	if sw.obs != nil {
		s.Observer = sw.obs.census()
	}
	s.CPUSeconds, s.RSSMB, s.Goroutines = selfUsage()
	return s
}

func (sw *swarm) logSummary(prev *stateFile) {
	s := sw.snapshot(false)
	dt := s.Updated.Sub(prev.Updated).Seconds()
	cpu := 0.0
	if dt > 0 && !prev.Updated.IsZero() {
		cpu = (s.CPUSeconds - prev.CPUSeconds) / dt * 100
	}
	o := s.Observer
	var seals []string
	for k, v := range o.Seals {
		seals = append(seals, fmt.Sprintf("%s %d", k, v))
	}
	sort.Strings(seals)
	log.Printf("swarm %s: %d/%d in world (%d connected), %d walkers; entries %d, creates %d, drops %d, reconnects %d; clicks %d (echoed %d, unanswered %d, corrected %d); party-match entries %d (checks %d, renewed %d, relisted %d), joins accepted %d, invites accepted %d; in %d pkts %.1f MB; cpu %.1f%% rss %.0f MB goroutines %d; observer sees %d players, %d geared, %d at +3 or more, %d at +8 or more (max +%d), weapons [%s], 0x3038 %d, undecoded %d, standing at y %.2f..%.2f",
		sw.cfg.prefix, s.InWorld, s.Bots, s.Connected, s.Walkers, s.Entries, s.Creates, s.Drops, s.Reconnects,
		s.Clicks, s.Echoes, s.NoEcho, s.Corrections, s.Listed, s.Checks, s.Renewed, s.Relisted, s.JoinsOK, s.InvitesOK, s.PacketsIn, s.MBIn, cpu, s.RSSMB, s.Goroutines,
		o.Players, o.WithGear, o.Plus3, o.Plus8, o.MaxPlus, strings.Join(seals, ", "), o.Equips, o.DecodeErrors, o.MinY, o.MaxY)
	if len(s.Errors) > 0 {
		log.Printf("swarm %s: errors so far %v; last: %s", sw.cfg.prefix, s.Errors, s.LastError)
	}
	*prev = s
}

func up(cfg config) error {
	if err := checkPrefix(cfg.prefix); err != nil {
		return err
	}
	if cfg.n < 1 || cfg.n > maxBots {
		return fmt.Errorf("-n must be 1..%d", maxBots)
	}
	if cfg.rate <= 0 {
		return fmt.Errorf("-rate must be positive")
	}
	if cfg.probe {
		if err := checkPrefix(cfg.probeCfg.prefix); err != nil {
			return fmt.Errorf("-probe-prefix: %w", err)
		}
		if cfg.probeCfg.prefix == cfg.prefix {
			return fmt.Errorf("-probe-prefix must differ from -prefix")
		}
		if _, err := cfg.probeCfg.spot(); err != nil {
			return err
		}
	}
	if st, err := readState(cfg.state); err == nil && !st.Stopped && alive(st.PID) && st.PID != os.Getpid() {
		return fmt.Errorf("a swarm for prefix %q is already running (pid %d, %s)", cfg.prefix, st.PID, cfg.state)
	}
	if status, err := queryStatus(cfg.addr); err != nil {
		log.Printf("server status: %v (continuing)", err)
	} else {
		log.Printf("server status before the swarm: %d in the world, max %d", status.Current, status.Max)
		// A bot past the server's -max-players is refused "full" and would only
		// retry: the swarm is capped at the room there is.
		room := status.Max - status.Current - cfg.headroom
		if cfg.probe {
			room-- // the probe's
		}
		if room < 1 {
			return fmt.Errorf("no room: %d of %d in the world (-headroom %d); raise the server's -max-players / OPENSRO_MAX_PLAYERS", status.Current, status.Max, cfg.headroom)
		}
		if room < cfg.n {
			log.Printf("WARNING: the server takes %d players (%d in the world now, -headroom %d): running %d bots, not %d. Raise its -max-players / OPENSRO_MAX_PLAYERS for more.",
				status.Max, status.Current, cfg.headroom, room, cfg.n)
			cfg.n = room
		}
		if status.Current+cfg.n >= status.Max {
			log.Printf("WARNING: %d bots fill the server (max %d): non-GM logins are refused while it is full (-headroom N keeps N free)", cfg.n, status.Max)
		}
	}
	db, err := openDB(cfg.pg)
	if err != nil {
		return err
	}
	defer db.Close()
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	cat, err := loadCatalogue(ctx, db)
	if err != nil {
		return err
	}
	if cat.rows == 0 {
		return fmt.Errorf("the items table has no wearable rows: import the reference data first (deploy/README.md)")
	}
	log.Printf("gear catalogue: %s", cat.summary())

	pw := make([]byte, 12)
	if _, err := rand.Read(pw); err != nil {
		return err
	}
	if cfg.radius <= 0 {
		cfg.radius = autoRadius(cfg.n)
	}
	if cfg.walkEvery < time.Second {
		return fmt.Errorf("-walk-every must be 1s or more")
	}
	sw := &swarm{cfg: cfg, db: db, cat: cat, plaza: plazaFor(cfg.radius), pace: &pacer{every: time.Duration(float64(time.Second) / cfg.rate)},
		password: "sw-" + hex.EncodeToString(pw), started: time.Now(), gearIDs: map[int64]int{},
		obs: &observer{players: map[uint32]pcspawn.Record{}, cat: cat}}
	created, err := ensureAccounts(ctx, db, cfg.prefix, cfg.n, sw.password)
	if err != nil {
		return err
	}
	log.Printf("%d bot accounts (%d new), %s0000..%s; logging in at %.0f a second; standing at y %.3f in a %.0f-unit disc around 97/168 local (%.0f, %.0f); %d%% walk every ~%s",
		cfg.n, created, cfg.prefix, botName(cfg.prefix, cfg.n-1), cfg.rate, cfg.y, sw.plaza.R, sw.plaza.X, sw.plaza.Z, cfg.walkPct, cfg.walkEvery)

	for i := 0; i < cfg.n; i++ {
		sw.bots = append(sw.bots, &bot{sw: sw, i: i, name: botName(cfg.prefix, i), walker: (i*37+11)%100 < cfg.walkPct, observer: i == 0})
	}
	var wg sync.WaitGroup
	if cfg.probe {
		pcfg := cfg.probeCfg
		pcfg.password = sw.password
		wg.Add(1)
		go func() {
			defer wg.Done()
			if err := runProbe(ctx, cfg.addr, db, pcfg); err != nil {
				log.Printf("probe: %v", err)
			}
		}()
	}
	for _, b := range sw.bots {
		wg.Add(1)
		go func() { defer wg.Done(); b.run(ctx) }()
	}
	_ = writeState(cfg.state, sw.snapshot(false))
	tick := time.NewTicker(5 * time.Second)
	defer tick.Stop()
	summary := time.NewTicker(cfg.summaryEvery)
	defer summary.Stop()
	var prev stateFile
	sw.logSummary(&prev)
	for {
		select {
		case <-ctx.Done():
			log.Printf("stopping: logging %d bots out", len(sw.bots))
			for _, b := range sw.bots {
				b.stop()
			}
			done := make(chan struct{})
			go func() { wg.Wait(); close(done) }()
			select {
			case <-done:
			case <-time.After(10 * time.Second):
				log.Printf("some bots did not stop within 10 s")
			}
			sw.logSummary(&prev)
			_ = writeState(cfg.state, sw.snapshot(true))
			return nil
		case <-tick.C:
			if err := writeState(cfg.state, sw.snapshot(false)); err != nil {
				log.Printf("state file: %v", err)
			}
		case <-summary.C:
			sw.logSummary(&prev)
		}
	}
}

// queryStatus asks the server for its status (0x0007 / 0x0008), on its own
// connection, before any login.
func queryStatus(addr string) (session.ServerStatus, error) {
	if addr == "" {
		return session.ServerStatus{}, errors.New("no -addr")
	}
	nc, err := net.DialTimeout("tcp", addr, 5*time.Second)
	if err != nil {
		return session.ServerStatus{}, err
	}
	defer nc.Close()
	c := &conn{c: nc, r: bufio.NewReader(nc), st: &stats{}}
	if err := c.send(session.OpServerStatusRequest, nil); err != nil {
		return session.ServerStatus{}, err
	}
	data, err := c.await(session.OpServerStatus, 5*time.Second)
	if err != nil {
		return session.ServerStatus{}, err
	}
	return session.DecodeServerStatus(data)
}

func status(cfg config) error {
	if err := checkPrefix(cfg.prefix); err != nil {
		return err
	}
	st, err := readState(cfg.state)
	switch {
	case err != nil:
		fmt.Printf("no state file at %s (%v)\n", cfg.state, err)
	default:
		running := !st.Stopped && alive(st.PID)
		fmt.Printf("swarm %s: process %d %s, state written %s ago\n", st.Prefix, st.PID, map[bool]string{true: "running", false: "not running"}[running], time.Since(st.Updated).Round(time.Second))
		fmt.Printf("  bots %d: connected %d, online (in the world) %d, walkers %d\n", st.Bots, st.Connected, st.InWorld, st.Walkers)
		fmt.Printf("  entries %d, creates %d, seeded %d, drops %d, reconnects %d\n", st.Entries, st.Creates, st.Seeded, st.Drops, st.Reconnects)
		fmt.Printf("  clicks %d, echoed %d, unanswered %d, corrected %d\n", st.Clicks, st.Echoes, st.NoEcho, st.Corrections)
		fmt.Printf("  party-match entries listed %d (checks %d, renewed %d, relisted %d), join requests accepted %d, invitations accepted %d\n",
			st.Listed, st.Checks, st.Renewed, st.Relisted, st.JoinsOK, st.InvitesOK)
		fmt.Printf("  process: cpu %.1f s total, rss %.0f MB, %d goroutines; in %d packets, %.1f MB\n", st.CPUSeconds, st.RSSMB, st.Goroutines, st.PacketsIn, st.MBIn)
		o := st.Observer
		fmt.Printf("  observer (%s0000) sees %d players, %d geared, %d at +3 or more, %d at +8 or more, max +%d; weapons %v; standing at y %.2f..%.2f\n", st.Prefix, o.Players, o.WithGear, o.Plus3, o.Plus8, o.MaxPlus, o.Seals, o.MinY, o.MaxY)
		if o.Sample != "" {
			fmt.Printf("  e.g. %s\n", o.Sample)
		}
		if len(st.Errors) > 0 {
			fmt.Printf("  errors %v\n  last: %s\n", st.Errors, st.LastError)
		}
	}
	if cfg.addr != "" {
		if s, err := queryStatus(cfg.addr); err != nil {
			fmt.Printf("server %s: %v\n", cfg.addr, err)
		} else {
			fmt.Printf("server %s: %d characters in the world, max %d\n", cfg.addr, s.Current, s.Max)
		}
	}
	if cfg.pg != "" {
		db, err := openDB(cfg.pg)
		if err != nil {
			return err
		}
		defer db.Close()
		c, err := countBots(context.Background(), db, cfg.prefix)
		if err != nil {
			return err
		}
		fmt.Printf("database: %d bot accounts, %d characters, %d worn rows, %d weapons at +3 or more, %d at +8 or more\n", c.Accounts, c.Characters, c.WornRows, c.Plus3, c.Plus8)
	}
	return nil
}

func down(cfg config) error {
	if err := checkPrefix(cfg.prefix); err != nil {
		return err
	}
	if st, err := readState(cfg.state); err == nil && alive(st.PID) && !st.Stopped {
		log.Printf("stopping the running swarm (pid %d)", st.PID)
		if err := terminate(st.PID); err != nil {
			return fmt.Errorf("signalling pid %d: %w", st.PID, err)
		}
		deadline := time.Now().Add(60 * time.Second)
		for alive(st.PID) && time.Now().Before(deadline) {
			time.Sleep(200 * time.Millisecond)
		}
		if alive(st.PID) {
			return fmt.Errorf("pid %d did not stop within 60 s", st.PID)
		}
		// The server's disconnect bookkeeping (the position and guild-point
		// saves) runs as each connection closes: let it finish first.
		time.Sleep(3 * time.Second)
	}
	db, err := openDB(cfg.pg)
	if err != nil {
		return err
	}
	defer db.Close()
	rep, err := cleanup(context.Background(), db, cfg.prefix)
	if err != nil {
		return err
	}
	log.Printf("removed %s", rep)
	c, err := countBots(context.Background(), db, cfg.prefix)
	if err != nil {
		return err
	}
	log.Printf("left: %d bot accounts, %d characters, %d worn rows", c.Accounts, c.Characters, c.WornRows)
	if err := os.Remove(cfg.state); err != nil && !errors.Is(err, os.ErrNotExist) {
		log.Printf("state file: %v", err)
	}
	return nil
}

// items prints the gear catalogue and the first bots' loadouts, read-only.
func items(cfg config) error {
	db, err := openDB(cfg.pg)
	if err != nil {
		return err
	}
	defer db.Close()
	cat, err := loadCatalogue(context.Background(), db)
	if err != nil {
		return err
	}
	fmt.Println(cat.summary())
	for i := 0; i < cfg.n; i++ {
		lk := lookFor(cfg.seed, i)
		fmt.Printf("%s %s body %d scale 0x%02x:", botName(cfg.prefix, i), lk.Gender(), lk.RefObjID, lk.Scale)
		for _, g := range cat.loadout(cfg.seed, i, lk.Race, lk.Sex) {
			fmt.Printf(" [%d] %d %s %s +%d(adv %d)", g.Slot, g.Item.ID, g.Item.Code, g.Item.Seal, g.Plus(), g.Adv)
		}
		fmt.Println()
	}
	return nil
}

func usage() {
	fmt.Fprintf(os.Stderr, `usage:
  swarm up     -addr HOST:PORT -pg DSN [-n 1000] [-prefix swarm] [-rate 20] [-walk 10] [-probe]
  swarm probe  -addr HOST:PORT -pg DSN [-prefix probe] [-probe-region 98/171 -probe-x 960 -probe-z 960]
  swarm status [-prefix swarm] [-addr HOST:PORT] [-pg DSN]
  swarm down   -pg DSN [-prefix swarm]
  swarm items  -pg DSN [-n 10]
`)
	os.Exit(2)
}

func main() {
	if len(os.Args) < 2 {
		usage()
	}
	cmd := os.Args[1]
	fs := flag.NewFlagSet(cmd, flag.ExitOnError)
	var cfg config
	fs.StringVar(&cfg.addr, "addr", "", "the server's gateway, HOST:PORT")
	fs.StringVar(&cfg.pg, "pg", os.Getenv("SWARM_PG"), "the server's Postgres DSN (env SWARM_PG)")
	fs.StringVar(&cfg.prefix, "prefix", "swarm", "bot accounts are named PREFIX0000..: 5-8 lowercase letters")
	fs.StringVar(&cfg.state, "state", "", "the state file (default $TMPDIR/opensro-swarm-PREFIX.json)")
	fs.IntVar(&cfg.n, "n", 1000, "up: how many bots; items: how many loadouts to print")
	fs.IntVar(&cfg.walkPct, "walk", 10, "up: percent of the bots that click-move")
	fs.Float64Var(&cfg.rate, "rate", 20, "up: connection attempts a second (logins and reconnects)")
	fs.Int64Var(&cfg.seed, "seed", 1, "up/items: the looks, gear and spots are fixed by it")
	fs.Float64Var(&cfg.radius, "radius", 0, "up: the plaza disc's radius, its north edge on the deck's at 97/168 local z 960 (0: 85 x sqrt(n/1000))")
	fs.DurationVar(&cfg.walkEvery, "walk-every", 5*time.Second, "up: a walker's mean time between clicks (uniform over 0.6..1.4 of it)")
	fs.Float64Var(&cfg.y, "y", plazaY, "up: the height the bots stand at (the plaza deck's, MEASURED)")
	fs.BoolVar(&cfg.party, "party", true, "up: each bot lists a party-match entry and accepts every join request and invitation")
	fs.IntVar(&cfg.headroom, "headroom", 0, "up: cap the bots so this many of the server's -max-players slots stay free (0: no cap)")
	fs.DurationVar(&cfg.summaryEvery, "summary", 30*time.Second, "up: how often the summary is logged")
	pc := &cfg.probeCfg
	fs.BoolVar(&cfg.probe, "probe", false, "up: also run the latency probe (as -probe-prefix0000)")
	fs.StringVar(&pc.prefix, "probe-prefix", "probe", "up -probe: the probe's account prefix (5-8 lowercase letters, not -prefix)")
	fs.StringVar(&pc.zone, "probe-zone", plazaZone, "probe: the zone frame its spot is written in")
	fs.StringVar(&pc.region, "probe-region", "98/171", "probe: the region it stands in, x/y (default: a field three regions from Jangan's plaza with no nest)")
	fs.Float64Var(&pc.x, "probe-x", 960, "probe: its region-local x (it clicks between x and x+8)")
	fs.Float64Var(&pc.z, "probe-z", 960, "probe: its region-local z")
	fs.Float64Var(&pc.y, "probe-y", 0, "probe: its height")
	fs.DurationVar(&pc.every, "probe-every", 250*time.Millisecond, "probe: the time between clicks")
	fs.DurationVar(&pc.spike, "probe-spike", 200*time.Millisecond, "probe: a round trip over this is logged on its own line")
	fs.DurationVar(&pc.report, "probe-report", 10*time.Second, "probe: how often p50 / p99 / max are logged")
	fs.DurationVar(&pc.timeout, "probe-timeout", 5*time.Second, "probe: a click with no echo within this is logged as lost")
	switch cmd {
	case "up", "down", "status", "items", "probe":
	default:
		usage()
	}
	if err := fs.Parse(os.Args[2:]); err != nil {
		os.Exit(2)
	}
	if cmd == "probe" {
		// Its own prefix: never the crowd's default, whose prefix0000 is a
		// running swarm's observer.
		set := false
		fs.Visit(func(f *flag.Flag) { set = set || f.Name == "prefix" })
		if set {
			pc.prefix = cfg.prefix
		}
		cfg.prefix = pc.prefix
	}
	if cfg.state == "" {
		cfg.state = defaultState(cfg.prefix)
	}
	log.SetFlags(log.Ldate | log.Ltime)
	var err error
	switch cmd {
	case "up":
		if cfg.addr == "" {
			err = errors.New("up needs -addr")
		} else {
			err = up(cfg)
		}
	case "probe":
		if cfg.addr == "" {
			err = errors.New("probe needs -addr")
		} else {
			err = probeOnly(cfg)
		}
	case "down":
		err = down(cfg)
	case "status":
		err = status(cfg)
	case "items":
		if cfg.n == 1000 {
			cfg.n = 10
		}
		err = items(cfg)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "swarm:", err)
		os.Exit(1)
	}
}

// probeOnly is `swarm probe`: the probe alone, until SIGINT or SIGTERM.
func probeOnly(cfg config) error {
	if err := checkPrefix(cfg.prefix); err != nil {
		return err
	}
	db, err := openDB(cfg.pg)
	if err != nil {
		return err
	}
	defer db.Close()
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	pw := make([]byte, 12)
	if _, err := rand.Read(pw); err != nil {
		return err
	}
	pc := cfg.probeCfg
	pc.prefix = cfg.prefix
	pc.password = "pr-" + hex.EncodeToString(pw)
	return runProbe(ctx, cfg.addr, db, pc)
}
