package fff

/*
    Byte scanning, 32 bytes at a time. Finding line ends and finding a query's
    rarest character are the two loops that touch every byte of the index, so
    they get SIMD; everything else works a line at a time.
*/

import "base:intrinsics"
import "core:bytes"
import "core:simd"

@(private = "file")
LANES :: 32
@(private = "file")
V :: #simd[LANES]u8

@(private = "file")
load :: #force_inline proc "contextless" (s: []u8, i: int) -> V {
	return intrinsics.unaligned_load((^V)(raw_data(s[i:])))
}

// How many times `c` occurs in `s`.
count_byte :: proc "contextless" (s: []u8, c: u8) -> int {
	n := 0
	i := 0
	want := V(c)
	ones := V(1)
	// Up to 255 blocks fit in the u8 lanes before they have to be added up.
	for i + LANES <= len(s) {
		acc: V
		blocks := min((len(s) - i) / LANES, 255)
		for _ in 0 ..< blocks {
			acc += simd.lanes_eq(load(s, i), want) & ones
			i += LANES
		}
		n += int(simd.reduce_add_pairs(simd.u16x32(acc)))
	}
	for ; i < len(s); i += 1 do if s[i] == c do n += 1
	return n
}

// The first `c` in `s`, or -1.
find_byte :: #force_inline proc "contextless" (s: []u8, c: u8) -> int {
	return bytes.index_byte(s, c)
}

// The first ASCII letter `lower` in `s` in either case, or -1. `lower` must
// be a lower-case letter: OR-ing in 0x20 maps 'A'..'Z' onto 'a'..'z' and
// nothing else onto a letter.
find_letter_fold :: proc "contextless" (s: []u8, lower: u8) -> int {
	i := 0
	want := V(lower)
	bit := V(0x20)
	for i + LANES <= len(s) {
		if simd.reduce_or(simd.lanes_eq(load(s, i) | bit, want)) != 0 {
			for j in 0 ..< LANES do if s[i + j] | 0x20 == lower do return i + j
		}
		i += LANES
	}
	for ; i < len(s); i += 1 do if s[i] | 0x20 == lower do return i
	return -1
}

// How rare a byte is in source code and text, roughly: lower is rarer. Used to
// pick which character of a query to scan for.
char_rarity :: proc "contextless" (c: u8) -> int {
	switch c {
	case 'a' ..= 'z':
		// English and code letter frequency, most common first.
		ORDER :: "etaoinsrlcdhupmfgbywvkxjqz"
		for o, i in ORDER do if u8(o) == c do return 100 - i
	case 'A' ..= 'Z':
		return 40
	case '0' ..= '9':
		return 50
	case ' ', '\t', '_', '.', ',', '(', ')', ';', '=', '"', '\'', '-', '/', '*', '{', '}', ':':
		return 110
	case '[', ']', '<', '>', '+', '&', '|', '!', '#':
		return 60
	case:
		return 30 // ~ ` ^ @ $ % ? \ and non-ASCII
	}
	return 100
}
