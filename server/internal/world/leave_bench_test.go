package world

import (
	"fmt"
	"testing"

	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
)

// crowdHub is n characters standing in one view window (a 60-unit square,
// inside one 320-unit block), as the swarm stands them on Jangan's plaza.
func crowdHub(n int) (*Hub, []*gateway.Session) {
	h := NewHub()
	sess := make([]*gateway.Session, n)
	for i := range sess {
		sess[i] = gateway.NewTestSession(uint64(i + 1))
		h.Enter(sess[i], int64(i+1), fmt.Sprintf("c%d", i), 10, "jangan", Position{X: float64(i % 60), Z: float64(i / 60 % 60)})
	}
	return h, sess
}

// BenchmarkLeaveInCrowd is one character leaving a crowd of n and coming
// back: the write lock's hold for a disconnect (and an arrival) in the plaza.
func BenchmarkLeaveInCrowd(b *testing.B) {
	for _, n := range []int{1000, 3000, 7000} {
		b.Run(fmt.Sprint(n), func(b *testing.B) {
			h, sess := crowdHub(n)
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				s := sess[i%n]
				left, _, ok := h.Leave(s)
				if !ok {
					b.Fatal("not in the world")
				}
				b.StopTimer()
				h.Enter(s, left.CharacterID, left.Name, 10, "jangan", left.Pos)
				b.StartTimer()
			}
		})
	}
}

// BenchmarkEnterInCrowd is one character arriving in a crowd of n: the write
// lock's hold for an arrival (its snapshot of everyone in view).
func BenchmarkEnterInCrowd(b *testing.B) {
	for _, n := range []int{1000, 3000, 7000} {
		b.Run(fmt.Sprint(n), func(b *testing.B) {
			h, sess := crowdHub(n)
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				s := sess[i%n]
				b.StopTimer()
				left, _, _ := h.Leave(s)
				b.StartTimer()
				h.Enter(s, left.CharacterID, left.Name, 10, "jangan", left.Pos)
			}
		})
	}
}
