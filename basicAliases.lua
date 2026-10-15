-- Filename: eljayPlugins/basicAliases.lua
-- Purpose: Basic Aliases Generalized for all Characters
-- Version: 2.10
-- Date: 2026-Oct-15
--
-- Changes in 2.10:
--   * argument aliases are plain rune.alias.exact rows (Rune appends typed arguments natively),
--     so the regex helper is gone; no block-comment markers are used in comments
--
-- Changes in 2.9:
--   * brought to standard: basicAliases command (short alias basic) with help, trigger on/off,
--     debug toggle and loader line; triggers now live in one group so on/off covers them all

-- How it works
--  * Triggers: auto-responses to game text, plus gag triggers (gag = true) for noisy lines.
--    Yes/no questions arrive as prompts (no line ending), so those use prompt_trigger().
--    All triggers belong to the "basicAliases" group; `basicAliases on|off` switches the group.
--  * Aliases: one row each with rune.alias.exact; Rune appends anything typed after the alias
--    ("qs" -> "quest status", "qs 3" -> "quest status 3"). Helper plan() wraps skill aliases.
--    Aliases are always active; only the triggers are toggled.
--  * Commands are chained with ";" inside a single rune.send string.
--  * Commands: `basicAliases` (short alias `basic`) shows help; `on|off` toggles the triggers;
--    `debug on|off` toggles debug messages (default off).

local NAME, VERSION, GROUP = "basicAliases", "2.10", "basicAliases"
local debugOn = false

-- Output helpers

local function paint(color, text)
  local ok, r = pcall(function() return rune.style[color](text) end)
  return (ok and type(r) == "string") and r or text
end

local function say(msg) rune.echo(paint("cyan", "[" .. NAME .. "] ") .. msg) end
local function dbg(msg) if debugOn then say(paint("yellow", "debug: ") .. msg) end end

-- Helpers

-- auto-response: when the pattern matches, send cmd (on = "prompt" for partial lines)
local function auto(pattern, cmd, on)
  rune.trigger.regex(pattern, function() dbg("trigger -> " .. cmd); rune.send(cmd) end, { group = GROUP, on = on })
end

-- text that may arrive as a prompt (partial line, no newline) or as a full line
local function prompt_trigger(pattern, cmd) auto(pattern, cmd, "prompt"); auto(pattern, cmd) end

-- hide matching lines
local function gag(pattern) rune.trigger.regex(pattern, function() dbg("gagged a line") end, { group = GROUP, gag = true }) end

local function plan(key, skill) rune.alias.exact(key, "plan '" .. skill .. "'") end
local function ganuk(m) rune.send("shop buy " .. m[1] .. ";down;give " .. m[1] .. " ganuk") end

-- Triggers

-- Auto-responses
auto("^A sudden, strong gust of wind knocks you to the ground!$", "stand")
auto("^A tangle vine twists around your feet, preventing you from leaving!$", "attack tangle")
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
rune.alias.regex("^forge +(.+)$", function(m) rune.send("put " .. m[1] .. " forge;close forge") end)

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
rune.alias.regex("^rrr +(.+)$", function(m) rune.send("rem notes;read research buy " .. m[1] .. ";bind thesis notes;hold notes") end)

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
rune.alias.regex("^setslave +(.+)$", function(m) rune.send("clan security set " .. m[1] .. " alliancetalk chatlog gohall log where") end)
rune.alias.exact("ff", "form follow")
rune.alias.exact("fss", "form structure shield")
rune.alias.exact("fr", "form rep")
rune.alias.exact("fw", "form where")
rune.alias.exact("wc", "who sortbyclan")  -- 'wh' conflicted, renamed
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


-- Command: basicAliases (short alias: basic)

local function help()
  local ok, H = pcall(require, "helpstyle")
  local shown = ok and type(H) == "table" and pcall(function()
    H.title(NAME)
    H.section("Commands")
    H.line("basicAliases", "show this help")
    H.line("basicAliases on|off", "turn the auto-response and gag triggers on or off")
    H.line("basicAliases debug on|off", "show or hide debug messages")
    H.section("Short alias")
    H.line("basic", "same as basicAliases")
    H.foot("v" .. VERSION .. "  triggers=" .. (rune.group.is_enabled(GROUP) and "on" or "off") .. " debug=" .. (debugOn and "on" or "off"))
  end)
  if not shown then
    say("v" .. VERSION .. "  basicAliases | basicAliases on|off | basicAliases debug on|off | basic")
  end
end

local function command(m)
  local a, b = string.lower(m[1] or ""):match("^(%S*)%s*(%S*)")
  if a == "" or a == "help" then
    help()
  elseif a == "on" or a == "off" then
    if a == "on" then rune.group.enable(GROUP) else rune.group.disable(GROUP) end
    say("triggers " .. a)
  elseif a == "debug" and (b == "on" or b == "off") then
    debugOn = (b == "on")
    say("debug " .. b)
  else
    say("unknown option; type basicAliases or basic for help")
  end
end

rune.alias.regex("^(?:basicAliases|basic)(?: +(.*))?$", command)

say("v" .. VERSION .. " loaded (basicAliases or basic for help)")