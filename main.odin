package main

import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"

LINE_LENGTH_MAX :: 256

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
		context.logger = log.create_console_logger(.Debug)
	} else {
		context.logger = log.create_console_logger(.Error)
	}

	state := shell_state_init()

	for {
		buf: [LINE_LENGTH_MAX]byte
		fmt.printf("%v:$ ", os.args[0])
		n, err := os.read(os.stdin, buf[:])
		if err != nil {
			fmt.eprintfln("osh: error: %v", err)
			break
		}
		// TODO: escape quotes
		command := strings.split(strings.trim_right(string(buf[:n]), "\n "), " ")

		log.debugf("parsed command: %v", command)

		// TODO: support for builtins
		fullpath, errfind := find_executable(state, command[0])
		if errfind != nil {
			fmt.eprintfln("osh(%v): %v: %v", command[0], errfind)
			continue
		}
		img := command[0]
		switch len(fullpath) {
		case 0:
			fmt.eprintfln("osh: %v: not found", img)
		case:
			desc := os.Process_Desc{"", command, nil, os.stderr, os.stdout, os.stdin}
			process, errstart := os.process_start(desc)
			if errstart != nil {
				fmt.eprintfln("osh: %v: %v", img, errstart)
				continue
			}
			state, errwait := os.process_wait(process)
			if errwait != nil {
				fmt.eprintfln("osh(%v): %v: %v", state.exit_code, img, errwait)
				continue
			}
		}
	}
}
