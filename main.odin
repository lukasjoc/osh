package main

import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"

INPUT_LEN_MAX :: 256

Shell_State :: struct {
	runtime_path: []string,
	oldpath:      string,
	currpath:     string,
}

shell_state_init :: proc() -> (state: Shell_State, init_err: os.Error) {
	value, _ := os.lookup_env_alloc("PATH", context.allocator)
	path := strings.split(value, ":")
	dir := os.get_working_directory(context.allocator) or_return
	return {runtime_path = path, oldpath = "", currpath = dir}, nil
}

find_executable :: proc(state: Shell_State, needle: string) -> (path: string, err: os.Error) {
	if os.is_file(needle) {
		return os.get_absolute_path(needle, context.allocator)
	}
	for ent in state.runtime_path {
		log.debugf("searching path: %v", ent)
		ents, err := os.read_all_directory_by_path(ent, context.allocator)
		if err != nil {
			log.warnf("cannot open path: %v", ent)
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

is_builtin :: #force_inline proc(v: string) -> bool {
	switch v {
	case "type", "exit", "cd":
		return true
	case:
		return false
	}
}


Builtin_Exit :: enum {
	Success,
	Error,
}

shell_state_exec_builtin_exit :: proc(state: ^Shell_State, args: []string) -> Builtin_Exit {
	usage :: proc() -> Builtin_Exit {
		fmt.eprintfln("Exit the shell with a exit code. Note that only ony integers are allowed.")
		fmt.eprintfln("usage: exit [code]")
		fmt.eprintfln("  -h, --help  show this help")
		fmt.eprintfln("example: exit")
		fmt.eprintfln("example: exit 2")
		return Builtin_Exit.Success
	}

	report_err :: proc(msg: string) -> Builtin_Exit {
		fmt.eprintfln("error: %s", msg)
		fmt.eprintfln("help: exit --help")
		return Builtin_Exit.Error
	}

	if len(args) < 1 {return usage()}

	assert(args[0] == "exit")

	for arg in args {
		switch arg {
		case "-h", "--help":
			return usage()
		case:
			if strings.starts_with(arg, "-") {
				return report_err(fmt.aprintf("unexpected option: `%s`", arg))
			}
		}
	}

	code := 0
	if len(args) > 1 {
		code, ok := strconv.parse_int(args[1])
		if !ok {
			return report_err(fmt.aprintf("unexpected exit code: `%s`", args[1]))
		}
	}

	os.exit(code)
}

shell_state_exec_builtin_type :: proc(state: ^Shell_State, args: []string) -> Builtin_Exit {
	usage :: proc() -> Builtin_Exit {
		fmt.eprintfln("Show the identity of a name visible to the shell.")
		fmt.eprintfln("usage: type <name>")
		fmt.eprintfln("  -h, --help  show this help")
		fmt.eprintfln("example: type cd")
		fmt.eprintfln("example: type /usr/bin/git")
		return Builtin_Exit.Success
	}

	report_err :: proc(msg: string) -> Builtin_Exit {
		fmt.eprintfln("error: %s", msg)
		fmt.eprintfln("help: type --help")
		return Builtin_Exit.Error
	}

	if len(args) < 2 {return usage()}

	assert(args[0] == "type")
	name := args[1]
	for arg in args {
		switch arg {
		case "-h", "--help":
			return usage()
		case:
			if strings.starts_with(arg, "-") {
				return report_err(fmt.aprintf("unexpected option: `%s`", arg))
			}
		}
	}

	if os.is_file(name) {
		path, err := os.get_absolute_path(name, context.allocator)
		if err != nil {
			return report_err(fmt.aprintf("%v", err))
		}
		fmt.printfln("%s is %s", name, path)
		return Builtin_Exit.Success
	}

	found := false

	if is_builtin(name) {
		found = true
		fmt.printfln("%s is a shell builtin", name)
	}

	for ent in state.runtime_path {
		log.debugf("searching path: %v", ent)
		ents, err := os.read_all_directory_by_path(ent, context.allocator)
		if err != nil {
			log.warnf("cannot open path: %v", ent)
			continue
		}
		for ent in ents {
			if ent.name == name {
				found = true
				fmt.printfln("%s is %s", name, ent.fullpath)
			}
		}
	}

	if found == false {
		fmt.eprintfln("osh: type: %v: not found", name)
	}

	return Builtin_Exit.Success
}

shell_state_exec_builtin_cd :: proc(state: ^Shell_State, args: []string) -> Builtin_Exit {
	usage :: proc() -> Builtin_Exit {
		fmt.eprintfln(
			"Change the current dir. If dir is not given it will change into the users home dir.",
		)
		fmt.eprintfln("usage: cd [-] [dir]")
		fmt.eprintfln("  -           change to the previous dir")
		fmt.eprintfln("  -h, --help  show this help")
		fmt.eprintfln("example: cd")
		fmt.eprintfln("example: cd -")
		fmt.eprintfln("example: cd /bar")
		return Builtin_Exit.Success
	}

	report_err :: proc(msg: string) -> Builtin_Exit {
		fmt.eprintfln("error: %s", msg)
		fmt.eprintfln("help: cd --help")
		return Builtin_Exit.Error
	}

	if len(args) < 1 {return usage()}

	assert(args[0] == "cd")

	for arg in args {
		switch arg {
		case "-h", "--help":
			return usage()
		case "-":
			continue
		case:
			if strings.starts_with(arg, "-") {
				return report_err(fmt.aprintf("unexpected option: `%s`", arg))
			}
		}
	}

	home_dir := os.user_home_dir(context.allocator) or_else panic("should get home dir of user")

	path: string

	if len(args) == 1 {
		path = home_dir
	} else {
		path = args[1]
	}

	log.debugf("before: %v", state)
	if path == "-" {
		oldpath := state.oldpath
		log.debugf("change dir: %v", path)
		if err := os.change_directory(oldpath); err != nil {
			fmt.eprintfln("osh: cd: path:%v %v", oldpath, err)
		} else {
			state.oldpath = state.currpath
			state.currpath = oldpath
		}
	} else {
		abs_path, abs_err := os.get_absolute_path(path, context.allocator)
		if abs_err != nil {
			fmt.eprintfln("osh: cd: path:%v %v", path, abs_err)
		}
		log.debugf("change dir: %v", abs_path)
		change_err := os.change_directory(abs_path)
		if change_err != nil {
			fmt.eprintfln("osh: cd: path:%v %v", abs_path, change_err)
		} else {
			oldpath := state.currpath
			state.currpath = abs_path
			state.oldpath = oldpath
		}
	}
	log.debugf("after: %v", state)

	return Builtin_Exit.Success
}

parse_string_lit :: #force_inline proc(s: string) -> int {
	delim := s[0]
	assert(delim == '"' || delim == '\'', "expected quote")
	n := 1
	for ; n < len(s); n += 1 {
		if s[n] == delim {break}
	}
	assert(s[n] == delim, "expected a matching quote")
	return n
}

parse_field :: #force_inline proc(s: string) -> int {
	n := 1
	for ; n < len(s); n += 1 {
		if s[n] == ' ' || s[n] == '\n' {break}
	}
	return n
}

argparse :: proc(s: string) -> (args: [dynamic]string, err: os.Error) {
	for pos := 0; pos < len(s); pos += 1 {
		ch := s[pos]
		if ch == ' ' || ch == '\n' {continue}
		if ch == '"' || ch == '\'' {
			n := parse_string_lit(s[pos:])
			append(&args, s[pos + 1:pos + n])
			pos += n
		} else {
			n := parse_field(s[pos:])
			append(&args, s[pos:pos + n])
			pos += n
		}
	}
	log.debugf("parsed args: %v", args)
	return args, nil
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

	state, init_err := shell_state_init()
	if init_err != nil {
		os.exit(1)
	}

	for {
		buf: [INPUT_LEN_MAX]byte

		fmt.printf("%v:$ ", os.args[0])

		n, read_err := os.read(os.stdin, buf[:])
		if read_err != nil {
			fmt.eprintfln("osh: error: %v", read_err)
			break
		}

		args, parse_err := argparse(string(buf[:n]))
		if parse_err != nil {
			log.warnf("could not parse input: %v", parse_err)
			continue
		}

		if len(args) == 0 {continue}

		arg0 := args[0]
		if arg0 == "exit" {
			shell_state_exec_builtin_exit(&state, args[:])
			continue
		} else if arg0 == "type" {
			shell_state_exec_builtin_type(&state, args[:])
			continue
		} else if arg0 == "cd" {
			shell_state_exec_builtin_cd(&state, args[:])
			continue
		}

		// TODO: fix leaks
		fullpath, find_err := find_executable(state, args[0])
		if find_err != nil {
			fmt.eprintfln("osh: %v: %v", args[0], find_err)
			continue
		}

		switch len(fullpath) {
		case 0:
			fmt.eprintfln("osh: %v: not found", arg0)
		case:
			desc := os.Process_Desc{"", args[:], nil, os.stderr, os.stdout, os.stdin}
			process, start_err := os.process_start(desc)
			if start_err != nil {
				fmt.eprintfln("osh: %v: %v", arg0, start_err)
				continue
			}
			state, wait_err := os.process_wait(process)
			if wait_err != nil {
				fmt.eprintfln("osh(%v): %v: %v", state.exit_code, arg0, wait_err)
				continue
			}
		}
	}
}
