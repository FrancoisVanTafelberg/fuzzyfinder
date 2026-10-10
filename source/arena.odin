package fff

/*
    Where file text and line tables live: big blocks straight from the OS,
    handed out front to back.

    One heap allocation per file meant one more call per file, memory zeroed
    that was about to be overwritten, and on rebuild one free per file. A
    reader instead fills ARENA_BLOCK-sized blocks; a file too big to share a
    block gets a block of its own. Blocks come from the OS untouched (pages
    are only made real when first written) and go back whole when the index
    is freed.

    One arena per reader thread, so no locking.
*/

import "core:mem/virtual"

ARENA_BLOCK :: 16 << 20
// Bigger than this and a file gets a block to itself, so a block is never
// mostly wasted.
ARENA_OWN :: ARENA_BLOCK / 4

Arena :: struct {
	blocks: [dynamic][]u8, // every block, to give back
	cur:    []u8,
	used:   int,
}

// `n` bytes, aligned to `align`. Not zeroed (fresh blocks happen to be).
arena_alloc :: proc(a: ^Arena, n: int, align := 1) -> []u8 {
	if n > ARENA_OWN {
		size := (n + 4095) &~ 4095
		block, err := virtual.reserve_and_commit(uint(size))
		if err != nil do return nil
		if size >= 2 << 20 do memory_hint_huge(block)
		append(&a.blocks, block)
		return block[:n]
	}
	at := (a.used + align - 1) &~ (align - 1)
	if a.cur == nil || at + n > len(a.cur) {
		block, err := virtual.reserve_and_commit(ARENA_BLOCK)
		if err != nil do return nil
		memory_hint_huge(block)
		append(&a.blocks, block)
		a.cur = block
		at = 0
	}
	a.used = at + n
	return a.cur[at:][:n]
}

// Give back the most recent allocation, or shrink it to `keep` bytes. Only
// for the allocation just made: a file that turned out to be binary.
arena_trim :: proc(a: ^Arena, last: []u8, keep := 0) {
	if len(last) == 0 do return
	if len(a.blocks) > 0 && raw_data(a.blocks[len(a.blocks) - 1]) == raw_data(last) && raw_data(last) != raw_data(a.cur) {
		// It had a block to itself.
		if keep == 0 {
			b := pop(&a.blocks)
			virtual.release(raw_data(b), uint(len(b)))
		}
		return
	}
	if a.cur != nil && raw_data(last) >= raw_data(a.cur) && uintptr(raw_data(last)) + uintptr(len(last)) == uintptr(raw_data(a.cur)) + uintptr(a.used) {
		a.used -= len(last) - keep
	}
}

arena_release :: proc(a: ^Arena) {
	for b in a.blocks do virtual.release(raw_data(b), uint(len(b)))
	delete(a.blocks)
	a^ = {}
}

// What the arena holds from the OS.
arena_size :: proc(a: ^Arena) -> i64 {
	total: i64
	for b in a.blocks do total += i64(len(b))
	return total
}
