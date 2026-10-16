-- Filename: eljayPlugins/basicAliases.lua
-- Purpose: Provides shared aliases and automatic responses for all characters
-- Version: 2.11
-- Date: 2026-Oct-16
-- Changelog:
--   2.11  Persisted trigger on/off state with rune.store; debug remains off
--        on startup; registered the full command and short alias as exact aliases.
--   2.10  Argument aliases are plain rune.alias.exact rows (Rune appends typed
--        arguments natively), so the regex helper is gone; comments use -- only.
--
-- How it works:
--   * Triggers: automatic responses to game text and gag triggers for noisy
--     lines. Yes/no questions use prompt triggers as well as full-line triggers.
--   * All triggers belong to the "basicAliases" group; basicAliases on|off
--     switches the group, and its state is saved with rune.store.
--   * Aliases: one row each with rune.alias.exact; Rune appends typed arguments
--     natively (for example, "qs 3" runs "quest status 3"). Helper plan() wraps
--     skill aliases. Aliases are always active; only triggers are toggled.
--   * Commands are chained with ";" inside a single rune.send string.
--   * Commands are typed without a / prefix. basicAliases is the full command
--     and basic is the short alias; typing either alone shows help.
--   * Debug messages default to off and are not persisted.
--
-- Commands (basic works in place of basicAliases):
--   basicAliases                 show this help
--   basicAliases on|off          enable or disable the triggers
--   basicAliases debug on|off    show or hide debug messages (default off)
--
-- Tweaks (top of file):
--   * None

local NAME, VERSION, GROUP = "basicAliases", "2.11", "basicAliases"
local SETTINGS_KEY = "basicAliases.settings"
local debugOn = false

-- Output helpers

local function paint(color, text)
  local ok, result = pcall(function()
    return rune.style[color](text)
  end)
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

-- Helpers

-- Auto-response: when the pattern matches, send cmd (on = "prompt" for partial lines).
local function auto(pattern, cmd, on)
  rune.trigger.regex(pattern, function()
    dbg("trigger -> " .. cmd)
    rune.send(cmd)
  end, { group = GROUP, on = on })
end

-- Text that may arrive as a prompt (partial line) or as a full line.
local function prompt_trigger(pattern, cmd)
  auto(pattern, cmd, "prompt")
  auto(pattern, cmd)
end

-- Hide matching lines.
local function gag(pattern)
  rune.trigger.regex(pattern, function()
    dbg("gagged a line")
  end, { group = GROUP, gag = true })
end

local function plan(key, skill)
  rune.alias.exact(key, "plan '" .. skill .. "'")
end

-- Triggers

-- Auto-responses
auto("^A sudden, strong gust of wind knocks you to the ground!$", "stand")
auto("^A tangle vine twists around your feet, preventing you from leaving!", "attack tangle")
auto("^\\s*An open coffin is covered in dust here\\.$", "enter coffin")
auto("^Divusmors vanishes with a clap of thunder!$", "get all.loot;get all lootable")

-- Yes/no questions (prompts)
prompt_trigger("Do you wish to join this formation\\s*\\(y/N\\)\\?", "y")
prompt_trigger("(?i)do you allow this follower.*\\(y/n\\)", "y")

-- Gag triggers (suppress output)
gag("^\\s+a (?:magical belt pouch|woven gold bag|yellow silk bag|red silk bag|blue silk bag|black silk bag) \\(new\\)$")
gag("^An armor-plated harmonica holder squonks discordantly, displeased by your ")

-- Movement / recall

rune.alias.exact("mp", "mount pegasus")
rune.alias.exact("dism", "dismount pegasus;hitch pegasus post")
rune.alias.exact("lip", "look in portal")
rune.alias.exact("ep", "enter portal")
rune.alias.exact("cwo", "cast 'word of recall'")
rune.alias.exact("ahall", "alliance gohall")
rune.alias.exact("hall", "clan gohall")

-- Containers / looking

rune.alias.exact("l1", "look in 1.trunk")
rune.alias.exact("l2", "look in 2.trunk")
rune.alias.exact("l3", "look in 3.trunk")
rune.alias.exact("l4", "look in 4.trunk")
rune.alias.exact("l5", "look in tanbluck")
rune.alias.exact("lg", "look in 'a goldweave bag'")
rune.alias.exact("le", "look in 'a bag embroidered with silver runes'")
rune.alias.exact("lr", "look in 'an earthen bag'")
rune.alias.exact("lm", "look in gnomish")
rune.alias.exact("lb", "look in bag")
rune.alias.exact("lp", "look in pouch")
rune.alias.exact("lt", "look in trunk")
rune.alias.exact("ln", "look in 'a pouch of plenitude'")
rune.alias.exact("lno", "open 'a pouch of plenitude'")
rune.alias.exact("lnc", "close 'a pouch of plenitude'")
rune.alias.exact("lc", "look in corpse;look in 2.corpse;look in 3.corpse")
rune.alias.exact("lv", "look valuable")
rune.alias.exact("lrt", "look rootbag")
rune.alias.exact("ta", "take all corpse")
rune.alias.exact("tl", "take all lootable")
rune.alias.exact("tc", "take crystal")
rune.alias.exact("tt", "take all.tourm corpse")
rune.alias.exact("tg", "take gold corpse")
rune.alias.exact("fha", "take bernadette miner;eat bernadette")
rune.alias.exact("ir", "inventory reorder")
rune.alias.regex("^forge +(.+)$", function(matches)
  rune.send("put " .. matches[1] .. " forge;close forge")
end)

-- Basics / utility

rune.alias.exact("ce", "chat enter")
rune.alias.exact("cx", "chat exit")
rune.alias.exact("cen", "check newstat")
rune.alias.exact("ceb", "check equipment bindings")
rune.alias.exact("cem", "check equipment missing")
rune.alias.exact("cev", "check equipment value")
rune.alias.exact("cg", "check gossip")
rune.alias.exact("r", "rest")
rune.alias.exact("st", "stand")
rune.alias.exact("sm0", "set automap off")
rune.alias.exact("sm1", "set automap on")
rune.alias.exact("sc", "scan")
rune.alias.exact("su", "survey")
rune.alias.exact("mr", "mail receive")
rune.alias.exact("hs", "help status")
rune.alias.exact("init", "protocol gmcp sendchar")
rune.alias.exact("path", "skill analyze")
rune.alias.exact("lo", "lay out")
rune.alias.exact("rb", "raise bar")
rune.alias.exact("fb", "fistbump")
rune.alias.exact("rf", "relay #first")
rune.alias.exact("go", "where is")
rune.alias.exact("nf", "news _search")

-- Info / where
rune.alias.exact("bi", "boss info")
rune.alias.exact("bw", "boss where")
rune.alias.exact("mi", "mark info")
rune.alias.exact("ml", "mark list")
rune.alias.exact("mw", "mark where")
rune.alias.exact("sg", "ship cargo")

-- Research
rune.alias.exact("rrl", "read research list")
rune.alias.regex("^rrr +(.+)$", function(matches)
  rune.send("rem notes;read research buy " .. matches[1] .. ";bind thesis notes;hold notes")
end)

-- Locker
rune.alias.exact("lor", "locker remove")
rune.alias.exact("los", "locker store")
rune.alias.exact("ll", "locker list")
rune.alias.exact("ls", "locker survey")

-- Bank / vendor / shop
rune.alias.exact("dep", "bank deposit all")
rune.alias.exact("wd50", "bank withdraw 50000")
rune.alias.exact("wd60", "bank withdraw 60000")
rune.alias.exact("vf", "vendor search")
rune.alias.exact("vr", "vendor reprice")
rune.alias.exact("vs", "vendor search")
rune.alias.exact("vw", "vendor where")

-- Say / NPC responses
rune.alias.exact("bjh", "say hit")
rune.alias.exact("bjs", "give gambling dealer")
rune.alias.exact("bjy", "say stay")
rune.alias.exact("siw", "sayto illusionist i will")
rune.alias.exact("pr", "sayto orc yes;nod orc")
rune.alias.exact("sr", "sayto representative yes")
rune.alias.exact("sim", "say I'm ready to move on")
rune.alias.exact("clump", "give clump quenya;sayto quenya Icanda hom ganda standa")
rune.alias.exact("globe", "give globe quenya;sayto quenya Free the inner powers of the globe")
rune.alias.exact("tema", "sayto priest restore the order of the tame")
rune.alias.exact("hbx", "say By the flames of Gath, deliver me from this inferno!")
rune.alias.exact("cm", "cower mourdul")

-- Clan / alliance / formation / who
rune.alias.exact("cw", "clan where")
rune.alias.exact("nt", "clan talk novice")
rune.alias.exact("ps", "pursuer")
rune.alias.regex("^setslave +(.+)$", function(matches)
  rune.send("clan security set " .. matches[1] .. " alliancetalk chatlog gohall log where")
end)
rune.alias.exact("ff", "form follow")
rune.alias.exact("fss", "form structure shield")
rune.alias.exact("fr", "form rep")
rune.alias.exact("fw", "form where")
rune.alias.exact("wc", "who sortbyclan") -- 'wh' conflicted, renamed
rune.alias.exact("whol", "who 1 19")
rune.alias.exact("who1", "who 20 60")
rune.alias.exact("who2", "who 61 120")
rune.alias.exact("who3", "who 121 180")
rune.alias.exact("who4", "who 181 240")

-- Ships
rune.alias.exact("sht", "ship target attacker")
rune.alias.exact("shf", "ship fire")
rune.alias.exact("shff", "ship fire fire-launcher")

-- Breath (dracon)
rune.alias.exact("rfi", "breathe fire")
rune.alias.exact("rga", "breathe gas")
rune.alias.exact("rac", "breathe acid")
rune.alias.exact("rfr", "breathe frost")
rune.alias.exact("rli", "breathe lightning")

-- Combat / skills
rune.alias.exact("b", "bash")
rune.alias.exact("h", "hold")
rune.alias.exact("sd", "strike down")
rune.alias.exact("sb", "strike blow")
rune.alias.exact("rh", "raise hackles")
rune.alias.exact("vhd", "herald death")
rune.alias.exact("hd", "herald death")

-- Plan (skills)
plan("sss", "summon soldier")
plan("ppr", "physical reinforcement")
plan("pbd", "battle dive")
plan("hb", "headbutt")
plan("pfr", "frothing rage")
plan("bm", "blood in your mouth")

-- Quests / recall / auction / alliance / inventory
rune.alias.exact("ql", "quest list")
rune.alias.exact("qr", "quest request")
rune.alias.exact("qrr", "quest request rewarding")
rune.alias.exact("qrm", "quest request metaphase")
rune.alias.exact("qc", "quest complete")
rune.alias.exact("qi", "quest identify")
rune.alias.exact("qs", "quest status")
rune.alias.exact("rl", "recall list")
rune.alias.exact("if", "inventory search")
rune.alias.exact("al", "auction list")
rune.alias.exact("ab", "auction bid")
rune.alias.exact("ai", "auction identify")
rune.alias.exact("aw", "alliance where")

-- Settings

local enabled = true

local function load_settings()
  if not (rune.store and type(rune.store.get) == "function") then
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

-- Help

local helpstyle_ok, H = pcall(require, "helpstyle")
if not helpstyle_ok or type(H) ~= "table" then
  H = nil
end

local function emit(row)
  if row ~= nil then
    rune.echo(row)
  end
end

local function help()
  local status = "v" .. VERSION .. "  triggers=" .. onoff(enabled) ..
    " debug=" .. onoff(debugOn)

  local styled = H and pcall(function()
    emit(H.title("Basic aliases  (alias: basic)"))
    emit(H.section("Commands"))
    emit(H.line("basicAliases", "show this help (short alias: basic)"))
    emit(H.line("basicAliases on|off", "enable or disable the automatic-response and gag triggers"))
    emit(H.line("basicAliases debug on|off", "show or hide debug messages (default off)"))
    emit(H.foot(status))
  end)

  if not styled then
    rune.echo("Basic aliases  (alias: basic)")
    rune.echo("  basicAliases                 show this help (short alias: basic)")
    rune.echo("  basicAliases on|off          enable or disable the automatic-response and gag triggers")
    rune.echo("  basicAliases debug on|off    show or hide debug messages (default off)")
    rune.echo(status)
  end
end

local function command(args, ctx)
  local text = tostring(args or ""):lower():match("^%s*(.-)%s*$")
  local option, value = text:match("^(%S*)%s*(%S*)$")

  if option == "" or option == "help" then
    help()
  elseif option == "on" or option == "off" then
    enabled = (option == "on")
    if enabled then
      rune.group.enable(GROUP)
    else
      rune.group.disable(GROUP)
    end
    save_settings()
    say("triggers " .. option)
  elseif option == "debug" and (value == "on" or value == "off") then
    debugOn = (value == "on")
    say("debug " .. value)
  else
    say("unknown option; type basicAliases or basic for help")
  end
end

-- Full command and short alias are bare aliases, not slash commands.
rune.alias.exact("basicAliases", command)
rune.alias.exact("basic", command)

-- Restore the saved trigger state after registering this plugin's triggers.
load_settings()
if enabled then
  rune.group.enable(GROUP)
else
  rune.group.disable(GROUP)
end

-- Single loader row.
say("v" .. VERSION .. " loaded (basicAliases or basic for help)")
