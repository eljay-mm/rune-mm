-- Filename: eljayPlugins/asciiMapPane.lua
-- Purpose: ASCII map pane for Rune + horstgs Materia Magica.
-- Version: 2.27
-- Date: 2026-Oct-23
--
--[[ Todo:
- insert planning notes here between revisions.
--]]
--
-- Changelog:
--   2.27  No-loss size pass: dead pane-size probing and the inert pad setting
--         removed; settings, commands and help table-driven; layout node cap
--         scaled to the pane; look hook skips long input; header trimmed.
--   2.26  `amp colours` also tries asciiMapColours at the config root, and
--         says where the file is expected when it cannot be loaded.
--   2.25  Colour management moved to eljayPlugins/asciiMapColours.lua, loaded
--         only on `amp colours`; basic (16-colour) is the default scheme
--         again. On `look` the trail is cleared. Removed the links, color,
--         dim, tags and help subcommands.
--   2.24  Trail fades in the colour of you, never inverted.
-- How it works:
--   * GMCP Room.Info on every move updates the latest room and redraws the pane; redraws are skipped when nothing relevant changed.
--   * Layout follows mapper_map.lua (horstgs): from your room it walks the exits breadth-first (n ne e se s sw w nw), one step per exit, the first room to reach a cell keeps it; only your zone and floor by default; up, down, in and out exits are not drawn.
--   * Walk depth comes from the pane: out until rooms stop landing in the visible window (one room of margin), at least the window radius and at most three times that plus six.
--   * Rooms sit two characters apart; a box-line link is drawn only when that exit leads to the room placed in that cell. Exits to rooms the mapper has not stored show as ?.
--   * Rooms are classified by flags and tags like mapper_map.lua: x pk, T trainer, $ shop, S safe, ^ v % stairs, # road, o plain. The trail (your last six rooms) uses the colour of you, fading, and is cleared on look.
--   * In the wilds the game sends its own map after a compass frame; the pane shows only the title, the room number and name, the exits row, and that map's roads (#) and you (@) where the game put them.
--   * Colours: 16-colour basic is the default; `amp colours` loads asciiMapColours.lua (schemes, custom colours, codes) and its saved codes are applied at startup. Fixed in every scheme: id/name bold white, exits and stairs cyan, shops green, roads grey. The 256-colour schemes need `export TERM=xterm-256color` before starting Rune (add it to ~/.bashrc to keep it).
--   * The pane title is the area name: the plugin sets rune.asciimap_title and calls rune_build_layout(); init.lua uses title = rune.asciimap_title or "asciiMap" for that pane.
--   * The pane size is saved per character via charname (other settings are shared); the room store is require("mapper_store"). Server text is stripped of control characters; debug output stays off unless enabled.
--   * The bare command shows a help summary (helpstyle) with the version at the start of the footer row.
--
-- Commands:
--   asciiMapPane (amp)                    show this summary
--   asciiMapPane on|off                   show or hide the map pane
--   asciiMapPane zone on|off              stay in the current zone (default) / cross zone borders
--   asciiMapPane colours|colors ...       colour schemes and codes (asciiMapColours.lua)
--   asciiMapPane flags|trail on|off       overlays
--   asciiMapPane size <W> <H>|auto        set pane size in characters (saved per character)
--   asciiMapPane calibrate [W H]          draw a test frame of that size (default: current)
--   asciiMapPane legend                   what the symbols mean
--   asciiMapPane refresh | reset          force a redraw | restore defaults
--   asciiMapPane debug on|off             debug logging (default off)

local T0 = os.clock and os.clock() or 0
local VERSION = "2.27"

-- Command names: full command and short alias.
local NAME  = "asciiMapPane"
local SHORT = "amp"

local PANE_ID = "eljayPlugins/asciiMapPane"

-- Rune's pane API has no size query, so this is the "auto" size. Edit
-- these two numbers (or use asciiMapPane size W H) to match your pane.
local DEFAULT_W = 42
local DEFAULT_H = 10

-- Limits (input validation / resource safety).
local MIN_W, MAX_W = 10, 200
local MIN_H, MAX_H = 3, 100

local CURRENT_MARKER = "@"

local enabled = true
local redraw_pending = false
local current_info = nil
local last_pane_text = nil
local load_ms = 0

local manual_w, manual_h = nil, nil

-- Redraw skipping
local last_sig = nil
local wilds, wilds_uid, wilds_id = nil, nil, 0   -- the game's wilds map (see Setup)
local epoch = 0

-- Server-supplied text may include control characters.
local function clean(value)
    local text = tostring(value == nil and "" or value)
    text = text:gsub("%c", "?")
    text = text:gsub("\194[\128-\159]", "?")
    return text
end

-- Debug logging: OFF by default.
local DEBUG = false

local function dbg(...)
    local ok, text = pcall(string.format, ...)
    if type(rune.echo) == "function" then
        rune.echo("[" .. NAME .. ":debug] " .. clean(ok and text or tostring((...))))
    end
end

-----------------------------------------------------------------------
-- Store access (lazy)
-----------------------------------------------------------------------

-- The room store, required directly as mapper_map.lua does.
local store = require("mapper_store")
local charname = require("charname")

-----------------------------------------------------------------------
-- Helpers
-----------------------------------------------------------------------

local function key_of(x, y)
    return (x + 1024) * 2048 + (y + 1024)
end

local function info_uid(info)
    if type(info) ~= "table" then
        return nil
    end

    local uid = info.num or info.id or info.uid
    if uid == nil then
        return nil
    end

    return tostring(uid)
end

local function has_exit(room, dir)
    return room ~= nil
        and type(room.exits) == "table"
        and room.exits[dir] ~= nil
end

local function clamp(v, lo, hi)
    return math.max(lo, math.min(hi, v))
end

-----------------------------------------------------------------------
-- Pane + size
-----------------------------------------------------------------------

local function write_pane(text)
    if text == last_pane_text then
        return
    end

    last_pane_text = text

    if rune.pane and rune.pane.replace then
        pcall(rune.pane.replace, PANE_ID, text)

        if rune.pane.scroll_to_top then
            pcall(rune.pane.scroll_to_top, PANE_ID)
        end
    end
end

-- Replace the pane text even when it matches the last text written.
local function force_pane(text)
    last_pane_text = nil
    write_pane(text)
end

local function show_pane()
    if rune.pane and rune.pane.show then
        rune.pane.show(PANE_ID)
    end
end

local function hide_pane()
    if rune.pane and rune.pane.hide then
        rune.pane.hide(PANE_ID)
    end
end

-- The pane title is the area name. Panes have no runtime title setter, so
-- this sets rune.asciimap_title and re-declares the layout, as mapper_map.lua
-- does; init.lua reads the title when it builds the layout.
local function set_title(text)
    text = clean(text):sub(1, 40)
    if text == "" then text = "asciiMap" end
    if text == rune.asciimap_title then return end

    rune.asciimap_title = text
    if rune_build_layout then pcall(rune_build_layout) end
    last_pane_text = nil   -- the re-declared pane may be empty
    if DEBUG then dbg("title: %s", text) end
end

-- Rune has no pane size query, so the size is the one you set with `size W H`
-- (saved per character) or the default above.
local function detect_size()
    if manual_w and manual_h then
        return manual_w, manual_h, "manual"
    end

    return DEFAULT_W, DEFAULT_H, "default"
end

-----------------------------------------------------------------------
-- Header and exits lines
-----------------------------------------------------------------------

local EXIT_ORDER = {
    "n", "ne", "e", "se", "s", "sw", "w", "nw", "u", "d", "in", "out",
}

local function area_of(info, stored)
    return info.area or info.zone or (stored and stored.area)
        or (type(info.coord) == "table" and info.coord.name)
        or "Unknown zone"
end

local function header_line(info, stored, width)
    local name = info.name or (stored and stored.name) or "Unknown room"

    local text = string.format("%s %s",
        clean(info_uid(info) or (stored and stored.uid) or "?"), clean(name))

    return #text > width and text:sub(1, width) or text
end

local function exits_line(stored, info, width)
    local present = {}

    local function add_from(exits)
        if type(exits) == "table" then
            for dir in pairs(exits) do
                present[tostring(dir):lower()] = true
            end
        end
    end

    add_from(stored and stored.exits)

    if next(present) == nil then
        add_from(info and info.exits)
    end

    local list = {}
    for _, dir in ipairs(EXIT_ORDER) do
        if present[dir] then
            list[#list + 1] = dir
        end
    end

    local text = "Exits: " .. (#list > 0 and table.concat(list, " ") or "-")
    return text:sub(1, width)
end

-----------------------------------------------------------------------
-- Styling tables
-----------------------------------------------------------------------

-- Colour codes in use, by name. The defaults are the 16-colour basic scheme;
-- `amp colours` (asciiMapColours.lua) can change them, and the saved codes
-- are applied at startup (see load_codes).
local CODES = { header = "1;37", exits = "36", road = "37", stairs = "36",
    shop = "32", you = "1;30;43", unexplored = "1;91", pk = "1;91",
    trainer = "93", safe = "92", room = "37", links = "90", dark = "2" }
local DEFAULT_CODES = {}
for k, v in pairs(CODES) do DEFAULT_CODES[k] = v end

local UNEXPLORED_MARKER = "?"

local TRAIL_LENGTH = 6   -- rooms remembered

local ESC = string.char(27)

local opts = { flags = true, trail = true, dim = true, zone = true }

local history = {}

-- Rooms are classified by exact flags and tags, as mapper_map.lua does.
local function tokens(v)
    local set = {}

    if type(v) == "table" then
        for _, x in ipairs(v) do set[tostring(x):lower()] = true end
    else
        for tok in tostring(v or ""):lower():gmatch("[^,%s]+") do set[tok] = true end
    end

    return set
end

local function token_list(v)
    local t = {}
    for k in pairs(tokens(v)) do t[#t + 1] = k end
    table.sort(t)
    return table.concat(t, ",")
end

-- A room is a road when its terrain, flags or tags hold one of these words.
local ROADS = { road = true, street = true, path = true, trail = true }

local function is_road(room, flags, tags)
    for _, set in ipairs({ flags, tags, tokens(room.terrain), tokens(room.terraininfo) }) do
        for t in pairs(ROADS) do
            if set[t] then return true end
        end
    end

    return false
end

local PK = { npk = true, cpk = true, lpk = true,
    ["player-kill-neutral"] = true, ["player-kill-chaotic"] = true }

-- Order matters: pk, trainer, shop, safe, then stairs, road, a plain room.
local function compute_style(room)
    local flags, tags = tokens(room.flags), tokens(room.tags)
    local pk = tags.dt

    for t in pairs(PK) do
        if flags[t] then pk = true break end
    end

    local glyph, key

    if pk then
        glyph, key = "x", "pk"
    elseif flags.trainer or tags.trainer then
        glyph, key = "T", "trainer"
    elseif flags.shop or tags.shop then
        glyph, key = "$", "shop"
    elseif flags.safe or tags.safe then
        glyph, key = "s", "safe"
    else
        local up, down = has_exit(room, "u"), has_exit(room, "d")

        if up and down then
            glyph, key = "%", "stairs"
        elseif up then
            glyph, key = "^", "stairs"
        elseif down then
            glyph, key = "v", "stairs"
        elseif is_road(room, flags, tags) then
            glyph, key = "#", "road"
        else
            glyph, key = "o", "room"
        end
    end

    return { glyph = glyph, key = key, dark = flags.dark or tags.dark }
end

local style_cache = setmetatable({}, { __mode = "k" })

local function room_style(room)
    local st = style_cache[room]
    if st == nil then
        st = compute_style(room)
        style_cache[room] = st
    end
    return st
end

-- With the flags overlay off, special rooms are drawn as plain rooms.
local SPECIAL = { pk = true, trainer = true, shop = true, safe = true }
local PLAIN = { glyph = "o", key = "room" }

-- The trail is drawn in the colour of you, fading from your last room back,
-- and never inverted: a block colour (background or reverse video) becomes
-- text in that colour. Finds the colour in you's code: a background first,
-- else a foreground.
local function trail_base(code)
    local nums = {}
    for n in code:gmatch("%d+") do nums[#nums + 1] = tonumber(n) end

    local fg, bg, i = nil, nil, 1
    while i <= #nums do
        local n = nums[i]

        if (n == 38 or n == 48) and nums[i + 1] == 5 and nums[i + 2] then
            local c = nums[i + 2]
            local base = (c < 16) and { c16 = (c < 8) and 30 + c or 82 + c } or { c256 = c }
            if n == 48 then bg = base else fg = base end
            i = i + 2
        elseif (n >= 40 and n <= 47) or (n >= 100 and n <= 107) then
            bg = { c16 = n - 10 }
        elseif (n >= 30 and n <= 37) or (n >= 90 and n <= 97) then
            fg = { c16 = n }
        end

        i = i + 1
    end

    return bg or fg or { c16 = 37 }
end

local FADE = { 1, 0.88, 0.76, 0.66, 0.57, 0.5 }   -- brightness per trail step
local LEVELS = { 0, 95, 135, 175, 215, 255 }      -- the 256-colour cube levels

-- A 256-colour number scaled to a fraction of its brightness.
local function dim256(n, f)
    if n >= 232 then
        return math.max(232, 232 + math.floor((n - 232) * f))
    end

    local v, out = n - 16, 0
    for _, comp in ipairs({ math.floor(v / 36), math.floor(v / 6) % 6, v % 6 }) do
        local want, best, gap = LEVELS[comp + 1] * f, 0, math.huge
        for lv = 0, 5 do
            local d = math.abs(LEVELS[lv + 1] - want)
            if d < gap then best, gap = lv, d end
        end
        out = out * 6 + best
    end

    return 16 + out
end

local function trail_code(rank)
    local base = trail_base(CODES.you)
    local step = math.min(rank, #FADE)

    if base.c256 then
        return (step == 1 and "1;" or "") .. "38;5;" .. dim256(base.c256, FADE[step])
    end

    -- 16 colours cannot be scaled: bold, then plain, then faint.
    return (step == 1 and "1;" or (step > 3 and "2;" or "")) .. base.c16
end

local function cell_color(st, rank)
    if rank and opts.trail then
        return trail_code(rank)
    end

    local code = CODES[st.key]

    if opts.flags and st.dark then
        code = code .. ";" .. CODES.dark
    end

    return code
end

-----------------------------------------------------------------------
-- Layout
-----------------------------------------------------------------------

-- Layout: the method of mapper_map.lua.  Exits are walked in this fixed
-- order (never with pairs(), whose order is undefined) so the map keeps its
-- shape from one redraw to the next.
local DELTA = {
    n = { 0, 1 }, ne = { 1, 1 }, e = { 1, 0 }, se = { 1, -1 },
    s = { 0, -1 }, sw = { -1, -1 }, w = { -1, 0 }, nw = { -1, 1 },
}

local DIR_ORDER = { "n", "ne", "e", "se", "s", "sw", "w", "nw" }

-- A jump of 1..4 floors in a horizontal exit is a stair coded as an exit,
-- not a real neighbour; 5 or more is a stale coordinate and is left alone.
local MAX_FLOOR_JUMP = 4
-- Depth is worked out from the pane: the walk goes out until rooms stop
-- landing in the visible window (plus one room of margin), but never fewer
-- levels than the window's radius, and at most three times that plus six.
local PATIENCE = 2    -- levels with nothing in view before the walk stops

-- Link glyphs per direction (box drawing characters).
local LINK_GLYPHS = { n = "\226\148\130", s = "\226\148\130",
    e = "\226\148\128", w = "\226\148\128",
    ne = "\226\149\177", sw = "\226\149\177",
    nw = "\226\149\178", se = "\226\149\178" }

local LONG_DIRS = {
    north = "n", south = "s", east = "e", west = "w",
    northeast = "ne", northwest = "nw", southeast = "se",
    southwest = "sw", up = "u", down = "d",
}

local view_stats = "layout: none"
local needs_followup = false

local function exit_uid(e)
    if type(e) == "string" or type(e) == "number" then
        return tostring(e)
    end

    if type(e) == "table" then
        local v = e.uid or e.to or e.num or e.id
        return v and tostring(v) or nil
    end

    return nil
end

local function pseudo_room(info)
    local room = { uid = info_uid(info), name = info.name,
        area = info.area or info.zone, flags = info.flags,
        tags = info.tags, coord = info.coord, exits = {} }

    if type(info.exits) == "table" then
        for dir, e in pairs(info.exits) do
            local d = tostring(dir):lower()
            d = LONG_DIRS[d] or d

            local uid = exit_uid(e)
            if uid then
                room.exits[d] = uid
            end
        end
    end

    return room
end

-- Walks out from `start`, giving each reachable room a grid position.
-- One cell holds one room: when two routes want the same cell the first to
-- arrive keeps it (breadth-first, so rooms nearer to you win) and the other
-- is simply not placed.  Returns layout[uid] = {x, y}, rooms[uid] = room,
-- the cell -> uid map, exits to rooms the mapper does not have, and a count.
local function build_layout(s, start, root_uid, area, root_z, win, same_zone)
    local reach = math.max(win.xmax, -win.xmin, win.ymax, -win.ymin)
    local max_depth = reach * 3 + 6
    local max_nodes = math.max(500, 6 * (win.xmax - win.xmin + 1) * (win.ymax - win.ymin + 1))

    local function on_this_floor(room)
        if not root_z or type(room.coord) ~= "table" then
            return true
        end

        local z = tonumber(room.coord.z)

        if not z then
            return true
        end

        local jump = math.abs(z - root_z)

        return jump == 0 or jump > MAX_FLOOR_JUMP
    end

    local layout = { [root_uid] = { x = 0, y = 0 } }
    local rooms = { [root_uid] = start }
    local occupied = { [key_of(0, 0)] = root_uid }
    local unknown = {}
    local frontier = { { room = start, x = 0, y = 0 } }
    local count = 1

    local idle, level = 0, 0

    while level < max_depth do
        level = level + 1
        local nxt, seen = {}, 0   -- seen: rooms placed this level inside the window

        for _, node in ipairs(frontier) do
            local exits = node.room.exits

            if type(exits) == "table" then
                for i = 1, #DIR_ORDER do
                    local dir = DIR_ORDER[i]
                    local e = exits[dir]

                    if e then
                        local dest = type(e) == "string" and e or exit_uid(e)

                        if dest and not layout[dest] then
                            local d = DELTA[dir]
                            local x, y = node.x + d[1], node.y + d[2]
                            local k = key_of(x, y)
                            local dest_room = s.get(dest)

                            if not dest_room then
                                unknown[#unknown + 1] = { k = k, x = x, y = y,
                                    fx = node.x, fy = node.y, dir = dir }
                            elseif (not same_zone or not area
                                    or dest_room.area == area)
                                and on_this_floor(dest_room)
                                and not occupied[k] then
                                layout[dest] = { x = x, y = y }
                                rooms[dest] = dest_room
                                occupied[k] = dest
                                count = count + 1
                                if x >= win.xmin and x <= win.xmax
                                    and y >= win.ymin and y <= win.ymax then
                                    seen = seen + 1
                                end
                                nxt[#nxt + 1] = { uid = dest, room = dest_room,
                                    x = x, y = y }
                            end
                        end
                    end
                end
            end
        end

        frontier = nxt

        if #frontier == 0 or count >= max_nodes then
            break
        end

        idle = (seen > 0) and 0 or idle + 1
        if level >= reach and idle >= PATIENCE then
            break
        end
    end

    return layout, rooms, occupied, unknown, count, level
end

-----------------------------------------------------------------------
-- Colour output
-----------------------------------------------------------------------

local function paint_text(text, code)
    return ESC .. "[" .. code .. "m" .. text .. ESC .. "[0m"
end

local function paint_row(chars, codes)
    local out, current = {}, nil

    for i = 1, #chars do
        local ch = chars[i]
        local code = codes[i]

        if ch == " " then
            code = nil
        end

        if code ~= current then
            if current then
                out[#out + 1] = ESC .. "[0m"
            end

            if code then
                out[#out + 1] = ESC .. "[" .. code .. "m"
            end

            current = code
        end

        out[#out + 1] = ch
    end

    if current then
        out[#out + 1] = ESC .. "[0m"
    end

    return table.concat(out)
end

-----------------------------------------------------------------------
-- Drawing
-----------------------------------------------------------------------

local function reset_caches()
    style_cache = setmetatable({}, { __mode = "k" })
end

local draw

local function draw_impl()
    redraw_pending = false

    if not enabled then
        return
    end

    if type(current_info) ~= "table" then
        write_pane("Waiting for Room.Info.")
        return
    end

    local s = store

    local width, height = detect_size()
    width = math.max(width, 5)
    height = math.max(height, 3)

    local uid = info_uid(current_info)
    local stored = uid and s.get(uid) or nil

    -- Room.Info is the freshest view of where we are; the stored room
    -- supplies exits when Room.Info has none.
    local start = pseudo_room(current_info)
    if next(start.exits) == nil and stored then
        start = stored
    end

    -- Skip the redraw if nothing that affects the picture has changed.
    local es = {}
    for i = 1, #DIR_ORDER do
        local e = start.exits and start.exits[DIR_ORDER[i]]
        es[i] = e and tostring(exit_uid(e)) or ""
    end

    local sig = table.concat({
        uid or "?", epoch, width, height,
        opts.flags and 1 or 0, opts.trail and 1 or 0,
        opts.zone and 1 or 0, wilds and wilds.id or 0,
        table.concat(history, ","), table.concat(es, ","),
    }, "|")

    if sig == last_sig and not needs_followup then
        if DEBUG then dbg("draw skipped (unchanged)") end
        return
    end

    set_title(area_of(current_info, stored))

    local header = header_line(current_info, stored, width)
    local rows = math.max(height - 2, 1)    -- header + exits lines
    local sx0 = math.floor((width + 1) / 2) -- centre column
    local sy0 = math.floor((rows + 1) / 2)  -- centre row

    local lines = {
        paint_text(header, CODES.header),
        paint_text(exits_line(start, current_info, width), CODES.exits),
    }

    -- Wilds: only the roads (#) and you (@) of the game's own map, in the
    -- places the game put them, centred on you; no adjacent rooms.
    if wilds then
        for sy = 1, rows do
            local row = wilds.rows[wilds.r0 - sy0 + sy] or ""
            local chars, codes = {}, {}

            for sx = 1, width do
                local i = wilds.c0 + sx - sx0
                local ch = (i >= 1) and row:sub(i, i) or ""

                if ch == "#" then
                    chars[sx], codes[sx] = "#", CODES.road
                elseif ch == "@" then
                    chars[sx], codes[sx] = "@", CODES.you
                else
                    chars[sx], codes[sx] = " ", false
                end
            end

            lines[#lines + 1] = paint_row(chars, codes)
        end

        view_stats = string.format("wilds map: %d rows", #wilds.rows)
        needs_followup = false
        write_pane(table.concat(lines, "\n"))
        last_sig = sig
        return
    end

    -- Rooms visible each side of you. win is the visible window in room
    -- units plus one room of margin (links and ? markers reach into the pane
    -- from rooms just outside it); build_layout works out its own depth.
    local step = 2                          -- characters per room step
    local win = {
        xmin = math.ceil((1 - sx0) / step) - 1,
        xmax = math.floor((width - sx0) / step) + 1,
        ymin = math.ceil((sy0 - rows) / step) - 1,
        ymax = math.floor((sy0 - 1) / step) + 1,
    }

    local area = start.area or (stored and stored.area)
    local zc = (stored and stored.coord) or start.coord
    local root_z = type(zc) == "table" and tonumber(zc.z) or nil
    local root_uid = tostring(uid or start.uid or "?")

    local layout, rooms, occupied, unknown, placed, depth =
        build_layout(s, start, root_uid, area, root_z, win, opts.zone)

    needs_followup = (stored == nil)

    -- Recently visited rooms (index 1 is where we are now).
    local trail_rank = {}
    if opts.trail then
        for i = 2, #history do
            trail_rank[history[i]] = i - 1
        end
    end

    -- Sparse character grid, centred on you (north is up).
    local gch, gcode = {}, {}

    local function put(cx, cy, ch, code, keep)
        local k = key_of(cx, cy)

        if keep and gch[k] then
            return
        end

        gch[k], gcode[k] = ch, code or false
    end

    -- Draw in a fixed order (top row first, then left to right), so cells
    -- wanted by two links always go to the same one.  Only rooms near the
    -- visible window can put anything inside it (a link is at most one
    -- character from its room), so the rest are skipped before the sort.
    local margin = step + 1
    local xmin, xmax = (1 - sx0) - margin, (width - sx0) + margin
    local ymin, ymax = (sy0 - rows) - margin, (sy0 - 1) + margin

    local order = {}
    for ruid, at in pairs(layout) do
        local nx, ny = at.x * step, at.y * step

        if nx >= xmin and nx <= xmax and ny >= ymin and ny <= ymax then
            order[#order + 1] = { uid = ruid, x = at.x, y = at.y }
        end
    end

    table.sort(order, function(a, b)
        if a.y ~= b.y then
            return a.y > b.y
        end
        return a.x < b.x
    end)

    local glyphs = LINK_GLYPHS

    for _, node in ipairs(order) do
        local room = rooms[node.uid]
        local nx, ny = node.x * step, node.y * step

        if node.uid == root_uid then
            put(nx, ny, CURRENT_MARKER, CODES.you)
        else
            local st = room_style(room)
            if not opts.flags and SPECIAL[st.key] then st = PLAIN end

            put(nx, ny, st.glyph, cell_color(st, trail_rank[node.uid]))
        end

        -- A link only where this exit really leads to the room placed in
        -- the cell that direction points at.
        if type(room.exits) == "table" then
            for i = 1, #DIR_ORDER do
                local dir = DIR_ORDER[i]
                local e = room.exits[dir]

                if e then
                    local dest = type(e) == "string" and e or exit_uid(e)
                    local t = dest and layout[dest]
                    local d = DELTA[dir]

                    if t and t.x == node.x + d[1] and t.y == node.y + d[2] then
                        put(nx + d[1], ny + d[2], glyphs[dir], CODES.links, true)
                    end
                end
            end
        end
    end

    -- Exits to rooms the mapper doesn't have yet.
    local n_unexplored, seen = 0, {}

    for _, u in ipairs(unknown) do
        if not occupied[u.k] and not seen[u.k] then
            seen[u.k] = true
            n_unexplored = n_unexplored + 1

            put(u.x * step, u.y * step, UNEXPLORED_MARKER, CODES.unexplored, true)

            local d = DELTA[u.dir]
            put(u.fx * step + d[1], u.fy * step + d[2], glyphs[u.dir],
                CODES.links, true)
        end
    end

    view_stats = string.format("layout: %d rooms, %d unexplored, reach %d",
        placed, n_unexplored, depth)

    for sy = 1, rows do
        local cy = sy0 - sy
        local chars, codes = {}, {}

        for sx = 1, width do
            local k = key_of(sx - sx0, cy)

            chars[sx] = gch[k] or " "
            codes[sx] = gcode[k] or false
        end

        lines[#lines + 1] = paint_row(chars, codes)
    end

    write_pane(table.concat(lines, "\n"))
    last_sig = sig
end

draw = function()
    local clock = DEBUG and os.clock or nil
    local t0 = clock and clock() or 0

    local ok, err = pcall(draw_impl)

    if not ok then
        redraw_pending = false
        last_sig = nil
        force_pane(NAME .. " error:\n" .. clean(err))
        if DEBUG then
            dbg("draw error: %s", tostring(err))
        end
    elseif clock then
        dbg("draw %.2f ms | %s", (clock() - t0) * 1000, view_stats)
    end
end

local function later(delay)
    if redraw_pending then
        return
    end

    if rune.timer and rune.timer.after then
        redraw_pending = true
        if DEBUG then dbg("follow-up redraw in %.2fs", delay) end
        rune.timer.after(delay, draw)
    end
end

local function request_draw()
    if not enabled then
        return
    end

    draw()
    if needs_followup then
        later(0.25)
    end
end

local function request_later_draw()
    epoch = epoch + 1
    if enabled then
        later(0.1)
    end
end

-----------------------------------------------------------------------
-- Pane utilities: legend, debug dump, flags and tags list, calibrate
-----------------------------------------------------------------------

local function legend()
    local width = detect_size()
    local items, seen = {}, {}

    local function add(glyph, code, label)
        local key = glyph .. "|" .. code
        if not seen[key] then
            seen[key] = true
            items[#items + 1] = {
                text = paint_text(glyph, code) .. " " .. label,
                len = #glyph + 1 + #label,
            }
        end
    end

    add(CURRENT_MARKER, CODES.you, "you")
    add(UNEXPLORED_MARKER, CODES.unexplored, "unexplored exit")
    add("x", CODES.pk, "pk")
    add("T", CODES.trainer, "trainer")
    add("$", CODES.shop, "shop")
    add("S", CODES.safe, "safe")
    add("^", CODES.stairs, "up")
    add("v", CODES.stairs, "down")
    add("%", CODES.stairs, "up+down")
    add("#", CODES.road, "road")
    add("o", CODES.room, "room")

    local out = { paint_text(NAME .. " legend", CODES.header) }
    local line, len = {}, 0

    local function flush()
        if #line > 0 then
            out[#out + 1] = table.concat(line, "  ")
            line, len = {}, 0
        end
    end

    for _, item in ipairs(items) do
        if len > 0 and len + 2 + item.len > width then
            flush()
        end

        line[#line + 1] = item.text
        len = len + item.len + (#line > 1 and 2 or 0)
    end

    flush()

    out[#out + 1] = paint_text("dark", CODES.room .. ";" .. CODES.dark) .. " = dark room"
    out[#out + 1] = paint_text("trail", trail_code(1))
        .. " = path you walked (fades with age)"

    force_pane(table.concat(out, "\n"))
end

local function debug_dump()
    local out = {}

    if type(current_info) == "table" then
        local parts = {}
        for k, v in pairs(current_info) do
            if type(v) ~= "table" and type(v) ~= "function" then
                parts[#parts + 1] = clean(k) .. "=" .. clean(v)
            end
        end
        table.sort(parts)
        out[#out + 1] = "Room.Info: " .. table.concat(parts, " ")
    else
        out[#out + 1] = "Room.Info: none yet"
    end

    local s = store
    local w, h, src = detect_size()

    out[#out + 1] = string.format("pane size %sx%s (%s)", tostring(w), tostring(h), src)

    local total = 0
    for _ in pairs(s.rooms) do
        total = total + 1
    end

    local uid = info_uid(current_info)
    local stored = uid and s.get(uid)
    local c = stored and stored.coord
    if type(c) ~= "table" then c = {} end

    out[#out + 1] = string.format("store rooms %d", total)
    out[#out + 1] = string.format("here: %s,%s,%s | %s",
        tostring(c.x), tostring(c.y), tostring(c.z), view_stats)
    out[#out + 1] = string.format("flags=[%s] tags=[%s] glyph=%s",
        clean(token_list(stored and stored.flags)),
        clean(token_list(stored and stored.tags)),
        stored and room_style(stored).glyph or "-")

    force_pane(table.concat(out, "\n"))
end

-- Draws a frame of exactly W x H characters (the size the map would use).
-- If all four + corners show and no line wraps, the pane fits that size.
local function calibrate(w, h)
    local dw, dh = detect_size()
    w = clamp(math.floor(tonumber(w) or dw), MIN_W, MAX_W)
    h = clamp(math.floor(tonumber(h) or dh), MIN_H, MAX_H)
    local inner = w - 2

    -- Top and bottom edges: + corners, a tens digit every 10 columns, : every 5.
    local t = {}
    for c = 1, w do
        if c == 1 or c == w then
            t[c] = "+"
        elseif c % 10 == 0 then
            t[c] = tostring(math.floor(c / 10) % 10)
        elseif c % 5 == 0 then
            t[c] = ":"
        else
            t[c] = "-"
        end
    end
    local edge = paint_text(table.concat(t), "36")

    local notes = {
        string.format("%d x %d", w, h),
        "all 4 + corners visible",
        "and no wrapped lines",
        "= this size fits",
        "too big? try smaller",
        "room left? try bigger",
        NAME .. " size " .. w .. " " .. h,
    }

    -- Side rows: row number at both edges, so the last visible row is easy to read.
    local function row(r, note)
        local lab = tostring(r)
        local body = (note and (lab .. " " .. note) or lab):sub(1, inner)
        local right = (#body + #lab < inner) and lab or ""
        return "|" .. body .. string.rep(" ", inner - #body - #right) .. right .. "|"
    end

    local lines = { edge }
    for r = 2, h - 1 do
        lines[#lines + 1] = row(r, notes[r - 1])
    end
    lines[#lines + 1] = edge

    force_pane(table.concat(lines, "\n"))
end

-----------------------------------------------------------------------
-- Setup
-----------------------------------------------------------------------

-- The layout in init.lua declares the pane (title and border); this only
-- makes sure it exists.
if rune.pane and rune.pane.create then
    rune.pane.create(PANE_ID)
end

local function set_enabled(value)
    enabled = value
    if enabled then
        show_pane()
        draw()
    else
        hide_pane()
    end
end

-----------------------------------------------------------------------
-- Output and help
-----------------------------------------------------------------------

-- Output: one row, with the coloured plugin-name prefix.
local style = rune.style

local function paint(msg)
    local prefix = "[" .. NAME .. "] "

    if style and type(style.cyan) == "function" then
        prefix = style.cyan(prefix)
    end

    return prefix .. msg
end

local function say(msg)
    if type(rune.echo) == "function" then
        rune.echo(paint(msg))
    else
        force_pane("[" .. NAME .. "] " .. msg)
    end
end

-- helpstyle is only needed when help is shown, so it loads on first use.
local H = nil

local function helpstyle()
    if H == nil then
        local ok, mod = pcall(require, "helpstyle")
        if ok and type(mod) == "table" then
            H = mod
        else
            H = {
                title   = function(t) return t end,
                section = function(t) return t end,
                line    = function(c, d) return string.format("  %-32s %s", c, d) end,
                foot    = function(t) return t end,
            }
        end
    end
    return H
end

local function onoff(v) return v and "on" or "off" end

local function help_status()
    local w, h = detect_size()
    return string.format(
        "v%s  enabled=%s zone=%s size=%sx%s debug=%s load=%dms",
        VERSION, onoff(enabled), opts.zone and "same" or "any",
        tostring(w), tostring(h), onoff(DEBUG), load_ms)
end

local function show_help(note)
    local h = helpstyle()
    local out = {}
    local function emit(text) out[#out + 1] = text end
    local function row(cmd, desc)
        emit(h.line(cmd == "" and NAME or (NAME .. " " .. cmd), desc))
    end

    if note then emit(paint(note)) end

    emit(h.title(NAME .. " - ASCII map of the rooms around you"))
    emit(h.section("Display:"))
    row("", "show this summary")
    row("on|off", "show or hide the map pane")
    row("zone on|off", "stay in this zone / cross borders")
    row("colours|colors", "list or change the map colours")
    row("refresh", "force a redraw")
    row("reset", "restore defaults")
    row("legend", "what the symbols mean")
    emit(h.section("Overlays:"))
    row("flags on|off", "mark x T $ S rooms, dark [" .. onoff(opts.flags) .. "]")
    row("trail on|off", "colour rooms you walked [" .. onoff(opts.trail) .. "]")
    emit(h.section("Size:"))
    row("size <W> <H>", "set pane size (per character)")
    row("size auto", "back to the default size")
    row("calibrate [W H]", "test frame to find the size")
    emit(h.section("Info:"))
    row("debug", "size and room data")
    row("debug on|off", "debug logging (default off)")
    emit(h.line(SHORT, "short alias for " .. NAME))
    emit(h.foot(help_status()))

    if type(rune.echo) == "function" then
        for _, line in ipairs(out) do rune.echo(line) end
    else
        show_pane()
        force_pane(table.concat(out, "\n"))
    end
end

-----------------------------------------------------------------------
-- Colours: the codes are applied here; asciiMapColours.lua (loaded only when
-- `amp colours` is used) holds the schemes and the editing commands
-----------------------------------------------------------------------

local COLOURS_KEY = "asciiMapPane.colours"

-- Apply the saved colour codes at startup. Only digits and ; are accepted,
-- so nothing but a colour sequence can reach the terminal.
local function load_codes()
    if not (rune.store and type(rune.store.get) == "function") then return end

    local ok, saved = pcall(rune.store.get, COLOURS_KEY)
    if not ok or type(saved) ~= "table" or type(saved.codes) ~= "table" then return end

    for k, v in pairs(saved.codes) do
        if CODES[k] ~= nil and type(v) == "string" and #v <= 40
            and v:match("^%d[%d;]*$") then
            CODES[k] = v
        end
    end
end

-- amp reset: back to the 16-colour defaults (a custom scheme is kept).
local function reset_colours()
    for k, v in pairs(DEFAULT_CODES) do CODES[k] = v end

    local ok, cur = pcall(rune.store.get, COLOURS_KEY)
    if ok and type(cur) == "table" then
        cur.scheme, cur.codes = "basic", nil
        pcall(rune.store.set, COLOURS_KEY, cur)
    end
end

local COLOURS_MODULES = { "eljayPlugins/asciiMapColours", "asciiMapColours" }
local colour_api

local function colours_command(words)
    local mod, err

    for _, name in ipairs(COLOURS_MODULES) do
        local ok, m = pcall(require, name)

        if ok and type(m) == "table" and m.run then
            mod = m
            break
        end

        err = err or tostring(ok and "no run() in module" or m)   -- keep the first
    end

    if not mod then
        say("colours module not loaded: " .. clean(err):sub(1, 60))
        say("expected: " .. (rune.config_dir or ".") .. "/eljayPlugins/asciiMapColours.lua")
        return
    end

    colour_api = colour_api or {
        CODES = CODES, NAME = NAME, SHORT = SHORT, clean = clean, say = say,
        paint = paint, paint_text = paint_text, helpstyle = helpstyle,
        help_status = help_status,
        redraw = function() last_pane_text = nil; draw() end,
    }
    mod.run(words, colour_api)
end

-----------------------------------------------------------------------
-- Saved settings (rune.store); debug is deliberately not saved
-----------------------------------------------------------------------

local SETTINGS_KEY = "asciiMapPane.settings"
local SIZE_KEY = "asciiMapPane.size"   -- per character once the name is known
local saved_sig = {}

local function get_table(key)
    if not (rune.store and rune.store.get) then return nil end

    local ok, t = pcall(rune.store.get, key)
    if ok and type(t) == "table" then return t end
end

-- Read the latest stored table, change only our keys, write it back; skipped
-- when sig is what was last saved under that key.
local function save_to(key, fields, sig)
    if saved_sig[key] == sig or not (rune.store and rune.store.set) then return end

    local cur = get_table(key) or {}
    for k, v in pairs(fields) do cur[k] = v end

    if pcall(rune.store.set, key, cur) then saved_sig[key] = sig end
end

local function save_settings()
    save_to(SETTINGS_KEY,
        { enabled = enabled, flags = opts.flags, trail = opts.trail, zone = opts.zone },
        table.concat({ tostring(enabled), tostring(opts.flags),
            tostring(opts.trail), tostring(opts.zone) }, "|"))
end

local function load_settings()
    local saved = get_table(SETTINGS_KEY)
    if not saved then return end

    if type(saved.enabled) == "boolean" then enabled = saved.enabled end

    for _, name in ipairs({ "flags", "trail", "zone" }) do
        if type(saved[name]) == "boolean" then opts[name] = saved[name] end
    end
end

-- The custom pane size is saved per character, as mapper_map.lua saves its
-- settings: until the name is known the plain key is used.
local function size_key()
    if charname.get() then return charname.key(SIZE_KEY) end
    return SIZE_KEY
end

-- This character's size, else the plain key, else the old shared settings.
local function load_size()
    local found

    for _, key in ipairs({ size_key(), SIZE_KEY, SETTINGS_KEY }) do
        found = get_table(key)
        if found then break end
    end

    local w, h = tonumber(found and found.w), tonumber(found and found.h)
    manual_w = w and h and clamp(math.floor(w), MIN_W, MAX_W) or nil
    manual_h = w and h and clamp(math.floor(h), MIN_H, MAX_H) or nil
    saved_sig[size_key()] = nil
end

local function save_size()
    local key = size_key()

    save_to(key, { w = manual_w or false, h = manual_h or false },
        table.concat({ key, tostring(manual_w), tostring(manual_h) }, "|"))
end

load_settings()
load_size()
load_codes()

if not enabled then hide_pane() end

-----------------------------------------------------------------------
-- Command
-----------------------------------------------------------------------

local function redraw_now()
    last_pane_text = nil
    draw()
end

local function reset_all()
    enabled = true
    opts.flags, opts.trail, opts.zone = true, true, true
    manual_w, manual_h = nil, nil
    reset_colours()
    reset_caches()
    show_pane()
    redraw_now()
    say("settings reset to defaults")
end

local function set_size(words)
    local w, h = tonumber(words[2]), tonumber(words[3])

    if w and h then
        local cw = clamp(math.floor(w), MIN_W, MAX_W)
        local ch = clamp(math.floor(h), MIN_H, MAX_H)
        manual_w, manual_h = cw, ch

        if cw ~= w or ch ~= h then
            say(string.format("size limited to %dx%d (allowed %d-%d x %d-%d)",
                cw, ch, MIN_W, MAX_W, MIN_H, MAX_H))
        end
    else
        manual_w, manual_h = nil, nil
    end

    redraw_now()
end

local COMMANDS = {
    on = function() set_enabled(true) end,
    off = function() set_enabled(false) end,
    debug = function(words)
        if words[2] == "on" or words[2] == "off" then
            DEBUG = (words[2] == "on")
            say("debug logging " .. onoff(DEBUG))
        else
            debug_dump()
        end
    end,
    calibrate = function(words) calibrate(words[2], words[3]) end,
    colours = colours_command,
    colors = colours_command,
    legend = legend,
    refresh = function() reset_caches() redraw_now() end,
    reset = reset_all,
    size = set_size,
}

local function run_command_impl(arg_text)
    epoch = epoch + 1

    local words = {}
    for word in tostring(arg_text or ""):gmatch("%S+") do words[#words + 1] = word:lower() end
    local action = words[1] or ""

    if action == "" then
        show_help()
    elseif COMMANDS[action] then
        COMMANDS[action](words)
    elseif opts[action] ~= nil then
        opts[action] = (words[2] ~= "off")
        redraw_now()
    else
        show_help("unknown option '" .. clean(action):sub(1, 20) .. "'")
    end

    save_settings()
    save_size()
end

local function run_command(arg_text)
    if DEBUG then dbg("command: '%s'", tostring(arg_text)) end
    local ok, err = pcall(run_command_impl, arg_text)
    if not ok then force_pane(NAME .. " error:\n" .. clean(err)) end
end

-- Bare command only (no / prefix): one regex alias covers the full command
-- and the short alias, because the command takes arguments.
if rune.alias and rune.alias.regex then
    pcall(rune.alias.regex, "^(?:" .. NAME .. "|" .. SHORT .. ")\\b(.*)$", function(match)
        run_command(match[1])
    end, { name = NAME })
end

-- The name arrives a moment after login, and the size is keyed on it.
if charname.on_change then
    charname.on_change(function()
        load_size()
        last_sig = nil
        if enabled then draw() end
    end)
end

-- Wilds: after a compass frame the game sends its own map (11 rows). Only
-- its roads (#) and you (@) are shown; see draw_impl.
local WILDS_FRAME = "^\\(-{10,}\\)\\s+\\S+ <---\\(M\\)---> \\S+\\s*$"
local WILDS_LINES = 13   -- frame line, compass row, then the 11 map rows
local wilds_pending, wilds_n = nil, 0

local function wilds_text(line)
    if type(line) == "string" then return line end
    local ok, text = pcall(function() return line:clean() end)
    return ok and tostring(text) or ""
end

-- The map and Room.Info can arrive in either order, so the map is attached
-- to whatever room is current a moment after it arrived.
local function wilds_commit(n)
    if n ~= wilds_n or not wilds_pending then return end

    wilds, wilds_uid, wilds_pending = wilds_pending, info_uid(current_info), nil
    last_sig = nil
    draw()
end

-- A room that sent no map is not the wilds: back to the normal view.
local function wilds_check()
    if wilds and wilds_uid ~= info_uid(current_info) then
        wilds, wilds_uid = nil, nil
        last_sig = nil
        draw()
    end
end

local function wilds_capture(_, ctx)
    if not enabled or type(ctx) ~= "table" or type(ctx.lines) ~= "table" then return end

    local rows, r0, c0 = {}, nil, nil

    for i = 3, #ctx.lines do
        local text = wilds_text(ctx.lines[i])
        if text:find("%l") then break end   -- description or objects: the map is over

        rows[#rows + 1] = text
        local c = text:find("@", 1, true)
        if c then r0, c0 = #rows, c end
    end

    if not r0 or #rows < 3 then return end

    wilds_id, wilds_n = wilds_id + 1, wilds_n + 1
    wilds_pending = { rows = rows, r0 = r0, c0 = c0, id = wilds_id }

    local n = wilds_n
    if rune.timer and rune.timer.after then
        rune.timer.after(0.3, function() wilds_commit(n) end)
    else
        wilds_commit(n)
    end
end

if rune.trigger and rune.trigger.regex then
    pcall(rune.trigger.regex, WILDS_FRAME, wilds_capture,
        { name = NAME .. ".wilds", span = { max = WILDS_LINES } })
end

if rune.gmcp and rune.gmcp.on then
    rune.gmcp.on("Room.Info", function(data)
        if type(data) ~= "table" then return end
        current_info = data
        local uid = info_uid(data)
        if DEBUG then dbg("Room.Info uid=%s", tostring(uid)) end
        if uid and uid ~= history[1] then
            table.insert(history, 1, uid)
            history[TRAIL_LENGTH + 2] = nil
        end
        request_draw()
        if wilds and rune.timer and rune.timer.after then
            rune.timer.after(0.6, wilds_check)
        end
    end, { name = NAME })
end

-- On look: forget the trail and redraw, so the fading trail is removed.
if rune.hooks and rune.hooks.on then
    rune.hooks.on("input", function(text)
        if #text > 12 then return end

        local cmd = text:lower():match("^%s*(%S+)%s*$")

        if cmd == "look" or cmd == "l" then
            for i = #history, 2, -1 do history[i] = nil end
            last_sig = nil
            if enabled then draw() end
        end
    end, { name = NAME .. ".look" })
end

if rune.hooks and rune.hooks.on then
    rune.hooks.on("mapper_room_changed", function() request_later_draw() end)
end

write_pane(NAME .. " loaded; waiting for Room.Info...")

load_ms = ((os.clock and os.clock() or 0) - T0) * 1000

-- Single-row loader line.
say("v" .. VERSION .. " loaded (" .. NAME .. " or " .. SHORT .. " for help)")