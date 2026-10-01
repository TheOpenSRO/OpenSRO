package main

import (
	"bytes"
	"log/slog"
	"strings"
	"testing"

	"github.com/OpenSRO/srrevamp/server/internal/session"
)

// Round 678: the startup lines. Nothing set says the client keeps its
// defaults; an intro the archive does not carry says where the client looks
// and what it falls back to.
func TestFrontEndThemeFromFlagsLogs(t *testing.T) {
	var buf bytes.Buffer
	logger := slog.New(slog.NewTextHandler(&buf, nil))

	if theme := frontEndThemeFromFlags(session.FrontEndTheme{}, logger); !theme.IsDefault() {
		t.Errorf("nothing set served %+v", theme)
	}
	if !strings.Contains(buf.String(), `level=INFO msg="front-end theme: client defaults`) {
		t.Errorf("no defaults line:\n%s", buf.String())
	}

	buf.Reset()
	theme := frontEndThemeFromFlags(session.FrontEndTheme{Intro: "myserver", Logo: "../x.png"}, logger)
	if theme.Intro != "myserver" || theme.Logo != "" {
		t.Errorf("served %+v", theme)
	}
	for _, want := range []string{
		`level=WARN msg="front-end logo \"../x.png\" is not a valid image file name`,
		`level=INFO msg="front-end intro \"myserver\" is not a retail intro: the client must have custom/intro/myserver.txt, or it falls back to option.txt's IntroName"`,
		`level=INFO msg="front-end theme" intro=myserver bgm="" logo="" copyright="" band_top="" band_bottom=""`,
	} {
		if !strings.Contains(buf.String(), want) {
			t.Errorf("no line containing\n %s\nin\n%s", want, buf.String())
		}
	}
}
