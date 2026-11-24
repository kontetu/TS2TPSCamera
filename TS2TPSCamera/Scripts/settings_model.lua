-- Pure logic behind the F1 settings screen (no game access, unit tested).
local config = require("config")
local store = require("store")
local M = {}

-- Rows in display order: { header = group_id }, { entry = config entry } or { action = name }.
-- Hidden entries are not listed. Order: camera (TPS on/off, camera position screen, auto-turn on/off, speed), pad, mouse.
function M.rows()
    local rows = {}
    for _, group in ipairs(config.group_order) do
        local block = {}
        for _, entry in ipairs(config.entries) do
            if entry.group == group and not entry.hidden then
                block[#block + 1] = { entry = entry }
                -- the camera position screen row sits right under the TPS on/off switch
                if entry.key == "enabled" then block[#block + 1] = { action = "camera_screen" } end
            end
        end
        if #block > 0 then -- a group whose settings are all hidden shows no header
            rows[#rows + 1] = { header = group }
            for _, row in ipairs(block) do rows[#rows + 1] = row end
        end
    end
    return rows
end

M.ACTION_LABELS = {
    camera_screen = { ja = "カメラ位置変更画面を開く", en = "Open camera position screen" },
}
function M.action_label(name, japanese) local l = M.ACTION_LABELS[name]; return japanese and l.ja or l.en end

-- Control help drawn as "icon: description" (main screen footer and camera position screen).
-- Icons: { "face", "A" } Xbox face button, { "bumper", "LB" }, { "trigger", "LT" }, { "stick", "RS" },
-- { "dpad", "ud" | "lr" | "udlr" } (highlighted arms), { "key", "Enter" } keycap,
-- { "mouse", "move" | "left" | "right" | "wheel" | "wheel_up" | "wheel_down" }, { "hold", "長押し" } (accent text),
-- { "sep", "/" } (plain text between icons).
function M.help_rows(screen, japanese)
    local ja = japanese
    if screen == "camera" then
        local hold = ja and "長押し" or "hold"
        return {
            { label = ja and "パッド" or "Gamepad", items = {
                { icons = { { "dpad", "udlr" } }, text = ja and "カメラを上下左右へ" or "Move camera" },
                { icons = { { "stick", "RS" } }, text = ja and "視点操作" or "Look" },
                { icons = { { "bumper", "LB" } }, text = ja and "手前へ" or "Nearer" },
                { icons = { { "bumper", "RB" } }, text = ja and "奥へ" or "Farther" },
                { icons = { { "trigger", "LT" } }, text = ja and "視野角＋" or "FOV +" },
                { icons = { { "trigger", "RT" } }, text = ja and "視野角－" or "FOV -" },
                { icons = { { "face", "X" }, { "hold", hold } }, text = ja and "すべてリセット" or "Reset all" },
                { icons = { { "face", "B" } }, text = ja and "戻る" or "Back" } } },
            { label = ja and "キーボード" or "Keyboard", items = {
                { icons = { { "key", "↑" }, { "key", "↓" }, { "key", "←" }, { "key", "→" } }, text = ja and "カメラを上下左右へ" or "Move camera" },
                { icons = { { "key", "PgDn" } }, text = ja and "手前へ" or "Nearer" },
                { icons = { { "key", "PgUp" } }, text = ja and "奥へ" or "Farther" },
                { icons = { { "key", "Q" } }, text = ja and "視野角＋" or "FOV +" },
                { icons = { { "key", "E" } }, text = ja and "視野角－" or "FOV -" },
                { icons = { { "key", "R" }, { "hold", hold } }, text = ja and "すべてリセット" or "Reset all" },
                { icons = { { "key", "ESC" } }, text = ja and "戻る" or "Back" } } },
            { label = ja and "マウス" or "Mouse", items = {
                { icons = { { "mouse", "move" } }, text = ja and "視点操作" or "Look" },
                { icons = { { "mouse", "wheel_down" } }, text = ja and "手前へ" or "Nearer" },
                { icons = { { "mouse", "wheel_up" } }, text = ja and "奥へ" or "Farther" },
                { icons = { { "mouse", "right" } }, text = ja and "戻る" or "Back" } } },
        }
    end
    return {
        { label = ja and "パッド" or "Gamepad", items = {
            { icons = { { "dpad", "ud" } }, text = ja and "項目選択" or "Select" },
            { icons = { { "dpad", "lr" } }, text = ja and "値の変更" or "Adjust" },
            { icons = { { "bumper", "LB" }, { "bumper", "RB" } }, text = ja and "10倍で変える" or "Change x10" },
            { icons = { { "face", "X" } }, text = ja and "各項目をリセット" or "Reset each item" },
            { icons = { { "face", "A" } }, text = ja and "決定" or "Confirm" },
            { icons = { { "face", "B" } }, text = ja and "閉じる" or "Close" } } },
        { label = ja and "キーボード" or "Keyboard", items = {
            { icons = { { "key", "↑" }, { "key", "↓" } }, text = ja and "項目選択" or "Select" },
            { icons = { { "key", "←" }, { "key", "→" } }, text = ja and "値の変更" or "Adjust" },
            { icons = { { "key", "PgUp" }, { "key", "PgDn" } }, text = ja and "10倍で変える" or "Change x10" },
            { icons = { { "key", "R" } }, text = ja and "各項目をリセット" or "Reset each item" },
            { icons = { { "key", "Enter" } }, text = ja and "決定" or "Confirm" },
            { icons = { { "key", "ESC" }, { "sep", "/" }, { "key", "F1" } }, text = ja and "閉じる" or "Close" } } },
        { label = ja and "マウス" or "Mouse", items = {
            { icons = { { "mouse", "move" } }, text = ja and "項目選択" or "Select" },
            { icons = { { "mouse", "left" } }, text = ja and "値の左側/右側で減らす/増やす（オン/オフは切替）" or "Left / right of a value: lower / raise (ON/OFF: toggle)" },
            { icons = { { "mouse", "wheel" } }, text = ja and "値の変更" or "Adjust" },
            { icons = { { "mouse", "right" } }, text = ja and "閉じる" or "Close" } } },
    }
end

-- UMG font sizes are points: the game draws text 96/72 as wide as text_width(label, size) estimates in pixels.
M.PT = 96 / 72
local function drawn_width(label, size) return M.text_width(label, size) * M.PT end
M.drawn_width = drawn_width

-- Icon sizes in screen units (the drawing code in ui.lua uses the same numbers).
M.ICON = { h = 22, face = 22, bumper = 34, trigger = 30, stick = 22, dpad = 22, mouse = 16, key_min = 22, key_pad = 10, inner_gap = 3 }
local MOUSE_ARROW = { move = "↔", wheel_up = "↑", wheel_down = "↓" }

local function key_size(label) return (#label > 1 and label:match("^[%w]+$")) and 12 or 13 end

function M.icon_width(kind, arg)
    local I = M.ICON
    if kind == "face" then return I.face end
    if kind == "bumper" then return I.bumper end
    if kind == "trigger" then return I.trigger end
    if kind == "stick" then return I.stick end
    if kind == "dpad" then return I.dpad end
    if kind == "key" then return math.max(I.key_min, drawn_width(arg, key_size(arg)) + I.key_pad) end
    if kind == "mouse" then
        local arrow = MOUSE_ARROW[arg]
        return I.mouse + (arrow and (3 + drawn_width(arrow, 12)) or 0)
    end
    if kind == "hold" then return drawn_width(arg, 12) + 4 end
    if kind == "sep" then return drawn_width(arg, 13) + 6 end
    return 0
end

-- Lay the rows out. opts: x (left of the device labels), y (top of the first row), label_w (label column; nil =
-- as wide as the widest device label at label_size + 14), row_h, max_right (nil = no limit), size (description
-- font size), gap (space between items). Widths are the drawn widths (points, see M.PT).
-- If a row would pass max_right the description size shrinks (to 11) and then the gap (to 8).
-- Returns ops (drawing instructions with absolute positions), the right edge used, and the size / gap chosen.
-- ops: { op = "label", x, y, text } | { op = "icon", kind, arg, x, y, w, arrow?, key_size? } | { op = "text", x, y, text, size }
function M.layout_help(rows, japanese, opts)
    local colon = japanese and "：" or ": "
    local function row_width(row, size, gap)
        local width = 0
        for index, item in ipairs(row.items) do
            if index > 1 then width = width + gap end
            for i, icon in ipairs(item.icons) do
                if i > 1 then width = width + M.ICON.inner_gap end
                width = width + M.icon_width(icon[1], icon[2])
            end
            width = width + 2 + drawn_width(colon .. item.text, size)
        end
        return width
    end
    local size, gap = opts.size or 13, opts.gap or 14
    local label_w = opts.label_w
    if not label_w then
        label_w = 0
        for _, row in ipairs(rows) do label_w = math.max(label_w, drawn_width(row.label, opts.label_size or 13)) end
        label_w = math.ceil(label_w + 14)
    end
    local start = opts.x + label_w
    if opts.max_right then
        local function widest() local w = 0 for _, row in ipairs(rows) do w = math.max(w, row_width(row, size, gap)) end return w end
        while start + widest() > opts.max_right and size > 11 do size = size - 1 end
        while start + widest() > opts.max_right and gap > 8 do gap = gap - 1 end
    end
    local ops, right = {}, start
    for r, row in ipairs(rows) do
        local y = opts.y + (r - 1) * opts.row_h
        ops[#ops + 1] = { op = "label", x = opts.x, y = y, text = row.label }
        local x = start
        for index, item in ipairs(row.items) do
            if index > 1 then x = x + gap end
            for i, icon in ipairs(item.icons) do
                if i > 1 then x = x + M.ICON.inner_gap end
                local w = M.icon_width(icon[1], icon[2])
                ops[#ops + 1] = { op = "icon", kind = icon[1], arg = icon[2], x = x, y = y, w = w,
                    arrow = icon[1] == "mouse" and MOUSE_ARROW[icon[2]] or nil, key_size = icon[1] == "key" and key_size(icon[2]) or nil }
                x = x + w
            end
            local label = colon .. item.text
            ops[#ops + 1] = { op = "text", x = x + 2, y = y, text = label, size = size }
            x = x + 2 + drawn_width(label, size)
        end
        right = math.max(right, x)
    end
    return ops, right, size, gap
end

-- Where every row of the main screen sits inside the panel (the renderer and the mouse share this):
-- layout[i] = { y = top, h = height, header = bool }. Returns the list and the y below the last row.
function M.row_layout(rows, body_y, head_h, row_h)
    local layout, y = {}, body_y
    for index, row in ipairs(rows) do
        local h = row.header and head_h or row_h
        layout[index] = { y = y, h = h, header = row.header ~= nil }
        y = y + h
    end
    return layout, y
end

-- Which half of a drawn value text (x0 .. x1, e.g. "<  0.86  >") the point px is on: "less" left of the
-- middle, "more" right of it, nil outside (with `pad` px of slack on both ends).
function M.value_part(px, x0, x1, pad)
    pad = pad or 0
    if type(px) ~= "number" or px < x0 - pad or px > x1 + pad then return nil end
    return (px < (x0 + x1) / 2) and "less" or "more"
end

-- The selectable row under panel point (px, py), and the part of it: "less" / "more" for the left / right half
-- of the value, "label" elsewhere. Headers and gaps give nil. spans[index] = { x0, x1 }: where the value text
-- of that row is drawn (its arrows move with the text length); without it the value column
-- (value_x .. value_x + value_w) is split in the middle.
function M.hit_row(rows, layout, px, py, left, right, value_x, value_w, box_h, spans)
    if type(px) ~= "number" or type(py) ~= "number" or px < left or px > right then return nil end
    for index, slot in ipairs(layout) do
        if not slot.header and rows[index] and not rows[index].header and py >= slot.y and py < slot.y + box_h then
            local span = spans and spans[index]
            local part
            if span then
                part = M.value_part(px, span[1], span[2], 20)
            elseif px >= value_x and px <= value_x + value_w then
                part = (px < value_x + value_w / 2) and "less" or "more"
            end
            return index, part or "label"
        end
    end
    return nil
end

-- Rough rendered width of a label at a font size (no font metrics are available from Lua). Deliberately on the
-- generous side: CJK / full-width characters are one em, everything else 0.6 em (a space 0.35 em).
function M.text_width(label, size)
    local width = 0
    local ok = pcall(function()
        for _, code in utf8.codes(label) do
            if code >= 0x2E80 then width = width + 1.0
            elseif code == 32 then width = width + 0.35
            elseif code >= 0x80 then width = width + 0.8
            else width = width + 0.6 end
        end
    end)
    if not ok then width = #label * 0.8 end
    return width * size
end

-- The largest font size <= `size` (not below `min_size`) at which the label fits in max_width.
function M.fit_size(label, size, max_width, min_size)
    local width = M.text_width(label, size)
    if width <= max_width then return size end
    local fitted = math.floor(size * max_width / width * 10) / 10
    return math.max(min_size or 9, fitted)
end

local function selectable(row) return row.entry ~= nil or row.action ~= nil end
M.selectable = selectable

function M.label(entry, japanese) return japanese and entry.ja or entry.en end
function M.group_title(group, japanese) local g = config.groups[group]; return japanese and g.ja or g.en end

local function trim_number(value)
    if value % 1 == 0 then return string.format("%d", value) end
    local text = string.format("%.3f", value):gsub("0+$", ""):gsub("%.$", "")
    return text
end

function M.format_value(entry, value, japanese)
    if entry.kind == "bool" then
        if japanese then return value and "オン" or "オフ" end
        return value and "ON" or "OFF"
    end
    return trim_number(value)
end

function M.format_default(entry, japanese) return M.format_value(entry, entry.default, japanese) end

-- New value after one step. dir = -1 / +1; big = x10. Booleans just toggle.
function M.step(entry, value, dir, big)
    if entry.kind == "bool" then return not value end
    local amount = entry.step * (big and 10 or 1) * dir
    local v = math.floor((value + amount) * 1e4 + 0.5) / 1e4 -- no float drift (0.1 + 0.2 ...)
    return store.sanitize_value(entry, v)
end

-- Index of the next selectable row (entry) from `index` in direction dir (+1/-1), wrapping round.
function M.move(rows, index, dir)
    local n = #rows
    local i = index
    for _ = 1, n do
        i = i + dir
        if i > n then i = 1 elseif i < 1 then i = n end
        if selectable(rows[i]) then return i end
    end
    return index
end

function M.first_selectable(rows)
    for i, row in ipairs(rows) do if selectable(row) then return i end end
    return 1
end

-- First visible row so that `selected` is on screen (keeps `first` when it already is).
-- When scrolling up onto the first entry the group header above it is brought into view too.
function M.window_start(rows, selected, per_page, first)
    local max_first = math.max(1, #rows - per_page + 1)
    first = math.max(1, math.min(first or 1, max_first))
    local top = selected
    if rows[selected - 1] and rows[selected - 1].header then top = selected - 1 end
    if top < first then first = top end
    if selected > first + per_page - 1 then first = selected - per_page + 1 end
    return first
end

-- Write `value` into the settings table. The pitch limits must stay apart: a change that would
-- make them meet or cross is refused (returns false).
function M.apply(settings, key, value)
    local old = settings[key]
    settings[key] = value
    if settings.pitch_min >= settings.pitch_max then
        settings[key] = old
        return false
    end
    return true
end

return M
