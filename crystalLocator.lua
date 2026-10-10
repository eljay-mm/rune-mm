-- Filename: eljayPlugins/crystalLocator.lua
-- Purpose: Crystal Locator - finds coords of crystals via the MMAtlas crystal finder
-- Inspired by the MUSHclient plugin by Elbereth
-- Version: 3.4
-- Date: 2026-Oct-10
--
-- Changes in 3.4:
--   * after "Walk there with" the plugin runs `spdxy nearby <x>, <y>` (setting `nearby`, on by default)
--
-- Changes in 3.3:
--   * filename no longer uses the y_ prefix
--
-- Changes in 3.2:
--   * `cc` (give to Tadamir, then drop and sac the crystal quest item) and `cl` (look at it) aliases moved
--     here from basicAliases.lua, with the character-name read ("name" global var)
--
-- Changes in 3.1:
--   * all IMap handling removed (no imap commands are sent, "take crystal" trigger removed)
--   * everything above and including the "It looks like ..." row is trimmed from the submitted/copied block
--   * clipboard: tries native tools first (wl-copy / xclip / xsel), OSC 52 as last resort,
--     strips control characters, and `crystal copytest` helps diagnose a bad clipboard path
--   * `lines` is now an optional cap (0 = no cap); `mode count` needs lines > 0

local VERSION  = "3.4"
local ENDPOINT = "https://ooc.dune.net/mm/find-crystal-guild-vi.pl"

local SCROLL_PATTERN = "Tadamir the guildsman gives you a tightly-rolled scroll\\.$"
local HEADER_PATTERN = "^You focus your powers of observation on"
-- The first line matching this Lua pattern, and every line above it, is trimmed from the block
local IGNORE_PATTERN = "^It looks like"

--[[ Settings (change live with: crystal set <key> <value>) ]]--
local cfg = {
  debug    = true,    -- verbose [crystal:debug] output
  method   = "post",  -- "post" or "get": how the map is submitted
  lines    = 0,       -- map lines to submit (excluding header and ignored rows); 0 = no cap
  mode     = "blank", -- "blank": capture ends at first blank line; "count": capture header + `lines` + ignored row
  trim     = false,   -- strip trailing whitespace from every map line before submitting
  fallback = true,    -- if no coords found, retry with other method / other trim setting
  copy     = true,    -- copy the submitted map block to the clipboard
  nearby   = true,    -- after "Walk there with", run `spdxy nearby <x>, <y>`
  clip     = "auto",  -- clipboard method: auto | osc | wl-copy | xclip | xsel
  timeout  = 15,      -- HTTP timeout in seconds
}

local SETTINGS = {
  debug = "bool", fallback = "bool", copy = "bool", trim = "bool", nearby = "bool",
  method = { "post", "get" }, mode = { "blank", "count" },
  clip = { "auto", "osc", "wl-copy", "xclip", "xsel" },
  lines = "number", timeout = "number",
}

--[[ State ]]--
local state = {
  enabled   = true,   -- crystal on / off
  armed     = false,  -- set by receiving the scroll (or `crystal on`), cleared after one capture
  busy      = false,  -- a request is in flight
  crystal   = nil,    -- "x,y" of last located crystal
  lastLines = nil,    -- last submitted lines (table)
  lastBlock = nil,    -- last submitted block (string)
  lastBody  = nil,    -- last HTTP response body
  lastInfo  = nil,    -- one-line summary of last HTTP exchange
}

--[[ Output helpers ]]--
local function paint(color, text)
  local fn = rune.style and rune.style[color]
  if type(fn) == "function" then
    local ok, out = pcall(fn, text)
    if ok and out then return out end
  end
  return text
end

local function say(msg)
  rune.echo(paint("cyan", "[crystal] ") .. msg)
end

local function dbg(msg)
  if cfg.debug then
    rune.echo(paint("blue", "[crystal:debug] ") .. msg)
  end
end

local function flatten(s, n)
  s = tostring(s or "")
  if n and #s > n then s = s:sub(1, n) .. "..." end
  return (s:gsub("[\r\n]+", " | "))
end

--[[ URL encode: everything except unreserved chars is %XX, space becomes + ]]--
local function urlencode(str)
  str = str:gsub("\r", "")
  local out = str:gsub("([^%w%-%._~ ])", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
  out = out:gsub(" ", "+")
  return out
end

--[[ Clipboard ]]--
-- Remove control characters (keep \n and \t) so nothing can break an escape sequence
local function sanitize(text)
  text = text:gsub("\r", "")
  text = text:gsub("[\1-\8\11-\31\127]", "")
  return text
end

local function hasTool(name)
  local ok, p = pcall(io.popen, "command -v " .. name .. " 2>/dev/null")
  if not ok or not p then return false end
  local out = p:read("*l")
  p:close()
  return out ~= nil and out ~= ""
end

local EXTERNAL = {
  ["wl-copy"] = "wl-copy",
  ["xclip"]   = "xclip -selection clipboard",
  ["xsel"]    = "xsel --clipboard --input",
}

local function pickClipMethod()
  if cfg.clip ~= "auto" then return cfg.clip end
  if os.getenv("WAYLAND_DISPLAY") and hasTool("wl-copy") then return "wl-copy" end
  if os.getenv("DISPLAY") and hasTool("xclip") then return "xclip" end
  if os.getenv("DISPLAY") and hasTool("xsel") then return "xsel" end
  return "osc"
end

-- Returns ok(boolean), method(string), err(string|nil)
local function copyToClipboard(text)
  text = sanitize(text)
  local method = pickClipMethod()

  if method == "osc" then
    if not (rune.clipboard and rune.clipboard.set) then
      return false, method, "rune.clipboard is not available in this Rune version"
    end
    local ok, err = pcall(rune.clipboard.set, text)
    if not ok then return false, method, tostring(err) end
    return true, method
  end

  local cmd = EXTERNAL[method]
  local okp, p = pcall(io.popen, cmd .. " 2>/dev/null", "w")
  if not okp or not p then
    return false, method, "io.popen is not available (try: crystal set clip osc)"
  end
  p:write(text)
  p:close()
  return true, method
end

local function doCopy(text, announce)
  local ok, method, err = copyToClipboard(text)
  if ok then
    local msg = string.format("Copied %d chars (%d lines) to clipboard via %s",
      #text, select(2, text:gsub("\n", "\n")) + 1, method)
    if announce then say(msg) else dbg(msg) end
  else
    say(paint("red", "Clipboard copy failed (" .. method .. "): ") .. tostring(err))
  end
  return ok
end

--[[ Response parsing ]]--
local function stripTags(body)
  local t = body:gsub("<[^>]*>", " ")
  t = t:gsub("&nbsp;", " "):gsub("&amp;", "&")
  return t
end

-- Returns x, y, how  (strings) or nil
local function parseCoords(body)
  local text = stripTags(body or "")
  -- Preferred: "(x, y)" / "(x,y)", negatives allowed
  local x, y = text:match("%(%s*(%-?%d+)%s*,%s*(%-?%d+)%s*%)")
  if x then return x, y, "parenthesised pair" end
  -- Fallback: a bare "x,y" pair, but only trusted in a short plain-text reply
  if #text <= 500 then
    x, y = text:match("(%-?%d+)%s*,%s*(%-?%d+)")
    if x then return x, y, "bare pair (short reply)" end
  end
  return nil
end

--[[ Request building ]]--
local function buildBlock(lines, trim)
  local t = {}
  for i, l in ipairs(lines) do
    if trim then
      t[i] = (l:gsub("%s+$", ""))
    else
      t[i] = l
    end
  end
  return table.concat(t, "\n")
end

local function sendRequest(method, block, callback)
  local enc = urlencode(block)
  local opts = { timeout = cfg.timeout }
  if method == "get" then
    local url = ENDPOINT .. "?map=" .. enc
    dbg(string.format("GET %s?map=<%d encoded chars>  (full URL %d chars)", ENDPOINT, #enc, #url))
    rune.http.get(url, opts, callback)
  else
    opts.headers = { ["Content-Type"] = "application/x-www-form-urlencoded" }
    dbg(string.format("POST %s  body map=<%d encoded chars>", ENDPOINT, #enc))
    rune.http.post(ENDPOINT, "map=" .. enc, opts, callback)
  end
end

--[[ Found / not found ]]--
local function onFound(x, y, attemptNo, attempt, how)
  state.crystal = x .. "," .. y
  say("Your crystal is located at " .. paint("white", "(" .. x .. ", " .. y .. ")"))
  dbg("Parsed from response using: " .. how)

  if attemptNo > 1 then
    say(string.format("Attempt %d worked (method=%s, trim=%s). Make it the default with: crystal set method %s  /  crystal set trim %s",
      attemptNo, attempt.method, tostring(attempt.trim), attempt.method, attempt.trim and "on" or "off"))
  end

  say("Walk there with: " .. paint("yellow", "spdxy " .. x .. ", " .. y))
  rune.send("spdxy nearby " .. x .. ", " .. y)
end

local function onNotFound()
  say(paint("red", "MMAtlas could not find that location."))
  say("Run " .. paint("yellow", "crystal debug") .. " to inspect the submitted lines and the raw reply.")
end

--[[ Submit a block (list of lines), trying fallbacks if enabled ]]--
local function submit(lines)
  if state.busy then
    say("A request is already running, please wait.")
    return
  end

  local other = (cfg.method == "get") and "post" or "get"
  local attempts = { { method = cfg.method, trim = cfg.trim } }
  if cfg.fallback then
    attempts[#attempts + 1] = { method = other,      trim = cfg.trim }
    attempts[#attempts + 1] = { method = cfg.method, trim = not cfg.trim }
  end

  -- What we remember / copy is the block as submitted on the first attempt
  state.lastLines = lines
  state.lastBlock = buildBlock(lines, cfg.trim)
  if cfg.copy then doCopy(state.lastBlock, false) end

  state.busy = true

  local function try(i)
    local a = attempts[i]
    if not a then
      state.busy = false
      onNotFound()
      return
    end

    local block = buildBlock(lines, a.trim)
    dbg(string.format("Attempt %d/%d: method=%s trim=%s, %d lines, %d chars",
      i, #attempts, a.method, tostring(a.trim), #lines, #block))

    local ok, perr = pcall(sendRequest, a.method, block, function(resp, err)
      if err then
        state.busy = false
        state.lastInfo = "transport error: " .. tostring(err)
        say(paint("red", "Request failed: ") .. tostring(err))
        return
      end

      local body = resp.body or ""
      state.lastBody = body
      local ctype = resp.headers and (resp.headers["Content-Type"] or resp.headers["content-type"]) or "?"
      state.lastInfo = string.format("attempt %d: %s trim=%s -> HTTP %s, %d bytes, %s",
        i, a.method, tostring(a.trim), tostring(resp.status), #body, tostring(ctype))
      dbg(state.lastInfo)
      dbg("Reply: " .. flatten(stripTags(body), 300))

      local x, y, how = parseCoords(body)
      if x then
        state.busy = false
        onFound(x, y, i, a, how)
      else
        dbg("No coordinates in reply" .. (attempts[i + 1] and ", trying next attempt" or ""))
        try(i + 1)
      end
    end)

    if not ok then
      state.busy = false
      say(paint("red", "Could not start request: ") .. tostring(perr))
    end
  end

  try(1)
end

--[[ Capture handler: fires ONCE with the whole header+map block ]]--
local function onCapture(_, ctx)
  if not (state.enabled and state.armed) then return end
  state.armed = false

  local all = {}
  local src = (ctx and ctx.lines) or { ctx.line }
  for i, ln in ipairs(src) do all[i] = ln:clean() end
  dbg(string.format("Span captured %d lines (header included)", #all))

  -- Drop the header line, and everything above AND including the "It looks like ..." row
  local first = 2
  local found = false
  for i = 2, #all do
    if all[i]:match(IGNORE_PATTERN) then
      first = i + 1
      found = true
      break
    end
  end
  if found then
    dbg(string.format("Trimmed %d line(s) above and including the 'It looks like' row", first - 1))
  else
    dbg("No 'It looks like' row found - only the header line was dropped")
  end

  local lines = {}
  for i = first, #all do lines[#lines + 1] = all[i] end

  -- Strip trailing blank lines
  while #lines > 0 and lines[#lines]:match("^%s*$") do table.remove(lines) end

  -- Optional cap: keep the last cfg.lines lines
  if cfg.lines > 0 and #lines > cfg.lines then
    local t = {}
    for i = #lines - cfg.lines + 1, #lines do t[#t + 1] = lines[i] end
    lines = t
  end

  if #lines == 0 then
    say(paint("red", "Capture came back empty."))
    say("Try: crystal set lines <n>  and  crystal set mode count   (ends capture by line count instead of at a blank line)")
    return
  end

  if cfg.lines > 0 and #lines < cfg.lines then
    say(paint("yellow", string.format("Warning: only %d map lines captured, expected %d.", #lines, cfg.lines)))
  end
  local blanks = 0
  for _, l in ipairs(lines) do if l:match("^%s*$") then blanks = blanks + 1 end end
  if blanks > 0 then dbg(blanks .. " blank line(s) inside the submitted block") end

  say(string.format("Map captured (%d lines), asking MMAtlas...", #lines))
  submit(lines)
end

-- (Re)register the capture trigger. Same name => replaces the old one.
local function registerCapture()
  local span
  if cfg.mode == "count" and cfg.lines > 0 then
    span = { max = cfg.lines + 2 }            -- header + "It looks like" row + map lines
  else
    span = { to = "^\\s*$", max = 60 }        -- ends at (and includes) first blank line
  end
  rune.trigger.regex(HEADER_PATTERN, onCapture, { name = "crystal-capture", span = span })
end

--[[ Triggers ]]--
rune.trigger.regex(SCROLL_PATTERN, function()
  if state.enabled then
    state.armed = true
    dbg("Scroll received - armed, waiting for the map")
  end
end, { name = "crystal-scroll" })

registerCapture()

--[[ Commands ]]--
local function showHelp()
  say("CrystalLocator v" .. VERSION)
  rune.echo("")
  rune.echo("* " .. paint("yellow", "crystal on") .. "          - enable and arm the locator")
  rune.echo("* " .. paint("yellow", "crystal off") .. "         - disable the locator")
  rune.echo("* " .. paint("yellow", "crystal last") .. "        - display coords of last crystal")
  rune.echo("* " .. paint("yellow", "crystal debug") .. "       - show submitted lines (with markers) and the raw reply")
  rune.echo("* " .. paint("yellow", "crystal copy") .. "        - copy the last submitted map block to the clipboard")
  rune.echo("* " .. paint("yellow", "crystal copytest") .. "    - copy a 3-line test text to check the clipboard path")
  rune.echo("* " .. paint("yellow", "crystal resend") .. "      - resubmit the last captured block")
  rune.echo("* " .. paint("yellow", "crystal log") .. "         - save block + reply to crystal_debug.txt")
  rune.echo("* " .. paint("yellow", "crystal set") .. "         - list settings;  crystal set <key> <value>  to change")
  rune.echo("    keys: debug, method(post|get), lines, mode(blank|count), trim, fallback, copy, nearby, clip, timeout")
end

local function showSettings()
  say("Settings:")
  local keys = {}
  for k in pairs(SETTINGS) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do
    rune.echo(string.format("    %-9s = %s", k, tostring(cfg[k])))
  end
  rune.echo(string.format("    %-9s = %s", "enabled", tostring(state.enabled)))
  rune.echo(string.format("    %-9s = %s", "armed", tostring(state.armed)))
  rune.echo(string.format("    %-9s = %s", "clip now", pickClipMethod()))
end

local function parseBool(v)
  v = (v or ""):lower()
  if v == "on" or v == "true" or v == "yes" or v == "1" then return true end
  if v == "off" or v == "false" or v == "no" or v == "0" then return false end
  return nil
end

local function setSetting(key, val)
  local spec = SETTINGS[key]
  if not spec then
    say("Unknown setting '" .. key .. "'. Type 'crystal set' to list them.")
    return
  end
  if spec == "bool" then
    local b = parseBool(val)
    if b == nil then say("Use on/off for " .. key); return end
    cfg[key] = b
  elseif spec == "number" then
    local n = tonumber(val)
    local min = (key == "lines") and 0 or 1
    if not n or n < min then say(key .. " needs a number >= " .. min); return end
    cfg[key] = n
  else
    local okv = false
    for _, allowed in ipairs(spec) do
      if allowed == val then okv = true end
    end
    if not okv then say(key .. " must be one of: " .. table.concat(spec, ", ")); return end
    cfg[key] = val
  end
  if key == "lines" or key == "mode" then registerCapture() end
  say(key .. " = " .. tostring(cfg[key]))
end

local function showDebug()
  if not state.lastLines then
    say("No crystal block captured yet.")
    return
  end
  say(string.format("Last submitted block (%d lines). Format: nn [length] |text|  - '|' at the end reveals trailing spaces", #state.lastLines))
  rune.echo("--------------------------------")
  for i, l in ipairs(state.lastLines) do
    rune.echo(string.format("%02d [%3d] |%s|", i, #l, l))
  end
  rune.echo("--------------------------------")
  rune.echo(string.format("Block: %d chars, %d chars URL-encoded", #state.lastBlock, #urlencode(state.lastBlock)))
  if state.lastInfo then rune.echo("Last exchange: " .. state.lastInfo) end
  if state.lastBody then rune.echo("Raw reply: " .. flatten(state.lastBody, 600)) end
end

local function writeLog()
  if not state.lastBlock then
    say("No crystal block captured yet.")
    return
  end
  local home = os.getenv("HOME") or os.getenv("USERPROFILE") or ""
  local path = home .. "/.config/rune/eljayPlugins/crystal_debug.txt"
  local ok, f, err = pcall(io.open, path, "w")
  if ok and f then
    f:write("== Submitted block ==\n" .. state.lastBlock .. "\n\n")
    f:write("== Last exchange ==\n" .. tostring(state.lastInfo) .. "\n\n")
    f:write("== Raw reply ==\n" .. tostring(state.lastBody) .. "\n")
    f:close()
    say("Written to " .. path)
  else
    say("Failed to write log: " .. tostring(ok and err or f))
  end
end

local commands = {
  [""]       = showHelp,
  help       = showHelp,
  on         = function()
    state.enabled = true
    state.armed = true
    say("Locator enabled and armed - read the scroll / look at the map now.")
  end,
  off        = function()
    state.enabled = false
    state.armed = false
    say("Locator disabled.")
  end,
  last       = function()
    if state.crystal then
      say(paint("blue", "Your last crystal was located at: ") .. paint("white", state.crystal))
    else
      say("Go buy a map first!")
    end
  end,
  debug      = showDebug,
  log        = writeLog,
  copy       = function()
    if state.lastBlock then
      doCopy(state.lastBlock, true)
    else
      say("No crystal block captured yet.")
    end
  end,
  copytest   = function()
    say("Copying a 3-line test via '" .. pickClipMethod() .. "' - paste somewhere; you should see 3 lines: alpha / beta / gamma")
    doCopy("alpha\nbeta\ngamma", true)
  end,
  resend     = function()
    if state.lastLines then
      say("Resubmitting last captured block...")
      submit(state.lastLines)
    else
      say("No crystal block captured yet.")
    end
  end,
}

rune.alias.regex("^crystal(?:\\s+(\\S+))?(?:\\s+(.*))?$", function(m, ctx)
  m = m or (ctx and ctx.matches) or {}
  local sub  = (m[1] or ""):lower()
  local rest = m[2] or ""

  if sub == "set" then
    local key, val = rest:match("^(%S+)%s*(.-)%s*$")
    if key then setSetting(key:lower(), val) else showSettings() end
    return
  end

  local fn = commands[sub]
  if fn then
    fn()
  else
    say("Unknown command '" .. sub .. "'.")
    showHelp()
  end
end, { name = "crystal-cmd" })

--[[ Crystal quest item aliases (need the character name) ]]--
local function charName()
  local n = rune.get_global_var and rune.get_global_var("name")
  if n and n ~= "" then return n end
  say(paint("red", "Character name is not set (global var 'name').") )
  return nil
end

rune.alias.exact("cc", function()
  local n = charName()
  if n then rune.send("give tadamir" .. n .. " Tadamir;drop crystalquest" .. n .. ";sac crystalquest" .. n) end
end)

rune.alias.exact("cl", function()
  local n = charName()
  if n then rune.send("look crystalquest" .. n) end
end)

rune.alias.exact("CrystalLocator:help", showHelp)

rune.alias.exact("cs", "crystal last")


say("CrystalLocator v" .. VERSION .. " loaded - type 'crystal help'")
