-- Filename: eljayPlugins/oocWikiSearch.lua
-- Inspired by the MUSHclient plugin by Ferdinand
-- Version 2.0
-- Date: 2026-Oct-09
--
-- Commands:
--   ooc <search term>
--   ooc <number>
--   ooc list

local BASE_URL = "https://ooc.dune.net"
local USER_AGENT = "Rune-oocWiki/1.1"
local MAX_RESULTS = 30
local MAX_PAGE_CHARS = 16000

local last_term = nil
local last_results = {}

----------------------------------------------------------------------
-- Output
----------------------------------------------------------------------

local function say(text)
  text = tostring(text or "")

  if rune and rune.echo then
    rune.echo(text)
  else
    print(text)
  end
end

local function usage()
  say("[ooc] Usage:")
  say("  ooc <search term>  Search the Order of Chaos wiki")
  say("  ooc <number>       Open a search result")
  say("  ooc list           Show the previous result list")
end

----------------------------------------------------------------------
-- String helpers
----------------------------------------------------------------------

local function trim(value)
  value = tostring(value or "")
  value = value:gsub("^%s+", "")
  value = value:gsub("%s+$", "")
  return value
end

local function html_unescape(value)
  value = tostring(value or "")

  local entities = {
    ["&nbsp;"] = " ",
    ["&amp;"] = "&",
    ["&lt;"] = "<",
    ["&gt;"] = ">",
    ["&quot;"] = '"',
    ["&#39;"] = "'",
    ["&apos;"] = "'",
  }

  value = value:gsub("&[%w#]+;", function(entity)
    return entities[entity] or entity
  end)

  value = value:gsub("&#(%d+);", function(number)
    local code = tonumber(number)

    if code and code >= 0 and code <= 255 then
      return string.char(code)
    end

    return ""
  end)

  return value
end

local function html_to_text(value)
  value = tostring(value or "")

  value = value:gsub("<script.-</script>", "")
  value = value:gsub("<SCRIPT.-</SCRIPT>", "")
  value = value:gsub("<style.-</style>", "")
  value = value:gsub("<STYLE.-</STYLE>", "")
  value = value:gsub("<!--.-%-%->", "")

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

  value = value:gsub(
    "<[Pp][Rr][Ee][^>]*>(.-)</[Pp][Rr][Ee]>",
    function(block)
      block = block:gsub("<[^>]+>", "")
      return "\n\n" .. block .. "\n\n"
    end
  )

  value = value:gsub("<[^>]+>", "")
  value = html_unescape(value)

  value = value:gsub("\r\n", "\n")
  value = value:gsub("\r", "\n")
  value = value:gsub("[ \t]+\n", "\n")
  value = value:gsub("\n[ \t]+", "\n")
  value = value:gsub("\n%s*\n%s*\n+", "\n\n")

  return trim(value)
end

----------------------------------------------------------------------
-- Shell and HTTP
----------------------------------------------------------------------

local function shell_quote(value)
  value = tostring(value or "")
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function run_command(command)
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
      message = message .. ": " .. trim(output)
    end

    return nil, message
  end

  return output
end

local function http_get(url)
  local command = table.concat({
    "curl",
    "--fail",
    "--silent",
    "--show-error",
    "--location",
    "--connect-timeout", "10",
    "--max-time", "30",
    "--user-agent", shell_quote(USER_AGENT),
    shell_quote(url),
    "2>&1",
  }, " ")

  return run_command(command)
end

local function http_post(url, fields)
  local command = {
    "curl",
    "--fail",
    "--silent",
    "--show-error",
    "--location",
    "--connect-timeout", "10",
    "--max-time", "30",
    "--user-agent", shell_quote(USER_AGENT),
  }

  for key, value in pairs(fields) do
    command[#command + 1] = "--data-urlencode"
    command[#command + 1] =
      shell_quote(tostring(key) .. "=" .. tostring(value))
  end

  command[#command + 1] = shell_quote(url)
  command[#command + 1] = "2>&1"

  return run_command(table.concat(command, " "))
end

----------------------------------------------------------------------
-- Wiki URL and result parsing
----------------------------------------------------------------------

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
      and not clean_title:match("^edit$")
      and not clean_title:match("^history$")
      and not clean_title:match("^delete$")
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

  return results
end

----------------------------------------------------------------------
-- Display
----------------------------------------------------------------------

local function show_list()
  if #last_results == 0 then
    say("[ooc] No previous search.")
    say("[ooc] Try: ooc <search term>")
    return
  end

  say("")
  say("[ooc] Results for: " .. tostring(last_term or ""))

  for index, result in ipairs(last_results) do
    say(string.format("  %2d. %s", index, result.title))
  end

  say("")
  say("[ooc] Open a result with: ooc <number>")
end

local function show_page(index, other_count)
  local result = last_results[index]

  if not result then
    say(string.format(
      "[ooc] Choose a result from 1 to %d.",
      #last_results
    ))
    return
  end

  -- Important:
  -- Use the normal wiki page URL, for example:
  --   https://ooc.dune.net/Malfat
  --
  -- Do not use /action=browse?id=... because the wiki returns
  -- "Untitled Document / Invalid Page" for those result paths.
  local url = page_url(result.path)

  say("[ooc] Loading: " .. result.title)

  local body, error_message = http_get(url)

  if not body then
    say("[ooc] Could not fetch page: " .. tostring(error_message))
    return
  end

  local text = html_to_text(body)

  if text == "" then
    say("[ooc] Page is empty or unreadable: " .. result.title)
    return
  end

  if #text > MAX_PAGE_CHARS then
    text = text:sub(1, MAX_PAGE_CHARS)
    text = text .. "\n\n[Page truncated]"
  end

  say("")
  say("===== " .. result.title .. " =====")
  say(text)
  say("===== End of " .. result.title .. " =====")

  if other_count and other_count > 0 then
    say(string.format(
      "[ooc] %d other result(s) matched. Use: ooc list",
      other_count
    ))
  end
end

----------------------------------------------------------------------
-- Search
----------------------------------------------------------------------

local function search_wiki(term)
  term = trim(term)

  if term == "" then
    usage()
    return
  end

  say("[ooc] Searching for: " .. term)

  local body, error_message = http_post(
    BASE_URL .. "/",
    {
      search = term,
      dosearch = "1",
    }
  )

  if not body then
    say("[ooc] Search failed: " .. tostring(error_message))
    return
  end

  last_term = term
  last_results = parse_results(body)

  if #last_results == 0 then
    say("[ooc] No pages found for: " .. term)
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

----------------------------------------------------------------------
-- Command handling
----------------------------------------------------------------------

local function ooc_command(matches)
  local argument = ""

  if type(matches) == "table" then
    argument = matches[1] or ""
  end

  argument = trim(argument)

  if argument == "" then
    usage()
    return
  end

  if argument:lower() == "list" then
    show_list()
    return
  end

  local number = argument:match("^(%d+)$")

  if number then
    local index = tonumber(number)

    if #last_results == 0 then
      say("[ooc] No previous search.")
      say("[ooc] Try: ooc <search term>")
      return
    end

    if not last_results[index] then
      say(string.format(
        "[ooc] Choose a result from 1 to %d, or use: ooc list",
        #last_results
      ))
      return
    end

    show_page(index, 0)
    return
  end

  search_wiki(argument)
end

----------------------------------------------------------------------
-- Rune alias
----------------------------------------------------------------------

if not rune then
  error("y_oocWiki.lua: Rune API is unavailable")
end

if not rune.alias or not rune.alias.regex then
  error("y_oocWiki.lua: rune.alias.regex is unavailable")
end

rune.alias.regex(
  "^ooc(?:\\s+(.*))?$",
  ooc_command,
  {
    name = "ooc_wiki",
    group = "ooc_wiki",
    priority = 10,
  }
)

say("[ooc] Wiki search loaded.")
say("[ooc] Try: ooc <search term>")
