#+build !windows
package fff

/*
    Browse... on Linux: whichever desktop folder picker is installed - zenity
    (GNOME and most others) or kdialog (KDE) - opened at the current root.
    Run on its own thread (root_bar.odin), so fff keeps drawing.
*/

import "core:os"
import "core:strings"

// Ask for a folder. ok false: cancelled. `problem` says why there was no
// dialog at all.
pick_folder :: proc(start: string, allocator := context.allocator) -> (path: string, ok: bool, problem: string) {
	tries := [?][]string {
		{"zenity", "--file-selection", "--directory", "--title=Folder to search", strings.concatenate({start, "/"}, context.temp_allocator)},
		{"kdialog", "--getexistingdirectory", start, "--title", "Folder to search"},
	}
	for cmd in tries {
		c := cmd
		if cmd[0] == "zenity" do c = {cmd[0], cmd[1], cmd[2], cmd[3], strings.concatenate({"--filename=", cmd[4]}, context.temp_allocator)}
		state, out, _, err := os.process_exec({command = c}, context.temp_allocator)
		if err != nil do continue // not installed: try the next
		if !state.exited || state.exit_code != 0 do return "", false, "" // cancelled
		p := strings.trim_space(string(out))
		if p == "" do return "", false, ""
		return strings.clone(p, allocator), true, ""
	}
	return "", false, "no folder picker found (install zenity or kdialog) - type the path instead"
}
