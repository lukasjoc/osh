package main

import "core:bytes"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"

INPUT_LEN_MAX :: 256

Shell_State :: struct {
	path: []string,
}

shell_state_init :: proc() -> Shell_State {
	value, _ := os.lookup_env_alloc("PATH", context.allocator)
	path := strings.split(value, ":")
	return {path}
}

find_executable :: proc(state: Shell_State, needle: string) -> (path: string, err: os.Error) {
	if os.is_file(needle) {
		return os.get_absolute_path(needle, context.allocator)
	}

	for path in state.path {
		log.debugf("searching bin path: %v", path)
		ents, err := os.read_all_directory_by_path(path, context.allocator)
		if err != nil {
			log.warnf("cannot open dirpath: %v", path)
			continue
		}
		for ent in ents {
			if ent.name == needle {
				return ent.fullpath, nil
			}
		}
	}

	return "", nil
}

parse_input :: proc(input: []byte) -> (toks: [dynamic]string, err: os.Error) {
	log.debugf("input: %v", input)

	temp := strings.builder_make(context.temp_allocator) or_return
	defer strings.builder_destroy(&temp)

	for r in string(input) {
		if bytes.is_ascii_space(r) {
            // TODO: optimize. i'd rather copy into toks directly
			tok := strings.clone(strings.to_string(temp))
			log.debugf("tok: %v -> %v", tok, cast(u8)r)
			append(&toks, tok)
			strings.builder_reset(&temp)
		} else {
            // TODO: handle literals
			strings.write_rune(&temp, r)
		}
	}

	log.debugf("parsed toks: %v", toks)
	return toks, nil
}

main :: proc() {
	when ODIN_DEBUG {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)
		defer {
			if len(track.allocation_map) > 0 {
				fmt.eprintf("=== %v allocations not freed: ===\n", len(track.allocation_map))
				for _, entry in track.allocation_map {
					fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
				}
			}
			mem.tracking_allocator_destroy(&track)
		}
	}

	context.logger = log.create_console_logger(.Debug when ODIN_DEBUG else .Info)

	state := shell_state_init()

	for {
		buf: [INPUT_LEN_MAX]byte

		fmt.printf("%v:$ ", os.args[0])

		n, err := os.read(os.stdin, buf[:])
		if err != nil {
			fmt.eprintfln("osh: error: %v", err)
			break
		}

		toks, parse_err := parse_input(buf[:n])
		if parse_err != nil {
			log.warnf("could not parse input: %v", err)
			continue
		}

		// TODO: fix leaks
		// TODO: support for builtins
		// fullpath, find_err := find_executable(state, toks[0])
		// if find_err != nil {
		// 	fmt.eprintfln("osh(%v): %v: %v", toks[0], find_err)
		// 	continue
		// }
		// img := toks[0]
		// switch len(fullpath) {
		// case 0:
		// 	fmt.eprintfln("osh: %v: not found", img)
		// case:
		// 	desc := os.Process_Desc{"", toks[:], nil, os.stderr, os.stdout, os.stdin}
		// 	process, start_err := os.process_start(desc)
		// 	if start_err != nil {
		// 		fmt.eprintfln("osh: %v: %v", img, start_err)
		// 		continue
		// 	}
		// 	state, wait_err := os.process_wait(process)
		// 	if wait_err != nil {
		// 		fmt.eprintfln("osh(%v): %v: %v", state.exit_code, img, wait_err)
		// 		continue
		// 	}
		// }
	}
}
