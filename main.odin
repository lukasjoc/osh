package main

import "base:runtime"
import "core:c/libc"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import lua "vendor:lua/5.4"

INPUT_LEN_MAX :: 256

Shell_State :: struct {
	runtime_path: []string,
	oldpath:      string,
	currpath:     string,
}

shell_state_init :: proc() -> (state: Shell_State, err: os.Error) {
	value, _ := os.lookup_env_alloc("PATH", context.allocator)
	path := strings.split(value, ":")
	dir := os.get_working_directory(context.allocator) or_return
	return {runtime_path = path, oldpath = "", currpath = dir}, nil
}

find_executable :: proc(state: ^Shell_State, needle: string) -> (string, os.Error, bool) {
	if os.is_file(needle) {
		path, err := os.get_absolute_path(needle, context.allocator)
		if err != nil {
			return "", err, false
		}
		return path, nil, true
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
				return ent.fullpath, nil, true
			}
		}
	}
	return "", nil, false
}

is_builtin :: #force_inline proc(v: string) -> bool {
	switch v {
	case "type", "exit", "cd":
		return true
	case:
		return false
	}
}


Exit_Code :: enum {
	Success = 0,
	Error   = 1,
}

shell_state_exec_builtin_exit :: proc(state: ^Shell_State, args: []string) -> Exit_Code {
	usage :: proc() -> Exit_Code {
		fmt.eprintfln("Exit the shell with a exit code. Note that only ony integers are allowed.")
		fmt.eprintfln("usage: exit [code]")
		fmt.eprintfln("  -h, --help  show this help")
		fmt.eprintfln("example: exit")
		fmt.eprintfln("example: exit 2")
		return .Success
	}

	report_err :: proc(msg: string) -> Exit_Code {
		fmt.eprintfln("error: %s", msg)
		fmt.eprintfln("help: exit --help")
		return .Error
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

shell_state_exec_builtin_type :: proc(state: ^Shell_State, args: []string) -> Exit_Code {
	// TODO: support for aliases
	usage :: proc() -> Exit_Code {
		fmt.eprintfln("Show the identity of a name visible to the shell.")
		fmt.eprintfln("usage: type <name>")
		fmt.eprintfln("  -h, --help  show this help")
		fmt.eprintfln("example: type cd")
		fmt.eprintfln("example: type /usr/bin/git")
		return .Success
	}

	report_err :: proc(msg: string) -> Exit_Code {
		fmt.eprintfln("error: %s", msg)
		fmt.eprintfln("help: type --help")
		return .Error
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
		return .Success
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

	return .Success
}

shell_state_exec_builtin_cd :: proc(state: ^Shell_State, args: []string) -> Exit_Code {
	usage :: proc() -> Exit_Code {
		fmt.eprintfln(
			"Change the current dir. If dir is not given it will change into the users home dir.",
		)
		fmt.eprintfln("usage: cd [-] [dir]")
		fmt.eprintfln("  -           change to the previous dir")
		fmt.eprintfln("  -h, --help  show this help")
		fmt.eprintfln("example: cd")
		fmt.eprintfln("example: cd -")
		fmt.eprintfln("example: cd /bar")
		return .Success
	}

	report_err :: proc(msg: string) -> Exit_Code {
		fmt.eprintfln("error: %s", msg)
		fmt.eprintfln("help: cd --help")
		return .Error
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
			return .Error
		}
		state.oldpath = state.currpath
		state.currpath = oldpath
	} else {
		abs_path, abs_err := os.get_absolute_path(path, context.allocator)
		if abs_err != nil {
			fmt.eprintfln("osh: cd: path:%v %v", path, abs_err)
			return .Error
		}
		log.debugf("change dir: %v", abs_path)
		change_err := os.change_directory(abs_path)
		if change_err != nil {
			fmt.eprintfln("osh: cd: path:%v %v", abs_path, change_err)
			return .Error
		}
		oldpath := state.currpath
		state.currpath = abs_path
		state.oldpath = oldpath
	}
	log.debugf("after: %v", state)

	return .Success
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

shell_state_exec :: proc(state: ^Shell_State, args: []string) -> Exit_Code {
	assert(len(args) > 0)
	name := args[0]

	if name == "exit" {
		return shell_state_exec_builtin_exit(state, args[:])
	} else if name == "type" {
		return shell_state_exec_builtin_type(state, args[:])
	} else if name == "cd" {
		return shell_state_exec_builtin_cd(state, args[:])
	}

	fullpath, find_err, ok := find_executable(state, name)
	if find_err != nil {
		fmt.eprintfln("osh: %v: %v", name, find_err)
		return .Error
	}

	if !ok {
		fmt.eprintfln("osh: %v: not found", name)
		return .Error
	}

	desc := os.Process_Desc{"", args[:], nil, os.stderr, os.stdout, os.stdin}
	process, start_err := os.process_start(desc)
	if start_err != nil {
		fmt.eprintfln("osh: %v: %v", name, start_err)
		return .Error
	}

	state, wait_err := os.process_wait(process)
	if wait_err != nil {
		fmt.eprintfln("osh(%v): %v: %v", state.exit_code, name, wait_err)
		return .Error
	}

	return .Success
}

luaregister_lib :: proc(state: ^lua.State, name: cstring, lib: lua.CFunction) -> libc.int {
	lua.getglobal(state, cstring("package"))
	lua.getfield(state, -1, cstring("preload"))
	lua.pushcfunction(state, lib)
	lua.setfield(state, -2, name)
	lua.pop(state, 2)
	return 0
}


Shared_Config :: struct #packed {
	prompt:  string,
	aliases: map[string]string,
}

shared_config: Shared_Config

osh_prelude_bind_alias :: proc "c" (state: ^lua.State) -> libc.int {
	cvalue := lua.tostring(state, lua.gettop(state))
	lua.pop(state, 1)
	cname := lua.tostring(state, lua.gettop(state))
	lua.pop(state, 1)
	lua.pushlightuserdata(state, rawptr(&shared_config))
	lua.gettable(state, lua.REGISTRYINDEX)
	if !lua.islightuserdata(state, -1) {
		return 1
	}
	shared := cast(^Shared_Config)lua.touserdata(state, -1)
	context = runtime.default_context()
	when ODIN_DEBUG {libc.printf("defining alias: %s=%s\n", cname, cvalue)}
	name, _ := strings.clone_from_cstring(cname)
	value, _ := strings.clone_from_cstring(cvalue)
	map_insert(&shared.aliases, name, value)
	return 0
}

osh_prelude_set_prompt :: proc "c" (state: ^lua.State) -> libc.int {
	cvalue := lua.tostring(state, lua.gettop(state))
	lua.pop(state, 1)
	lua.pushlightuserdata(state, rawptr(&shared_config))
	lua.gettable(state, lua.REGISTRYINDEX)
	if !lua.islightuserdata(state, -1) {
		return 1
	}
	shared := cast(^Shared_Config)lua.touserdata(state, -1)
	context = runtime.default_context()
	when ODIN_DEBUG {libc.printf("defining prompt: %s\n", cvalue)}
	value, err := strings.clone_from_cstring(cvalue)
	shared.prompt = value
	return 0
}

luaopen_osh_prelude :: proc "c" (state: ^lua.State) -> libc.int {
	context = runtime.default_context()
	reg := []lua.L_Reg {
		{name = cstring("bind_alias"), func = osh_prelude_bind_alias},
		{name = cstring("set_prompt"), func = osh_prelude_set_prompt},
		{},
	}
	lua.pushlightuserdata(state, rawptr(&shared_config))
	lua.pushlightuserdata(state, rawptr(&shared_config))
	lua.settable(state, lua.REGISTRYINDEX)
	lua.L_newlib(state, reg)
	return 1
}


// TODO: fix leaks
main :: proc() {
	context.logger = log.create_console_logger(.Debug when ODIN_DEBUG else .Info)

	when ODIN_DEBUG {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)
		defer {
			if len(track.allocation_map) > 0 {
				log.fatalf("=== %v allocations not freed: ===\n", len(track.allocation_map))
				for _, entry in track.allocation_map {
					log.fatalf("- %v bytes @ %v\n", entry.size, entry.location)
				}
			}
			mem.tracking_allocator_destroy(&track)
		}
	}

	shared_config = {
		prompt  = "$>",
		aliases = make(map[string]string),
	}

	L := lua.L_newstate()
	defer lua.close(L)
	if L == nil {
		fmt.println("no lua for you sir/or madam!")
		return
	}


	lua.L_openlibs(L)

	luaregister_lib(L, "osh_prelude", luaopen_osh_prelude)

	if ret := lua.L_dofile(L, "config.lua"); ret != 0 {
		error := lua.tostring(L, -1)
		fmt.println(error)
		lua.pop(L, 1)
	}

	when ODIN_DEBUG {
		log.infof("Collected aliases that are still in scope!!")
		for key, value in shared_config.aliases {
			log.infof("ALIAS(%s): %s", key, value)
		}
	}

	state, init_err := shell_state_init()
	if init_err != nil {
		os.exit(1)
	}

	for {
		buf: [INPUT_LEN_MAX]byte

		fmt.printf("%s", shared_config.prompt)

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

		name := args[0]

		if value, ok := shared_config.aliases[name]; ok {
			log.debugf("alias: %v", value)
			augmented, parse_err := argparse(value)
			if parse_err != nil {
				log.warnf("could not parse input: %v", parse_err)
				continue
			}
			if len(args) == 0 {continue}
			append(&augmented, ..args[1:])
			log.debugf("augmented args: %v", augmented[:])
			_exit := shell_state_exec(&state, augmented[:])
			continue
		}

		_exit := shell_state_exec(&state, args[:])
	}
}
