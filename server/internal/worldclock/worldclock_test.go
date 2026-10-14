package worldclock

import (
	"testing"
	"time"
)

// The divisor is the binary's integer arithmetic: 30 * 1000 / 1440 = 20.
func TestOneGameSecondIsTwentyMilliseconds(t *testing.T) {
	if MsPerGameSecond != 20 {
		t.Fatalf("MsPerGameSecond = %d, want 20 (30000 / 1440 truncated)", MsPerGameSecond)
	}
	if RealDay != 1728*time.Second {
		t.Fatalf("RealDay = %v, want 28m48s", RealDay)
	}
}

func TestClockStartsAtMidnightAndAdvances(t *testing.T) {
	t0 := time.Unix(1_700_000_000, 0)
	c := New(t0, 0, 0, 0)
	cases := []struct {
		after time.Duration
		want  Time
	}{
		{0, Time{0, 0, 0, 0}},
		{19 * time.Millisecond, Time{0, 0, 0, 0}}, // integer division: not a whole step yet
		{20 * time.Millisecond, Time{0, 0, 0, 1}},
		{1200 * time.Millisecond, Time{0, 0, 1, 0}},      // 60 game seconds
		{72 * time.Second, Time{0, 1, 0, 0}},             // 3600 x 20 ms
		{12 * 72 * time.Second, Time{0, 12, 0, 0}},       // noon after 14 min 24 s
		{RealDay, Time{1, 0, 0, 0}},                      // the next day
		{RealDay + 20*72*time.Second, Time{1, 20, 0, 0}}, // day 1, 20:00
		{-time.Second, Time{0, 0, 0, 0}},                 // a clock never runs backwards
	}
	for _, tc := range cases {
		if got := c.At(t0.Add(tc.after)); got != tc.want {
			t.Errorf("after %v: %v, want %v", tc.after, got, tc.want)
		}
	}
}

func TestStartFlagBase(t *testing.T) {
	t0 := time.Unix(1_700_000_000, 0)
	c := New(t0, 0, 14, 30)
	if got := c.At(t0); got != (Time{0, 14, 30, 0}) {
		t.Fatalf("start 14:30: %v", got)
	}
	if got := c.At(t0.Add(10 * 72 * time.Second)); got != (Time{1, 0, 30, 0}) {
		t.Fatalf("ten game hours later: %v, want day 1 00:30", got)
	}
}

// The operator's set-hour keeps the day and the minute, zeroes the second and
// clamps above 22 to 23 (READ, 0x412be0).
func TestSetHour(t *testing.T) {
	t0 := time.Unix(1_700_000_000, 0)
	c := New(t0, 3, 5, 41)
	now := t0.Add(37 * 20 * time.Millisecond) // 05:41:37
	if got := c.At(now); got != (Time{3, 5, 41, 37}) {
		t.Fatalf("before: %v", got)
	}
	if got := c.SetHour(now, 18); got != (Time{3, 18, 41, 0}) {
		t.Fatalf("SetHour 18: %v", got)
	}
	if got := c.At(now.Add(20 * time.Millisecond)); got != (Time{3, 18, 41, 1}) {
		t.Fatalf("runs on: %v", got)
	}
	if got := c.SetHour(now, 200); got.Hour != 23 {
		t.Fatalf("SetHour 200: hour %d, want 23", got.Hour)
	}
}

func TestParseStart(t *testing.T) {
	if h, m, err := ParseStart(""); err != nil || h != 0 || m != 0 {
		t.Fatalf("empty: %d %d %v", h, m, err)
	}
	if h, m, err := ParseStart("06:15"); err != nil || h != 6 || m != 15 {
		t.Fatalf("06:15: %d %d %v", h, m, err)
	}
	for _, bad := range []string{"24:00", "12:60", "noon", "-1:00"} {
		if _, _, err := ParseStart(bad); err == nil {
			t.Errorf("%q accepted", bad)
		}
	}
}
