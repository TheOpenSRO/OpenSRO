//go:build windows

package main

import "os"

// probe reports whether pid exists. Windows has no signal 0: opening the
// process is the probe.
func probe(pid int) error {
	p, err := os.FindProcess(pid)
	if err != nil {
		return err
	}
	return p.Release()
}

// terminate stops pid. Windows has no SIGTERM, so this is a kill: the bots'
// sessions end without a logout and the server times them out (OURS).
func terminate(pid int) error {
	p, err := os.FindProcess(pid)
	if err != nil {
		return err
	}
	return p.Kill()
}
