-- Filename: eljayPlugins/crystalLocator.lua
-- Purpose: Finds the coordinates of a guild crystal from the scroll map via the MMAtlas crystal finder and shows them in the status bar.
-- Version: 3.20
-- Date: 2026-Oct-25
--[[ Todo
- insert planning notes here between revisions.
]]
-- Changelog:
--   3.20 Under 16000 bytes (retries fixed, settings reduced, `log` and `copytest` dropped);
--        help rows use the short alias.
-- How it works:
--   * Inspired by the MUSHclient plugin by Elbereth.
--   * The scroll from Tadamir arms the locator (`crystal on` arms it by hand).
--   * The map block is captured whole; the header and everything above and including the
--     "It looks like ..." row are trimmed off.
--   * It goes to the MMAtlas finder (POST; if nothing is found it retries GET, then POST
--     with trailing spaces trimmed) and is copied to the clipboard (wl-copy, xclip, xsel
--     or OSC 52).
--   * Coordinates are echoed, shown in the statusTray CRYSTAL slot (cleared on a new map,
--     `crystal off` and `cc`), and `spdxy nearby x, y` is run.
--   * Settings are saved with rune.store (never debug); helpstyle loads lazily.

local LOAD_START = (os and os.clock) and os.clock() or nil
local load_ms = nil

local VERSION = "3.20"

-- Command names: full command and short alias.
local NAME  = "crystalLocator"
local SHORT = "crystal"

local ENDPOINT   = "https://ooc.dune.net/mm/find-crystal-guild-vi.pl"
local STORE_KEY  = "crystallocator.settings"
local TRAY_KEY   = "statustray.settings"
local IS_WINDOWS = package.config:sub(1, 1) == "\\"

local SCROLL_PATTERN = "Tadamir the guildsman gives you a tightly-rolled scroll\\.$"  -- Go regexp
local HEADER_PATTERN = "^You focus your powers of observation on"  -- Go regexp
local IGNORE_PATTERN = "^It looks like"  -- Lua pattern

local CLIP_CMDS = { ["wl-copy"] = "wl-copy", xclip = "xclip -selection clipboard", xsel = "xsel --clipboard --input" }
local function valid_clip(c) return c == "auto" or c == "osc" or CLIP_CMDS[c] ~= nil end
local ATTEMPTS = { { "post", false }, { "get", false }, { "post", true } }   -- method, trim

local cfg   = { debug = false, fallback = true, copy = true, clip = "auto" }
local state = { enabled = true, armed = false, busy = false }

local function load_settings()
  local ok, saved = pcall(rune.store.get, STORE_KEY)
  if not ok or type(saved) ~= "table" then return end
  if type(saved.enabled) == "boolean" then state.enabled = saved.enabled end
  for _, k in ipairs({ "fallback", "copy" }) do
    if type(saved[k]) == "boolean" then cfg[k] = saved[k] end
  end
  if valid_clip(saved.clip) then cfg.clip = saved.clip end
end

-- Read the latest stored table, change it, save it, then refresh the in-memory copy.
local function save_settings()
  local ok, t = pcall(rune.store.get, STORE_KEY)
  if not ok or type(t) ~= "table" then t = {} end
  t.enabled, t.fallback, t.copy, t.clip = state.enabled, cfg.fallback, cfg.copy, cfg.clip
  pcall(rune.store.set, STORE_KEY, t)
  load_settings()
end

load_settings()

local ANSI = { cyan = 36, blue = 34, white = 37, yellow = 33, red = 31 }

-- rune.style.<colour>, then rune.style("<colour>", ...), then a plain ANSI escape.
local function paint(color, text)
  text = tostring(text)
  local style = rune.style
  local fn = type(style) == "table" and style[color]
  local ok, out
  if type(fn) == "function" then
    ok, out = pcall(fn, text)
  elseif type(style) == "function" then
    ok, out = pcall(style, color, text)
  end
  if ok and type(out) == "string" then return out end
  return "\27[" .. (ANSI[color] or 0) .. "m" .. text .. "\27[0m"
end

local PREFIX = "[" .. NAME .. "] "

local function say(msg)
  pcall(rune.echo, paint("cyan", PREFIX) .. tostring(msg))
end

local function emit(line)
  if line ~= nil then rune.echo(line) end
end

local function dbg(msg)
  if cfg.debug then rune.echo(paint("blue", "[" .. NAME .. ":debug] ") .. msg) end
end

local function flatten(s, n)
  s = tostring(s or "")
  if n and #s > n then s = s:sub(1, n) .. "..." end
  return (s:gsub("[\r\n]+", " | "):gsub("[%c\127]", " "))
end

local function urlencode(s)
  return (s:gsub("\r", ""):gsub("[^%w%-%._~ ]", function(c)
    return string.format("%%%02X", c:byte())
  end):gsub(" ", "+"))
end

-- statusTray CRYSTAL slot: used only when statusTray is loaded, else its store entry is updated.
local function tray()
  for name, m in pairs(package.loaded) do
    if type(name) == "string" and name:match("statusTray$") and type(m) == "table"
       and type(m.set_crystal) == "function" then
      return m
    end
  end
end

local function store_crystal(value)
  local ok, t = pcall(rune.store.get, TRAY_KEY)
  if not ok or type(t) ~= "table" then t = {} end
  t.crystal = value
  pcall(rune.store.set, TRAY_KEY, t)
end

-- Set (x, y) or clear (no arguments) the CRYSTAL slot.
local function status_crystal(x, y)
  local m = tray()
  if m and x then pcall(m.set_crystal, x, y)
  elseif m and type(m.clear_crystal) == "function" then pcall(m.clear_crystal)
  else store_crystal(x and (x .. " " .. y) or nil) end
end

-- Clipboard: native tool when found (cached: the lookup spawns a shell), else OSC 52.
local clipChoice = nil

local function hasTool(name)
  local ok, p = pcall(io.popen, "command -v " .. name .. " 2>/dev/null")
  if not ok or not p then return false end
  local out = p:read("*l")
  p:close()
  return out ~= nil and out ~= ""
end

local function clipMethod()
  if IS_WINDOWS then return "osc" end
  if cfg.clip ~= "auto" then return cfg.clip end
  if not clipChoice then
    clipChoice = "osc"
    local wl, x = os.getenv("WAYLAND_DISPLAY"), os.getenv("DISPLAY")
    if wl and hasTool("wl-copy") then clipChoice = "wl-copy"
    elseif x and hasTool("xclip") then clipChoice = "xclip"
    elseif x and hasTool("xsel") then clipChoice = "xsel" end
  end
  return clipChoice
end

local function doCopy(text, announce)
  text = text:gsub("\r", ""):gsub("[\1-\8\11-\31\127]", "")
  local method = clipMethod()
  local ok, err
  if method == "osc" then
    ok, err = pcall(function() rune.clipboard.set(text) end)
  else
    local p
    ok, p = pcall(io.popen, CLIP_CMDS[method] .. " 2>/dev/null", "w")
    if ok and p then
      p:write(text)
      p:close()
    else
      ok, err = false, "io.popen unavailable (try: " .. SHORT .. " set clip osc)"
    end
  end
  if ok then
    local msg = string.format("Copied %d chars to the clipboard via %s", #text, method)
    local out = announce and say or dbg
    out(msg)
  else
    say(paint("red", "Clipboard copy failed (" .. method .. "): ") .. tostring(err))
  end
  return ok
end

local function parseCoords(body)
  local text = body:gsub("<[^>]*>", " "):gsub("&nbsp;", " ")
  local x, y = text:match("%(%s*(%-?%d+)%s*,%s*(%-?%d+)%s*%)")
  if not x and #text <= 500 then x, y = text:match("(%-?%d+)%s*,%s*(%-?%d+)") end
  return x, y, text
end

local function buildBlock(lines, trim)
  local t = {}
  for i, l in ipairs(lines) do t[i] = trim and (l:gsub("%s+$", "")) or l end
  return table.concat(t, "\n")
end

local function sendRequest(method, block, callback)
  local enc = urlencode(block)
  local opts = { timeout = 15 }
  if method == "get" then
    rune.http.get(ENDPOINT .. "?map=" .. enc, opts, callback)
  else
    opts.headers = { ["Content-Type"] = "application/x-www-form-urlencoded" }
    rune.http.post(ENDPOINT, "map=" .. enc, opts, callback)
  end
end

local function onFound(x, y)
  state.crystal, state.busy = x .. "," .. y, false
  status_crystal(x, y)
  say("Your crystal is located at " .. paint("white", "(" .. x .. ", " .. y .. ")"))
  say("Walk there with: " .. paint("yellow", "spdxy " .. x .. ", " .. y))
  rune.send("spdxy nearby " .. x .. ", " .. y)
end

local function submit(lines)
  if state.busy then say("A request is already running, please wait."); return end

  state.lastLines, state.lastBlock = lines, buildBlock(lines, false)
  if cfg.copy then doCopy(state.lastBlock, false) end
  state.busy = true
  status_crystal()

  local total = cfg.fallback and #ATTEMPTS or 1

  local function try(i)
    if i > total then
      state.busy = false
      say(paint("red", "MMAtlas could not find that location.") .. " See: " ..
        paint("yellow", SHORT .. " debug"))
      return
    end
    local method, trim = ATTEMPTS[i][1], ATTEMPTS[i][2]

    local ok, perr = pcall(sendRequest, method, buildBlock(lines, trim), function(resp, err)
      if err then
        state.busy, state.lastInfo = false, "transport error: " .. tostring(err)
        say(paint("red", "Request failed: ") .. tostring(err))
        return
      end
      local body = tostring(resp.body or ""):sub(1, 200000)
      state.lastBody = body
      state.lastInfo = string.format("attempt %d: %s trim=%s -> HTTP %s, %d bytes",
        i, method, tostring(trim), tostring(resp.status), #body)
      local x, y, text = parseCoords(body)
      dbg(state.lastInfo .. "; reply: " .. flatten(text, 200))
      if x then onFound(x, y) else try(i + 1) end
    end)
    if not ok then
      state.busy = false
      say(paint("red", "Could not start request: ") .. tostring(perr))
    end
  end

  try(1)
end

local function onCapture(_, ctx)
  if not (state.enabled and state.armed) then return end
  state.armed = false

  local all = {}
  for i, ln in ipairs((ctx and ctx.lines) or { ctx.line }) do all[i] = ln:clean() end

  -- Drop the header, and everything above and including the "It looks like" row.
  local first = 2
  for i = 2, #all do
    if all[i]:match(IGNORE_PATTERN) then first = i + 1; break end
  end
  local lines = {}
  for i = first, #all do lines[#lines + 1] = all[i] end
  while #lines > 0 and lines[#lines]:match("^%s*$") do table.remove(lines) end

  if #lines == 0 then say(paint("red", "Capture came back empty.")); return end
  say(string.format("Map captured (%d lines), asking MMAtlas...", #lines))
  submit(lines)
end

rune.trigger.regex(HEADER_PATTERN, onCapture, { name = "crystal-capture", span = { to = "^\\s*$", max = 60 } })

rune.trigger.regex(SCROLL_PATTERN, function()
  if state.enabled then state.armed = true; dbg("Scroll received - armed") end
end, { name = "crystal-scroll" })

local H_module
local function get_helpstyle()
  if H_module == nil then
    local ok, mod = pcall(require, "helpstyle")
    H_module = (ok and type(mod) == "table") and mod or false
  end
  return H_module or nil
end

local function status_line()
  return string.format("v%s  enabled=%s armed=%s debug=%s%s", VERSION, tostring(state.enabled),
    tostring(state.armed), tostring(cfg.debug), load_ms and (" load=" .. load_ms .. "ms") or "")
end

local HELP_COMMANDS = {
  { NAME,                     "show this help" },
  { SHORT .. " on|off",        "enable and arm / disable the locator" },
  { SHORT .. " last",          "show the last crystal location" },
  { SHORT .. " debug",         "show the last block and raw reply" },
  { SHORT .. " debug on|off",  "toggle debug messages (default off)" },
  { SHORT .. " copy",          "copy the last map block to the clipboard" },
  { SHORT .. " resend",        "resubmit the last captured block" },
  { SHORT .. " set",           "list settings" },
  { SHORT .. " set <key> <v>", "change a setting" },
}

local HELP_USAGE = {
  { "look map | look crystalQuest", "find location and populate statusTray" },
  { "tc", "take crystal" },
  { "cc", "give, drop and sac the map; clear tray" }, 
  { SHORT, "short alias for " .. NAME },
}

local function showHelp()
  local status = status_line()
  local H = get_helpstyle()

  local styled = H and pcall(function()
    rune.echo(H.title(NAME .. "  (alias: " .. SHORT .. ")"))
    emit(H.section("Commands"))
    for _, row in ipairs(HELP_COMMANDS) do emit(H.line(row[1], row[2])) end
    emit(H.section("Usage"))
    for _, row in ipairs(HELP_USAGE) do emit(H.line(row[1], row[2])) end
    emit(H.foot(status))
  end)
  if styled then return end

  -- Plain fallback when helpstyle is missing or its API differs.
  emit("crystalLocator")
  for _, list in ipairs({ HELP_COMMANDS, HELP_USAGE }) do
    for _, row in ipairs(list) do emit("  " .. row[1] .. "  " .. row[2]) end
  end
  emit(status)
end

local BOOLS = { on = true, ["true"] = true, yes = true, off = false, ["false"] = false, no = false }
local function parseBool(v) return BOOLS[(v or ""):lower()] end

local function setSetting(key, val)
  if key == "clip" then
    if not valid_clip(val) then say("clip must be auto, osc, wl-copy, xclip or xsel"); return end
    cfg.clip, clipChoice = val, nil
  elseif key == "debug" or key == "fallback" or key == "copy" then
    local b = parseBool(val)
    if b == nil then say("Use on/off for " .. key); return end
    cfg[key] = b
  else
    say("Unknown setting '" .. key .. "' (debug, fallback, copy, clip).")
    return
  end
  if key ~= "debug" then save_settings() end
  say(key .. " = " .. tostring(cfg[key]))
end

local function showDebug()
  if not state.lastLines then say("No crystal block captured yet."); return end
  say(#state.lastLines .. " lines: nn [length] |text| (the closing | shows trailing spaces)")
  for i, l in ipairs(state.lastLines) do
    emit(string.format("%02d [%3d] |%s|", i, #l, (l:gsub("[%c\127]", "?"))))
  end
  emit(tostring(state.lastInfo) .. "; reply: " .. flatten(state.lastBody, 600))
end

local commands
commands = {
  [""] = showHelp,
  on = function()
    state.enabled, state.armed = true, true
    save_settings()
    say("Locator enabled and armed - read the scroll / look at the map now.")
  end,
  off = function()
    state.enabled, state.armed = false, false
    save_settings()
    status_crystal()
    say("Locator disabled.")
  end,
  last = function()
    if state.crystal then
      say(paint("blue", "Your last crystal was located at: ") .. paint("white", state.crystal))
    else
      say("Go buy a map first!")
    end
  end,
  debug = function(arg)
    arg = (arg or ""):lower()
    if arg == "" then showDebug(); return end
    local b = parseBool(arg)
    if b == nil then say("Usage: " .. SHORT .. " debug on|off  (no argument shows the last block)"); return end
    cfg.debug = b
    say("Debug messages " .. (b and "on" or "off"))
  end,
  copy = function()
    if state.lastBlock then doCopy(state.lastBlock, true) else say("No crystal block captured yet.") end
  end,
  resend = function()
    if state.lastLines then
      say("Resubmitting last captured block...")
      submit(state.lastLines)
    else
      say("No crystal block captured yet.")
    end
  end,
}

local function dispatch(args, ctx)
  if type(args) ~= "string" then args = (ctx and type(ctx.args) == "string") and ctx.args or "" end
  local sub, rest = args:match("^%s*(%S*)%s*(.-)%s*$")
  sub = (sub or ""):lower()

  if sub == "set" then
    local key, val = rest:match("^(%S*)%s*(.-)%s*$")
    if key == "" then
      say(string.format("debug=%s fallback=%s copy=%s clip=%s (%s)", tostring(cfg.debug),
        tostring(cfg.fallback), tostring(cfg.copy), cfg.clip, clipMethod()))
    else
      setSetting(key:lower(), val)
    end
  elseif commands[sub] then
    commands[sub](rest)
  else
    showHelp()
  end
end

rune.alias.exact(NAME, dispatch)
rune.alias.exact(SHORT, dispatch)

-- Quest item aliases (map keyword: crystalQuest).
rune.alias.exact("cc", function()
  status_crystal()
  return "give tadamir Tadamir;drop crystalQuest;sac crystalQuest"
end)
rune.alias.exact("tc", "take crystal")

if LOAD_START then load_ms = math.floor((os.clock() - LOAD_START) * 1000 + 0.5) end

say("v" .. VERSION .. " loaded (" .. NAME .. " or " .. SHORT .. " for help)")