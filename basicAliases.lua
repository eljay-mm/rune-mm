-- Filename: eljayPlugins/basicAliases.lua
-- Purpose: Basic Aliases Generalized for all Characters
-- Version: 2.0
-- Date: 2026-Oct-09

--[[ Triggers ]]--

-- Auto-responses
rune.trigger.regex("^A sudden, strong gust of wind knocks you to the ground!$", function()
  rune.send("stand")
end)

rune.trigger.regex("^A tangle vine twists around your feet, preventing you from leaving!$", function()
  rune.send("attack tangle")
end)

rune.trigger.regex("^Do you wish to join this formation (y/N)?$", function()
  rune.send("y")
end)

rune.trigger.regex("^     An open coffin is covered in dust here.$", function()
  rune.send("enter coffin")
end)

rune.trigger.regex("^Divusmors vanishes with a clap of thunder!$", function()
  rune.send("get all.loot; get all lootable")
end)

-- Gag triggers (suppress output)
rune.trigger.regex("^     a magical belt pouch \\(new\\)$", function() end, { omit = true })
rune.trigger.regex("^An armor-plated harmonica holder squonks discordantly, displeased by your ", function() end, { omit = true })
rune.trigger.regex("^     a woven gold bag \\(new\\)$", function() end, { omit = true })
rune.trigger.regex("^     a yellow silk bag \\(new\\)$", function() end, { omit = true })
rune.trigger.regex("^     a red silk bag \\(new\\)$", function() end, { omit = true })
rune.trigger.regex("^     a blue silk bag \\(new\\)$", function() end, { omit = true })
rune.trigger.regex("^     a black silk bag \\(new\\)$", function() end, { omit = true })

--[[ Alias Groups ]]--

-- Movement aliases
rune.alias.exact("mp", "mount pegasus")
rune.alias.exact("dism", "dismount pegasus;hitch pegasus post")

rune.alias.regex("^nrin$", function()
  rune.send([[open south
.2s2(se)5s
unlock south
open south
s
close north
lock north]])
end)

rune.alias.regex("^nrout$", function()
  rune.send([[unlock north
open north
n
close south
lock south
.5n2(nw)n
open north
.n]])
end)

rune.alias.regex("^pcin$", function()
  rune.send([[unlock west
open west
west
close east
lock east
.n2e2s4e12s8w
enter portal
.s(nw)2n(ne)n4e4n6w]])
end)

rune.alias.regex("^pcout$", function()
  rune.send([[unlock west
open west
west
close east
lock east
.n2e2s4e12s8w
enter portal
.s(nw)2n(ne)n4e4n6w]])
end)

rune.alias.exact("ep", "enter portal")

-- Basics/Utility aliases
rune.alias.exact("l1", "look in 1.trunk")
rune.alias.exact("l2", "look in 2.trunk")
rune.alias.exact("l3", "look in 3.trunk")
rune.alias.exact("l4", "look in 4.trunk")
rune.alias.exact("l5", "look in tanbluck")
rune.alias.exact("lg", [[look in 'a goldweave bag']])
rune.alias.exact("le", [[look in 'a bag embroidered with silver runes']])
rune.alias.exact("lr", [[look in 'an earthen bag']])
rune.alias.exact("lm", [[look in 'a massive iron chest']])
rune.alias.exact("lb", "look in bag")
rune.alias.exact("lp", "look in pouch")
rune.alias.exact("lt", "look in trunk")

rune.alias.regex("^forge *(.*)$", function(m)
  rune.send("put " .. (m[1] or "") .. " forge;close forge")
end)

rune.alias.regex("^lc *$", function()
  rune.send("look in corpse;look in 2.corpse;look in 3.corpse")
end)

rune.alias.exact("ta", "take all corpse")
rune.alias.exact("tl", "take all lootable")
rune.alias.exact("tc", "take crystal")

rune.alias.exact("ce", "chat enter")
rune.alias.exact("cx", "chat exit")

rune.alias.exact("cen", "check newstat")
rune.alias.exact("ceb", "check equipment bindings")
rune.alias.exact("cem", "check equipment missing")
rune.alias.exact("cev", "check equipment value")
rune.alias.exact("r", "rest")
rune.alias.exact("st", "stand")

rune.alias.exact("sm0", "set automap off")
rune.alias.exact("sm1", "set automap on")

rune.alias.regex("^lor *(.*)$", function(m)
  rune.send("locker remove " .. (m[1] or ""))
end)

rune.alias.exact("los", "locker store ")  -- Note: add item manually
rune.alias.exact("ll", "locker list")
rune.alias.exact("ls", "locker survey")

rune.alias.exact("sc", "scan")
rune.alias.exact("su", "survey")
rune.alias.exact("mr", "mail receive")
rune.alias.exact("dep", "bank deposit all")
rune.alias.exact("wd20", "bank withdraw 20000")
rune.alias.exact("wd50", "bank withdraw 50000")

rune.alias.exact("bjh", "say hit")
rune.alias.exact("bjs", "give gambling dealer")
rune.alias.exact("bjy", "say stay")
rune.alias.exact("siw", "sayto illusionist i will")
rune.alias.exact("pr", "sayto orc yes;nod orc")
rune.alias.exact("sr", "sayto representative yes")

rune.alias.exact("cw", "clan where")
rune.alias.exact("hall", "clan gohall")
rune.alias.exact("ps", "pursuer")
rune.alias.exact("ff *", function()  -- Note: args appended
  rune.send("form follow ")  -- append target
end)
rune.alias.exact("fss", "form structure shield")

rune.alias.exact("wc", "who sortbyclan")  -- Note: 'wh' conflicted, renamed
rune.alias.exact("whol", "who 1 19")
rune.alias.exact("who1", "who 20 60")
rune.alias.exact("who2", "who 61 120")
rune.alias.exact("who3", "who 121 180")
rune.alias.exact("who4", "who 181 240")
rune.alias.exact("whon", "who novice")
rune.alias.exact("wk", "who keep")

rune.alias.exact("wd20", "bank withdraw 20000")
rune.alias.exact("wd50", "bank withdraw 50000")

rune.alias.exact("hs", "help status")
rune.alias.exact("cs", "crystal last")

rune.alias.exact("wd20", "bank withdraw 20000")  -- duplicate, safe
rune.alias.exact("wd50", "bank withdraw 50000")  -- duplicate, safe

-- Regex aliases with optional targets
rune.alias.regex("^([ ]+(.+))?$", function(m)  -- 'b' alone or 'b target'
  rune.send("bash " .. (m[1] or ""))
end)

rune.alias.regex("^gslit([ ]+(.+))?$", function(m)
  local tgt = m[1] or ""
  rune.send([[take "a garrote" pouch
use "a garrote" ]] .. tgt .. [[
rem "a garrote"
put "a garrote" pouch]])
end)

rune.alias.regex("^h([ ]+(.+))?$", function(m)
  rune.send("hold " .. (m[1] or ""))
end)

rune.alias.regex("^f([ ]+(.+))?$", function(m)
  rune.send("flee " .. (m[1] or ""))
end)

rune.alias.regex("^ql$", function()
  rune.send("quest list")
end)

rune.alias.regex("^qc([ ]+(.+))?$", function(m)
  rune.send("quest complete " .. (m[1] or ""))
end)

rune.alias.regex("^qi([ ]+(.+))?$", function(m)
  rune.send("quest identify " .. (m[1] or ""))
end)

rune.alias.regex("^qr$", function()
  rune.send("quest request")
end)

rune.alias.regex("^qrr$", function()
  rune.send("quest request rewarding")
end)

rune.alias.regex("^qs([ ]+(.+))?$", function(m)
  rune.send("quest status " .. (m[1] or ""))
end)

rune.alias.regex("^rl([ ]+(.+))?$", function(m)
  rune.send("recall list " .. (m[1] or ""))
end)

rune.alias.regex("^wor$", function()
  rune.send([[cast 'word of recall']])
end)

rune.alias.regex("^sim$", function()
  rune.send("say I'm ready to move on")
end)

rune.alias.regex("^al$", function()
  rune.send("auction list")
end)

rune.alias.regex("^ab([ ]+(.+))?$", function(m)
  rune.send("auction bid " .. (m[1] or ""))
end)

rune.alias.regex("^ai([ ]+(.+))?$", function(m)
  rune.send("auction identify " .. (m[1] or ""))
end)

rune.alias.regex("^aw([ ]+(.+))?$", function(m)
  rune.send("alliance where " .. (m[1] or ""))
end)

rune.alias.regex("^if([ ]+(.+))?$", function(m)
  rune.send("inventory search " .. (m[1] or ""))
end)

-- Lua-function aliases (complex logic from XML)
rune.alias.exact("cc", function()
  local n = rune.get_global_var("name")
  if n then
    rune.send("give tadamir" .. n .. " Tadamir")
    rune.send("drop crystalquest" .. n)
    rune.send("sac crystalquest" .. n)
  end
end)

rune.alias.exact("cl", function()
  local n = rune.get_global_var("name")
  if n then
    rune.send("look crystalquest" .. n)
  end
end)

rune.alias.regex("^vs *(.*)$", function(m) rune.send("vendor search " .. (m[1] or "")) end)
rune.alias.regex("^vw *(.*)$", function(m) rune.send("vendor where " .. (m[1] or "")) end)