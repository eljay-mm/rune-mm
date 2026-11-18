-- Filename: eljayPlugins/combatEventsTracker.lua
-- Purpose: Combat events & status tracker.
-- Version: 1.10
-- Date: 2026-Nov-18
--[[
TODO:
- Confirm whether cast_finished reports additional fields for successful casts.
]]
-- Changelog:
--   1.10  Header lists the help title; registrations on single rows;
--         control characters stripped from opponent names.
--   1.8-1.9  Fix /reload layout-wrapper stacking; one regex alias; disable
--         triggers on "off"; session GMCP watch; lazy helpstyle; exact
--         affect removal.
--   1.5-1.7  Parse char.cast_finished, remove expired affects, fix spell names.
--   1.0-1.4  Add combat output, summaries, GMCP watch and combat pane.
--
-- How it works:
--   * Formats combat rounds and opponent health from Char.combat_mxp.
--   * Shows the opponent and active cast-finished affects in a combat pane.
--   * Removes an affect when combat text reports "[Off: ... loses AFFECT]".
--   * Replaces the Quests pane while combat is active, then restores the layout.
--   * "cet off" disables the two output triggers; GMCP watch lasts until restart.
--   * For 256-colour output, export TERM=xterm-256color before starting Rune.
--
-- combatEventsTracker  (alias: cet)
-- Commands (type without "/"):
--   combatEventsTracker       show this help
--   cet on|off                enable / disable tracking
--   cet debug on|off          enable / disable debug messages
--   cet gmcp [on|off|prefix]  watch GMCP, optionally filtered by package
--   cet                       short alias for combatEventsTracker
--
-- Tweaks (top of file):
--   * END        seconds without a combat round before the fight summary
--   * ONE_ALIAS  true = one regex alias; false = two exact aliases
--

local LOAD_STARTED = os.clock()

-- Tweaks:
local END = 5
local ONE_ALIAS = true

-- Command names: full command and short alias.
local NAME = "combatEventsTracker"
local SHORT = "cet"

local VERSION = "1.10"
local STORE_KEY = NAME .. ".settings"
local GMCP_KEY = NAME .. ".gmcp"
local PANE = NAME

local H
local enabled = true
local debug_on = false
local gmcp_prefix = ""
local fight = nil
local immune_name = nil
local vitals_hp = nil
local base_layout = nil
local pane_placed = false
local warned_layout = false
local LOAD_MS = 0
local N = { aliases = 0, triggers = 0 }
local TRIGGERS = {}

local function paint(color, text)
  local style = rune and rune.style
  local fn = style and style[color]
  if type(fn) == "function" then
    local ok, result = pcall(fn, text)
    if ok and type(result) == "string" then return result end
  end
  return text
end

local function say(message)
  rune.echo(paint("cyan", "[" .. NAME .. "] ") .. tostring(message))
end

local function dbg(message)
  if debug_on then
    say(paint("blue", "debug: " .. tostring(message)))
  end
end

local function onoff(value)
  return value and "on" or "off"
end

local function read_settings()
  local ok, saved = pcall(rune.store.get, STORE_KEY)
  if ok and type(saved) == "table" then return saved end
  return {}
end

local function apply_settings(saved)
  enabled = saved.enabled ~= false
  debug_on = saved.debug == true
end

local function update_settings(mutate)
  local fresh = read_settings()
  mutate(fresh)
  local ok = pcall(rune.store.set, STORE_KEY, fresh)
  if ok then apply_settings(fresh) end
end

local function save_enabled(value)
  enabled = value
  update_settings(function(settings)
    settings.enabled = value
  end)
  enabled = value
end

local function save_debug(value)
  debug_on = value
  update_settings(function(settings)
    settings.debug = value
  end)
  debug_on = value
end

-- The GMCP watch lives in rune.session: it survives /reload, not restart.
local function save_gmcp_prefix(value)
  gmcp_prefix = value
  pcall(function()
    if value == "" then
      rune.session.delete(GMCP_KEY)
    else
      rune.session.set(GMCP_KEY, value)
    end
  end)
end

local function load_gmcp_prefix()
  local ok, value = pcall(rune.session.get, GMCP_KEY)
  if ok and type(value) == "string" then
    gmcp_prefix = value
  end
end

local function get_helpstyle()
  if not H then H = require("helpstyle") end
  return H
end

local function c(color, text)
  return "\27[38;5;" .. color .. "m" .. text .. "\27[0m"
end

local GREEN, YELLOW, MAGENTA, RED, GREY = 10, 11, 13, 9, 7

-- Opponent names come from the game: drop control characters.
local function clean_name(text)
  local name = (tostring(text or ""):gsub("%c", ""))
  if name == "" then return "?" end
  return name
end

local function copy_tree(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, child in pairs(value) do
    result[key] = copy_tree(child)
  end
  return result
end

local function combat_pane_node(original)
  local node = copy_tree(original or {})
  node.type = "pane"
  node.name = PANE
  node.title = "Combat"
  node.hidden = false
  node.children = nil
  return node
end

local function replace_quests(node)
  for index, child in ipairs(node.children or {}) do
    if child.type == "pane" and child.name == "quests" then
      node.children[index] = combat_pane_node(child)
      return true
    end
    if replace_quests(child) then return true end
  end
  return false
end

local function split_output(node)
  for index, child in ipairs(node.children or {}) do
    if child.type == "pane" and child.name == "output" then
      local output = copy_tree(child)
      output.size = "1fr"
      node.children[index] = {
        type = "row",
        size = child.size or "1fr",
        children = {
          output,
          {
            type = "pane",
            name = PANE,
            size = "45%",
            border = "full",
            title = "Combat",
          },
        },
      }
      return true
    end
    if split_output(child) then return true end
  end
  return false
end

local function combat_layout(layout)
  local result = copy_tree(layout)
  if replace_quests(result) then return result end
  if split_output(result) then return result end
  return nil
end

-- Keep the original Rune layout setter on rune.ui so /reload replaces this
-- wrapper instead of stacking another wrapper around the previous one.
local ui = rune.ui
local real_layout = ui._cet_real_layout or ui.layout
pcall(function() ui._cet_real_layout = real_layout end)

local function apply_layout(layout)
  if type(layout) == "table" then
    base_layout = copy_tree(layout)
  end

  pane_placed = false
  local selected = layout

  if enabled and fight and type(layout) == "table" then
    selected = combat_layout(layout)
    if selected then
      pane_placed = true
    else
      selected = layout
    end
  end

  return real_layout(selected)
end

ui.layout = apply_layout

-- Returns true, or false and a diagnostic.
local function relayout()
  local builder = rawget(_G, "rune_build_layout")
  if type(builder) == "function" then
    local ok, err = pcall(builder)
    if ok then return true end
    return false, "layout rebuild failed: " .. tostring(err)
  end

  if type(base_layout) == "table" then
    local ok, err = pcall(apply_layout, base_layout)
    if ok then return true end
    return false, "layout restore failed: " .. tostring(err)
  end

  return false, "no layout declared yet"
end

local function normalize_affect(text)
  text = tostring(text or ""):lower()
  text = text:gsub("^[%s'\"]+", "")
  text = text:gsub("[%s'\"]+$", "")
  text = text:gsub("[%c]", "")
  text = text:gsub("^the%s+", "")
  text = text:gsub("%s+", " ")
  return text
end

local render_combat_pane

local function remove_affect(expired_name)
  if not fight or not expired_name or expired_name == "" then return false end

  local expired = normalize_affect(expired_name)
  local removed = false

  for index = #fight.affects, 1, -1 do
    local affect = fight.affects[index]
    local key = affect.key or normalize_affect(affect.label or affect)

    -- Exact normalized matching avoids removing a different affect whose name
    -- merely contains this affect's name as a substring.
    if key == expired then
      fight.affect_keys[key] = nil
      table.remove(fight.affects, index)
      removed = true
    end
  end

  if removed then render_combat_pane() end
  return removed
end

render_combat_pane = function()
  if not fight then return end

  local lines = {
    paint("magenta", "Opponent: ") .. fight.name,
    paint("gray", "Cast-finished affects:"),
  }

  if #fight.affects == 0 then
    lines[#lines + 1] = paint("gray", "  None recorded yet.")
  else
    for _, affect in ipairs(fight.affects) do
      lines[#lines + 1] = "  " .. affect.label
    end
  end

  local ok, err = pcall(rune.pane.replace, PANE, table.concat(lines, "\n"))
  if not ok then
    dbg("could not update combat pane: " .. tostring(err))
  end
end

local function show_combat_pane()
  render_combat_pane()

  local ok, err = relayout()
  if not ok then
    dbg(err)
    if not warned_layout then
      warned_layout = true
      say("combat pane unavailable: no reusable layout has been declared")
    end
    return
  end

  if pane_placed then
    pcall(rune.pane.show, PANE)
  elseif not warned_layout then
    warned_layout = true
    say("combat pane unavailable: layout has no Quests or output pane")
  end
end

local function hide_combat_pane()
  pane_placed = false
  local ok, err = relayout()
  if not ok then
    dbg("could not restore the original layout: " .. tostring(err))
  end
end

local function times(n)
  if n == 1 then return "once" end
  if n == 2 then return "twice" end
  if n == 3 then return "thrice" end
  return tostring(n) .. " times"
end

local function cap(text)
  return text:sub(1, 1):upper() .. text:sub(2)
end

local function your_line(name, hits, misses, blocked)
  local text
  if hits > 0 then
    text = "You hit " .. name .. " " .. times(hits)
    if misses > 0 then
      text = text .. " and miss " .. times(misses)
    end
  elseif misses > 0 then
    text = "You miss " .. name .. " " .. times(misses)
  end

  if blocked > 0 then
    text = text and (text .. ", and are blocked " .. times(blocked))
      or (cap(name) .. " blocks you " .. times(blocked))
  end
  return text and (text .. ".") or nil
end

local function their_line(name, hits, misses, blocked)
  local text
  if hits > 0 then
    text = cap(name) .. " hits you " .. times(hits)
    if misses > 0 then
      text = text .. " and misses you " .. times(misses)
    end
  elseif misses > 0 then
    text = cap(name) .. " misses you " .. times(misses)
  end

  if blocked > 0 then
    text = text and (text .. ", and you block " .. times(blocked))
      or ("You block " .. name .. " " .. times(blocked))
  end
  return text and (text .. ".") or nil
end

local function finish_fight(expected_fight)
  local current = fight
  if not current or (expected_fight and current ~= expected_fight) then
    return
  end

  fight, immune_name = nil, nil
  hide_combat_pane()

  if current.rounds == 0 then return end

  local lost = current.hp0 and current.hp1
    and (current.hp0 - current.hp1) or nil
  local text = "The fight with " .. current.name .. " lasted "
    .. current.rounds .. " round"
    .. (current.rounds == 1 and "" or "s")
    .. ": you landed " .. current.you_hit .. " of "
    .. (current.you_hit + current.you_miss) .. " attacks, "
    .. current.name .. " landed " .. current.it_hit .. " of "
    .. (current.it_hit + current.it_miss)

  if lost and lost > 0 then
    text = text .. ", and you lost " .. lost .. " hp"
  elseif lost and lost < 0 then
    text = text .. ", and you gained " .. -lost .. " hp"
  end

  rune.echo(c(GREY, text .. "."))
end

local function arm_end_timer(expected_fight)
  local ok, err = pcall(function()
    rune.timer.after(END, function()
      finish_fight(expected_fight)
    end, { name = NAME .. "-combat-end" })
  end)
  if not ok then
    dbg("could not schedule fight summary: " .. tostring(err))
  end
end

local function begin_fight(name)
  if not enabled then return end
  name = clean_name(name)
  if fight and fight.name == name then return end
  if fight then finish_fight(fight) end

  fight = {
    name = name,
    rounds = 0,
    you_hit = 0,
    you_miss = 0,
    it_hit = 0,
    it_miss = 0,
    hp0 = vitals_hp,
    hp1 = vitals_hp,
    affects = {},
    affect_keys = {},
  }

  show_combat_pane()
  arm_end_timer(fight)
end

local function number(data, key)
  local value = tonumber(data[key])
  if value and value == value then return value end
  return 0
end

local function handle_vitals(data)
  if type(data) == "table" then
    local hp = tonumber(data.hp)
    if hp and hp == hp then
      vitals_hp = hp
      if fight then fight.hp1 = hp end
    end
  end
end

local function handle_round(data)
  if not enabled or type(data) ~= "table" then return end

  local name = clean_name(data.opponent_name)
  if not fight or fight.name ~= name then begin_fight(name) end
  if not fight then return end

  local current = fight
  local hits = number(data, "you_hit")
  local misses = number(data, "you_miss")
  local opponent_hits = number(data, "opponent_hits")
  local opponent_misses = number(data, "opponent_misses")
  local hp = math.max(0, math.min(100,
    number(data, "opponent_hp_percent")))
  local you_hp = number(data, "your_hp_percent")
  local distance = tonumber(data.distance_to_opponent)
  local range = tonumber(data.your_weapon_range)

  current.rounds = current.rounds + 1
  current.you_hit = current.you_hit + hits
  current.you_miss = current.you_miss + misses
  current.it_hit = current.it_hit + opponent_hits
  current.it_miss = current.it_miss + opponent_misses

  local mine = your_line(name, hits, misses,
    number(data, "opponent_defends"))
  local theirs = their_line(name, opponent_hits, opponent_misses,
    number(data, "you_defend"))
  local immune = immune_name
    and immune_name:lower() == name:lower()

  if mine then
    rune.echo(c(GREEN, mine)
      .. (immune and (" " .. c(RED, "[IMMUNE]")) or ""))
  end
  if theirs then rune.echo(c(YELLOW, theirs)) end

  if immune and not mine then
    rune.echo(c(RED, cap(name) .. " is immune to your attack."))
  elseif not immune and distance and range
      and distance > range and not current.told_range then
    current.told_range = true
    rune.echo(c(RED, cap(name) .. " is out of your reach: "
      .. distance .. " away, and your weapon reaches " .. range .. "."))
  end

  local filled = math.max(hp > 0 and 1 or 0,
    math.min(20, math.floor(20 * hp / 100 + 0.5)))
  local health_color = hp >= 50 and GREEN or hp >= 25 and 226 or RED
  local drop = ""

  if current.last_hp and current.last_hp ~= hp then
    drop = " " .. c(hp < current.last_hp and RED or GREEN,
      string.format("(%+d)", hp - current.last_hp))
  end

  rune.echo(c(MAGENTA, cap(name) .. ":") .. " "
    .. c(health_color, string.rep("▰", filled))
    .. c(8, string.rep("▱", 20 - filled))
    .. " " .. hp .. "%" .. drop)

  current.last_hp = hp
  current.last_you = you_hp
  render_combat_pane()
  arm_end_timer(current)
end

local function clean_cast_text(value)
  if type(value) ~= "string" then return nil end
  local text = value:gsub("^%s+", ""):gsub("%s+$", "")
  text = text:gsub("%c", "")
  if text == "" then return nil end
  return text
end

local function parse_cast_finished(data)
  if type(data) == "string" then
    return clean_cast_text(data), nil
  end
  if type(data) ~= "table" then return nil, nil end

  local text = clean_cast_text(data.casting_completed)
  if text then
    local affect = text:match("^'([^']+)'%s+cast")
      or text:match("^\"([^\"]+)\"%s+cast")
      or text:match("^(.+)%s+cast%s+successful")
      or text:match("^(.+)%s+cast%s+unsuccessful")

    if affect then affect = clean_cast_text(affect) end

    local lower = text:lower()
    local successful = lower:find("cast successful", 1, true) ~= nil
      or lower:find("casting successful", 1, true) ~= nil
    local unsuccessful = lower:find("cast unsuccessful", 1, true) ~= nil
      or lower:find("casting unsuccessful", 1, true) ~= nil
      or lower:find("cast failed", 1, true) ~= nil
      or lower:find("casting failed", 1, true) ~= nil

    if unsuccessful then return affect, false end
    if successful then return affect, true end
    return affect or text, nil
  end

  for _, key in ipairs({
    "affect_name", "affect", "spell_name", "spell",
    "ability_name", "ability", "cast_name", "name",
  }) do
    local affect = clean_cast_text(data[key])
    if affect then return affect, nil end
  end

  return nil, nil
end

local function handle_cast_finished(data)
  if not enabled or not fight then return end

  local affect, successful = parse_cast_finished(data)
  if not affect then
    dbg("cast_finished payload has no recognized string")
    return
  end
  if successful == false then
    dbg("cast did not land: " .. affect)
    return
  end

  local key = normalize_affect(affect)
  local label = affect
  if successful == nil then label = label .. " (status unknown)" end

  if not fight.affect_keys[key] then
    fight.affect_keys[key] = true
    fight.affects[#fight.affects + 1] = { label = label, key = key }
    render_combat_pane()
  end
end

local function handle_off_line(matches, _ctx)
  if not enabled or not fight then return end
  if not matches or not matches[1] then return end
  remove_affect(matches[1])
end

local function handle_immunity(data)
  if not enabled or type(data) ~= "table" then return end
  local message = data.combat_immunity
  if message then
    immune_name = tostring(message):match("^(.-) is immune")
      or (fight and fight.name)
  end
end

local function handle_gmcp(package, _, raw)
  if not enabled or gmcp_prefix == "" then return end

  local name = tostring(package or "")
  if gmcp_prefix ~= "*" and name:lower():sub(1, #gmcp_prefix)
      ~= gmcp_prefix:lower() then
    return
  end

  rune.echo(c(GREY, "[gmcp] " .. name .. " "
    .. tostring(raw or "")))
end

local function handle_combat_start(matches)
  if enabled and matches and matches[1] then
    begin_fight(matches[1])
  end
end

local function show_help()
  local H = get_helpstyle()
  rune.echo(H.title(NAME .. "  (alias: " .. SHORT .. ")"))
  rune.echo(H.section("Commands"))
  rune.echo(H.line(NAME, "show this help"))
  rune.echo(H.line(SHORT .. " on|off", "enable / disable tracking"))
  rune.echo(H.line(SHORT .. " debug on|off",
    "enable / disable debug messages"))
  rune.echo(H.line(SHORT .. " gmcp [on|off|prefix]",
    "watch GMCP, optionally filtered by package"))
  rune.echo(H.line(SHORT, "short alias for " .. NAME))
  rune.echo(H.foot(string.format(
    "v%s  enabled=%s debug=%s gmcp=%s aliases=%d triggers=%d load=%dms",
    VERSION,
    tostring(enabled),
    tostring(debug_on),
    gmcp_prefix == "" and "off" or gmcp_prefix,
    N.aliases,
    N.triggers,
    LOAD_MS
  )))
end

local function clean_prefix(text)
  return (tostring(text or ""):gsub("%c", "")):sub(1, 64)
end

local function set_triggers(on)
  local fn = rune.trigger[on and "enable" or "disable"]
  if type(fn) ~= "function" then return end

  for _, trigger_name in ipairs(TRIGGERS) do
    pcall(fn, trigger_name)
  end
end

local function handle_command(args, _ctx)
  local text = type(args) == "string" and args or ""
  local command, rest = text:match("^%s*(%S*)%s*(.-)%s*$")
  command = (command or ""):lower()
  rest = rest or ""
  local value = rest:lower()

  if command == "" or command == "help" then
    show_help()
  elseif (command == "on" or command == "off") and rest == "" then
    save_enabled(command == "on")
    set_triggers(enabled)

    if not enabled and fight then
      fight, immune_name = nil, nil
      hide_combat_pane()
    end
    say("tracking " .. onoff(enabled))
  elseif command == "debug"
      and (value == "on" or value == "off") then
    save_debug(value == "on")
    say("debug " .. onoff(debug_on))
  elseif command == "gmcp" then
    if value == "off" then
      save_gmcp_prefix("")
    elseif value == "on" then
      save_gmcp_prefix("*")
    elseif rest ~= "" then
      save_gmcp_prefix(clean_prefix(rest))
    elseif gmcp_prefix ~= "" then
      save_gmcp_prefix("")
    else
      save_gmcp_prefix("*")
    end

    say(gmcp_prefix == "" and "GMCP watch off"
      or ("GMCP watch on (" .. gmcp_prefix .. ")"))
  else
    show_help()
  end
end

local function dispatch(matches, ctx)
  local rest = type(matches) == "table" and matches[1] or ""
  handle_command(rest, ctx)
end

local function register_trigger(pattern, handler, suffix)
  local trigger_name = NAME .. "-" .. suffix
  rune.trigger.regex(pattern, handler, { name = trigger_name })
  TRIGGERS[#TRIGGERS + 1] = trigger_name
  N.triggers = N.triggers + 1
end

apply_settings(read_settings())
load_gmcp_prefix()

-- Build and remember the configured layout before combat can start.
local initial_builder = rawget(_G, "rune_build_layout")
if type(initial_builder) == "function" then
  local ok, err = pcall(initial_builder)
  if not ok then
    dbg("initial layout capture failed: " .. tostring(err))
  end
end

local alias_pattern = "^(?:" .. NAME .. "|" .. SHORT
  .. ")(?:\\s+(.*))?$"

if ONE_ALIAS then
  local ok = pcall(rune.alias.regex, alias_pattern, dispatch,
    { name = NAME .. "-command" })
  if ok then
    N.aliases = 1
  else
    rune.alias.exact(NAME, handle_command)
    rune.alias.exact(SHORT, handle_command)
    N.aliases = 2
  end
else
  rune.alias.exact(NAME, handle_command)
  rune.alias.exact(SHORT, handle_command)
  N.aliases = 2
end

register_trigger("^You enter into combat with (.+)\\.$", handle_combat_start, "combat-start")
register_trigger("^\\[Off:\\s+.+\\s+loses\\s+([^\\]]+)\\]", handle_off_line, "affect-off")

if not enabled then set_triggers(false) end

rune.hooks.on("gmcp", handle_gmcp, { name = NAME .. "-gmcp-watch" })
rune.gmcp.on("Char.Vitals", handle_vitals, { name = NAME .. "-vitals" })
rune.gmcp.on("Char.combat_mxp", handle_round, { name = NAME .. "-round" })
rune.gmcp.on("Char.combat_immunity", handle_immunity, { name = NAME .. "-immunity" })
rune.gmcp.on("Char.cast_finished", handle_cast_finished, { name = NAME .. "-cast-finished" })

LOAD_MS = math.floor((os.clock() - LOAD_STARTED) * 1000 + 0.5)
say(string.format("v%s loaded (%s or %s for help)",
  VERSION, NAME, SHORT))