-- Run with tests/run_tests.py (needs `pip install lupa`). Plain asserts, no framework.
local cam = require("camera_math")
local store = require("store")
local config = require("config")

local failures, count = 0, 0
local function check(name, cond, detail)
    count = count + 1
    if not cond then failures = failures + 1; print("FAIL: " .. name .. (detail and (" -> " .. tostring(detail)) or "")) end
end
local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-6) end

-- wrap180 / angle_diff
check("wrap 190", near(cam.wrap180(190), -170))
check("wrap -190", near(cam.wrap180(-190), 170))
check("wrap 180", near(cam.wrap180(180), 180))
check("wrap 720", near(cam.wrap180(720), 0))
check("diff across seam", near(cam.angle_diff(170, -170), 20))
check("diff other way", near(cam.angle_diff(-170, 170), -20))

-- step_angle
check("step small", near(cam.step_angle(0, 5, 10), 5))
check("step capped", near(cam.step_angle(0, 50, 10), 10))
check("step across seam", near(cam.step_angle(175, -175, 3), 178))
check("step negative", near(cam.step_angle(0, -50, 10), -10))

-- damp_angle
check("damp zero dt", near(cam.damp_angle(10, 90, 4, 0), 10))
local d = cam.damp_angle(0, 90, 4, 0.1)
check("damp moves toward", d > 0 and d < 90, d)
check("damp frame independent", near(cam.damp_angle(cam.damp_angle(0, 90, 4, 0.05), 90, 4, 0.05), cam.damp_angle(0, 90, 4, 0.1), 1e-6))
check("damp shortest way", cam.damp_angle(170, -170, 4, 0.1) > 170 or cam.damp_angle(170, -170, 4, 0.1) < -170)

-- deadzone
check("deadzone inside", cam.deadzone(0.1, 0.15) == 0)
check("deadzone full", near(cam.deadzone(1, 0.15), 1))
check("deadzone negative", near(cam.deadzone(-1, 0.15), -1))
check("deadzone scaled", near(cam.deadzone(0.575, 0.15), 0.5))

-- apply_look
local cfg = store.defaults()
local y, p = cam.apply_look(0, 0, { mx = 10, my = 0, rx = 0, ry = 0 }, cfg, 0.016)
check("mouse right turns right", near(y, 10 * cfg.mouse_sens_x), y)
y, p = cam.apply_look(0, 0, { mx = 0, my = 10, rx = 0, ry = 0 }, cfg, 0.016)
check("mouse up looks up", near(p, 10 * cfg.mouse_sens_y), p)
cfg.mouse_invert_y = true
y, p = cam.apply_look(0, 0, { mx = 0, my = 10, rx = 0, ry = 0 }, cfg, 0.016)
check("mouse invert y", near(p, -10 * cfg.mouse_sens_y), p)
cfg.mouse_invert_y = false
cfg.mouse_invert_x = true
y, p = cam.apply_look(0, 0, { mx = 10, my = 0, rx = 0, ry = 0 }, cfg, 0.016)
check("mouse invert x", near(y, -10 * cfg.mouse_sens_x), y)
y, p = cam.apply_look(0, 0, { mx = 0, my = 0, rx = 1, ry = 1 }, cfg, 0.1)
check("mouse invert leaves the stick alone", y > 0 and p < 0, y)
cfg.mouse_invert_x = false
y, p = cam.apply_look(0, 0, { mx = 0, my = 0, rx = 1, ry = 0 }, cfg, 0.5)
check("pad full right for 0.5s", near(y, cfg.pad_sens_x * 0.5), y)
y, p = cam.apply_look(0, 0, { mx = 0, my = 0, rx = 0, ry = 1 }, cfg, 0.2)
check("pad up (game delivers it flipped) looks down by default", near(p, -cfg.pad_sens_y * 0.2), p)
cfg.pad_look_invert_y = true
y, p = cam.apply_look(0, 0, { mx = 0, my = 0, rx = 0, ry = 1 }, cfg, 0.2)
check("pad invert y flips it", near(p, cfg.pad_sens_y * 0.2), p)
cfg.pad_look_invert_y = false
cfg.pad_look_invert_x = true
y, p = cam.apply_look(0, 0, { mx = 0, my = 0, rx = 1, ry = 0 }, cfg, 0.2)
check("pad invert x flips it", near(y, -cfg.pad_sens_x * 0.2), y)
cfg.pad_look_invert_x = false
y, p = cam.apply_look(0, 0, { mx = 0, my = 10, rx = 0, ry = 0 }, cfg, 0.5)
check("mouse unaffected by the pad settings", near(p, 10 * cfg.mouse_sens_y), p)
y, p = cam.apply_look(0, 0, { mx = 0, my = 0, rx = 0.1, ry = 0.1 }, cfg, 1)
check("pad inside deadzone ignored", y == 0 and p == 0)
y, p = cam.apply_look(0, 59, { mx = 0, my = 1000, rx = 0, ry = 0 }, cfg, 0.016)
check("pitch clamped high", near(p, cfg.pitch_max), p)
y, p = cam.apply_look(0, -59, { mx = 0, my = -1000, rx = 0, ry = 0 }, cfg, 0.016)
check("pitch clamped low", near(p, cfg.pitch_min), p)
y, p = cam.apply_look(179, 0, { mx = 20, my = 0, rx = 0, ry = 0 }, cfg, 0.016)
check("yaw wraps", y < 0 and y > -180, y)
cfg.use_mouse = false
y, p = cam.apply_look(0, 0, { mx = 100, my = 100, rx = 0, ry = 0 }, cfg, 0.016)
check("mouse disabled", y == 0 and p == 0)

-- target angles
check("yaw to +Y", near(cam.yaw_to_target({ X = 0, Y = 0 }, { X = 0, Y = 5 }), 90))
check("yaw to -X", near(math.abs(cam.yaw_to_target({ X = 0, Y = 0 }, { X = -5, Y = 0 })), 180))
check("pitch up", near(cam.pitch_to_target({ X = 0, Y = 0, Z = 0 }, { X = 10, Y = 0, Z = 10 }), 45))

-- lock-on step
do
    local c = store.defaults()
    local from, to = { X = 0, Y = 0, Z = 0 }, { X = 0, Y = 500, Z = 0 }
    local ny, np = cam.lockon_step(0, 0, from, to, c, 0.1)
    check("lockon turns toward +Y", ny > 0 and ny < 90, ny)
    local yy = 0
    for _ = 1, 200 do yy = cam.lockon_step(yy, 0, from, to, c, 0.05) end
    check("lockon converges", near(yy, 90, 0.5), yy)
    local sy = 170
    for _ = 1, 200 do sy = cam.lockon_step(sy, 0, from, { X = -500, Y = -1, Z = 0 }, c, 0.05) end
    check("lockon shortest way across seam", math.abs(sy) > 178, sy)
    local py = 0
    local pp = 0
    for _ = 1, 200 do py, pp = cam.lockon_step(py, pp, from, { X = 100, Y = 0, Z = 1e6 }, c, 0.05) end
    check("lockon pitch clamped", near(pp, c.pitch_max), pp)
    check("lockon ignores target on top of player", cam.lockon_step(0, 0, from, { X = 5, Y = 5, Z = 0 }, c, 0.1) == nil)
    check("aligned: facing the target", cam.lockon_aligned(90, c.start_pitch, from, to, c, 3))
    check("aligned: facing away is not aligned", not cam.lockon_aligned(-90, c.start_pitch, from, to, c, 3))
    check("aligned: pitch off is not aligned", not cam.lockon_aligned(90, c.start_pitch + 20, from, to, c, 3))
    check("aligned: yaw across the seam", cam.lockon_aligned(179, c.start_pitch, from, { X = -500, Y = -2, Z = 0 }, c, 3))
    check("aligned: target on top of player", cam.lockon_aligned(0, 0, from, { X = 5, Y = 5, Z = 0 }, c, 3))
    local ay, ap, frames = 0, 0, 0
    local fast = setmetatable({ lockon_speed = c.lockon_speed * 2.5 }, { __index = c })
    while not cam.lockon_aligned(ay, ap, from, to, c, 3) and frames < 1000 do ay, ap = cam.lockon_step(ay, ap, from, to, fast, 1 / 60); frames = frames + 1 end
    check("initial turn reaches the enemy within 1.5 s", frames < 90, frames)
end

-- store
local defaults = store.defaults()
check("defaults enabled", defaults.enabled == true)
local clamped = store.sanitize({ distance = 99999, fov = -5, enabled = "yes", mouse_sens_x = 0 / 0 })
check("clamp max", clamped.distance == config.by_key.distance.max)
check("clamp min", clamped.fov == config.by_key.fov.min)
check("bool fallback", clamped.enabled == true)
check("nan fallback", clamped.mouse_sens_x == config.by_key.mouse_sens_x.default)
local swapped = store.sanitize({ pitch_min = 10, pitch_max = -10 })
check("pitch limits repaired", swapped.pitch_min < swapped.pitch_max)
local text = store.serialise(store.sanitize({ distance = 333, mouse_invert_x = true }))
local parsed = store.parse(text)
check("roundtrip number", parsed and parsed.distance == 333)
check("roundtrip bool", parsed and parsed.mouse_invert_x == true)
check("parse rejects code", store.parse("os.execute('x')") == nil)
check("parse rejects garbage", store.parse("this is not lua") == nil)

-- settings model (F1 screen logic)
do
    local model = require("settings_model")
    local rows = model.rows()
    local entries, headers, actions, hidden_listed = 0, 0, 0, 0
    for _, r in ipairs(rows) do
        if r.entry then entries = entries + 1; if r.entry.hidden then hidden_listed = hidden_listed + 1 end
        elseif r.header then headers = headers + 1
        elseif r.action then actions = actions + 1 end
    end
    local visible = 0
    for _, e in ipairs(config.entries) do if not e.hidden then visible = visible + 1 end end
    check("model lists every visible setting once", entries == visible, entries)
    check("hidden settings are not listed", hidden_listed == 0)
    check("camera position items are hidden", config.by_key.distance.hidden and config.by_key.height.hidden and config.by_key.shoulder.hidden
        and config.by_key.wall_check.hidden and config.by_key.cut_blend.hidden)
    check("model has 3 headers and 1 action", headers == 3 and actions == 1, headers .. "/" .. actions)
    do -- camera block comes first, in the requested order
        local want = { "camera", "enabled", "camera_screen", "auto_recenter", "auto_recenter_speed", "pad_look" }
        local got = {}
        for i = 1, #want do local r = rows[i]; got[i] = r.header or (r.entry and r.entry.key) or r.action end
        check("camera group order", table.concat(got, ",") == table.concat(want, ","), table.concat(got, ","))
    end
    check("combat settings are hidden", config.by_key.lockon_camera.hidden and config.by_key.lockon_speed.hidden and config.by_key.dpad_shortcuts.hidden and config.by_key.keep_when_grabbed.hidden)
    check("model first row is a header", rows[1].header == "camera")
    local ok_labels = true
    for _, e in ipairs(config.entries) do if not (e.ja and e.en and e.group and config.groups[e.group]) then ok_labels = false end end
    check("every setting has ja/en label and group", ok_labels)
    check("fov and look limits are not listed", config.by_key.fov.hidden and config.by_key.start_pitch.hidden and config.by_key.pitch_min.hidden and config.by_key.pitch_max.hidden)
    check("no manual language override", config.by_key.ui_language == nil and config.by_key.ui_japanese == nil)
    check("action label", model.action_label("camera_screen", true) ~= model.action_label("camera_screen", false))
    check("action label has no key hint", model.action_label("camera_screen", true) == "カメラ位置変更画面を開く"
        and model.action_label("camera_screen", false) == "Open camera position screen")
    -- footer help: confirm sits just left of close, ESC is upper case, and each line fits the 920 px panel interior
    for _, ja in ipairs({ true, false }) do
        local pad_help, key_help = model.footer_help(ja)
        check("footer pad: confirm before close (" .. tostring(ja) .. ")", pad_help:find(ja and "Aで決定、Bで閉じる" or "A: confirm, B: close", 1, true) ~= nil)
        check("footer keys: confirm before close (" .. tostring(ja) .. ")", key_help:find(ja and "Enterで決定、ESCかF1で閉じる" or "Enter: confirm, ESC or F1: close", 1, true) ~= nil)
        check("footer has no mixed-case Esc", not key_help:find("Esc", 1, true) and not pad_help:find("Esc", 1, true))
        check("footer lines fit at size 13", model.text_width(pad_help, 13) <= 920 and model.text_width(key_help, 13) <= 920,
            model.text_width(pad_help, 13) .. "/" .. model.text_width(key_help, 13))
    end
    -- the main screen shows every row at once: 4 headings x 30 + 13 rows x 32 px must leave room in a 1080 px screen
    do
        local heads, others = 0, 0
        for _, r in ipairs(rows) do if r.header then heads = heads + 1 else others = others + 1 end end
        local panel_h = 62 + heads * 30 + others * 32 + 10 + 112
        check("all rows fit the panel without scrolling", panel_h <= 800, panel_h)
    end
    check("fit_size keeps a fitting label", model.fit_size("abc", 13, 100) == 13)
    check("fit_size shrinks a long label", model.fit_size(string.rep("あ", 40), 17, 400) < 17 and model.text_width(string.rep("あ", 40), model.fit_size(string.rep("あ", 40), 17, 400)) <= 400)
    check("fit_size never goes below the minimum", model.fit_size(string.rep("あ", 400), 17, 100, 9) == 9)
    local dist = config.by_key.distance
    check("step number", model.step(dist, 220, 1, false) == 230)
    check("step big", model.step(dist, 220, 1, true) == 320)
    check("step clamps max", model.step(dist, 595, 1, true) == dist.max)
    check("step clamps min", model.step(dist, 65, -1, true) == dist.min)
    local sens = config.by_key.mouse_sens_x
    local v = 0.1
    for _ = 1, 3 do v = model.step(sens, v, 1, false) end
    check("no float drift", v == 0.13, v)
    check("toggle bool", model.step(config.by_key.enabled, true, 1, false) == false)
    check("format bool ja", model.format_value(config.by_key.enabled, true, true) == "オン")
    check("format bool en", model.format_value(config.by_key.enabled, false, false) == "OFF")
    check("format int", model.format_value(dist, 220, true) == "220")
    check("format decimal", model.format_value(sens, 0.15, true) == "0.15")
    local sel = model.first_selectable(rows)
    check("first selectable is an entry", rows[sel].entry ~= nil and sel == 2, sel)
    -- the action row can be selected, and every move lands on an entry or the action
    local walk, seen_action = sel, false
    for _ = 1, #rows * 2 do
        walk = model.move(rows, walk, 1)
        check("move lands on a selectable row", model.selectable(rows[walk]))
        if rows[walk].action then seen_action = true end
    end
    check("walking down reaches the action row", seen_action)
    check("move up wraps to last row", model.move(rows, sel, -1) == #rows)
    check("window keeps first when visible", model.window_start(rows, 5, 13, 1) == 1)
    check("window scrolls down", model.window_start(rows, #rows - 2, 5, 1) == #rows - 6, model.window_start(rows, #rows - 2, 5, 1))
    check("window shows header above selection", model.window_start(rows, 7, 3, 9) == 6, model.window_start(rows, 7, 3, 9))
    check("window clamps at end", model.window_start(rows, #rows, 5, 1) == #rows - 4)
    local s = store.defaults()
    check("pitch_max may reach 0", model.apply(s, "pitch_max", 0) == true)
    check("pitch limits cannot meet", model.apply(s, "pitch_min", 0) == false and s.pitch_min == -60)
    check("apply normal value", model.apply(s, "distance", 300) == true and s.distance == 300)
    check("hidden defaults stay sane", store.defaults().wall_check == true and store.defaults().cut_blend == 0)
end

-- recenter
do
    local y, p2 = 170, 20
    for _ = 1, 120 do y, p2 = cam.recenter_step(y, p2, -170, -12, 10, 10, 1 / 60) end
    check("recenter goes the short way round the seam", math.abs(cam.angle_diff(y, -170)) < 1.5, y)
    check("recenter pitch settles", near(p2, -12, 1.5), p2)
    local y2, p3 = cam.recenter_step(0, 30, 90, -12, 0.5, nil, 0.1)
    check("slow turn moves yaw only", y2 > 0 and y2 < 90 and p3 == 30, y2)
    local y3 = 0
    for _ = 1, 60 * 20 do y3 = cam.recenter_step(y3, 0, 90, -12, 0.5, nil, 1 / 60) end
    check("slow turn arrives", near(y3, 90, 0.5), y3)
    check("auto recenter is configurable", store.defaults().auto_recenter == false and store.defaults().auto_recenter_speed == 1)
end

print(string.format("%d checks, %d failures", count, failures))
return failures
