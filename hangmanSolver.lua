-- Filename: eljayPlugins/hangmanSolver.lua
-- Purpose: Hangman Solver - solves hangman puzzles using online solver
-- Version: 2.3
-- Date: 2026-Oct-13
-- Changelog:
--   2.3  Performance (result cache, failure back-off, no repeat lookups) and
--        Windows support (curl.exe, cmd.exe quoting, NUL redirect, temp dir).
--   2.2  Added on/off toggle, debug toggle (default off), bare-command help.
--   2.1  Short curl timeouts, no wget fallback or temp files, sanitized input.
--   2.0  Baseline conversion (inspired by the MUSHclient plugin by Oona).
--
-- How it works:
--   * Inspired by the MUSHclient plugin by Oona
--   * When MM says "You hold a game of hangman ...", the plugin sends
--     "hangman start" and "hangman e" (the best opening letter).
--   * "Progress thus far: <pattern>" lines are remembered as the current pattern.
--   * "Failed letters: <letters>" lines trigger a lookup: the pattern and the
--     wrong guesses are sent to hangman-solver.com using curl, and the words
--     it returns are echoed as possible guesses.
--   * A few well-known "emp" patterns (e____, em___, emp__, empt_) are solved
--     locally without any lookup (the answer is "empty").
--   * Lookups are cached per game (same pattern + guesses = no second request),
--     use short curl timeouts, and after a failed lookup the solver pauses for
--     20 seconds so a dead network never stalls Rune's Lua thread repeatedly.
--   * Works on Linux/macOS (curl, sh) and Windows (curl.exe, cmd.exe); the
--     pattern/guesses are sanitized to letters and underscores before they
--     reach the shell.
--   * Commands: type "hangmanSolver" alone for help; "hangmanSolver on|off"
--     enables/disables the triggers; "hangmanSolver debug on|off" toggles
--     debug output (default off).

local H = require("helpstyle")

-- Settings (reset to these defaults each time the plugin loads)
local enabled = true
local DEBUG = false

-- Constants
local IS_WINDOWS = package.config:sub(1, 1) == "\\"
local BASE_URL = "https://www.hangman-solver.com/.netlify/functions/answers?word="
local BACKOFF_SECONDS = 20

-- State variables
local hangman_word = ""
local possible_guesses = {}
local cache = {}        -- "pattern|guesses" -> list of words (cleared per game)
local last_key = nil    -- last lookup key, to skip repeat lookups
local fail_until = 0    -- os.time() before which lookups are paused

local function debug(msg)
  if DEBUG then rune.echo("Debug: " .. msg) end
end

local function onoff(flag) return flag and "on" or "off" end

--[[ Extract Words from JSON Response ]]--
local function extractWords(json_string)
  local words = {}
  -- Match "word":"value" patterns
  for word in json_string:gmatch('"word"%s*:%s*"([^"]*)"') do
    words[#words + 1] = word
  end
  return words
end

--[[ Build the platform-specific curl command (URL is already sanitized) ]]--
local function curlCommand(url)
  if IS_WINDOWS then
    return 'curl.exe -s -L --connect-timeout 2 --max-time 3 "' .. url .. '" 2>NUL'
  end
  return "curl -s -L --connect-timeout 2 --max-time 3 '" .. url .. "' 2>/dev/null"
end

--[[ Run a command and return its output (io.popen, else temp-file fallback) ]]--
local function runCommand(cmd)
  if io.popen then
    local ok, pipe = pcall(io.popen, cmd, "r")
    if ok and pipe then
      local out = pipe:read("*a") or ""
      pipe:close()
      return out
    end
  end
  -- Fallback for Lua builds without io.popen
  local tmpdir = os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
  local sep = IS_WINDOWS and "\\" or "/"
  local tmp = tmpdir .. sep .. "hangman_" .. os.time() .. ".txt"
  local quote = IS_WINDOWS and '"' or "'"
  os.execute(cmd .. " > " .. quote .. tmp .. quote)
  local f = io.open(tmp, "r")
  if not f then return "" end
  local out = f:read("*a") or ""
  f:close()
  os.remove(tmp)
  return out
end

--[[ Solve Hangman - cached, short-timeout curl lookup ]]--
local function solveHangman(wrong_guesses)
  if hangman_word == nil or hangman_word == "" then
    rune.echo("Unknown starting length?")
    return
  elseif #possible_guesses == 1 then
    rune.echo("Possible guesses: " .. table.concat(possible_guesses, ", "))
    return
  elseif string.find(hangman_word, "_", 1, true) == nil then
    -- We're done, good job
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

  -- Sanitize everything that ends up in the shell command
  local word = hangman_word:gsub("[^%a_]", "")
  local guesses = (wrong_guesses or ""):gsub("[^%a]", "")
  local key = word .. "|" .. guesses

  -- Same state as the last lookup: nothing new to ask
  if key == last_key then
    debug("Skipping repeat lookup for " .. key)
    return
  end

  -- Cached from earlier in this game
  local cached = cache[key]
  if cached then
    debug("Cache hit for " .. key)
    possible_guesses = cached
    last_key = key
    rune.echo("Possible guesses: " .. table.concat(possible_guesses, ", "))
    return
  end

  -- Pause after a recent failure instead of blocking again
  local now = os.time()
  if now < fail_until then
    debug("Solver paused for " .. (fail_until - now) .. "s after a failure")
    return
  end

  local url = BASE_URL .. word .. "&guesses=" .. guesses
  debug("Fetching " .. url)

  local response = runCommand(curlCommand(url))
  if #response == 0 then
    fail_until = os.time() + BACKOFF_SECONDS
    debug("Empty response from solver")
    rune.echo("Solver unavailable - manual guessing needed (retry in " .. BACKOFF_SECONDS .. "s)")
    return
  end
  debug("Raw response (" .. #response .. " chars): " .. response:sub(1, 200))

  -- Parse JSON response
  local words = extractWords(response)
  if #words > 0 then
    possible_guesses = words
    cache[key] = words
    last_key = key
    rune.echo("Possible guesses: " .. table.concat(words, ", "))
  else
    fail_until = os.time() + BACKOFF_SECONDS
    rune.echo("Could not parse solver response - manual guessing needed")
  end
end

--[[ Start Hangman Game ]]--
local function startHangman()
  hangman_word = ""
  possible_guesses = {}
  cache = {}
  last_key = nil
  rune.send("hangman start")
  rune.send("hangman e")
end

--[[ Set Current Word Pattern ]]--
local function setWord(word)
  hangman_word = word
end

--[[ Help ]]--
local function showHelp()
  rune.echo(H.title("Hangman Solver"))
  rune.echo(H.section("Commands"))
  rune.echo(H.line("hangmanSolver on|off  -  enable or disable the solver triggers"))
  rune.echo(H.line("hangmanSolver debug on|off  -  toggle debug output"))
  rune.echo(H.foot("v2.3  solver=" .. onoff(enabled) .. " debug=" .. onoff(DEBUG)
    .. " os=" .. (IS_WINDOWS and "windows" or "unix")))
end

--[[ Commands: hangmanSolver [on|off | debug on|off] ]]--
rune.alias.regex("^hangmanSolver(?:\\s+(.*))?$", function(m)
  local arg = (m[1] or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  if arg == "on" or arg == "off" then
    enabled = (arg == "on")
    rune.echo("Hangman solver " .. onoff(enabled))
  elseif arg == "debug on" or arg == "debug off" then
    DEBUG = (arg == "debug on")
    rune.echo("Hangman solver debug " .. onoff(DEBUG))
  else
    showHelp()
  end
end)

--[[ Triggers ]]--

-- When you receive a hangman game
rune.trigger.regex("^You hold a game of hangman (.*?)$", function(m)
  if enabled then startHangman() end
end)

-- Progress pattern update
rune.trigger.regex("^Progress thus far: (.*?)$", function(m)
  if enabled then setWord(m[1] or "") end
end)

-- Failed letters - trigger solution
rune.trigger.regex("^Failed letters: (.*?)$", function(m)
  if enabled then solveHangman(m[1] or "") end
end)
