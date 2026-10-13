-- Filename: eljayPlugins/hangmanSolver.lua
-- Purpose: Hangman solver - solves hangman puzzles using an online solver.
-- Version: 2.4
-- Date: 2026-Oct-13
-- Changelog:
--   2.4  Added repo-standard command summary and persisted settings; kept the original solver logic.
--   2.3  Performance (result cache, failure back-off, no repeat lookups) and Windows support.
--   2.2  Added on/off toggle, debug toggle (default off), and bare-command help.
--   2.1  Short curl timeouts, no wget fallback or temp files, sanitized input.
-- How it works:
--   * Inspired by the MUSHclient plugin by Oona.
--   * When MM says "You hold a game of hangman ...", the plugin sends "hangman start" and "hangman e" (the best opening letter).
--   * "Progress thus far: <pattern>" lines are remembered as the current pattern.
--   * "Failed letters: <letters>" lines trigger a lookup: the pattern and the wrong guesses are sent to hangman-solver.com using curl.
--   * The returned words are echoed as possible guesses.
--   * A few well-known "emp" patterns (e____, em___, emp__, empt_) are solved locally without any lookup.
--   * Lookups are cached per game, use short curl timeouts, and after a failed lookup the solver pauses briefly to avoid repeated dead network stalls.
--   * Works on Linux/macOS (curl, sh) and Windows (curl.exe, cmd.exe); the pattern/guesses are sanitized to letters and underscores before they reach the shell.
--
-- Commands:
--   hangmanSolver            show this summary
--   hangmanSolver on|off     enable or disable the solver triggers
--   hangmanSolver debug on|off  toggle debug output
--   hangmanSolver help       show this summary

local SETTINGS_KEY = "hangmanSolver.settings"

local enabled = true
local debug_enabled = false

local okH, H = pcall(require, "helpstyle")
if not okH or type(H) ~= "table" then
  H = nil
end

local IS_WINDOWS = package.config:sub(1, 1) == "\\"
local BASE_URL = "https://www.hangman-solver.com/.netlify/functions/answers?word="
local BACKOFF_SECONDS = 20

-- State variables
local hangman_word = ""
local possible_guesses = {}
local cache = {}
local last_key = nil
local fail_until = 0

local function dbg(msg)
  if debug_enabled then
    rune.echo("[hangmanSolver:debug] " .. tostring(msg))
  end
end

local function onoff(flag)
  return flag and "on" or "off"
end

local function load_settings()
  if not (rune and rune.store and type(rune.store.get) == "function") then
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

local function save_settings()
  if not (rune and rune.store and type(rune.store.set) == "function") then
    return
  end

  pcall(rune.store.set, SETTINGS_KEY, {
    enabled = enabled,
    debug = debug_enabled,
  })
end

local function extractWords(json_string)
  local words = {}
  for word in json_string:gmatch('"word"%s*:%s*"([^"]*)"') do
    words[#words + 1] = word
  end
  return words
end

local function curlCommand(url)
  if IS_WINDOWS then
    return 'curl.exe -s -L --connect-timeout 2 --max-time 3 "' .. url .. '" 2>NUL'
  end
  return "curl -s -L --connect-timeout 2 --max-time 3 '" .. url .. "' 2>/dev/null"
end

local function runCommand(cmd)
  if io.popen then
    local ok, pipe = pcall(io.popen, cmd, "r")
    if ok and pipe then
      local out = pipe:read("*a") or ""
      pipe:close()
      return out
    end
  end

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

local function solveHangman(wrong_guesses)
  if hangman_word == nil or hangman_word == "" then
    rune.echo("Unknown starting length?")
    return
  elseif #possible_guesses == 1 then
    rune.echo("Possible guesses: " .. table.concat(possible_guesses, ", "))
    return
  elseif string.find(hangman_word, "_", 1, true) == nil then
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

  local word = hangman_word:gsub("[^%a_]", "")
  local guesses = (wrong_guesses or ""):gsub("[^%a]", "")
  local key = word .. "|" .. guesses

  if key == last_key then
    dbg("Skipping repeat lookup for " .. key)
    return
  end

  local cached = cache[key]
  if cached then
    dbg("Cache hit for " .. key)
    possible_guesses = cached
    last_key = key
    rune.echo("Possible guesses: " .. table.concat(possible_guesses, ", "))
    return
  end

  local now = os.time()
  if now < fail_until then
    dbg("Solver paused for " .. (fail_until - now) .. "s after a failure")
    return
  end

  local url = BASE_URL .. word .. "&guesses=" .. guesses
  dbg("Fetching " .. url)

  local response = runCommand(curlCommand(url))
  if #response == 0 then
    fail_until = os.time() + BACKOFF_SECONDS
    dbg("Empty response from solver")
    rune.echo("Solver unavailable - manual guessing needed (retry in " .. BACKOFF_SECONDS .. "s)")
    return
  end

  dbg("Raw response (" .. #response .. " chars): " .. response:sub(1, 200))

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

local function startHangman()
  hangman_word = ""
  possible_guesses = {}
  cache = {}
  last_key = nil
  rune.send("hangman start")
  rune.send("hangman e")
end

local function setWord(word)
  hangman_word = word
end

local function show_help()
  local status = "v2.4  solver=" .. onoff(enabled) .. " debug=" .. onoff(debug_enabled) .. " os=" .. (IS_WINDOWS and "windows" or "unix")

  if H and H.title and H.section and H.line and H.foot then
    rune.echo(H.title("Hangman Solver"))
    rune.echo(H.section("Commands"))
    rune.echo(H.line("hangmanSolver", "show this summary"))
    rune.echo(H.line("hangmanSolver on|off", "enable or disable the solver triggers"))
    rune.echo(H.line("hangmanSolver debug on|off", "toggle debug output"))
    rune.echo(H.foot(status))
    return
  end

  rune.echo("Hangman Solver")
  rune.echo("  hangmanSolver                 show this summary")
  rune.echo("  hangmanSolver on|off          enable or disable the solver triggers")
  rune.echo("  hangmanSolver debug on|off    toggle debug output")
  rune.echo(status)
end

rune.alias.regex("^hangmanSolver(?:\\s+(.*))?$", function(m)
  local text = (m[1] or ""):lower()
  local cmd = text:match("^(%S*)") or ""
  local value = text:match("^%S+%s*(.*)$") or ""

  if cmd == "" or cmd == "help" then
    show_help()
    return
  end

  if cmd == "on" then
    enabled = true
    save_settings()
    rune.echo("Hangman solver " .. onoff(enabled))
    return
  end

  if cmd == "off" then
    enabled = false
    save_settings()
    rune.echo("Hangman solver " .. onoff(enabled))
    return
  end

  if cmd == "debug" then
    if value == "on" then
      debug_enabled = true
    elseif value == "off" then
      debug_enabled = false
    else
      show_help()
      return
    end

    save_settings()
    rune.echo("Hangman solver debug " .. onoff(debug_enabled))
    return
  end

  show_help()
end, { name = "hangmanSolver" })

rune.trigger.regex("^You hold a game of hangman (.*?)$", function(m)
  if enabled then
    startHangman()
  end
end, { name = "hangmanSolver-start" })

rune.trigger.regex("^Progress thus far: (.*?)$", function(m)
  if enabled then
    setWord(m[1] or "")
  end
end, { name = "hangmanSolver-pattern" })

rune.trigger.regex("^Failed letters: (.*?)$", function(m)
  if enabled then
    solveHangman(m[1] or "")
  end
end, { name = "hangmanSolver-failed" })

load_settings()
save_settings()