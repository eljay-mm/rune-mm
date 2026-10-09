-- Filename: eljayPlugins/asciiMapPane.lua
-- Purpose: ASCII map pane for Rune + horstgs Materia Magica.
-- Version: 2.0
-- Date: 2026-Oct-09
--
-- Commands:
--     /asciiMapPane                 redraw
--     /asciiMapPane on | off
--     /asciiMapPane compact | spaced  1 char per room (default) / with link lines
--     /asciiMapPane terrains        list terrain names in your map (for glyphs)
--     /asciiMapPane color on|off    ANSI colours (default on)
--     /asciiMapPane flags|trail|dim|strict on|off
--                                flags: tint safe/dark rooms; trail: colour
--                                the rooms you just walked; dim: fade far
--                                rooms; strict: drop rooms whose coordinates
--                                show they are not really adjacent
--     /asciiMapPane legend          show what the symbols and colours mean
--     /asciiMapPane refresh         force a redraw
--     /asciiMapPane size W H        set pane size in characters (W cols, H lines)
--     /asciiMapPane size auto       use the pane's reported size again
--     /asciiMapPane pad N           border allowance subtracted from a
--                                reported pane size (default 2)
--     /asciiMapPane calibrate       print a ruler to measure the pane, then
--                                use /asciiMapPane size W H with what you see
--     /asciiMapPane debug           show pane API / size / room data
--
-- Uses mapper_store: get(uid) -> { name, area, coord={x,y,z}, exits={dir=uid} }
-- The map is laid out from exits around the current room, so a redraw
-- touches only a few hundred rooms, never the whole map.
--

local PANE_ID = "asciiMapPane"

-- Rune's pane API has no size query, so this is the "auto" size.  Edit
-- these two numbers (or use /asciiMapPane size W H) to match your pane.
local DEFAULT_W = 42
local DEFAULT_H = 10

local EMPTY_MARKER   = " "   -- blank: only real rooms are drawn
local ROOM_MARKER    = "o"
local UP_MARKER      = "^"   -- room with an up exit
local DOWN_MARKER    = "v"   -- room with a down exit
local UPDOWN_MARKER  = "%"   -- room with both
local CURRENT_MARKER = "@"

local enabled = true
local redraw_pending = false
local current_info = nil
local last_pane_text = nil

local manual_w, manual_h = nil, nil
local use_color = true
local compact = true   -- 1 character per room (4x denser); false = spaced with links
local border_pad = 2

-----------------------------------------------------------------------
-- Store access (lazy)
-----------------------------------------------------------------------

local store = nil
local store_source = "none"

-- rawget: never trigger metamethods on unknown tables while scanning.
local function looks_like_store(t)
    return type(t) == "table"
        and type(rawget(t, "rooms")) == "table"
        and type(rawget(t, "get")) == "function"
end

local function has_rooms(t)
    return looks_like_store(t) and next(rawget(t, "rooms")) ~= nil
end

-- Finds the mapper's LIVE store.  If another copy of the module was
-- loaded by require() it would be empty, so every plausible holder is
-- checked and a populated one is preferred.
local function find_store()
    local found = {}

    local function consider(label, value)
        if looks_like_store(value) then
            found[#found + 1] = { label = label, store = value }
        end
    end

    consider("_G.mapper_store", _G.mapper_store)

    if type(_G.mapper) == "table" then
        consider("_G.mapper.store", _G.mapper.store)
        consider("_G.mapper", _G.mapper)
    end

    pcall(function()
        for _, name in ipairs({ "mapper_store", "eljayPlugins.mapper_store" }) do
            consider("package.loaded." .. name, package.loaded[name])
        end

        for name, value in pairs(package.loaded) do
            consider("package.loaded." .. tostring(name), value)
        end

        for name, value in pairs(_G) do
            consider("_G." .. tostring(name), value)
        end
    end)

    for _, name in ipairs({ "mapper_store", "eljayPlugins.mapper_store" }) do
        local ok, mod = pcall(require, name)
        if ok then
            consider("require(" .. name .. ")", mod)
        end
    end

    for _, f in ipairs(found) do
        if has_rooms(f.store) then
            return f.store, f.label
        end
    end

    if found[1] then
        return found[1].store, found[1].label .. " (empty)"
    end

    return nil, "none"
end

-- Fallback: read mapper/map.db ourselves (same line format the mapper
-- writes: fields split by US (0x1f), exits "dir=uid" split by RS (0x1e)).
-- Parsed incrementally so no single call runs long.
local US, RS = "\31", "\30"
local own = { rooms = {} }
function own.get(uid)
    if uid == nil then
        return nil
    end

    return own.rooms[tostring(uid)]
end

local own_state = { done = false, text = nil, pos = 1, err = nil }
local store_note = nil
local live_retry = 0

local function parse_room(line)
    local f = {}
    local start = 1

    for i = 1, 8 do
        local at = line:find(US, start, true)

        if not at then
            f[i] = line:sub(start)
            break
        end

        f[i] = line:sub(start, at - 1)
        start = at + 1
    end

    local uid = f[1]
    if not uid or uid == "" then
        return nil
    end

    local room = { uid = uid, name = f[2], area = f[3],
        flags = f[4], terrain = f[5], terraininfo = f[6] }

    if f[7] and f[7] ~= "" then
        local x, y, z = f[7]:match("([^,]*),([^,]*),([^,]*)")
        x, y = tonumber(x), tonumber(y)

        if x and y then
            room.coord = { x = x, y = y, z = tonumber(z) or 0 }
        end
    end

    if f[8] and f[8] ~= "" then
        room.exits = {}

        for pair in f[8]:gmatch("[^" .. RS .. "]+") do
            local dir, dest = pair:match("^(%a+)=(.*)$")

            if dir and dest and dest ~= "" then
                room.exits[dir] = dest
            end
        end
    end

    return room
end

local function own_load_step()
    if own_state.done then
        return true
    end

    if not own_state.text then
        local path = (rune.config_dir or ".") .. "/mapper/map.db"
        local f = io.open(path, "r")

        if not f then
            own_state.done = true
            own_state.err = "cannot open " .. path
            return true
        end

        own_state.text = f:read("*a")
        f:close()
        own_state.pos = 1
    end

    local clock = os.clock
    local t0 = clock and clock() or 0
    local text, pos = own_state.text, own_state.pos

    while true do
        local nl = text:find("\n", pos, true)
        local line = nl and text:sub(pos, nl - 1) or text:sub(pos)
        pos = (nl or #text) + 1

        line = line:gsub("\r$", "")
        local room = parse_room(line)

        if room then
            own.rooms[room.uid] = room
        end

        if not nl then
            own_state.done = true
            own_state.text = nil
            break
        end

        if clock and clock() - t0 > 0.15 then
            break
        end
    end

    own_state.pos = pos
    return own_state.done
end

local function own_count()
    local n = 0
    for _ in pairs(own.rooms) do
        n = n + 1
    end
    return n
end

local function get_store()
    -- A populated live store always wins.
    if store and store ~= own and has_rooms(store) then
        return store
    end

    -- While using our own copy, only re-scan for the live store now and
    -- then.
    live_retry = live_retry + 1

    if store ~= own or live_retry % 20 == 0 then
        local found, label = find_store()

        if found then
            if not has_rooms(found) and type(found.load) == "function"
                and found ~= own then
                -- Private never-loaded copy: leave it alone (we load our
                -- own below) unless it has rooms.
                found = nil
            end
        end

        if found and has_rooms(found) then
            store, store_source = found, label
                return store
        end
    end

    -- Fall back to reading map.db directly.
    if not own_load_step() then
        store_note = string.format("Loading map file... %d rooms",
            own_count())
        return nil
    end

    -- Count once, not on every redraw.
    if own_state.total == nil then
        own_state.total = own_count()
    end

    if own_state.total == 0 then
        store_note = own_state.err or "map.db is empty."
        return nil
    end

    if store ~= own then
        store, store_source = own, "own map.db reader"
    end

    return store
end

-----------------------------------------------------------------------
-- Helpers
-----------------------------------------------------------------------

-- Numeric grid key: no string building on the hot path.  Offsets are
-- always small (bounded by the pane size).
local function key_of(x, y)
    return (x + 1024) * 2048 + (y + 1024)
end

-- Reads {x,y,z} (z optional) or a "x,y,z" string.
local function read_coord(c)
    if type(c) == "string" then
        local a, b, d = c:match("(%-?%d+)[, ]+(%-?%d+)[, ]*(%-?%d*)")
        if a and b then
            return tonumber(a), tonumber(b), tonumber(d) or 0
        end
        return nil
    end

    if type(c) ~= "table" then
        return nil
    end

    local x = tonumber(c.x or c[1])
    local y = tonumber(c.y or c[2])
    local z = tonumber(c.z or c[3] or c.level or 0)

    if x and y then
        return x, y, z or 0
    end

    return nil
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

-----------------------------------------------------------------------
-- Index
-----------------------------------------------------------------------

local function has_exit(room, dir)
    return room ~= nil
        and type(room.exits) == "table"
        and room.exits[dir] ~= nil
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

    -- replace() swaps the whole content in one call.
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

    -- Keep the header (first line) in view.
    if type(rune.pane.scroll_to_top) == "function" then
        pcall(rune.pane.scroll_to_top, PANE_ID)
    end
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

-- Returns w, h, source.  Tries the pane API (names are guesses, all
-- wrapped in pcall), then manual size, then defaults.
local function detect_size()
    if manual_w and manual_h then
        return manual_w, manual_h, "manual"
    end

    local p = rune.pane

    if type(p) == "table" then
        for _, name in ipairs({
            "size", "get_size", "dimensions", "dims", "info", "get",
            "metrics", "rect", "bounds",
        }) do
            if type(p[name]) == "function" then
                local ok, a, b = pcall(p[name], PANE_ID)

                if ok then
                    local w, h

                    if type(a) == "table" then
                        w = a.width or a.w or a.cols or a.columns
                        h = a.height or a.h or a.rows or a.lines
                    else
                        w, h = a, b
                    end

                    w, h = tonumber(w), tonumber(h)

                    if w and h and w > 0 and h > 0 then
                        return w - border_pad, h - border_pad,
                            "pane." .. name
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

-----------------------------------------------------------------------
-- Drawing
-----------------------------------------------------------------------

local function header_line(info, stored, width)
    local name = info.name or (stored and stored.name) or "Unknown room"
    local area = info.area or info.zone or (stored and stored.area)
        or (type(info.coord) == "table" and info.coord.name)
        or "Unknown zone"

    local text = string.format("%s %s | %s",
        info_uid(info) or (stored and stored.uid) or "?",
        name, area)

    if #text > width then
        text = text:sub(1, width)
    end

    return text
end

local EXIT_ORDER = {
    "n", "ne", "e", "se", "s", "sw", "w", "nw", "u", "d", "in", "out",
}

local function exits_line(stored, info, width)
    local present = {}

    local function add_from(exits)
        if type(exits) ~= "table" then
            return
        end

        for dir in pairs(exits) do
            present[tostring(dir):lower()] = true
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
-- Styling tables (edit freely)
-----------------------------------------------------------------------

-- Each entry: { glyph, { words }, colour }.  Words are matched
-- (case-insensitive substring) against the room's terrain / terraininfo
-- / flags; first match wins.  Run `asciiMapPane terrains` to see the names
-- your map uses.  Colours are ANSI SGR codes.
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

-- Fallback for rooms whose terrain is empty: whole words in the NAME.
local NAME_GLYPHS = {
    { "#", { "road", "street", "trail", "path", "lane", "avenue", "alley",
             "highway", "boulevard", "crossroads", "bridge" }, "33" },
    { "$", { "shop", "store", "market", "bazaar" }, "32" },
}

-- Flag styling (substring match on the room's flags).
local FLAG_FG  = { { "safe", "92" } }   -- first match recolours the room
local FLAG_MOD = { { "dark", "2" } }    -- modifier (2 = faint)

local UNEXPLORED_MARKER = "?"

local TRAIL_LENGTH = 6
-- Newest -> oldest visited room.
local TRAIL_COLORS = { "1;95", "95", "35", "35", "2;35", "2;35" }

-- Rooms further out than this fraction of the view are drawn faint.
local DIM_START = 0.7

-- Fixed colours (also the fallback per symbol).
local ESC = string.char(27)

local COLORS = {
    ["@"] = "1;97;45",   -- you: bold white on magenta
    ["?"] = "1;91",      -- unexplored exit
    ["#"] = "33", ["$"] = "32", ["o"] = "37", ["~"] = "34",
    ["^"] = "1;92", ["v"] = "1;92", ["%"] = "1;92",   -- stairs
    ["-"] = "90", ["|"] = "90", ["/"] = "90", ["\\"] = "90",
    ["X"] = "90",
}

-- Toggles: `asciiMapPane <name> on|off`.
local opts = { flags = true, trail = true, dim = true, strict = true }

local history = {}   -- uids, newest (current room) first

-----------------------------------------------------------------------
-- Per-room style (cached: terrain/flags don't change)
-----------------------------------------------------------------------

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

    -- Stairs/ladders matter most.
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

        -- Plain/unknown rooms (empty terrain, or just "indoors" etc.) can
        -- still be recognised by whole words in their name.
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

-- Final colour for one room cell.
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

local DIR_OFFSET = {
    n = { 0, 1 }, s = { 0, -1 }, e = { 1, 0 }, w = { -1, 0 },
    ne = { 1, 1 }, nw = { -1, 1 }, se = { 1, -1 }, sw = { -1, -1 },
}

-- Fixed order => deterministic layouts.
local LAYOUT_DIRS = { "n", "e", "s", "w", "ne", "se", "sw", "nw" }

local LONG_DIRS = {
    north = "n", south = "s", east = "e", west = "w",
    northeast = "ne", northwest = "nw", southeast = "se",
    southwest = "sw", up = "u", down = "d",
}

local view_stats = "layout: none"
local needs_followup = false   -- an exit led to a room not stored yet

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

-- A room-like table built from Room.Info, for rooms not stored yet.
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

-- Lays rooms out by dead reckoning from the exits: each compass exit is
-- one step in that direction (east = +x, north = +y, relative to the
-- start room).  No coordinates are needed, so it works in player homes,
-- dungeons and across zone borders.
--
-- Strict mode additionally drops a room whose stored coordinates show
-- it is NOT one step away in that direction (long exits, portals, stale
-- links), unless both rooms share the same coordinate (homes/instances).
--
-- Exits to rooms the mapper doesn't have yet are recorded as unexplored.
local function layout_from_exits(s, start, start_uid, hx, hy)
    local k0 = key_of(0, 0)
    local grid = { [k0] = start }
    local uids = { [k0] = start_uid }
    local unexplored = {}
    local posx, posy = { [start] = 0 }, { [start] = 0 }
    local queue, head = { start }, 1
    local missing, skipped = false, 0
    local strict = opts.strict

    while queue[head] and head <= 4000 do
        local room = queue[head]
        head = head + 1

        local exits = room.exits

        if type(exits) == "table" then
            local px, py = posx[room], posy[room]
            local rx, ry

            if strict then
                rx, ry = read_coord(room.coord)
            end

            for i = 1, #LAYOUT_DIRS do
                local dir = LAYOUT_DIRS[i]
                local e = exits[dir]

                if e then
                    local off = DIR_OFFSET[dir]
                    local nx, ny = px + off[1], py + off[2]
                    local k = key_of(nx, ny)

                    if grid[k] == nil and not unexplored[k]
                        and nx <= hx and nx >= -hx
                        and ny <= hy and ny >= -hy then
                        local uid = exit_uid(e)
                        local dest = uid and s.get(uid)

                        if not dest then
                            unexplored[k] = true
                            missing = true
                        elseif posx[dest] == nil then
                            local ok = true

                            if rx then
                                local dx, dy = read_coord(dest.coord)

                                if dx then
                                    local ddx, ddy = dx - rx, dy - ry

                                    if not (ddx == off[1] and ddy == off[2])
                                        and not (ddx == 0 and ddy == 0) then
                                        ok = false
                                    end
                                end
                            end

                            if ok then
                                grid[k] = dest
                                uids[k] = uid
                                posx[dest], posy[dest] = nx, ny
                                queue[#queue + 1] = dest
                            else
                                skipped = skipped + 1
                            end
                        end
                    end
                end
            end
        end
    end

    return grid, uids, unexplored, #queue, missing, skipped
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

-- Joins one map row.  codes[i] (if set) overrides the symbol's default
-- colour; runs of the same colour share one escape sequence.
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

local draw   -- forward declaration (assigned below)

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

        if not own_state.done and rune.timer and rune.timer.after then
            redraw_pending = true
            rune.timer.after(0.05, draw)
        end

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

    if start.coord == nil and stored then
        start.coord = stored.coord
    end

    local header = header_line(current_info, stored, width)
    local rows = math.max(height - 2, 1)    -- header + exits lines
    local sx0 = math.floor((width + 1) / 2) -- centre column
    local sy0 = math.floor((rows + 1) / 2)  -- centre row

    local lines = {
        paint_text(header, "1;37"),
        paint_text(exits_line(start, current_info, width), "36"),
    }

    -- Spaced mode shows half as many rooms per axis.
    local span = compact and 2 or 4
    local half_w = math.max(width / span, 1)
    local half_h = math.max(rows / span, 1)

    local grid, uids, unexplored, placed, missing, skipped =
        layout_from_exits(s, start, uid, math.ceil(half_w) + 1,
            math.ceil(half_h) + 1)

    needs_followup = missing

    local n_unexplored = 0
    for _ in pairs(unexplored) do
        n_unexplored = n_unexplored + 1
    end

    view_stats = string.format("layout: %d rooms, %d skipped, %d unexplored",
        placed, skipped, n_unexplored)

    -- Recently visited rooms (index 1 is where we are now).
    local trail_rank = {}

    if opts.trail then
        for i = 2, #history do
            trail_rank[history[i]] = i - 1
        end
    end

    local abs = math.abs

    -- Symbol and colour for the room (or unexplored exit) at an offset.
    local function room_cell(ox, oy)
        local k = key_of(ox, oy)
        local room = grid[k]

        if room then
            local st = room_style(room)
            local dist = math.max(abs(ox) / half_w, abs(oy) / half_h)

            return st.glyph, cell_color(st, trail_rank[uids[k]], dist)
        end

        if unexplored[k] then
            return UNEXPLORED_MARKER, nil
        end

        return nil
    end

    local function room_at_offset(ox, oy)
        return grid[key_of(ox, oy)]
    end

    for sy = 1, rows do
        local dy = sy - sy0
        local chars, codes = {}, {}

        for sx = 1, width do
            local dx = sx - sx0
            local ch, code = " ", nil

            if compact then
                -- one character per room
                if dx == 0 and dy == 0 then
                    ch = CURRENT_MARKER
                else
                    local g, c = room_cell(dx, -dy)

                    if g then
                        ch, code = g, c
                    end
                end
            else
                -- rooms on even offsets, link characters between them
                local row_is_room = (dy % 2 == 0)
                local col_is_room = (dx % 2 == 0)

                -- room offsets: east = +x, north = +y
                local top = row_is_room and (-dy / 2) or (-(dy - 1) / 2)
                local left = col_is_room and (dx / 2) or ((dx - 1) / 2)

                if row_is_room and col_is_room then
                    if dx == 0 and dy == 0 then
                        ch = CURRENT_MARKER
                    else
                        local g, c = room_cell(left, top)

                        if g then
                            ch, code = g, c
                        end
                    end

                elseif row_is_room then
                    local l = room_at_offset(left, top)
                    local r = room_at_offset(left + 1, top)

                    if has_exit(l, "e") or has_exit(r, "w") then
                        ch = "-"
                    end

                elseif col_is_room then
                    local up = room_at_offset(left, top)
                    local dn = room_at_offset(left, top - 1)

                    if has_exit(up, "s") or has_exit(dn, "n") then
                        ch = "|"
                    end

                else
                    local ul = room_at_offset(left, top)
                    local ur = room_at_offset(left + 1, top)
                    local ll = room_at_offset(left, top - 1)
                    local lr = room_at_offset(left + 1, top - 1)

                    local back = has_exit(ul, "se") or has_exit(lr, "nw")
                    local fwd = has_exit(ll, "ne") or has_exit(ur, "sw")

                    if back and fwd then
                        ch = "X"
                    elseif back then
                        ch = "\\"
                    elseif fwd then
                        ch = "/"
                    end
                end
            end

            chars[#chars + 1] = ch
            codes[#codes + 1] = code or false
        end

        lines[#lines + 1] = paint_row(chars, codes)
    end

    write_pane(table.concat(lines, "\n"))
end

-- Any runtime error is shown in the pane instead of silently leaving
-- it blank.
draw = function()
    local ok, err = pcall(draw_impl)

    if not ok then
        redraw_pending = false
        last_pane_text = nil
        write_pane("asciiMapPane error:\n" .. tostring(err))
    end
end

-----------------------------------------------------------------------
-- Legend
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

    local out = { paint_text("asciiMapPane legend", "1;37") }
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

    last_pane_text = nil
    write_pane(table.concat(out, "\n"))
end

local function later(delay)
    if redraw_pending then
        return
    end

    if rune.timer and rune.timer.after then
        redraw_pending = true
        rune.timer.after(delay, draw)
    end
end

-- Room.Info: draw immediately.  Only if a neighbouring room was not in
-- the store yet (the mapper is still recording it) redraw once shortly
-- after, instead of always drawing twice.
local function request_draw()
    if not enabled then
        return
    end

    draw()

    if needs_followup then
        later(0.25)
    end
end

-- The mapper changed something: one coalesced redraw, no immediate one.
local function request_later_draw()
    if enabled then
        later(0.1)
    end
end

-----------------------------------------------------------------------
-- Debug
-----------------------------------------------------------------------

local function debug_dump()
    -- The pane may show only its LAST few lines, so the details come
    -- first and the important summary goes at the very bottom.
    local detail, summary = {}, {}

    if type(current_info) == "table" then
        local parts = {}
        for k, v in pairs(current_info) do
            if type(v) ~= "table" and type(v) ~= "function" then
                parts[#parts + 1] = tostring(k) .. "=" .. tostring(v)
            end
        end
        table.sort(parts)
        detail[#detail + 1] = "Room.Info: " .. table.concat(parts, " ")
    else
        detail[#detail + 1] = "Room.Info: none yet"
    end

    local names = {}
    if type(rune.pane) == "table" then
        for k, v in pairs(rune.pane) do
            names[#names + 1] = tostring(k)
                .. (type(v) == "function" and "()" or "")
        end
        table.sort(names)
    end
    detail[#detail + 1] = "rune.pane: " .. table.concat(names, " ")

    local top = {}
    if type(rune) == "table" then
        for k, v in pairs(rune) do
            top[#top + 1] = tostring(k) .. (type(v) == "table" and "{}" or "")
        end
        table.sort(top)
    end
    detail[#detail + 1] = "rune: " .. table.concat(top, " ")

    local s = get_store()
    local w, h, src = detect_size()

    summary[#summary + 1] = string.format("pane size %sx%s (%s)",
        tostring(w), tostring(h), src)

    if s then
        local total = 0
        for _ in pairs(s.rooms) do
            total = total + 1
        end

        local stored = info_uid(current_info) and s.get(info_uid(current_info))
        local sx, sy, sz = read_coord(stored and stored.coord)

        summary[#summary + 1] = string.format(
            "store: %s | rooms %d", store_source, total)
        summary[#summary + 1] = string.format("here: %s,%s,%s | %s",
            tostring(sx), tostring(sy), tostring(sz), view_stats)
        summary[#summary + 1] = string.format("terrain=[%s] info=[%s] glyph=%s",
            tostring(stored and stored.terrain or ""),
            tostring(stored and stored.terraininfo or ""),
            stored and room_style(stored).glyph or "-")
    else
        summary[#summary + 1] = "store: NOT FOUND - "
            .. tostring(store_note)
    end

    local out = {}
    for _, line in ipairs(detail) do
        out[#out + 1] = line
    end
    for _, line in ipairs(summary) do
        out[#out + 1] = line
    end

    last_pane_text = nil
    write_pane(table.concat(out, "\n"))
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
        out[#out + 1] = string.format("%s (%d)", rows[i][1], rows[i][2])
    end

    last_pane_text = nil
    write_pane(table.concat(out, "\n"))
end

-----------------------------------------------------------------------
-- Calibration ruler
-----------------------------------------------------------------------

local function calibrate()
    -- Column ruler: the label k*10 ends exactly at column k*10.
    local ruler = ""
    for k = 1, 12 do
        ruler = ruler .. string.format("%10d", k * 10)
    end

    -- Numbered so that the BOTTOM line is 01 and numbers rise upward:
    -- the highest number you can see is the pane's height, whether the
    -- pane shows its top or its bottom.
    local lines = {}
    for n = 60, 1, -1 do
        lines[#lines + 1] = string.format("%02d", n) .. ruler:sub(3)
    end

    last_pane_text = nil
    write_pane(table.concat(lines, "\n"))
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

local function run_command_impl(arg_text)
    local words = {}
    for word in tostring(arg_text or ""):gmatch("%S+") do
        words[#words + 1] = word:lower()
    end

    local action = words[1] or ""

    if action == "off" then
        set_enabled(false)
    elseif action == "on" then
        set_enabled(true)
    elseif action == "debug" then
        debug_dump()
    elseif action == "calibrate" then
        calibrate()
    elseif action == "color" or action == "colour" then
        use_color = (words[2] ~= "off")
        last_pane_text = nil
        draw()
    elseif action == "legend" then
        legend()
    elseif action == "terrains" then
        list_terrains()
    elseif action == "compact" or action == "spaced" then
        compact = (action == "compact")
        last_pane_text = nil
        draw()
    elseif action == "refresh" then
        last_pane_text = nil
        draw()
    elseif action == "size" then
        local w, h = tonumber(words[2]), tonumber(words[3])
        if w and h then
            manual_w, manual_h = w, h
        else
            manual_w, manual_h = nil, nil
        end
        last_pane_text = nil
        draw()
    elseif action == "pad" then
        border_pad = tonumber(words[2]) or border_pad
        last_pane_text = nil
        draw()
    elseif opts[action] ~= nil then
        opts[action] = (words[2] ~= "off")
        last_pane_text = nil
        draw()
    elseif enabled then
        draw()
    end
end

-- Command registration.  Rune treats "/word" as a client command, which
-- aliases do not catch, so register both ways:
--   * an alias, so plain `asciiMapPane ...` (no slash) works
--   * a client command, so `/asciiMapPane ...` works (several API names
--     are tried; the first that succeeds wins)
local function args_to_text(args)
    if type(args) == "table" then
        return table.concat(args, " ")
    end

    return tostring(args or "")
end

local function run_command(arg_text)
    local ok, err = pcall(run_command_impl, arg_text)

    if not ok then
        last_pane_text = nil
        write_pane("asciiMapPane error:\n" .. tostring(err))
    end
end

if rune.alias and rune.alias.regex then
    -- "[-]" is a literal hyphen in both Lua patterns and regex.
    pcall(rune.alias.regex, "^/?ascii[-]map(.*)$", function(match)
        run_command(match[1])
    end, { name = "y-asciiMapPane" })
end

if type(rune.command) == "table" then
    for _, fname in ipairs({
        "add", "register", "create", "define", "set", "on",
    }) do
        local f = rune.command[fname]

        if type(f) == "function" then
            local ok = pcall(f, "asciiMapPane", function(args)
                run_command(args_to_text(args))
            end)

            if ok then
                break
            end
        end
    end
end

if rune.gmcp and rune.gmcp.on then
    rune.gmcp.on("Room.Info", function(data)
        if type(data) ~= "table" then
            return
        end

        current_info = data

        local uid = info_uid(data)

        if uid and uid ~= history[1] then
            table.insert(history, 1, uid)
            history[TRAIL_LENGTH + 2] = nil
        end

        request_draw()
    end)
end

if rune.hooks and rune.hooks.on then
    rune.hooks.on("mapper_room_changed", function()
        request_later_draw()
    end)
end

-- Cheap marker so a blank pane can be told apart from "not loaded".
write_pane("asciiMapPane loaded; waiting for Room.Info...")