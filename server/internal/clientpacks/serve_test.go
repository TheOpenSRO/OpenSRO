package clientpacks

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func servedSet(t *testing.T) (*Built, []byte, string) {
	t.Helper()
	dir := t.TempDir()
	content := map[string]string{}
	for i := 0; i < 40; i++ {
		content[fmt.Sprintf("f%02d.txt", i)] = strings.Repeat(fmt.Sprint(i), 1000)
	}
	zb := writeZip(t, filepath.Join(dir, "z_test.pk3"), content)
	b, err := Build(Options{Dir: dir, HTTPPort: 15780})
	if err != nil {
		t.Fatal(err)
	}
	return b, zb, dir
}

func get(t *testing.T, h http.Handler, method, path string, hdr map[string]string, remote string) *httptest.ResponseRecorder {
	t.Helper()
	r := httptest.NewRequest(method, path, nil)
	if remote != "" {
		r.RemoteAddr = remote
	}
	for k, v := range hdr {
		r.Header.Set(k, v)
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}

func TestServeOnlyTheListedPacks(t *testing.T) {
	b, zb, dir := servedSet(t)
	os.WriteFile(filepath.Join(dir, "secret.txt"), []byte("no"), 0o644)
	h := NewHandler(b, ServeLimits{PerMinute: 1000}, nil)
	w := get(t, h, "GET", "/packs/z_test.pk3", nil, "")
	if w.Code != 200 || !bytes.Equal(w.Body.Bytes(), zb) {
		t.Fatalf("GET: %d, %d bytes", w.Code, w.Body.Len())
	}
	if et := w.Header().Get("ETag"); et != `"`+b.Files[0].SHA256Hex()+`"` {
		t.Fatalf("ETag %s", et)
	}
	if w := get(t, h, "HEAD", "/packs/z_test.pk3", nil, ""); w.Code != 200 || w.Body.Len() != 0 ||
		w.Header().Get("Content-Length") != fmt.Sprint(len(zb)) {
		t.Fatalf("HEAD: %d %d %s", w.Code, w.Body.Len(), w.Header().Get("Content-Length"))
	}
	for _, p := range []string{"/", "/packs/", "/packs", "/packs/secret.txt", "/packs/Z_TEST.PK3", "/packs/../z_test.pk3",
		"/z_test.pk3", "/packs/z_test.pk3/", "/packs/sub/z_test.pk3", "/packs/%2e%2e%2fsecret.txt"} {
		if w := get(t, h, "GET", p, nil, ""); w.Code != 404 {
			t.Errorf("%s: %d, want 404", p, w.Code)
		}
	}
	if w := get(t, h, "POST", "/packs/z_test.pk3", nil, ""); w.Code != 405 {
		t.Errorf("POST: %d", w.Code)
	}
}

func TestServeRanges(t *testing.T) {
	b, zb, _ := servedSet(t)
	h := NewHandler(b, ServeLimits{PerMinute: 1000}, nil)
	w := get(t, h, "GET", "/packs/z_test.pk3", map[string]string{"Range": "bytes=100-"}, "")
	if w.Code != 206 || !bytes.Equal(w.Body.Bytes(), zb[100:]) {
		t.Fatalf("range: %d, %d bytes", w.Code, w.Body.Len())
	}
	if cr := w.Header().Get("Content-Range"); cr != fmt.Sprintf("bytes 100-%d/%d", len(zb)-1, len(zb)) {
		t.Fatalf("Content-Range %s", cr)
	}
	// A resume of the same file (If-Range = its hash) continues; one of
	// another file starts over.
	w = get(t, h, "GET", "/packs/z_test.pk3", map[string]string{"Range": "bytes=10-", "If-Range": `"` + b.Files[0].SHA256Hex() + `"`}, "")
	if w.Code != 206 {
		t.Fatalf("If-Range same: %d", w.Code)
	}
	w = get(t, h, "GET", "/packs/z_test.pk3", map[string]string{"Range": "bytes=10-", "If-Range": `"00"`}, "")
	if w.Code != 200 || w.Body.Len() != len(zb) {
		t.Fatalf("If-Range other: %d", w.Code)
	}
	if w := get(t, h, "GET", "/packs/z_test.pk3", map[string]string{"Range": fmt.Sprintf("bytes=%d-", len(zb)+5)}, ""); w.Code != 416 {
		t.Fatalf("past the end: %d", w.Code)
	}
}

func TestServeRefusesAChangedPack(t *testing.T) {
	b, _, dir := servedSet(t)
	h := NewHandler(b, ServeLimits{PerMinute: 1000}, nil)
	writeZip(t, filepath.Join(dir, "z_test.pk3"), map[string]string{"other": "content"})
	if w := get(t, h, "GET", "/packs/z_test.pk3", nil, ""); w.Code != 503 {
		t.Fatalf("changed pack: %d", w.Code)
	}
}

func TestServeLimits(t *testing.T) {
	b, _, _ := servedSet(t)
	h := NewHandler(b, ServeLimits{PerMinute: 3, PerIP: 1, MaxActive: 2}, nil)
	now := time.Unix(1000, 0)
	h.now = func() time.Time { return now }
	for i := 0; i < 3; i++ {
		if w := get(t, h, "GET", "/packs/z_test.pk3", nil, "10.0.0.1:5000"); w.Code != 200 {
			t.Fatalf("request %d: %d", i, w.Code)
		}
	}
	if w := get(t, h, "GET", "/packs/z_test.pk3", nil, "10.0.0.1:5001"); w.Code != 429 || w.Header().Get("Retry-After") == "" {
		t.Fatalf("4th in a minute: %d", w.Code)
	}
	if w := get(t, h, "GET", "/packs/z_test.pk3", nil, "10.0.0.2:5000"); w.Code != 200 {
		t.Fatalf("another address: %d", w.Code)
	}
	now = now.Add(time.Minute)
	if w := get(t, h, "GET", "/packs/z_test.pk3", nil, "10.0.0.1:5000"); w.Code != 200 {
		t.Fatalf("a minute later: %d", w.Code)
	}
	// At once: the per-address and the total caps.
	if c, _ := h.admit("10.0.0.3"); c != 0 {
		t.Fatal(c)
	}
	if c, _ := h.admit("10.0.0.3"); c != http.StatusTooManyRequests {
		t.Fatalf("2nd at once from one address: %d", c)
	}
	if c, _ := h.admit("10.0.0.4"); c != 0 {
		t.Fatal(c)
	}
	if c, _ := h.admit("10.0.0.5"); c != http.StatusServiceUnavailable {
		t.Fatalf("3rd at once: %d", c)
	}
	h.release("10.0.0.3")
	h.release("10.0.0.4")
	if h.active != 0 || len(h.perIP) != 0 {
		t.Fatalf("active %d perIP %v", h.active, h.perIP)
	}
}

// The real listener: a download cut short and resumed with a range gives the
// whole file, as the client does it.
func TestListenResume(t *testing.T) {
	b, zb, _ := servedSet(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	addr, err := Listen(ctx, "127.0.0.1:0", NewHandler(b, ServeLimits{PerMinute: 1000}, nil), nil)
	if err != nil {
		t.Fatal(err)
	}
	if ListenPort(addr) == 0 {
		t.Fatal("no port")
	}
	url := "http://" + addr.String() + "/packs/z_test.pk3"
	resp, err := http.Get(url)
	if err != nil {
		t.Fatal(err)
	}
	part := make([]byte, 1000)
	if _, err := io.ReadFull(resp.Body, part); err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	req, _ := http.NewRequest("GET", url, nil)
	req.Header.Set("Range", "bytes=1000-")
	resp, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	rest, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != 206 || !bytes.Equal(append(part, rest...), zb) {
		t.Fatalf("resume: %d, %d+%d bytes of %d", resp.StatusCode, len(part), len(rest), len(zb))
	}
	resp, err = http.Get("http://" + addr.String() + "/")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 404 {
		t.Fatalf("listing: %d", resp.StatusCode)
	}
}
