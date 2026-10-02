package ignore

// odin test source/ignore

import "core:testing"

@(test)
normalising :: proc(t: ^testing.T) {
	a := normalize_folder(" build ")
	defer delete(a)
	testing.expect_value(t, a, "build/")
	b := normalize_folder("source\\rlu\\")
	defer delete(b)
	testing.expect_value(t, b, "source/rlu/")
	testing.expect_value(t, normalize_folder("  "), "")
	c := normalize_type("*.LOG")
	defer delete(c)
	testing.expect_value(t, c, "log")
}

@(test)
name_entries_match_anywhere :: proc(t: ^testing.T) {
	testing.expect(t, folder_entry_matches("build/", "build"))
	testing.expect(t, folder_entry_matches("build/", "a/b/build"))
	testing.expect(t, !folder_entry_matches("build/", "builder"))
	testing.expect(t, folder_entry_matches("node_*/", "web/node_modules"))
}

@(test)
anchored_entries_match_from_the_root :: proc(t: ^testing.T) {
	testing.expect(t, folder_entry_matches("/source/rlu/", "source/rlu"))
	testing.expect(t, folder_entry_matches("/source/rlu/", "source/rlu/deeper"))
	testing.expect(t, !folder_entry_matches("/source/rlu/", "other/source/rlu"))
	testing.expect(t, !folder_entry_matches("/source/rlu/", "source/rlux"))
}

@(test)
files_are_hidden_by_type_and_folder :: proc(t: ^testing.T) {
	r: Rules
	defer destroy(&r)
	add_type(&r, "log")
	add_folder(&r, "build")
	lists := []^Rules{&r}
	testing.expect(t, file_ignored(lists, "x/y/out.LOG"))
	testing.expect(t, file_ignored(lists, "x/build/main.c"))
	testing.expect(t, !file_ignored(lists, "x/builder/main.c"))
	testing.expect(t, !file_ignored(lists, ".gitignore"))
	testing.expect(t, !add_type(&r, "*.Log"), "duplicates are refused")
}
