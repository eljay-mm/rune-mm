-- Filename: eljayPlugins/druidSpellTLAs.lua
-- Purpose: Druid Spells with Three Letter Acronyms
-- Version: 2.0 (converted from yDruidSpells.xml)
-- Date: 2026-Oct-09

-- Evoke Magma / Invoke Magma
rune.alias.regex("^dcf(?:[ ]+(.+))?$", function(m) rune.send("evoke magma " .. (m[1] or "")) end)
rune.alias.regex("^dfs(?:[ ]+(.+))?$", function(m) rune.send("invoke magma " .. (m[1] or "")) end)

-- Cure Series (Minerals / Ice / Salt)
rune.alias.regex("^dcs(?:[ ]+(.+))?$", function(m) rune.send("evoke minerals " .. (m[1] or "")) end)
rune.alias.regex("^dho(?:[ ]+(.+))?$", function(m) rune.send("evoke ice " .. (m[1] or "")) end)
rune.alias.regex("^dcp(?:[ ]+(.+))?$", function(m) rune.send("evoke salt " .. (m[1] or "") .. " " .. (m[1] or "")) end)
rune.alias.regex("^dcd(?:[ ]+(.+))?$", function(m) rune.send("invoke salt " .. (m[1] or "")) end)

-- Ooze Series (Double Target / Single Target)
rune.alias.regex("^doo(?:[ ]+(.+))?$", function(m) rune.send("evoke ooze " .. (m[1] or "") .. " " .. (m[1] or "")) end)
rune.alias.regex("^deo(?:[ ]+(.+))?$", function(m) rune.send("evoke ooze " .. (m[1] or "") .. " " .. (m[1] or "")) end)
rune.alias.regex("^dss(?:[ ]+(.+))?$", function(m) rune.send("invoke ooze " .. (m[1] or "")) end)

-- Vacuum / Air Series
rune.alias.regex("^dblink(?:[ ]+(.+))?$", function(m) rune.send("invoke vacuum " .. (m[1] or "")) end)
rune.alias.regex("^dev(?:[ ]+(.+))?$", function(m) rune.send("evoke vacuum " .. (m[1] or "")) end)
rune.alias.regex("^dle(?:[ ]+(.+))?$", function(m) rune.send("invoke air " .. (m[1] or "")) end)
rune.alias.regex("^dcy(?:[ ]+(.+))?$", function(m) rune.send("evoke air " .. (m[1] or "") .. " " .. (m[1] or "")) end)

-- Radiance / Smoke / Water
rune.alias.regex("^dre(?:[ ]+(.+))?$", function(m) rune.send("evoke radiance " .. (m[1] or "")) end)
rune.alias.regex("^dbl(?:[ ]+(.+))?$", function(m) rune.send("evoke smoke " .. (m[1] or "") .. " " .. (m[1] or "")) end)
rune.alias.regex("^dwa(?:[ ]+(.+))?$", function(m) rune.send("evoke water " .. (m[1] or "")) end)
rune.alias.regex("^drf(?:[ ]+(.+))?$", function(m) rune.send("invoke water " .. (m[1] or "")) end)

-- Steam / Ash / Life / Dust
rune.alias.regex("^dha(?:[ ]+(.+))?$", function(m) rune.send("evoke steam " .. (m[1] or "") .. " " .. (m[1] or "")) end)
rune.alias.regex("^dpd(?:[ ]+(.+))?$", function(m) rune.send("invoke steam " .. (m[1] or "")) end)
rune.alias.regex("^dpn(?:[ ]+(.+))?$", function(m) rune.send("invoke ash " .. (m[1] or "")) end)
rune.alias.regex("^dhb(?:[ ]+(.+))?$", function(m) rune.send("invoke life " .. (m[1] or "")) end)
rune.alias.regex("^dcb(?:[ ]+(.+))?$", function(m) rune.send("invoke dust " .. (m[1] or "")) end)

-- Earth / Fire / Ether
rune.alias.regex("^dwe(?:[ ]+(.+))?$", function(m) rune.send("evoke earth " .. (m[1] or "") .. " " .. (m[1] or "")) end)
rune.alias.regex("^dhs(?:[ ]+(.+))?$", function(m) rune.send("invoke earth " .. (m[1] or "")) end)
rune.alias.regex("^dfi(?:[ ]+(.+))?$", function(m) rune.send("evoke fire " .. (m[1] or "") .. " " .. (m[1] or "")) end)
rune.alias.regex("^dsa(?:[ ]+(.+))?$", function(m) rune.send("invoke fire " .. (m[1] or "")) end)
rune.alias.regex("^dsh(?:[ ]+(.+))?$", function(m) rune.send("invoke ether " .. (m[1] or "")) end)
rune.alias.regex("^dlc(?:[ ]+(.+))?$", function(m) rune.send("evoke ether " .. (m[1] or "")) end)

-- Lightning
rune.alias.regex("^dli(?:[ ]+(.+))?$", function(m) rune.send("evoke lightning " .. (m[1] or "") .. " " .. (m[1] or "")) end)