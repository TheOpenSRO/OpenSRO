package skilljob

import (
	"context"
	"testing"
	"time"
)

// The memory store: a put replaces the character's job of that skill, the
// list is oldest end first, and ended jobs are dropped on request.
func TestMemStore(t *testing.T) {
	ctx := context.Background()
	s := NewMemStore()
	now := time.Date(2026, 10, 27, 12, 0, 0, 0, time.UTC)
	_ = s.Put(ctx, Job{CharacterID: 1, SkillID: 10, Until: now.Add(2 * time.Hour)})
	_ = s.Put(ctx, Job{CharacterID: 1, SkillID: 11, Until: now.Add(time.Hour)})
	_ = s.Put(ctx, Job{CharacterID: 1, SkillID: 10, ItemID: 7, Until: now.Add(3 * time.Hour)})
	_ = s.Put(ctx, Job{CharacterID: 2, SkillID: 10, Until: now.Add(time.Hour)})
	js, _ := s.List(ctx, 1)
	if len(js) != 2 || js[0].SkillID != 11 || js[1].SkillID != 10 || js[1].ItemID != 7 {
		t.Fatalf("jobs %+v, want 11 then the replaced 10", js)
	}
	_ = s.DeleteEnded(ctx, 1, now.Add(time.Hour))
	if js, _ := s.List(ctx, 1); len(js) != 1 || js[0].SkillID != 10 {
		t.Errorf("after the first job's end: %+v", js)
	}
	_ = s.Delete(ctx, 1, 10)
	if js, _ := s.List(ctx, 1); len(js) != 0 {
		t.Errorf("after the delete: %+v", js)
	}
	if js, _ := s.List(ctx, 2); len(js) != 1 {
		t.Errorf("another character's job went: %+v", js)
	}
}
