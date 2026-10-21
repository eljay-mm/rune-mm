-- Filename: eljayPlugins/oocWikiSearch.lua
-- Purpose: Search and open pages on the OOC wiki (Order of Chaos).
-- Version: 2.6
-- Date: 2026-Oct-20
--
--[[ Todo:
- insert planning notes here between revisions.
--]]
--
-- Changelog:
--   2.6  Faster load: helpstyle and saved settings load on first use, and
--        registration is cut to three aliases (two exact bare commands plus
--        one regex alias for both names); load time is shown in the help
--        footer; NAME/SHORT command-name locals and a short-alias help row.
--   2.5  Clipboard copy now uses rune.clipboard.set first, as annwnQuestSearch
--        does (external tools stay as a fallback); paint/say, help and saved
--        settings follow annwnQuestSearch v2.7 (only on/off is saved, debug
--        always starts off).
--   2.4  Selecting a result with `ooc <number>` copies the page URL to the
--        clipboard (rune.clipboard if present, else wl-copy, xclip, xsel,
--        pbcopy or clip) and prints the URL; automatic opens do not copy.
--   2.3  Display method aligned with annwnQuestSearch (paint/say/emit via
--        rune.echo, cyan prefix via rune.style.cyan); bare oocWikiSearch and
--        ooc are exact aliases so help always shows, term commands use a
--        separate regex alias; on/off and debug persisted in rune.store;
--        alias registration is guarded and reports failures.
--   2.2  Main command is now oocWikiSearch with ooc as the short alias;
--        bare command shows help (helpstyle) with version footer;
--        on/off and debug toggles added (debug defaults to off);
--        single-row loader line; Windows-compatible curl quoting;
--        shorter curl timeouts so the client never stalls;
--        HTML entity decoding fixed (&amp; last, numeric entities first).
--   2.1  Repo-style header update and command summary standardized.
--   2.0  Original release.
--
-- How it works:
--   * Inspired by the MUSHclient plugin by Ferdinand.
--   * The plugin searches the OOC wiki via the public search endpoint.
--   * The returned hyperlinks are parsed into page titles and paths.
--   * Selecting a result opens the canonical wiki page URL, strips the HTML
--     and prints the cleaned text.
--   * The last result set is cached so `list` and `<number>` work without
--     re-searching.
--   * A single result, or a result whose title exactly matches the search
--     term, is opened automatically.
--   * Opening a result by number also copies its URL to the system clipboard
--     using rune.clipboard.set (OSC 52), falling back to wl-copy, xclip, xsel,
--     pbcopy or clip if that is unavailable.
--   * The on/off setting is saved with rune.store; the debug toggle always
--     starts off.
--   * Loading is kept light: helpstyle and the saved on/off setting are read
--     the first time they are needed, and the help footer shows the load time.
--   * Commands are typed without a / prefix. oocWikiSearch is the full
--     command and ooc is the short alias; typing either alone shows help.
--   * Requests use curl (included with Windows 10+, Linux and macOS) with
--     short timeouts; no shell-special characters reach the command line.
--
-- Commands (alias: ooc):
--   oocWikiSearch                    show this help
--   oocWikiSearch <search term>      search the OOC wiki
--   oocWikiSearch <number>           open a previous result by number and
--                                    copy its URL to the clipboard
--   oocWikiSearch list               show the previous result list
--   oocWikiSearch search <term>      search for a term that is also a command word
--   oocWikiSearch on|off             enable or disable searching
--   oocWikiSearch debug on|off       toggle debug messages (default off)

local LOAD_START = os.clock()
local load_ms = nil

-- Command names: full command and short alias.
local NAME = "oocWikiSearch"
local SHORT = "ooc"

local VERSION = "2.6"

local BASE_URL = "https://ooc.dune.net"
local USER_AGENT = "Rune-oocWikiSearch/" .. VERSION
local MAX_RESULTS = 30
local MAX_PAGE_CHARS = 16000
local MAX_BODY_CHARS = 500000
local CONNECT_TIMEOUT = 3   -- seconds; Rune aborts scripts that run too long
local MAX_TIME = 4          -- seconds

local ENABLED = true
local DEBUG = false  -- never saved: always starts off

local IS_WINDOWS = package.config:sub(1, 1) == "\\"

local last_term = nil
local last_results = {}

if not rune then
  error(NAME .. ".lua: Rune API is unavailable")
end

if not rune.alias or not rune.alias.regex then
  error(NAME .. ".lua: rune.alias.regex is unavailable")
end

---------------------------------------------------------------------------
-- Output and settings (same method as annwnQuestSearch)
---------------------------------------------------------------------------

local PREFIX = "[" .. NAME .. "] "
local SETTINGS_KEY = NAME .. ".settings"
local ANSI_CYAN = "\27[36m"
local ANSI_RESET = "\27[0m"

-- Optional shared help styling (same module autopouch.lua uses), loaded on
-- the first help request so it does not slow the plugin load.
local helpstyle_module = nil
local helpstyle_tried = false

local function get_helpstyle()
  if not helpstyle_tried then
    helpstyle_tried = true

    local ok, module = pcall(require, "helpstyle")

    if ok and type(module) == "table" then
      helpstyle_module = module
    end
  end

  return helpstyle_module
end

local function emit(text)
  text = tostring(text or "")

  if not pcall(rune.echo, text) then
    print(text)
  end
end

-- Cyan "[name] " prefix: rune.style.cyan, then rune.style("cyan", ...), then a
-- plain ANSI escape, so the colour shows whichever style API Rune provides.
local function paint(message)
  local prefix
  local style = rune and rune.style

  if type(style) == "table" and type(style.cyan) == "function" then
    local ok, text = pcall(style.cyan, PREFIX)
    if ok and type(text) == "string" then prefix = text end
  elseif type(style) == "function" then
    local ok, text = pcall(style, "cyan", PREFIX)
    if ok and type(text) == "string" then prefix = text end
  end

  prefix = prefix or (ANSI_CYAN .. PREFIX .. ANSI_RESET)

  return prefix .. tostring(message)
end

-- Single row with the coloured "[name]" prefix.
local function say(message)
  if not pcall(rune.echo, paint(message)) then
    print(PREFIX .. tostring(message))
  end
end

-- Unprefixed output (page text, result list).
local function plain(text)
  emit(text)
end

local function dbg(message)
  if DEBUG then
    say(message)
  end
end

local function onoff(flag)
  return flag and "on" or "off"
end

-- Only the on/off setting is persisted.
local function load_settings()
  if not (rune and rune.store and type(rune.store.get) == "function") then
    return
  end

  local ok, saved = pcall(rune.store.get, SETTINGS_KEY)

  if ok and type(saved) == "table" and type(saved.enabled) == "boolean" then
    ENABLED = saved.enabled
  end
end

local function save_settings()
  if not (rune and rune.store and type(rune.store.set) == "function") then
    return
  end

  pcall(rune.store.set, SETTINGS_KEY, { enabled = ENABLED })
end

-- Settings are read on first use, not at load.
local settings_loaded = false

local function ensure_settings()
  if not settings_loaded then
    settings_loaded = true
    load_settings()
  end
end

local function load_text()
  if load_ms then
    return string.format("%dms", math.floor(load_ms + 0.5))
  end

  return "n/a"
end

---------------------------------------------------------------------------
-- Help (helpstyle rows passed to emit)
---------------------------------------------------------------------------

local function usage()
  ensure_settings()

  -- One status row, starting with the version, as the footer.
  local status = string.format(
    "v%s  enabled=%s debug=%s results=%d load=%s",
    VERSION, onoff(ENABLED), onoff(DEBUG), #last_results, load_text()
  )

  local H = get_helpstyle()

  local styled = H and pcall(function()
    emit(H.title("OOC wiki search"))
    emit(H.section("Commands"))
    emit(H.line(NAME .. " <term>", "search the Order of Chaos wiki"))
    emit(H.line(NAME .. " <number>", "open a result and copy its URL"))
    emit(H.line(NAME .. " list", "show the previous result list"))
    emit(H.line(NAME .. " search <term>", "search for a term that is also a command"))
    emit(H.line(NAME .. " on|off", "enable or disable searching"))
    emit(H.line(NAME .. " debug on|off", "toggle debug messages (default off)"))
    emit(H.line(SHORT, "short alias for " .. NAME))
    emit(H.foot(status))
  end)

  if styled then
    return
  end

  -- Plain fallback when helpstyle is missing or its API differs.
  emit("OOC wiki search")
  emit("  " .. NAME .. " <term>           search the Order of Chaos wiki")
  emit("  " .. NAME .. " <number>         open a result and copy its URL")
  emit("  " .. NAME .. " list             show the previous result list")
  emit("  " .. NAME .. " search <term>    search for a term that is also a command")
  emit("  " .. NAME .. " on|off           enable or disable searching")
  emit("  " .. NAME .. " debug on|off     toggle debug messages (default off)")
  emit("  " .. SHORT .. "                short alias for " .. NAME)
  emit(status)
end

---------------------------------------------------------------------------
-- String helpers
---------------------------------------------------------------------------

local function trim(value)
  value = tostring(value or "")
  value = value:gsub("^%s+", "")
  value = value:gsub("%s+$", "")
  return value
end

local NAMED_ENTITIES = {
  ["&nbsp;"] = " ",
  ["&lt;"] = "<",
  ["&gt;"] = ">",
  ["&quot;"] = '"',
  ["&apos;"] = "'",
  ["&#39;"] = "'",
}

local function code_to_text(code)
  if not code or code < 0 then
    return ""
  end

  if code < 128 then
    return string.char(code)
  end

  if utf8 and utf8.char and code <= 0x10FFFF then
    local ok, char = pcall(utf8.char, code)
    if ok then
      return char
    end
  end

  if code <= 255 then
    return string.char(code)
  end

  return ""
end

local function html_unescape(value)
  value = tostring(value or "")

  -- Named entities (except &amp;, which must be decoded last).
  value = value:gsub("&[%a]+;", function(entity)
    return NAMED_ENTITIES[entity] or entity
  end)

  value = value:gsub("&#(%d+);", function(number)
    return code_to_text(tonumber(number))
  end)

  value = value:gsub("&#[xX](%x+);", function(number)
    return code_to_text(tonumber(number, 16))
  end)

  value = value:gsub("&amp;", "&")

  return value
end

local function html_to_text(value)
  value = tostring(value or "")

  value = value:gsub("<[Ss][Cc][Rr][Ii][Pp][Tt].-</[Ss][Cc][Rr][Ii][Pp][Tt]>", "")
  value = value:gsub("<[Ss][Tt][Yy][Ll][Ee].-</[Ss][Tt][Yy][Ll][Ee]>", "")
  value = value:gsub("<!--.-%-%->", "")

  -- <pre> blocks first, so their line breaks survive the cleanup below.
  value = value:gsub(
    "<[Pp][Rr][Ee][^>]*>(.-)</[Pp][Rr][Ee]>",
    function(block)
      block = block:gsub("<[^>]+>", "")
      return "\n\n" .. block .. "\n\n"
    end
  )

  value = value:gsub("<[Hh][1-6][^>]*>", "\n\n")
  value = value:gsub("</[Hh][1-6]>", "\n\n")
  value = value:gsub("<[Pp][^>]*>", "\n\n")
  value = value:gsub("</[Pp]>", "\n\n")
  value = value:gsub("<[Bb][Rr]%s*/?>", "\n")
  value = value:gsub("<[Ll][Ii][^>]*>", "* ")
  value = value:gsub("</[Ll][Ii]>", "\n")
  value = value:gsub("<[Tt][Rr][^>]*>", "\n")
  value = value:gsub("</[Tt][Rr]>", "\n")
  value = value:gsub("<[Tt][Dd][^>]*>", "  ")

  value = value:gsub("<[^>]+>", "")
  value = html_unescape(value)

  value = value:gsub("\r\n", "\n")
  value = value:gsub("\r", "\n")
  value = value:gsub("[ \t]+\n", "\n")
  value = value:gsub("\n[ \t]+", "\n")
  value = value:gsub("\n%s*\n%s*\n+", "\n\n")

  return trim(value)
end

---------------------------------------------------------------------------
-- Shell and HTTP (cross-platform)
---------------------------------------------------------------------------

local function shell_quote(value)
  value = tostring(value or "")
  value = value:gsub("%c", " ")

  if IS_WINDOWS then
    -- cmd.exe: drop characters that cannot be quoted safely.
    value = value:gsub('[%%%^&|<>"]', "")
    value = value:gsub("\\+$", "")
    return '"' .. value .. '"'
  end

  -- POSIX shells: single quotes, embedded quotes escaped.
  return "'" .. (value:gsub("'", "'\\''")) .. "'"
end

local function run_command(command)
  dbg("running: " .. command)

  local pipe, error_message = io.popen(command, "r")

  if not pipe then
    return nil, error_message or "unable to execute curl"
  end

  local output = pipe:read("*a")
  local success, reason, code = pipe:close()

  if not success then
    local message = "curl request failed"

    if reason then
      message = message .. " (" .. tostring(reason) .. ")"
    end

    if code then
      message = message .. ", exit code " .. tostring(code)
    end

    if output and output ~= "" then
      message = message .. ": " .. trim(output):sub(1, 200)
    end

    return nil, message
  end

  if #output > MAX_BODY_CHARS then
    output = output:sub(1, MAX_BODY_CHARS)
  end

  dbg("received " .. #output .. " bytes")

  return output
end

local function curl_base()
  return {
    "curl",
    "--fail",
    "--silent",
    "--show-error",
    "--location",
    "--connect-timeout", tostring(CONNECT_TIMEOUT),
    "--max-time", tostring(MAX_TIME),
    "--user-agent", shell_quote(USER_AGENT),
  }
end

local function http_get(url)
  local command = curl_base()

  command[#command + 1] = shell_quote(url)
  command[#command + 1] = "2>&1"

  return run_command(table.concat(command, " "))
end

local function http_post(url, fields)
  local command = curl_base()

  for key, value in pairs(fields) do
    command[#command + 1] = "--data-urlencode"
    command[#command + 1] =
      shell_quote(tostring(key) .. "=" .. tostring(value))
  end

  command[#command + 1] = shell_quote(url)
  command[#command + 1] = "2>&1"

  return run_command(table.concat(command, " "))
end

---------------------------------------------------------------------------
-- Wiki URL and result parsing
---------------------------------------------------------------------------

local function normalize_path(href)
  if not href then
    return nil
  end

  href = href:gsub("&amp;", "&")
  href = href:gsub("^https?://ooc%.dune%.net", "")
  href = href:gsub("^/", "")

  -- Ignore non-page links.
  if href == ""
    or href:match("^#")
    or href:match("^mailto:")
    or href:match("^javascript:")
    or href:match("^action=")
    or href:match("^RecentChanges")
    or href:match("^Special:")
  then
    return nil
  end

  -- If the result is an old-style browse link, extract its page value.
  local browse_id = href:match("^action=browse[?&]id=([^&]+)")
  if browse_id then
    href = browse_id
  end

  return href
end

local function page_url(path)
  path = tostring(path or "")
  path = path:gsub("^https?://ooc%.dune%.net", "")
  path = path:gsub("^/", "")

  return BASE_URL .. "/" .. path
end

local IGNORED_TITLES = { edit = true, history = true, delete = true }

local function parse_results(body)
  local results = {}
  local seen = {}

  for href, title in body:gmatch(
    '<[Aa][^>]-[Hh][Rr][Ee][Ff]=["\']([^"\']-)["\'][^>]*>(.-)</[Aa]>'
  ) do
    local clean_path = normalize_path(href)
    local clean_title = html_to_text(title)

    if clean_path
      and clean_title ~= ""
      and not seen[clean_path]
      and not IGNORED_TITLES[clean_title:lower()]
    then
      seen[clean_path] = true

      results[#results + 1] = {
        path = clean_path,
        title = clean_title,
      }

      if #results >= MAX_RESULTS then
        break
      end
    end
  end

  dbg("parsed " .. #results .. " result(s)")

  return results
end

---------------------------------------------------------------------------
-- Clipboard
---------------------------------------------------------------------------

local clipboard_commands = nil

local function build_clipboard_commands()
  if IS_WINDOWS then
    return { "clip 2>nul" }
  end

  local quiet = " >/dev/null 2>&1"
  local wayland = os.getenv and os.getenv("WAYLAND_DISPLAY")
  local list = {}

  if wayland and wayland ~= "" then
    list[#list + 1] = "wl-copy" .. quiet
  end

  list[#list + 1] = "xclip -selection clipboard" .. quiet
  list[#list + 1] = "xsel --clipboard --input" .. quiet

  if not (wayland and wayland ~= "") then
    list[#list + 1] = "wl-copy" .. quiet
  end

  list[#list + 1] = "pbcopy" .. quiet

  return list
end

local function pipe_to_command(command, text)
  local ok, result = pcall(function()
    local pipe = io.popen(command, "w")

    if not pipe then
      return false
    end

    pipe:write(text)

    local closed = pipe:close()

    return closed == true or closed == 0
  end)

  return ok and result == true
end

-- Returns true and the method used, or false.
local function copy_to_clipboard(text)
  text = tostring(text or "")

  -- Rune clipboard first (rune.clipboard.set, as annwnQuestSearch does).
  if type(rune.clipboard) == "table" then
    for _, fn_name in ipairs({ "set", "copy" }) do
      local fn = rune.clipboard[fn_name]

      if type(fn) == "function" then
        local ok, result = pcall(fn, text)

        if ok then
          dbg("clipboard via rune.clipboard." .. fn_name)
          return true, "rune.clipboard"
        end
      end
    end
  end

  -- External tools; the first that succeeds wins.
  clipboard_commands = clipboard_commands or build_clipboard_commands()

  for _, command in ipairs(clipboard_commands) do
    if pipe_to_command(command, text) then
      dbg("clipboard via: " .. command)
      return true, command
    end

    dbg("clipboard failed: " .. command)
  end

  return false
end

---------------------------------------------------------------------------
-- Display
---------------------------------------------------------------------------

local function show_list()
  if #last_results == 0 then
    say("No previous search. Try: oocWikiSearch <search term>")
    return
  end

  plain("")
  say("Results for: " .. tostring(last_term or ""))

  for index, result in ipairs(last_results) do
    plain(string.format("  %2d. %s", index, result.title))
  end

  plain("")
  say("Open a result with: oocWikiSearch <number>")
end

local function show_page(index, other_count, copy_url)
  local result = last_results[index]

  if not result then
    say(string.format("Choose a result from 1 to %d.", #last_results))
    return
  end

  -- Use the normal wiki page URL; browse?id results may be invalid.
  local url = page_url(result.path)

  dbg("url: " .. url)

  if copy_url then
    if copy_to_clipboard(url) then
      say("URL copied to clipboard: " .. url)
    else
      say("Could not copy to the clipboard (install wl-clipboard or xclip). URL: " .. url)
    end
  end

  say("Loading: " .. result.title)

  local body, error_message = http_get(url)

  if not body then
    say("Could not fetch page: " .. tostring(error_message))
    return
  end

  local text = html_to_text(body)

  if text == "" then
    say("Page is empty or unreadable: " .. result.title)
    return
  end

  if #text > MAX_PAGE_CHARS then
    text = text:sub(1, MAX_PAGE_CHARS)
    text = text .. "\n\n[Page truncated]"
  end

  plain("")
  plain("===== " .. result.title .. " =====")
  plain(text)
  plain("===== End of " .. result.title .. " =====")

  if other_count and other_count > 0 then
    say(string.format(
      "%d other result(s) matched. Use: oocWikiSearch list",
      other_count
    ))
  end
end

---------------------------------------------------------------------------
-- Search
---------------------------------------------------------------------------

local function search_wiki(term)
  term = trim((tostring(term or ""):gsub("%c", " ")))

  if term == "" then
    usage()
    return
  end

  say("Searching for: " .. term)

  local body, error_message = http_post(
    BASE_URL .. "/",
    {
      search = term,
      dosearch = "1",
    }
  )

  if not body then
    say("Search failed: " .. tostring(error_message))
    return
  end

  last_term = term
  last_results = parse_results(body)

  if #last_results == 0 then
    say("No pages found for: " .. term)
    return
  end

  local wanted = term:lower()

  for index, result in ipairs(last_results) do
    if result.title:lower() == wanted then
      show_page(index, #last_results - 1)
      return
    end
  end

  if #last_results == 1 then
    show_page(1, 0)
  else
    show_list()
  end
end

---------------------------------------------------------------------------
-- Command handling
---------------------------------------------------------------------------

local function set_toggle(label, current, setting)
  setting = setting:lower()

  if setting == "on" then
    return true
  elseif setting == "off" then
    return false
  end

  say(label .. " is " .. onoff(current) .. ". Use: " .. label .. " on|off")
  return current
end

local function require_enabled()
  if ENABLED then
    return true
  end

  say("Searching is off. Use: " .. NAME .. " on")
  return false
end

local function open_result(number)
  if #last_results == 0 then
    say("No previous search. Try: oocWikiSearch <search term>")
    return
  end

  local index = tonumber(number)

  if not index or not last_results[index] then
    say(string.format(
      "Choose a result from 1 to %d, or use: oocWikiSearch list",
      #last_results
    ))
    return
  end

  show_page(index, 0, true)
end

local function dispatch(argument)
  ensure_settings()

  argument = trim(argument)

  if argument == "" or argument:lower() == "help" then
    usage()
    return
  end

  local lowered = argument:lower()

  if lowered == "on" or lowered == "off" then
    ENABLED = (lowered == "on")
    save_settings()
    say("Searching " .. onoff(ENABLED))
    return
  end

  local debug_setting = lowered:match("^debug%s*(.*)$")

  if debug_setting then
    DEBUG = set_toggle("debug", DEBUG, trim(debug_setting))
    if trim(debug_setting) ~= "" then
      say("Debug " .. onoff(DEBUG))
    end
    return
  end

  if lowered == "list" then
    show_list()
    return
  end

  if not require_enabled() then
    return
  end

  local forced_term = argument:match("^[Ss][Ee][Aa][Rr][Cc][Hh]%s+(.+)$")

  if forced_term then
    search_wiki(forced_term)
    return
  end

  local number = argument:match("^(%d+)$")

  if number then
    open_result(number)
    return
  end

  search_wiki(argument)
end

---------------------------------------------------------------------------
-- Rune aliases (no / prefix; the short alias works in place of the full name)
---------------------------------------------------------------------------

-- Bare command: exact alias handler taking (args, ctx); always shows help.
local function bare_command(args, ctx)
  if type(args) == "string" and trim(args) ~= "" then
    dispatch(args)
    return
  end

  usage()
end

-- Command with arguments: one regex alias for both names, capture 1 is the
-- argument text.
local function term_command(matches)
  local argument = ""

  if type(matches) == "table" then
    argument = matches[1] or ""
  elseif type(matches) == "string" then
    argument = matches
  end

  dispatch(argument)
end

local function register(kind, pattern, handler, options)
  local ok, err = pcall(rune.alias[kind], pattern, handler, options)

  if not ok then
    say("Alias '" .. tostring(pattern) .. "' failed: " .. tostring(err))
  end

  return ok
end

local has_exact = type(rune.alias.exact) == "function"

for _, command in ipairs({ NAME, SHORT }) do
  local options = { name = command, group = NAME, priority = 10 }

  if has_exact then
    register("exact", command, bare_command, options)
  else
    register("regex", "^" .. command .. "\\s*$", bare_command, options)
  end
end

register(
  "regex",
  "^(?:" .. NAME .. "|" .. SHORT .. ")\\s+(.+)$",
  term_command,
  { name = NAME .. "_args", group = NAME, priority = 10 }
)

load_ms = (os.clock() - LOAD_START) * 1000

say(string.format("v%s loaded (%s or %s for help)", VERSION, NAME, SHORT))