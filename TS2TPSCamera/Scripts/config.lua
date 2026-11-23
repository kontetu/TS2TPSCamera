-- Setting schema + defaults for TS2TPSCamera. Pure data (no game access), so tests can load it.
-- Order = order on the F1 screen and in settings_values.lua. ja/en = labels, group = section.
-- hidden = saved and used, but not listed on the F1 list (distance/height/side/fov are set on the camera
-- position screen; the rest keep their defaults).
local groups = {
    general = { ja = "全般", en = "General" },
    pad_look   = { ja = "視点操作（パッド）", en = "Look controls (gamepad)" },
    mouse_look = { ja = "操作視点（マウス）", en = "Look controls (mouse)" },
    camera  = { ja = "カメラ", en = "Camera" },
    combat  = { ja = "戦闘・その他", en = "Combat and misc" },
}

local entries = {
    -- camera group, first row: the TPS on/off switch (then the camera position screen row, see settings_model)
    { key = "enabled",        kind = "bool",   default = true, group = "camera", ja = "TPSカメラ（OFFで元の固定カメラ）", en = "TPS camera (OFF = original fixed camera)" },
    { key = "japanese_value", kind = "number", default = 9, min = -1, max = 60, step = 1, group = "general", hidden = true, ja = "日本語に当たるゲームの言語番号（ログで 9 を確認済み。ゲームの文字が読めないときだけ使う）", en = "Game language number for Japanese (9 confirmed in the log; only used if the game texts cannot be read)" },
    -- camera
    { key = "distance",       kind = "number", default = 120,  min = 60,   max = 600, step = 10, group = "camera", hidden = true, ja = "カメラ距離", en = "Distance" },
    { key = "height",         kind = "number", default = 52,   min = -50,  max = 200, step = 5,  group = "camera", hidden = true, ja = "カメラの高さ", en = "Height" },
    { key = "shoulder",       kind = "number", default = 24,   min = -150, max = 150, step = 5,  group = "camera", hidden = true, ja = "左右位置（＋で右寄り）", en = "Side offset (+ = right)" },
    { key = "fov",            kind = "number", default = 72,   min = 50,   max = 110, step = 1,  group = "camera", hidden = true, ja = "視野角 (FOV)", en = "Field of view" },
    { key = "start_pitch",    kind = "number", default = -12,  min = -80,  max = 80,  step = 1,  group = "camera", hidden = true, ja = "開始時の上下角", en = "Start pitch" },
    { key = "pitch_min",      kind = "number", default = -60,  min = -85,  max = 0,   step = 1,  group = "camera", hidden = true, ja = "見下ろす限界", en = "Look-down limit" },
    { key = "pitch_max",      kind = "number", default = 60,   min = 0,    max = 85,  step = 1,  group = "camera", hidden = true, ja = "見上げる限界", en = "Look-up limit" },
    { key = "wall_check",     kind = "bool",   default = true, group = "camera", hidden = true, ja = "壁めり込み防止", en = "Wall check" },
    { key = "cut_blend",      kind = "number", default = 0.0,  min = 0.0,  max = 1.5, step = 0.05, group = "camera", hidden = true, ja = "部屋切替のブレンド秒", en = "Room cut blend (s)" },
    -- look controls: gamepad (right stick). The stick's up/down arrives opposite to the mouse, camera_math flips it.
    { key = "use_pad",        kind = "bool",   default = true, group = "pad_look", hidden = true, ja = "右スティックで視点操作", en = "Right stick look" },
    { key = "pad_sens_x",     kind = "number", default = 170,  min = 20,   max = 400, step = 10, group = "pad_look", ja = "右スティック感度 左右", en = "Right stick sensitivity (left/right)" },
    { key = "pad_sens_y",     kind = "number", default = 170,  min = 20,   max = 400, step = 10, group = "pad_look", ja = "右スティック感度 上下", en = "Right stick sensitivity (up/down)" },
    { key = "pad_deadzone",   kind = "number", default = 0.15, min = 0.0,  max = 0.6, step = 0.01, group = "pad_look", ja = "スティックのデッドゾーン", en = "Stick dead zone" },
    { key = "pad_look_invert_x", kind = "bool", default = false, group = "pad_look", ja = "右スティックの左右反転", en = "Invert right stick left/right" },
    { key = "pad_look_invert_y", kind = "bool", default = false, group = "pad_look", ja = "右スティックの上下反転", en = "Invert right stick up/down" },
    -- look controls: mouse
    { key = "use_mouse",      kind = "bool",   default = true, group = "mouse_look", hidden = true, ja = "マウスで視点操作", en = "Mouse look" },
    { key = "mouse_sens_x",   kind = "number", default = 0.86, min = 0.02, max = 1.0, step = 0.01, group = "mouse_look", ja = "マウスの感度 左右", en = "Mouse sensitivity (left/right)" },
    { key = "mouse_sens_y",   kind = "number", default = 0.85, min = 0.02, max = 1.0, step = 0.01, group = "mouse_look", ja = "マウスの感度 上下", en = "Mouse sensitivity (up/down)" },
    { key = "mouse_invert_x", kind = "bool",   default = false, group = "mouse_look", ja = "マウスの左右反転", en = "Invert mouse left/right" },
    { key = "mouse_invert_y", kind = "bool",   default = false, group = "mouse_look", ja = "マウスの上下反転", en = "Invert mouse up/down" },
    -- camera (the camera position screen is opened from the first row of this group)
    { key = "auto_recenter",  kind = "bool",   default = false, group = "camera", ja = "移動中にカメラを自動で背後へ回す", en = "Auto-turn camera behind while moving" },
    { key = "auto_recenter_speed", kind = "number", default = 1, min = 0.1, max = 3.0, step = 0.1, group = "camera", ja = "自動で背後へ回る速さ", en = "Auto-turn speed" },
    -- combat / misc
    { key = "lockon_camera",  kind = "bool",   default = true, group = "combat", hidden = true, ja = "構え中にカメラを敵へ向ける", en = "Turn camera to locked-on enemy" },
    { key = "lockon_speed",   kind = "number", default = 4.0,  min = 0.5,  max = 15,  step = 0.5, group = "combat", hidden = true, ja = "敵へ向く速さ", en = "Lock-on turn speed" },
    { key = "dpad_shortcuts", kind = "bool",   default = true, group = "combat", hidden = true, ja = "十字キーで武器切替（右スティックはカメラ専用）", en = "D-pad weapon shortcut" },
    { key = "keep_when_grabbed", kind = "bool", default = true, group = "combat", hidden = true, ja = "敵に捕まっている間もTPS", en = "Keep TPS while grabbed" },
    { key = "keep_on_ladder", kind = "bool",   default = true, group = "combat", hidden = true, ja = "はしごの上り下りもTPS", en = "Keep TPS on ladders" },
    { key = "wasd_move",      kind = "bool",   default = true, group = "combat", hidden = true, ja = "WASDで左スティック同様に移動", en = "WASD moves like the left stick" },
}
local by_key = {}
for _, entry in ipairs(entries) do by_key[entry.key] = entry end
return { entries = entries, by_key = by_key, groups = groups, group_order = { "camera", "pad_look", "mouse_look", "general", "combat" } }
