-- Filename: eljayPlugins/hangmanSolver.lua
-- Purpose: Hangman Solver - solves hangman puzzles using online solver
-- Inspired by the MUSHclient plugin by Oona
-- Version: 2.1
-- Date: 2026-Oct-11
--
-- How it works:
--   * When MM says "You hold a game of hangman ...", the plugin sends
--     "hangman start" and "hangman e" (the best opening letter).
--   * "Progress thus far: <pattern>" lines are remembered as the current pattern.
--   * "Failed letters: <letters>" lines trigger a lookup: the pattern and the
--     wrong guesses are sent to hangman-solver.com using curl, and the words
--     it returns are echoed as possible guesses.
--   * A few well-known "emp" patterns (e____, em___, emp__, empt_) are solved
--     locally without any lookup (the answer is "empty").
--   * v2.1: the lookup uses short curl timeouts (so Rune's Lua thread is never
--     blocked for long), the wget fallback and temp files are gone, and the
--     pattern/guesses are sanitized before reaching the shell.

local DEBUG = false  -- set to false to silence the Debug: lines

-- State variables
local hangman_word = ""
local possible_guesses = {}

local function debug(msg)
  if DEBUG then rune.echo("Debug: " .. msg) end
end

--[[ Extract Words from JSON Response ]]--
local function extractWords(json_string)
  local words = {}
  -- Match "word":"value" patterns
  for word in json_string:gmatch('"word"%s*:%s*"([^"]*)"') do
    table.insert(words, word)
  end
  return words
end

--[[ Solve Hangman - short-timeout curl lookup ]]--
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
  local cleaned_guesses = (wrong_guesses or ""):gsub("[^%a]", "")

  local url = "https://www.hangman-solver.com/.netlify/functions/answers?word="
    .. word .. "&guesses=" .. cleaned_guesses
  debug("Fetching " .. url)

  -- Short timeouts keep Rune's Lua thread from being blocked for long
  local cmd = string.format(
    "curl -s -L --connect-timeout 2 --max-time 3 '%s' 2>/dev/null", url)
  local pipe = io.popen(cmd, "r")
  if not pipe then
    rune.echo("Solver unavailable - manual guessing needed")
    return
  end
  local response = pipe:read("*a") or ""
  pipe:close()

  if #response == 0 then
    debug("Empty response from solver")
    rune.echo("Solver unavailable - manual guessing needed")
    return
  end
  debug("Raw response (" .. #response .. " chars): " .. response:sub(1, 200))

  -- Parse JSON response
  possible_guesses = extractWords(response)
  if #possible_guesses > 0 then
    rune.echo("Possible guesses: " .. table.concat(possible_guesses, ", "))
  else
    rune.echo("Could not parse solver response - manual guessing needed")
  end
end

--[[ Start Hangman Game ]]--
local function startHangman()
  hangman_word = ""
  possible_guesses = {}
  rune.send("hangman start")
  rune.send("hangman e")
end

--[[ Set Current Word Pattern ]]--
local function setWord(word)
  hangman_word = word
end

--[[ Triggers ]]--

-- When you receive a hangman game
rune.trigger.regex("^You hold a game of hangman (.*?)$", function(m)
  startHangman()
end)

-- Progress pattern update
rune.trigger.regex("^Progress thus far: (.*?)$", function(m)
  setWord(m[1] or "")
end)

-- Failed letters - trigger solution
rune.trigger.regex("^Failed letters: (.*?)$", function(m)
  solveHangman(m[1] or "")
end)
