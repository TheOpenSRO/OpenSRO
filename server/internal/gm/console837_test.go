package gm

import (
	"os"
	"regexp"
	"strings"
	"testing"
)

// TestConsoleListsEveryCommand: the client's console forwards only the GM
// words in its GM_COMMANDS list (client/scripts/ui/console.gd), so every word
// this package dispatches must be there (round 837: /silk was not).
func TestConsoleListsEveryCommand(t *testing.T) {
	src, err := os.ReadFile("gm.go")
	if err != nil {
		t.Fatal(err)
	}
	console, err := os.ReadFile("../../../client/scripts/ui/console.gd")
	if err != nil {
		t.Skip("no client tree beside the server:", err)
	}
	block := string(src)
	start := strings.Index(block, "switch cmd {")
	if start < 0 {
		t.Fatal("no dispatcher switch in gm.go")
	}
	block = block[start:]
	if end := strings.Index(block, "\n\t}\n"); end > 0 {
		block = block[:end]
	}
	listLine := regexp.MustCompile(`const GM_COMMANDS := \[([^\]]*)\]`).FindSubmatch(console)
	if listLine == nil {
		t.Fatal("no GM_COMMANDS in console.gd")
	}
	listed := map[string]bool{}
	for _, m := range regexp.MustCompile(`"([a-z]+)"`).FindAllSubmatch(listLine[1], -1) {
		listed[string(m[1])] = true
	}
	for _, m := range regexp.MustCompile(`case "([a-z]+)"`).FindAllStringSubmatch(block, -1) {
		if !listed[m[1]] {
			t.Errorf("/%s is dispatched by the server but not forwarded by the client console", m[1])
		}
	}
}
