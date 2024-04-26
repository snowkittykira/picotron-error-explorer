# picotron error explorer

by kira

version 0.0.4

an interactive error screen for picotron.
on error, shows the stack, local variables,
and the source code when available.

## usage

`include` or `require` `error_explorer.lua`
in your program _after_ defining your `_init`,
`_update`, and `_draw` functions.

press `up` and `down` to move up and down on
the stack, press `x` or `space` to toggle font
size. click on tables in the variable view to
expand them.

## how it works

in order to catch errors and inspect runtime
state, this script replaces `_init`, `_update`
and `_draw` functions with ones that call the
original ones inside a coroutine.

when there's an error, it uses lua's debug
library to inspect the coroutine. a copy
of the error is also printed to the console
with printh if you're running picotron from
the command line.

the following debug apis are used:

- `debug.getinfo`
- `debug.getlocal`
- `debug.getupvalue`
- `debug.traceback`

## version history 

version 0.0.4

- also catch errors in `_init`

version 0.0.3

- automatically choose the right stack frame
  based on the error message
- more thoroughly protect from errors in error
  explorer itself

version 0.0.2

- don't regenerate stack info every draw
- scroll stack and variables list with mousewheel
- click on stack to switch stack frames
- click on tables in variables view to expand them
- escape strings when printing them

version 0.0.1

- adjust colors
- code cleanup
- use `btnp` instead of `keyp`
- slightly more thorough `reset`
- don't show temporaries

version 0.0.0 (prerelease)

- initial discord beta
