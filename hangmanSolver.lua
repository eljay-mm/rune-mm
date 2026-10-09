-- Filename: eljayPlugins/hangmanSolver.lua
-- Purpose: Hangman Solver - solves hangman puzzles using online solver
-- Inspired by the MUSHclient plugin by Oona
-- Version: 2.0 
-- Date: 2026-Oct-09

-- State variables
local hangman_word = ""
local possible_guesses = {}

--[[ Extract Words from JSON Response ]]--
local function extractWords(json_string)
  local words = {}
  -- Match "word":"value" patterns
  for word in json_string:gmatch('"word"%s*:%s*"([^"]*)"') do
    table.insert(words, word)
  end
  return words
end

--[[ Solve Hangman - Uses curl with proper GET request ]]--
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

  -- Clean the guesses (remove spaces)
  local cleaned_guesses = wrong_guesses:gsub(" ", "")
  local url = "https://www.hangman-solver.com/.netlify/functions/answers?word=" .. hangman_word .. "&guesses=" .. cleaned_guesses

  -- Debug: show what we're fetching
  rune.echo("Debug: Fetching " .. url)

  -- Use curl with proper GET request (not @ for temp file)
  local output_file = "/tmp/hangman_result_" .. os.time() .. ".txt"
  
  local cmd = string.format("curl -s -L --max-time 10 '%s' > %s 2>&1", url, output_file)
  
  local ret = os.execute(cmd)
  if ret ~= 0 then
    rune.echo("Debug: curl returned error code " .. tostring(ret))
  end

  -- Read response
  local result_file = io.open(output_file, "r")
  if not result_file then
    rune.echo("Error reading solver result file")
    os.remove(output_file)
    return
  end
  
  local response = result_file:read("*a")
  result_file:close()
  os.remove(output_file)

  -- Debug: show raw response
  if #response == 0 then
    rune.echo("Debug: Empty response from solver")
    return
  end
  
  rune.echo("Debug: Raw response (" .. #response .. " chars): " .. response:sub(1, 200))

  -- Parse JSON response
  possible_guesses = extractWords(response)
  if #possible_guesses > 0 then
    rune.echo("Possible guesses: " .. table.concat(possible_guesses, ", "))
  else
    rune.echo("Could not parse solver response - trying alternate method")
    
    -- Fallback: try wget if curl fails
    local alt_output = "/tmp/hangman_alt_" .. os.time() .. ".txt"
    local alt_cmd = string.format("wget -q -O %s '%s' 2>/dev/null", alt_output, url)
    os.execute(alt_cmd)
    
    local alt_file = io.open(alt_output, "r")
    if alt_file then
      local alt_response = alt_file:read("*a")
      alt_file:close()
      possible_guesses = extractWords(alt_response)
      os.remove(alt_output)
      
      if #possible_guesses > 0 then
        rune.echo("Possible guesses (wget): " .. table.concat(possible_guesses, ", "))
        return
      end
    end
    
    rune.echo("Solver unavailable - manual guessing needed")
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