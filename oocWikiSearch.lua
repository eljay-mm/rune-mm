-- Filename: eljayPlugins/oocWikiSearch.lua
-- Purpose: Search and open pages on the OOC wiki (Order of Chaos).
-- Version: 2.9
-- Date: 2026-Oct-25
--
--[[ Todo:
- insert planning notes here between revisions.
--]]
--
-- Changelog:
--   2.9  A page opened automatically (single hit or exact title match) also
--        copies its URL, not only a page picked by number.
--   2.8  Fix URL clipboard copy: rune.clipboard is no longer required to be
--        a Lua table, so rune.clipboard.set is called as in annwnQuestSearch.
--   2.7  Compact code and header (under 16000 bytes); help command rows use
--        the short alias and fit 76 columns; on/off is saved by re-reading
--        rune.store before each write.
--   2.6  Faster load (lazy helpstyle and settings, three aliases), load
--        time in the help footer, NAME/SHORT command-name locals.
--   2.0-2.5  Original release, short alias, toggles, curl hardening, URL
--        copy to the clipboard.
--
-- How it works:
--   * Inspired by the MUSHclient plugin by Ferdinand.
--   * Searches the OOC wiki through its public search endpoint and parses
--     the returned links into page titles and paths.
--   * A single hit, or a title matching the term exactly, opens at once;
--     otherwise a numbered list is cached for `list` and `<number>`.
--   * Opening a page strips the HTML and prints the text, and copies the
--     URL (rune.clipboard.set, OSC 52, with wl-copy, xclip, xsel, pbcopy
--     or clip as fallbacks), whether picked by number or opened at once.
--   * Requests use curl with short timeouts; no shell-special characters
--     reach the command line (Windows 10+, Linux, macOS).
--   * Commands are typed without a / prefix; oocWikiSearch is the full
--     command and ooc the short alias. Typing either alone shows help.
--   * The on/off setting is saved with rune.store; debug always starts off.
--   * helpstyle and the settings load on first use; help shows load time.
--
-- Commands (ooc works in place of oocWikiSearch):
--   oocWikiSearch                  show help
--   oocWikiSearch <term>           search the OOC wiki
--   oocWikiSearch <number>         open a result and copy its URL
--   oocWikiSearch list             show the previous result list
--   oocWikiSearch search <term>    search for a command-word term
--   oocWikiSearch on|off           enable or disable searching
--   oocWikiSearch debug on|off     toggle debug messages (default off)

local LOAD_START = os.clock()

-- Command names: full command and short alias.
local NAME = "oocWikiSearch"
local SHORT = "ooc"

local VERSION = "2.9"
local BASE_URL = "https://ooc.dune.net"
local USER_AGENT = "Rune-oocWikiSearch/" .. VERSION
local MAX_RESULTS, MAX_PAGE, MAX_BODY = 30, 16000, 500000
local KEY = NAME .. ".settings"
local PREFIX = "[" .. NAME .. "] "
local WINDOWS = package.config:sub(1, 1) == "\\"

local ENABLED, DEBUG = true, false  -- debug is never saved
local last_term, last_results = nil, {}
local load_ms, settings_loaded, helpstyle

if not (rune and rune.alias and rune.alias.regex) then
  error(NAME .. ".lua: Rune alias API is unavailable")
end

local function emit(text)
  text = tostring(text or "")
  if not pcall(rune.echo, text) then print(text) end
end

-- Cyan "[name] " prefix via rune.style, with a plain ANSI fallback.
local function say(message)
  local style = rune.style
  local ok, text = pcall(function()
    if type(style) == "table" then return style.cyan(PREFIX) end
    return style("cyan", PREFIX)
  end)
  if not (ok and type(text) == "string") then
    text = "\27[36m" .. PREFIX .. "\27[0m"
  end
  emit(text .. tostring(message))
end

local function dbg(message)
  if DEBUG then say(message) end
end

local function onoff(flag)
  return flag and "on" or "off"
end

-- Settings: only on/off is saved. Reads happen on first use; every write
-- re-reads the stored table, changes it, saves it and refreshes ENABLED.
local function ensure_settings()
  if settings_loaded then return end
  settings_loaded = true
  pcall(function()
    local saved = rune.store.get(KEY)
    if type(saved) == "table" and type(saved.enabled) == "boolean" then
      ENABLED = saved.enabled
    end
  end)
end

local function save_settings()
  pcall(function()
    local saved = rune.store.get(KEY)
    if type(saved) ~= "table" then saved = {} end
    saved.enabled = ENABLED
    rune.store.set(KEY, saved)
    local fresh = rune.store.get(KEY)
    if type(fresh) == "table" and type(fresh.enabled) == "boolean" then
      ENABLED = fresh.enabled
    end
  end)
end

local function usage()
  ensure_settings()
  if helpstyle == nil then
    local ok, module = pcall(require, "helpstyle")
    helpstyle = ok and type(module) == "table" and module or false
  end

  local H = helpstyle
  local rows = {
    { NAME .. " <term>", "search the OOC wiki" },
    { SHORT .. " <number>", "open a result, copy its URL" },
    { SHORT .. " list", "show the last results" },
    { SHORT .. " search <term>", "search a command-word term" },
    { SHORT .. " on|off", "enable or disable searching" },
    { SHORT .. " debug on|off", "toggle debug (default off)" },
    { SHORT, "short alias for " .. NAME },
  }
  local status = string.format(
    "v%s  enabled=%s debug=%s results=%d load=%s", VERSION,
    tostring(ENABLED), tostring(DEBUG), #last_results,
    load_ms and string.format("%dms", math.floor(load_ms + 0.5)) or "n/a"
  )

  local styled = H and pcall(function()
    emit(H.title(NAME .. "  (alias: " .. SHORT .. ")"))
    emit(H.section("Commands"))
    for _, row in ipairs(rows) do emit(H.line(row[1], row[2])) end
    emit(H.foot(status))
  end)
  if styled then return end

  -- Plain fallback when helpstyle is missing or its API differs.
  emit("oocWikiSearch")
  for _, row in ipairs(rows) do
    emit(string.format("  %-22s %s", row[1], row[2]))
  end
  emit(status)
end

local function trim(value)
  return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local ENTITIES = { nbsp = " ", lt = "<", gt = ">", quot = '"', apos = "'" }

local function chr(code)
  if code < 128 then return string.char(code) end
  return utf8 and code <= 0x10FFFF and utf8.char(code) or "?"
end

-- &amp; is decoded last so "&amp;lt;" stays "&lt;".
local function unescape(text)
  text = text:gsub("&(%a+);", function(name) return ENTITIES[name] end)
  text = text:gsub("&#(%d+);", function(n) return chr(tonumber(n)) end)
  text = text:gsub("&#[xX](%x+);", function(n) return chr(tonumber(n, 16)) end)
  return (text:gsub("&amp;", "&"))
end

local function ci(word)
  return (word:gsub("%a", function(c) return "[" .. c:upper() .. c:lower() .. "]" end))
end

local STRIP = {
  "<" .. ci("script") .. ".-</" .. ci("script") .. ">",
  "<" .. ci("style") .. ".-</" .. ci("style") .. ">",
  "<!%-%-.-%-%->",
}

local function html_to_text(value)
  value = tostring(value or "")
  for _, pattern in ipairs(STRIP) do value = value:gsub(pattern, "") end

  value = value:gsub("</?[HhPp][^>]*>", "\n\n")
  value = value:gsub("<[Bb][Rr][^>]*>", "\n")
  value = value:gsub("<[Ll][Ii][^>]*>", "* ")
  value = value:gsub("</[Ll][Ii]>", "\n")
  value = value:gsub("</?[Tt][Rr][^>]*>", "\n")
  value = value:gsub("<[Tt][Dd][^>]*>", "  ")
  value = unescape((value:gsub("<[^>]+>", "")))

  value = value:gsub("\r\n?", "\n")
  value = value:gsub("[ \t]+\n", "\n"):gsub("\n[ \t]+", "\n")
  value = value:gsub("\n%s*\n%s*\n+", "\n\n")
  return trim(value)
end

local function shell_quote(value)
  value = tostring(value or ""):gsub("%c", " ")
  if WINDOWS then
    -- cmd.exe: drop characters that cannot be quoted safely.
    value = value:gsub('[%%%^&|<>"]', ""):gsub("\\+$", "")
    return '"' .. value .. '"'
  end
  return "'" .. (value:gsub("'", "'\\''")) .. "'"
end

-- GET, or POST when fields are given. Timeouts (seconds) stay under Rune's
-- script time limit.
local function http(url, fields)
  local command = {
    "curl --fail --silent --show-error --location --connect-timeout 3"
      .. " --max-time 4 --user-agent " .. shell_quote(USER_AGENT),
  }
  for key, value in pairs(fields or {}) do
    command[#command + 1] = "--data-urlencode " .. shell_quote(key .. "=" .. value)
  end
  command[#command + 1] = shell_quote(url)
  command[#command + 1] = "2>&1"
  command = table.concat(command, " ")
  dbg("running: " .. command)

  local pipe, err = io.popen(command, "r")
  if not pipe then return nil, err or "unable to run curl" end

  local output = pipe:read("*a") or ""
  if not pipe:close() then
    return nil, "curl failed: " .. trim(output):sub(1, 200)
  end

  dbg("received " .. #output .. " bytes")
  return output:sub(1, MAX_BODY)
end

local SKIP = { "^#", "^mailto:", "^javascript:", "^action=", "^RecentChanges", "^Special:" }
local IGNORED = { edit = true, history = true, delete = true }

local function normalize_path(href)
  href = href:gsub("&amp;", "&"):gsub("^https?://ooc%.dune%.net", ""):gsub("^/", "")
  if href == "" then return nil end
  for _, pattern in ipairs(SKIP) do
    if href:match(pattern) then return nil end
  end
  return href
end

local function parse_results(body)
  local results, seen = {}, {}

  for href, title in body:gmatch(
    '<[Aa][^>]-[Hh][Rr][Ee][Ff]=["\']([^"\']-)["\'][^>]*>(.-)</[Aa]>'
  ) do
    local path, text = normalize_path(href), html_to_text(title)
    if path and text ~= "" and not seen[path] and not IGNORED[text:lower()] then
      seen[path] = true
      results[#results + 1] = { path = path, title = text }
      if #results >= MAX_RESULTS then break end
    end
  end

  dbg("parsed " .. #results .. " result(s)")
  return results
end

-- rune.clipboard first (as annwnQuestSearch does), then external tools.
local function copy_to_clipboard(text)
  for _, name in ipairs({ "set", "copy" }) do
    local ok, done = pcall(function()
      local fn = rune.clipboard[name]
      if type(fn) ~= "function" then return false end
      fn(text)
      return true
    end)
    if ok and done then
      dbg("clipboard via rune.clipboard." .. name)
      return true
    end
  end

  local tools = WINDOWS and { "clip" }
    or { "wl-copy", "xclip -selection clipboard", "xsel --clipboard --input", "pbcopy" }
  local quiet = WINDOWS and " 2>nul" or " >/dev/null 2>&1"

  for _, tool in ipairs(tools) do
    local ok, done = pcall(function()
      local pipe = io.popen(tool .. quiet, "w")
      if not pipe then return false end
      pipe:write(text)
      local closed = pipe:close()
      return closed == true or closed == 0
    end)
    if ok and done then
      dbg("clipboard via " .. tool)
      return true
    end
  end

  return false
end

local function show_list()
  if #last_results == 0 then
    say("No previous search. Try: " .. SHORT .. " <term>")
    return
  end

  emit("")
  say("Results for: " .. tostring(last_term))
  for index, result in ipairs(last_results) do
    emit(string.format("  %2d. %s", index, result.title))
  end
  emit("")
  say("Open a result with: " .. SHORT .. " <number>")
end

local function show_page(index, others, copy)
  local result = last_results[index]
  if not result then
    say(string.format("Choose a result from 1 to %d.", #last_results))
    return
  end

  local url = BASE_URL .. "/" .. result.path
  dbg("url: " .. url)

  if copy then
    say(copy_to_clipboard(url) and "URL copied to clipboard: " .. url
      or "Could not copy (install wl-clipboard or xclip). URL: " .. url)
  end

  say("Loading: " .. result.title)
  local body, err = http(url)
  if not body then
    say("Could not fetch page: " .. tostring(err))
    return
  end

  local text = html_to_text(body)
  if text == "" then
    say("Page is empty or unreadable: " .. result.title)
    return
  end
  if #text > MAX_PAGE then
    text = text:sub(1, MAX_PAGE) .. "\n\n[Page truncated]"
  end

  emit("")
  emit("===== " .. result.title .. " =====")
  emit(text)
  emit("===== End of " .. result.title .. " =====")

  if others and others > 0 then
    say(others .. " other result(s) matched. Use: " .. SHORT .. " list")
  end
end

local function search_wiki(term)
  term = trim((tostring(term or ""):gsub("%c", " ")))
  if term == "" then
    usage()
    return
  end

  say("Searching for: " .. term)
  local body, err = http(BASE_URL .. "/", { search = term, dosearch = "1" })
  if not body then
    say("Search failed: " .. tostring(err))
    return
  end

  last_term, last_results = term, parse_results(body)
  local count = #last_results
  if count == 0 then
    say("No pages found for: " .. term)
    return
  end

  local wanted = term:lower()
  for index, result in ipairs(last_results) do
    if result.title:lower() == wanted then
      show_page(index, count - 1, true)
      return
    end
  end

  if count == 1 then show_page(1, 0, true) else show_list() end
end

local function dispatch(argument)
  ensure_settings()
  argument = trim(argument)
  local low = argument:lower()

  if low == "" or low == "help" then
    usage()
  elseif low == "on" or low == "off" then
    ENABLED = low == "on"
    save_settings()
    say("Searching " .. onoff(ENABLED))
  elseif low == "debug" or low:match("^debug%s+%a+$") then
    local setting = low:match("^debug%s+(%a+)$")
    if setting == "on" or setting == "off" then DEBUG = setting == "on" end
    say("debug is " .. onoff(DEBUG))
  elseif low == "list" then
    show_list()
  elseif not ENABLED then
    say("Searching is off. Use: " .. SHORT .. " on")
  elseif low:match("^search%s+%S") then
    search_wiki(argument:match("^%a+%s+(.+)$"))
  elseif low:match("^%d+$") then
    local index = tonumber(low)
    if #last_results == 0 then
      say("No previous search. Try: " .. SHORT .. " <term>")
    elseif not last_results[index] then
      say(string.format("Choose a result from 1 to %d, or use: %s list", #last_results, SHORT))
    else
      show_page(index, 0, true)
    end
  else
    search_wiki(argument)
  end
end

-- Bare commands are exact aliases taking (args, ctx); one regex alias covers
-- both names when a term or subcommand follows.
local function bare_command(args)
  if type(args) == "string" and trim(args) ~= "" then dispatch(args) else usage() end
end

local function term_command(matches)
  local argument = matches
  if type(matches) == "table" then argument = matches[1] end
  dispatch(argument)
end

local function register(kind, ...)
  local ok, err = pcall(rune.alias[kind], ...)
  if not ok then say("Alias failed: " .. tostring(err)) end
end

for _, command in ipairs({ NAME, SHORT }) do
  register("exact", command, bare_command, { name = command, group = NAME, priority = 10 })
end

register(
  "regex", "^(?:" .. NAME .. "|" .. SHORT .. ")\\s+(.+)$", term_command,
  { name = NAME .. "_args", group = NAME, priority = 10 }
)

load_ms = (os.clock() - LOAD_START) * 1000

say(string.format("v%s loaded (%s or %s for help)", VERSION, NAME, SHORT))