-- TS2TPSCamera: third-person camera for Tormented Souls 2 (UE4SS Lua mod).
--
-- How it works (verified by the TS2Probe runs, see research/PHASE0-NOTES-ja.md):
--  * The game's fixed cameras are plain level-placed CameraActors, switched by the player
--    controller with SetViewTargetWithBlend(CameraActor, 0). We swap that target for the
--    pawn itself, so the pawn's own SpringArm + camera ("CameraBoom"/"FollowCamera") is used.
--  * Mouse / right stick turn the controller's ControlRotation, which the boom follows.
--  * Left-stick movement uses the pawn's NorthCamera (and "Current/Last Camera Rotator"),
--    which the game sets to the fixed camera's rotation at every cut. We overwrite those with
--    the TPS camera's yaw every tick (pre-hook of the pawn's ReceiveTick).
--  * Anything that is not a plain gameplay CameraActor (cinematics, puzzle cameras, POI ...)
--    is left alone, and the original camera is restored when the TPS stops being valid.
-- F1 opens the settings screen (ui.lua); every setting lives in config.lua.
-- The right stick belongs to the camera: its weapon shortcut (AxisHorizontal/AxisVertical on the
-- pawn) is blocked, and the D-pad picks the shortcut instead (it no longer does tank movement).
local VERSION = "0.9.1" -- keep in step with dist/CHANGELOG.md and Build-Release.ps1
local PREFIX = "[TS2TPS] "
local function log(message) print(PREFIX .. tostring(message) .. "\n") end

local source = debug.getinfo(1, "S").source:gsub("^@", "")
local scripts_dir = source:match("^(.*[/\\])") or "./"
local mod_dir = scripts_dir:match("^(.*[/\\])Scripts[/\\]$") or scripts_dir
local settings_path = mod_dir .. "settings_values.lua"

local config = require("config")
local cam_math = require("camera_math")
local store = require("store")

local settings = store.load(settings_path)

------------------------------------------------------------------ helpers
local function try(fn, ...)
    local ok, result = pcall(fn, ...)
    if ok then return result end
    return nil
end

local function valid(object)
    if object == nil then return false end
    local ok, result = pcall(function() return object:IsValid() end)
    return ok and result == true
end

local function full_name(object)
    if not valid(object) then return "<nil>" end
    return try(function() return object:GetFullName() end) or "<?>"
end

local function same_object(a, b)
    if not valid(a) or not valid(b) then return false end
    local ok, result = pcall(function() return a:GetAddress() == b:GetAddress() end)
    if ok then return result end
    return full_name(a) == full_name(b)
end

local function num(value)
    if type(value) == "number" then return value end
    return nil
end

-- FRotator.Pitch reads back as nil on this build while .Yaw works; the lower-case key works.
-- Assign every spelling, each in its own pcall, so one failing key cannot skip the others.
local function assign_fields(struct, fields)
    for k, v in pairs(fields) do
        pcall(function() struct[k] = v end)
        if k == "Pitch" then pcall(function() struct.pitch = v end) end
    end
end

-- Set a struct property field by field (in place); also try assigning a table.
local function set_struct(object, property, fields)
    local ok = pcall(function() assign_fields(object[property], fields) end)
    if not ok then ok = pcall(function() object[property] = fields end) end
    return ok
end

local function rot_pitch(r)
    if r == nil then return nil end
    return num(try(function() return r.Pitch end)) or num(try(function() return r.pitch end))
end

local function set_control_rotation(pc, pitch, yaw)
    -- table first (works for yaw), then an in-place edit of the real struct (also sets pitch)
    pcall(function() pc:SetControlRotation({ Pitch = pitch, pitch = pitch, Yaw = yaw, Roll = 0 }) end)
    pcall(function()
        local r = pc:GetControlRotation()
        assign_fields(r, { Pitch = pitch, Yaw = yaw, Roll = 0 })
        pc:SetControlRotation(r)
    end)
end

local function read_yaw(object, property)
    return num(try(function() return object[property].Yaw end))
end

------------------------------------------------------------------ state
local S = {
    engaged = false,
    yaw = 0, pitch = -12,
    last_fixed = nil,      -- last plain gameplay CameraActor the game wanted
    saved = nil,           -- original boom/camera/pawn values, restored on disengage
    self_call = false,     -- true while we call SetViewTargetWithBlend ourselves
    bad_time = 0,          -- seconds the "gameplay" test has been false while engaged
    last_clock = nil,
    written_yaw = nil, rewrites = 0, ticks = 0, last_diag = 0,
    verify_logs = 0,
    swaps = 0,
    mouse_x = nil, mouse_y = nil, key_x = nil, key_y = nil,
}
local screen = nil -- the F1 settings screen (ui.lua), created at the end of this file

local function save_settings() store.save(settings_path, settings) end

------------------------------------------------------------------ game access
local cached_pc = nil
local function local_pc()
    if valid(cached_pc) then return cached_pc end
    cached_pc = nil
    for _, pc in ipairs(FindAllOf("PlayerController") or {}) do
        if valid(pc) and try(function() return pc:IsLocalPlayerController() end) then
            cached_pc = pc
            return pc
        end
    end
    return nil
end

local function pawn_of(pc)
    local pawn = try(function() return pc:K2_GetPawn() end)
    if valid(pawn) then return pawn end
    pawn = try(function() return pc.Pawn end)
    if valid(pawn) then return pawn end
    return nil
end

local function is_plain_gameplay_camera(actor)
    if not valid(actor) then return false end
    local class_name = try(function() return actor:GetClass():GetFullName() end) or ""
    if class_name ~= "Class /Script/Engine.CameraActor" then return false end
    local name = full_name(actor)
    if name:find("/Game/Cinematics/", 1, true) or name:find("MovieScene", 1, true) then return false end
    return true
end

local function game_paused(pc)
    return try(function()
        return StaticFindObject("/Script/Engine.Default__GameplayStatics"):IsGamePaused(pc)
    end) == true
end

local function is_grabbed(pawn)
    return try(function() return pawn.BPC_PL_DamageSystem.isbeenGrabbed end) == true
end

-- On a ladder the climb is scripted (input is disabled), and the game cuts to the room camera.
-- The climb system component holds CurrentLadder for the whole climb; the pawn's IsClimbing is a second signal.
local function is_climbing(pawn)
    if not settings.keep_on_ladder or not valid(pawn) then return false end
    if try(function() return pawn.IsClimbing end) == true then return true end
    return valid(try(function() return pawn.ClimbSystemComponent.CurrentLadder end))
end

-- Pushing / pulling an object (a cart ...): the push controls belong to the game, the camera stays free.
local function is_pushing(pawn)
    if not valid(pawn) then return false end
    if try(function() return pawn.IsPushingObject end) == true then return true end
    -- the push component holds CurrentPushable for the whole push (its IsPushingObject() is valid(CurrentPushable))
    return valid(try(function() return pawn.PushSystemComponent.CurrentPushable end))
end

-- Normal play = the pawn exists and the game has not taken input away from it.
-- Being grabbed by an enemy or climbing a ladder disables input too, but the TPS view is kept then.
local function gameplay_ok(pawn)
    if not valid(pawn) then return false end
    if try(function() return pawn.isInputDisabled end) ~= true then return true end
    return (settings.keep_when_grabbed and is_grabbed(pawn)) or is_climbing(pawn) or is_pushing(pawn)
end

-- Puzzles, QTEs, cranks and in-game cinematics keep the game's own camera. The pawn carries flags
-- for them; the first one that is true names the reason (nil = ordinary play).
local SPECIAL_FLAGS = { "isSolvingPuzzle", "isInteractingWithPuzzleComp", "isInteractingWithChildPuzzleComp", "OnCinematic", "QTEnabled", "bIsInteractingWithCrankLogic" }
-- (OnCinematic reads back as an object on this build, so it never counts as true.)
-- A puzzle keeps CurrentPuzzle / bIsInsideInteraction set for its whole duration, while
-- isSolvingPuzzle and isInputDisabled flicker between steps (seen in the log).
-- The dimension mirror (BP_DimensionMirror, built as a puzzle) leaves isInteractingWithPuzzleComp set after the
-- crossing, with no CurrentPuzzle and the controls back: the player walks freely, so the flag is stale. The
-- puzzle-component flags therefore count only while a puzzle is really running; if the game does take the
-- camera for a puzzle, the view-target check hands the camera back anyway.
local PUZZLE_COMP_FLAGS = { isInteractingWithPuzzleComp = true, isInteractingWithChildPuzzleComp = true }

local function puzzle_running(pawn)
    return valid(try(function() return pawn.CurrentPuzzle end))
        or try(function() return pawn.bIsInsideInteraction end) == true
        or try(function() return pawn.isSolvingPuzzle end) == true
end

local function special_state(pawn)
    -- the struggle QTE while an enemy holds the player keeps the TPS view (keep_when_grabbed)
    local grabbed_recently = false
    if settings.keep_when_grabbed then
        if is_grabbed(pawn) then S.last_grab_clock = os.clock() end
        grabbed_recently = os.clock() - (S.last_grab_clock or -100) < 1.5
    end
    local stale = nil
    for _, flag in ipairs(SPECIAL_FLAGS) do
        if try(function() return pawn[flag] end) == true and not (flag == "QTEnabled" and grabbed_recently) then
            if not PUZZLE_COMP_FLAGS[flag] or puzzle_running(pawn) then return flag end
            stale = stale or flag
        end
    end
    if stale ~= S.stale_flag then
        S.stale_flag = stale
        if stale then
            log("ignoring " .. stale .. ": no puzzle is running (CurrentPuzzle=nil, bIsInsideInteraction=false, isSolvingPuzzle=false)")
        end
    end
    if valid(try(function() return pawn.CurrentPuzzle end)) then return "CurrentPuzzle" end
    if try(function() return pawn.bIsInsideInteraction end) == true then return "bIsInsideInteraction" end
    return nil
end

-- After a point of interest (eye mark), a puzzle or the like ends, the game gives the fixed room camera back
-- ("returning"). Its flags stay set for about a second after that, so they are ignored (up to 4 s) while our
-- own camera is taking the view over again; they end the grace as soon as they are all clear.
local function effective_special(pawn)
    local raw = special_state(pawn)
    if S.returning then
        if raw == nil or os.clock() >= (S.returning_until or 0) then
            S.returning = nil
        else
            return nil, raw
        end
    end
    return raw, raw
end

local function special_flag_dump(pawn)
    local parts = {}
    for _, flag in ipairs(SPECIAL_FLAGS) do parts[#parts + 1] = flag .. "=" .. tostring(try(function() return pawn[flag] end)) end
    parts[#parts + 1] = "CurrentPuzzle=" .. (valid(try(function() return pawn.CurrentPuzzle end)) and (full_name(pawn.CurrentPuzzle):match("[^%.:]+$") or "?") or "nil")
    parts[#parts + 1] = "bIsInsideInteraction=" .. tostring(try(function() return pawn.bIsInsideInteraction end))
    parts[#parts + 1] = "isInputDisabled=" .. tostring(try(function() return pawn.isInputDisabled end))
    return table.concat(parts, " ")
end

------------------------------------------------------------------ camera setup
local function boom_and_camera(pawn)
    local boom = try(function() return pawn.CameraBoom end)
    local cam = try(function() return pawn.FollowCamera end)
    if not valid(boom) or not valid(cam) then return nil, nil end
    return boom, cam
end

local function save_originals(pawn, boom, cam)
    if S.saved then return end
    local saved = {
        arm = try(function() return boom.TargetArmLength end),
        use_control = try(function() return boom.bUsePawnControlRotation end),
        collision = try(function() return boom.bDoCollisionTest end),
        inherit_pitch = try(function() return boom.bInheritPitch end),
        inherit_yaw = try(function() return boom.bInheritYaw end),
        inherit_roll = try(function() return boom.bInheritRoll end),
        lag = try(function() return boom.bEnableCameraLag end),
        rot_lag = try(function() return boom.bEnableCameraRotationLag end),
        fov = try(function() return cam.FieldOfView end),
        ctrl_yaw = try(function() return pawn.bUseControllerRotationYaw end),
        ctrl_pitch = try(function() return pawn.bUseControllerRotationPitch end),
        socket = { X = try(function() return boom.SocketOffset.X end), Y = try(function() return boom.SocketOffset.Y end), Z = try(function() return boom.SocketOffset.Z end) },
        target = { X = try(function() return boom.TargetOffset.X end), Y = try(function() return boom.TargetOffset.Y end), Z = try(function() return boom.TargetOffset.Z end) },
    }
    local movement = try(function() return pawn.CharacterMovement end)
    if valid(movement) then
        saved.orient = try(function() return movement.bOrientRotationToMovement end)
        saved.desired = try(function() return movement.bUseControllerDesiredRotation end)
    end
    S.saved = saved
    log(string.format("originals: arm=%s useControl=%s inheritP/Y/R=%s/%s/%s collision=%s fov=%s pawn.ctrlYaw=%s ctrlPitch=%s orientToMove=%s desiredRot=%s",
        tostring(saved.arm), tostring(saved.use_control), tostring(saved.inherit_pitch), tostring(saved.inherit_yaw), tostring(saved.inherit_roll), tostring(saved.collision), tostring(saved.fov),
        tostring(saved.ctrl_yaw), tostring(saved.ctrl_pitch), tostring(saved.orient), tostring(saved.desired)))
end

local function apply_camera_settings(pawn)
    local boom, cam = boom_and_camera(pawn)
    if not boom then return false end
    save_originals(pawn, boom, cam)
    S.arm = nil
    pcall(function() boom.TargetArmLength = settings.distance end)
    pcall(function() boom.bUsePawnControlRotation = true end)
    -- a fixed-camera game may have switched these off, which would freeze up/down look
    pcall(function() boom.bInheritPitch = true end)
    pcall(function() boom.bInheritYaw = true end)
    pcall(function() boom.bInheritRoll = true end)
    pcall(function() boom.bDoCollisionTest = settings.wall_check end)
    pcall(function() boom.bEnableCameraLag = false end)
    pcall(function() boom.bEnableCameraRotationLag = false end)
    set_struct(boom, "TargetOffset", { X = 0, Y = 0, Z = settings.height })
    set_struct(boom, "SocketOffset", { X = 0, Y = settings.shoulder, Z = 0 })
    pcall(function() cam.FieldOfView = settings.fov end)
    -- the pawn must not be turned by the controller rotation we are about to drive
    pcall(function() pawn.bUseControllerRotationYaw = false end)
    pcall(function() pawn.bUseControllerRotationPitch = false end)
    local movement = try(function() return pawn.CharacterMovement end)
    if valid(movement) then
        pcall(function() movement.bUseControllerDesiredRotation = false end)
    end
    return true
end

-- Darkness effect (screen flicker / lines while standing in the dark without a light).
-- BPC_DarknessSystem.LoadMaterialToCameras puts the character's DarknessSystem_Mat (a post-process material)
-- into the PostProcessSettings of every BP_RailCamera's camera, then animates its "Alpha" / "Lines"
-- parameters. Our TPS view looks through the pawn's FollowCamera, which never gets that material, so the
-- effect was missing. Add the same material instance to FollowCamera (weight 1); while it is idle the game
-- keeps Alpha at 0, so it only shows when the game turns it on.
local function blendable_index(cam, mat)
    local found, count = nil, 0
    pcall(function()
        local arr = cam.PostProcessSettings.WeightedBlendables.Array
        count = arr:GetArrayNum()
        arr:ForEach(function(index, element)
            local item = element:get()
            if same_object(try(function() return item.Object end), mat) then found = index end
        end)
    end)
    return found, count
end

local function ensure_darkness_effect(pawn)
    local now = os.clock()
    if now < (S.dark_next or 0) then return end
    S.dark_next = now + 1.0
    local mat = try(function() return pawn.DarknessSystem_Mat end)
    local cam = try(function() return pawn.FollowCamera end)
    if not valid(mat) or not valid(cam) then return end
    if blendable_index(cam, mat) then return end
    if S.dark_failed and same_object(S.dark_failed, mat) then return end

    local _, before = blendable_index(cam, mat)
    local tried = {}
    local attempts = {
        { "AddOrUpdateBlendable", function() cam:AddOrUpdateBlendable(mat, 1.0) end },
        { "array append", function()
            local arr = cam.PostProcessSettings.WeightedBlendables.Array
            arr[arr:GetArrayNum() + 1] = { Weight = 1.0, Object = mat }
        end },
        { "struct assign", function()
            cam.PostProcessSettings.WeightedBlendables = { Array = { { Weight = 1.0, Object = mat } } }
        end },
    }
    for _, attempt in ipairs(attempts) do
        local ok, err = pcall(attempt[2])
        local index, count = blendable_index(cam, mat)
        tried[#tried + 1] = attempt[1] .. "=" .. (index and "ok" or (ok and "no effect" or ("error " .. tostring(err))))
        if index then
            log(string.format("darkness effect added to the TPS camera (%s; blendables %d -> %d, PostProcessBlendWeight=%s)",
                attempt[1], before, count, tostring(try(function() return cam.PostProcessBlendWeight end))))
            S.dark_failed = nil
            return
        end
    end
    S.dark_failed = mat
    log("darkness effect could NOT be added to the TPS camera: " .. table.concat(tried, ", "))
end

local function restore_originals(pawn)
    local saved = S.saved
    if not saved or not valid(pawn) then return end
    local boom, cam = boom_and_camera(pawn)
    if boom then
        if saved.arm then pcall(function() boom.TargetArmLength = saved.arm end) end
        if saved.use_control ~= nil then pcall(function() boom.bUsePawnControlRotation = saved.use_control end) end
        if saved.collision ~= nil then pcall(function() boom.bDoCollisionTest = saved.collision end) end
        if saved.inherit_pitch ~= nil then pcall(function() boom.bInheritPitch = saved.inherit_pitch end) end
        if saved.inherit_yaw ~= nil then pcall(function() boom.bInheritYaw = saved.inherit_yaw end) end
        if saved.inherit_roll ~= nil then pcall(function() boom.bInheritRoll = saved.inherit_roll end) end
        if saved.lag ~= nil then pcall(function() boom.bEnableCameraLag = saved.lag end) end
        if saved.rot_lag ~= nil then pcall(function() boom.bEnableCameraRotationLag = saved.rot_lag end) end
        if saved.target.Z then set_struct(boom, "TargetOffset", saved.target) end
        if saved.socket.Y then set_struct(boom, "SocketOffset", saved.socket) end
    end
    if cam and saved.fov then pcall(function() cam.FieldOfView = saved.fov end) end
    if saved.ctrl_yaw ~= nil then pcall(function() pawn.bUseControllerRotationYaw = saved.ctrl_yaw end) end
    if saved.ctrl_pitch ~= nil then pcall(function() pawn.bUseControllerRotationPitch = saved.ctrl_pitch end) end
    local movement = try(function() return pawn.CharacterMovement end)
    if valid(movement) and saved.desired ~= nil then pcall(function() movement.bUseControllerDesiredRotation = saved.desired end) end
    S.saved = nil
end

-- A fixed-camera game may clamp the controller's pitch to ~0 (PlayerCameraManager.ViewPitchMin/Max),
-- which would flatten up/down look every frame. Widen the limits while the TPS camera is on.
local VIEW_LIMITS = { "ViewPitchMin", "ViewPitchMax", "ViewYawMin", "ViewYawMax" }

local function save_view_limits(cm)
    if S.saved_view or not valid(cm) then return end
    local saved = {}
    for _, name in ipairs(VIEW_LIMITS) do saved[name] = num(try(function() return cm[name] end)) end
    S.saved_view = saved
    log(string.format("camera manager limits: pitch %s..%s yaw %s..%s", tostring(saved.ViewPitchMin), tostring(saved.ViewPitchMax), tostring(saved.ViewYawMin), tostring(saved.ViewYawMax)))
end

local function widen_view_limits(cm)
    if not valid(cm) then return end
    pcall(function() cm.ViewPitchMin = -89.0 end)
    pcall(function() cm.ViewPitchMax = 89.0 end)
    pcall(function() cm.ViewYawMin = 0.0 end)
    pcall(function() cm.ViewYawMax = 359.999 end)
end

local function restore_view_limits(cm)
    local saved = S.saved_view
    if not saved or not valid(cm) then return end
    for _, name in ipairs(VIEW_LIMITS) do
        if saved[name] ~= nil then pcall(function() cm[name] = saved[name] end) end
    end
    S.saved_view = nil
end

local function set_view_target(pc, target, blend)
    S.self_call = true
    local ok, err = pcall(function() pc:SetViewTargetWithBlend(target, blend or 0.0, 0, 0.0, false) end)
    S.self_call = false
    if not ok then log("SetViewTargetWithBlend failed: " .. tostring(err)) end
    return ok
end

------------------------------------------------------------------ engage / disengage
local function engage(pc, pawn, set_target, reason)
    if not apply_camera_settings(pawn) then log("engage aborted: pawn has no CameraBoom/FollowCamera") return false end
    save_view_limits(try(function() return pc.PlayerCameraManager end))
    S.arm = nil
    if not S.engaged then
        local pawn_yaw = num(try(function() return pawn:K2_GetActorRotation().Yaw end))
        S.yaw = pawn_yaw or S.yaw
        S.pitch = settings.start_pitch
    end
    if set_target then set_view_target(pc, pawn, settings.cut_blend) end
    S.engaged = true
    S.bad_time = 0
    S.written_yaw = nil
    log(string.format("ENGAGED (%s) yaw=%.1f pitch=%.1f", reason, S.yaw, S.pitch))
    return true
end

local function disengage(pc, pawn, restore_view, reason)
    if not S.engaged then return end
    restore_originals(pawn)
    restore_view_limits(valid(pc) and try(function() return pc.PlayerCameraManager end) or nil)
    S.engaged = false
    S.written_yaw = nil
    -- back to the original controls: nothing of our WASD / D-pad handling may stay behind
    if S.wasd_on then
        S.wasd_on = false
        if valid(pawn) then
            pcall(function() pawn:SetStickXValue(0); pawn:SetStickYValue(0) end)
        end
    end
    S.inject, S.number_until = nil, nil
    S.wheel_check, S.wheel_pending, S.sprinting = nil, 0, nil
    local restored = false
    if restore_view and valid(pc) then
        -- give back whatever camera the game asked for last (a puzzle camera, a room camera ...)
        local back = S.last_fixed
        if valid(S.requested) and not same_object(S.requested, pawn) then back = S.requested end
        if valid(back) then restored = set_view_target(pc, back, 0.0) end
    end
    log(string.format("DISENGAGED (%s) restoredView=%s", reason, tostring(restored)))
end

------------------------------------------------------------------ input
local function key_state(pc, fname)
    return num(try(function() return pc:GetInputAnalogKeyState({ KeyName = fname }) end)) or 0
end

local function read_input(pc)
    if not S.key_x then
        S.key_x, S.key_y = FName("MouseX"), FName("MouseY")
        S.pad_x, S.pad_y = FName("Gamepad_RightX"), FName("Gamepad_RightY")
    end
    return { mx = key_state(pc, S.key_x), my = key_state(pc, S.key_y), rx = key_state(pc, S.pad_x), ry = key_state(pc, S.pad_y) }
end

-- D-pad = weapon shortcut (the game's own shortcut is the right stick direction, which now turns the camera).
-- Pressing a direction feeds the pawn's AxisHorizontal/AxisVertical what the stick would have, for ~0.25 s.
local DPAD = {
    { key = "Gamepad_DPad_Up",    axis = "AxisVertical",   value = -1 },
    { key = "Gamepad_DPad_Down",  axis = "AxisVertical",   value = 1 },
    { key = "Gamepad_DPad_Right", axis = "AxisHorizontal", value = 1 },
    { key = "Gamepad_DPad_Left",  axis = "AxisHorizontal", value = -1 },
}

local function send_axis(pawn, axis, value)
    S.injecting = true
    pcall(function()
        if axis == "AxisVertical" then pawn:AxisVertical(value) else pawn:AxisHorizontal(value) end
    end)
    S.injecting = false
end

local key_names = {}
local function fname(name)
    local value = key_names[name]
    if not value then value = FName(name); key_names[name] = value end
    return value
end

-- Number keys 1-5 are mapped by the game to the same action as the right stick (IA_InGame_Shortcut_Stick):
-- they select a weapon exactly as the original does, so their calls must get through.
local NUMBER_KEYS = { "One", "Two", "Three", "Four", "Five" }
local function number_key_down(pc)
    for _, name in ipairs(NUMBER_KEYS) do
        if key_state(pc, fname(name)) > 0.5 then return true end
    end
    return false
end
local function number_key_window() return S.number_until ~= nil and os.clock() < S.number_until end

-- The D-pad (and W/A/S/D) feed the pawn's tank-movement values dpadX/dpadY; in TPS they must not move the
-- character. Called from the pawn's tick and straight after the controller's D-pad action events.
local function clear_dpad(pawn)
    pcall(function() pawn.dpadX = 0 end)
    pcall(function() pawn.dpadY = 0 end)
end

-- Also take away what drives the walking / turning animation (the animation blueprint reads these).
local TANK_FLAGS = { "MovingF", "MovingB", "MovingR", "MovingL", "isTurningR", "isTurningL" }
local function suppress_tank_state(pawn, where)
    clear_dpad(pawn)
    pcall(function() pawn.characterCurrentSpeed = 0 end)
    for _, name in ipairs(TANK_FLAGS) do pcall(function() pawn[name] = false end) end
    -- movement status (0 idle, 1 walking, 2 running): the walking animation follows it
    local status_before = try(function() return pawn.Status end)
    pcall(function() pawn.Status = 0 end)
    pcall(function() pawn.IsRunningTankMode = false end)
    S.suppress_logs = (S.suppress_logs or 0) + 1
    if S.suppress_logs <= 8 then
        log(string.format("tank state suppressed in %s: Status %s->%s speedVar=%s MovingF=%s isTurningR=%s dpad=(%s,%s)", where,
            tostring(status_before), tostring(try(function() return pawn.Status end)),
            tostring(try(function() return pawn.characterCurrentSpeed end)), tostring(try(function() return pawn.MovingF end)),
            tostring(try(function() return pawn.isTurningR end)), tostring(try(function() return pawn.dpadX end)), tostring(try(function() return pawn.dpadY end))))
    end
end

-- W/A/S/D act like the left stick: camera-relative analog movement. The pawn picks analog movement whenever
-- stickX/stickY are not zero, so those are fed from the keys (the game would only give them tank movement).
local function pad_stick_active(pc)
    local lx, ly = key_state(pc, fname("Gamepad_LeftX")), key_state(pc, fname("Gamepad_LeftY"))
    return lx * lx + ly * ly > 0.04
end

local function set_stick(pawn, x, y)
    local ok = pcall(function() pawn:SetStickXValue(x); pawn:SetStickYValue(y) end)
    if not ok then
        pcall(function() pawn.stickX = x end)
        pcall(function() pawn.stickY = y end)
        if not S.stick_fallback_logged then S.stick_fallback_logged = true; log("SetStickXValue/YValue failed, wrote stickX/stickY directly") end
    end
end

-- Keyboard walk / run. The pawn picks walking or running from how far the stick is pushed, so W/A/S/D at full
-- strength always ran. Now the keys walk (a partial stick value) and run (full value) exactly when the game's own
-- run state is on: Shift is handled by the game as in the fixed camera (IA_Run -> RunTankModePressed /
-- RunTankModeReleased set IsRunningTankMode), and the TPS keys only follow that state.
-- The walk strength sits between the pawn's WalkPercent and RunPercent and corrects itself from the pawn's
-- movement Status (0 idle, 1 walking, 2 running) if the game still runs or does not move.
local function shift_down(pc)
    return key_state(pc, fname("LeftShift")) > 0.5 or key_state(pc, fname("RightShift")) > 0.5
end

-- the game's run state (what Shift does in the fixed camera); Shift held if the flag cannot be read
local function game_wants_run(pc, pawn)
    local flag = try(function() return pawn.IsRunningTankMode end)
    if type(flag) == "boolean" then return flag, "IsRunningTankMode" end
    return shift_down(pc), "Shift held"
end

local function walk_strength(pawn)
    if S.walk_mag then return S.walk_mag end
    local wp = num(try(function() return pawn.WalkPercent end))
    local rp = num(try(function() return pawn.RunPercent end))
    local mag = 0.45
    if wp and rp and wp >= 0 and rp > wp and rp <= 1 then mag = (wp + rp) / 2 end
    S.walk_mag = mag
    log(string.format("keyboard walk strength %.2f (pawn WalkPercent=%s RunPercent=%s WalkVelocity=%s RunVelocity=%s MaxRunVelocity=%s)",
        mag, tostring(wp), tostring(rp), tostring(try(function() return pawn.WalkVelocity end)),
        tostring(try(function() return pawn.RunVelocity end)), tostring(try(function() return pawn.MaxRunVelocity end))))
    return mag
end

-- the game still runs while we walk (Status 2), or nothing moves (Status 0): nudge the walk strength
local function tune_walk(pawn, now)
    local status = num(try(function() return pawn.Status end))
    if status == 2 or status == 0 then
        S.walk_bad_since = S.walk_bad_since or now
        if now - S.walk_bad_since > 0.4 then
            local before = S.walk_mag
            if status == 2 then S.walk_mag = math.max(0.15, S.walk_mag - 0.1) else S.walk_mag = math.min(0.95, S.walk_mag + 0.1) end
            S.walk_bad_since = nil
            if S.walk_mag ~= before then
                log(string.format("keyboard walk strength %.2f -> %.2f (pawn Status=%s while walking)", before, S.walk_mag, tostring(status)))
            end
        end
    else
        S.walk_bad_since = nil
    end
end

local function update_wasd(pc, pawn)
    if not settings.wasd_move then return end
    local input_disabled = try(function() return pawn.isInputDisabled end) == true
    local x = (key_state(pc, fname("D")) > 0.5 and 1 or 0) - (key_state(pc, fname("A")) > 0.5 and 1 or 0)
    local y = (key_state(pc, fname("W")) > 0.5 and 1 or 0) - (key_state(pc, fname("S")) > 0.5 and 1 or 0)
    if input_disabled then x, y = 0, 0 end
    local run, source = game_wants_run(pc, pawn)
    if run ~= S.game_run and (S.run_flag_logs or 0) < 30 then
        S.run_flag_logs = (S.run_flag_logs or 0) + 1
        log(string.format("game run state %s (%s, Shift=%s, moving=%s)", tostring(run), source, tostring(shift_down(pc)), tostring(x ~= 0 or y ~= 0)))
    end
    -- after running, the pawn reports Status 2 for a moment while it slows down: do not tune the walk then
    if S.game_run and not run then S.walk_settle_until = os.clock() + 1.0 end
    S.game_run = run
    if x ~= 0 or y ~= 0 then
        if pad_stick_active(pc) then return end -- the gamepad stick wins
        local length = math.sqrt(x * x + y * y)
        local strength = run and 1.0 or walk_strength(pawn)
        if not run and S.wasd_on and os.clock() > (S.walk_settle_until or 0) then tune_walk(pawn, os.clock()) end
        set_stick(pawn, x / length * strength, y / length * strength)
        if not S.wasd_on then S.wasd_on = true; log("WASD movement (left-stick style) active: walk, run follows the game's run state (Shift)") end
        if run ~= S.sprinting then
            S.sprinting = run
            if (S.sprint_logs or 0) < 20 then
                S.sprint_logs = (S.sprint_logs or 0) + 1
                log(string.format("keyboard %s (strength %.2f, Status=%s)", run and "run" or "walk", strength, tostring(try(function() return pawn.Status end))))
            end
        end
    elseif S.wasd_on then
        S.wasd_on, S.sprinting = false, nil
        if not pad_stick_active(pc) then set_stick(pawn, 0, 0) end
    end
end

-- Mouse wheel: next / previous weapon of the shortcut slots, in the order of the number keys 1-4.
-- pawn.Inventory.Shortcuts holds item ids ("" = empty). Its first entry is the centre slot; then come up,
-- right, down, left (seen in game: key 2 sends right / AxisHorizontal +1, key 3 sends down / AxisVertical +1,
-- the right direction equips Shortcuts[2] and the left one Shortcuts[4]). A slot is selected the same way as
-- with the D-pad. Scrolling down goes 1 -> 2 -> 3 -> 4 -> 1, up goes back; empty slots are skipped.
local WHEEL_SLOTS = {
    { name = "1 (up)",    dpad = 1 },
    { name = "2 (right)", dpad = 3 },
    { name = "3 (down)",  dpad = 2 },
    { name = "4 (left)",  dpad = 4 },
}

-- the weapon ids of the four direction slots (1 up, 2 right, 3 down, 4 left), "" = empty
local function read_slots(pawn)
    local raw = {}
    pcall(function()
        pawn.Inventory.Shortcuts:ForEach(function(index, element)
            local value = element:get()
            raw[index] = (type(value) == "string" and value) or try(function() return value:ToString() end) or ""
        end)
    end)
    local offset = (#raw >= 5) and 1 or 0 -- skip the centre slot
    local slots = {}
    for slot = 1, 4 do slots[slot] = raw[slot + offset] or "" end
    if not S.slots_logged and #raw > 0 then
        S.slots_logged = true
        log("weapon shortcut slots (centre first): " .. table.concat(raw, ",") .. " -> wheel order up,right,down,left = " .. table.concat(slots, ","))
    end
    return slots
end

local function current_weapon_id(pawn)
    local id = try(function() return pawn.BPC_WeaponSystemComponent.CurrentWeapon.weaponID end)
    if id == nil then return nil end
    if type(id) == "string" then return id end
    return try(function() return id:ToString() end)
end

local function wheel_step(pc)
    local function pressed(key)
        return try(function() return pc:WasInputKeyJustPressed({ KeyName = fname(key) }) end) == true
    end
    if pressed("MouseScrollDown") then return 1 end
    if pressed("MouseScrollUp") then return -1 end
    return 0
end

local function update_wheel(pc, pawn, input_disabled)
    local step = wheel_step(pc)
    if step ~= 0 and not input_disabled then
        S.wheel_pending = math.max(-3, math.min(3, (S.wheel_pending or 0) + step))
    end
    local now = os.clock()
    -- after a switch, check that the game equipped what was asked for (logged; equipping takes a moment)
    if S.wheel_check and now >= S.wheel_check.at then
        local check = S.wheel_check
        S.wheel_check = nil
        local now_id = current_weapon_id(pawn) or ""
        if now_id ~= check.id and (S.wheel_miss_logs or 0) < 10 then
            S.wheel_miss_logs = (S.wheel_miss_logs or 0) + 1
            log(string.format("wheel: asked for slot %s (%s), weapon now %s (before %s)", WHEEL_SLOTS[check.slot].name, check.id, now_id, tostring(check.before)))
        end
    end
    if (S.wheel_pending or 0) == 0 or S.inject or S.wheel_check or input_disabled then return end
    local direction = S.wheel_pending > 0 and 1 or -1
    S.wheel_pending = S.wheel_pending - direction
    local slots = read_slots(pawn)
    local now_id = current_weapon_id(pawn)
    local current = 0
    for slot = 1, 4 do if slots[slot] ~= "" and slots[slot] == now_id then current = slot end end
    if current == 0 and direction < 0 then current = 5 end
    local target = nil
    for i = 1, 4 do
        local slot = ((current - 1 + direction * i) % 4) + 1
        if slots[slot] ~= "" and slots[slot] ~= now_id then target = slot break end
    end
    if not target then
        if (S.wheel_empty_logs or 0) < 5 then
            S.wheel_empty_logs = (S.wheel_empty_logs or 0) + 1
            log("wheel: no other weapon in the shortcut slots (" .. table.concat(slots, ",") .. "), current=" .. tostring(now_id))
        end
        S.wheel_pending = 0
        return
    end
    local entry = DPAD[WHEEL_SLOTS[target].dpad]
    S.inject = { axis = entry.axis, value = entry.value, left = 0.25 }
    S.wheel_check = { at = now + 0.9, slot = target, id = slots[target], before = now_id }
    if (S.wheel_logs or 0) < 30 then
        S.wheel_logs = (S.wheel_logs or 0) + 1
        log(string.format("wheel %s: %s -> slot %s (%s) via %s", direction > 0 and "down" or "up",
            current >= 1 and current <= 4 and WHEEL_SLOTS[current].name or tostring(now_id), WHEEL_SLOTS[target].name, slots[target], entry.key))
    end
end

local function update_dpad_shortcuts(pc, pawn, dt)
    -- the D-pad no longer drives tank movement
    local any_dpad = false
    for _, entry in ipairs(DPAD) do if key_state(pc, fname(entry.key)) > 0.5 then any_dpad = true end end
    S.dpad_held = any_dpad
    if any_dpad and not S.wasd_on and not pad_stick_active(pc) then suppress_tank_state(pawn, "tick") else clear_dpad(pawn) end
    -- belt and braces: the right stick must not select a weapon either (number keys excepted)
    if not number_key_window() then
        pcall(function() pawn.RightAxisHorizontal = 0 end)
        pcall(function() pawn.RightAxisVertical = 0 end)
    end
    local input_disabled = try(function() return pawn.isInputDisabled end) == true
    S.dpad_prev = S.dpad_prev or {}
    for index, entry in ipairs(DPAD) do
        entry.fname = entry.fname or FName(entry.key)
        local down = key_state(pc, entry.fname) > 0.5
        if down and not S.dpad_prev[index] and not S.inject and not input_disabled then
            S.inject = { axis = entry.axis, value = entry.value, left = 0.25 }
            log("D-pad shortcut: " .. entry.key)
        end
        S.dpad_prev[index] = down
    end
    update_wheel(pc, pawn, input_disabled)
    if S.inject then
        send_axis(pawn, S.inject.axis, S.inject.value)
        S.inject.left = S.inject.left - dt
        if S.inject.left <= 0 then
            send_axis(pawn, S.inject.axis, 0.0)
            S.inject = nil
        end
    end
end

------------------------------------------------------------------ per-frame update
local function write_basis(pawn, yaw)
    set_struct(pawn, "NorthCamera", { Pitch = 0, Yaw = yaw, Roll = 0 })
    set_struct(pawn, "Current Camera Rotator", { Pitch = 0, Yaw = yaw, Roll = 0 })
    set_struct(pawn, "Last Camera Rotator", { Pitch = 0, Yaw = yaw, Roll = 0 })
    S.written_yaw = yaw
    if S.verify_logs < 4 then
        S.verify_logs = S.verify_logs + 1
        log(string.format("basis write check: wrote yaw=%.1f read NorthCamera=%s Current=%s Last=%s", yaw,
            tostring(read_yaw(pawn, "NorthCamera")), tostring(read_yaw(pawn, "Current Camera Rotator")), tostring(read_yaw(pawn, "Last Camera Rotator"))))
    end
end

------------------------------------------------------------------ lock-on
-- The game's own lock-on is only read, never changed. While the weapon is readied (isAiming)
-- the target is whatever the pawn holds in CurrentTarget / CurrentEnemy.
local TARGET_PROPS = { "CurrentTarget", "CurrentEnemy" }

local function lockon_target(pawn)
    if not try(function() return pawn.isAiming end) then return nil end
    for _, prop in ipairs(TARGET_PROPS) do
        local t = try(function() return pawn[prop] end)
        if valid(t) then return t, prop end
    end
    return nil
end

local function vec3(v)
    if not v then return nil end
    local x, y, z = num(try(function() return v.X end)), num(try(function() return v.Y end)), num(try(function() return v.Z end))
    if x and y and z then return { X = x, Y = y, Z = z } end
    return nil
end

local function lockon_log(pawn, target, prop, on)
    local now = os.clock()
    if on ~= S.lock_logged_state then
        S.lock_logged_state = on
        log(string.format("lock-on camera %s via %s %s", on and "ON" or "OFF", tostring(prop), on and full_name(target):match("[^%.:]+$") or ""))
    end
    if on and now - (S.last_lock_diag or 0) > 1.5 and (S.lock_diag_count or 0) < 40 then
        S.last_lock_diag = now
        S.lock_diag_count = (S.lock_diag_count or 0) + 1
        local parts = {}
        for _, p in ipairs({ "CurrentTarget", "CurrentEnemy", "TargetToWatch" }) do
            parts[#parts + 1] = p .. "=" .. (valid(try(function() return pawn[p] end)) and (full_name(try(function() return pawn[p] end)):match("[^%.:]+$") or "?") or "nil")
        end
        log("lock-on diag: " .. table.concat(parts, " ") .. " yaw=" .. string.format("%.1f", S.yaw) .. " pitch=" .. string.format("%.1f", S.pitch))
    end
end

------------------------------------------------------------------ pad button remap (flashlight)
-- In TPS the right-stick click turns the camera behind the character and the left-stick click switches the
-- flashlight. The game maps IA_InGame_CenterShortcut (flashlight) to the right-stick click and the (unused) debug-menu
-- action to the left-stick click; those two key assignments are swapped around in the mapping contexts and in the
-- live player input while the TPS camera is engaged, and put back when the fixed camera is back.
local REMAPS = {
    { action = "IA_InGame_CenterShortcut", from = "Gamepad_RightThumbstick", to = "Gamepad_LeftThumbstick" },
    { action = "IA_InGame_OpenDebugMenu",  from = "Gamepad_LeftThumbstick",  to = "None" },
}

local function name_of(object)
    if not valid(object) then return "" end
    return try(function() return object:GetFName():ToString() end) or ""
end

-- Walks one TArray<FEnhancedActionKeyMapping>; returns changed count, seen count.
local function remap_array(array, on)
    local changed, seen = 0, 0
    local count = try(function() return #array end) or 0
    for index = 1, count do
        local mapping = try(function() return array[index] end)
        if mapping ~= nil then
            local action = try(function() return name_of(mapping.Action) end) or ""
            local key = try(function() return mapping.Key.KeyName:ToString() end)
            for _, r in ipairs(REMAPS) do
                if action == r.action and key then
                    seen = seen + 1
                    local want = on and r.to or r.from
                    if key ~= want and (key == r.from or key == r.to) then
                        local done = pcall(function() mapping.Key.KeyName = FName(want) end)
                        local now_key = try(function() return mapping.Key.KeyName:ToString() end)
                        if not done or now_key ~= want then
                            pcall(function() mapping.Key = { KeyName = FName(want) } end)
                            now_key = try(function() return mapping.Key.KeyName:ToString() end)
                        end
                        if now_key == want then changed = changed + 1 end
                        S.remap_logs = (S.remap_logs or 0) + 1
                        if S.remap_logs <= 12 then log(string.format("key remap %s: %s -> %s (now %s)", r.action, key, want, tostring(now_key))) end
                    end
                end
            end
        end
    end
    return changed, seen
end

local function apply_remap(on)
    local changed, seen = 0, 0
    for _, ctx in ipairs(FindAllOf("InputMappingContext") or {}) do
        if valid(ctx) and full_name(ctx):find("IMC_InGame", 1, true) then
            local arrays = {}
            local deflt = try(function() return ctx.DefaultKeyMappings.Mappings end)
            if deflt ~= nil then arrays[#arrays + 1] = deflt end
            local legacy = try(function() return ctx.Mappings end)
            if legacy ~= nil then arrays[#arrays + 1] = legacy end
            for _, array in ipairs(arrays) do
                local c, n = remap_array(array, on)
                changed, seen = changed + c, seen + n
            end
        end
    end
    local live = FindFirstOf("EnhancedPlayerInput")
    if valid(live) then
        local array = try(function() return live.EnhancedActionMappings end)
        if array ~= nil then
            local c, n = remap_array(array, on)
            changed, seen = changed + c, seen + n
        end
    end
    return changed, seen
end

local function update_remap(engaged)
    local now = os.clock()
    local want = engaged and settings.enabled and true or false
    -- re-check now and then: the game may rebuild its mappings from the contexts
    if want == S.remap_on and now - (S.remap_check or 0) < 3 then return end
    S.remap_check = now
    local changed, seen = apply_remap(want)
    if want ~= S.remap_on then
        log(string.format("pad button remap %s: changed=%d found=%d", want and "ON (RS = camera reset, LS = flashlight)" or "OFF (original)", changed, seen))
        S.remap_on = want
    end
end

local function update(pawn, dt)
    local pc = local_pc()
    if not valid(pc) then return end
    local player_pawn = pawn_of(pc)
    if player_pawn ~= nil then
        if not same_object(player_pawn, pawn) then return end -- another character ticking
    elseif not full_name(pawn):find("BP_CarolineNew_C", 1, true) then
        return
    end
    S.ticks = S.ticks + 1

    -- A different character / controller than last time = a save was loaded (the level is rebuilt). The new
    -- pawn has the game's own camera boom settings (low, wide FOV), and the old yaw/pitch mean nothing for it:
    -- redo the camera setup on it and start behind the character at the normal pitch.
    if not same_object(S.known_pawn, pawn) or not same_object(S.known_pc, pc) then
        local had = S.known_pawn ~= nil
        S.known_pawn, S.known_pc = pawn, pc
        S.settle_until = os.clock() + 3.5
        S.saved, S.saved_view, S.arm, S.written_yaw = nil, nil, nil, nil
        S.recenter_until, S.lock_id, S.lock_turn_until, S.hold_state, S.climbing = nil, nil, nil, nil, false
        S.walk_mag, S.wheel_check, S.wheel_pending = nil, nil, 0
        S.ready_time = 0
        if S.engaged then
            local py = num(try(function() return pawn:K2_GetActorRotation().Yaw end))
            S.yaw, S.pitch = py or S.yaw, settings.start_pitch
            apply_camera_settings(pawn)
            save_view_limits(try(function() return pc.PlayerCameraManager end))
        end
        log(string.format("new character/controller (%s): camera set up again, engaged=%s yaw=%.1f pitch=%.1f",
            had and "save loaded" or "first", tostring(S.engaged), S.yaw or 0, S.pitch or 0))
    end

    if S.ui_open then
        -- a settings screen is open (time is almost stopped): only the look input still turns the camera,
        -- scaled with real time because the game's delta is ~0 now
        if S.engaged then
            local look_dt = S.real_dt or 0.016
            local look = read_input(pc)
            -- the main screen shows the mouse cursor: moving it to click must not turn the camera
            if screen and screen.cursor_active() then look.mx, look.my = 0, 0 end
            S.yaw, S.pitch = cam_math.apply_look(S.yaw, S.pitch, look, settings, look_dt)
            set_control_rotation(pc, S.pitch, S.yaw)
            S.cmd = { pc = pc, pitch = S.pitch, yaw = S.yaw }
        end
        if screen then screen.frame(pc) end
        return
    end

    local cm = try(function() return pc.PlayerCameraManager end)
    local vt = valid(cm) and try(function() return cm.ViewTarget.Target end) or nil
    local vt_is_pawn = same_object(vt, pawn)

    -- trace every view-target change (and the state around it) to learn how puzzles/menus move the camera
    local vt_name = full_name(vt)
    if vt_name ~= S.last_vt_name and (S.vt_logs or 0) < 300 then
        S.last_vt_name = vt_name
        S.vt_logs = (S.vt_logs or 0) + 1
        log(string.format("view target -> %s (class %s) engaged=%s inputDisabled=%s puzzle=%s",
            vt_name:match("[^%.:]+$") or vt_name, (try(function() return vt:GetClass():GetFullName() end) or "?"):match("[^%.:]+$") or "?",
            tostring(S.engaged), tostring(try(function() return pawn.isInputDisabled end)), tostring(special_state(pawn))))
    end

    if not settings.enabled then
        if S.engaged then disengage(pc, pawn, true, "disabled") end
        return
    end
    if game_paused(pc) then return end

    local special, raw_special = effective_special(pawn)
    if special ~= S.special then
        S.special = special
        log("special state " .. tostring(special) .. (raw_special ~= special and (" (raw " .. tostring(raw_special) .. " ignored: camera returning)") or "") .. " | " .. special_flag_dump(pawn))
    end
    -- Examining an eye-mark object only sets bIsInsideInteraction; the game keeps the room camera (it does not
    -- move the view). Stay on the TPS camera then and just hold it still, instead of flipping to the fixed view.
    -- If the game does take the camera (a point-of-interest camera, a puzzle ...), the branch below hands it over.
    local hold = false
    if special == "bIsInsideInteraction" and S.engaged and (vt_is_pawn or is_plain_gameplay_camera(vt)) then
        hold, special = true, nil
    end
    if special then
        S.ready_time = 0
        if S.engaged then
            -- give the game its own camera back right away (the one it asked for, if we swapped it)
            disengage(pc, pawn, vt_is_pawn, "special state: " .. special)
        end
        return
    end

    local ok = gameplay_ok(pawn)

    if not S.engaged then
        -- engage only after normal play has been stable for a moment: puzzle / cutscene
        -- hand-overs flip the flags back and forth and would flash the TPS view
        if ok then S.ready_time = (S.ready_time or 0) + dt else S.ready_time = 0 end
        if (S.ready_time or 0) < 0.3 then
            local clock_now = os.clock()
            if clock_now - (S.last_wait_log or 0) > 2 and (S.wait_logs or 0) < 60 then
                S.last_wait_log, S.wait_logs = clock_now, (S.wait_logs or 0) + 1
                log(string.format("waiting to engage: ok=%s ready=%.2f inputDisabled=%s vt=%s", tostring(ok), S.ready_time or 0,
                    tostring(try(function() return pawn.isInputDisabled end)), vt_name:match("[^%.:]+$") or "?"))
            end
            return
        end
        if ok and vt_is_pawn then
            engage(pc, pawn, false, "view target is the pawn")
        elseif ok and is_plain_gameplay_camera(vt) then
            S.last_fixed = vt
            engage(pc, pawn, true, "fixed camera " .. full_name(vt):match("[^%.:]+$"))
        end
        if not S.engaged then return end
    else
        if not vt_is_pawn then
            if os.clock() < (S.blend_until or 0) then
                -- the game's own blend toward our pawn camera is still running (the target changes when it ends)
            elseif ok and is_plain_gameplay_camera(vt) then
                S.last_fixed = vt
                set_view_target(pc, pawn, settings.cut_blend)
                S.swaps = S.swaps + 1
            else
                -- the game took the camera (cinematic, puzzle, POI ...): hand everything back
                disengage(pc, pawn, false, "game camera: " .. full_name(vt):match("[^%.:]+$"))
                return
            end
        end
        -- input disabled (inventory, menus, item pick-up ...) while the pawn's camera is the view:
        -- keep the TPS view, just hold it still (no look input) until input comes back
    end
    ensure_darkness_effect(pawn)
    local pushing = is_pushing(pawn)
    if hold ~= S.hold_state then
        S.hold_state = hold
        if hold and (S.hold_logs or 0) < 20 then
            S.hold_logs = (S.hold_logs or 0) + 1
            local pushable = try(function() return pawn.PushSystemComponent.CurrentPushable end)
            log(string.format("holding the TPS view during an interaction: pushing=%s IsPushingObject=%s CurrentPushable=%s IsPushingEnemy=%s",
                tostring(pushing), tostring(try(function() return pawn.IsPushingObject end)),
                valid(pushable) and (full_name(pushable):match("[^%.:]+$") or "?") or "nil", tostring(try(function() return pawn.IsPushingEnemy end))))
        end
    end
    if pushing then hold = false end -- a push does not take the camera: look around freely meanwhile
    local frozen = not ok or hold

    -- did the game rewrite the basis since we wrote it?
    if S.written_yaw then
        local current = read_yaw(pawn, "NorthCamera")
        if current and math.abs(cam_math.angle_diff(current, S.written_yaw)) > 0.5 then S.rewrites = S.rewrites + 1 end
    end

    widen_view_limits(cm)
    local grabbed = is_grabbed(pawn)
    local boom = try(function() return pawn.CameraBoom end)
    if valid(boom) then
        -- same distance as normal play, also while grabbed (the wall check is off then, see below)
        S.arm = settings.distance
        local arm_seen = num(try(function() return boom.TargetArmLength end))
        pcall(function() boom.TargetArmLength = S.arm end)
        pcall(function() boom.bDoCollisionTest = settings.wall_check and not grabbed end)
        S.cmd_arm = S.arm
        S.cmd_collision = settings.wall_check and not grabbed
        if grabbed and os.clock() - (S.last_grab_diag or 0) > 0.5 then
            S.last_grab_diag = os.clock()
            local cam_loc = valid(cm) and try(function() return cm:K2_GetActorLocation() end) or nil
            local pawn_loc = try(function() return pawn:K2_GetActorLocation() end)
            local dist = nil
            if cam_loc and pawn_loc then
                local dx, dy, dz = (num(cam_loc.X) or 0) - (num(pawn_loc.X) or 0), (num(cam_loc.Y) or 0) - (num(pawn_loc.Y) or 0), (num(cam_loc.Z) or 0) - (num(pawn_loc.Z) or 0)
                dist = math.sqrt(dx * dx + dy * dy + dz * dz)
            end
            log(string.format("grab diag: armLeftByGame=%s wroteArm=%.0f camToPawn=%s", tostring(arm_seen), S.arm, dist and string.format("%.0f", dist) or "?"))
        end
    end

    local input = read_input(pc)
    local locked = false
    if frozen then
        locked = true -- hold the current view: no look input, no lock-on while the game owns the input
    elseif settings.lockon_camera then
        local target, prop = lockon_target(pawn)
        lockon_log(pawn, target, prop, target ~= nil)
        if target then
            -- The camera turns to the enemy only at the moment of aiming (and when the lock-on switches to another
            -- enemy); once it faces the enemy the look input is free again.
            local target_id = full_name(target)
            if target_id ~= S.lock_id then
                S.lock_id = target_id
                S.lock_turn_until = os.clock() + 1.5
            end
            if S.lock_turn_until and os.clock() < S.lock_turn_until then
                local from, to = vec3(try(function() return pawn:K2_GetActorLocation() end)), vec3(try(function() return target:K2_GetActorLocation() end))
                if from and to then
                    local fast = setmetatable({ lockon_speed = settings.lockon_speed * 2.5 }, { __index = settings })
                    local ny, np = cam_math.lockon_step(S.yaw, S.pitch, from, to, fast, dt)
                    if ny then S.yaw, S.pitch, locked = ny, np, true end
                    if cam_math.lockon_aligned(S.yaw, S.pitch, from, to, settings, 3) then S.lock_turn_until = nil end
                else
                    S.lock_turn_until = nil
                end
            else
                S.lock_turn_until = nil
            end
        else
            S.lock_id, S.lock_turn_until = nil, nil
        end
    end
    if not locked then
        local now = os.clock()
        local look_active = math.abs(input.mx or 0) + math.abs(input.my or 0) > 0
            or math.abs(cam_math.deadzone(input.rx or 0, settings.pad_deadzone)) + math.abs(cam_math.deadzone(input.ry or 0, settings.pad_deadzone)) > 0
        if look_active then S.last_look = now; S.recenter_until = nil; S.settle_until = nil end
        -- just after a load the game still moves / turns the character into the saved spot: keep the camera
        -- behind it (normal pitch) until the player touches the look input or a few seconds have passed
        if S.settle_until and now < S.settle_until then
            local velocity = try(function() return pawn:GetVelocity() end)
            local vx, vy = num(try(function() return velocity.X end)) or 0, num(try(function() return velocity.Y end)) or 0
            if vx * vx + vy * vy > 60 * 60 then
                S.settle_until = nil -- the player is walking: from here the camera is theirs
            else
                local settle_yaw = num(try(function() return pawn:K2_GetActorRotation().Yaw end))
                if settle_yaw then S.yaw, S.pitch = settle_yaw, settings.start_pitch end
                locked = true
            end
        end
        -- right-stick click: turn the camera behind the character (smoothly), unless the player steers meanwhile
        local rs_down = key_state(pc, fname("Gamepad_RightThumbstick")) > 0.5
        if rs_down and not S.rs_prev and not S.climbing then
            S.recenter_until = now + 1.2
            log("camera reset behind the character (right-stick click)")
        end
        S.rs_prev = rs_down
        local face_yaw = nil
        if S.recenter_until or settings.auto_recenter then
            face_yaw = num(try(function() return pawn:K2_GetActorRotation().Yaw end))
        end
        if face_yaw and S.recenter_until and now < S.recenter_until then
            S.yaw, S.pitch = cam_math.recenter_step(S.yaw, S.pitch, face_yaw, settings.start_pitch, 10, 10, dt)
            locked = true
            if math.abs(cam_math.angle_diff(S.yaw, face_yaw)) < 1.5 and math.abs(S.pitch - settings.start_pitch) < 1.5 then S.recenter_until = nil end
        else
            S.recenter_until = nil
            -- walking on: the camera slowly swings behind the character (yaw only), when the player is not looking around
            if face_yaw and settings.auto_recenter and not S.climbing and now - (S.last_look or 0) > 0.8
                and not (try(function() return pawn.isAiming end) == true) then
                local velocity = try(function() return pawn:GetVelocity() end)
                local vx, vy = num(try(function() return velocity.X end)) or 0, num(try(function() return velocity.Y end)) or 0
                if vx * vx + vy * vy > 60 * 60 then
                    S.yaw = cam_math.recenter_step(S.yaw, S.pitch, face_yaw, settings.start_pitch, settings.auto_recenter_speed, nil, dt)
                end
            end
        end
        if not locked then
            S.yaw, S.pitch = cam_math.apply_look(S.yaw, S.pitch, input, settings, dt)
        end
    end
    set_control_rotation(pc, S.pitch, S.yaw)
    S.cmd = { pc = pc, pitch = S.pitch, yaw = S.yaw }
    write_basis(pawn, S.yaw)
    -- on a ladder the game's own controls stay untouched (the climb is scripted anyway)
    local climbing = is_climbing(pawn) or pushing
    if climbing ~= S.climbing then
        S.climbing = climbing
        log("ladder/push control handed to the game=" .. tostring(climbing) .. " pushing=" .. tostring(pushing) .. " inputDisabled=" .. tostring(try(function() return pawn.isInputDisabled end)) .. " vt=" .. (vt_name:match("[^%.:]+$") or "?"))
        if climbing and S.wasd_on then
            S.wasd_on = false
            pcall(function() pawn:SetStickXValue(0); pawn:SetStickYValue(0) end)
        end
    end
    if settings.dpad_shortcuts and not frozen and not climbing then update_dpad_shortcuts(pc, pawn, dt) end
    if not frozen and not climbing then update_wasd(pc, pawn) end

    if grabbed ~= S.was_grabbed then
        S.was_grabbed = grabbed
        log(string.format("grabbed=%s inputDisabled=%s vt=%s", tostring(grabbed), tostring(try(function() return pawn.isInputDisabled end)), full_name(vt):match("[^%.:]+$") or "?"))
    end

    local now = os.clock()
    if now - S.last_diag > 10 then
        S.last_diag = now
        local fwd = valid(cm) and try(function() return cm:GetActorForwardVector() end) or nil
        local fz = fwd and num(try(function() return fwd.Z end))
        local real_pitch = fz and math.deg(math.asin(math.max(-1, math.min(1, fz)))) or nil
        local ctrl = try(function() return pc:GetControlRotation() end)
        local ctrl_fwd = ctrl and try(function() return StaticFindObject("/Script/Engine.Default__KismetMathLibrary"):GetForwardVector(ctrl) end) or nil
        local ctrl_fz = ctrl_fwd and num(try(function() return ctrl_fwd.Z end))
        local ctrl_pitch_fwd = ctrl_fz and math.deg(math.asin(math.max(-1, math.min(1, ctrl_fz)))) or nil
        log(string.format("diag: ticks=%d basisRewrittenByGame=%d swaps=%d wanted yaw=%.1f pitch=%.1f | controlRot P=%s | camFwdPitch=%s | arm=%s | blockedStick=%d vt=%s",
            S.ticks, S.rewrites, S.swaps, S.yaw, S.pitch,
            tostring(rot_pitch(ctrl)) .. "/fwd:" .. (ctrl_pitch_fwd and string.format("%.1f", ctrl_pitch_fwd) or "nil"), real_pitch and string.format("%.1f", real_pitch) or "nil",
            tostring(S.arm and string.format("%.0f", S.arm)),
            S.blocked or 0, full_name(vt):match("[^%.:]+$") or "?"))
    end
end

local function on_tick(self_param, delta_param)
    local pawn = try(function() return self_param:get() end)
    local dt = num(try(function() return delta_param:get() end))
    local clock = os.clock()
    S.real_dt = S.last_clock and math.min(0.1, math.max(0.001, clock - S.last_clock)) or 0.016
    if not dt or dt <= 0 or dt > 0.25 then dt = S.last_clock and math.min(0.25, math.max(0.001, clock - S.last_clock)) or 0.016 end
    S.last_clock = clock
    pcall(update_remap, S.engaged)
    local ok, err = pcall(update, pawn, dt)
    if not ok then
        S.errors = (S.errors or 0) + 1
        if S.errors <= 5 then log("update error: " .. tostring(err)) end
    end
end

------------------------------------------------------------------ hooks
local function on_tick_post(self_param)
    local cmd = S.cmd
    if not S.engaged or not cmd or not valid(cmd.pc) then return end
    local pawn = try(function() return self_param:get() end)
    if not valid(pawn) then return end
    pcall(function()
        set_control_rotation(cmd.pc, cmd.pitch, cmd.yaw)
        local boom = pawn.CameraBoom
        if S.cmd_arm then boom.TargetArmLength = S.cmd_arm end
        if S.cmd_collision ~= nil then boom.bDoCollisionTest = S.cmd_collision end
    end)
end

-- Swap the game's fixed-camera cuts for the pawn before they happen (no flicker).
local ok_hook, hook_err = pcall(RegisterHook, "/Script/Engine.PlayerController:SetViewTargetWithBlend", function(self, new_target)
    local target = try(function() return new_target:get() end)
    if not S.self_call and (S.call_logs or 0) < 300 then
        S.call_logs = (S.call_logs or 0) + 1
        log(string.format("SetViewTargetWithBlend(%s, class %s) engaged=%s", full_name(target):match("[^%.:]+$") or "?",
            (try(function() return target:GetClass():GetFullName() end) or "?"):match("[^%.:]+$") or "?", tostring(S.engaged)))
    end
    if not S.self_call and valid(target) then S.requested = target end -- what the game itself asked for
    -- The game hands the fixed room camera back after a point of interest / puzzle / QTE: go straight to the TPS
    -- camera instead of showing the fixed one until the pawn's flags clear.
    if not S.self_call and settings.enabled and not S.engaged and S.special and is_plain_gameplay_camera(target) then
        local pc = try(function() return self:get() end)
        local pawn = valid(pc) and pawn_of(pc) or nil
        if valid(pawn) and pcall(function() new_target:set(pawn) end) then
            S.last_fixed = target
            if engage(pc, pawn, false, "game returned its camera after " .. tostring(S.special)) then
                S.returning, S.returning_until = true, os.clock() + 4
                S.blend_until = os.clock() + 2.5
                S.swaps = S.swaps + 1
            end
        end
        return
    end
    if S.self_call or not settings.enabled or not S.engaged then return end
    if not is_plain_gameplay_camera(target) then return end
    local pc = try(function() return self:get() end)
    local pawn = valid(pc) and pawn_of(pc) or nil
    if not valid(pawn) or not gameplay_ok(pawn) or effective_special(pawn) then return end
    S.last_fixed = target
    if pcall(function() new_target:set(pawn) end) then S.swaps = S.swaps + 1 end
end)
log("RegisterHook SetViewTargetWithBlend -> " .. tostring(ok_hook) .. (ok_hook and "" or (" " .. tostring(hook_err))))

-- Right-stick weapon shortcut: the controller feeds the stick into the pawn's AxisHorizontal/AxisVertical.
-- While the stick drives the camera, zero those calls (our own D-pad injection is let through).
for _, name in ipairs({ "AxisHorizontal", "AxisVertical" }) do
    local ok, err = pcall(RegisterHook, "/Script/TormentedSouls2.TormentedSouls2Character:" .. name, function(self, value)
        if S.injecting or not S.engaged or not settings.dpad_shortcuts then return end
        -- The inventory's item-rotation stick (IA_Inv_RotationStick) calls these same two functions. While the game has
        -- taken the input away from the pawn (inventory, item screens) they belong to that screen: let them through.
        local owner = try(function() return self:get() end)
        local pc = local_pc()
        if (valid(owner) and try(function() return owner.isInputDisabled end) == true) or (valid(pc) and game_paused(pc)) then
            S.axis_pass = (S.axis_pass or 0) + 1
            if S.axis_pass <= 3 then log(string.format("%s passed through (input disabled or paused: inventory / item screen)", name)) end
            return
        end
        if valid(pc) and number_key_down(pc) then
            S.number_until = os.clock() + 0.4
            S.number_calls = (S.number_calls or 0) + 1
            if S.number_calls <= 12 then
                local which = "?"
                for _, key in ipairs(NUMBER_KEYS) do if key_state(pc, fname(key)) > 0.5 then which = key end end
                log(string.format("number-key weapon shortcut passed through (%s=%s, key %s)", name, tostring(num(try(function() return value:get() end))), which))
            end
            return
        end
        if number_key_window() then return end
        local v = num(try(function() return value:get() end))
        if v and math.abs(v) > 0.05 then
            S.blocked = (S.blocked or 0) + 1
            if S.blocked <= 3 then log(string.format("blocked stick shortcut %s=%.2f", name, v)) end
        end
        pcall(function() value:set(0.0) end)
    end)
    log("RegisterHook " .. name .. " -> " .. tostring(ok) .. (ok and "" or (" " .. tostring(err))))
end

-- Tank movement of the D-pad: the character's DigitalMovement applies it with AddMovementInput (forward / back)
-- and K2_AddActorWorldRotation (turning). Those native calls are neutralised for the player's pawn while a D-pad
-- direction is held in TPS (and neither the left stick nor WASD is in use).
local function tank_input_blocked(self_param)
    if not S.engaged or not settings.enabled or not settings.dpad_shortcuts or S.ui_open or S.wasd_on or S.climbing then return false end
    local pc = local_pc()
    if not valid(pc) then return false end
    local pawn = pawn_of(pc)
    if not valid(pawn) then return false end
    if self_param then
        local actor = try(function() return self_param:get() end)
        if not valid(actor) or not same_object(actor, pawn) then return false end
    end
    local down = false
    for _, entry in ipairs(DPAD) do
        if key_state(pc, fname(entry.key)) > 0.5 then down = true; break end
    end
    if not down or pad_stick_active(pc) then return false end
    return pawn
end

local ok_move, err_move = pcall(RegisterHook, "/Script/Engine.Pawn:AddMovementInput", function(self, direction, scale)
    local blocked_pawn = tank_input_blocked(self)
    if not blocked_pawn then return end
    pcall(function() scale:set(0.0) end)
    suppress_tank_state(blocked_pawn, "AddMovementInput")
    S.tank_blocked_move = (S.tank_blocked_move or 0) + 1
    if S.tank_blocked_move == 1 then log("D-pad tank movement blocked (AddMovementInput)") end
end)
log("RegisterHook AddMovementInput -> " .. tostring(ok_move) .. (ok_move and "" or (" " .. tostring(err_move))))

local ok_turn, err_turn = pcall(RegisterHook, "/Script/Engine.Actor:K2_AddActorWorldRotation", function(self, delta)
    local blocked_pawn = tank_input_blocked(self)
    if not blocked_pawn then return end
    suppress_tank_state(blocked_pawn, "AddActorWorldRotation")
    local done = pcall(function() delta:set({ Pitch = 0.0, Yaw = 0.0, Roll = 0.0 }) end)
    if not done then pcall(function() local r = delta:get(); r.Pitch = 0.0; r.Yaw = 0.0; r.Roll = 0.0 end) end
    S.tank_blocked_turn = (S.tank_blocked_turn or 0) + 1
    if S.tank_blocked_turn == 1 then log("D-pad tank turning blocked (K2_AddActorWorldRotation) set=" .. tostring(done)) end
end)
log("RegisterHook K2_AddActorWorldRotation -> " .. tostring(ok_turn) .. (ok_turn and "" or (" " .. tostring(err_turn))))

-- Blueprint functions can only be hooked once their class is loaded (not yet at the main menu), so every
-- hook on the controller blueprint is registered by a retry loop like the pawn's tick hook.
local PC_BP = "/Game/NewInputSystem/TormentedSouls2PlayerController.TormentedSouls2PlayerController_C:"
local pending_hooks = {}
local function hook_when_loaded(event_name, pre, post, full_path)
    pending_hooks[#pending_hooks + 1] = { name = event_name, path = full_path, pre = pre or function() end, post = post, tries = 0 }
end

-- The animation blueprint reads the pawn's MovingF/B/R/L right at the start of these two functions (tank walk
-- and tank turn animations). Clear them just before, while a D-pad direction is held in TPS.
local ABP_BP = "/Game/Characters/Caroline/Animations/CharacterAnimations/ABP_CarolineCharacter.ABP_CarolineCharacter_C:"
for _, fn_name in ipairs({ "CalculateForwardDirection", "CalculateTurnDirection" }) do
    hook_when_loaded("ABP " .. fn_name, function()
        local blocked_pawn = tank_input_blocked(nil)
        if not blocked_pawn then return end
        suppress_tank_state(blocked_pawn, "ABP " .. fn_name)
    end, nil, ABP_BP .. fn_name)
end

-- The controller's D-pad/WASD action events write dpadX/dpadY; clear them right after, so the character's own
-- tick (which may run before our tick hook) never sees them.
for _, event_name in ipairs({ "InpActEvt_IA_Move_DPAD_K2Node_EnhancedInputActionEvent_81", "InpActEvt_IA_Move_DPAD_K2Node_EnhancedInputActionEvent_82" }) do
    hook_when_loaded(event_name, nil, function(self)
        if not S.engaged or not settings.enabled or not settings.dpad_shortcuts or S.ui_open then return end
        local pc = try(function() return self:get() end)
        local pawn = valid(pc) and pawn_of(pc) or nil
        if not valid(pawn) or S.climbing or not gameplay_ok(pawn) or special_state(pawn) then return end
        S.dpad_events = (S.dpad_events or 0) + 1
        if S.dpad_events <= 6 then
            log(string.format("D-pad/WASD event: game wrote dpadX=%s dpadY=%s (cleared)", tostring(num(try(function() return pawn.dpadX end))), tostring(num(try(function() return pawn.dpadY end)))))
        end
        clear_dpad(pawn)
    end)
end

LoopAsync(1000, function()
    local left = 0
    for _, hook in ipairs(pending_hooks) do if not hook.done then left = left + 1 end end
    if left == 0 then return true end
    ExecuteInGameThread(function()
        for _, hook in ipairs(pending_hooks) do
            if not hook.done then
                hook.tries = hook.tries + 1
                local ok, err = pcall(RegisterHook, hook.path or (PC_BP .. hook.name), hook.pre, hook.post)
                if ok then
                    hook.done = true
                    log(string.format("hooked %s (attempt %d)", hook.name, hook.tries))
                elseif hook.tries % 30 == 1 then
                    log(string.format("waiting to hook %s (attempt %d): %s", hook.name, hook.tries, tostring(err):sub(1, 100)))
                end
            end
        end
    end)
    return false
end)

-- The character blueprint is not loaded at the main menu, so retry until it exists.
local TICK_PATH = "/Game/Characters/BP_TormentedSoulCharacter.BP_TormentedSoulCharacter_C:ReceiveTick"
local tick_hooked, tries = false, 0
LoopAsync(1000, function()
    if tick_hooked then return true end
    ExecuteInGameThread(function()
        if tick_hooked then return end
        tries = tries + 1
        local ok, err = pcall(RegisterHook, TICK_PATH, on_tick, on_tick_post)
        if ok then
            tick_hooked = true
            log("hooked pawn ReceiveTick (attempt " .. tries .. ")")
        elseif tries % 20 == 1 then
            log("waiting for the character blueprint (attempt " .. tries .. "): " .. tostring(err):sub(1, 120))
        end
    end)
    return false
end)

------------------------------------------------------------------ F1 settings screen

-- Make the enabled switch take effect right away (the game is frozen while the screen is open).
local function refresh_enabled(pc, pawn)
    if not settings.enabled then
        if S.engaged then disengage(pc, pawn, true, "disabled in settings") end
        return
    end
    if S.engaged or special_state(pawn) or not gameplay_ok(pawn) then return end
    local cm = try(function() return pc.PlayerCameraManager end)
    local vt = valid(cm) and try(function() return cm.ViewTarget.Target end) or nil
    if same_object(vt, pawn) then
        engage(pc, pawn, false, "enabled in settings")
    elseif is_plain_gameplay_camera(vt) then
        S.last_fixed = vt
        engage(pc, pawn, true, "enabled in settings, fixed camera " .. (full_name(vt):match("[^%.:]+$") or "?"))
    end
end

-- A value changed on the screen (key = nil: the screen closed, "*": everything was reset).
-- Camera values are applied immediately; the file is written at most every 0.4 s and when the screen closes.
local function on_setting_changed(key)
    local now = os.clock()
    if key == nil or now - (S.last_save or 0) > 0.4 then
        save_settings()
        S.last_save = now
    end
    if key == nil then log("settings screen closed; settings saved"); return end
    local pc = local_pc()
    local pawn = valid(pc) and pawn_of(pc) or nil
    if not valid(pawn) then return end
    if S.engaged then
        apply_camera_settings(pawn)
        if key == "start_pitch" or key == "*" then S.pitch = settings.start_pitch end
        S.pitch = cam_math.clamp(S.pitch, settings.pitch_min, settings.pitch_max)
        set_control_rotation(pc, S.pitch, S.yaw)
        S.cmd = { pc = pc, pitch = S.pitch, yaw = S.yaw }
        S.arm, S.cmd_arm = settings.distance, settings.distance
        S.cmd_collision = settings.wall_check and not is_grabbed(pawn)
    end
    if key == "enabled" or key == "*" then refresh_enabled(pc, pawn) end
end

-- Only in ordinary play: not paused (a game menu is open), no cursor, no puzzle/QTE, input enabled.
local function can_open_screen()
    local pc = local_pc()
    local pawn = valid(pc) and pawn_of(pc) or nil
    if not valid(pawn) then return false, "no player character" end
    if game_paused(pc) then return false, "the game is paused (a game menu is open)" end
    if try(function() return pc.bShowMouseCursor end) == true then return false, "a menu is showing the mouse cursor" end
    local special = special_state(pawn)
    if special then return false, "special state: " .. special end
    if try(function() return pawn.isInputDisabled end) == true then return false, "the game has taken the controls" end
    return true
end

-- The game keeps its own language in the game instance (currentLanguage, an enum), not in Unreal's culture
-- (which stays "en"). Everything found is logged so the mapping can be checked against the log.
local function describe(value)
    if value == nil then return "nil" end
    if type(value) ~= "userdata" then return type(value) .. ":" .. tostring(value) end
    return "userdata:" .. tostring(try(function() return value:ToString() end) or "?")
end

-- True when `text` contains kana (U+3040..U+30FF), i.e. the game's own text is Japanese.
local function has_kana(text)
    local ok, result = pcall(function()
        for _, code in utf8.codes(text) do
            if code >= 0x3040 and code <= 0x30FF then return true end
        end
        return false
    end)
    return ok and result == true
end

-- Ask the game itself: its localized texts come from GameInstance:GetTextByID(TDBUI, id). If a label is
-- returned in Japanese the game is set to Japanese, whatever number the language enum uses.
local PROBE_TEXT_IDS = { "UI_O_Language", "UI_L_Language", "UI_L_Subtitles" }
local function localized_texts(gi)
    local found = {}
    local db = try(function() return gi.TDBUI end)
    if not valid(db) then return found end
    for _, id in ipairs(PROBE_TEXT_IDS) do
        local text = try(function()
            local r = gi:GetTextByID(db, id)
            if type(r) == "string" then return r end
            return r:ToString()
        end)
        if type(text) == "string" and text ~= "" and not text:find("not found", 1, true) then found[#found + 1] = { id = id, text = text } end
    end
    return found
end

local function game_language()
    local gi = try(function() return FindFirstOf("BP_TS2GameInstance_C") end) or try(function() return FindFirstOf("TS2GameInstance") end)
    local raw = valid(gi) and (try(function() return gi.currentLanguage end)) or nil
    local texts = valid(gi) and localized_texts(gi) or {}
    local shown = {}
    for _, t in ipairs(texts) do shown[#shown + 1] = t.id .. "=" .. t.text end
    log(string.format("game language: currentLanguage=%s texts=[%s]", describe(raw), table.concat(shown, " | ")))
    -- Japanese: kana anywhere, or the language label written 言語 (Chinese writes 语言 / 語言, no kana
    -- there; confirmed in the log: Japanese = number 9 = "言語", English = number 0 = "Language")
    for _, t in ipairs(texts) do
        if has_kana(t.text) or (t.id == "UI_L_Language" and t.text == "言語") then return "ja" end
    end
    if #texts > 0 then return "en" end
    -- no readable game text: fall back to a pinned language number (hidden setting japanese_value)
    if type(raw) == "number" and settings.japanese_value >= 0 and raw == settings.japanese_value then return "ja" end
    return "en"
end

local ok_ui, ui_err = pcall(function()
    screen = require("ui").new({
        valid = valid, log = log,
        player = function() local pc = local_pc(); return valid(pc) and pawn_of(pc) or nil, pc end,
        settings = settings, on_change = on_setting_changed, can_open = can_open_screen, key_state = key_state,
        set_open = function(open) S.ui_open = open end,
        language = game_language,
    })
end)
if not ok_ui then log("settings screen unavailable: " .. tostring(ui_err)) end

-- Keyboard: every binding does nothing unless the screen is open (except F1, which toggles it).
local function bind(key_name, handler)
    local key = Key[key_name]
    if not key then log("unknown key " .. key_name); return end
    local ok, err = pcall(RegisterKeyBindAsync, key, function() ExecuteInGameThread(handler) end)
    if not ok then log("could not bind " .. key_name .. ": " .. tostring(err)) end
end
local function screen_key(name) return function() if screen and screen.is_open() then screen.key(name) end end end
if screen then
    bind("F1", function() screen.toggle() end)
    -- arrows, WASD and PgUp/PgDn are polled by the screen itself (they repeat while held)
    -- Esc is polled by the screen (it also has to wait for the key to be released)
    for key_name, action in pairs({ R = "reset", RETURN = "confirm" }) do bind(key_name, screen_key(action)) end
end

log(string.format("loaded v" .. VERSION .. ". enabled=%s distance=%s fov=%s settings=%s", tostring(settings.enabled), tostring(settings.distance), tostring(settings.fov), settings_path))
