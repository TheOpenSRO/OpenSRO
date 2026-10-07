//go:build !windows

package main

import "syscall"

// probe reports whether pid exists (signal 0).
func probe(pid int) error { return syscall.Kill(pid, 0) }

// terminate asks pid to stop (SIGTERM: the swarm logs its bots out first).
func terminate(pid int) error { return syscall.Kill(pid, syscall.SIGTERM) }
