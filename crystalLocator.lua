-- Filename: eljayPlugins/crystalLocator.lua
-- Purpose: Finds the coordinates of a guild crystal from the scroll map via the MMAtlas crystal finder and shows them in the status bar.
-- Version: 3.15
-- Date: 2026-Oct-14
-- Changelog:
--   3.15 Brought to standard: loader line, clipboard tool lookup cached (no shell spawn per copy),
--        tolerant statusTray lookup, restored the Inspired-by line, shorter changelog.
--   3.14 The `cc` alias also clears the statusTray CRYSTAL slot.
--   3.13 Main command is `crystalLocator` with `crystal` as short alias; added the `tc` alias.
-- How it works:
--   * Inspired by the MUSHclient plugin by Elbereth.
--   * Receiving the scroll from Tadamir arms the locator (`crystalLocator on` arms it manually).
--   * Reading the map is captured as one multi-line block; the header line and everything above and including the "It looks like ..." row are trimmed off.
--   * The remaining map lines are submitted to the MMAtlas crystal finder (POST; if no coordinates are returned it retries once with GET and once with trailing spaces trimmed).
--   * The submitted block is copied to the clipboard (wl-copy / xclip / xsel, OSC 52 as the last resort and on Windows).
--   * When coordinates come back, the plugin echoes them, prints "Walk there with: spdxy x, y" and runs `spdxy nearby x, y`.
--   * The found coordinates are placed in the CRYSTAL slot of the statusTray bar ("x y"); the slot is cleared when a new map is submitted, on `crystalLocator off` and when you run `cc`.
--   * Settings (and the enabled flag) are saved with rune.store; debug is never saved and is always off at load.
--
-- Commands (`crystal` is a short alias for `crystalLocator`):
--   crystalLocator                show help
--   crystalLocator on             enable and arm the locator
--   crystalLocator off            disable the locator
--   crystalLocator last           display the last crystal location
--   crystalLocator debug          display the last submitted block and raw reply
--   crystalLocator debug on|off   toggle debug output while processing
--   crystalLocator copy           copy the last submitted map block
--   crystalLocator copytest       copy a 3-line test block to check the clipboard path
--   crystalLocator resend         resubmit the last captured block
--   crystalLocator log            save the block and reply to crystal_debug.txt in the temp folder
--   crystalLocator set            list settings; use `crystalLocator set <key> <value>` to change them
--   cs                            shorthand for `crystalLocator last`
--   cl                            look at the crystal quest item (alias)
--   cc                            give the crystal to Tadamir then drop and sac the map; also clears the statusTray CRYSTAL slot
--   tc                            take the crystal (alias)
--
-- Notes:
--   * Clipboard writes are sanitized so the server cannot inject control codes.
--   * Server text echoed to the screen has control characters removed.

local VERSION  = "3.15"
local ENDPOINT = "https://ooc.dune.net/mm/find-crystal-guild-vi.pl"
local STORE_KEY = "crystallocator.settings"
local MAX_BODY  = 200000   -- bytes of a reply that are ever parsed
local IS_WINDOWS = package.config:sub(1, 1) == "\\"

local SCROLL_PATTERN = "Tadamir the guildsman gives you a tightly-rolled scroll\\.$"   -- Go regexp (RE2)
local HEADER_PATTERN = "^You focus your powers of observation on"        -- Go regexp (RE2)
local IGNORE_PATTERN = "^It looks like"                                  -- Lua pattern (string.match)

-- Settings (change live with: crystalLocator set <key> <value>)
local cfg = {
  debug    = false,   -- verbose [crystalLocator:debug] output
  method   = "post",  -- "post" or "get"
  lines    = 0,       -- map lines to submit; 0 = no cap
  mode     = "blank", -- "blank": capture ends at first blank line; "count": capture header + `lines` + ignored row
  trim     = false,   -- strip trailing whitespace from every map line before submitting
  fallback = true,    -- if no coords found, retry with other method / other trim setting
  copy     = true,    -- copy the submitted map block to the clipboard
  clip     = "auto",  -- clipboard method: auto | osc | wl-copy | xclip | xsel
  timeout  = 15,      -- HTTP timeout in seconds
}

local SETTINGS = {
  debug = "bool", fallback = "bool", copy = "bool", trim = "bool",
  method = { "post", "get" }, mode = { "blank", "count" },
  clip = { "auto", "osc", "wl-copy", "xclip", "xsel" },
  lines = "number", timeout = "number",
}

-- State
local state = {
  enabled   = true,
  armed     = false,
  busy      = false,
  crystal   = nil,
  lastLines = nil,
  lastBlock = nil,
  lastBody  = nil,
  lastInfo  = nil,
}

-- Persistence (rune.store). Debug is never saved: it is always off at load.
local function load_settings()
  local ok, saved = pcall(rune.store.get, STORE_KEY)
  if not ok or type(saved) ~= "table" then return end

  if type(saved.enabled) == "boolean" then state.enabled = saved.enabled end

  for key, spec in pairs(SETTINGS) do
    local v = saved[key]
    if key ~= "debug" and v ~= nil then
      if spec == "bool" then
        if type(v) == "boolean" then cfg[key] = v end
      elseif spec == "number" then
        if type(v) == "number" and v >= ((key == "lines") and 0 or 1) then cfg[key] = v end
      else
        for _, allowed in ipairs(spec) do
          if allowed == v then cfg[key] = v end
        end
      end
    end
  end
end

local function save_settings()
  local t = { enabled = state.enabled }
  for key in pairs(SETTINGS) do
    if key ~= "debug" then t[key] = cfg[key] end
  end
  pcall(rune.store.set, STORE_KEY, t)
end

load_settings()

-- statusTray integration ---------------------------------------------------
-- The CRYSTAL slot of the statusTray bar shows only found coordinates ("x y").
-- statusTray is used only if it is already loaded (so removing it from the
-- PLUGINS list in initEljay.lua really disables it); otherwise the value is
-- written to its rune.store entry so it is picked up when statusTray loads.
local TRAY_MODULES   = { "eljayPlugins/statusTray", "eljayPlugins.statusTray" }
local TRAY_STORE_KEY = "statustray.settings"

local function tray()
  for _, name in ipairs(TRAY_MODULES) do
    local m = package.loaded[name]
    if type(m) == "table" and type(m.set_crystal) == "function" then return m end
  end
  -- Fallback: any already-loaded module whose name ends in "statusTray"
  for name, m in pairs(package.loaded) do
    if type(name) == "string" and name:match("statusTray$")
       and type(m) == "table" and type(m.set_crystal) == "function" then
      return m
    end
  end
  return nil
end

-- Update only the crystal field; keep anything else stored in that table.
local function store_crystal(value)
  local ok, saved = pcall(rune.store.get, TRAY_STORE_KEY)
  local t = (ok and type(saved) == "table") and saved or {}
  t.crystal = value
  pcall(rune.store.set, TRAY_STORE_KEY, t)
end

-- Helpers
local function paint(color, text)
  local fn = rune.style and rune.style[color]
  if type(fn) == "function" then
    local ok, out = pcall(fn, text)
    if ok and out then return out end
  end
  return text
end

local function say(msg)
  rune.echo(paint("cyan", "[crystalLocator] ") .. msg)
end

local function dbg(msg)
  if cfg.debug then
    rune.echo(paint("blue", "[crystalLocator:debug] ") .. msg)
  end
end

-- Used for echoing server text: control characters (including ESC) are removed
-- so a reply cannot inject terminal escape sequences.
local function flatten(s, n)
  s = tostring(s or "")
  if n and #s > n then s = s:sub(1, n) .. "..." end
  s = s:gsub("[\r\n]+", " | ")
  return (s:gsub("[%c\127]", " "))
end

-- URL encode: everything except unreserved chars is %XX, space becomes +
local function urlencode(str)
  str = str:gsub("\r", "")
  local out = str:gsub("([^%w%-%._~ ])", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
  out = out:gsub(" ", "+")
  return out
end

-- Clipboard sanitisation
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

-- The auto-detected tool is cached: looking it up spawns a shell, so it is done once
-- (cleared by `crystalLocator copytest` and when the clip setting changes).
local clipChoice = nil

local function pickClipMethod()
  if IS_WINDOWS then return "osc" end   -- the external tools below are Unix-only
  if cfg.clip ~= "auto" then return cfg.clip end
  if clipChoice then return clipChoice end
  if os.getenv("WAYLAND_DISPLAY") and hasTool("wl-copy") then clipChoice = "wl-copy"
  elseif os.getenv("DISPLAY") and hasTool("xclip") then clipChoice = "xclip"
  elseif os.getenv("DISPLAY") and hasTool("xsel") then clipChoice = "xsel"
  else clipChoice = "osc" end
  return clipChoice
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
    return false, method, "io.popen is not available (try: crystalLocator set clip osc)"
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

-- Response parsing
local function stripTags(body)
  local t = body:gsub("<[^>]*>", " ")
  t = t:gsub("&nbsp;", " "):gsub("&amp;", "&")
  return t
end

-- Returns x, y, how (strings) or nil
local function parseCoords(body)
  local text = stripTags(body or "")
  local x, y = text:match("%(%s*(%-?%d+)%s*,%s*(%-?%d+)%s*%)")
  if x then return x, y, "parenthesised pair" end

  if #text <= 500 then
    x, y = text:match("(%-?%d+)%s*,%s*(%-?%d+)")
    if x then return x, y, "bare pair (short reply)" end
  end
  return nil
end

-- Request building
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

-- Place found coordinates in / clear the statusTray CRYSTAL slot
local function set_status_crystal(x, y)
  local m = tray()
  if m then
    pcall(m.set_crystal, tostring(x), tostring(y))
  else
    store_crystal(tostring(x) .. " " .. tostring(y))
  end
end

local function clear_status_crystal()
  local m = tray()
  if m and type(m.clear_crystal) == "function" then
    pcall(m.clear_crystal)
  else
    store_crystal(nil)
  end
end

-- Found / not found
local function onFound(x, y, attemptNo, attempt, how)
  state.crystal = x .. "," .. y
  state.busy = false
  set_status_crystal(x, y)

  say("Your crystal is located at " .. paint("white", "(" .. x .. ", " .. y .. ")"))
  dbg("Parsed from response using: " .. how)

  if attemptNo > 1 then
    say(string.format(
      "Attempt %d worked (method=%s, trim=%s). Make it the default with: crystalLocator set method %s  /  crystalLocator set trim %s",
      attemptNo, attempt.method, tostring(attempt.trim), attempt.method, attempt.trim and "on" or "off"
    ))
  end

  say("Walk there with: " .. paint("yellow", "spdxy " .. x .. ", " .. y))
  rune.send("spdxy nearby " .. x .. ", " .. y)
end

local function onNotFound()
  state.busy = false
  say(paint("red", "MMAtlas could not find that location."))
  say("Run " .. paint("yellow", "crystalLocator debug") .. " to inspect the submitted lines and the raw reply (" .. paint("yellow", "crystalLocator debug on") .. " for step-by-step messages next time).")
end

-- Submit a block (list of lines), trying fallbacks if enabled
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

  state.lastLines = lines
  state.lastBlock = buildBlock(lines, cfg.trim)
  if cfg.copy then doCopy(state.lastBlock, false) end

  state.busy = true
  clear_status_crystal()

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

      local body = tostring(resp.body or ""):sub(1, MAX_BODY)
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

-- Capture handler: fires ONCE with the whole header+map block
local function onCapture(_, ctx)
  if not (state.enabled and state.armed) then return end
  state.armed = false

  local all = {}
  local src = (ctx and ctx.lines) or { ctx.line }
  for i, ln in ipairs(src) do
    all[i] = ln:clean()
  end
  dbg(string.format("Span captured %d lines (header included)", #all))

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
  for i = first, #all do
    lines[#lines + 1] = all[i]
  end

  while #lines > 0 and lines[#lines]:match("^%s*$") do
    table.remove(lines)
  end

  if cfg.lines > 0 and #lines > cfg.lines then
    local t = {}
    for i = #lines - cfg.lines + 1, #lines do
      t[#t + 1] = lines[i]
    end
    lines = t
  end

  if #lines == 0 then
    say(paint("red", "Capture came back empty."))
    say("Try: crystalLocator set lines <n>  and  crystalLocator set mode count   (ends capture by line count instead of at a blank line)")
    return
  end

  if cfg.lines > 0 and #lines < cfg.lines then
    say(paint("yellow", string.format("Warning: only %d map lines captured, expected %d.", #lines, cfg.lines)))
  end

  local blanks = 0
  for _, l in ipairs(lines) do
    if l:match("^%s*$") then blanks = blanks + 1 end
  end
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
    span = { to = "^\\s*$", max = 60 }        -- ends at (and includes) first blank line (Go regexp)
  end
  rune.trigger.regex(HEADER_PATTERN, onCapture, { name = "crystal-capture", span = span })
end

-- Triggers
rune.trigger.regex(SCROLL_PATTERN, function()
  if state.enabled then
    state.armed = true
    dbg("Scroll received - armed, waiting for the map")
  end
end, { name = "crystal-scroll" })

registerCapture()

-- Commands & help
local okH, H = pcall(require, "helpstyle")
if not okH or type(H) ~= "table" then H = nil end

local function onoff(flag) return flag and "on" or "off" end

-- Version first, no plugin name, one footer row.
local function status_line()
  return string.format("v%s  enabled=%s armed=%s debug=%s",
    VERSION, onoff(state.enabled), onoff(state.armed), onoff(cfg.debug))
end

local HELP = {
  { "crystalLocator on",           "enable and arm the locator" },
  { "crystalLocator off",          "disable the locator and clear the statusTray CRYSTAL slot" },
  { "crystalLocator last",         "display coords of last crystal (shorthand: cs)" },
  { "crystalLocator debug",        "show submitted lines (with markers) and the raw reply" },
  { "crystalLocator debug on|off", "show / hide debug messages while processing (default off)" },
  { "crystalLocator copy",         "copy the last submitted map block to the clipboard" },
  { "crystalLocator copytest",     "copy a 3-line test text to check the clipboard path" },
  { "crystalLocator resend",       "resubmit the last captured block" },
  { "crystalLocator log",          "save block + reply to crystal_debug.txt in the temp folder" },
  { "crystalLocator set",          "list settings;  crystalLocator set <key> <value>  to change" },
  { "crystal",                     "short alias: crystal <command> works like crystalLocator <command>" },
  { "cl",                          "look crystalQuest" },
  { "cc",                          "give tadamir Tadamir;drop crystalQuest;sac crystalQuest; clears the statusTray CRYSTAL slot" },
  { "tc",                          "take crystal" },
}
local KEYS_LINE = "settings keys: debug, method(post|get), lines, mode(blank|count), trim, fallback, copy, clip, timeout"

local function showHelp()
  if H then
    local ok = pcall(function()
      rune.echo(H.title("Crystal Locator"))
      rune.echo(H.section("Commands"))
      for _, row in ipairs(HELP) do
        rune.echo(H.line(row[1] .. "  -  " .. row[2]))
      end
      rune.echo(H.line(KEYS_LINE))
      rune.echo(H.foot(status_line()))
    end)
    if ok then return end
  end

  say("CrystalLocator v" .. VERSION)
  for _, row in ipairs(HELP) do
    rune.echo("* " .. paint("yellow", row[1]) .. "  - " .. row[2])
  end
  rune.echo("    " .. KEYS_LINE)
  rune.echo(status_line())
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
    say("Unknown setting '" .. key .. "'. Type 'crystalLocator set' to list them.")
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
  save_settings()
  if key == "clip" then clipChoice = nil end
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
    rune.echo(string.format("%02d [%3d] |%s|", i, #l, (l:gsub("[%c\127]", "?"))))
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
  -- Temp folder (not the plugin folder), so the log is never committed to git
  local tmp = os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
  local path = tmp .. "/crystal_debug.txt"
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
    save_settings()
    say("Locator enabled and armed - read the scroll / look at the map now.")
  end,
  off        = function()
    state.enabled = false
    state.armed = false
    save_settings()
    clear_status_crystal()
    say("Locator disabled.")
  end,
  last       = function()
    if state.crystal then
      say(paint("blue", "Your last crystal was located at: ") .. paint("white", state.crystal))
    else
      say("Go buy a map first!")
    end
  end,
  debug      = function(arg)
    arg = (arg or ""):lower()
    if arg == "" then showDebug(); return end
    local b = parseBool(arg)
    if b == nil then say("Usage: crystalLocator debug on|off   (no argument shows the last submitted block)"); return end
    cfg.debug = b
    say("Debug messages " .. (b and "on" or "off"))
  end,
  log        = writeLog,
  copy       = function()
    if state.lastBlock then
      doCopy(state.lastBlock, true)
    else
      say("No crystal block captured yet.")
    end
  end,
  copytest   = function()
    clipChoice = nil   -- re-detect, e.g. after installing wl-clipboard / xclip
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

rune.alias.regex("^(?:crystalLocator|crystal)(?:\\s+(\\S+))?(?:\\s+(.*))?$", function(m, ctx)
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
    fn(rest)
  else
    say("Unknown command '" .. sub .. "'.")
    showHelp()
  end
end, { name = "crystal-cmd" })

-- Crystal quest item aliases (map keyword: crystalQuest)
-- cc: hand in the crystal, then clear the statusTray CRYSTAL slot. The commands are
-- returned as a string, so they are processed exactly as the plain alias string was.
rune.alias.exact("cc", function()
  clear_status_crystal()
  return "give tadamir Tadamir;drop crystalQuest;sac crystalQuest"
end)
rune.alias.exact("cl", "look crystalQuest")
rune.alias.exact("tc", "take crystal")

rune.alias.exact("CrystalLocator:help", showHelp)
rune.alias.exact("cs", "crystalLocator last")

say("v" .. VERSION .. " loaded (crystalLocator or crystal for help)")