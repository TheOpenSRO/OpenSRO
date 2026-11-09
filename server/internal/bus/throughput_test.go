package bus

import (
	"context"
	"encoding/binary"
	"os"
	"sort"
	"sync"
	"testing"
	"time"
)

// TestPostgresBusThroughput measures the LISTEN/NOTIFY bus between two
// processes' buses (round 869 lane W2, game_worlds.md 12.7: "bus messages per
// second and their delay"): publishers on one, a subscriber on the other,
// 200-byte messages (a delivery batch of a few packets). Run with
// OPENSRO_TEST_BUS_BENCH=1; it logs the rate and the delay percentiles.
func TestPostgresBusThroughput(t *testing.T) {
	if os.Getenv("OPENSRO_TEST_BUS_BENCH") == "" {
		t.Skip("OPENSRO_TEST_BUS_BENCH is not set")
	}
	a, b := openPG(t)
	const n, publishers = 20000, 8
	var mu sync.Mutex
	var delays []time.Duration
	done := make(chan struct{})
	b.Subscribe("host.bench", func(m []byte) {
		sent := time.Unix(0, int64(binary.LittleEndian.Uint64(m)))
		mu.Lock()
		delays = append(delays, time.Since(sent))
		if len(delays) == n {
			close(done)
		}
		mu.Unlock()
	})
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := b.WaitListening(ctx); err != nil {
		t.Fatal(err)
	}
	start := time.Now()
	var wg sync.WaitGroup
	for p := 0; p < publishers; p++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			msg := make([]byte, 200)
			for i := 0; i < n/publishers; i++ {
				binary.LittleEndian.PutUint64(msg, uint64(time.Now().UnixNano()))
				if err := a.Publish(context.Background(), "host.bench", msg); err != nil {
					t.Error(err)
					return
				}
			}
		}()
	}
	wg.Wait()
	pubTook := time.Since(start)
	select {
	case <-done:
	case <-time.After(60 * time.Second):
	}
	took := time.Since(start)
	mu.Lock()
	defer mu.Unlock()
	sort.Slice(delays, func(i, j int) bool { return delays[i] < delays[j] })
	if len(delays) == 0 {
		t.Fatal("nothing received")
	}
	pct := func(p float64) time.Duration { return delays[int(p*float64(len(delays)-1))] }
	t.Logf("%d of %d received; published in %v (%.0f/s), all received in %v (%.0f/s); delay p50 %v p99 %v max %v",
		len(delays), n, pubTook.Round(time.Millisecond), float64(n)/pubTook.Seconds(), took.Round(time.Millisecond),
		float64(len(delays))/took.Seconds(), pct(0.5).Round(time.Microsecond), pct(0.99).Round(time.Microsecond),
		delays[len(delays)-1].Round(time.Microsecond))
}
