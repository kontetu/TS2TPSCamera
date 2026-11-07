-- Pure camera math (degrees). No game access, so tests can load it.
local M = {}

function M.clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- Wrap an angle into (-180, 180].
function M.wrap180(a)
    a = a % 360
    if a > 180 then a = a - 360 end
    return a
end

-- Shortest signed rotation that takes angle a to angle b.
function M.angle_diff(a, b)
    return M.wrap180(b - a)
end

-- Move `current` toward `target` by at most max_step (shortest way round).
function M.step_angle(current, target, max_step)
    local d = M.angle_diff(current, target)
    if math.abs(d) <= max_step then return M.wrap180(target) end
    return M.wrap180(current + (d > 0 and max_step or -max_step))
end

-- Exponential smoothing toward target; speed in 1/s. Frame-rate independent.
function M.damp_angle(current, target, speed, dt)
    if speed <= 0 or dt <= 0 then return M.wrap180(current) end
    local t = 1 - math.exp(-speed * dt)
    return M.wrap180(current + M.angle_diff(current, target) * t)
end

-- Remove the dead zone and rescale so the output still reaches +/-1.
function M.deadzone(v, dz)
    local a = math.abs(v)
    if a <= dz then return 0 end
    local scaled = (a - dz) / (1 - dz)
    return v < 0 and -scaled or scaled
end

-- Apply one frame of look input.
--   input: mx,my = mouse counts this frame (my > 0 = mouse moved up),
--          rx,ry = right stick (-1..1, ry > 0 = pushed up)
--   cfg:   the settings table. Pitch > 0 looks up, yaw > 0 turns right.
function M.apply_look(yaw, pitch, input, cfg, dt)
    local dyaw, dpitch = 0, 0
    if cfg.use_mouse then
        local mx = (input.mx or 0) * cfg.mouse_sens_x
        local my = (input.my or 0) * cfg.mouse_sens_y
        if cfg.mouse_invert_x then mx = -mx end
        if cfg.mouse_invert_y then my = -my end
        dyaw = dyaw + mx
        dpitch = dpitch + my
    end
    if cfg.use_pad then
        local rx = M.deadzone(input.rx or 0, cfg.pad_deadzone)
        local ry = M.deadzone(input.ry or 0, cfg.pad_deadzone)
        local pad_yaw = rx * cfg.pad_sens_x * dt
        -- the game's right-stick Y arrives opposite to the mouse here: flip it so "up looks up" by default
        local pad_pitch = -ry * cfg.pad_sens_y * dt
        if cfg.pad_look_invert_x then pad_yaw = -pad_yaw end
        if cfg.pad_look_invert_y then pad_pitch = -pad_pitch end
        dyaw = dyaw + pad_yaw
        dpitch = dpitch + pad_pitch
    end
    return M.wrap180(yaw + dyaw), M.clamp(pitch + dpitch, cfg.pitch_min, cfg.pitch_max)
end

-- Yaw (degrees) that points from `from` toward `to` ({X=,Y=}); UE yaw 0 = +X, 90 = +Y.
function M.yaw_to_target(from, to)
    return math.deg(math.atan(to.Y - from.Y, to.X - from.X))
end

-- Pitch (degrees, + = up) from `from` to `to` ({X=,Y=,Z=}).
function M.pitch_to_target(from, to)
    local dx, dy, dz = to.X - from.X, to.Y - from.Y, to.Z - from.Z
    return math.deg(math.atan(dz, math.sqrt(dx * dx + dy * dy)))
end

-- One frame of lock-on camera. `from` = player position, `to` = target position ({X,Y,Z}).
-- Eases yaw/pitch toward "look from behind the player at the target". Returns nil when the
-- target is too close to give a stable direction (caller keeps free look for that frame).
function M.lockon_step(yaw, pitch, from, to, cfg, dt)
    local dx, dy = to.X - from.X, to.Y - from.Y
    if dx * dx + dy * dy < 30 * 30 then return nil end
    local want_yaw = M.yaw_to_target(from, to)
    -- keep the default look-down angle and add the target's elevation on top of it
    local want_pitch = M.clamp(cfg.start_pitch + M.pitch_to_target(from, to), cfg.pitch_min, cfg.pitch_max)
    local new_yaw = M.damp_angle(yaw, want_yaw, cfg.lockon_speed, dt)
    local new_pitch = pitch + (want_pitch - pitch) * (1 - math.exp(-cfg.lockon_speed * dt))
    return new_yaw, M.clamp(new_pitch, cfg.pitch_min, cfg.pitch_max)
end

-- True when yaw/pitch already look at the target from behind the player (within tol degrees), or when the
-- target is too close to give a direction (nothing to turn to).
function M.lockon_aligned(yaw, pitch, from, to, cfg, tol)
    local dx, dy = to.X - from.X, to.Y - from.Y
    if dx * dx + dy * dy < 30 * 30 then return true end
    local want_yaw = M.yaw_to_target(from, to)
    local want_pitch = M.clamp(cfg.start_pitch + M.pitch_to_target(from, to), cfg.pitch_min, cfg.pitch_max)
    return math.abs(M.angle_diff(yaw, want_yaw)) <= tol and math.abs(want_pitch - pitch) <= tol
end

-- Turn the camera toward "behind the character" (yaw = the character's facing, pitch = the default look-down angle).
-- speed in 1/s (exponential). pitch_speed nil = leave the pitch alone (used by the slow automatic turn while walking).
-- Returns new yaw, new pitch.
function M.recenter_step(yaw, pitch, face_yaw, rest_pitch, speed, pitch_speed, dt)
    local new_yaw = M.damp_angle(yaw, face_yaw, speed, dt)
    local new_pitch = pitch
    if pitch_speed and pitch_speed > 0 and dt > 0 then
        new_pitch = pitch + (rest_pitch - pitch) * (1 - math.exp(-pitch_speed * dt))
    end
    return new_yaw, new_pitch
end

return M
