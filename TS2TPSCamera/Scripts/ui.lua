-- The F1 screens: UMG widgets built in Lua (same technique as the SN2Settings mod).
--   main screen   - list of settings (settings_model.lua), keyboard + gamepad + mouse (cursor shown; the
--                   widgets ignore the mouse, so clicks reach the game's input and are hit-tested here)
--   camera screen - "camera position" editor with the centre of the screen left clear
-- Keys that need hold/repeat are polled here; the rest come in through screen.key(name) from main.lua.
-- The game is frozen (time dilation ~0, components keep ticking so camera changes show at once) while a
-- screen is open, and the game's own input is switched off so ESC/Start cannot open its menus.
local model = require("settings_model")
local config = require("config")
local store = require("store")

local M = {}

local palette = {
    text = { R = .93, G = .95, B = .97, A = 1 }, accent = { R = .95, G = .72, B = .3, A = 1 },
    muted = { R = .72, G = .75, B = .78, A = 1 }, warn = { R = 1, G = .43, B = .34, A = 1 },
    panel = { R = .04, G = .045, B = .055, A = .95 }, panel_rim = { R = .65, G = .5, B = .25, A = .55 },
    side_panel = { R = .02, G = .02, B = .03, A = .78 },
    row = { R = 1, G = 1, B = 1, A = .045 }, selected = { R = .95, G = .72, B = .3, A = .22 },
    line = { R = .7, G = .6, B = .4, A = .35 },
}
-- Every row of the main screen is on screen at once (no scrolling): the panel height follows from the rows.
local BASE_PANEL_W = 980 -- the main panel grows past this when the help lines need it
local MARGIN = 30
local BODY_Y = 62
local HEAD_H = 30 -- group heading row
local ROW_H = 32  -- setting row
local FOOT_H = 134 -- two help blocks, the mouse line + the note line
-- value column of a setting row (the mouse clicks its left / right half to lower / raise the value)
local VALUE_X, VALUE_W = 680, 180

-- Camera screen steps per repeat (the settings' own steps are coarser).
local STEP = { height = 2, shoulder = 2, distance = 4, fov = 1 }
local HOLD_RESET_SECONDS = 1.0

-- Inputs polled while a screen is open. Directions repeat while held; `hold` = fires once after that long.
local function dirs(action, pad_key, keys, delay, interval)
    local list = { { key = pad_key, action = action, repeats = true, delay = delay, interval = interval } }
    for _, k in ipairs(keys) do list[#list + 1] = { key = k, action = action, repeats = true, delay = delay, interval = interval } end
    return list
end
local function join(...)
    local out = {}
    for _, list in ipairs({ ... }) do for _, item in ipairs(list) do out[#out + 1] = item end end
    return out
end

local MAIN_INPUTS = join(
    dirs("up", "Gamepad_DPad_Up", { "Up", "W" }),
    dirs("down", "Gamepad_DPad_Down", { "Down", "S" }),
    dirs("left", "Gamepad_DPad_Left", { "Left", "A" }),
    dirs("right", "Gamepad_DPad_Right", { "Right", "D" }),
    dirs("left_big", "Gamepad_LeftShoulder", { "PageDown" }),
    dirs("right_big", "Gamepad_RightShoulder", { "PageUp" }),
    { { key = "Gamepad_FaceButton_Left", action = "reset" },
      { key = "Gamepad_FaceButton_Bottom", action = "confirm" },
      { key = "Gamepad_FaceButton_Right", action = "close" },
      { key = "Escape", action = "close" } })

local CAMERA_INPUTS = join(
    dirs("cam_up", "Gamepad_DPad_Up", { "Up", "W" }, 0.3, 0.04),
    dirs("cam_down", "Gamepad_DPad_Down", { "Down", "S" }, 0.3, 0.04),
    dirs("cam_left", "Gamepad_DPad_Left", { "Left", "A" }, 0.3, 0.04),
    dirs("cam_right", "Gamepad_DPad_Right", { "Right", "D" }, 0.3, 0.04),
    dirs("cam_far", "Gamepad_LeftShoulder", { "PageDown" }, 0.3, 0.04),
    dirs("cam_near", "Gamepad_RightShoulder", { "PageUp" }, 0.3, 0.04),
    dirs("cam_fov_up", "Gamepad_LeftTriggerAxis", { "Q" }, 0.3, 0.05),
    dirs("cam_fov_down", "Gamepad_RightTriggerAxis", { "E" }, 0.3, 0.05),
    { { key = "Gamepad_FaceButton_Left", action = "cam_reset", hold = HOLD_RESET_SECONDS },
      { key = "R", action = "cam_reset", hold = HOLD_RESET_SECONDS },
      { key = "Gamepad_FaceButton_Right", action = "back" },
      { key = "Escape", action = "back" } })

-- ctx: valid, log, player() -> pawn, pc, settings (live table), on_change(key|nil), can_open() -> ok, why,
--      key_state(pc, FName), set_open(bool), language() -> "ja" | "en" | ...
function M.new(ctx)
    assert(ctx and ctx.valid and ctx.log and ctx.player and ctx.settings and ctx.on_change and ctx.can_open and ctx.key_state,
        "settings screen context incomplete")
    local settings = ctx.settings
    local rows = model.rows()
    local PER_PAGE = #rows -- everything fits, nothing scrolls
    local body_h = 0
    for _, row in ipairs(rows) do body_h = body_h + (row.header and HEAD_H or ROW_H) end
    local FOOT_Y = BODY_Y + body_h + 10
    local PANEL_H = FOOT_Y + FOOT_H
    local PANEL_W = BASE_PANEL_W
    local value_shift = 0 -- the value column moves right with the panel
    local view, generation = nil, 0
    local opened = 0 -- counts openings: a hand-back of the game's input from an earlier close must not run into a new one
    local mode = "main"
    local selected = model.first_selectable(rows)
    local first = 1
    local frozen = nil -- { paused = bool, dilation = number|nil, pc = ... }
    local input_state = nil
    local font_object, font_searched = nil, false
    local held = {}
    local note = nil
    local hold_progress = 0
    local layout = model.row_layout(rows, BODY_Y, HEAD_H, ROW_H)
    local value_spans = {} -- row index -> { x0, x1 } of the value text as drawn (for the mouse)
    local mouse = {}
    local CLOSE_BOX = { x = PANEL_W - MARGIN - 40, y = 8, w = 50, h = 40 } -- the x in the top right corner

    -- Screen language: always the game's own language (ctx.language() -> "ja", "en", ...), read at every open.
    local game_is_japanese = false
    local function japanese() return game_is_japanese end

    local function class(name)
        local found = StaticFindObject("/Script/UMG." .. name)
        assert(ctx.valid(found), "UMG class missing: " .. name)
        return found
    end
    local function colour(value) return { SpecifiedColor = value, ColorUseRule = 0 } end
    local function make(name)
        local widget = StaticConstructObject(class(name), view.tree)
        assert(ctx.valid(widget), "could not construct UMG " .. name)
        return widget
    end

    -- Borrow a font the game's own UI already uses. For Japanese, prefer the font of a text block that is
    -- itself showing Japanese text right now (so the glyphs are known to exist); else any text block's font.
    local function has_cjk(label)
        local ok, result = pcall(function()
            for _, code in utf8.codes(label) do if code >= 0x3040 then return true end end
            return false
        end)
        return ok and result == true
    end

    local function find_game_font(want_cjk)
        local any, cjk, cjk_text = nil, nil, nil
        local blocks = FindAllOf("TextBlock") or {}
        for _, block in ipairs(blocks) do
            if ctx.valid(block) then
                local found = nil
                pcall(function() found = block.Font.FontObject end)
                if ctx.valid(found) then
                    any = any or found
                    if want_cjk and not cjk then
                        local label = nil
                        pcall(function() label = block:GetText():ToString() end)
                        if type(label) == "string" and has_cjk(label) then cjk, cjk_text = found, label end
                    end
                end
            end
        end
        ctx.log(string.format("settings screen font search: %d text blocks, japanese-text font=%s (%s), any=%s", #blocks,
            cjk and cjk:GetFullName() or "none", tostring(cjk_text), any and any:GetFullName() or "none"))
        return cjk or any
    end

    -- One font for every character. The game has no Japanese font of its own: kana/kanji come from the
    -- engine's fallback face (DroidSansFallback) while Latin/digits come from the game's Erika (or Roboto).
    -- To make the whole screen look alike, build a font object whose every typeface entry is that same
    -- DroidSansFallback face (it also contains Latin letters, digits and symbols).
    local FALLBACK_FACE = "/Engine/EngineFonts/Faces/DroidSansFallback.DroidSansFallback"
    local TEMPLATE_FONT = "/Engine/EngineFonts/Roboto.Roboto"
    local unified_font = nil

    local function build_unified_font()
        if unified_font and ctx.valid(unified_font) then return unified_font end
        unified_font = nil
        local face = StaticFindObject(FALLBACK_FACE)
        if not ctx.valid(face) then ctx.log("unified font: DroidSansFallback face not found"); return nil end
        local template = StaticFindObject(TEMPLATE_FONT)
        if not ctx.valid(template) then ctx.log("unified font: template font not found"); return nil end
        local created = nil
        local ok, err = pcall(function()
            created = StaticConstructObject(template:GetClass(), view.tree, FName("TS2TPSUnifiedFont"), 0, 0, false, false, template)
        end)
        if not ok or not ctx.valid(created) then ctx.log("unified font: could not create font object: " .. tostring(err)); return nil end
        local replaced, total = 0, 0
        local function set_face(entry)
            total = total + 1
            local done = false
            for _, field in ipairs({ "FontFaceAsset", "LocalFontFaceAsset" }) do
                if not done then
                    done = pcall(function() entry.Font[field] = face end)
                    if done then done = (entry.Font[field] ~= nil) end
                end
            end
            if done then replaced = replaced + 1 end
        end
        local fok, ferr = pcall(function()
            local fonts = created.CompositeFont.DefaultTypeface.Fonts
            fonts:ForEach(function(_, element)
                local entry = element
                pcall(function() entry = element:get() end)
                set_face(entry)
            end)
        end)
        ctx.log(string.format("unified font: created %s, typeface entries replaced %d/%d%s", created:GetFullName(),
            replaced, total, fok and "" or (" error=" .. tostring(ferr))))
        if replaced == 0 or replaced ~= total then return nil end
        unified_font = created
        return unified_font
    end

    local function game_font()
        if font_searched then return font_object end
        font_searched = true
        font_object = build_unified_font()
        if not font_object then font_object = find_game_font(japanese()) end
        return font_object
    end

    -- max_w (optional): the text must stay inside this width, so the font shrinks if it would not fit.
    local function text(label, size, tint, max_w)
        local widget = make("TextBlock")
        widget:SetText(FText(label))
        widget:SetColorAndOpacity(colour(tint or palette.text))
        local font = widget.Font
        font.Size = max_w and model.fit_size(label, size, max_w, 9) or size
        local gf = game_font()
        if gf then pcall(function() font.FontObject = gf end) end
        widget:SetFont(font)
        return widget
    end

    -- Placement relative to the centre of the screen (main screen panel).
    local function put(widget, x, y, w, h, z)
        local slot = view.content:AddChildToCanvas(widget)
        slot:SetAnchors({ Minimum = { X = .5, Y = .5 }, Maximum = { X = .5, Y = .5 } })
        slot:SetAlignment({ X = 0, Y = 0 })
        slot:SetPosition({ X = x - PANEL_W / 2, Y = y - PANEL_H / 2 })
        if w then slot:SetSize({ X = w, Y = h }) else slot:SetAutoSize(true) end
        slot:SetZOrder(z or 0)
        return widget
    end

    -- Placement relative to a screen corner: (ax, ay) = (1, 1) bottom right, (0, 1) bottom left.
    -- (px, py) is the panel's top-left offset from the corner anchor; (dx, dy) the child's offset in the panel.
    local function put_corner(widget, ax, px, py, dx, dy, w, h, z)
        local slot = view.content:AddChildToCanvas(widget)
        slot:SetAnchors({ Minimum = { X = ax, Y = 1 }, Maximum = { X = ax, Y = 1 } })
        slot:SetAlignment({ X = 0, Y = 0 })
        slot:SetPosition({ X = px + dx, Y = py + dy })
        if w then slot:SetSize({ X = w, Y = h }) else slot:SetAutoSize(true) end
        slot:SetZOrder(z or 0)
        return widget
    end

    local function make_box(w, h, fill, rim, width, radius)
        local image = make("Image")
        local ok = pcall(function()
            local brush = image.Brush
            brush.DrawAs = 4
            brush.ImageSize = { X = w, Y = h }
            brush.TintColor = colour(fill)
            brush.OutlineSettings.RoundingType = 0
            brush.OutlineSettings.CornerRadii = { X = radius, Y = radius, Z = radius, W = radius }
            brush.OutlineSettings.Width = width
            brush.OutlineSettings.Color = colour(rim)
            image:SetBrush(brush)
        end)
        if not ok then pcall(function() image:SetColorAndOpacity(fill) end) end
        return image
    end
    local function box(x, y, w, h, fill, rim, width, radius, z)
        return put(make_box(w, h, fill, rim, width, radius), x, y, w, h, z)
    end

    ------------------------------------------------------------------ control help icons
    -- "icon: description" help (settings_model.help_rows / layout_help). Icons are rounded boxes and text
    -- only. place(widget, x, y, w, h, z) puts a widget in the coordinates of the panel being drawn.
    local icon_col = {
        A = { R = .24, G = .65, B = .21, A = 1 }, B = { R = .88, G = .22, B = .17, A = 1 },
        X = { R = .18, G = .49, B = .82, A = 1 }, Y = { R = .91, G = .72, B = .10, A = 1 },
        dark = { R = .2, G = .215, B = .235, A = 1 }, rim = { R = .54, G = .56, B = .59, A = 1 },
        stick_top = { R = .31, G = .32, B = .35, A = 1 }, white = { R = 1, G = 1, B = 1, A = 1 },
        key = { R = .84, G = .85, B = .87, A = 1 }, key_shadow = { R = .47, G = .49, B = .51, A = 1 },
        key_text = { R = .09, G = .1, B = .12, A = 1 },
    }

    -- text centred in the box (x, y, w, h)
    local function centered_text(label, size, tint, x, y, w, h, place, z)
        local widget = text(label, size, tint)
        pcall(function() widget:SetJustification(1) end) -- ETextJustify::Center
        local line_h = size * model.PT * 1.2
        place(widget, x, y + (h - line_h) / 2, w, line_h, z)
    end

    local function draw_icon(op, place)
        local I = model.ICON
        local x, y, h, kind, arg = op.x, op.y, I.h, op.kind, op.arg
        local function bx(dx, dy, w, bh, fill, rim, width, radius, z)
            place(make_box(w, bh, fill, rim or fill, width or 0, radius or 0), x + dx, y + dy, w, bh, z or 4)
        end
        local accent = palette.accent
        if kind == "face" then
            bx(0, 0, I.face, h, icon_col[arg] or icon_col.dark, nil, 0, h / 2)
            centered_text(arg, 13, icon_col.white, x, y, I.face, h, place, 5)
        elseif kind == "bumper" then
            bx(0, 2, I.bumper, h - 4, icon_col.dark, icon_col.rim, 1, 6)
            centered_text(arg, 11, icon_col.white, x, y, I.bumper, h, place, 5)
        elseif kind == "trigger" then
            bx(0, 0, I.trigger, h, icon_col.dark, icon_col.rim, 1, 9)
            centered_text(arg, 11, icon_col.white, x, y, I.trigger, h, place, 5)
        elseif kind == "stick" then
            bx(0, 0, I.stick, h, icon_col.dark, icon_col.rim, 1, h / 2)
            bx(4, 4, h - 8, h - 8, icon_col.stick_top, nil, 0, (h - 8) / 2, 5)
            centered_text(arg, 9, icon_col.white, x, y, I.stick, h, place, 6)
        elseif kind == "dpad" then
            local size, arm = I.dpad, 8
            local c = (size - arm) / 2
            bx(c, 0, arm, size, icon_col.dark, nil, 0, 2)
            bx(0, c, size, arm, icon_col.dark, nil, 0, 2)
            if arg:find("u", 1, true) then bx(c, 0, arm, c + 1, accent, nil, 0, 2, 5) end
            if arg:find("d", 1, true) then bx(c, size - c - 1, arm, c + 1, accent, nil, 0, 2, 5) end
            if arg:find("l", 1, true) then bx(0, c, c + 1, arm, accent, nil, 0, 2, 5) end
            if arg:find("r", 1, true) then bx(size - c - 1, c, c + 1, arm, accent, nil, 0, 2, 5) end
        elseif kind == "key" then
            bx(0, 1, op.w, h, icon_col.key_shadow, nil, 0, 4)
            bx(0, 0, op.w, h - 1, icon_col.key, nil, 0, 4, 5)
            centered_text(arg, op.key_size or 13, icon_col.key_text, x, y, op.w, h - 1, place, 6)
        elseif kind == "mouse" then
            local w = I.mouse
            bx(0, 0, w, h, icon_col.dark, icon_col.rim, 1, w / 2)
            if arg == "left" then bx(1, 1, w / 2 - 1, h / 2 - 1, accent, nil, 0, 6, 5) end
            if arg == "right" then bx(w / 2, 1, w / 2 - 1, h / 2 - 1, accent, nil, 0, 6, 5) end
            bx(w / 2 - 0.5, 1, 1, h / 2 - 1, icon_col.rim, nil, 0, 0, 6)
            if arg:find("wheel", 1, true) then bx(w / 2 - 2, 4, 4, 7, accent, nil, 0, 2, 7) end
            if op.arrow then place(text(op.arrow, 12, accent), x + w + 3, y + (h - 12 * model.PT * 1.2) / 2, nil, nil, 5) end
        elseif kind == "hold" then
            place(text(arg, 12, accent), x + 2, y + (h - 12 * model.PT * 1.2) / 2, nil, nil, 5)
        elseif kind == "sep" then
            place(text(arg, 13, palette.muted), x + 3, y + (h - 13 * model.PT * 1.2) / 2, nil, nil, 5)
        end
    end

    local function draw_help(ops, place, label_size)
        local h = model.ICON.h
        for _, op in ipairs(ops) do
            if op.op == "label" then
                place(text(op.text, label_size, palette.accent), op.x, op.y + (h - label_size * model.PT * 1.2) / 2, nil, nil, 3)
            elseif op.op == "text" then
                place(text(op.text, op.size, palette.muted), op.x, op.y + (h - op.size * model.PT * 1.2) / 2, nil, nil, 3)
            else
                draw_icon(op, place)
            end
        end
    end

    ------------------------------------------------------------------ main screen
    local function render_main()
        view.dim:SetBrushColor({ R = 0, G = 0, B = 0, A = .55 })
        local ja = japanese()
        -- the help lines decide the panel width (each "icon: description" line stays inside the frame)
        local help_ops, help_right = model.layout_help(model.help_rows("main", ja), ja, { x = MARGIN, y = FOOT_Y + 10,
            label_size = 13, row_h = 34, size = 13, gap = 14 })
        PANEL_W = math.max(BASE_PANEL_W, math.ceil(help_right + MARGIN))
        value_shift = PANEL_W - BASE_PANEL_W
        CLOSE_BOX.x = PANEL_W - MARGIN - 40
        box(0, 0, PANEL_W, PANEL_H, palette.panel, palette.panel_rim, 1, 14, 0)
        put(text(ja and "TPSカメラ 設定" or "TPS Camera Settings", 24, palette.text, 600), MARGIN, 14, 600, 34, 3)
        put(text("F1", 16, palette.accent), PANEL_W - MARGIN - 100, 20, 40, 26, 3)
        put(text("×", 26, palette.text), CLOSE_BOX.x + 14, CLOSE_BOX.y + 2, 36, 36, 3)

        first = model.window_start(rows, selected, PER_PAGE, first) -- always 1: every row fits
        value_spans = {}
        local y = BODY_Y
        local inner_w = PANEL_W - 2 * MARGIN
        for index = first, math.min(#rows, first + PER_PAGE - 1) do
            local row = rows[index]
            if row.header then
                put(text(model.group_title(row.header, ja), 15, palette.accent, inner_w - 8), MARGIN + 4, y + 6, inner_w - 8, 22, 3)
                box(MARGIN, y + HEAD_H - 3, inner_w, 1, palette.line, palette.line, 0, 0, 2)
                y = y + HEAD_H
            else
                local is_sel = index == selected
                box(MARGIN, y, inner_w, ROW_H - 4, is_sel and palette.selected or palette.row,
                    is_sel and palette.accent or palette.row, is_sel and 1 or 0, 6, 1)
                if row.action then
                    put(text(model.action_label(row.action, ja), 17, palette.accent, 640), MARGIN + 14, y + 2, 640, 24, 3)
                    put(text(">>", 18, palette.accent), 850 + value_shift, y + 1, 60, 26, 3)
                else
                    local entry = row.entry
                    local value = settings[entry.key]
                    put(text(model.label(entry, ja), 17, palette.text, 630), MARGIN + 14, y + 2, 630, 24, 3)
                    local shown = model.format_value(entry, value, ja)
                    if is_sel then shown = "<  " .. shown .. "  >" end
                    local vx = 690 + value_shift
                    put(text(shown, 18, value ~= entry.default and palette.accent or palette.text, 160), vx, y + 1, 160, 26, 3)
                    value_spans[index] = { vx, vx + math.min(160, model.drawn_width(shown, model.fit_size(shown, 18, 160, 9))) }
                    if value ~= entry.default then
                        put(text((ja and "既定 " or "Default ") .. model.format_default(entry, ja), 12, palette.muted, 80), 860 + value_shift, y + 6, 80, 18, 3)
                    end
                end
                y = y + ROW_H
            end
        end

        -- footer: one line each for the gamepad, the keyboard and the mouse, as "icon: description"
        box(MARGIN, FOOT_Y - 4, inner_w, 1, palette.line, palette.line, 0, 0, 2)
        draw_help(help_ops, function(widget, x, y, w, h, z) put(widget, x, y, w, h, z) end, 13)
        if note then put(text(note, 14, palette.warn, inner_w), MARGIN, FOOT_Y + 108, inner_w, 20, 3) end
    end

    ------------------------------------------------------------------ camera position screen
    -- Only two small panels in the bottom corners; the middle stays clear so the character is visible.
    local function render_camera()
        view.dim:SetBrushColor({ R = 0, G = 0, B = 0, A = 0 })
        local ja = japanese()

        -- bottom left: controls, one line each for the gamepad, the keyboard and the mouse ("icon: description")
        local help_ops, help_right = model.layout_help(model.help_rows("camera", ja), ja, { x = 16, y = 48,
            label_size = 14, row_h = 36, size = 14, gap = 16 })
        local GW, GH = help_right + 24, 48 + 36 * 3 + 6
        local gx, gy = MARGIN, -(MARGIN + GH)
        put_corner(make_box(GW, GH, palette.side_panel, palette.panel_rim, 1, 10), 0, gx, gy, 0, 0, GW, GH, 0)
        put_corner(text(ja and "カメラ位置変更" or "Camera position", 18, palette.accent, GW - 32), 0, gx, gy, 16, 10, nil, nil, 3)
        draw_help(help_ops, function(widget, x, y, w, h, z) put_corner(widget, 0, gx, gy, x, y, w, h, z) end, 14)

        -- bottom right: the numbers
        local VW, VH = 330, 180
        local vx, vy = -(MARGIN + VW), -(MARGIN + VH)
        put_corner(make_box(VW, VH, palette.side_panel, palette.panel_rim, 1, 10), 1, vx, vy, 0, 0, VW, VH, 0)
        put_corner(text(ja and "カメラ位置" or "Camera position", 16, palette.accent, VW - 32), 1, vx, vy, 16, 8, nil, nil, 3)
        local items = {
            { "distance", ja and "距離（奥行き）" or "Distance (depth)" },
            { "height", ja and "高さ" or "Height" },
            { "shoulder", ja and "左右" or "Side" },
            { "fov", ja and "視野角" or "FOV" },
        }
        for i, item in ipairs(items) do
            local entry = config.by_key[item[1]]
            local value = settings[item[1]]
            put_corner(text(item[2], 17, palette.text, 170), 1, vx, vy, 16, 8 + i * 30, nil, nil, 3)
            put_corner(text(model.format_value(entry, value, ja), 20, value ~= entry.default and palette.accent or palette.text, VW - 200 - 16), 1, vx, vy, 200, 6 + i * 30, nil, nil, 3)
        end
        if hold_progress > 0 then
            put_corner(text((ja and "リセット中 " or "Resetting ") .. string.format("%d%%", math.floor(hold_progress * 100)), 14, palette.warn, VW - 32), 1, vx, vy, 16, 8 + 5 * 30 - 4, nil, nil, 3)
        end
    end

    local function render()
        if not view then return end
        view.content:ClearChildren()
        if mode == "camera" then render_camera() else render_main() end
    end

    ------------------------------------------------------------------ freeze / unfreeze
    -- SetGamePaused reported success but the game kept running, so time is stopped with the global
    -- time dilation instead (minimum 0.0001): everything stands still, components still tick.
    local function statics_object() return StaticFindObject("/Script/Engine.Default__GameplayStatics") end

    -- The pause menu (IA_Pause on Esc / Start) is an action of the controller's in-game mapping contexts, and
    -- DisableInput does not switch the controller's own input off: Esc pressed here also opened the pause menu.
    -- Those contexts are taken away while a screen is open; the game's own SwitchMapToInGame (what it calls when
    -- its inventory closes) puts the right one back once the keys that closed the screen are up.
    local PAUSE_CONTEXTS = {
        "/Game/NewInputSystem/IMC_InGame.IMC_InGame",
        "/Game/NewInputSystem/IMC_InGame2.IMC_InGame2",
        "/Game/NewInputSystem/IMC_InGame3.IMC_InGame3",
    }

    local function input_subsystem()
        for _, sub in ipairs(FindAllOf("EnhancedInputLocalPlayerSubsystem") or {}) do
            if ctx.valid(sub) then return sub end
        end
        return nil
    end

    local function remove_pause_contexts()
        local sub = input_subsystem()
        if not ctx.valid(sub) then
            ctx.log("settings screen: no EnhancedInputLocalPlayerSubsystem - Esc may still open the pause menu")
            return false
        end
        local removed, problems = 0, {}
        local options = { bIgnoreAllPressedKeysUntilRelease = true, bForceImmediately = true, bNotifyUserSettings = false }
        for _, path in ipairs(PAUSE_CONTEXTS) do
            local imc = StaticFindObject(path)
            if ctx.valid(imc) then
                local ok, err = pcall(function() sub:RemoveMappingContext(imc, options) end)
                if not ok then ok, err = pcall(function() sub:RemoveMappingContext(imc) end) end
                if ok then removed = removed + 1 else problems[#problems + 1] = path:match("[^.]+$") .. ": " .. tostring(err) end
            end
        end
        ctx.log(string.format("settings screen: in-game input contexts taken away (%d)%s", removed,
            #problems > 0 and (" problems: " .. table.concat(problems, "; ")) or ""))
        return removed > 0
    end

    local function restore_pause_contexts(pc)
        local ok, err = pcall(function() pc:SwitchMapToInGame() end)
        ctx.log("settings screen: in-game input given back (SwitchMapToInGame " .. tostring(ok) .. (ok and "" or (" " .. tostring(err))) .. ")")
    end

    local function freeze_game(pc, pawn)
        local statics = statics_object()
        frozen = { pc = pc, pawn = pawn }
        -- the game's own input (Esc / Start opening its menu, shooting ...) is off while we are open
        pcall(function() pc:DisableInput(pc) end)
        pcall(function() pawn:DisableInput(pc) end)
        frozen.contexts_removed = remove_pause_contexts()
        if not ctx.valid(statics) then return end
        local ok, previous = pcall(function() return statics:GetGlobalTimeDilation(pc) end)
        frozen.dilation = (ok and type(previous) == "number" and previous > 0.01) and previous or 1.0
        local set_ok = pcall(function() statics:SetGlobalTimeDilation(pc, 0.0001) end)
        if not set_ok then frozen.dilation = nil end
        ctx.log(string.format("settings screen: game frozen (time dilation %s, was %s)", tostring(set_ok), tostring(previous)))
    end

    -- Give the game its input back, but only after the keys used to close the screen are released,
    -- otherwise the same Esc press would open the game's pause menu.
    local function release_game_input(pc, pawn, give_contexts_back)
        local tries, done = 0, false
        local my_open = opened
        LoopInGameThreadWithDelay(60, function()
            -- the loop did not always stop on "return true" (seen after a call into a game function): the work
            -- is done once, later calls only ask to stop again
            if done then return true end
            -- the screen was opened again meanwhile: that screen keeps the game's input off and gives it back itself
            if opened ~= my_open then done = true return true end
            tries = tries + 1
            local held_key = nil
            if ctx.valid(pc) then
                for _, name in ipairs({ "Escape", "F1", "Enter", "Gamepad_FaceButton_Right", "Gamepad_FaceButton_Bottom", "RightMouseButton" }) do
                    if ctx.key_state(pc, FName(name)) > 0.5 then held_key = name end
                end
            end
            if held_key and tries < 12 then return false end
            if held_key then ctx.log("settings screen: " .. held_key .. " still reads as held after 0.7 s; giving the input back anyway") end
            done = true
            if ctx.valid(pc) then pcall(function() pc:EnableInput(pc) end) end
            if ctx.valid(pawn) and ctx.valid(pc) then pcall(function() pawn:EnableInput(pc) end) end
            if give_contexts_back and ctx.valid(pc) then restore_pause_contexts(pc) end
            return true
        end)
    end

    local function unfreeze_game()
        local state = frozen
        frozen = nil
        if not state then return end
        local statics = statics_object()
        local pc = state.pc
        if not ctx.valid(pc) then local _, fallback = ctx.player(); pc = fallback end
        if state.dilation and ctx.valid(statics) and ctx.valid(pc) then
            pcall(function() statics:SetGlobalTimeDilation(pc, state.dilation) end)
        end
        if ctx.valid(pc) then release_game_input(pc, state.pawn, state.contexts_removed) end
    end

    ------------------------------------------------------------------ mouse cursor
    -- Main screen: cursor shown, game + UI input (keys still reach the game's input, which we poll).
    -- Camera screen and closed: cursor hidden, game-only input (the mouse turns the camera again).
    local function set_cursor(pc, on)
        if not ctx.valid(pc) then return end
        pcall(function() pc.bShowMouseCursor = on end)
        local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
        if not ctx.valid(lib) then return end
        local ok, err
        if on then
            ok, err = pcall(function() lib:SetInputMode_GameAndUIEx(pc, nil, 0, false, false) end)
        else
            ok, err = pcall(function() lib:SetInputMode_GameOnly(pc, false) end)
        end
        if not mouse.mode_logged or not ok then
            mouse.mode_logged = true
            ctx.log(string.format("settings screen: mouse cursor %s (input mode set=%s%s)", on and "shown" or "hidden", tostring(ok), ok and "" or (" " .. tostring(err))))
        end
    end

    ------------------------------------------------------------------ actions
    local function close()
        generation = generation + 1
        local old, state = view, input_state
        view, input_state = nil, nil
        mode = "main"
        if state and ctx.valid(state.pc) then set_cursor(state.pc, false) end
        unfreeze_game()
        if old and ctx.valid(old.root) then pcall(function() old.root:RemoveFromParent() end) end
        if state and ctx.valid(state.pc) then
            pcall(function() state.pc:SetIgnoreLookInput(false) end)
            pcall(function() state.pc:SetIgnoreMoveInput(false) end)
        end
        if ctx.set_open then ctx.set_open(false) end
        if old then ctx.on_change(nil) end -- final refresh + save
    end

    -- Keys down right now must not count as a new press in the screen that is about to appear.
    local function block_held_keys()
        local now = os.clock()
        for _, list in ipairs({ MAIN_INPUTS, CAMERA_INPUTS }) do
            for _, def in ipairs(list) do
                held[def.key] = { down = true, since = now, fired = true, next = math.huge }
            end
        end
        hold_progress = 0
    end

    local function change(dir, big)
        local row = rows[selected]
        if not row or not row.entry then return end
        local entry = row.entry
        local new_value = model.step(entry, settings[entry.key], dir, big)
        note = nil
        if not model.apply(settings, entry.key, new_value) then
            note = japanese() and "上下限が重なるため変更できません" or "The look-up and look-down limits may not meet"
        else
            ctx.on_change(entry.key)
        end
        render()
    end

    local function reset_item()
        local row = rows[selected]
        if not row or not row.entry then return end
        note = nil
        if model.apply(settings, row.entry.key, row.entry.default) then ctx.on_change(row.entry.key) end
        render()
    end

    local function open_camera()
        if (mouse.switch_logs or 0) < 30 then
            mouse.switch_logs = (mouse.switch_logs or 0) + 1
            ctx.log("settings screen: camera position screen opened")
        end
        mouse.quiet_until = os.clock() + 0.25
        mode = "camera"
        if input_state then set_cursor(input_state.pc, false) end
        note = nil
        block_held_keys()
        render()
    end

    local function back_to_main(reason)
        if (mouse.switch_logs or 0) < 30 then
            mouse.switch_logs = (mouse.switch_logs or 0) + 1
            ctx.log("settings screen: back to the main screen (" .. tostring(reason or "B / ESC") .. ")")
        end
        mouse.quiet_until = os.clock() + 0.25
        mode = "main"
        mouse.x, mouse.y = nil, nil
        if input_state then set_cursor(input_state.pc, true) end
        block_held_keys()
        render()
    end

    -- camera screen: change one value by a step (clamped to its range) and apply at once
    local function nudge(key, sign)
        local entry = config.by_key[key]
        local raw = settings[key] + sign * STEP[key]
        local value = store.sanitize_value(entry, math.floor(raw * 1e4 + 0.5) / 1e4)
        if value ~= settings[key] then
            settings[key] = value
            ctx.on_change(key)
        end
        render()
    end

    local function reset_camera()
        for _, key in ipairs({ "distance", "height", "shoulder", "fov" }) do settings[key] = config.by_key[key].default end
        ctx.on_change("distance")
        hold_progress = 0
        render()
    end

    local actions = {
        up = function() selected = model.move(rows, selected, -1); note = nil; mouse.x = nil; render() end,
        down = function() selected = model.move(rows, selected, 1); note = nil; mouse.x = nil; render() end,
        left = function() change(-1, false) end,
        right = function() change(1, false) end,
        left_big = function() change(-1, true) end,
        right_big = function() change(1, true) end,
        reset = reset_item,
        confirm = function()
            mouse.last_confirm = os.clock()
            local row = rows[selected]
            if (mouse.confirm_logs or 0) < 20 then
                mouse.confirm_logs = (mouse.confirm_logs or 0) + 1
                ctx.log(string.format("settings screen: confirm on row %d (%s)", selected,
                    row and (row.action or (row.entry and row.entry.key) or row.header) or "?"))
            end
            if row and row.action == "camera_screen" then open_camera() end
        end,
        close = close,
        cam_up = function() nudge("height", 1) end,
        cam_down = function() nudge("height", -1) end,
        cam_left = function() nudge("shoulder", -1) end,
        cam_right = function() nudge("shoulder", 1) end,
        cam_far = function() nudge("distance", 1) end,
        cam_fov_up = function() nudge("fov", 1) end,
        cam_fov_down = function() nudge("fov", -1) end,
        cam_near = function() nudge("distance", -1) end,
        cam_reset = reset_camera,
        back = function() back_to_main("B / ESC") end,
    }

    local function poll_inputs(token)
        if token ~= generation or not view then return true end
        local pc = input_state and input_state.pc
        if not ctx.valid(pc) then return false end
        local now = os.clock()
        local progress = 0
        for _, def in ipairs(mode == "camera" and CAMERA_INPUTS or MAIN_INPUTS) do
            local fname = def.fname
            if not fname then fname = FName(def.key); def.fname = fname end
            local down = ctx.key_state(pc, fname) > 0.5
            local st = held[def.key]
            if not st then st = { down = false }; held[def.key] = st end
            if down then
                if not st.down then
                    st.down, st.since, st.fired, st.next = true, now, false, now + (def.delay or 0.45)
                    if not def.hold then
                        st.fired = true
                        actions[def.action]()
                        if not view then return true end
                    end
                elseif def.hold then
                    if not st.fired then
                        local p = (now - st.since) / def.hold
                        if p >= 1 then
                            st.fired = true
                            actions[def.action]()
                            if not view then return true end
                        elseif p > progress then
                            progress = p
                        end
                    end
                elseif def.repeats and now >= (st.next or math.huge) then
                    st.next = now + (def.interval or 0.09)
                    actions[def.action]()
                    if not view then return true end
                end
            else
                st.down = false
            end
        end
        if mode == "camera" and (math.abs(progress - hold_progress) >= 0.05 or (progress == 0 and hold_progress ~= 0)) then
            hold_progress = progress
            render()
        end
        return false
    end

    ------------------------------------------------------------------ mouse (called every frame while open)
    local layout_lib = nil
    -- mouse position in panel coordinates (the panel is centred), plus the raw viewport position
    local function mouse_in_panel(pc)
        layout_lib = (layout_lib and ctx.valid(layout_lib)) and layout_lib or StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
        if not ctx.valid(layout_lib) then return nil end
        local pos = layout_lib:GetMousePositionOnViewport(pc)
        local size = layout_lib:GetViewportSize(pc)
        local scale = layout_lib:GetViewportScale(pc)
        local mx, my, sx, sy = pos.X, pos.Y, size.X, size.Y
        if type(mx) ~= "number" or type(my) ~= "number" or type(sx) ~= "number" or type(sy) ~= "number"
            or type(scale) ~= "number" or scale <= 0 then return nil end
        local vw, vh = sx / scale, sy / scale
        if not mouse.pos_logged then
            mouse.pos_logged = true
            ctx.log(string.format("settings screen mouse: position (%.0f, %.0f), viewport %.0fx%.0f px, scale %.3f -> %.0fx%.0f units, panel %dx%d",
                mx, my, sx, sy, scale, vw, vh, PANEL_W, PANEL_H))
        end
        return mx - (vw / 2 - PANEL_W / 2), my - (vh / 2 - PANEL_H / 2), mx, my
    end

    -- A press event this frame. Mouse buttons are read this way, not from their held state: that state was seen
    -- reading "held" with nobody pressing (after the input mode changes), which made phantom clicks.
    local function just_pressed(pc, key)
        local ok, result = pcall(function() return pc:WasInputKeyJustPressed({ KeyName = FName(key) }) end)
        return ok and result == true
    end

    -- The game turns gamepad A into a left click at the cursor (CommonUI's gamepad cursor), so with the pad the
    -- mouse handling must stand aside: A on "Open camera position screen" also clicked the row under the cursor.
    -- The pad counts as active while the game's CommonInputSubsystem says so (input type 1 = gamepad) or a pad
    -- button is down / was pressed just now.
    local common_input = nil
    local PAD_BUTTONS = { "Gamepad_FaceButton_Bottom", "Gamepad_FaceButton_Right", "Gamepad_FaceButton_Left", "Gamepad_FaceButton_Top" }
    local function gamepad_active(pc)
        for _, key in ipairs(PAD_BUTTONS) do
            if ctx.key_state(pc, FName(key)) > 0.5 or just_pressed(pc, key) then mouse.pad_until = os.clock() + 0.4 end
        end
        if os.clock() < (mouse.pad_until or 0) then return true end
        if not (common_input and ctx.valid(common_input)) then
            common_input = nil
            for _, sub in ipairs(FindAllOf("CommonInputSubsystem") or {}) do
                if ctx.valid(sub) then common_input = sub break end
            end
        end
        if common_input then
            local ok, kind = pcall(function() return common_input:GetCurrentInputType() end)
            if ok and type(kind) == "number" then
                if kind ~= mouse.input_kind and (mouse.kind_logs or 0) < 20 then
                    mouse.kind_logs = (mouse.kind_logs or 0) + 1
                    ctx.log("settings screen: game input type " .. tostring(kind) .. " (0 mouse/keyboard, 1 gamepad)")
                end
                mouse.input_kind = kind
                return kind == 1
            end
        end
        return false
    end

    local function wheel_step(pc)
        if just_pressed(pc, "MouseScrollUp") then return 1 end
        if just_pressed(pc, "MouseScrollDown") then return -1 end
        return 0
    end

    local function mouse_frame(pc)
        if not view or not ctx.valid(pc) then return end
        local left_click = just_pressed(pc, "LeftMouseButton")
        local right_click = just_pressed(pc, "RightMouseButton")
        -- no clicks in the first moment after a screen switch (the press that switched may still be reported)
        if os.clock() < (mouse.quiet_until or 0) then left_click, right_click = false, false end
        local wheel = wheel_step(pc)
        if gamepad_active(pc) then
            -- The pad is in use: the game may turn its A press into a click at the cursor, and then the A button
            -- itself never shows up (seen in the log: the first A gave only a click). Such a click is the A press:
            -- confirm the selected row (unless A already confirmed just now). The cursor position plays no part.
            if left_click then
                local handled = mode == "main" and os.clock() - (mouse.last_confirm or -10) > 0.3
                if (mouse.pad_click_logs or 0) < 10 then
                    mouse.pad_click_logs = (mouse.pad_click_logs or 0) + 1
                    ctx.log("settings screen: gamepad A arrived as a click -> " .. (handled and "confirm" or "ignored"))
                end
                if handled then actions.confirm() end
            end
            mouse.x, mouse.y = nil, nil
            return
        end
        if mode == "camera" then
            if right_click then back_to_main("right click") return end
            if wheel > 0 then nudge("distance", -1) elseif wheel < 0 then nudge("distance", 1) end
            return
        end
        if right_click then close() return end
        local ok, px, py, mx, my = pcall(mouse_in_panel, pc)
        if not ok or not px then
            if not ok and not mouse.error_logged then mouse.error_logged = true; ctx.log("settings screen mouse error: " .. tostring(px)) end
            return
        end
        -- The pointer takes the selection only after it really moved: a still (or hidden) cursor must not pull the
        -- selection away from the pad / keys. The anchor is dropped (nil) whenever the pad or the keys move the
        -- selection or a screen switches; the next frame only sets it again.
        local moved = false
        if mouse.x == nil then
            mouse.x, mouse.y = mx, my
        elseif math.abs(mx - mouse.x) + math.abs(my - mouse.y) > 6 then
            moved = true
            mouse.x, mouse.y = mx, my
        end
        if left_click and px >= CLOSE_BOX.x and px <= CLOSE_BOX.x + CLOSE_BOX.w and py >= CLOSE_BOX.y and py <= CLOSE_BOX.y + CLOSE_BOX.h then
            close()
            return
        end
        local index, part = model.hit_row(rows, layout, px, py, MARGIN, PANEL_W - MARGIN, VALUE_X + value_shift, VALUE_W, ROW_H - 4, value_spans)
        if not index then return end
        -- pointing selects (only when the mouse moved, so a still cursor does not fight the keys)
        if index ~= selected and (moved or left_click or wheel ~= 0) then
            selected = index
            note = nil
            render()
        end
        local row = rows[index]
        if left_click then
            if row.action then
                actions.confirm()
            elseif row.entry then
                if row.entry.kind == "bool" then change(1, false)
                elseif part == "less" then change(-1, false)
                elseif part == "more" then change(1, false) end
            end
        elseif wheel ~= 0 and row.entry then
            change(wheel, false)
        end
    end

    local function open()
        opened = opened + 1
        local ok_open, why = ctx.can_open()
        if not ok_open then ctx.log("settings screen not opened: " .. tostring(why)); return false end
        local pawn, pc = ctx.player()
        if not ctx.valid(pawn) or not ctx.valid(pc) then return false end
        local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
        local root = lib:Create(pc, class("UserWidget"), pc)
        assert(ctx.valid(root), "could not create root widget")
        view = { pc = pc, root = root, lib = lib }
        view.tree = StaticConstructObject(class("WidgetTree"), root)
        root.WidgetTree = view.tree
        local canvas = make("CanvasPanel"); view.tree.RootWidget = canvas
        view.dim = make("Border"); view.dim:SetBrushColor({ R = 0, G = 0, B = 0, A = .55 })
        local dim_slot = canvas:AddChildToCanvas(view.dim)
        dim_slot:SetAnchors({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 1, Y = 1 } })
        dim_slot:SetOffsets({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
        view.content = make("CanvasPanel")
        local content_slot = canvas:AddChildToCanvas(view.content)
        content_slot:SetAnchors({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 1, Y = 1 } })
        content_slot:SetOffsets({ Left = 0, Top = 0, Right = 0, Bottom = 0 })
        content_slot:SetZOrder(1)
        pcall(function() root:SetVisibility(3) end) -- HitTestInvisible: clicks go to the game's input, not the widgets
        root:AddToViewport(1600)
        input_state = { pc = pc }
        mode = "main"
        pcall(function() pc:SetIgnoreLookInput(true) end)
        pcall(function() pc:SetIgnoreMoveInput(true) end)
        if ctx.language then
            local ok, lang = pcall(ctx.language)
            game_is_japanese = ok and type(lang) == "string" and lang:lower():sub(1, 2) == "ja"
        end
        if ctx.set_open then ctx.set_open(true) end
        freeze_game(pc, pawn)
        mouse.quiet_until = os.clock() + 0.25
        mouse.x, mouse.y = nil, nil
        set_cursor(pc, true)
        note = nil
        font_searched = false
        block_held_keys()
        render()
        local token = generation
        LoopInGameThreadWithDelay(40, function()
            local ok, result = pcall(poll_inputs, token)
            if not ok then ctx.log("settings screen poll error: " .. tostring(result)); return true end
            return result
        end)
        return true
    end

    local function try_open()
        if view then return true end
        local ok, result = pcall(open)
        if not ok then close(); ctx.log("settings screen failed to open: " .. tostring(result)); return false end
        return result == true and view ~= nil
    end

    return {
        open = try_open,
        close = function() if view then close() end end,
        toggle = function() if view then close() else try_open() end end,
        is_open = function() return view ~= nil end,
        -- every frame while open (main.lua): mouse clicks / wheel
        frame = function(pc)
            if not view then return end
            local pok, perr = pcall(poll_inputs, generation)
            if not pok and not mouse.poll_error then mouse.poll_error = true; ctx.log("settings screen poll error (frame): " .. tostring(perr)) end
            if not view then return end
            local ok, err = pcall(mouse_frame, pc)
            if not ok and not mouse.frame_error then mouse.frame_error = true; ctx.log("settings screen mouse error: " .. tostring(err)) end
        end,
        -- true while the cursor is shown: the mouse must not turn the camera then
        cursor_active = function() return view ~= nil and mode ~= "camera" end,
        -- keys that arrive as key binds (main.lua): reset confirm close
        key = function(name)
            if not view then return end
            if mode == "camera" then
                return
            elseif name == "lang" then
                return
            elseif actions[name] then
                actions[name]()
            end
        end,
    }
end

return M
