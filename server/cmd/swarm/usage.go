package main

import (
	"os"
	"runtime"
	"strconv"
	"strings"
)

// selfUsage is this process's CPU time (user + system, seconds), resident
// memory (MB) and goroutine count, from /proc (Linux; zeros elsewhere).
func selfUsage() (cpu, rssMB float64, goroutines int) {
	goroutines = runtime.NumGoroutine()
	if b, err := os.ReadFile("/proc/self/stat"); err == nil {
		s := string(b)
		if i := strings.LastIndexByte(s, ')'); i > 0 {
			f := strings.Fields(s[i+1:])
			// Fields after the name: state is [0], utime [11], stime [12].
			if len(f) > 12 {
				u, _ := strconv.ParseFloat(f[11], 64)
				k, _ := strconv.ParseFloat(f[12], 64)
				cpu = (u + k) / 100 // USER_HZ, 100 on Linux
			}
		}
	}
	if b, err := os.ReadFile("/proc/self/statm"); err == nil {
		f := strings.Fields(string(b))
		if len(f) > 1 {
			pages, _ := strconv.ParseFloat(f[1], 64)
			rssMB = pages * float64(os.Getpagesize()) / (1 << 20)
		}
	}
	return cpu, rssMB, goroutines
}
