package session

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/OpenSRO/OpenSRO/server/internal/account"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
)

// LoginAttempt is one login as any front door sees it: OpenSRO's own
// 0x0001 or 0x6102, or the retail listener's 0x6102 / 0x6103.
type LoginAttempt struct {
	Username string
	Password string
	// Remote is the client's address (the per-IP limit).
	Remote net.Addr
	// Session is the connection the login came in on. On success the
	// service marks it authenticated and remembers it for the account until
	// it ends ("already connected"). nil only in tests that check a decision.
	Session *gateway.Session
}

// LoginOutcome is the service's decision: the 0xA102 the client is sent
// (Ack; for OpenSRO's own connection the agent fields stay empty), the
// account on success, and whether the connection must be closed after the
// reply is sent (READ: the gateway closes after every GlobalManager refusal
// and after the last allowed wrong password).
type LoginOutcome struct {
	Ack     LoginAck
	Account *account.Account
	Close   bool
}

// The login rules' defaults (round 788).
const (
	// DefaultLoginFailureTolerance is how many wrong passwords an account
	// name may have before the connection is closed and the automatic block
	// is raised: GlobalManager's `LoginFailureTolerance` code default (READ
	// 0x40f3ec; MEASURED 3 in the package's server.cfg too).
	DefaultLoginFailureTolerance = 3
	// DefaultLoginFailureBlockMinutes is the automatic block's length:
	// `LoginFailureBlockTimeMin`'s code default (READ 0x40f404). The package's
	// server.cfg sets 0 (MEASURED), which raises no block.
	DefaultLoginFailureBlockMinutes = 10
	// DefaultLoginPunishmentGuide is the reason the automatic block shows the
	// player (retail's `LoginPunishmentGuide`, an operator's text). OURS:
	// short and neutral; -login-punishment-guide replaces it.
	DefaultLoginPunishmentGuide = "Too many wrong passwords. Please try again later."
	// LoginFailureExpiry is how long an account name's wrong passwords are
	// remembered after the last one. OURS: whether retail's count ever
	// expires by time is OPEN (GlobalManager 0x464ac0 keeps it until the
	// block or a success); a generous hour keeps an attacker's count across
	// tries and lets the table forget names nobody uses.
	LoginFailureExpiry = time.Hour
	// infiniteBlockYears is how far the end time on the wire lies for a
	// punishment with no end (end_at NULL): the begin plus 100 years, what
	// the operator console's "Set Infinite Duration" writes as the end (READ:
	// SR_UserPunishment.dll 0x10006610 -- GetLocalTime twice, `add wYear,
	// 0x64` at 0x10006635, the second time into the Punish End Time pickers
	// 0x408/0x409 with DTM_SETSYSTEMTIME; the first, unchanged, into Punish
	// Begin Time 0x406/0x407).
	infiniteBlockYears = 100
	// maxBlockReasonBytes bounds the reason on the wire: the gateway reads
	// `_QueryBlockGuide`'s reason into a 0x200-byte field at certparam+0x42
	// (READ 0x415f4c), so 511 bytes and the terminator (INFERRED).
	maxBlockReasonBytes = 0x200 - 1
)

// LoginRules are the operator's settings (cmd/server's -login-* flags).
type LoginRules struct {
	// FailureTolerance is the wrong passwords an account name may have; the
	// one that reaches it closes the connection. 0 means the default (3).
	FailureTolerance int
	// BlockMinutes is the automatic login block's length; 0 raises none (the
	// connection is still closed and the count cleared).
	BlockMinutes int
	// PunishmentGuide is the automatic block's reason; "" means the default.
	PunishmentGuide string
	// MaxPerIP is how many accounts may be logged in from one address at once
	// (retail's `MaxUserForNonePCBangIP`); 0 is no limit (OURS default: off).
	MaxPerIP int
}

func (r LoginRules) tolerance() int {
	if r.FailureTolerance <= 0 {
		return DefaultLoginFailureTolerance
	}
	return r.FailureTolerance
}

func (r LoginRules) guide() string {
	if r.PunishmentGuide == "" {
		return DefaultLoginPunishmentGuide
	}
	return r.PunishmentGuide
}

// LoginService is the one place a login is decided (round 788): every front
// door asks it, so the rules -- wrong-password counting and the automatic
// block, punishments, already connected, inspection, full, the per-IP limit
// -- are the same whichever wire the client speaks. See
// docs/protocol/opcodes/login.md, "The login reply, READ (round 788)".
//
// The order is retail's: the password and the account's block first (the
// gateway's certify job), then the full server (the gateway, before it asks
// GlobalManager), then GlobalManager's admission -- already connected, the
// per-IP limit, inspection. Use it by pointer; the zero value with Accounts
// set works (tolerance 3, no automatic block, no inspection or capacity, and
// with Online nil no already-connected rule or IP limit).
type LoginService struct {
	Accounts account.Store
	// Status is the server's state now: inspection and capacity. nil: open,
	// no capacity.
	Status func() ServerStatus
	// Staff reports a GM account (the -gm-accounts list): it passes
	// inspection and a full server (OURS, round 679's review: retail exempts
	// by privileged IP and the account's security bytes from the certify row,
	// INFERRED). nil: nobody.
	Staff func(username string) bool
	// Online is the logged-in table: already connected and the per-IP limit.
	// nil turns both off (tests, tools).
	Online *OnlineAccounts
	Rules  LoginRules
	// Now is the clock; nil is time.Now. Location is the zone the block's end
	// time is written in on the wire; nil is time.Local (the gateway sends
	// the database's datetime as stored, the server's local time).
	Now      func() time.Time
	Location *time.Location
	Logger   *slog.Logger

	mu       sync.Mutex
	failures map[string]loginFailures
	swept    time.Time
}

// loginFailures is one account name's wrong passwords.
type loginFailures struct {
	used int
	last time.Time
}

func (s *LoginService) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

func (s *LoginService) location() *time.Location {
	if s.Location != nil {
		return s.Location
	}
	return time.Local
}

func (s *LoginService) logger() *slog.Logger {
	if s.Logger != nil {
		return s.Logger
	}
	return slog.Default()
}

func loginRefusal(code uint8, close bool) LoginOutcome {
	return LoginOutcome{Ack: LoginAck{Code: code}, Close: close}
}

// Login decides one attempt.
func (s *LoginService) Login(ctx context.Context, a LoginAttempt) LoginOutcome {
	now := s.now()
	// A connection that is already logged in (OURS): retail's client leaves
	// the gateway once its login succeeds, so a second login never reaches
	// it; on OpenSRO's one connection it is refused as "already connected",
	// and nothing changes -- the session stays logged in as it was.
	if a.Session != nil {
		if _, authed := AuthenticatedAccountID(a.Session); authed {
			return loginRefusal(LoginErrAlreadyConnected, false)
		}
	}

	acc, err := s.Accounts.Authenticate(ctx, a.Username, a.Password)
	switch {
	case errors.Is(err, account.ErrInvalidCredentials):
		return s.wrongPassword(ctx, a.Username, now)
	case errors.Is(err, account.ErrBlocked):
		// READ: certify result 3 -> `_QueryBlockGuide` -> [2,2,1, reason,
		// end] (GatewayServer 0x415f46, 0x40dca8); no disconnect follows
		// (0x40dc40 and its caller 0x40dc2a send and return).
		var be *account.BlockedError
		if !errors.As(err, &be) {
			// A store that knows no more than "blocked": no end to show.
			be = &account.BlockedError{Punishment: account.Punishment{BeginAt: now}}
		}
		return LoginOutcome{Ack: s.blockedAck(be.Punishment)}
	case err != nil:
		// READ: a certify query error is job 3 -> [2,6] (0x415f1b, 0x40dc83).
		s.logger().Warn("login: the account store failed", "account", a.Username, "error", err)
		return loginRefusal(LoginErrFailed, false)
	}

	staff := s.Staff != nil && s.Staff(acc.Username)
	var st ServerStatus
	if s.Status != nil {
		st = s.Status()
	}
	// The gateway's own shard check: full and not exempt -> [2,5] (READ
	// 0x40d871); no disconnect (none in 0x40d710-0x40de06).
	if !staff && st.Max > 0 && st.Current >= st.Max {
		return loginRefusal(LoginErrFull, false)
	}

	// GlobalManager's admission (0xA200); the gateway disconnects after
	// every refusal (READ 0x405e1d).
	ip := ipOf(a.Remote)
	if s.Online != nil {
		if r := s.Online.check(acc.ID, ip, s.Rules.MaxPerIP); r != admitted {
			return admitRefusal(r)
		}
	}
	// Under inspection (READ: GlobalManager error 3 -> [2,2,2], after the
	// duplicate and IP checks of 0x401b70).
	if st.Inspection && !staff {
		return LoginOutcome{Ack: LoginAck{Code: LoginErrBlocked, BlockKind: LoginBlockInspection}, Close: true}
	}
	if s.Online != nil {
		if r := s.Online.admit(acc.ID, a.Session, ip, s.Rules.MaxPerIP); r != admitted {
			return admitRefusal(r) // lost a race since the check
		}
	}

	// In. The name's wrong passwords are forgotten: retail forgets them on
	// the image code's success that follows a right password (READ
	// GlobalManager 0xA112 -> 0x40f050); OpenSRO has no image code, so a
	// successful login is that moment (OURS).
	s.mu.Lock()
	delete(s.failures, a.Username)
	s.mu.Unlock()
	if a.Session != nil {
		authenticate(a.Session, acc.ID, acc.Username)
	}
	return LoginOutcome{Ack: LoginAck{OK: true}, Account: acc}
}

func admitRefusal(r admitResult) LoginOutcome {
	if r == admitIPLimit {
		return loginRefusal(LoginErrIPLimit, true)
	}
	return loginRefusal(LoginErrAlreadyConnected, true)
}

// wrongPassword counts one wrong password against name (READ GlobalManager
// 0x464ac0: counted per account NAME, server-wide) and answers [2,1,max,used].
// Below the tolerance the connection stays open; the attempt that reaches it
// clears the count, raises the automatic block and closes (READ 0x4277a5,
// 0x4071c7).
func (s *LoginService) wrongPassword(ctx context.Context, name string, now time.Time) LoginOutcome {
	max := s.Rules.tolerance()
	s.mu.Lock()
	if s.failures == nil {
		s.failures = map[string]loginFailures{}
	}
	if now.Sub(s.swept) >= time.Minute {
		for n, f := range s.failures {
			if now.Sub(f.last) >= LoginFailureExpiry {
				delete(s.failures, n)
			}
		}
		s.swept = now
	}
	f := s.failures[name]
	if f.used > 0 && now.Sub(f.last) >= LoginFailureExpiry {
		f = loginFailures{}
	}
	f.used++
	f.last = now
	used := f.used
	last := used >= max
	if last {
		delete(s.failures, name)
	} else {
		s.failures[name] = f
	}
	s.mu.Unlock()

	out := LoginOutcome{Ack: LoginAck{Code: LoginErrPassword, MaxAttempts: uint32(max), UsedAttempts: uint32(used)}}
	if last {
		out.Close = true
		s.punishAutomatically(ctx, name, now, used)
	}
	return out
}

// punishAutomatically raises the automatic login block for name, retail's
// `EXEC _RegisterAutomatedPunishment '<acct>',1,'<punisher>','<guide>',
// '<description>',<minutes>` (READ GlobalManager 0x4277a5). A name with no
// account, or a store that keeps no punishments, gets none.
func (s *LoginService) punishAutomatically(ctx context.Context, name string, now time.Time, used int) {
	minutes := s.Rules.BlockMinutes
	if minutes <= 0 {
		return
	}
	store, okStore := s.Accounts.(account.PunishmentStore)
	lookup, okLookup := s.Accounts.(account.AccountLookup)
	if !okStore || !okLookup {
		s.logger().Warn("login: the account store keeps no punishments; no automatic block", "account", name)
		return
	}
	acc, err := lookup.AccountByName(ctx, name)
	if errors.Is(err, account.ErrNoSuchAccount) {
		return
	}
	if err != nil {
		s.logger().Warn("login: the automatic block's account lookup failed", "account", name, "error", err)
		return
	}
	p, err := store.AddPunishment(ctx, account.Punishment{
		AccountID: acc.ID, Type: account.PunishLogin, Executor: account.AutomatedPunisher,
		Guide:       s.Rules.guide(),
		Description: fmt.Sprintf("automatic: %d wrong passwords", used),
		BeginAt:     now, EndAt: now.Add(time.Duration(minutes) * time.Minute),
	})
	if err != nil {
		s.logger().Warn("login: raising the automatic block failed", "account", name, "error", err)
		return
	}
	s.logger().Info("login: automatic block for wrong passwords", "account", name, "serial", p.Serial,
		"minutes", minutes, "until", p.EndAt)
}

// blockedAck is [2,2,1, reason, end] for p: the end in the server's local
// wall time, an infinite one as the begin plus 100 years (infiniteBlockYears).
func (s *LoginService) blockedAck(p account.Punishment) LoginAck {
	loc := s.location()
	end := p.EndAt.In(loc)
	if p.Infinite() {
		b := p.BeginAt.In(loc)
		end = time.Date(b.Year()+infiniteBlockYears, b.Month(), b.Day(), b.Hour(), b.Minute(), b.Second(), 0, loc)
	}
	return LoginAck{Code: LoginErrBlocked, BlockKind: LoginBlockPunished,
		BlockReason: truncateUTF8(p.Guide, maxBlockReasonBytes), BlockEnd: end}
}

// truncateUTF8 cuts s to at most n bytes at a character boundary.
func truncateUTF8(s string, n int) string {
	if len(s) <= n {
		return s
	}
	for n > 0 && !utf8.RuneStart(s[n]) {
		n--
	}
	return s[:n]
}

// SessionEnded forgets sess's login: its account may log in again. The
// gateway's OnDisconnect calls it, after the world's bookkeeping has saved
// the character (cmd/server: the last disconnect hook), so a new login of
// the account cannot read the character before the old session's save.
func (s *LoginService) SessionEnded(sess *gateway.Session) {
	s.Online.Release(sess)
}

// LegacyReason is the reason string OpLoginResult carries for an outcome,
// for clients that speak the old 0x0001 (OURS: the words are this server's,
// except inspection and full, which are retail's, round 679).
func LegacyReason(out LoginOutcome) string {
	a := out.Ack
	if a.OK {
		return ""
	}
	switch a.Code {
	case LoginErrPassword:
		if a.UsedAttempts >= a.MaxAttempts {
			return fmt.Sprintf("invalid username or password (%d of %d attempts: disconnected)", a.UsedAttempts, a.MaxAttempts)
		}
		return "invalid username or password"
	case LoginErrBlocked:
		switch a.BlockKind {
		case LoginBlockInspection:
			return LoginRefusedInspection
		case LoginBlockPunished:
			if a.BlockReason == "" {
				return "account blocked until " + a.BlockEnd.Format("2006-01-02 15:04:05")
			}
			return "account blocked: " + a.BlockReason + " (until " + a.BlockEnd.Format("2006-01-02 15:04:05") + ")"
		}
		return "account blocked"
	case LoginErrAlreadyConnected:
		return "this account is already connected"
	case LoginErrFull:
		return LoginRefusedFull
	case LoginErrIPLimit:
		return "too many accounts are connected from your address"
	}
	return "login failed"
}

// LoginHandlerFor answers OpenSRO's old OpLogin 0x0001 through svc, with the
// old OpLoginResult reason string (LegacyReason). The connection is closed
// after the reply when the outcome says so.
func LoginHandlerFor(svc *LoginService) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		if p.Opcode != OpLogin {
			return nil
		}
		req, err := DecodeLoginRequest(p.Data)
		if err != nil {
			return sess.Send(&proto.Packet{
				Opcode: OpLoginResult,
				Data:   (&LoginResult{OK: false, Reason: "malformed request"}).Encode(),
			})
		}
		out := svc.Login(ctx, LoginAttempt{Username: req.Username, Password: req.Password,
			Remote: sess.RemoteAddr(), Session: sess})
		res := &LoginResult{OK: out.Ack.OK, Reason: LegacyReason(out)}
		if err := sess.Send(&proto.Packet{Opcode: OpLoginResult, Data: res.Encode()}); err != nil {
			return err
		}
		if out.Close {
			return gateway.ErrEndSession
		}
		return nil
	}
}

// GatewayLoginHandler answers retail's 0x6102 on OpenSRO's own connection
// with retail's 0xA102 (round 788). The session stays open unless the
// outcome says to close it; then the reply is written out first
// (gateway.ErrEndSession drains the queue).
func GatewayLoginHandler(svc *LoginService) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		if p.Opcode != OpGatewayLogin {
			return nil
		}
		req, err := DecodeGatewayLoginRequest(p.Data)
		var out LoginOutcome
		if err != nil {
			out = LoginOutcome{Ack: LoginAck{Code: LoginErrFailed}, Close: true}
		} else {
			out = svc.Login(ctx, LoginAttempt{Username: req.Username, Password: req.Password,
				Remote: sess.RemoteAddr(), Session: sess})
		}
		if err := sess.Send(&proto.Packet{Opcode: OpGatewayLoginAck, Data: out.Ack.Encode()}); err != nil {
			return err
		}
		if out.Close {
			return gateway.ErrEndSession
		}
		return nil
	}
}
