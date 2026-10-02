#+build !windows
#+build !linux
package fff

// No OS counters on this platform yet; fff's own still work.
os_sample :: proc() -> Os_Sample {
	return {}
}
