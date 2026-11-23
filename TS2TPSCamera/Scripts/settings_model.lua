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

-- The two help lines at the bottom of the main screen (gamepad, keyboard).
function M.footer_help(japanese)
    if japanese then
        return "方向キー上下で項目、方向キー左右で値変更、RB/LBで10倍ずつ値変更、Xでそれぞれを初期化、Aで決定、Bで閉じる",
            "矢印キー上下で項目、矢印キー左右で値変更、PgUp/PgDnで10倍ずつ値変更、Rでそれぞれを初期化、Enterで決定、ESCかF1で閉じる"
    end
    return "D-pad up/down: select, left/right: change value, RB/LB: 10x, X: reset item, A: confirm, B: close",
        "Up/Down: select, Left/Right: change value, PgUp/PgDn: 10x, R: reset item, Enter: confirm, ESC or F1: close"
end

-- Third help line of the main screen: the mouse.
function M.mouse_help(japanese)
    if japanese then
        return "マウス: カーソルを合わせて選択、値の左側/右側をクリックで減らす/増やす（オン/オフはクリックで切替）、ホイールで値変更、右クリックで閉じる"
    end
    return "Mouse: point to select, click left / right of a value: lower / raise (ON/OFF: click), wheel: change, right click: close"
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
