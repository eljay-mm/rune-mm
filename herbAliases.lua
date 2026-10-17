-- Filename: eljayPlugins/herbAliases.lua
-- Purpose: Provides short aliases for Herbalism mixing, throwing and eating.
-- Version: 1.5
-- Date: 2026-Oct-17
-- Changelog:
--   1.5  Replace the numbered pick command with a searchable picker that reopens after each choice.
--   1.4  Separate alias names and mix commands with a tab in the list and picker.
--   1.3  Add a numbered picker for the m* aliases and their mix commands.
--   1.2  Add a list command showing each m* alias and its mix command.
--   1.1  Remove the obsolete mixon and mixoff aliases; change the short alias to herb.
--   1.0  Convert the yHerbalism MUSHclient aliases to Rune aliases.
--
-- How it works:
--   * Registers short aliases for mixing and using herbal mixtures.
--   * Optional target text is passed to the matching throw or eat command.
--   * The list and picker use the same set of m* aliases and mix commands.
--   * Selecting an item in the picker sends its mix command and reopens the picker.
--   * Press Esc to close the picker.
--
-- Commands (type without "/"; "herb" is a short alias for "herbAliases"):
--   herbAliases / herb       show this help
--   herbAliases list         list m* aliases and their mix commands
--   herbAliases pick         open the searchable mix picker
--   herbAliases on|off       enable / disable the aliases
--   herbAliases debug        toggle debug messages
--
-- Tweaks:
--   * Edit mixAliases below to change the entries shown by list and pick.

local NAME = "herbAliases"
local SHORT = "herb"
local VERSION = "1.5"

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
  { alias = "mbl", command = "mix 'blindness'" },
  { alias = "mbp", command = "mix 'battle prowess'" },
  { alias = "mca", command = "mix 'calm'" },
  { alias = "mcl", command = "mix 'cure light'" },
  { alias = "mhh", command = "mix 'halflings herb'" },
  { alias = "mre", command = "mix 'refresh'" },
  { alias = "mfa", command = "mix 'fatigue'" },
  { alias = "mbb", command = "mix 'beast of burden'" },
  { alias = "meo", command = "mix 'elemental overload'" },
}

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
  rune.echo(H.line(NAME .. " | " .. SHORT, "show this help"))
  rune.echo(H.line(NAME .. " list", "list m* aliases and their mix commands"))
  rune.echo(H.line(NAME .. " pick", "open the searchable mix picker"))
  rune.echo(H.line(NAME .. " on|off", "enable / disable the aliases"))
  rune.echo(H.line(NAME .. " debug", "toggle debug messages"))
  rune.echo(H.section("Herbalism"))
  rune.echo(H.line("mbl / mbp / mca / mcl / mhh", "mix a herbal mixture"))
  rune.echo(H.line("mre / mfa / mbb / meo", "mix a herbal mixture"))
  rune.echo(H.line("hbl / hbp / hca / hcl / hhh", "use a matching herbal mixture"))
  rune.echo(H.line("hre / hfa / hbb / heo", "use a matching herbal mixture"))
  rune.echo(H.foot(string.format(
    "v%s  enabled=%s debug=%s",
    VERSION,
    onoff(enabled),
    onoff(debugEnabled)
  )))
end

local function listMixAliases()
  rune.echo(H.title("Herbalism mix aliases"))
  for _, item in ipairs(mixAliases) do
    rune.echo(item.alias .. "\t" .. item.command)
  end
end

local showPicker

showPicker = function()
  local items = {}

  for _, item in ipairs(mixAliases) do
    items[#items + 1] = {
      text = item.alias .. "\t" .. item.command,
      value = item.command,
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
    listMixAliases()
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
  rune.alias.exact(name, function(args)
    runCommand(args)
  end)
end

local function registerFixedAlias(name, command)
  rune.alias.exact(name, function()
    send(command)
  end)
end

local function registerUseAlias(name, verb, mixture)
  rune.alias.exact(name, function(args)
    local target = trim(args)
    local command = verb .. " '" .. mixture .. "'"
    if target ~= "" then
      command = command .. " " .. target
    end
    send(command)
  end)
end

registerCommandAlias(NAME)
registerCommandAlias(SHORT)

registerFixedAlias("mbl", "mix 'blindness'")
registerUseAlias("hbl", "throw", "a temporarily charred herbal mixture")

registerFixedAlias("mbp", "mix 'battle prowess'")
registerUseAlias("hbp", "eat", "a flourescing magenta herbal mixture")

registerFixedAlias("mca", "mix 'calm'")
registerUseAlias("hca", "eat", "a faint yellow herbal mixture")

registerFixedAlias("mcl", "mix 'cure light'")
registerUseAlias("hcl", "eat", "a glimmering white herbal mixture")

registerFixedAlias("mhh", "mix 'halflings herb'")
registerUseAlias("hhh", "eat", "a bright green herbal mixture")

registerFixedAlias("mre", "mix 'refresh'")
registerUseAlias("hre", "eat", "a warm brown herbal mixture")

registerFixedAlias("mfa", "mix 'fatigue'")
registerUseAlias("hfa", "throw", "a sparkling gold herbal mixture")

registerFixedAlias("mbb", "mix 'beast of burden'")
registerUseAlias("hbb", "eat", "a tawny herbal mixture")

registerFixedAlias("meo", "mix 'elemental overload'")
registerUseAlias("heo", "throw", "a malevolent magenta herbal mixture")

say(string.format("v%s loaded (%s or %s for help)", VERSION, NAME, SHORT))
