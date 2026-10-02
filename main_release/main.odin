package main_release

// Release entry point: fff linked straight in, no library swapping.
// Same call order as the hot-reload host, minus the reloading.

import fff "../source"

main :: proc() {
	fff.game_init_window()
	fff.game_init()

	for fff.game_update() {}

	fff.game_shutdown()
	fff.game_shutdown_window()
}
