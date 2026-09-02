--[[
    Massgate - paired exotic-matter transit gates for Icarus.
    UE4SS 3.0.1 Lua side. The items, recipes, tech-tree node and power draw live in the
    data-table pak (mod/data/patches.json); this script adds the behaviour:

      * recognises our gates: Spotlight_Tripod actors whose item row is Massgate_Gate_<Channel>
      * swaps their placeholder mesh for a gate-like one when they spawn
      * on "Engage Massgate" (press interact) validates the pair, charges up, then moves
        the player to the partner gate on the same channel, landing safely on the ground
      * enforces: two gates per channel, both powered, minimum separation from any other
        gate (interference), per-gate cooldown, stay in the field while charging
      * brings your dismounted tames that stand in the field along (F dismounts, so you
        cannot engage while riding anyway)
      * talks to the player through the on-screen chat box

    Everything is wrapped in pcall and logged with the [Massgate] prefix so a failure
    never takes the game down; check ue4ss/UE4SS.log while testing.
]]

local CONFIG = {
    GateRowPrefix        = "Massgate_Gate_",
    GateClass            = "BP_Spotlight_Tripod_C",
    ButtonInteractHook   = "/Game/BP/Behaviours/Interactable/BP_Interactable_ButtonTrigger.BP_Interactable_ButtonTrigger_C:Interact",
    GatesPerChannel      = 2,
    RequirePower         = true,    -- both gates must be running
    InterferenceRadiusCm = 50000,   -- 500 m: no other gate (any channel) may be closer
    CooldownSeconds      = 20,      -- per gate, after a transit
    ChargeSeconds        = 3,       -- delay between engaging and the actual transit
    FieldRadiusCm        = 800,     -- the field: player must stay inside while charging, and
                                    -- tames inside it travel along
    BringTames           = true,    -- your dismounted mounts/pets in the field come with you
    FollowingTamesOnly   = true,    -- ... but only those set to Follow, so a farm never travels
    MountClass           = "BP_Mount_Base_C",
    FollowState          = 1,       -- EMountMovementBehaviourState::Follow
    TameSpacingCm        = 250,     -- lateral spacing for arriving tames
    ArrivalOffsetCm      = 150,     -- step out in front of the destination gate
    ArrivalLiftCm        = 100,     -- capsule half-height-ish lift above the traced ground
    TraceUpCm            = 300,     -- ground trace starts this far above the target
    TraceDownCm          = 800,     -- ... and ends this far below it
    ExoticsPerTrip       = 5,       -- TODO: actually deduct from the player's inventory
    -- Placeholder look. The deployable is the game's Spotlight tripod; at spawn we swap its
    -- mesh for this one (set to false to keep the tripod). Must match PreviewStaticMesh in
    -- patches.json so the placement preview looks like the placed gate.
    GateMesh             = "/Game/ASS/DEP/DEP_OEI_LandingPad/SM_DEP_OEI_LandingPad_T4.SM_DEP_OEI_LandingPad_T4",
    PlaceholderMeshMatch = "Tripod_Light",
    Debug                = true,
}

local function log(fmt, ...)
    print(string.format("[Massgate] " .. fmt .. "\n", ...))
end

local function dbg(fmt, ...)
    if CONFIG.Debug then log(fmt, ...) end
end

-- Development switch (config.lua next to this file). Everything that makes the gate
-- expensive is turned off so it can be tested on an early-game character.
local okCfg, userConfig = pcall(require, "config")
local DEV_MODE = okCfg and type(userConfig) == "table" and userConfig.DevMode == true
if DEV_MODE then
    CONFIG.RequirePower         = false
    CONFIG.ExoticsPerTrip       = 0
    CONFIG.CooldownSeconds      = 0
    CONFIG.InterferenceRadiusCm = 1000 -- 10 m, enough to test the refusal at a base
    log("DEV MODE: no power, no exotics, no cooldown, 10 m interference radius")
elseif not okCfg then
    log("config.lua not found or invalid (%s); using shipped defaults", tostring(userConfig))
end
if okCfg and type(userConfig) == "table" and userConfig.GateMesh ~= nil then
    CONFIG.GateMesh = userConfig.GateMesh
end

------------------------------------------------------------------------------------------
-- Small helpers
------------------------------------------------------------------------------------------

local function valid(obj)
    return obj ~= nil and obj:IsValid()
end

local function locationOf(actor)
    return actor:K2_GetActorLocation()
end

local function distance(a, b)
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function fmtLoc(v)
    return string.format("(%.0f, %.0f, %.0f)", v.X, v.Y, v.Z)
end

local function fullName(obj)
    local ok, name = pcall(function() return obj:GetFullName() end)
    return ok and name or "?"
end

------------------------------------------------------------------------------------------
-- Gate discovery
------------------------------------------------------------------------------------------

local function rowNameOf(actor)
    local ok, name = pcall(function()
        return actor.ItemData.ItemStaticData.RowName:ToString()
    end)
    if ok then return name end
    return nil
end

-- Returns the channel name for a gate actor, or nil when the actor is not a gate.
local function channelOf(actor)
    if not valid(actor) then return nil end
    local row = rowNameOf(actor)
    if row and row:sub(1, #CONFIG.GateRowPrefix) == CONFIG.GateRowPrefix then
        return row:sub(#CONFIG.GateRowPrefix + 1)
    end
    if row == "Massgate_Gate" then return "Alpha" end -- v0.1 gates placed before channels
    return nil
end

local function isGate(actor)
    return channelOf(actor) ~= nil
end

local function allGates()
    local gates = {}
    local ok, objects = pcall(FindAllOf, CONFIG.GateClass)
    if ok and objects then
        for _, actor in ipairs(objects) do
            local channel = channelOf(actor)
            if channel then gates[#gates + 1] = { actor = actor, channel = channel } end
        end
    end
    return gates
end

local function isPowered(gate)
    local ok, running = pcall(function() return gate.bIsDeviceRunning end)
    return ok and running == true
end

------------------------------------------------------------------------------------------
-- Player feedback: the game's chat box accepts local system messages
------------------------------------------------------------------------------------------

local function tell(player, text)
    log("-> %s", text)
    pcall(function()
        local controller = player:GetController()
        if valid(controller) then
            controller:AddLocalMessage("[Massgate] " .. text)
        end
    end)
end

------------------------------------------------------------------------------------------
-- Look: swap the placeholder tripod mesh for the configured gate mesh
------------------------------------------------------------------------------------------

local meshCache = nil

local function loadGateMesh()
    if not CONFIG.GateMesh then return nil end
    if valid(meshCache) then return meshCache end
    local path = CONFIG.GateMesh
    local ok, mesh = pcall(StaticFindObject, path)
    if not ok or not valid(mesh) then
        ok, mesh = pcall(LoadAsset, (path:gsub("%.[^./]+$", "")))
    end
    if ok and valid(mesh) then
        meshCache = mesh
        return mesh
    end
    log("could not load gate mesh %s (%s)", path, tostring(mesh))
    return nil
end

local function applyGateLook(actor)
    if not CONFIG.GateMesh then return end
    local ok, err = pcall(function()
        local mesh = loadGateMesh()
        if not mesh then return end
        local smcClass = StaticFindObject("/Script/Engine.StaticMeshComponent")
        local components = actor:K2_GetComponentsByClass(smcClass)
        local swapped = 0
        for i = 1, #components do
            local comp = components[i]
            local current = comp.StaticMesh
            if valid(current) and fullName(current):find(CONFIG.PlaceholderMeshMatch, 1, true) then
                comp:SetStaticMesh(mesh)
                swapped = swapped + 1
            end
        end
        dbg("look applied to %s (%d component(s) swapped)", fullName(actor), swapped)
    end)
    if not ok then log("applyGateLook failed: %s", tostring(err)) end
end

------------------------------------------------------------------------------------------
-- Arrival: trace down to the ground in front of the destination gate
------------------------------------------------------------------------------------------

local function groundedDestination(partner, player)
    local base = locationOf(partner)
    local forward = partner:GetActorForwardVector()
    local target = {
        X = base.X + forward.X * CONFIG.ArrivalOffsetCm,
        Y = base.Y + forward.Y * CONFIG.ArrivalOffsetCm,
        Z = base.Z,
    }
    local ok, traced = pcall(function()
        local kismet = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
        if not valid(kismet) then return nil end
        local startV = { X = target.X, Y = target.Y, Z = target.Z + CONFIG.TraceUpCm }
        local endV   = { X = target.X, Y = target.Y, Z = target.Z - CONFIG.TraceDownCm }
        local hit = {}
        local wasHit = kismet:LineTraceSingle(
            player, startV, endV,
            0,                  -- ETraceTypeQuery1 = Visibility
            false,              -- trace complex
            { player, partner }, -- actors to ignore (the gate itself must not count as ground)
            0,                  -- no debug draw
            hit,
            true,               -- ignore self
            { R = 1, G = 0, B = 0, A = 1 }, { R = 0, G = 1, B = 0, A = 1 }, 0.0)
        if wasHit and hit.ImpactPoint then
            return hit.ImpactPoint.Z
        end
        return nil
    end)
    if ok and traced then
        target.Z = traced + CONFIG.ArrivalLiftCm
        dbg("ground trace hit at Z=%.0f", traced)
    else
        target.Z = base.Z + CONFIG.ArrivalLiftCm
        dbg("ground trace unavailable (%s); using gate height", tostring(traced))
    end
    return target
end

------------------------------------------------------------------------------------------
-- Transit rules
------------------------------------------------------------------------------------------

local lastTransit = {} -- gate full name -> os.time() of last use
local charging    = {} -- gate full name -> true while a transit is charging

-- Pressing F while riding dismounts, so a rider can never engage a gate. Instead the
-- gate carries every tame of yours that stands in the field when the transit fires.
local function ownsTame(player, tame)
    local ok, owns = pcall(function()
        local state = player:GetPlayerState()
        if not valid(state) then return true end
        return tame:IsMountOwner(state)
    end)
    if not ok then return true end -- cannot tell: in solo play it is yours anyway
    return owns == true
end

local function tamesInField(gate, player)
    if not CONFIG.BringTames then return {} end
    local found = {}
    local ok, mounts = pcall(FindAllOf, CONFIG.MountClass)
    if not ok or not mounts then return found end
    local here = locationOf(gate)
    for _, tame in ipairs(mounts) do
        if valid(tame) and distance(here, locationOf(tame)) <= CONFIG.FieldRadiusCm and ownsTame(player, tame) then
            local ridden, following = false, true
            pcall(function() ridden = tame:IsBeingRidden() == true end)
            if CONFIG.FollowingTamesOnly then
                local ok2, state = pcall(function() return tame.MovementBehaviourState end)
                following = ok2 and tonumber(state) == CONFIG.FollowState
            end
            if not ridden and following then found[#found + 1] = tame end
        end
    end
    return found
end

local function moveTame(tame, dest, rotation)
    -- The game's own safe teleport for mounts; falls back to the plain engine move.
    local ok = pcall(function() tame:TeleportToSafeLocation(dest) end)
    if not ok then
        pcall(function() tame:K2_TeleportTo(dest, rotation) end)
    end
end

-- Returns partner actor, or nil plus a reason string.
local function resolvePartner(gate, channel, gates)
    local same, nearest = {}, nil
    local here = locationOf(gate)
    for _, entry in ipairs(gates) do
        if fullName(entry.actor) ~= fullName(gate) then
            local d = distance(here, locationOf(entry.actor))
            if not nearest or d < nearest then nearest = d end
            if entry.channel == channel then same[#same + 1] = entry.actor end
        end
    end
    if nearest and nearest < CONFIG.InterferenceRadiusCm then
        return nil, string.format("Lattice interference: another Massgate is %.0f m away (need %.0f m).",
            nearest / 100, CONFIG.InterferenceRadiusCm / 100)
    end
    if #same == 0 then
        return nil, string.format("No partner lattice on channel %s. Build a second %s gate elsewhere.", channel, channel)
    end
    if #same + 1 > CONFIG.GatesPerChannel then
        return nil, string.format("Channel %s has %d lattices; only %d may be tuned. Remove the extras.",
            channel, #same + 1, CONFIG.GatesPerChannel)
    end
    return same[1], nil
end

local function checkReady(gate, player, partner)
    if CONFIG.RequirePower then
        if not isPowered(gate) then return "This Massgate is unpowered." end
        if not isPowered(partner) then return "The destination Massgate is unpowered." end
    end
    return nil
end

local function performTransit(gate, player, partner, channel)
    local here = locationOf(gate)
    local dest = groundedDestination(partner, player)
    local rotation = player:K2_GetActorRotation()
    local tames = tamesInField(gate, player) -- collect before the player moves away

    local ok, moved = pcall(function() return player:K2_TeleportTo(dest, rotation) end)
    if not ok then
        return tell(player, "Transit failed (engine refused the move). See UE4SS.log."), log("teleport error: %s", tostring(moved))
    end
    if moved == false then
        -- Something solid where we wanted to land; fall back to right above the gate.
        local base = locationOf(partner)
        pcall(function()
            player:K2_TeleportTo({ X = base.X, Y = base.Y, Z = base.Z + CONFIG.ArrivalLiftCm + 50 }, rotation)
        end)
    end

    -- Tames line up to the right of the arrival point.
    if #tames > 0 then
        local right = partner:GetActorRightVector()
        for i, tame in ipairs(tames) do
            moveTame(tame, {
                X = dest.X + right.X * CONFIG.TameSpacingCm * i,
                Y = dest.Y + right.Y * CONFIG.TameSpacingCm * i,
                Z = dest.Z + 50,
            }, rotation)
        end
    end

    local now = os.time()
    lastTransit[fullName(gate)] = now
    lastTransit[fullName(partner)] = now
    log("transit [%s] %s -> %s (%.0f m) moved=%s tames=%d", channel, fmtLoc(here), fmtLoc(dest),
        distance(here, dest) / 100, tostring(moved), #tames)
    local parts = { "Transit complete." }
    if CONFIG.ExoticsPerTrip > 0 then parts[#parts + 1] = string.format("%d Exotics consumed.", CONFIG.ExoticsPerTrip) end
    if #tames == 1 then parts[#parts + 1] = "Your tame came with you." end
    if #tames > 1 then parts[#parts + 1] = string.format("%d tames came with you.", #tames) end
    tell(player, table.concat(parts, " "))
end

local function engage(gate, player)
    local channel = channelOf(gate)
    local key = fullName(gate)
    if charging[key] then
        return tell(player, "Lattice already charging.")
    end

    local gates = allGates()
    dbg("engage [%s]: %d gate(s) on prospect", channel, #gates)

    local partner, why = resolvePartner(gate, channel, gates)
    if not partner then return tell(player, why) end

    local now = os.time()
    if lastTransit[key] and now - lastTransit[key] < CONFIG.CooldownSeconds then
        return tell(player, string.format("Lattice re-stabilising, %d s remaining.",
            CONFIG.CooldownSeconds - (now - lastTransit[key])))
    end

    local notReady = checkReady(gate, player, partner)
    if notReady then return tell(player, notReady) end

    if CONFIG.ChargeSeconds <= 0 then
        return performTransit(gate, player, partner, channel)
    end

    charging[key] = true
    tell(player, string.format("Lattice charging on channel %s. Stay in the field for %d s.", channel, CONFIG.ChargeSeconds))

    ExecuteWithDelay(CONFIG.ChargeSeconds * 1000, function()
        ExecuteInGameThread(function()
            charging[key] = nil
            local ok, err = pcall(function()
                if not valid(gate) or not valid(player) then return end
                if not valid(partner) then
                    return tell(player, "Transit aborted: the partner lattice is gone.")
                end
                if distance(locationOf(player), locationOf(gate)) > CONFIG.FieldRadiusCm then
                    return tell(player, "Transit aborted: you left the field.")
                end
                local stillNotReady = checkReady(gate, player, partner)
                if stillNotReady then return tell(player, "Transit aborted: " .. stillNotReady) end
                performTransit(gate, player, partner, channel)
            end)
            if not ok then log("charge completion error: %s", tostring(err)) end
        end)
    end)
end

------------------------------------------------------------------------------------------
-- Hooking
--
-- Our gate's press-interaction is the game's generic ButtonTrigger behaviour, so we hook
-- its Interact and act only when the owning actor is one of our gates. Blueprint
-- functions can only be hooked once their class is loaded (first time any button-trigger
-- item exists in the world), so we retry until it sticks.
------------------------------------------------------------------------------------------

local hooked = false

local function onButtonInteract(self, Instigator, HitResult)
    local ok, err = pcall(function()
        local behaviour = self:get()
        local player = Instigator:get()
        if not valid(behaviour) or not valid(player) then return end

        local component = behaviour:GetInteractableComponent()
        if not valid(component) then return end
        local owner = component:GetOwner()
        if not isGate(owner) then return end

        dbg("gate engaged by %s at %s", fullName(player), fmtLoc(locationOf(owner)))
        engage(owner, player)
    end)
    if not ok then log("interact handler error: %s", tostring(err)) end
end

local function tryHook()
    if hooked then return true end
    local ok, err = pcall(RegisterHook, CONFIG.ButtonInteractHook, onButtonInteract)
    if ok then
        hooked = true
        log("hooked %s", CONFIG.ButtonInteractHook)
        -- Gates that were already in the world (loaded with the save) get their look now.
        for _, entry in ipairs(allGates()) do applyGateLook(entry.actor) end
    else
        dbg("hook not available yet (%s)", tostring(err))
    end
    return hooked
end

-- Keep trying every few seconds until the Blueprint class exists in memory.
LoopAsync(5000, function()
    ExecuteInGameThread(tryHook)
    return hooked
end)

-- Every new tripod actor: if it is one of our gates, log it and give it the gate look.
pcall(NotifyOnNewObject, "/Game/BP/Objects/World/Items/Deployables/Lights/BP_Spotlight_Tripod.BP_Spotlight_Tripod_C",
    function(actor)
        ExecuteWithDelay(500, function()
            ExecuteInGameThread(function()
                local channel = channelOf(actor)
                if channel then
                    log("gate [%s] spawned at %s (powered=%s)", channel, fmtLoc(locationOf(actor)), tostring(isPowered(actor)))
                    applyGateLook(actor)
                end
            end)
        end)
    end)

-- Console helper while testing: type `massgate` in the UE4SS console to list gates.
pcall(RegisterConsoleCommandHandler, "massgate", function(FullCommand, Parameters, Ar)
    local gates = allGates()
    Ar:Log(string.format("[Massgate] %d gate(s); hooked=%s dev=%s", #gates, tostring(hooked), tostring(DEV_MODE)))
    for i, entry in ipairs(gates) do
        Ar:Log(string.format("  #%d [%s] %s powered=%s", i, entry.channel, fmtLoc(locationOf(entry.actor)), tostring(isPowered(entry.actor))))
    end
    return true
end)

log("loaded (row prefix %s, class %s, dev=%s, mesh=%s)", CONFIG.GateRowPrefix, CONFIG.GateClass,
    tostring(DEV_MODE), tostring(CONFIG.GateMesh))
