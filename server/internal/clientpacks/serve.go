package clientpacks

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"
)

// DefaultListen is the listener's address when -client-packs is set, no
// -client-packs-url is, and -client-packs-listen does not say otherwise.
// OURS: the gateway's default port plus one.
const DefaultListen = ":15780"

// ServeLimits bound the listener. OURS: a small private server's numbers.
type ServeLimits struct {
	// MaxActive is how many downloads run at once, all clients together;
	// one more is answered 503 with Retry-After.
	MaxActive int
	// PerIP is how many downloads one address runs at once (429 beyond).
	PerIP int
	// PerMinute is how many requests one address may start a minute (429
	// beyond): a resumed download is a handful, a loop of tiny ranges is not.
	PerMinute int
	// Stall ends a download whose client takes no bytes for this long.
	Stall time.Duration
}

// DefaultServeLimits: 16 downloads at once, 2 an address, 60 requests an
// address a minute, 60 s without progress. OURS.
var DefaultServeLimits = ServeLimits{MaxActive: 16, PerIP: 2, PerMinute: 60, Stall: 60 * time.Second}

// PathPrefix is where the listener serves the packs: /packs/<name>.
const PathPrefix = "/packs/"

// Handler serves exactly the files of b, by the names the manifest gives
// them, at PathPrefix + name: GET and HEAD, with ranges (a resumed
// download), nothing else -- no other path, no folder listing, no file the
// manifest does not name, and no file that changed since Build hashed it
// (its hash would no longer be the one the clients were told).
type Handler struct {
	b      *Built
	lim    ServeLimits
	log    *slog.Logger
	mu     sync.Mutex
	active int
	perIP  map[string]int
	window map[string]*ipWindow
	warned map[string]bool
	now    func() time.Time
}

type ipWindow struct {
	start time.Time
	n     int
}

// NewHandler returns the listener's handler. A zero limit takes the default's.
func NewHandler(b *Built, lim ServeLimits, logger *slog.Logger) *Handler {
	d := DefaultServeLimits
	if lim.MaxActive <= 0 {
		lim.MaxActive = d.MaxActive
	}
	if lim.PerIP <= 0 {
		lim.PerIP = d.PerIP
	}
	if lim.PerMinute <= 0 {
		lim.PerMinute = d.PerMinute
	}
	if lim.Stall <= 0 {
		lim.Stall = d.Stall
	}
	if logger == nil {
		logger = slog.New(slog.NewTextHandler(discard{}, nil))
	}
	return &Handler{b: b, lim: lim, log: logger, perIP: map[string]int{}, window: map[string]*ipWindow{},
		warned: map[string]bool{}, now: time.Now}
}

type discard struct{}

func (discard) Write(p []byte) (int, error) { return len(p), nil }

func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("X-Content-Type-Options", "nosniff")
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	name, ok := strings.CutPrefix(r.URL.Path, PathPrefix)
	if !ok || name == "" || strings.Contains(name, "/") {
		http.NotFound(w, r)
		return
	}
	f, ok := h.b.ByName(name)
	if !ok {
		http.NotFound(w, r)
		return
	}
	ip := clientIP(r)
	if code, why := h.admit(ip); code != 0 {
		w.Header().Set("Retry-After", "10")
		http.Error(w, why, code)
		return
	}
	defer h.release(ip)

	fh, err := os.Open(f.Path)
	if err != nil {
		h.log.Error("client packs: cannot open a listed pack", "pack", f.Name, "err", err)
		http.Error(w, "unavailable", http.StatusServiceUnavailable)
		return
	}
	defer fh.Close()
	st, err := fh.Stat()
	if err != nil || st.Size() != f.Size || !st.ModTime().Equal(f.ModTime) {
		h.mu.Lock()
		first := !h.warned[f.Name]
		h.warned[f.Name] = true
		h.mu.Unlock()
		if first {
			h.log.Error("client packs: a pack changed since the server started -- it is not served (its hash is not the one clients were told); restart the server to name the new one",
				"pack", f.Name, "path", f.Path)
		}
		http.Error(w, "this pack changed on the server; ask its operator to restart it", http.StatusServiceUnavailable)
		return
	}
	w.Header().Set("Content-Type", "application/zip")
	// The hash as the entity tag: a resumed download's If-Range then only
	// continues the same file (http.ServeContent compares it).
	w.Header().Set("ETag", `"`+f.SHA256Hex()+`"`)
	w.Header().Set("Cache-Control", "no-cache")
	sw := &stallWriter{ResponseWriter: w, rc: http.NewResponseController(w), stall: h.lim.Stall}
	sw.arm()
	start := h.now()
	http.ServeContent(sw, r, "", f.ModTime, fh)
	if r.Method == http.MethodGet {
		h.log.Info("client pack served", "pack", f.Name, "addr", ip, "range", r.Header.Get("Range"), "bytes", sw.n,
			"ms", h.now().Sub(start).Milliseconds())
	}
}

// admit counts a request in, or says why not (0 when admitted).
func (h *Handler) admit(ip string) (int, string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	now := h.now()
	win := h.window[ip]
	if win == nil || now.Sub(win.start) >= time.Minute {
		win = &ipWindow{start: now}
		h.window[ip] = win
		// Forget windows long gone, so the map stays as small as the
		// clients of the last minute.
		if len(h.window) > 1024 {
			for k, v := range h.window {
				if now.Sub(v.start) >= time.Minute {
					delete(h.window, k)
				}
			}
		}
	}
	if win.n >= h.lim.PerMinute {
		return http.StatusTooManyRequests, "too many requests from this address; try again in a minute"
	}
	if h.perIP[ip] >= h.lim.PerIP {
		return http.StatusTooManyRequests, "too many downloads from this address at once"
	}
	if h.active >= h.lim.MaxActive {
		return http.StatusServiceUnavailable, "the server is busy serving packs; try again shortly"
	}
	win.n++
	h.perIP[ip]++
	h.active++
	return 0, ""
}

func (h *Handler) release(ip string) {
	h.mu.Lock()
	h.active--
	if h.perIP[ip]--; h.perIP[ip] <= 0 {
		delete(h.perIP, ip)
	}
	h.mu.Unlock()
}

func clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

// stallWriter moves the connection's write deadline forward before every
// write: a client that stops reading is cut off after `stall`, however long
// an honest download of a large pack takes.
type stallWriter struct {
	http.ResponseWriter
	rc    *http.ResponseController
	stall time.Duration
	n     int64
}

func (s *stallWriter) arm() { _ = s.rc.SetWriteDeadline(time.Now().Add(s.stall)) }

func (s *stallWriter) Write(p []byte) (int, error) {
	s.arm()
	n, err := s.ResponseWriter.Write(p)
	s.n += int64(n)
	return n, err
}

// Server is the listener: a plain http.Server around Handler with bounded
// header reads and idle connections.
func Server(addr string, h http.Handler) *http.Server {
	return &http.Server{
		Addr:    addr,
		Handler: h,
		// No ReadTimeout: net/http's background read would cancel a long
		// download's request when it expired; a GET has no body to bound.
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    8 << 10,
	}
}

// Listen binds addr now (so a port in use stops the server at startup, like
// the gateway's) and serves h until ctx ends.
func Listen(ctx context.Context, addr string, h http.Handler, logger *slog.Logger) (net.Addr, error) {
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return nil, fmt.Errorf("clientpacks: listening on %s: %w", addr, err)
	}
	srv := Server(addr, h)
	go func() {
		<-ctx.Done()
		sctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = srv.Shutdown(sctx)
	}()
	go func() {
		if err := srv.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) && logger != nil {
			logger.Error("client packs: the listener stopped", "err", err)
		}
	}()
	return ln.Addr(), nil
}

// ListenPort is the port of a listen address (":15780", "0.0.0.0:15780").
func ListenPort(addr net.Addr) uint16 {
	if t, ok := addr.(*net.TCPAddr); ok && t.Port > 0 && t.Port <= 0xffff {
		return uint16(t.Port)
	}
	return 0
}
