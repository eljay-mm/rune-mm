-- Filename: eljayPlugins/hangmanSolver.lua
-- Purpose: Solves hangman puzzles using an online solver (needs curl).
-- Version: 2.7
-- Date: 2026-Oct-25
--[[
TODO:
- insert planning notes here between revisions.
]]
-- Changelog:
--   2.7  Updated command handling, persisted settings, and help to repo conventions.
--   2.6  Brought commands, help, load-time reporting, and output in line with repo conventions.
--   2.5  Brought to standard: Purpose aligned with the README, short alias hms,
--        cyan-prefixed single-row output, standard loader line.
--   2.4  Added repo-standard command summary and persisted settings; kept the original solver logic.
--   2.3  Performance (result cache, failure back-off, no repeat lookups) and Windows support.
--   2.2  Added on/off toggle, debug toggle (default off), and bare-command help.
--   2.1  Short curl timeouts, no wget fallback or temp files, sanitized input.
-- How it works:
--   * Inspired by the MUSHclient plugin by Oona.
--   * Solves hangman puzzles using an online solver (hangman-solver.com), reached with curl.
--   * When MM says "You hold a game of hangman ...", sends "hangman start"
--     and "hangman e" as the opening guess.
--   * Remembers "Progress thus far: <pattern>" lines as the current pattern.
--   * Uses "Failed letters: <letters>" lines to look up possible guesses.
--   * Solves a few well-known "emp" patterns locally without a lookup.
--   * Caches lookups and pauses briefly after a failed request.
--   * Works on Linux, macOS, and Windows with curl; shell-bound puzzle data is sanitized.
--   * Settings (on/off and debug) are saved with rune.store.
--
-- Commands (type without "/"; "hms" is a short alias for "hangmanSolver"):
--   hangmanSolver       show this help
--   hms on|off          enable / disable solver triggers
--   hms debug on|off    enable / disable debug messages
--   hms                 short alias for hangmanSolver
--
-- Tweaks:
--   * BACKOFF_SECONDS  pause after a failed solver request
--
local LOAD_STARTED = os.clock()
local LOAD_MS = 0

-- Command names: full command and short alias.
local NAME = "hangmanSolver"
local SHORT = "hms"

local VERSION = "2.7"
local SETTINGS_KEY = NAME .. ".settings"

local H = require("helpstyle")
local IS_WINDOWS = package.config:sub(1, 1) == "\\"
local BASE_URL = "https://www.hangman-solver.com/.netlify/functions/answers?word="
local BACKOFF_SECONDS = 20

local enabled = true
local debug_enabled = false

-- State variables.
local hangman_word = ""
local possible_guesses = {}
local cache = {}
local last_key = nil
local fail_until = 0

local function say(msg)
  local prefix = "[" .. NAME .. "] "
  local style = rune.style

  if style and type(style.cyan) == "function" then
    local ok, colored = pcall(style.cyan, prefix)
    if ok and colored then
      prefix = colored
    end
  end

  rune.echo(prefix .. tostring(msg))
end

local function dbg(msg)
  if debug_enabled then
    say("[debug] " .. tostring(msg))
  end
end

local function onoff(flag)
  return flag and "on" or "off"
end

local function load_settings()
  if not (rune.store and type(rune.store.get) == "function") then
    return
  end

  local ok, saved = pcall(rune.store.get, SETTINGS_KEY)
  if ok and type(saved) == "table" then
    if type(saved.enabled) == "boolean" then
      enabled = saved.enabled
    end
    if type(saved.debug) == "boolean" then
      debug_enabled = saved.debug
    end
  end
end

local function update_settings(mutate)
  if not (rune.store and type(rune.store.get) == "function"
      and type(rune.store.set) == "function") then
    return
  end

  local ok, fresh = pcall(rune.store.get, SETTINGS_KEY)
  if not ok or type(fresh) ~= "table" then
    fresh = {}
  end

  mutate(fresh)
  local saved = pcall(rune.store.set, SETTINGS_KEY, fresh)
  if saved then
    if type(fresh.enabled) == "boolean" then
      enabled = fresh.enabled
    end
    if type(fresh.debug) == "boolean" then
      debug_enabled = fresh.debug
    end
  end
end

local function set_enabled(value)
  update_settings(function(settings)
    settings.enabled = value
  end)
  -- Keep the runtime toggle responsive even if storage is unavailable.
  enabled = value
end

local function set_debug(value)
  update_settings(function(settings)
    settings.debug = value
  end)
  debug_enabled = value
end

local function extract_words(json_string)
  local words = {}
  for word in json_string:gmatch('"word"%s*:%s*"([^"]*)"') do
    words[#words + 1] = word
  end
  return words
end

local function curl_command(url)
  if IS_WINDOWS then
    return 'curl.exe -s -L --connect-timeout 2 --max-time 3 "' .. url .. '" 2>NUL'
  end

  return "curl -s -L --connect-timeout 2 --max-time 3 '" .. url .. "' 2>/dev/null"
end

local function run_command(cmd)
  if type(io.popen) ~= "function" then
    return nil
  end

  local ok, pipe = pcall(io.popen, cmd, "r")
  if not ok or not pipe then
    return nil
  end

  local read_ok, output = pcall(function()
    return pipe:read("*a")
  end)
  pcall(function()
    pipe:close()
  end)

  if not read_ok then
    return nil
  end

  return output or ""
end

local function solve_hangman(wrong_guesses)
  if hangman_word == "" then
    say("Unknown starting length?")
    return
  elseif #possible_guesses == 1 then
    say("Possible guesses: " .. table.concat(possible_guesses, ", "))
    return
  elseif not hangman_word:find("_", 1, true) then
    return
  elseif hangman_word == "e____" then
    rune.send("hangman m")
    return
  elseif hangman_word == "em___" then
    rune.send("hangman p")
    return
  elseif hangman_word == "emp__" then
    rune.send("hangman t")
    return
  elseif hangman_word == "empt_" then
    rune.send("hangman y")
    return
  end

  -- Restrict shell-bound values to expected characters.
  local word = hangman_word:gsub("[^%a_]", "")
  local guesses = (wrong_guesses or ""):gsub("[^%a]", "")
  local key = word .. "|" .. guesses

  if key == last_key then
    dbg("Skipping repeat lookup")
    return
  end

  local cached = cache[key]
  if cached then
    dbg("Cache hit")
    possible_guesses = cached
    last_key = key
    say("Possible guesses: " .. table.concat(possible_guesses, ", "))
    return
  end

  local now = os.time()
  if now < fail_until then
    dbg("Solver paused for " .. (fail_until - now) .. "s after a failure")
    return
  end

  local url = BASE_URL .. word .. "&guesses=" .. guesses
  dbg("Fetching solver results")

  local response = run_command(curl_command(url))
  if not response or #response == 0 then
    fail_until = os.time() + BACKOFF_SECONDS
    say("Solver unavailable - manual guessing needed (retry in "
      .. BACKOFF_SECONDS .. "s)")
    return
  end

  dbg("Raw response (" .. #response .. " chars): " .. response:sub(1, 200))

  local words = extract_words(response)
  if #words > 0 then
    possible_guesses = words
    cache[key] = words
    last_key = key
    say("Possible guesses: " .. table.concat(words, ", "))
  else
    fail_until = os.time() + BACKOFF_SECONDS
    say("Could not parse solver response - manual guessing needed")
  end
end

local function start_hangman()
  hangman_word = ""
  possible_guesses = {}
  cache = {}
  last_key = nil
  fail_until = 0

  rune.send("hangman start")
  rune.send("hangman e")
end

local function show_help()
  rune.echo(H.title(NAME .. "  (alias: " .. SHORT .. ")"))
  rune.echo(H.section("Commands"))
  rune.echo(H.line(NAME, "show this help"))
  rune.echo(H.line(SHORT .. " on|off", "enable / disable solver triggers"))
  rune.echo(H.line(SHORT .. " debug on|off", "enable / disable debug messages"))
  rune.echo(H.line(SHORT, "short alias for " .. NAME))
  rune.echo(H.foot(string.format(
    "v%s  enabled=%s debug=%s bindings=5  load=%dms",
    VERSION,
    tostring(enabled),
    tostring(debug_enabled),
    LOAD_MS
  )))
end

local function handle_command(args, _ctx)
  local text = (args or ""):match("^%s*(.-)%s*$"):lower()

  if text == "" then
    show_help()
  elseif text == "on" then
    set_enabled(true)
    say("Solver " .. onoff(enabled))
  elseif text == "off" then
    set_enabled(false)
    say("Solver " .. onoff(enabled))
  elseif text == "debug on" then
    set_debug(true)
    say("Debug " .. onoff(debug_enabled))
  elseif text == "debug off" then
    set_debug(false)
    say("Debug " .. onoff(debug_enabled))
  else
    show_help()
  end
end

load_settings()

rune.alias.exact(NAME, handle_command)
rune.alias.exact(SHORT, handle_command)

rune.trigger.regex("^You hold a game of hangman (.*?)$", function(_m)
  if enabled then
    start_hangman()
  end
end, { name = NAME .. "-start" })

rune.trigger.regex("^Progress thus far: (.*?)$", function(m)
  if enabled then
    hangman_word = m[1] or ""
  end
end, { name = NAME .. "-pattern" })

rune.trigger.regex("^Failed letters: (.*?)$", function(m)
  if enabled then
    solve_hangman(m[1] or "")
  end
end, { name = NAME .. "-failed" })

LOAD_MS = math.floor((os.clock() - LOAD_STARTED) * 1000 + 0.5)
say(string.format("v%s loaded (%s or %s for help)", VERSION, NAME, SHORT))
