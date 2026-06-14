local osh = require("osh_prelude")

local ls_base = "ls --color=auto"
osh.bind_alias("..", "cd ..")
osh.bind_alias("ls", ls_base)
osh.bind_alias("ll", ls_base .. " -larth")
osh.bind_alias("grep", "grep --color=auto")
osh.bind_alias("clear", [[printf '\e[1;1H\e[2J']])

osh.set_prompt("$#> ")

print("We're shelling.. Have a nice day hacking (^@@^)")

