package efp

// The coverage census (round 619): how much of a real archive the typed
// decoder reads. It measures, per file, whether the header parses, whether the
// whole tree decodes with every byte consumed, and which features each file
// uses. It never stores or prints file contents, only counts and paths.

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"sort"
	"strings"
)

// Header reads just the magic, the version header and the root node's id and
// name: the part of a file the census calls "header parsed".
func Header(data []byte) (version, name string, err error) {
	if len(data) < magicLen+1+versionLen {
		return "", "", errors.New("efp: file too small to contain a header")
	}
	if string(data[:magicLen]) != magic {
		return "", "", fmt.Errorf("efp: bad magic %q, want %q", data[:magicLen], magic)
	}
	version = string(data[magicLen+1 : magicLen+1+versionLen])
	hs, err := headerSize(version)
	if err != nil {
		return version, "", err
	}
	r := &reader{b: data, off: magicLen + 1 + versionLen + hs}
	if _, err = r.u32(); err != nil {
		return version, "", err
	}
	name, err = r.str()
	return version, name, err
}

// Census accumulates coverage over many files.
type Census struct {
	Files        int
	HeaderOK     int
	Exact        int // decoded, zero bytes left
	TrailingZero int // decoded, only zero bytes left
	TrailingData int // decoded, non-zero bytes left
	Failed       int
	Versions     map[string]int
	HeaderFail   map[string]int // reason -> files
	DecodeFail   map[string]int // reason -> files
	Examples     map[string]string
	// Features counts files (not occurrences) per feature: "ctl:<key>",
	// "cmd:<name>", "type:<value type>", "view:<mode>", "render:<mode>",
	// "blend:additive|alpha|other", "extinct:<name>".
	Features map[string]int
	Nodes    int
}

// NewCensus returns an empty census.
func NewCensus() *Census {
	return &Census{
		Versions: map[string]int{}, HeaderFail: map[string]int{}, DecodeFail: map[string]int{},
		Examples: map[string]string{}, Features: map[string]int{},
	}
}

// reason trims an error to a stable bucket: the message up to " at offset".
func reason(err error) string {
	s := err.Error()
	if i := strings.Index(s, " at offset"); i >= 0 {
		s = s[:i]
	}
	if i := strings.Index(s, ": need "); i >= 0 {
		s = s[:i]
	}
	return s
}

// Add measures one file.
func (c *Census) Add(path string, data []byte) {
	c.Files++
	v, _, herr := Header(data)
	if herr != nil {
		k := reason(herr)
		if len(data) >= 8 && !bytes.HasPrefix(data, []byte(magic+" ")) {
			k = fmt.Sprintf("not JMXVEFF (starts %q)", data[:6])
		}
		c.HeaderFail[k]++
		c.Failed++
		if _, ok := c.Examples[k]; !ok {
			c.Examples[k] = path
		}
		return
	}
	c.HeaderOK++
	c.Versions[v]++
	f, err := Decode(data)
	if err != nil {
		c.Failed++
		k := reason(err)
		c.DecodeFail[k]++
		if _, ok := c.Examples[k]; !ok {
			c.Examples[k] = path
		}
		return
	}
	switch {
	case f.Trailing == 0:
		c.Exact++
	case bytes.Count(data[len(data)-f.Trailing:], []byte{0}) == f.Trailing:
		c.TrailingZero++
		if _, ok := c.Examples["trailing zeros"]; !ok {
			c.Examples["trailing zeros"] = path
		}
	default:
		c.TrailingData++
		if _, ok := c.Examples["trailing data"]; !ok {
			c.Examples["trailing data"] = path
		}
	}
	seen := map[string]bool{}
	mark := func(k string) { seen[k] = true }
	var cmds func([]Command)
	cmds = func(list []Command) {
		for _, cm := range list {
			mark("cmd:" + cm.Name)
			if cm.Value != nil {
				mark("type:" + cm.Value.TypeName())
			}
		}
	}
	f.Root.Walk(func(n *Node) {
		c.Nodes++
		for _, ct := range n.Controllers {
			mark("ctl:" + ct.Key)
			cmds(ct.Program)
		}
		for _, v := range n.Vars {
			mark("type:" + v.Type)
		}
		for _, l := range [][]Command{n.List90, n.Emit, n.ListD8, n.Update, n.List20C, n.Commands} {
			cmds(l)
		}
		for _, p := range []*Command{n.Extinct, n.View, n.Render} {
			if p != nil {
				cmds([]Command{*p})
			}
		}
		switch {
		case n.Loops():
			mark("life:loops (NormalTimeLoop)")
		case n.NeverExtinct():
			mark("life:never ends (NeverExtinct)")
		case n.Extinct != nil:
			mark("life:ends after its frames (" + n.Extinct.Name + ")")
		}
		if m := n.ViewMode(); m != "" {
			mark("view:" + m)
		}
		if m := n.RenderMode(); m != "" {
			mark("render:" + m)
			if m != "RenderNone" {
				mark(fmt.Sprintf("blend:src %d dest %d", n.State.SrcBlend, n.State.DestBlend))
				if n.State.Additive() {
					mark("blend:additive (dest ONE)")
				}
				mark(fmt.Sprintf("colorop:%d alphaop:%d", n.State.ColorOp, n.State.AlphaOp))
			}
		}
	})
	for k := range seen {
		c.Features[k]++
	}
}

// Decoded is the number of files whose tree decoded, however many bytes
// were left after it.
func (c *Census) Decoded() int { return c.Exact + c.TrailingZero + c.TrailingData }

func pct(n, d int) float64 {
	if d == 0 {
		return 0
	}
	return 100 * float64(n) / float64(d)
}

// Report writes the census as plain text.
func (c *Census) Report(w io.Writer) {
	fmt.Fprintf(w, "efp files:            %d\n", c.Files)
	fmt.Fprintf(w, "headers parsed:       %d (%.1f%%)\n", c.HeaderOK, pct(c.HeaderOK, c.Files))
	fmt.Fprintf(w, "tree decoded:         %d (%.1f%%)\n", c.Decoded(), pct(c.Decoded(), c.Files))
	fmt.Fprintf(w, "  exact, 0 bytes left: %d (%.1f%%)\n", c.Exact, pct(c.Exact, c.Files))
	fmt.Fprintf(w, "  zero padding after:  %d\n", c.TrailingZero)
	fmt.Fprintf(w, "  other bytes after:   %d\n", c.TrailingData)
	fmt.Fprintf(w, "failed:               %d\n", c.Failed)
	fmt.Fprintf(w, "nodes decoded:        %d\n", c.Nodes)
	section := func(title string, m map[string]int) {
		fmt.Fprintf(w, "\n%s\n", title)
		keys := make([]string, 0, len(m))
		for k := range m {
			keys = append(keys, k)
		}
		sort.Slice(keys, func(i, j int) bool {
			if m[keys[i]] != m[keys[j]] {
				return m[keys[i]] > m[keys[j]]
			}
			return keys[i] < keys[j]
		})
		for _, k := range keys {
			ex := ""
			if e, ok := c.Examples[k]; ok {
				ex = "  e.g. " + e
			}
			fmt.Fprintf(w, "  %6d  %s%s\n", m[k], k, ex)
		}
	}
	section("versions (header parsed)", c.Versions)
	section("header failures", c.HeaderFail)
	section("decode failures", c.DecodeFail)
	if e, ok := c.Examples["trailing zeros"]; ok {
		fmt.Fprintf(w, "\ntrailing zeros e.g. %s\n", e)
	}
	if e, ok := c.Examples["trailing data"]; ok {
		fmt.Fprintf(w, "trailing data e.g. %s\n", e)
	}
	section("features (files using each, among decoded files)", c.Features)
}
