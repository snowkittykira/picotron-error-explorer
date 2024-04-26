-- # picotron error explorer
--
-- by kira
--
-- version 0.0.4
--
-- an interactive error screen for picotron.
-- on error, shows the stack, local variables,
-- and the source code when available.
--
-- ## usage
--
-- `include` or `require` `error_explorer.lua`
-- in your program _after_ defining your `_init`,
-- `_update`, and `_draw` functions.
--
-- press `up` and `down` to move up and down on
-- the stack, press `x` or `space` to toggle font
-- size. click on tables in the variable view to
-- expand them.
--
-- ## how it works
--
-- in order to catch errors and inspect runtime
-- state, this script replaces `_init`, `_update`
-- and `_draw` functions with ones that call the
-- original ones inside a coroutine.
--
-- when there's an error, it uses lua's debug
-- library to inspect the coroutine. a copy
-- of the error is also printed to the console
-- with printh if you're running picotron from
-- the command line.
--
-- the following debug apis are used:
--
-- - `debug.getinfo`
-- - `debug.getlocal`
-- - `debug.getupvalue`
-- - `debug.traceback`
--
-- ## version history 
--
-- version 0.0.4
--
-- - also catch errors in `_init`
--
-- version 0.0.3
--
-- - automatically choose the right stack frame
--   based on the error message
-- - more thoroughly protect from errors in error
--   explorer itself
--
-- version 0.0.2
--
-- - don't regenerate stack info every draw
-- - scroll stack and variables list with mousewheel
-- - click on stack to switch stack frames
-- - click on tables in variables view to expand them
-- - escape strings when printing them
--
-- version 0.0.1
--
-- - adjust colors
-- - code cleanup
-- - use `btnp` instead of `keyp`
-- - slightly more thorough `reset`
-- - don't show temporaries
--
-- version 0.0.0 (prerelease)
--
-- - initial discord beta

-- ## license
--
-- Copyright 2024 Kira Boom
-- 
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the “Software”), to
-- deal in the Software without restriction, including without limitation the
-- rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
-- sell copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in
-- all copies or substantial portions of the Software.
-- 
-- THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS
-- OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
-- THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
-- FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
-- DEALINGS IN THE SOFTWARE.

---- util ----------------------------------------

local function filename_of (path)
  return path:match ('[^/]*$')
end

local function safe_tostring (value)
  if type (value) == 'string' then
    return string.format ('%q', value)
  else
    local success, value_string = pcall (tostring, value)
    return success and value_string
                   or ('error during tostring: ' .. tostring (value_string))
  end
end

local function get_lines (text)
  local lines = {}
  for line in text:gmatch ("(.-)\r?\n") do
    table.insert (lines, line)
  end
  local last_line = text:match ('([^\n]*)$')
  if last_line and last_line ~= '' then
    table.insert (lines, last_line)
  end
  return lines
end

local function compare_keys (a, b)
  local ta = type (a.key)
  local tb = type (b.key)
  if ta ~= tb then
    return ta < tb
  end
  if ta == 'number' or ta == 'string' then
    return a.key < b.key
  else
    return safe_tostring (a.key) < safe_tostring (b.key)
  end
end

local function sort (t, f)
  -- insertion sort
  f = f or function (a, b) return a < b end
  for i = 1, #t-1 do
    local val = t[i+1]
    local j = i
    while j >= 1 and not f(t[j], val) do
      t[j+1] = t[j]
      j = j - 1
    end
    t[j+1] = val
  end
end

local function approach (from, to)
  return from + (to - from) * 0.25
end

local function round (value)
  return math.floor (value + 0.5)
end

local function parse_message_for_location (msg)
  local path, line, err = msg:match ('^([^:]+):(%d+):(.*)$')
  return path, tonumber (line), err
end

---- state ---------------------------------------

local _G = _G
local error_message
local error_thread
local error_traceback
local init_done = false
local use_small_font = false
local mouse_was_clicked = false

-- stack view
local stack_frames = {}
local current_stack_index = 1
local hovered_stack_index = false
local mouse_over_stack = false
local stack_max_scroll = 0
local stack_scroll = 0
local stack_scroll_smooth = 0

-- variables view
local variables = {}
local hovered_variable = false
local variables_max_scroll = 0
local variables_scroll = 0
local variables_scroll_smooth = 0
local mouse_over_variables = false

-- source view
local source_lines = {}


---- main events ---------------------------------

local W = 480
local H = 270

local function rebuild ()
  -- rebuild stack frame info
  stack_frames = {}
  variables = {}
  source_lines = {}
  variables_scroll = 0
  variables_scroll_smooth = 0

  for i = 0, 20 do
    local info = debug.getinfo (error_thread, i)
    if not info then
      break
    end

    if info.short_src then
      table.insert (stack_frames, {
        filename = filename_of (info.short_src),
        path = info.short_src,
        line = info.currentline,
        depth = i,
        fn_name = (info.name or (filename_of (info.short_src) .. ':' .. tostring (info.linedefined))),
        source = info.source,
      })
    end
  end

  local frame = stack_frames [current_stack_index]

  if not frame then
    return
  end

  -- rebuild variables
  do
    local local_index = 1
    repeat
      local name, value = debug.getlocal (error_thread, frame.depth, local_index)
      if name then
        if name ~= '(temporary)' then
          table.insert (variables, {
            key = name,
            value = value,
          })
        end
        local_index = local_index + 1
      end
    until not name

    local info = debug.getinfo (error_thread, frame.depth)
    if info and info.func then
      local upvalue_index = 1
      repeat
        local name, value = debug.getupvalue (info.func, upvalue_index)
        if name then
          table.insert (variables, {
            key = name,
            value = value,
          })
          upvalue_index = upvalue_index + 1
        end
      until not name
    end
  end

  -- rebuild source lines
  local source = frame.source
  if source then
    if string.sub (source, 1, 1) == '@' then
      local filename = string.sub (source, 2, #source)
      source = fetch (filename)
    end
    if source and type (source) == 'string' then
      source_lines = get_lines (source)
    end
  end
end

local function error_update ()
  local last_index = current_stack_index
  if btnp (5) or keyp 'space' then
    use_small_font = not use_small_font
  end
  if btnp (2) then
    current_stack_index = math.max (1, current_stack_index - 1)
    stack_scroll = math.min (current_stack_index-1, stack_scroll)
  end
  if btnp (3) then
    current_stack_index = math.min (#stack_frames, current_stack_index + 1)
    stack_scroll = math.max ((current_stack_index) - (#stack_frames - stack_max_scroll), stack_scroll)
  end

  local _, _, click, _, wheel = mouse ()
  if mouse_over_stack then
    stack_scroll = math.max (0, math.min (stack_scroll - wheel * 2, stack_max_scroll))
  end
  stack_scroll_smooth = approach (stack_scroll_smooth, stack_scroll)
  if mouse_over_variables then
    variables_scroll = math.max (0, math.min (variables_scroll - wheel * 2, variables_max_scroll))
  end
  variables_scroll_smooth = approach (variables_scroll_smooth, variables_scroll)

  click = click ~= 0
  if click and not mouse_was_clicked then
    if hovered_stack_index then
      current_stack_index = hovered_stack_index
    end
    if hovered_variable and type (hovered_variable.value) == 'table' then
      if hovered_variable.contents then
        hovered_variable.contents = nil
      else
        local contents = {}
        hovered_variable.contents = contents
        for k,v in pairs (hovered_variable.value) do
          table.insert (contents, {
            key = k,
            value = v,
          })
        end
        sort (contents, compare_keys)
      end
    end
  end
  mouse_was_clicked = click

  if current_stack_index ~= last_index then
    rebuild()
  end
end

local function error_draw ()
  local prefix = use_small_font and '\014' or ''
  local font_height = (use_small_font and 6 or 11)
  local mx, my = mouse()
  local over_section = false
  local x0, y0, x, y

  local function go_to (new_x, new_y)
    x0, y0 = new_x, new_y
    x, y = x0, y0
  end

  local function section (sx, sy, sw, sh)
    over_section =
      mx >= sx and mx < sx + sw and
      my >= sy and my < sy + sh
    clip (sx, sy, sw, sh)
    go_to(sx+2, sy+2)
  end

  local function print_horizontal (text, color)
    local new_x, _new_y = print (prefix .. text, x, y, color)
    x = new_x
  end

  local function print_line (text, color)
    local _new_x, new_y = print (prefix .. text, x, y, color)
    x = x0
    y = new_y
  end

  -- draw setup
  cls (0)
  -- lighter dark gray for readability
  pal (5, 0xff707070, 2)
  color (5)

  -- error message
  section (0, 0, W, H/2)
  mouse_over_stack = over_section

  local loc_path, loc_line, err = parse_message_for_location (error_message)
  if loc_path then
    print_line ('error at ' .. loc_path .. ':' .. loc_line .. ':', 6)
    print_line ('  ' .. err, 8)
  else
    print_line ('error:', 6)
    print_line ('  ' .. error_message, 8)
  end

  -- stack frames
  print_line ('stack:', 6)
  section (0, y, W, H/2-y)
  local stack_top_y = y
  y = y - round (stack_scroll_smooth * font_height)
  local last_hovered_stack_index = hovered_stack_index
  hovered_stack_index = false
  for i, frame in ipairs (stack_frames) do
    color (last_hovered_stack_index == i and 7 or
           current_stack_index == i and 6 or 5)

   local y_before = y
    print_line (string.format ('  %s:%d in function %s',
      frame.filename, frame.line, frame.fn_name ))
    if over_section then
      if my >= y_before and my < y then
        hovered_stack_index = i
      end
    end
  end
  stack_max_scroll = #stack_frames - (H/2 - stack_top_y) / font_height

  local frame = stack_frames [current_stack_index]
  if not frame then
    return
  end

  -- variables
  section (0, H/2, W/2, H/2)
  mouse_over_variables = over_section
  print_line ('variables:', 6)
  section (0, y, W/2, H-y)
  local variables_top_y = y
  y = y - round (variables_scroll_smooth * font_height)
  local last_hovered_variable = hovered_variable
  hovered_variable = false
  local variable_count = 0
  local function draw_variable (variable, indent)
    variable_count = variable_count + 1
    local hovered = variable == last_hovered_variable
    local y_before = y
    print_horizontal (indent .. variable.key, hovered and 7 or 6)
    print_horizontal (': ', variable == last_hovered_variable and 7 or 5)
    print_line (safe_tostring(variable.value))

    if over_section and type (variable.value) == 'table' then
      if mx >= 0 and mx < W/2 and my >= y_before and my < y then
        hovered_variable = variable
      end
    end

    if variable.contents then
      for _, v in ipairs (variable.contents) do
        draw_variable (v, indent .. '  ')
      end
    end
  end
  for _, variable in ipairs (variables) do
    draw_variable (variable, '  ')
  end
  variables_max_scroll = variable_count - (H - variables_top_y) / font_height

  -- source
  section (W/2, H/2, W/2, H/2)
  print_line ('source of ' .. frame.path .. ':', 6)
  local context = use_small_font and 10 or 5
  local i_min = math.max (1, frame.line - context)
  local i_max = math.min (#source_lines, frame.line + context)
  for i = i_min, i_max do
    color (i == frame.line and 6 or 5)
    print_horizontal (string.format ('%4d ', i))
    print_line (source_lines [i])
  end

  clip ()
end

---- taking over during errors -------------------

local function reset ()
  -- based on reset() from /system/lib/head.lua
  -- see that fn for info
  note ()
  -- picotron segfaults if we call clip() during init
  if init_done then
    clip ()
  end
  camera ()
  pal ()
  palt ()
  memset (0x551f, 0, 9)
  poke (0x5508, 0x3f)
  poke (0x5509, 0x3f)
  poke (0x550a, 0x3f)
  poke (0x550b, 0x00)
  color (6)
  fillp ()
  poke (0x5f56, 0x40)
  poke (0x5f57, 0x56)
  poke (0x4000, get (fetch"/system/fonts/lil.font"))
  poke (0x5600, get (fetch"/system/fonts/p8.font"))
  poke (0x5606, peek (0x5600) * 4)
  poke (0x5605, 0x2)
  poke (0x5f28, 64)
  poke (0x5f29, 64)
end

local function on_error (thread, message)
  -- do this first in case we hit another error
  error_traceback = debug.traceback (thread, message)
  printh (error_traceback)

  error_thread = thread
  error_message = tostring (message)
  reset ()
  rebuild ()
  -- jump to the proper stack frame if we can
  local loc_path, loc_line = parse_message_for_location (error_message)
  for i, frame in ipairs (stack_frames) do
    if frame.path == loc_path and frame.line == loc_line then
      current_stack_index = i
      rebuild ()
      break
    end
  end
end

---- install main events that catch errors -------

local user_init = rawget (_G, '_init')
local user_update = rawget (_G, '_update')
local user_draw = rawget (_G, '_draw')

assert (user_draw and user_update,
  'please include install_error_handler after defining both _update and _draw')

local function call_error_event (fn, ...)
  -- if there's an error in our update or draw, throw the
  -- original error as well as the new error
  local success, err = pcall (fn, ...)
  if not success then
    error (error_traceback .. '\n\nerror during error handling: ' .. tostring (err))
  end
end

local function call_protected (fn)
  -- need to use coresume etc. and not coroutine.resume etc.
  -- for picotron compatibility
  local thread = cocreate (fn)
  local success, message = coresume(thread)
  if costatus (thread) ~= 'dead' then
    call_error_event (on_error, thread, 'setup_error_display.lua: _update and _draw shouldn\'t yield')
  end
  if not success then
    call_error_event (on_error, thread, message)
  end
end

if user_init then
  function _init ()
    call_protected (user_init)
    init_done = true
  end
else
  init_done = true
end

function _update ()
  if error_thread then
    call_error_event (error_update)
  else
    call_protected (user_update)
  end
end

function _draw ()
  if error_thread then
    call_error_event (error_draw)
  else
    call_protected (user_draw)
  end
end
