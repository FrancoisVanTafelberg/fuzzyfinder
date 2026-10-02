#+build windows
package fff

// The OS half of the metrics panel on Windows. Three of these calls are not in
// core:sys/windows, so they are declared here; all are kernel32 (the
// K32-prefixed memory call has been there since Windows 7).

import "core:time"
import win "core:sys/windows"

@(private = "file")
IO_COUNTERS :: struct {
	ReadOperationCount:  u64,
	WriteOperationCount: u64,
	OtherOperationCount: u64,
	ReadTransferCount:   u64,
	WriteTransferCount:  u64,
	OtherTransferCount:  u64,
}

@(private = "file")
PROCESS_MEMORY_COUNTERS :: struct {
	cb:                         win.DWORD,
	PageFaultCount:             win.DWORD,
	PeakWorkingSetSize:         uint,
	WorkingSetSize:             uint,
	QuotaPeakPagedPoolUsage:    uint,
	QuotaPagedPoolUsage:        uint,
	QuotaPeakNonPagedPoolUsage: uint,
	QuotaNonPagedPoolUsage:     uint,
	PagefileUsage:              uint,
	PeakPagefileUsage:          uint,
}

foreign import kernel32 "system:Kernel32.lib"

@(default_calling_convention = "system", private = "file")
foreign kernel32 {
	GetSystemTimes :: proc(idle, kernel, user: ^win.FILETIME) -> win.BOOL ---
	GetProcessIoCounters :: proc(process: win.HANDLE, counters: ^IO_COUNTERS) -> win.BOOL ---
	K32GetProcessMemoryInfo :: proc(process: win.HANDLE, counters: ^PROCESS_MEMORY_COUNTERS, cb: win.DWORD) -> win.BOOL ---
}

// FILETIME is in 100 ns units.
@(private = "file")
ft :: proc(f: win.FILETIME) -> time.Duration {
	return time.Duration((u64(f.dwHighDateTime) << 32 | u64(f.dwLowDateTime)) * 100)
}

os_sample :: proc() -> (s: Os_Sample) {
	me := win.GetCurrentProcess()
	created, exited, kernel, user: win.FILETIME
	if win.GetProcessTimes(me, &created, &exited, &kernel, &user) {
		s.proc_cpu = ft(kernel) + ft(user)
		s.ok_cpu = true
	}
	// System kernel time INCLUDES idle time.
	idle, skernel, suser: win.FILETIME
	if GetSystemTimes(&idle, &skernel, &suser) {
		s.sys_total = ft(skernel) + ft(suser)
		s.sys_busy = s.sys_total - ft(idle)
		s.ok_sys = true
	}
	pmc := PROCESS_MEMORY_COUNTERS {
		cb = size_of(PROCESS_MEMORY_COUNTERS),
	}
	if K32GetProcessMemoryInfo(me, &pmc, pmc.cb) {
		s.mem = i64(pmc.WorkingSetSize)
		s.ok_mem = true
	}
	io: IO_COUNTERS
	if GetProcessIoCounters(me, &io) {
		s.io_read = i64(io.ReadTransferCount)
		s.ok_io = true
	}
	return
}
