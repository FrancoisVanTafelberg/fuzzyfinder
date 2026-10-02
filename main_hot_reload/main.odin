package main_hot_reload

/*
    Hot-reload host. Taken from the Music Box (itself from Animal Kingdoms),
    with one change: the library is found next to the EXE rather than in the
    working directory, because fff's working directory is the folder being
    searched - you can run build/fff_dev from anywhere.

    A thin executable whose only job is to own the window's lifetime and swap
    the game library underneath it. Build with build_hot_reload while this is
    running and the new code is live within a frame, with the index, the
    query and the scroll position intact.

    Two details that are easy to get wrong:

      * The library is COPIED to a uniquely named file before loading. Windows
        holds an exclusive lock on a loaded DLL, so without the copy the
        compiler cannot overwrite it and the rebuild fails with a file-in-use
        error that looks like a compiler bug.

      * Game state lives in a single heap block the host holds a pointer to.
        The library is unloaded — taking its globals with it — before the new
        one is handed that same pointer back.

    Structure follows Karl Zylinski's odin-raylib-hot-reload-game-template.
*/

import "core:dynlib"
import "core:fmt"
import "core:os"
import "core:time"

// The host reads the library's timestamp with os.last_write_time_by_name, which
// returns time.Time only on a current Odin; older ones return os.File_Time and
// fail here with a type error that says nothing useful. The app package has the
// same floor (core:os was rebuilt on os2 during 2025-2026).
when ODIN_VERSION < "dev-2026-06" {
	#panic("fff needs Odin dev-2026-06 or newer, and this compiler is " + ODIN_VERSION + ".")
}

when ODIN_OS == .Windows {
	DLL_EXT :: ".dll"
} else when ODIN_OS == .Darwin {
	DLL_EXT :: ".dylib"
} else {
	DLL_EXT :: ".so"
}

// Which library this host runs: hot_reload/fff.dll, next to this exe.
GAME_NAME :: #config(GAME_NAME, "fff")

// Set once in main: <exe dir>/hot_reload/ and the library inside it.
dll_dir: string
dll_path: string

Game_API :: struct {
	// Bound automatically from exported symbols named game_<field>.
	init_window:       proc(),
	init:              proc(),
	update:            proc() -> bool,
	shutdown:          proc(),
	shutdown_window:   proc(),
	memory:            proc() -> rawptr,
	memory_size:       proc() -> int,
	hot_reloaded:      proc(_: rawptr),
	force_reload:      proc() -> bool,
	force_restart:     proc() -> bool,

	// Bookkeeping
	__handle:          dynlib.Library,
	modification_time: time.Time,
	version:           int,
}

load_game_api :: proc(version: int) -> (api: Game_API, ok: bool) {
	mod_time, mod_err := os.last_write_time_by_name(dll_path)
	if mod_err != nil {
		fmt.eprintfln("could not stat %s: %v", dll_path, mod_err)
		return
	}

	// Unique name per load so the old file can be replaced while in use.
	copy_path := fmt.tprintf("%s%s_%i%s", dll_dir, GAME_NAME, version, DLL_EXT)

	// Copied by reading and writing it rather than by shelling out to copy/cp.
	//
	// That used libc.system, and libc is a trap on Windows: `core:c/libc` does
	// `foreign import "system:libucrt.lib"`, the STATIC C runtime, while raylib
	// and Odin's own runtime bring in the DYNAMIC one. Two runtimes in one link
	// is a page of LNK2005 "already defined" errors. This host does not link
	// raylib so it never hit that — but it is one import away from it, and the
	// next person to reach for libc.system will not know why the build broke.
	//
	// Doing it in Odin is also better behaved: no shell, no quoting, and an
	// error we can report.
	{
		data, read_err := os.read_entire_file_from_path(dll_path, context.temp_allocator)
		if read_err != nil {
			fmt.eprintfln("could not read %s: %v", dll_path, read_err)
			return
		}
		if write_err := os.write_entire_file(copy_path, data); write_err != nil {
			fmt.eprintfln("could not write %s: %v", copy_path, write_err)
			return
		}
	}

	if _, sym_ok := dynlib.initialize_symbols(&api, copy_path, "game_", "__handle"); !sym_ok {
		fmt.eprintfln("failed to bind symbols: %s", dynlib.last_error())
		return
	}

	api.modification_time = mod_time
	api.version = version
	return api, true
}

unload_game_api :: proc(api: ^Game_API) {
	if api.__handle != nil {
		if !dynlib.unload_library(api.__handle) {
			fmt.eprintfln("failed to unload library: %s", dynlib.last_error())
		}
	}
	// Best effort: on Windows the file can still be locked for a moment after
	// the unload, and a leftover copy costs nothing but a megabyte.
	del := fmt.tprintf("%s%s_%i%s", dll_dir, GAME_NAME, api.version, DLL_EXT)
	os.remove(del)
}

main :: proc() {
	exe_dir, _ := os.get_executable_directory(context.allocator)
	dll_dir = fmt.aprintf("%s/hot_reload/", exe_dir)
	dll_path = fmt.aprintf("%s%s%s", dll_dir, GAME_NAME, DLL_EXT)

	// The library cannot see argv, so a folder to search is handed over as
	// the working directory: `fff_dev path\to\project`.
	for a in os.args[1:] {
		if len(a) > 0 && a[0] == '-' do continue
		if err := os.set_working_directory(a); err != nil {
			fmt.eprintfln("cannot search %s: %v", a, err)
			os.exit(1)
		}
		break
	}

	version := 0
	api, ok := load_game_api(version)
	if !ok {
		fmt.eprintfln("could not load %s - run build_hot_reload first", dll_path)
		os.exit(1)
	}
	version += 1

	api.init_window()
	api.init()

	old_apis: [dynamic]Game_API
	defer delete(old_apis)

	for api.update() {
		reload := api.force_reload()
		restart := api.force_restart()

		if mt, err := os.last_write_time_by_name(dll_path); err == nil && mt != api.modification_time {
			reload = true
		}

		if !reload && !restart do continue

		new_api, load_ok := load_game_api(version)
		if !load_ok do continue

		// A layout change means the old block can no longer be reinterpreted;
		// fall back to a restart rather than corrupting it.
		layout_changed := new_api.memory_size() != api.memory_size()

		if layout_changed || restart {
			api.shutdown()
			for &old in old_apis do unload_game_api(&old)
			clear(&old_apis)
			unload_game_api(&api)
			api = new_api
			api.init()
		} else {
			mem := api.memory()
			// Keep the old handle around: unloading it immediately can pull
			// the rug from under a callback still on the stack.
			append(&old_apis, api)
			api = new_api
			api.hot_reloaded(mem)
		}
		version += 1
		fmt.printfln("[hot reload] v%i  %v", api.version, time.now())
	}

	api.shutdown()
	api.shutdown_window()
	for &old in old_apis do unload_game_api(&old)
	unload_game_api(&api)
}
