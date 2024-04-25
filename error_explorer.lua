-- # picotron error explorer
--
-- by kira
--
-- version 0.0.1
--
-- an interactive error screen for picotron.
-- on error, shows the stack, local variables,
-- and the source code when available.
--
-- ## usage
--
-- `include` or `require` `error_explorer.lua`
-- in your program _after_ defining your `_update`
-- and `_draw` functions
--
-- ## how it works
--
-- in order to catch errors and inspect runtime
-- state, this script replaces `_update` and
-- `_draw` functions with ones that call the
-- original ones inside a coroutine.
--
-- when there's an error, it uses lua's debug
-- library to inspect the coroutine.
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
  local success, value_string = pcall (tostring, value)
  return success and value_string
                 or ('error during tostring: ' .. tostring (value_string))
end

local function get_lines (text)
  local lines = {}
  for line in text:gmatch ("(.-)\r?\n") do
    table.insert (lines, line)
  end
  return lines
end

---- state ---------------------------------------

local _G = _G
local error_message
local error_thread
local error_traceback
local current_index = 0
local use_small_font = false

---- main events ---------------------------------

local W = 480
local H = 270

local function error_update ()
  if btnp (5) or keyp 'space' then
    use_small_font = not use_small_font
  end
  if btnp (2) then
    current_index = math.max (0, current_index - 1)
  end
  if btnp (3) then
    current_index = current_index + 1
  end
end

local function error_draw ()
  cls (0)
  pal (5, 0xff707070, 2)
  local x0, y0, x, y
  color (5)
  local prefix = use_small_font and '\014' or ''

  local function go_to (new_x, new_y)
    x0, y0 = new_x, new_y
    x, y = x0, y0
  end

  local function section (sx, sy, sw, sh)
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

  section (0, 0, W, H/2)
  local loc, err = error_message:match ('^([^:]+:%d+):(.*)$')
  if loc then
    print_line ('error at ' .. loc .. ':', 6)
    print_line ('  ' .. err, 8)
  else
    print_line ('error:', 6)
    print_line ('  ' .. error_message, 8)
  end
  print_line ('stack:', 6)
  color (5)
  for i = 0, 20 do
    local info = debug.getinfo (error_thread, i)
    if not info then
      if current_index >= i then
        current_index = i-1
      end
      break
    end

    if info.short_src then
      color (current_index == i and 6 or 5)
      print_horizontal ('  ' .. filename_of (info.short_src))
      print_horizontal (':')
      print_horizontal (tostring (info.currentline))
      print_horizontal (' in function ')
      print_horizontal (info.name or (filename_of (info.short_src) .. ':' .. tostring (info.linedefined)))
      print_line ('')
    end
  end

  section (0, H/2, W/2, H/2)
  do
    print_line ('variables:', 6)
    local local_index = 1
    repeat
      local name, value = debug.getlocal (error_thread, current_index, local_index)
      if name then
        if name ~= '(temporary)' then
          print_horizontal ('  ' .. name, 6)
          print_horizontal (': ', 5)
          print_line (safe_tostring(value))
        end
        local_index = local_index + 1
      end
    until not name

    local info = debug.getinfo (error_thread, current_index)
    if info and info.func then
      local upvalue_index = 1
      repeat
        local name, value = debug.getupvalue (info.func, upvalue_index)
        if name then
          print_horizontal ('  ' .. name, 6)
          print_line (': ' .. safe_tostring (value), 5)
          upvalue_index = upvalue_index + 1
        end
      until not name
    end
  end

  section (W/2, H/2, W/2, H/2)
  do
    local info = debug.getinfo (error_thread, current_index)
    local source = info.source
    if source then
      color (6)
      if string.sub (source, 1, 1) == '@' then
        local filename = string.sub (source, 2, #source)
        print_line ('source of ' .. filename .. ':')
        source = fetch (filename)
      else
        print_line ('source:')
      end
      color (5)
      if source and type(source) == 'string' then
        local lines = get_lines (source)
        local context = use_small_font and 10 or 5
        local i_min = math.max (1, info.currentline - context)
        local i_max = math.min (#lines, info.currentline + context)
        for i = i_min, i_max do
          color (i == info.currentline and 6 or 5)
          print_horizontal (string.format ('%4d ', i))
          print_line (lines [i])
        end
      end
    end
  end

  clip ()
end

---- taking over during errors -------------------

local function reset ()
  -- based on reset() from /system/lib/head.lua
  -- see that fn for info
  note ()
  clip ()
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
  error_thread = thread
  error_message = message
  error_traceback = debug.traceback (thread, message)
  printh (error_traceback)
  reset ()
end

---- install main events that catch errors -------

local user_update = rawget (_G, '_update')
local user_draw = rawget (_G, '_draw')

assert (user_draw and user_update,
  'please include install_error_handler after defining both _update and _draw')

local function call_error_event (fn)
  -- if there's an error in our update or draw, throw the
  -- original error as well as the new error
  local success, err = pcall (fn)
  if not success then
    error (error_traceback .. '\n\nerror during error handling: ' .. err)
  end
end

local function call_protected (fn)
  -- need to use coresume etc. and not coroutine.resume etc.
  -- for picotron compatibility
  local thread = cocreate (fn)
  local success, message = coresume(thread)
  if costatus (thread) ~= 'dead' then
    on_error (thread, 'setup_error_display.lua: _update and _draw shouldn\'t yield')
  end
  if not success then
    on_error (thread, message)
  end
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
