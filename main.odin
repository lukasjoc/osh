package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:log"

LINE_LENGTH_MAX :: 256

Shell_State :: struct {
    path: []string,
}

shell_state_init :: proc () -> Shell_State {
    value, _ := os.lookup_env_alloc("PATH", context.allocator)
    path := strings.split(value, ":")
    return { path }
}

find_executable :: proc (state: Shell_State, needle: string) -> (path: string, err: os.Error) {
    if os.is_file(needle) {
        panic(fmt.aprintf("file path: %s", needle))
    }
    for path in state.path {
        log.debugf("searching bin path: %v", path)
        ents, err := os.read_all_directory_by_path(path, context.allocator)
        if err != nil {
            log.warnf("cannot open dirpath: %v", path)
            continue;
        }
        for ent in ents {
            if ent.name == needle {
                return ent.fullpath, nil
            }
        }
    }

    return "", nil
}

// TODO:
// found2, fullpath2 := find_executable(state, "./osh")
// fmt.println("found", found2, fullpath2)

main :: proc() {
    context.logger = log.create_console_logger(.Debug)
    state := shell_state_init()
    log.debugf("%v", state)

    for {
        buf: [LINE_LENGTH_MAX]byte
        fmt.printf("%v:$ ", os.args[0])
        n, err := os.read(os.stdin, buf[:])
        if err != nil {
            fmt.eprintfln("osh: error: %v", err)
            break;
        }
        command := strings.split(strings.trim_right(string(buf[:n]), "\n "), " ")

        log.debugf("parsed command: %v", command)

        fullpath, errfind := find_executable(state, command[0])
        if errfind != nil {
            fmt.eprintfln("osh(%v): %v: %v", command[0], err)
            continue
        }
        img := command[0]
        switch len(fullpath) {
            case 0: fmt.eprintfln("osh: %v: not found", img)
            case: {
                process, errstart := os.process_start({ "", command, nil, os.stderr, os.stdout, nil })
                if errstart != nil {
                    fmt.eprintfln("osh: %v: %v", img, err)
                    continue
                }
                state, errwait := os.process_wait(process)
                if errwait != nil {
                    fmt.eprintfln("osh(%v): %v: %v", state.exit_code, img, err)
                    continue
                }
            }
        }
    }
}
