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
local PANEL_W = 980
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
    local view, generation = nil, 0
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
    local mouse = { left = false, right = false }
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

    ------------------------------------------------------------------ main screen
    local function render_main()
        view.dim:SetBrushColor({ R = 0, G = 0, B = 0, A = .55 })
        local ja = japanese()
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
                    put(text(">>", 18, palette.accent), 850, y + 1, 60, 26, 3)
                else
                    local entry = row.entry
                    local value = settings[entry.key]
                    put(text(model.label(entry, ja), 17, palette.text, 630), MARGIN + 14, y + 2, 630, 24, 3)
                    local shown = model.format_value(entry, value, ja)
                    if is_sel then shown = "<  " .. shown .. "  >" end
                    put(text(shown, 18, value ~= entry.default and palette.accent or palette.text, 160), 690, y + 1, 160, 26, 3)
                    value_spans[index] = { 690, 690 + math.min(160, model.text_width(shown, model.fit_size(shown, 18, 160, 9))) }
                    if value ~= entry.default then
                        put(text((ja and "既定 " or "Default ") .. model.format_default(entry, ja), 12, palette.muted, 80), 860, y + 6, 80, 18, 3)
                    end
                end
                y = y + ROW_H
            end
        end

        -- footer: one block for the gamepad, one for the keyboard (each help line stays inside the panel)
        local pad_help, key_help = model.footer_help(ja)
        box(MARGIN, FOOT_Y - 4, inner_w, 1, palette.line, palette.line, 0, 0, 2)
        put(text(ja and "パッド" or "Gamepad", 13, palette.accent, 300), MARGIN, FOOT_Y + 2, 300, 20, 3)
        put(text(pad_help, 13, palette.muted, inner_w), MARGIN, FOOT_Y + 21, inner_w, 20, 3)
        put(text(ja and "キーボード" or "Keyboard", 13, palette.accent, 300), MARGIN, FOOT_Y + 43, 300, 20, 3)
        put(text(key_help, 13, palette.muted, inner_w), MARGIN, FOOT_Y + 62, inner_w, 20, 3)
        put(text(model.mouse_help(ja), 13, palette.muted, inner_w), MARGIN, FOOT_Y + 85, inner_w, 20, 3)
        if note then put(text(note, 14, palette.warn, inner_w), MARGIN, FOOT_Y + 108, inner_w, 20, 3) end
    end

    ------------------------------------------------------------------ camera position screen
    -- Only two small panels in the bottom corners; the middle stays clear so the character is visible.
    local function render_camera()
        view.dim:SetBrushColor({ R = 0, G = 0, B = 0, A = 0 })
        local ja = japanese()

        -- bottom left: controls
        local GW, GH = 640, 188
        local gx, gy = MARGIN, -(MARGIN + GH)
        put_corner(make_box(GW, GH, palette.side_panel, palette.panel_rim, 1, 10), 0, gx, gy, 0, 0, GW, GH, 0)
        local lines
        if ja then
            lines = { "十字キー / 矢印キー: カメラ位置を上下左右へ", "右スティック / マウス: 視点操作", "LB / PgDn / ホイール下: カメラを手前へ　　RB / PgUp / ホイール上: カメラを奥へ", "LT / Q: 視野角+　　RT / E: 視野角-", "X / R長押し: すべてリセット　　B / ESC / 右クリック: 設定画面へ戻る" }
        else
            lines = { "D-pad / arrow keys: move camera position up, down, left, right", "Right stick / mouse: look around", "LB / PgDn / wheel down: camera nearer    RB / PgUp / wheel up: camera farther", "LT / Q: FOV +    RT / E: FOV -", "Hold X / R: reset all    B / ESC / right click: back to settings" }
        end
        put_corner(text(ja and "カメラ位置変更" or "Camera position", 18, palette.accent, GW - 32), 0, gx, gy, 16, 10, nil, nil, 3)
        for i, line in ipairs(lines) do put_corner(text(line, 15, palette.text, GW - 32), 0, gx, gy, 16, 12 + i * 26, nil, nil, 3) end

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

    local function freeze_game(pc, pawn)
        local statics = statics_object()
        frozen = { pc = pc, pawn = pawn }
        -- the game's own input (Esc / Start opening its menu, shooting ...) is off while we are open
        pcall(function() pc:DisableInput(pc) end)
        pcall(function() pawn:DisableInput(pc) end)
        if not ctx.valid(statics) then return end
        local ok, previous = pcall(function() return statics:GetGlobalTimeDilation(pc) end)
        frozen.dilation = (ok and type(previous) == "number" and previous > 0.01) and previous or 1.0
        local set_ok = pcall(function() statics:SetGlobalTimeDilation(pc, 0.0001) end)
        if not set_ok then frozen.dilation = nil end
        ctx.log(string.format("settings screen: game frozen (time dilation %s, was %s)", tostring(set_ok), tostring(previous)))
    end

    -- Give the game its input back, but only after the keys used to close the screen are released,
    -- otherwise the same Esc press would open the game's pause menu.
    local function release_game_input(pc, pawn)
        local tries = 0
        LoopInGameThreadWithDelay(60, function()
            tries = tries + 1
            local still_down = false
            if ctx.valid(pc) then
                for _, name in ipairs({ "Escape", "F1", "Enter", "Gamepad_FaceButton_Right", "Gamepad_FaceButton_Bottom", "LeftMouseButton", "RightMouseButton" }) do
                    if ctx.key_state(pc, FName(name)) > 0.5 then still_down = true end
                end
            end
            if still_down and tries < 50 then return false end
            if ctx.valid(pc) then pcall(function() pc:EnableInput(pc) end) end
            if ctx.valid(pawn) and ctx.valid(pc) then pcall(function() pawn:EnableInput(pc) end) end
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
        if ctx.valid(pc) then release_game_input(pc, state.pawn) end
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
        mode = "camera"
        if input_state then set_cursor(input_state.pc, false) end
        note = nil
        block_held_keys()
        render()
    end

    local function back_to_main()
        mode = "main"
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
        up = function() selected = model.move(rows, selected, -1); note = nil; render() end,
        down = function() selected = model.move(rows, selected, 1); note = nil; render() end,
        left = function() change(-1, false) end,
        right = function() change(1, false) end,
        left_big = function() change(-1, true) end,
        right_big = function() change(1, true) end,
        reset = reset_item,
        confirm = function()
            local row = rows[selected]
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
        back = back_to_main,
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

    local function wheel_step(pc)
        local function just(key)
            local ok, result = pcall(function() return pc:WasInputKeyJustPressed({ KeyName = FName(key) }) end)
            return ok and result == true
        end
        if just("MouseScrollUp") then return 1 end
        if just("MouseScrollDown") then return -1 end
        return 0
    end

    local function mouse_frame(pc)
        if not view or not ctx.valid(pc) then return end
        local left = ctx.key_state(pc, FName("LeftMouseButton")) > 0.5
        local right = ctx.key_state(pc, FName("RightMouseButton")) > 0.5
        local left_click, right_click = left and not mouse.left, right and not mouse.right
        mouse.left, mouse.right = left, right
        local wheel = wheel_step(pc)
        if mode == "camera" then
            if right_click then back_to_main() return end
            if wheel > 0 then nudge("distance", -1) elseif wheel < 0 then nudge("distance", 1) end
            return
        end
        if right_click then close() return end
        local ok, px, py, mx, my = pcall(mouse_in_panel, pc)
        if not ok or not px then
            if not ok and not mouse.error_logged then mouse.error_logged = true; ctx.log("settings screen mouse error: " .. tostring(px)) end
            return
        end
        local moved = mouse.x == nil or math.abs(mx - mouse.x) + math.abs(my - mouse.y) > 1
        mouse.x, mouse.y = mx, my
        if left_click and px >= CLOSE_BOX.x and px <= CLOSE_BOX.x + CLOSE_BOX.w and py >= CLOSE_BOX.y and py <= CLOSE_BOX.y + CLOSE_BOX.h then
            close()
            return
        end
        local index, part = model.hit_row(rows, layout, px, py, MARGIN, PANEL_W - MARGIN, VALUE_X, VALUE_W, ROW_H - 4, value_spans)
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
        mouse.left = ctx.key_state(pc, FName("LeftMouseButton")) > 0.5
        mouse.right = ctx.key_state(pc, FName("RightMouseButton")) > 0.5
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
