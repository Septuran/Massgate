--[[
    Massgate - exotic-matter transit gates for Icarus.
    UE4SS 3.0.1 Lua side. The items, recipes, tech-tree node and power draw live in the
    data-table pak (mod/data/patches.json); this script adds the behaviour.

    A gate is a Spotlight_Tripod actor whose item row is Massgate_<Kind>_<Channel>:
      * Kind = Anchor     : the base end. Heavy, power hungry. Anchors ignore each other for
                            interference, so a base can hold one anchor per channel side by side.
      * Kind = Resonator  : the field end. Light, cheap, unshielded: it refuses to tune when
                            ANY other gate (anchor or resonator) is within the interference radius,
                            which also keeps it far from its own anchor.
    A pair is one anchor and one resonator on the same channel. Channels come from the row
    name, so adding channels in patches.json needs no change here.

    On "Engage Massgate" (press interact): validate the pair, charge up while the player stays in
    the field, then move the player (and any of their tames set to Follow inside the field) to
    the partner gate, landing on traced ground. Inbound trips (to the anchor) are carried by the
    anchor's mass and cost nothing; outbound trips (to a resonator) burn Exotics.

    Everything is wrapped in pcall and logged with the [Massgate] prefix so a failure never
    takes the game down; check ue4ss/UE4SS.log while testing.
]]

local CONFIG = {
    RowPattern           = "^Massgate_(%a+)_(%w+)$", -- kind, channel
    LegacyRow            = "Massgate_Gate",          -- v0.1 gates: treated as Anchor / Alpha
    GateClass            = "BP_Spotlight_Tripod_C",
    ButtonInteractHook   = "/Game/BP/Behaviours/Interactable/BP_Interactable_ButtonTrigger.BP_Interactable_ButtonTrigger_C:Interact",
    RequirePower         = true,    -- both ends must be running
    InterferenceRadiusCm = 50000,   -- 500 m: a resonator refuses if any other gate is closer
    CooldownSeconds      = 20,      -- per gate, after a transit
    ChargeSeconds        = 3,       -- delay between engaging and the actual transit
    FieldRadiusCm        = 800,     -- the field: player must stay inside while charging, and
                                    -- following tames inside it travel along
    BringTames           = true,
    FollowingTamesOnly   = true,    -- only tames set to Follow travel, so a farm never does
    MountClass           = "BP_Mount_Base_C",
    FollowState          = 1,       -- EMountMovementBehaviourState::Follow
    TameSpacingCm        = 250,
    ArrivalOffsetCm      = 150,     -- step out in front of the destination gate
    ArrivalLiftCm        = 100,     -- lift above traced ground
    TraceUpCm            = 300,
    TraceDownCm          = 800,
    ExoticsOutbound      = 5,       -- anchor -> resonator. TODO: actually deduct from inventory
    ExoticsInbound       = 0,       -- resonator -> anchor: the anchor does the work
    -- Looks. The deployable is the game's Spotlight tripod; at spawn we swap its mesh per kind.
    -- Keep in sync with PreviewStaticMesh in patches.json. Set a kind to false to keep the tripod.
    Meshes = {
        Anchor    = "/Game/ASS/DEP/DEP_OEI_LandingPad/SM_DEP_OEI_LandingPad_T4.SM_DEP_OEI_LandingPad_T4",
        Resonator = "/Game/ASS/DEP/SM_DEP_Laser_Uplink.SM_DEP_Laser_Uplink",
    },
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
    CONFIG.ExoticsOutbound      = 0
    CONFIG.ExoticsInbound       = 0
    CONFIG.CooldownSeconds      = 0
    CONFIG.InterferenceRadiusCm = 1000 -- 10 m, enough to test the refusal at a base
    log("DEV MODE: no power, no exotics, no cooldown, 10 m interference radius")
elseif not okCfg then
    log("config.lua not found or invalid (%s); using shipped defaults", tostring(userConfig))
end
if okCfg and type(userConfig) == "table" and type(userConfig.Meshes) == "table" then
    for kind, path in pairs(userConfig.Meshes) do CONFIG.Meshes[kind] = path end
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

local function metres(cm)
    return string.format("%.0f m", cm / 100)
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

-- Returns kind, channel for a gate actor, or nil when the actor is not a gate.
local function identify(actor)
    if not valid(actor) then return nil end
    local row = rowNameOf(actor)
    if not row then return nil end
    if row == CONFIG.LegacyRow then return "Anchor", "Alpha" end
    local kind, channel = row:match(CONFIG.RowPattern)
    if kind == "Anchor" or kind == "Resonator" then return kind, channel end
    return nil
end

local function isGate(actor)
    return identify(actor) ~= nil
end

local function allGates()
    local gates = {}
    local ok, objects = pcall(FindAllOf, CONFIG.GateClass)
    if ok and objects then
        for _, actor in ipairs(objects) do
            local kind, channel = identify(actor)
            if kind then gates[#gates + 1] = { actor = actor, kind = kind, channel = channel } end
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
-- Look: swap the placeholder tripod mesh for the kind's mesh
------------------------------------------------------------------------------------------

local meshCache = {}

local function loadMesh(kind)
    local path = CONFIG.Meshes[kind]
    if not path then return nil end
    if valid(meshCache[kind]) then return meshCache[kind] end
    local ok, mesh = pcall(StaticFindObject, path)
    if not ok or not valid(mesh) then
        ok, mesh = pcall(LoadAsset, (path:gsub("%.[^./]+$", "")))
    end
    if ok and valid(mesh) then
        meshCache[kind] = mesh
        return mesh
    end
    log("could not load %s mesh %s (%s)", kind, path, tostring(mesh))
    return nil
end

local function applyGateLook(actor, kind)
    local ok, err = pcall(function()
        local mesh = loadMesh(kind)
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
        dbg("%s look applied to %s (%d component(s) swapped)", kind, fullName(actor), swapped)
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
            0,                   -- ETraceTypeQuery1 = Visibility
            false,               -- trace complex
            { player, partner }, -- the gate itself must not count as ground
            0,                   -- no debug draw
            hit,
            true,                -- ignore self
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
-- Tames: pressing F while riding dismounts, so a rider can never engage a gate. Instead the
-- gate carries every tame of yours that is set to Follow and stands in the field.
------------------------------------------------------------------------------------------

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

------------------------------------------------------------------------------------------
-- Transit rules
------------------------------------------------------------------------------------------

local lastTransit = {} -- gate full name -> os.time() of last use
local charging    = {} -- gate full name -> true while a transit is charging

local function otherKind(kind)
    return kind == "Anchor" and "Resonator" or "Anchor"
end

-- Returns the partner entry, or nil plus a reason string.
local function resolvePartner(gate, kind, channel, gates)
    local here = locationOf(gate)
    local partners, sameKindOnChannel = {}, 0
    local nearestOffender = nil

    for _, entry in ipairs(gates) do
        if fullName(entry.actor) ~= fullName(gate) then
            local d = distance(here, locationOf(entry.actor))
            -- Interference: resonators are unshielded against everything; anchors only
            -- mind resonators (anchors share the base's reference frame).
            local offends = (kind == "Resonator") or (entry.kind == "Resonator")
            if offends and d < CONFIG.InterferenceRadiusCm and (not nearestOffender or d < nearestOffender.d) then
                nearestOffender = { d = d, entry = entry }
            end
            if entry.channel == channel then
                if entry.kind == kind then
                    sameKindOnChannel = sameKindOnChannel + 1
                else
                    partners[#partners + 1] = entry
                end
            end
        end
    end

    if nearestOffender then
        return nil, string.format("Lattice interference: a %s is %s away (need %s).",
            nearestOffender.entry.kind, metres(nearestOffender.d), metres(CONFIG.InterferenceRadiusCm))
    end
    if sameKindOnChannel > 0 then
        return nil, string.format("Channel %s has more than one %s. Remove the extra one.", channel, kind)
    end
    if #partners == 0 then
        return nil, string.format("No %s on channel %s. Build one elsewhere on the prospect.", otherKind(kind), channel)
    end
    if #partners > 1 then
        return nil, string.format("Channel %s has %d %ss; only one may be tuned. Remove the extras.",
            channel, #partners, otherKind(kind))
    end
    return partners[1], nil
end

local function checkReady(gate, partner)
    if CONFIG.RequirePower then
        if not isPowered(gate) then return "This lattice is unpowered." end
        if not isPowered(partner) then return "The destination lattice is unpowered." end
    end
    return nil
end

local function performTransit(gate, kind, channel, player, partner)
    local here = locationOf(gate)
    local dest = groundedDestination(partner, player)
    local rotation = player:K2_GetActorRotation()
    local tames = tamesInField(gate, player) -- collect before the player moves away
    local exotics = (kind == "Anchor") and CONFIG.ExoticsOutbound or CONFIG.ExoticsInbound

    local ok, moved = pcall(function() return player:K2_TeleportTo(dest, rotation) end)
    if not ok then
        log("teleport error: %s", tostring(moved))
        return tell(player, "Transit failed (engine refused the move). See UE4SS.log.")
    end
    if moved == false then
        -- Something solid where we wanted to land; fall back to right above the gate.
        local base = locationOf(partner)
        pcall(function()
            player:K2_TeleportTo({ X = base.X, Y = base.Y, Z = base.Z + CONFIG.ArrivalLiftCm + 50 }, rotation)
        end)
    end

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
    log("transit [%s] %s -> %s: %s -> %s (%s) moved=%s tames=%d exotics=%d", channel, kind, otherKind(kind),
        fmtLoc(here), fmtLoc(dest), metres(distance(here, dest)), tostring(moved), #tames, exotics)

    local parts = { kind == "Anchor" and "Outbound transit complete." or "Inbound transit complete." }
    if exotics > 0 then parts[#parts + 1] = string.format("%d Exotics consumed.", exotics) end
    if #tames == 1 then parts[#parts + 1] = "Your tame came with you." end
    if #tames > 1 then parts[#parts + 1] = string.format("%d tames came with you.", #tames) end
    tell(player, table.concat(parts, " "))
end

local function engage(gate, player)
    local kind, channel = identify(gate)
    local key = fullName(gate)
    if charging[key] then
        return tell(player, "Lattice already charging.")
    end

    local gates = allGates()
    dbg("engage %s [%s]: %d gate(s) on prospect", kind, channel, #gates)

    local partnerEntry, why = resolvePartner(gate, kind, channel, gates)
    if not partnerEntry then return tell(player, why) end
    local partner = partnerEntry.actor

    local now = os.time()
    if lastTransit[key] and now - lastTransit[key] < CONFIG.CooldownSeconds then
        return tell(player, string.format("Lattice re-stabilising, %d s remaining.",
            CONFIG.CooldownSeconds - (now - lastTransit[key])))
    end

    local notReady = checkReady(gate, partner)
    if notReady then return tell(player, notReady) end

    if CONFIG.ChargeSeconds <= 0 then
        return performTransit(gate, kind, channel, player, partner)
    end

    charging[key] = true
    tell(player, string.format("Lattice charging: %s to %s on channel %s. Stay in the field for %d s.",
        kind, otherKind(kind), channel, CONFIG.ChargeSeconds))

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
                local stillNotReady = checkReady(gate, partner)
                if stillNotReady then return tell(player, "Transit aborted: " .. stillNotReady) end
                performTransit(gate, kind, channel, player, partner)
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
        for _, entry in ipairs(allGates()) do applyGateLook(entry.actor, entry.kind) end
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

-- Every new tripod actor: if it is one of our gates, log it and give it its look.
pcall(NotifyOnNewObject, "/Game/BP/Objects/World/Items/Deployables/Lights/BP_Spotlight_Tripod.BP_Spotlight_Tripod_C",
    function(actor)
        ExecuteWithDelay(500, function()
            ExecuteInGameThread(function()
                local kind, channel = identify(actor)
                if kind then
                    log("%s [%s] spawned at %s (powered=%s)", kind, channel, fmtLoc(locationOf(actor)), tostring(isPowered(actor)))
                    applyGateLook(actor, kind)
                end
            end)
        end)
    end)

-- Console helper while testing: type `massgate` in the UE4SS console to list gates.
pcall(RegisterConsoleCommandHandler, "massgate", function(FullCommand, Parameters, Ar)
    local gates = allGates()
    Ar:Log(string.format("[Massgate] %d gate(s); hooked=%s dev=%s", #gates, tostring(hooked), tostring(DEV_MODE)))
    for i, entry in ipairs(gates) do
        Ar:Log(string.format("  #%d %s [%s] %s powered=%s", i, entry.kind, entry.channel,
            fmtLoc(locationOf(entry.actor)), tostring(isPowered(entry.actor))))
    end
    return true
end)

log("loaded (class %s, dev=%s)", CONFIG.GateClass, tostring(DEV_MODE))
