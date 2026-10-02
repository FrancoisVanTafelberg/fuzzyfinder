#+build linux
package fff

// The OS half of the metrics panel on Linux: getrusage for this process's
// CPU time, /proc for the rest.

import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:time"

@(private = "file")
proc_file :: proc(path: string) -> string {
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	return err == nil ? string(data) : ""
}

os_sample :: proc() -> (s: Os_Sample) {
	ru: linux.RUsage
	if linux.getrusage(.SELF, &ru) == .NONE {
		us := (ru.utime.seconds + ru.stime.seconds) * 1_000_000 + ru.utime.microseconds + ru.stime.microseconds
		s.proc_cpu = time.Duration(us) * time.Microsecond
		s.ok_cpu = true
	}

	// "cpu  user nice system idle iowait irq softirq steal ..." in clock
	// ticks; busy is everything but idle and iowait.
	if stat := proc_file("/proc/stat"); strings.has_prefix(stat, "cpu ") {
		first := stat[:strings.index_byte(stat, '\n')]
		fields := strings.fields(first[4:], context.temp_allocator)
		total, idle: i64
		for f, i in fields {
			if i >= 8 do break
			v, _ := strconv.parse_i64(f)
			total += v
			if i == 3 || i == 4 do idle += v
		}
		// Ticks are 1/100 s on every Linux that matters; only ratios are used.
		s.sys_total = time.Duration(total) * 10 * time.Millisecond
		s.sys_busy = time.Duration(total - idle) * 10 * time.Millisecond
		s.ok_sys = total > 0
	}

	// statm: "size resident shared ..." in pages.
	if statm := proc_file("/proc/self/statm"); statm != "" {
		fields := strings.fields(statm, context.temp_allocator)
		if len(fields) > 1 {
			pages, ok := strconv.parse_i64(fields[1])
			s.mem = pages * 4096
			s.ok_mem = ok
		}
	}

	// rchar: every byte read() returned, from disk or the page cache - which
	// is what reading a tree costs fff, cached or not.
	if io := proc_file("/proc/self/io"); io != "" {
		for line in strings.split_lines_iterator(&io) {
			if strings.has_prefix(line, "rchar:") {
				v, ok := strconv.parse_i64(strings.trim_space(line[6:]))
				s.io_read = v
				s.ok_io = ok
			}
		}
	}
	return
}
