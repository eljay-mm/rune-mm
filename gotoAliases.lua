-- Filename: eljayPlugins/gotoAliases.lua
-- Purpose: Aliases to run to gates, quest masters, banks, post offices and other places in the town you are in.
-- Version: 1.9
-- Date: 2026-Oct-19
--
--[[ Todo:
- insert planning notes here between revisions.
--]]
--
-- Changelog:
--   1.9  Remove goto next and goto custom (stored sends, defaults and their store key are gone).
--   1.8  Help no longer lists the custom sends (the footer still shows how many there are).
--   1.7  Remove all run aliases and helpers (the game's own run command is used as is); destination tables dropped;
--        handle_goto is now a local function.
--
-- How it works:
--   * Inspired by the MUSHclient plugin by Oona.
--   * Subscribes to GMCP Room.Info and remembers the latest room, zone and plane to work out which town you are in.
--   * One regex alias catches "goto ..." and "gotoAliases ..." and runs the matching subcommand.
--   * goto north|east|south|west|gate runs the mapper to that town exit.
--   * goto qm, rep, post, bank, reagents, lockers and crystal run the mapper to that spot,
--     and perform the action (quest request, sayto representative yes, shop buy 1) when you are already there.
--   * goto pursuer runs leg by leg towards the Orc Pursuer in Wroth; each room change continues the trip.
--   * goto where shows what the plugin sees (room, zone, plane, town) and where the load time went.
--   * Saves the on/off setting with rune.store; no config files are written.
--
-- Commands (type without "/"; "goto" is a short alias for "gotoAliases"):
--   gotoAliases | goto                   show this help
--   goto list                            show what you can goto from here
--   goto where                           show detected room, zone, plane, town and load breakdown
--   goto north|east|south|west|gate      run to that exit of the current town
--   goto qm | rep | post | bank          quest master, tourist rep, post office, bank
--   goto reagents | lockers              reagent shop, lockers
--   goto crystal                         crystal quest office in Rune
--   goto pursuer | goto cancel           run to the Orc Pursuer / stop after this leg
--   goto on|off                          enable or disable the plugin
--   goto debug [on|off]                  toggle debug messages (default off)

local function now()
  local ok, t = pcall(os.clock)
  return ok and t or 0
end
local T0 = now()

-- Load-time bookkeeping: each Rune-facing step at startup is timed and shown by "goto where".
local parts = {}
local function timed(name, fn)
  local t = now()
  fn()
  parts[#parts + 1] = { name, (now() - t) * 1000 }
end

local PLUGIN_NAME, SHORT, VERSION = "gotoAliases", "goto", "1.9"
local STORE_KEY = "gotoAliases.settings"
local GOTO_PATTERN = "^(goto(?:Aliases)?(?:\\s+.*)?)$"  -- captures the whole typed line

local style = rune.style

-- ---------------------------------------------------------------- helpers
local function paint(color, text)
  local fn = style[color]
  if type(fn) == "function" then return fn(text) end
  return text
end

local function say(msg) rune.echo(paint("cyan", "[" .. PLUGIN_NAME .. "] ") .. msg) end

-- helpstyle is loaded the first time help is shown (false = unavailable).
local helpstyle
local function get_help_lib()
  if helpstyle == nil then
    local ok, mod = pcall(require, "helpstyle")
    helpstyle = ok and mod or false
  end
  return helpstyle
end

local function send(cmd) rune.send(cmd) end
-- Run through the alias layer (needed for "mapper goto <room>"); falls back to a plain send.
local function execute(cmd)
  for _, f in ipairs({ rune.execute, rune.exec }) do
    if type(f) == "function" and pcall(f, cmd) then return end
  end
  send(cmd)
end

-- ---------------------------------------------------------------- state
local function load_settings()
  local ok, s = pcall(rune.store.get, STORE_KEY)
  if ok and type(s) == "table" then return s end
  return {}
end

local enabled = true
timed("settings", function() enabled = load_settings().enabled ~= false end)

local DEBUG = false
local running_to_pursuer, leg_sent = false, false
local cur = { num = nil, zone = nil, plane = nil }  -- latest GMCP Room.Info
local events_seen = 0
local load_ms = 0
local alias_mode = "none"
local handle_goto  -- defined below; declared here so the exact-alias fallback can call it

local function dbg(msg) if DEBUG then say(paint("gray", "debug: " .. msg)) end end

local function save_settings()
  local ok, err = pcall(rune.store.set, STORE_KEY, { enabled = enabled })
  if not ok then say("could not save settings: " .. tostring(err)) end
end

-- ---------------------------------------------------------------- data
local zone_key_map = {}
local function zones(key, ...) for _, z in ipairs({ ... }) do zone_key_map[z] = key end end
zones("rune", "Towne of Rune", "Runic Castle", "Player Homes - Rune", "Rune Condominiums", "Rune Estates", "Rune Realty", "Temple Crypt",
  "Temple of Sumter", "Winterborn Mansion", "Focault Magic Equipment Company", "Focault's Residence", "Van Pelt's Emporium")
zones("sigil", "Sigil", "The Sigilian Stronghold", "Sigil Castle", "Player Homes - Sigil", "Sigil Condominiums", "Sigil Realty")
zones("newrigel", "The Towne of New Rigel", "New Rigel Condominiums", "New Rigel Gardens", "New Rigel Realty", "Player Homes - New Rigel")
zones("xaventry", "The Towne of Xaventry", "The Xaventry Stronghold", "Xaventry Condominiums", "Xaventry Realty")
zones("tellerium", "Tellerium", "Player Homes - Tellerium", "Tellerium Condominiums", "Tellerium Realty")
zones("templeton", "Templeton", "The Templetonian Stronghold")
zones("piratescove", "Pirate's Cove", "Pirate's Cove Realty", "Player Homes - Pirates Cove")
zones("decara", "Towne of Decara", "Decara Condominiums", "Decara Realty", "Player Homes - Decara")
zones("vir", "Vir", "Vir Condominiums")
zones("mandrake", "Mandrake Woods", "Shadow Castle")
zones("vospire", "Vospire"); zones("diocletian", "Palace of Diocletian"); zones("lowangen", "Lowangen"); zones("maldra", "Maldra Keep")
zones("thorn", "Desert Thorn"); zones("gilvery", "Gilvery"); zones("runeforest", "Rune Forest"); zones("newkolvir", "New Kolvir")
zones("avarice", "Dungeon Avarice"); zones("wroth", "Dungeon Wroth"); zones("hillgiants", "A Hill Giant Refuge"); zones("toa", "Tower of Art")
zones("jmc", "The Joint Magical Consortium"); zones("emperorscrossroads", "Emperor's Crossroads"); zones("shlarksh", "Shlarksh")
zones("vesuvius", "Mount Vesuvius"); zones("takhtin", "Takhtin"); zones("dorathon", "The Fishing Village of Dorathon")
zones("winton", "The Hamlet of Winton"); zones("frostgiantskeep", "Forst Giant's Keep", "Frost Giant's Keep"); zones("deceit", "Dungeon Deceit")
zones("vandemaar", "Vandemaar's Keep"); zones("xalt", "Xalt, Unseelie Outpost"); zones("mulakanathos", "The Village of Mulakanathos")
zones("gorth", "Gorth"); zones("travelersretreat", "Traveler's Retreat"); zones("tavernoftheboars", "Tavern of the Boars")
zones("twinmoons", "Inn of the Twin Moons"); zones("lonelydragon", "The Lonely Dragon Inn"); zones("cenotaphy", "The Indestructible Cenotaphy")
zones("atlantis", "Atlantis"); zones("naulitas", "Naulitas"); zones("teolaven", "The Mountain Village of Teolaven")

local locations = {}
local function loc(key, continent, north, south, east, west, default_gate, qm, rep)
  locations[key] = { north = north, south = south, east = east, west = west, qm = qm, rep = rep, continent = continent,
    default_gate = default_gate or north or south or east or west }
end
-- key, continent, north, south, east, west, default_gate, qm, rep
loc("rune", "sepharia", "10435", "2832529", "2816440", "2809518", "2816440", "31323")
loc("sigil", "auryn", "3881069", "3908670", nil, nil, "3881069", "28450", "27890")
loc("newrigel", "sepharia", "2315135", "2358832", nil, nil, "2315135", "62566", "62036")
loc("xaventry", "sepharia", "2066541", "2105636", "2084947", "2087227", "2105636", "73968", "73100")
loc("tellerium", "avros", "2638058", "2656450", nil, nil, "2638058", "41852", "41790")
loc("templeton", "avros", "47337", nil, nil, "2309054", "2309054", "47421")
loc("piratescove", "beltane", "3288425", "3318326", "3295329", "3304508", "3304508")
loc("vospire", "auryn", nil, nil, "3765964", "3768246", "3765964")
loc("diocletian", "auryn", nil, "4189387")
loc("lowangen", "sepharia", nil, "2030293")
loc("maldra", "beltane", nil, "3573738", nil, nil, "3573738", "67947")
loc("thorn", "sepharia", nil, nil, "1807082", "1788665")
loc("decara", "underground", nil, nil, "11125213", nil, nil, "116546")
loc("vir", "underground", nil, nil, "12426873")
loc("gilvery", "sepharia", nil, nil, "1880596", "1880584", "1880584")
loc("runeforest", "sepharia", nil, nil, "2625535")
loc("newkolvir", "sepharia", nil, nil, nil, "3324605")
loc("avarice", "sepharia", "2377105")
loc("mandrake", "sepharia", nil, nil, "1900988")
loc("wroth", "sepharia", "1960870")
loc("hillgiants", "sepharia", nil, nil, nil, "2602424")
loc("toa", "sepharia", nil, nil, nil, "1547405")
loc("jmc", "sepharia", "1586161")
loc("emperorscrossroads", "auryn", nil, "4072040")
loc("shlarksh", "auryn", "3823947", "3835453")
loc("vesuvius", "auryn", "3729129")
loc("takhtin", "auryn", nil, "3844854")  -- technically beltane but runnable from auryn
loc("dorathon", "avros", nil, "2152729", "2145833", "2143525", "2143525")
loc("winton", "avros", "1964016")
loc("frostgiantskeep", "avros", nil, "1957223")
loc("deceit", "beltane", nil, "3525388")
loc("vandemaar", "beltane", "3925733")
loc("xalt", "beltane", nil, "3831487")
loc("mulakanathos", "beltane", "3900588")
loc("gorth", "beltane", nil, nil, nil, "3875363")
loc("travelersretreat", "sepharia", nil, nil, nil, "2558911")
loc("tavernoftheboars", "sepharia", nil, "2085131")
loc("twinmoons", "sepharia", nil, "1765641")
loc("lonelydragon", "sepharia", nil, "2669134")
loc("teolaven", "auryn", nil, nil, nil, "328834")
loc("cenotaphy", "beltane", nil, "3916564")
loc("atlantis", "ocean", "18892")
loc("naulitas", "ocean", nil, "4137902")
loc("cogworkcity", "sug", "17452076")
loc("renn", "sug", "17150349")

-- Gate room number -> town key, built once so Alyria lookups are a table read instead of a scan.
local gate_index = {}
for key, l in pairs(locations) do
  for _, d in ipairs({ "north", "south", "east", "west" }) do
    if l[d] and not gate_index[l[d]] then gate_index[l[d]] = key end
  end
end

local function service(field, rows) for key, n in pairs(rows) do locations[key][field] = n end end
service("post", { rune = "10560", sigil = "28083", diocletian = "28988", newrigel = "62584", xaventry = "73154", tellerium = "41703",
  templeton = "46556", piratescove = "29943", vospire = "40267", lowangen = "15961", maldra = "68121" })
service("bank", { rune = "10592", sigil = "28014", diocletian = "28985", newrigel = "62529", xaventry = "73970", tellerium = "41702",
  templeton = "46001", piratescove = "29914", vospire = "40282", lowangen = "16072", maldra = "68067", decara = "116102" })
service("reagents", { rune = "10554", sigil = "28003", diocletian = "28987", newrigel = "62576", xaventry = "73745", templeton = "46405",
  piratescove = "29915", vospire = "39918", lowangen = "16062", maldra = "68111" })
service("locker", { rune = "10558", sigil = "28034", diocletian = "28984", newrigel = "62542", xaventry = "73156", tellerium = "41710",
  templeton = "45967", piratescove = "29894", vospire = "40266", lowangen = "16232", vir = "146151", decara = "116084" })

-- ---------------------------------------------------------------- location (GMCP Room.Info cache)
local function zone_key()
  if cur.zone == "Alyria" then return gate_index[cur.num] end
  return zone_key_map[cur.zone]
end

local function have_room()
  if cur.num then return true end
  say("No room data yet. Move one room, then try again (goto where shows what has arrived).")
  return false
end

local function destination(field)
  local key = zone_key()
  return key and locations[key][field] or nil
end

local function names_of(t)
  local out = {}
  if type(t) == "table" then for k in pairs(t) do out[#out + 1] = tostring(k) end end
  table.sort(out)
  return #out > 0 and table.concat(out, ", ") or "(none)"
end

local function show_where()
  say("events=" .. events_seen .. "  room=" .. tostring(cur.num) .. "  zone=" .. tostring(cur.zone)
    .. "  plane=" .. tostring(cur.plane) .. "  town=" .. tostring(zone_key()))
  if events_seen == 0 then
    say("No Room.Info received yet; move one room.")
  elseif cur.zone and cur.zone ~= "Alyria" and not zone_key_map[cur.zone] then
    say("Zone '" .. cur.zone .. "' is not in the zone map (add it to the zones() table).")
  end
  local bits = {}
  for _, p in ipairs(parts) do bits[#bits + 1] = p[1] .. "=" .. string.format("%.1f", p[2]) end
  say("load " .. load_ms .. "ms: " .. table.concat(bits, "  "))
  say("aliases=" .. alias_mode)
end

-- ---------------------------------------------------------------- goto actions
local function goto_field(field, label)
  if not have_room() then return end
  local n = destination(field)
  if n then dbg("mapper goto " .. n); execute("mapper goto " .. n)
  else say("There is no " .. label .. " for this location.") end
end

local function goto_or_act(field, label, action)
  if not have_room() then return end
  local n = destination(field)
  if not n then say("There is no " .. label .. " for this location."); return end
  if cur.num == n then send(action) else execute("mapper goto " .. n) end
end

local function show_locations()
  if not have_room() then return end
  local key = zone_key()
  if not key then say("There are no goto options from this location."); return end
  local l, out = locations[key], {}
  for _, f in ipairs({ "north", "south", "east", "west", "qm", "rep", "post", "bank", "reagents", "locker" }) do
    if l[f] then out[#out + 1] = (f == "locker") and "lockers" or f end
  end
  say("You can goto: " .. table.concat(out, ", "))
end

local function goto_crystal()
  if not have_room() then return end
  local key = zone_key()
  if key == "rune" then
    if cur.num == "10407" then send("shop buy 1") else execute("mapper goto 10407") end
  elseif cur.zone == "Alyria" then send("run rune")
  elseif key == "xaventry" or key == "newrigel" then execute("mapper goto " .. locations[key].south)
  end
end

-- ---------------------------------------------------------------- orc pursuer
local function stop_pursuer() running_to_pursuer, leg_sent = false, false end

local function pursuer_step(initial)
  if not running_to_pursuer then return end
  local key = zone_key()
  dbg("pursuer step key=" .. tostring(key) .. " zone=" .. tostring(cur.zone) .. " room=" .. tostring(cur.num))

  if key == nil then
    if cur.zone == "Alyria" then
      if initial then say("Get to a gate to start running to the pursuer.") end
    else
      say("You don't know how to get there from here."); stop_pursuer()
    end
    return
  end

  if key == "wroth" then
    if initial and cur.num == "7461" then send("sayto orc yes"); send("nod orc"); stop_pursuer()
    elseif cur.num == "7682" then send("enter portal"); send("south"); stop_pursuer()
    elseif initial or cur.num == "1960870" then execute("mapper goto 7682") end
    return
  end

  local l = locations[key]
  if l.continent == "beltane" then say("You can't get there from Beltane."); stop_pursuer(); return end

  local target = (l.continent == "sepharia") and "run wroth" or "run rune"
  if cur.zone == "Alyria" then
    if not leg_sent then leg_sent = true; send(target) end  -- once per leg, not once per room on the road
  else
    leg_sent = false
    if initial then
      if l.default_gate then execute("mapper goto " .. l.default_gate)
      else say("Make your way to the gate outside to run to the pursuer.") end
    end
  end
end

local function goto_pursuer()
  if not have_room() then return end
  local key = zone_key()
  if (key == nil and cur.zone ~= "Alyria") or (key and locations[key].continent == "beltane") then
    say("You can't get to the orc pursuer from where you are!"); return
  end
  running_to_pursuer, leg_sent = true, false
  say("Running to the Orc Pursuer. 'goto cancel' stops after the current leg.")
  pursuer_step(true)
end

-- ---------------------------------------------------------------- help
local function show_help()
  local H = get_help_lib()
  local footer = "v" .. VERSION .. "  enabled=" .. tostring(enabled) .. " debug=" .. tostring(DEBUG)
    .. " load=" .. load_ms .. "ms"
  local rows = {
    { "gotoAliases | goto", "show this help" },
    { "goto list", "what you can goto from here" },
    { "goto where", "show detected room, zone, plane, town and load breakdown" },
    { "goto north|east|south|west|gate", "run to that exit of the town" },
    { "goto qm | rep | post | bank", "quest master, tourist rep, post office, bank" },
    { "goto reagents | lockers", "reagent shop, lockers" },
    { "goto crystal", "crystal quest office in Rune" },
    { "goto pursuer | cancel", "run to the Orc Pursuer / stop after this leg" },
    { "goto on|off", "enable or disable the plugin" },
    { "goto debug [on|off]", "toggle debug messages" },
  }
  if H then
    rune.echo(H.title("Goto Aliases  (alias: goto)"))
    rune.echo(H.section("Commands"))
    for _, r in ipairs(rows) do rune.echo(H.line(r[1], r[2])) end
    rune.echo(H.foot(footer))
  else
    say("Goto Aliases  (alias: goto)")
    for _, r in ipairs(rows) do rune.echo("  " .. r[1] .. "  -  " .. r[2]) end
    rune.echo(footer)
  end
end

local function set_enabled(on)
  if enabled == on then
    say(on and paint("green", "already on") or paint("red", "already off"))
    return
  end
  enabled = on
  save_settings()
  if not on then stop_pursuer() end
  say(on and paint("green", "on") or paint("red", "off"))
end

local function set_debug(on)
  if on == nil then on = not DEBUG end
  DEBUG = on
  say("debug " .. (DEBUG and paint("green", "on") or paint("red", "off")))
end

-- ---------------------------------------------------------------- dispatcher
-- Each action receives the rest of the typed line (used by debug).
local actions = {
  help = function() show_help() end,
  list = function() show_locations() end,
  where = function() show_where() end,
  north = function() goto_field("north", "north gate") end,
  south = function() goto_field("south", "south gate") end,
  east = function() goto_field("east", "east gate") end,
  west = function() goto_field("west", "west gate") end,
  gate = function() goto_field("default_gate", "gate") end,
  qm = function() goto_or_act("qm", "quest master", "quest request 'rewarding'") end,
  rep = function() goto_or_act("rep", "town rep", "sayto representative yes") end,
  post = function() goto_field("post", "post office") end,
  bank = function() goto_field("bank", "bank") end,
  reagents = function() goto_field("reagents", "reagent shop") end,
  lockers = function() goto_field("locker", "lockers") end,
  crystal = function() goto_crystal() end,
  pursuer = function() goto_pursuer() end,
  cancel = function() say("You will stop when this leg completes."); stop_pursuer() end,
  on = function() set_enabled(true) end,
  off = function() set_enabled(false) end,
  debug = function(rest)
    local v = (rest or ""):lower()
    if v == "on" then set_debug(true) elseif v == "off" then set_debug(false) else set_debug(nil) end
  end,
}
local SUB_ALIAS = { reagent = "reagents", locker = "lockers" }
-- Actions that stay available while the plugin is off.
local ALWAYS = { help = true, on = true, off = true, debug = true, where = true }

-- Find the typed text in whatever the alias callback hands over (a string, a capture list, or a context table).
local function pick_text(v, depth)
  if type(v) == "string" then return v end
  depth = depth or 0
  if type(v) ~= "table" or depth > 2 then return nil end
  local best
  for i = 1, 9 do if type(v[i]) == "string" then best = v[i] end end
  if best then return best end
  for _, k in ipairs({ "line", "input", "text", "match", "args" }) do
    if type(v[k]) == "string" then return v[k] end
  end
  for _, k in ipairs({ "captures", "groups", "matches" }) do
    local r = pick_text(v[k], depth + 1)
    if r then return r end
  end
  return nil
end

local function typed_text(a, b)
  local t = pick_text(a) or pick_text(b)
  return t or "", t ~= nil
end

local function shape(v)
  if type(v) ~= "table" then return type(v) end
  return "table{" .. names_of(v) .. "}"
end

local diagnosed = false
local function diagnose(a, b)
  if diagnosed then return end
  diagnosed = true
  say("alias callback gave no text (arg1=" .. shape(a) .. ", arg2=" .. shape(b) .. "); please report this line.")
end

-- Remove a leading command word ("goto north" -> "north"); text without it is returned unchanged.
local function strip_word(s, word)
  if s == word then return "" end
  return s:match("^" .. word .. "%s+(.*)$") or s
end

function handle_goto(a, b)
  local text, found = typed_text(a, b)
  if not found then diagnose(a, b) end
  text = text:match("^%s*(.-)%s*$")
  local stripped = strip_word(text, "gotoAliases")
  if stripped == text then stripped = strip_word(text, "goto") end
  local sub, rest = stripped:match("^(%S*)%s*(.-)$")
  sub = sub:lower()
  if sub == "" then sub = "help" end
  sub = SUB_ALIAS[sub] or sub
  local fn = actions[sub]
  if not fn then say("Unknown option '" .. sub .. "'. Type goto for help."); return end
  if not enabled and not ALWAYS[sub] then say("Plugin is off (goto on to enable)."); return end
  fn(rest)
end

-- ---------------------------------------------------------------- alias registration
-- Fallback only: exact aliases cost ~0.8 ms each, so they are used just if the regex alias is unavailable.
local FALLBACK_SUBS = { "", "help", "list", "where", "north", "south", "east", "west", "gate", "qm", "rep", "post",
  "bank", "reagents", "reagent", "lockers", "locker", "crystal", "pursuer", "cancel", "on", "off", "debug", "debug on",
  "debug off" }

local function register_exact_goto()
  for _, prefix in ipairs({ SHORT, PLUGIN_NAME }) do
    for _, sub in ipairs(FALLBACK_SUBS) do
      local command = prefix .. (sub ~= "" and (" " .. sub) or "")
      pcall(rune.alias.exact, command, function() handle_goto(command) end)
    end
  end
end

-- ---------------------------------------------------------------- startup
timed("gmcp", function()
  pcall(rune.gmcp.subscribe, "Room")
  rune.gmcp.on("Room.Info", function(data)
    if type(data) ~= "table" then return end
    events_seen = events_seen + 1
    cur.num = data.num ~= nil and tostring(data.num) or nil
    cur.zone = data.zone
    cur.plane = type(data.coord) == "table" and data.coord.name or nil
    if running_to_pursuer then pursuer_step(false) end
  end, { name = PLUGIN_NAME })
end)

timed("goto alias", function()
  local ok, res = pcall(rune.alias.regex, GOTO_PATTERN, handle_goto)
  if ok and res ~= false then
    alias_mode = "regex"
  else
    alias_mode = "exact"
    register_exact_goto()
  end
end)

-- Everything not timed above (data tables, function definitions) is reported as "other".
local total_ms = (now() - T0) * 1000
local timed_ms = 0
for _, p in ipairs(parts) do timed_ms = timed_ms + p[2] end
parts[#parts + 1] = { "other", math.max(total_ms - timed_ms, 0) }
load_ms = math.floor(total_ms + 0.5)

say("v" .. VERSION .. " loaded (gotoAliases or goto for help)")