-- Filename: eljayPlugins/herbAliases.lua
-- Purpose: Provides short aliases for Herbalism mixing, throwing and eating.
-- Version: 1.14
-- Date: 2026-Oct-26
--[[
- Confirm the configured h* actions and mixture names in game.
]]
-- Changelog:
--   1.14 Add case-insensitive literal substring filtering to list.
--   1.13 Align command documentation and help output with project conventions.
--   1.12 Remove the "mix" prefix from the list display and fit list rows within 74 characters.
--   1.11 Strip the leading "a " and trailing " herbal mixture" from mixture names in the list.
--   1.10 Add h* aliases and mixture names to the common-mix list.
--   1.9  Add a matching h* alias entry for every m* alias.
--   1.8  Correct binding count, add short-alias help row, and validate quantities and targets.
--   1.7  Add all common mixes with their power ranges and optional quantities.
--   1.6  Add standard help footer, persistent debug toggle and load-time reporting.
--   1.5  Replace the numbered pick command with a searchable picker that reopens after each choice.
--   1.4  Separate alias names and mix commands with a tab in the list and picker.
--   1.3  Add a numbered picker for the m* aliases and their mix commands.
--   1.2  Add a list command showing each m* alias and its mix command.
--   1.1  Remove the obsolete mixon and mixoff aliases; change the short alias to herb.
--   1.0  Convert the yHerbalism MUSHclient aliases to Rune aliases.
--
-- How it works:
--   * Registers short aliases for mixing and using herbal mixtures.
--   * Optional numeric quantities are passed to mix commands; validated target text is passed to use commands.
--   * The list and picker show each common mix, its m* and h* aliases, use details, command, and power range.
--   * The list accepts an optional case-insensitive literal substring filter matching aliases, use details, commands, mixtures, and power ranges.
--   * Each m* alias has a matching h* alias; unconfigured h* aliases prompt for their herb details.
--   * Selecting an item in the picker sends its mix command and reopens the picker.
--   * Press Esc to close the picker.
--
-- Commands (type without "/"; "herb" is a short alias for "herbAliases"):
--   herbAliases             show this help
--   herbAliases list [text] list common mixes; optionally filter by literal text
--   herbAliases pick        open the searchable mix picker
--   herbAliases on|off      enable / disable the aliases
--   herbAliases debug       toggle debug messages
--
-- Tweaks:
--   * mixAliases  entries shown by list and pick.
--   * useAliases  h* aliases, their matching m* aliases, verbs and herb mixture names.

local LOAD_STARTED = os.clock()

-- Command names: full command and short alias.
local NAME = "herbAliases"
local SHORT = "herb"
local VERSION = "1.14"
local BINDING_COUNT = 38

local STORE_ENABLED = "eljayPlugins." .. NAME .. ".enabled"
local STORE_DEBUG = "eljayPlugins." .. NAME .. ".debug"

local function storedBool(key, default)
  local ok, value = pcall(rune.store.get, key)
  if ok and type(value) == "boolean" then
    return value
  end
  return default
end

local enabled = storedBool(STORE_ENABLED, true)
local debugEnabled = storedBool(STORE_DEBUG, false)

local H = require("helpstyle")

local mixAliases = {
  { alias = "maw",  spell = "Awaken",                power = "5-10" },
  { alias = "mclt", spell = "Cause Light",           power = "11-20" },
  { alias = "mdi",  spell = "Detect Invisibility",   power = "21-30" },
  { alias = "mey",  spell = "Essence of Youth",      power = "31-40" },
  { alias = "mcl",  spell = "Cure Light",            power = "41-50" },
  { alias = "mre",  spell = "Refresh",               power = "51-60" },
  { alias = "maa",  spell = "Alchemical Attunement", power = "61-70" },
  { alias = "mfv",  spell = "Foster Vine",           power = "71-85" },
  { alias = "mca",  spell = "Calm",                  power = "86-105" },
  { alias = "mhh",  spell = "Halflings Herb",        power = "106-115" },
  { alias = "mdt",  spell = "Detect Truth",          power = "116-135" },
  { alias = "mge",  spell = "Golem Empathy",          power = "136-145" },
  { alias = "mfa",  spell = "Fatigue",               power = "146-155" },
  { alias = "mpd",  spell = "Prophylactic Draught",  power = "156-170" },
  { alias = "mbp",  spell = "Battle Prowess",        power = "171-185" },
  { alias = "meo",  spell = "Elemental Overload",    power = "186-200" },
  { alias = "mbb",  spell = "Beast of Burden",       power = "201-220" },
  { alias = "mbl",  spell = "Blindness",             power = "221-240" },
}

-- Each m* alias has an h* counterpart.
-- Fill in verb ("eat" or "throw") and mixture for unconfigured rows.
local useAliases = {
  { alias = "haw",  mixAlias = "maw",  verb = nil,     mixture = nil },
  { alias = "hclt", mixAlias = "mclt", verb = nil,     mixture = nil },
  { alias = "hdi",  mixAlias = "mdi",  verb = nil,     mixture = nil },
  { alias = "hey",  mixAlias = "mey",  verb = nil,     mixture = nil },
  { alias = "hcl",  mixAlias = "mcl",  verb = "eat",   mixture = "a glimmering white herbal mixture" },
  { alias = "hre",  mixAlias = "mre",  verb = "eat",   mixture = "a warm brown herbal mixture" },
  { alias = "haa",  mixAlias = "maa",  verb = nil,     mixture = nil },
  { alias = "hfv",  mixAlias = "mfv",  verb = nil,     mixture = nil },
  { alias = "hca",  mixAlias = "mca",  verb = "eat",   mixture = "a faint yellow herbal mixture" },
  { alias = "hhh",  mixAlias = "mhh",  verb = "eat",   mixture = "a bright green herbal mixture" },
  { alias = "hdt",  mixAlias = "mdt",  verb = nil,     mixture = nil },
  { alias = "hge",  mixAlias = "mge",  verb = nil,     mixture = nil },
  { alias = "hfa",  mixAlias = "mfa",  verb = "throw", mixture = "a sparkling gold herbal mixture" },
  { alias = "hpd",  mixAlias = "mpd",  verb = nil,     mixture = nil },
  { alias = "hbp",  mixAlias = "mbp",  verb = "eat",   mixture = "a flourescing magenta herbal mixture" },
  { alias = "heo",  mixAlias = "meo",  verb = "throw", mixture = "a malevolent magenta herbal mixture" },
  { alias = "hbb",  mixAlias = "mbb",  verb = "eat",   mixture = "a tawny herbal mixture" },
  { alias = "hbl",  mixAlias = "mbl",  verb = "throw", mixture = "a temporarily charred herbal mixture" },
}

local LOAD_MS

local function onoff(value)
  return value and "on" or "off"
end

local function say(message)
  local ok, styled = pcall(rune.style.cyan, "[" .. NAME .. "] ")
  rune.echo((ok and styled or "[" .. NAME .. "] ") .. message)
end

local function saveState()
  pcall(rune.store.set, STORE_ENABLED, enabled)
  pcall(rune.store.set, STORE_DEBUG, debugEnabled)
end

local function debug(message)
  if debugEnabled then
    say("debug: " .. message)
  end
end

local function send(command)
  if not enabled then
    debug("ignored while disabled: " .. command)
    return
  end
  rune.send(command)
end

local function showHelp()
  rune.echo(H.title(NAME .. " (alias: " .. SHORT .. ")"))
  rune.echo(H.section("Commands"))
  rune.echo(H.line(NAME, "show this help"))
  rune.echo(H.line(SHORT .. " list [text]", "filter common mixes and power ranges"))
  rune.echo(H.line(SHORT .. " pick", "open the searchable mix picker"))
  rune.echo(H.line(SHORT .. " on|off", "enable / disable the aliases"))
  rune.echo(H.line(SHORT .. " debug", "toggle debug messages"))
  rune.echo(H.line(SHORT, "short alias for " .. NAME))
  rune.echo(H.section("Use aliases"))
  rune.echo(H.line("haw / hclt / hdi", "use configured mixture"))
  rune.echo(H.line("hey / hcl / hre", "use configured mixture"))
  rune.echo(H.line("haa / hfv / hca", "use configured mixture"))
  rune.echo(H.line("hhh / hdt / hge", "use configured mixture"))
  rune.echo(H.line("hfa / hpd / hbp", "use configured mixture"))
  rune.echo(H.line("heo / hbb / hbl", "use configured mixture"))
  rune.echo(H.foot(string.format(
    "v%s  enabled=%s debug=%s bindings=%d  load=%dms",
    VERSION,
    onoff(enabled),
    onoff(debugEnabled),
    BINDING_COUNT,
    LOAD_MS
  )))
end

local function mixCommand(item)
  return "mix '" .. item.spell .. "'"
end

local function fit(value, width)
  value = tostring(value or "nil")
  if #value > width then
    return value:sub(1, width - 3) .. "..."
  end
  return value .. string.rep(" ", width - #value)
end

local function cyan(value)
  local ok, styled = pcall(rune.style.cyan, value)
  return ok and styled or value
end

local function listMixAliases(filter)
  filter = (filter or ""):lower()
  local shown = 0

  rune.echo(H.title("Herbalism common mixes"))
  rune.echo(
    fit("mix", 8) ..
    fit("use", 8) ..
    fit("how", 6) ..
    fit("mixture", 21) ..
    fit("mix command", 21) ..
    "power"
  )

  for _, mix in ipairs(mixAliases) do
    local hAlias = "nil"
    local use = "nil"
    local mixture = "nil"

    for _, item in ipairs(useAliases) do
      if item.mixAlias == mix.alias then
        hAlias = item.alias
        use = item.verb or "nil"

        if item.mixture then
          mixture = item.mixture
            :gsub("^a ", "")
            :gsub(" herbal mixture$", "")
        end

        break
      end
    end

    local displayCommand = mixCommand(mix):gsub("^mix%s+", "")
    local searchable = table.concat({
      mix.alias,
      hAlias,
      use,
      mixture,
      displayCommand,
      mix.power,
    }, " "):lower()

    if filter == "" or searchable:find(filter, 1, true) then
      shown = shown + 1
      rune.echo(
        cyan(fit(mix.alias, 8)) ..
        cyan(fit(hAlias, 8)) ..
        fit(use, 6) ..
        fit(mixture, 21) ..
        fit(displayCommand, 21) ..
        mix.power
      )
    end
  end

  if shown == 0 then
    rune.echo("No common mixes match '" .. filter .. "'.")
  end
end

local showPicker

showPicker = function()
  local items = {}

  for _, item in ipairs(mixAliases) do
    items[#items + 1] = {
      text = item.alias .. "\t" .. mixCommand(item) .. "  power " .. item.power,
      value = mixCommand(item),
    }
  end

  local ok, err = pcall(rune.ui.picker.show, {
    title = "Herbal mixtures - Esc to close",
    items = items,
    match_description = true,
    on_select = function(value)
      if type(value) == "string" then
        send(value)
      end

      rune.timer.after(0.05, showPicker, {
        name = NAME .. "-reopen",
      })
    end,
  })

  if not ok then
    say("Picker failed: " .. tostring(err))
  end
end

local function trim(value)
  return (value or ""):match("^%s*(.-)%s*$")
end

local function runCommand(args)
  local argument = trim(args)
  local subcommand, rest = argument:match("^(%S+)%s*(.-)$")
  subcommand = (subcommand or ""):lower()

  if subcommand == "" or subcommand == "help" then
    showHelp()
  elseif subcommand == "list" then
    listMixAliases(trim(rest))
  elseif subcommand == "pick" then
    showPicker()
  elseif subcommand == "on" then
    enabled = true
    saveState()
    say("aliases " .. onoff(enabled))
  elseif subcommand == "off" then
    enabled = false
    saveState()
    say("aliases " .. onoff(enabled))
  elseif subcommand == "debug" then
    local setting = trim(rest):lower()
    if setting == "on" then
      debugEnabled = true
    elseif setting == "off" then
      debugEnabled = false
    else
      debugEnabled = not debugEnabled
    end
    saveState()
    say("debug " .. onoff(debugEnabled))
  else
    showHelp()
  end
end

local function registerCommandAlias(name)
  rune.alias.exact(name, function(args, ctx)
    runCommand(args)
  end)
end

local function registerMixAlias(item)
  rune.alias.exact(item.alias, function(args, ctx)
    local quantity = trim(args)
    if quantity ~= "" then
      local amount = tonumber(quantity)
      if not quantity:match("^%d+$") or not amount or amount <= 0 then
        say("Quantity must be a positive whole number.")
        return
      end
    end

    local command = mixCommand(item)
    if quantity ~= "" then
      command = command .. " " .. quantity
    end
    send(command)
  end)
end

local function registerUseAlias(item)
  rune.alias.exact(item.alias, function(args, ctx)
    if not item.verb or not item.mixture then
      say(item.alias .. " is not configured yet; edit its entry in useAliases.")
      return
    end

    if item.verb ~= "eat" and item.verb ~= "throw" then
      say(item.alias .. " has an invalid verb; use 'eat' or 'throw'.")
      return
    end

    local target = trim(args)
    if target ~= "" and not target:match("^[%w _%-]+$") then
      say("Target may contain only letters, numbers, spaces, underscores and hyphens.")
      return
    end

    local command = item.verb .. " '" .. item.mixture .. "'"
    if target ~= "" then
      command = command .. " " .. target
    end
    send(command)
  end)
end

registerCommandAlias(NAME)
registerCommandAlias(SHORT)

for _, item in ipairs(mixAliases) do
  registerMixAlias(item)
end

for _, item in ipairs(useAliases) do
  registerUseAlias(item)
end

LOAD_MS = math.floor((os.clock() - LOAD_STARTED) * 1000 + 0.5)

say(string.format("v%s loaded (%s or %s for help)", VERSION, NAME, SHORT))
