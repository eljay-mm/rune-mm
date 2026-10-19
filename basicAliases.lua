-- Filename: eljayPlugins/basicAliases.lua
-- Purpose: Provides shared aliases and automatic responses for all characters
-- Version: 2.13
-- Date: 2026-Oct-19
--[[
TODO:
- insert planning notes here between revisions.
]]
-- Changelog:
--   2.13  Faster load: all simple aliases now live in one lookup table served by
--        a single regex dispatcher (was ~190 rune.alias.exact registrations);
--        forge/rrr/setslave share a second regex alias; the two gag lines are
--        one trigger; helpstyle is loaded only when help is shown; load time is
--        measured once at the end of loading and reported in the help footer.
--   2.12  Added stable names for regex aliases and triggers, used the trigger
--        group's live state in help, and added load-time reporting.
--   2.11  Persisted trigger on/off state with rune.store; debug remains off
--        on startup; registered the full command and short alias as exact aliases.
--
-- How it works:
--   * Triggers provide automatic responses to game text and gag noisy lines.
--     Yes/no questions use prompt triggers as well as full-line triggers.
--   * All triggers belong to the "basicAliases" group; basicAliases on|off
--     switches the group, and its state is saved with rune.store.
--   * Simple aliases are rows in one table, A("key", "command"). A single
--     regex alias matches any known key plus optional typed arguments, which
--     are appended to the command. Helper P() wraps skill aliases as plan '...'.
--   * Commands are chained with ";" inside a single rune.send string.
--   * Commands are typed without a / prefix. basicAliases is the full command
--     and basic is the short alias; typing either alone shows help.
--   * Debug messages default to off and reset to off on startup.
--
-- Commands (basic works in place of basicAliases):
--   basicAliases                 show this help
--   basicAliases on|off          enable or disable the triggers
--   basicAliases debug on|off    show or hide debug messages (default off)
--
-- Tweaks (top of file):
--   * None

local LOAD_STARTED = os.clock()

local NAME, VERSION, GROUP = "basicAliases", "2.13", "basicAliases"
local SHORT = "basic"
local SETTINGS_KEY = "basicAliases.settings"
local debugOn = false
local enabled = true
local triggerIndex = 0
local loadMs = 0

-- Output helpers

local function paint(color, text)
  local style = rune.style
  if not style or type(style[color]) ~= "function" then
    return text
  end

  local ok, result = pcall(style[color], text)
  return (ok and type(result) == "string") and result or text
end

local function say(message)
  rune.echo(paint("cyan", "[" .. NAME .. "] ") .. message)
end

local function dbg(message)
  if debugOn then
    say(paint("yellow", "debug: ") .. message)
  end
end

-- Trigger helpers

local function next_trigger_name()
  triggerIndex = triggerIndex + 1
  return string.format("%s.trigger.%03d", NAME, triggerIndex)
end

local function auto(pattern, cmd, on)
  rune.trigger.regex(pattern, function()
    dbg("trigger -> " .. cmd)
    rune.send(cmd)
  end, {
    name = next_trigger_name(),
    group = GROUP,
    on = on,
  })
end

local function prompt_trigger(pattern, cmd)
  auto(pattern, cmd, "prompt")
  auto(pattern, cmd)
end

local function gag(pattern)
  rune.trigger.regex(pattern, function()
    dbg("gagged a line")
  end, {
    name = next_trigger_name(),
    group = GROUP,
    gag = true,
  })
end

-- Alias table (served by one regex dispatcher, registered at the end)

local map, keys = {}, {}

local function A(key, cmd)
  if map[key] == nil then
    keys[#keys + 1] = key
  end
  map[key] = cmd
end

local function P(key, skill)
  A(key, "plan '" .. skill .. "'")
end

-- Triggers

auto("^A sudden, strong gust of wind knocks you to the ground!$", "stand")
auto("^A tangle vine twists around your feet, preventing you from leaving!", "attack tangle")
auto("^\\s*An open coffin is covered in dust here\\.$", "enter coffin")
auto("^Divusmors vanishes with a clap of thunder!$", "get all.loot;get all lootable")

prompt_trigger("Do you wish to join this formation\\s*\\(y/N\\)\\?", "y")
prompt_trigger("(?i)do you allow this follower.*\\(y/n\\)", "y")

gag("^(?:\\s+a (?:magical belt pouch|woven gold bag|yellow silk bag|red silk bag|blue silk bag|black silk bag) \\(new\\)$|An armor-plated harmonica holder squonks discordantly, displeased by your )")

-- Movement / recall

A("mp", "mount pegasus")
A("dism", "dismount pegasus;hitch pegasus post")
A("lip", "look in portal")
A("ep", "enter portal")
A("cwo", "cast 'word of recall'")
A("ahall", "alliance gohall")
A("hall", "clan gohall")

-- Containers / looking

A("l1", "look in 1.trunk")
A("l2", "look in 2.trunk")
A("l3", "look in 3.trunk")
A("l4", "look in 4.trunk")
A("l5", "look in tanbluck")
A("lg", "look in 'a goldweave bag'")
A("le", "look in 'a bag embroidered with silver runes'")
A("lr", "look in 'an earthen bag'")
A("lm", "look in gnomish")
A("lb", "look in bag")
A("lp", "look in pouch")
A("lt", "look in trunk")
A("ln", "look in 'a pouch of plenitude'")
A("lno", "open 'a pouch of plenitude'")
A("lnc", "close 'a pouch of plenitude'")
A("lc", "look in corpse;look in 2.corpse;look in 3.corpse")
A("lv", "look valuable")
A("lrt", "look rootbag")
A("ta", "take all corpse")
A("tl", "take all lootable")
A("tc", "take crystal")
A("tt", "take all.tourm corpse")
A("tg", "take gold corpse")
A("fha", "take bernadette miner;eat bernadette")
A("ir", "inventory reorder")

-- Basics / utility

A("ce", "chat enter")
A("cx", "chat exit")
A("cen", "check newstat")
A("ceb", "check equipment bindings")
A("cem", "check equipment missing")
A("cev", "check equipment value")
A("cg", "check gossip")
A("r", "rest")
A("st", "stand")
A("sm0", "set automap off")
A("sm1", "set automap on")
A("sc", "scan")
A("su", "survey")
A("mr", "mail receive")
A("hs", "help status")
A("path", "skill analyze")
A("lo", "lay out")
A("rb", "raise bar")
A("fb", "fistbump")
A("rf", "relay #first")
A("go", "where is")
A("nf", "news _search")

-- Info / where

A("bi", "boss info")
A("bw", "boss where")
A("mi", "mark info")
A("ml", "mark list")
A("mw", "mark where")
A("sg", "ship cargo")

-- Research

A("rrl", "read research list")

-- Locker

A("lor", "locker remove")
A("los", "locker store")
A("ll", "locker list")
A("ls", "locker survey")

-- Bank / vendor / shop

A("dep", "bank deposit all")
A("wd50", "bank withdraw 50000")
A("wd60", "bank withdraw 60000")
A("vf", "vendor search")
A("vr", "vendor reprice")
A("vs", "vendor search")
A("vw", "vendor where")

-- Say / NPC responses

A("bjh", "say hit")
A("bjs", "give gambling dealer")
A("bjy", "say stay")
A("siw", "sayto illusionist i will")
A("pr", "sayto orc yes;nod orc")
A("sr", "sayto representative yes")
A("sim", "say I'm ready to move on")
A("clump", "give clump quenya;sayto quenya Icanda hom ganda standa")
A("globe", "give globe quenya;sayto quenya Free the inner powers of the globe")
A("tema", "sayto priest restore the order of the tame")
A("hbx", "say By the flames of Gath, deliver me from this inferno!")
A("cm", "cower mourdul")

-- Clan / alliance / formation / who

A("cw", "clan where")
A("nt", "clan talk novice")
A("ps", "pursuer")
A("ff", "form follow")
A("fss", "form structure shield")
A("fr", "form rep")
A("fw", "form where")
A("wc", "who sortbyclan")
A("whol", "who 1 19")
A("who1", "who 20 60")
A("who2", "who 61 120")
A("who3", "who 121 180")
A("who4", "who 181 240")

-- Ships

A("sht", "ship target attacker")
A("shf", "ship fire")
A("shff", "ship fire fire-launcher")

-- Breath (dracon)

A("rfi", "breathe fire")
A("rga", "breathe gas")
A("rac", "breathe acid")
A("rfr", "breathe frost")
A("rli", "breathe lightning")

-- Combat / skills

A("b", "bash")
A("h", "hold")
A("sd", "strike down")
A("sb", "strike blow")
A("rh", "raise hackles")
A("vhd", "herald death")
A("hd", "herald death")

-- Plan (skills)

P("sss", "summon soldier")
P("ppr", "physical reinforcement")
P("pbd", "battle dive")
P("hb", "headbutt")
P("pfr", "frothing rage")
P("bm", "blood in your mouth")

-- Quests / recall / auction / alliance / inventory

A("ql", "quest list")
A("qr", "quest request")
A("qrr", "quest request rewarding")
A("qrm", "quest request metaphase")
A("qc", "quest complete")
A("qi", "quest identify")
A("qs", "quest status")
A("rl", "recall list")
A("if", "inventory search")
A("al", "auction list")
A("ab", "auction bid")
A("ai", "auction identify")
A("aw", "alliance where")

-- Aliases that take a required argument (forge, rrr, setslave)

local function safe(text)
  return type(text) == "string" and text ~= "" and not text:find("[;\r\n]")
end

local special = {
  forge = function(item) rune.send("put " .. item .. " forge;close forge") end,
  rrr = function(item) rune.send("rem notes;read research buy " .. item .. ";bind thesis notes;hold notes") end,
  setslave = function(text) rune.send("clan security set " .. text .. " alliancetalk chatlog gohall log where") end,
}

-- Settings

local function load_settings()
  if not rune.store or type(rune.store.get) ~= "function" then
    return
  end

  local ok, saved = pcall(rune.store.get, SETTINGS_KEY)
  if ok and type(saved) == "table" and type(saved.enabled) == "boolean" then
    enabled = saved.enabled
  end
end

local function save_settings()
  if rune.store and type(rune.store.set) == "function" then
    pcall(rune.store.set, SETTINGS_KEY, { enabled = enabled })
  end
end

local function onoff(value)
  return value and "on" or "off"
end

-- Help (helpstyle is loaded only when help is shown)

local function emit(row)
  if row ~= nil then rune.echo(row) end
end

local function trigger_state()
  if rune.group and type(rune.group.is_enabled) == "function" then
    local ok, state = pcall(rune.group.is_enabled, GROUP)
    if ok and type(state) == "boolean" then
      enabled = state
    end
  end
  return enabled
end

local function help()
  local status = "v" .. VERSION ..
    "  triggers=" .. onoff(trigger_state()) ..
    " debug=" .. onoff(debugOn) ..
    " aliases=" .. #keys ..
    string.format("  load=%dms", loadMs)

  local ok, H = pcall(require, "helpstyle")
  if not ok or type(H) ~= "table" then
    H = nil
  end

  local styled = H and pcall(function()
    emit(H.title("Basic aliases  (alias: " .. SHORT .. ")"))
    emit(H.section("Commands"))
    emit(H.line(NAME, "show this help (short alias: " .. SHORT .. ")"))
    emit(H.line(NAME .. " on|off", "enable or disable the automatic-response and gag triggers"))
    emit(H.line(NAME .. " debug on|off", "show or hide debug messages (default off)"))
    emit(H.foot(status))
  end)

  if not styled then
    rune.echo("Basic aliases  (alias: " .. SHORT .. ")")
    rune.echo("  " .. NAME .. "                 show this help (short alias: " .. SHORT .. ")")
    rune.echo("  " .. NAME .. " on|off          enable or disable the automatic-response and gag triggers")
    rune.echo("  " .. NAME .. " debug on|off    show or hide debug messages (default off)")
    rune.echo(status)
  end
end

local function command(args)
  local text = tostring(args or ""):lower():match("^%s*(.-)%s*$")
  local option, value = text:match("^(%S*)%s*(%S*)$")

  if option == "" or option == "help" then
    help()
  elseif option == "on" or option == "off" then
    enabled = option == "on"
    if enabled then
      rune.group.enable(GROUP)
    else
      rune.group.disable(GROUP)
    end
    save_settings()
    say("triggers " .. option)
  elseif option == "debug" and (value == "on" or value == "off") then
    debugOn = value == "on"
    say("debug " .. value)
  else
    say("unknown option; type " .. NAME .. " or " .. SHORT .. " for help")
  end
end

A(NAME, command)
A(SHORT, command)

-- Dispatchers (two registrations replace one per alias)

rune.alias.regex("^(" .. table.concat(keys, "|") .. ")(?:\\s+(.*))?$", function(matches)
  local key, args = matches[1], matches[2]
  local entry = map[key]
  if entry == nil then return end
  if type(args) ~= "string" then args = "" end

  if type(entry) == "function" then
    entry(args)
    return
  end

  if args ~= "" then
    if args:find("[\r\n]") then return end
    entry = entry .. " " .. args
  end
  dbg("alias " .. key .. " -> " .. entry)
  rune.send(entry)
end, { name = NAME .. ".alias.dispatch" })

rune.alias.regex("^(forge|rrr|setslave) +(.+)$", function(matches)
  local handler, text = special[matches[1]], matches[2]
  if handler and safe(text) then
    dbg("alias " .. matches[1] .. " " .. text)
    handler(text)
  end
end, { name = NAME .. ".alias.special" })

load_settings()
if enabled then
  rune.group.enable(GROUP)
else
  rune.group.disable(GROUP)
end

loadMs = math.floor((os.clock() - LOAD_STARTED) * 1000 + 0.5)
say("v" .. VERSION .. " loaded (" .. NAME .. " or " .. SHORT .. " for help)")