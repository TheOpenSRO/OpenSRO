package main

import (
	"archive/zip"
	"bytes"
	"context"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Round 789, lane U: the -client-packs flags.

func packDir(t *testing.T) (string, []byte) {
	t.Helper()
	dir := t.TempDir()
	var buf bytes.Buffer
	zw := zip.NewWriter(&buf)
	w, _ := zw.Create("server_dep/silkroad/textdata/test.txt")
	w.Write([]byte("hello"))
	zw.Close()
	if err := os.WriteFile(filepath.Join(dir, "z_test.pk3"), buf.Bytes(), 0o644); err != nil {
		t.Fatal(err)
	}
	return dir, buf.Bytes()
}

func TestStartClientPacksNone(t *testing.T) {
	var log bytes.Buffer
	m, err := startClientPacks(context.Background(), "", "https://x/p", "", false, slog.New(slog.NewTextHandler(&log, nil)))
	if err != nil || m.Required || len(m.Packs) != 0 {
		t.Fatalf("%+v %v", m, err)
	}
	if !strings.Contains(log.String(), "do nothing without -client-packs") {
		t.Fatalf("log: %s", log.String())
	}
}

func TestStartClientPacksServesThem(t *testing.T) {
	dir, zb := packDir(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var log bytes.Buffer
	m, err := startClientPacks(ctx, dir, "", "127.0.0.1:0", false, slog.New(slog.NewTextHandler(&log, nil)))
	if err != nil {
		t.Fatal(err)
	}
	if !m.Required || m.HTTPPort == 0 || len(m.Packs) != 1 || m.Packs[0].URL != "" {
		t.Fatalf("%+v", m)
	}
	resp, err := http.Get(fmt.Sprintf("http://127.0.0.1:%d/packs/z_test.pk3", m.HTTPPort))
	if err != nil {
		t.Fatal(err)
	}
	got, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != 200 || !bytes.Equal(got, zb) {
		t.Fatalf("%d, %d bytes", resp.StatusCode, len(got))
	}
	if !strings.Contains(log.String(), "named to every client before login") || !strings.Contains(log.String(), "z_test.pk3") {
		t.Fatalf("log: %s", log.String())
	}
}

func TestStartClientPacksURLTurnsTheListenerOff(t *testing.T) {
	dir, _ := packDir(t)
	m, err := startClientPacks(context.Background(), dir, "https://cdn.example.com/p", "", true, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	if m.HTTPPort != 0 || m.Packs[0].URL != "https://cdn.example.com/p/z_test.pk3" || !m.LocalExtras {
		t.Fatalf("%+v", m)
	}
	if _, err := startClientPacks(context.Background(), dir, "", "off", false, slog.New(slog.NewTextHandler(io.Discard, nil))); err == nil {
		t.Fatal("no URL and the listener off: accepted")
	}
}
