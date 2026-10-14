-- Filename: eljayPlugins/oocWikiSearch.lua
-- Purpose: Search and open pages on the OOC wiki (Order of Chaos).
-- Version: 2.2
-- Date: 2026-Oct-14
-- Changelog:
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
--   * Requests use curl (included with Windows 10+, Linux and macOS) with
--     short timeouts; no shell-special characters reach the command line.
--
-- Commands (alias: ooc):
--   oocWikiSearch                    show this help
--   oocWikiSearch <search term>      search the OOC wiki
--   oocWikiSearch <number>           open a previous result by number
--   oocWikiSearch list               show the previous result list
--   oocWikiSearch search <term>      search for a term that is also a command word
--   oocWikiSearch on|off             enable or disable searching
--   oocWikiSearch debug on|off       toggle debug messages (default off)

local NAME = "oocWikiSearch"
local VERSION = "2.2"

local BASE_URL = "https://ooc.dune.net"
local USER_AGENT = "Rune-oocWikiSearch/" .. VERSION
local MAX_RESULTS = 30
local MAX_PAGE_CHARS = 16000
local MAX_BODY_CHARS = 500000
local CONNECT_TIMEOUT = 3   -- seconds; Rune aborts scripts that run too long
local MAX_TIME = 4          -- seconds

local ENABLED = true
local DEBUG = false

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
-- Output
---------------------------------------------------------------------------

local function echo(text)
  text = tostring(text or "")

  if rune.echo then
    rune.echo(text)
  else
    print(text)
  end
end

-- Cyan "[name] " prefix, then plain text (single row).
local function say(text)
  echo("\27[36m[" .. NAME .. "]\27[0m " .. tostring(text or ""))
end

-- Unprefixed output (page text, result list).
local function plain(text)
  echo(text)
end

local function dbg(text)
  if DEBUG then
    echo("\27[33m[" .. NAME .. ":debug]\27[0m " .. tostring(text or ""))
  end
end

local function onoff(flag)
  return flag and "on" or "off"
end

---------------------------------------------------------------------------
-- Help (helpstyle, as in autopouch)
---------------------------------------------------------------------------

local has_helpstyle, H = pcall(require, "helpstyle")

if not has_helpstyle or type(H) ~= "table" then
  H = nil
end

local function help_call(fn_name, ...)
  if H and type(H[fn_name]) == "function" then
    local ok, result = pcall(H[fn_name], ...)
    if ok and result ~= nil then
      return tostring(result)
    end
  end
  return nil
end

local function help_title(text)
  return help_call("title", text) or text
end

local function help_section(text)
  return help_call("section", text) or ("-- " .. text .. " --")
end

local function help_line(command, description)
  return help_call("line", command, description)
    or string.format("  %-34s %s", command, description)
end

local function help_foot(text)
  return help_call("foot", text) or text
end

local function usage()
  echo(help_title(NAME .. " - search the OOC wiki (alias: ooc)"))
  echo(help_section("Commands"))
  echo(help_line("oocWikiSearch <term>", "Search the Order of Chaos wiki"))
  echo(help_line("oocWikiSearch <number>", "Open a search result"))
  echo(help_line("oocWikiSearch list", "Show the previous result list"))
  echo(help_line("oocWikiSearch search <term>", "Search for a term that is also a command"))
  echo(help_line("oocWikiSearch on|off", "Enable or disable searching"))
  echo(help_line("oocWikiSearch debug on|off", "Toggle debug messages"))
  echo(help_foot(string.format(
    "v%s  state=%s debug=%s results=%d",
    VERSION, onoff(ENABLED), onoff(DEBUG), #last_results
  )))
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

local function show_page(index, other_count)
  local result = last_results[index]

  if not result then
    say(string.format("Choose a result from 1 to %d.", #last_results))
    return
  end

  -- Use the normal wiki page URL; browse?id results may be invalid.
  local url = page_url(result.path)

  say("Loading: " .. result.title)
  dbg("url: " .. url)

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

  say("Searching is off. Use: oocWikiSearch on")
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

  show_page(index, 0)
end

local function wiki_command(matches)
  local argument = ""

  if type(matches) == "table" then
    argument = matches[1] or ""
  end

  argument = trim(argument)

  if argument == "" or argument:lower() == "help" then
    usage()
    return
  end

  local lowered = argument:lower()

  if lowered == "on" or lowered == "off" then
    ENABLED = (lowered == "on")
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
-- Rune alias (no / prefix; ooc is the short alias)
---------------------------------------------------------------------------

rune.alias.regex(
  "^(?:oocWikiSearch|ooc)(?:\\s+(.*))?$",
  wiki_command,
  {
    name = "oocWikiSearch",
    group = "oocWikiSearch",
    priority = 10,
  }
)

say(string.format("v%s loaded (oocWikiSearch or ooc for help)", VERSION))