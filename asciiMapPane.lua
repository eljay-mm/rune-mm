-- Filename: eljayPlugins/asciiMapPane.lua
-- Purpose: ASCII map pane for Rune + horstgs Materia Magica.
-- Version: 2.11
-- Date: 2026-Oct-21
--
--[[ Todo:
- insert planning notes here between revisions.
--]]
--
-- Changelog:
--   2.11  calibrate now draws a labelled frame of the exact size to test (the
--         current size, or calibrate <W> <H>), so you can see whether it fits.
--   2.10  Brought to standard from the v2.7 baseline. Removed the disabled
--         map.db fallback reader and the store-loading state (about 250 lines);
--         store search stops at the first usable store and retries every 5s.
--         Short alias amp; NAME/SHORT locals; one regex alias for both names;
--         helpstyle loaded only when help is shown; settings saved with
--         read-modify-write; load time in the help footer; named GMCP handler.
--         (v2.8/2.9 changes are not in this file.)
--   2.7   Layout and links follow mapper_map.lua (exit-graph walk, rooms two
--         characters apart, link only when the exit leads to the placed room).
-- How it works:
--   * Rune sends GMCP Room.Info on every move; the plugin keeps the latest room and redraws the pane.
--   * Inspired by mapper_map.lua in the horstgs Rune configuration: the layout comes from the exit graph, not from room coordinates, which are unreliable.
--   * From your room it walks the exits breadth-first in a fixed order (n ne e se s sw w nw); each exit is one step, and the first room to reach a cell keeps it.
--   * By default only rooms in the same zone and on the same floor are placed; up, down, in and out exits are not drawn.
--   * Rooms sit two characters apart, so every cell between two rooms belongs to exactly one link; a link (- | / \ or box lines) is drawn only when that exit leads to the room placed in that cell.
--   * Exits to rooms the mapper has not stored yet show as ?; rooms are symbolled and coloured by terrain, flags and name, with your recent trail highlighted and far rooms faded.
--   * Redraws are skipped when nothing relevant changed; settings are saved with rune.store, and debug output stays off unless enabled.
--   * Server-supplied text is stripped of control characters before display to protect the terminal from injected escapes.
--   * Typing the command on its own shows a help summary using helpstyle, with the version at the start of the footer row.
--
-- Commands:
--   asciiMapPane (amp)                    show this summary
--   asciiMapPane on|off                   show or hide the map pane
--   asciiMapPane compact|spaced           1 char per room, no links / rooms two apart with links (default)
--   asciiMapPane zone on|off              stay in the current zone (default) / cross zone borders
--   asciiMapPane links unicode|ascii      link line characters
--   asciiMapPane color on|off             ANSI colours on/off
--   asciiMapPane flags|trail|dim on|off   overlays
--   asciiMapPane size <W> <H>|auto        set pane size in characters
--   asciiMapPane calibrate [W H]          draw a test frame of that size (default: current)
--   asciiMapPane pad <N>                  border allowance
--   asciiMapPane debug on|off             debug logging (default off)
--   asciiMapPane help                     show this summary

local T0 = os.clock and os.clock() or 0
local VERSION = "2.11"

-- Command names: full command and short alias.
local NAME  = "asciiMapPane"
local SHORT = "amp"

local PANE_ID = "eljayPlugins/asciiMapPane"

-- Rune's pane API has no size query, so this is the "auto" size. Edit
-- these two numbers (or use asciiMapPane size W H) to match your pane.
local DEFAULT_W = 42
local DEFAULT_H = 15

-- Limits (input validation / resource safety).
local MIN_W, MAX_W = 10, 200
local MIN_H, MAX_H = 3, 100
local MAX_PAD = 10

local ROOM_MARKER    = "o"
local UP_MARKER      = "^"
local DOWN_MARKER    = "v"
local UPDOWN_MARKER  = "%"
local CURRENT_MARKER = "@"

local enabled = true
local redraw_pending = false
local current_info = nil
local last_pane_text = nil
local load_ms = 0

local manual_w, manual_h = nil, nil
local use_color = true
local compact = false   -- spaced (links) is the default view
local border_pad = 2

-- Redraw skipping
local last_sig = nil
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

local store, store_source, store_note = nil, "none", nil
local next_find = 0

local function usable(t)
    return type(t) == "table"
        and type(rawget(t, "rooms")) == "table"
        and type(rawget(t, "get")) == "function"
        and next(rawget(t, "rooms")) ~= nil
end

-- First usable store wins: well-known names first, then a scan.
local function find_store()
    local function try(label, value)
        if usable(value) then
            return value, label
        end
    end

    local s, label = try("_G.mapper_store", _G.mapper_store)
    if s then return s, label end

    if type(_G.mapper) == "table" then
        s, label = try("_G.mapper.store", _G.mapper.store)
        if s then return s, label end
        s, label = try("_G.mapper", _G.mapper)
        if s then return s, label end
    end

    for _, name in ipairs({ "mapper_store", "eljayPlugins.mapper_store" }) do
        s, label = try("package.loaded." .. name, package.loaded[name])
        if s then return s, label end
    end

    pcall(function()
        for name, value in pairs(package.loaded) do
            s, label = try("package.loaded." .. tostring(name), value)
            if s then return end
        end
        for name, value in pairs(_G) do
            s, label = try("_G." .. tostring(name), value)
            if s then return end
        end
    end)
    if s then return s, label end

    for _, name in ipairs({ "mapper_store", "eljayPlugins.mapper_store" }) do
        local ok, mod = pcall(require, name)
        s, label = try("require(" .. name .. ")", ok and mod or nil)
        if s then return s, label end
    end

    return nil, "none"
end

local function get_store()
    if usable(store) then
        return store
    end

    local now = os.time and os.time()
    if not now or now >= next_find then
        local found, label = find_store()
        if found then
            store, store_source = found, label
            if DEBUG then dbg("store -> %s", label) end
            return store
        end
        next_find = (now or 0) + 5
    end

    store_note = "mapper store not found (retrying)."
    return nil
end

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

    if not rune.pane then
        return
    end

    local done = false

    if type(rune.pane.replace) == "function" then
        done = pcall(rune.pane.replace, PANE_ID, text)
    end

    if not done then
        if rune.pane.clear then
            rune.pane.clear(PANE_ID)
        end

        if rune.pane.write then
            rune.pane.write(PANE_ID, text)
        end
    end

    if type(rune.pane.scroll_to_top) == "function" then
        pcall(rune.pane.scroll_to_top, PANE_ID)
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

local SIZE_FNS = {
    "size", "get_size", "dimensions", "dims", "info", "get",
    "metrics", "rect", "bounds",
}

local function detect_size_raw()
    if manual_w and manual_h then
        return manual_w, manual_h, "manual"
    end

    local p = rune.pane

    if type(p) == "table" then
        for _, name in ipairs(SIZE_FNS) do
            if type(p[name]) == "function" then
                local ok, a, b = pcall(p[name], PANE_ID)
                if ok then
                    if type(a) == "table" then
                        a, b = a.width or a.w or a.cols or a.columns,
                            a.height or a.h or a.rows or a.lines
                    end

                    a, b = tonumber(a), tonumber(b)
                    if a and b and a > 0 and b > 0 then
                        return a - border_pad, b - border_pad, "pane." .. name
                    end
                end
            end
        end

        if type(p.width) == "function" and type(p.height) == "function" then
            local ok1, w = pcall(p.width, PANE_ID)
            local ok2, h = pcall(p.height, PANE_ID)
            w, h = tonumber(w), tonumber(h)
            if ok1 and ok2 and w and h and w > 0 and h > 0 then
                return w - border_pad, h - border_pad, "pane.width/height"
            end
        end
    end

    return DEFAULT_W, DEFAULT_H, "default"
end

local function detect_size()
    local w, h, src = detect_size_raw()
    return clamp(math.floor(w), MIN_W, MAX_W),
        clamp(math.floor(h), MIN_H, MAX_H), src
end

-----------------------------------------------------------------------
-- Header and exits lines
-----------------------------------------------------------------------

local EXIT_ORDER = {
    "n", "ne", "e", "se", "s", "sw", "w", "nw", "u", "d", "in", "out",
}

local function header_line(info, stored, width)
    local name = info.name or (stored and stored.name) or "Unknown room"
    local area = info.area or info.zone or (stored and stored.area)
        or (type(info.coord) == "table" and info.coord.name)
        or "Unknown zone"

    local text = string.format("%s %s | %s",
        clean(info_uid(info) or (stored and stored.uid) or "?"),
        clean(name), clean(area))

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

local GLYPHS = {
    { "~", { "water", "swim", "ocean", "river", "lake", "sea" }, "34" },
    { "#", { "road", "street", "path", "trail", "lane", "city", "town",
             "urban", "paved" }, "33" },
    { "$", { "shop" }, "32" },
    { "o", { "forest", "wood", "jungle", "tree" }, "32" },
    { "o", { "mountain", "hill", "peak" }, "90" },
    { "o", { "inside", "indoor", "building", "house", "cave",
             "dungeon", "tunnel" }, "36" },
}

local DEFAULT_ROOM_COLOR = "37"

local NAME_GLYPHS = {
    { "#", { "road", "street", "trail", "path", "lane", "avenue", "alley",
             "highway", "boulevard", "crossroads", "bridge" }, "33" },
    { "$", { "shop", "store", "market", "bazaar" }, "32" },
}

local FLAG_FG  = { { "safe", "92" } }
local FLAG_MOD = { { "dark", "2" } }

local UNEXPLORED_MARKER = "?"

local TRAIL_LENGTH = 6
local TRAIL_COLORS = { "1;95", "95", "35", "35", "2;35", "2;35" }
local DIM_START = 0.7

local ESC = string.char(27)

local COLORS = {
    ["@"] = "1;97;45",
    ["?"] = "1;91",
    ["#"] = "33", ["$"] = "32", ["o"] = "37", ["~"] = "34",
    ["^"] = "1;92", ["v"] = "1;92", ["%"] = "1;92",
    ["-"] = "90", ["|"] = "90", ["/"] = "90", ["\\"] = "90",
    ["X"] = "90",
}

local opts = { flags = true, trail = true, dim = true, zone = true }

local history = {}

local function first_match(entries, text, plain_words)
    for _, entry in ipairs(entries) do
        for _, word in ipairs(entry[2]) do
            local hit
            if plain_words then
                hit = text:find("%f[%a]" .. word .. "%f[%A]")
            else
                hit = text:find(word, 1, true)
            end

            if hit then
                return entry[1], entry[3]
            end
        end
    end

    return nil
end

local function compute_style(room)
    local glyph, color
    local up = has_exit(room, "u")
    local down = has_exit(room, "d")

    if up and down then
        glyph = UPDOWN_MARKER
    elseif up then
        glyph = UP_MARKER
    elseif down then
        glyph = DOWN_MARKER
    end

    if glyph then
        color = COLORS[glyph]
    else
        local text = (tostring(room.terrain or "") .. " "
            .. tostring(room.terraininfo or "") .. " "
            .. tostring(room.flags or "")):lower()

        if text:match("%S") then
            glyph, color = first_match(GLYPHS, text, false)
        end

        if not glyph or glyph == ROOM_MARKER then
            local name = tostring(room.name or ""):lower():gsub("[^%a]", " ")
            local g, c = first_match(NAME_GLYPHS, " " .. name .. " ", true)

            if g then
                glyph, color = g, c
            end
        end

        if not glyph then
            glyph, color = ROOM_MARKER, DEFAULT_ROOM_COLOR
        end
    end

    local flags = tostring(room.flags or ""):lower()
    local fg, mod

    for _, f in ipairs(FLAG_FG) do
        if flags:find(f[1], 1, true) then
            fg = f[2]
            break
        end
    end

    for _, f in ipairs(FLAG_MOD) do
        if flags:find(f[1], 1, true) then
            mod = f[2]
            break
        end
    end

    return { glyph = glyph, color = color or DEFAULT_ROOM_COLOR,
        flag_fg = fg, flag_mod = mod }
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

local function cell_color(st, rank, dist)
    local code = st.color

    if opts.flags then
        if st.flag_fg then
            code = st.flag_fg
        end

        if st.flag_mod then
            code = st.flag_mod .. ";" .. code
        end
    end

    if rank and opts.trail then
        return TRAIL_COLORS[math.min(rank, #TRAIL_COLORS)]
    end

    if opts.dim and dist > DIM_START and code:sub(1, 2) ~= "2;" then
        code = "2;" .. code
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
local MIN_DEPTH, MAX_DEPTH = 12, 30    -- rooms of reach from your room
local MAX_NODES = 4000

-- Link glyphs per direction.
local LINK_GLYPHS = {
    unicode = { n = "\226\148\130", s = "\226\148\130",
        e = "\226\148\128", w = "\226\148\128",
        ne = "\226\149\177", sw = "\226\149\177",
        nw = "\226\149\178", se = "\226\149\178" },
    ascii = { n = "|", s = "|", e = "-", w = "-",
        ne = "/", sw = "/", nw = "\\", se = "\\" },
}

local link_style = "unicode"
local LINK_CODE = "90"

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
        area = info.area or info.zone, terrain = info.terrain,
        terraininfo = info.terraininfo, flags = info.flags,
        coord = info.coord, exits = {} }

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
local function build_layout(s, start, root_uid, area, root_z, depth, same_zone)
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

    for _ = 1, depth do
        local nxt = {}

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
                                nxt[#nxt + 1] = { uid = dest, room = dest_room,
                                    x = x, y = y }
                            end
                        end
                    end
                end
            end
        end

        frontier = nxt

        if #frontier == 0 or count >= MAX_NODES then
            break
        end
    end

    return layout, rooms, occupied, unknown, count
end

-----------------------------------------------------------------------
-- Colour output
-----------------------------------------------------------------------

local function paint_text(text, code)
    if not use_color then
        return text
    end
    return ESC .. "[" .. code .. "m" .. text .. ESC .. "[0m"
end

local function paint_row(chars, codes)
    if not use_color then
        return table.concat(chars)
    end

    local out, current = {}, nil

    for i = 1, #chars do
        local ch = chars[i]
        local code = codes[i]

        if ch == " " then
            code = nil
        elseif not code then
            code = COLORS[ch]
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

    local s = get_store()
    if not s then
        write_pane(store_note or "mapper_store not found.")
        return
    end

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
        compact and 1 or 0, use_color and 1 or 0, link_style,
        opts.flags and 1 or 0, opts.trail and 1 or 0,
        opts.dim and 1 or 0, opts.zone and 1 or 0,
        table.concat(history, ","), table.concat(es, ","),
    }, "|")

    if sig == last_sig and not needs_followup then
        if DEBUG then dbg("draw skipped (unchanged)") end
        return
    end

    local header = header_line(current_info, stored, width)
    local rows = math.max(height - 2, 1)    -- header + exits lines
    local sx0 = math.floor((width + 1) / 2) -- centre column
    local sy0 = math.floor((rows + 1) / 2)  -- centre row

    local lines = {
        paint_text(header, "1;37"),
        paint_text(exits_line(start, current_info, width), "36"),
    }

    -- Rooms visible each side of you, and how far to walk to fill the pane.
    local step = compact and 1 or 2         -- characters per room step
    local half_w = math.max(width / (2 * step), 1)
    local half_h = math.max(rows / (2 * step), 1)
    local depth = clamp(math.ceil(math.max(half_w, half_h)) + 1,
        MIN_DEPTH, MAX_DEPTH)

    local area = start.area or (stored and stored.area)
    local zc = (stored and stored.coord) or start.coord
    local root_z = type(zc) == "table" and tonumber(zc.z) or nil
    local root_uid = tostring(uid or start.uid or "?")

    local layout, rooms, occupied, unknown, placed =
        build_layout(s, start, root_uid, area, root_z, depth, opts.zone)

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

    local glyphs = LINK_GLYPHS[link_style] or LINK_GLYPHS.unicode
    local abs = math.abs

    for _, node in ipairs(order) do
        local room = rooms[node.uid]
        local nx, ny = node.x * step, node.y * step

        if node.uid == root_uid then
            put(nx, ny, CURRENT_MARKER, nil)
        else
            local st = room_style(room)
            local dist = math.max(abs(node.x) / half_w, abs(node.y) / half_h)

            put(nx, ny, st.glyph,
                cell_color(st, trail_rank[node.uid], dist))
        end

        -- A link only where this exit really leads to the room placed in
        -- the cell that direction points at.
        if not compact and type(room.exits) == "table" then
            for i = 1, #DIR_ORDER do
                local dir = DIR_ORDER[i]
                local e = room.exits[dir]

                if e then
                    local dest = type(e) == "string" and e or exit_uid(e)
                    local t = dest and layout[dest]
                    local d = DELTA[dir]

                    if t and t.x == node.x + d[1] and t.y == node.y + d[2] then
                        put(nx + d[1], ny + d[2], glyphs[dir], LINK_CODE, true)
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

            put(u.x * step, u.y * step, UNEXPLORED_MARKER, nil, true)

            if not compact then
                local d = DELTA[u.dir]
                put(u.fx * step + d[1], u.fy * step + d[2], glyphs[u.dir],
                    LINK_CODE, true)
            end
        end
    end

    view_stats = string.format("layout: %d rooms, %d unexplored, depth %d",
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
-- Pane utilities: legend, debug dump, terrains, calibration ruler
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

    add(CURRENT_MARKER, COLORS["@"], "you")
    add(UNEXPLORED_MARKER, COLORS["?"], "unexplored exit")

    for _, entry in ipairs(GLYPHS) do
        add(entry[1], entry[3], entry[2][1])
    end

    add(UP_MARKER, COLORS["^"], "up")
    add(DOWN_MARKER, COLORS["v"], "down")
    add(UPDOWN_MARKER, COLORS["%"], "up+down")

    local out = { paint_text(NAME .. " legend", "1;37") }
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

    out[#out + 1] = paint_text("safe", FLAG_FG[1][2]) .. " = safe room, "
        .. paint_text("dark", "2;" .. DEFAULT_ROOM_COLOR) .. " = dark"
    out[#out + 1] = paint_text("magenta", TRAIL_COLORS[1])
        .. " = path you walked, faint = far away"

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

    local names = {}
    if type(rune.pane) == "table" then
        for k, v in pairs(rune.pane) do
            names[#names + 1] = tostring(k) .. (type(v) == "function" and "()" or "")
        end
        table.sort(names)
    end
    out[#out + 1] = "rune.pane: " .. table.concat(names, " ")

    local s = get_store()
    local w, h, src = detect_size()

    out[#out + 1] = string.format("pane size %sx%s (%s)", tostring(w), tostring(h), src)

    if s then
        local total = 0
        for _ in pairs(s.rooms) do
            total = total + 1
        end

        local uid = info_uid(current_info)
        local stored = uid and s.get(uid)
        local c = stored and stored.coord
        if type(c) ~= "table" then c = {} end

        out[#out + 1] = string.format("store: %s | rooms %d", store_source, total)
        out[#out + 1] = string.format("here: %s,%s,%s | %s",
            tostring(c.x), tostring(c.y), tostring(c.z), view_stats)
        out[#out + 1] = string.format("terrain=[%s] info=[%s] glyph=%s",
            clean(stored and stored.terrain or ""),
            clean(stored and stored.terraininfo or ""),
            stored and room_style(stored).glyph or "-")
    else
        out[#out + 1] = "store: NOT FOUND - " .. tostring(store_note)
    end

    force_pane(table.concat(out, "\n"))
end

local function list_terrains()
    local s = get_store()
    if not s then
        write_pane("mapper_store not found.")
        return
    end

    local counts = {}
    for _, room in pairs(s.rooms) do
        local t = tostring(room.terrain or "(none)")
        counts[t] = (counts[t] or 0) + 1
    end

    local rows = {}
    for t, n in pairs(counts) do
        rows[#rows + 1] = { t, n }
    end
    table.sort(rows, function(a, b) return a[2] > b[2] end)

    local out = { "terrain (rooms):" }
    for i = 1, math.min(#rows, 25) do
        out[#out + 1] = string.format("%s (%d)", clean(rows[i][1]), rows[i][2])
    end

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

if rune.pane and rune.pane.create then
    rune.pane.create(PANE_ID, {
        title = "Map",
        border = "full",
    })
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
    local w, h, src = detect_size()
    return string.format(
        "v" .. VERSION .. "  enabled=%s mode=%s links=%s zone=%s color=%s size=%sx%s (%s) flags=%s trail=%s dim=%s debug=%s load=%dms",
        onoff(enabled), compact and "compact" or "spaced", link_style,
        opts.zone and "same" or "any", onoff(use_color),
        tostring(w), tostring(h), src, onoff(opts.flags), onoff(opts.trail),
        onoff(opts.dim), onoff(DEBUG), load_ms)
end

local function show_help(note)
    local h = helpstyle()
    local out = {}
    local function emit(text) out[#out + 1] = text end

    if note then emit(paint(note)) end

    emit(h.title(NAME .. " - ASCII map of the rooms around you"))
    emit(h.section("Display:"))
    emit(h.line(NAME, "show this summary"))
    emit(h.line(NAME .. " on|off", "show or hide the map pane"))
    emit(h.line(NAME .. " compact|spaced", "1 char per room, no links / rooms two apart with links"))
    emit(h.line(NAME .. " zone on|off", "stay in this zone (default) / cross zone borders"))
    emit(h.line(NAME .. " links unicode|ascii", "link line characters"))
    emit(h.line(NAME .. " color on|off", "ANSI colours"))
    emit(h.line(NAME .. " refresh", "force a redraw (clears caches)"))
    emit(h.line(NAME .. " reset", "restore defaults"))
    emit(h.line(NAME .. " legend", "what the symbols and colours mean"))
    emit(h.section("Overlays:"))
    emit(h.line(NAME .. " flags on|off", "tint safe and dark rooms"))
    emit(h.line(NAME .. " trail on|off", "colour the rooms you just walked"))
    emit(h.line(NAME .. " dim on|off", "fade far-away rooms"))
    emit(h.section("Size:"))
    emit(h.line(NAME .. " size <W> <H>", "set pane size in characters"))
    emit(h.line(NAME .. " size auto", "back to the default size"))
    emit(h.line(NAME .. " pad <N>", "border allowance (default 2)"))
    emit(h.line(NAME .. " calibrate [W H]", "test frame to find the right size"))
    emit(h.section("Info:"))
    emit(h.line(NAME .. " terrains", "list terrain names in your map"))
    emit(h.line(NAME .. " debug", "pane API, size and room data"))
    emit(h.line(NAME .. " debug on|off", "debug logging (default off)"))
    emit(h.line(NAME .. " help", "this summary"))
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
-- Saved settings (rune.store); debug is deliberately not saved
-----------------------------------------------------------------------

local SETTINGS_KEY = "asciiMapPane.settings"
local saved_sig = nil

local function snapshot()
    return {
        enabled = enabled, compact = compact, color = use_color,
        flags = opts.flags, trail = opts.trail, dim = opts.dim,
        zone = opts.zone, links = link_style, v = 3,
        w = manual_w or false, h = manual_h or false, pad = border_pad,
    }
end

local function snapshot_sig(t)
    return table.concat({
        tostring(t.enabled), tostring(t.compact), tostring(t.color),
        tostring(t.flags), tostring(t.trail), tostring(t.dim),
        tostring(t.zone), tostring(t.links), tostring(t.w), tostring(t.h),
        tostring(t.pad),
    }, "|")
end

-- Read the latest stored table, change only our keys, write it back.
local function save_settings()
    if not (rune.store and type(rune.store.set) == "function") then return end

    local snap = snapshot()
    local sig = snapshot_sig(snap)
    if sig == saved_sig then return end

    local ok, cur = pcall(rune.store.get, SETTINGS_KEY)
    if not ok or type(cur) ~= "table" then cur = {} end

    for k, v in pairs(snap) do cur[k] = v end

    if pcall(rune.store.set, SETTINGS_KEY, cur) then
        saved_sig = sig
    end
end

local function load_settings()
    if not (rune.store and type(rune.store.get) == "function") then return end
    local ok, saved = pcall(rune.store.get, SETTINGS_KEY)
    if not ok or type(saved) ~= "table" then return end

    if type(saved.enabled) == "boolean" then enabled = saved.enabled end
    -- Saved before the mapper_map layout (v3): the old default was the
    -- dense view without links, so only trust `compact` from v3 settings.
    if saved.v == 3 and type(saved.compact) == "boolean" then
        compact = saved.compact
    end
    if type(saved.color) == "boolean" then use_color = saved.color end

    if saved.links == "ascii" or saved.links == "unicode" then
        link_style = saved.links
    end

    for _, name in ipairs({ "flags", "trail", "dim", "zone" }) do
        if type(saved[name]) == "boolean" then opts[name] = saved[name] end
    end

    local w, h = tonumber(saved.w), tonumber(saved.h)
    if w and h then
        manual_w = clamp(math.floor(w), MIN_W, MAX_W)
        manual_h = clamp(math.floor(h), MIN_H, MAX_H)
    end

    local pad = tonumber(saved.pad)
    if pad then border_pad = clamp(math.floor(pad), 0, MAX_PAD) end

    saved_sig = snapshot_sig(snapshot())
end

load_settings()

if not enabled then hide_pane() end

-----------------------------------------------------------------------
-- Command
-----------------------------------------------------------------------

local function redraw_now()
    last_pane_text = nil
    draw()
end

local function run_command_impl(arg_text)
    epoch = epoch + 1

    local words = {}
    for word in tostring(arg_text or ""):gmatch("%S+") do words[#words + 1] = word:lower() end
    local action = words[1] or ""

    if action == "" or action == "help" or action == "?" or action == "h" or action == "-h" or action == "--help" then
        show_help()
    elseif action == "off" then
        set_enabled(false)
    elseif action == "on" then
        set_enabled(true)
    elseif action == "debug" then
        if words[2] == "on" or words[2] == "off" then
            DEBUG = (words[2] == "on")
            say("debug logging " .. onoff(DEBUG))
        else
            debug_dump()
        end
    elseif action == "calibrate" then
        calibrate(words[2], words[3])
    elseif action == "color" or action == "colour" then
        use_color = (words[2] ~= "off")
        redraw_now()
    elseif action == "legend" then
        legend()
    elseif action == "terrains" then
        list_terrains()
    elseif action == "compact" or action == "spaced" then
        compact = (action == "compact")
        redraw_now()
    elseif action == "refresh" then
        reset_caches()
        redraw_now()
    elseif action == "reset" then
        enabled, compact, use_color = true, false, true
        opts.flags, opts.trail, opts.dim, opts.zone = true, true, true, true
        link_style = "unicode"
        manual_w, manual_h, border_pad = nil, nil, 2
        reset_caches()
        show_pane()
        redraw_now()
        say("settings reset to defaults")
    elseif action == "size" then
        local w, h = tonumber(words[2]), tonumber(words[3])
        if w and h then
            local cw = clamp(math.floor(w), MIN_W, MAX_W)
            local ch = clamp(math.floor(h), MIN_H, MAX_H)
            manual_w, manual_h = cw, ch
            if cw ~= w or ch ~= h then
                say(string.format("size limited to %dx%d (allowed %d-%d x %d-%d)", cw, ch, MIN_W, MAX_W, MIN_H, MAX_H))
            end
        else
            manual_w, manual_h = nil, nil
        end
        redraw_now()
    elseif action == "pad" then
        local n = tonumber(words[2])
        if n then border_pad = clamp(math.floor(n), 0, MAX_PAD) end
        redraw_now()
    elseif action == "links" then
        if words[2] == "ascii" or words[2] == "unicode" then
            link_style = words[2]
            redraw_now()
        else
            show_help("links: unicode or ascii")
        end
    elseif opts[action] ~= nil then
        opts[action] = (words[2] ~= "off")
        redraw_now()
    else
        show_help("unknown option '" .. action .. "'")
    end

    save_settings()
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
    end, { name = NAME })
end

if rune.hooks and rune.hooks.on then
    rune.hooks.on("mapper_room_changed", function() request_later_draw() end)
end

write_pane(NAME .. " loaded; waiting for Room.Info...")

load_ms = ((os.clock and os.clock() or 0) - T0) * 1000

-- Single-row loader line.
say("v" .. VERSION .. " loaded (" .. NAME .. " or " .. SHORT .. " for help)")