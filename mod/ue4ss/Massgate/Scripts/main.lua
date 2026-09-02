--[[
    Massgate - exotic-matter transit gates for Icarus.
    UE4SS 3.0.1 Lua side. The items, recipes, tech-tree node and power draw live in the
    data-table pak (mod/data/patches.json); this script adds the behaviour.

    Two craftable items, both Spotlight_Tripod actors under the hood:
      * Anchor    (item row Massgate_Anchor)    : the base end. Heavy, power hungry. Anchors ignore
                                                  each other for interference, so a base can hold
                                                  several side by side.
      * Resonator (item row Massgate_Resonator) : the field end. Light, cheap, unshielded: refuses
                                                  to tune when ANY other gate is within the
                                                  interference radius, its own anchor included.
    The channel is a setting on the placed gate: alt-press "Tune channel" cycles through the
    configured list. Channels are stored per gate in channels.txt next to this mod, keyed by the
    item's database GUID (or its position as a fallback), so they survive save and load.
    A pair is one anchor and one resonator on the same channel.

    On "Engage Massgate" (press interact): validate the pair, charge up while the player stays in
    the field, then move the player (and any of their tames set to Follow inside the field) to
    the partner gate, landing on traced ground. Inbound trips (to the anchor) are carried by the
    anchor's mass and cost nothing; outbound trips (to a resonator) burn Exotics.

    Gameplay runs only where the game has authority (solo, host, or a UE4SS dedicated server).
    Looks and map icons are local and run everywhere the Lua is installed.

    Everything is wrapped in pcall and logged with the [Massgate] prefix so a failure never
    takes the game down; check ue4ss/UE4SS.log while testing.
]]

local CONFIG = {
    KindRows = { Massgate_Anchor = "Anchor", Massgate_Resonator = "Resonator" },
    -- Legacy rows from earlier builds: row -> kind, and an optional fixed default channel.
    LegacyRowPattern     = "^Massgate_(%a+)_(%w+)$",
    LegacyRow            = "Massgate_Gate",
    GateClass            = "BP_Spotlight_Tripod_C",
    ButtonInteractHook   = "/Game/BP/Behaviours/Interactable/BP_Interactable_ButtonTrigger.BP_Interactable_ButtonTrigger_C:Interact",
    EngageRow            = "Massgate_Activate",  -- D_Interactions row behind "Engage Massgate"
    TuneRow              = "Massgate_Tune",      -- D_Interactions row behind "Tune channel"
    Channels             = { "Alpha", "Beta", "Gamma" }, -- overridden from config.lua
    ChannelStore         = "Mods/Massgate/channels.txt", -- relative to the ue4ss folder (UE4SS cwd)
    RequirePower         = true,
    InterferenceRadiusCm = 50000,   -- 500 m
    CooldownSeconds      = 20,
    ChargeSeconds        = 3,
    FieldRadiusCm        = 800,
    BringTames           = true,
    FollowingTamesOnly   = true,
    MountClass           = "BP_Mount_Base_C",
    FollowState          = 1,       -- EMountMovementBehaviourState::Follow
    TameSpacingCm        = 250,
    ArrivalOffsetCm      = 150,
    ArrivalLiftCm        = 100,
    TraceUpCm            = 300,
    TraceDownCm          = 800,
    ExoticsOutbound      = 5,       -- anchor -> resonator. TODO: actually deduct from inventory
    ExoticsInbound       = 0,
    Meshes = {
        Anchor    = "/Game/ASS/DEP/DEP_OEI_LandingPad/SM_DEP_OEI_LandingPad_T4.SM_DEP_OEI_LandingPad_T4",
        Resonator = "/Game/ASS/DEP/SM_DEP_Laser_Uplink.SM_DEP_Laser_Uplink",
    },
    PlaceholderMeshMatch = "Tripod_Light",
    MapIcons             = true,
    MapIconComponentClass = "/Script/Icarus.IcarusMapIconComponent",
    MapIconsLibrary      = "/Script/Icarus.Default__MapIconsLibrary",
    MapIconsTable        = "/Engine/Transient.D_MapIcons",
    Debug                = true,
}

local IDENTITY_TRANSFORM = {
    Rotation    = { X = 0, Y = 0, Z = 0, W = 1 },
    Translation = { X = 0, Y = 0, Z = 0 },
    Scale3D     = { X = 1, Y = 1, Z = 1 },
}

local function log(fmt, ...)
    print(string.format("[Massgate] " .. fmt .. "\n", ...))
end

local function dbg(fmt, ...)
    if CONFIG.Debug then log(fmt, ...) end
end

-- config.lua: dev switch, channel list, mesh overrides.
local okCfg, userConfig = pcall(require, "config")
local DEV_MODE = okCfg and type(userConfig) == "table" and userConfig.DevMode == true
if DEV_MODE then
    CONFIG.RequirePower         = false
    CONFIG.ExoticsOutbound      = 0
    CONFIG.ExoticsInbound       = 0
    CONFIG.CooldownSeconds      = 0
    CONFIG.InterferenceRadiusCm = 1000 -- 10 m
    log("DEV MODE: no power, no exotics, no cooldown, 10 m interference radius")
elseif not okCfg then
    log("config.lua not found or invalid (%s); using shipped defaults", tostring(userConfig))
end
if okCfg and type(userConfig) == "table" then
    if type(userConfig.Channels) == "table" and #userConfig.Channels > 0 then
        CONFIG.Channels = userConfig.Channels
    end
    if type(userConfig.Meshes) == "table" then
        for kind, path in pairs(userConfig.Meshes) do CONFIG.Meshes[kind] = path end
    end
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

local function hasAuthority(actor)
    local ok, auth = pcall(function() return actor:HasAuthority() end)
    return ok and auth == true
end

local function channelIndex(channel)
    for i, c in ipairs(CONFIG.Channels) do
        if c == channel then return i end
    end
    return nil
end

------------------------------------------------------------------------------------------
-- Channel store: "key=channel" lines, one gate per line
------------------------------------------------------------------------------------------

local channelStore = nil

local function loadStore()
    if channelStore then return channelStore end
    channelStore = {}
    local ok, err = pcall(function()
        local f = io.open(CONFIG.ChannelStore, "r")
        if not f then return end
        for line in f:lines() do
            local key, channel = line:match("^(.-)=(%w+)%s*$")
            if key and channel then channelStore[key] = channel end
        end
        f:close()
    end)
    if not ok then log("channel store read failed: %s", tostring(err)) end
    return channelStore
end

local function saveStore()
    local ok, err = pcall(function()
        local f = assert(io.open(CONFIG.ChannelStore, "w"))
        for key, channel in pairs(channelStore or {}) do
            f:write(key, "=", channel, "\n")
        end
        f:close()
    end)
    if not ok then log("channel store write failed: %s", tostring(err)) end
end

-- Stable identity for a placed gate: the item's database GUID when it has one, else its
-- position rounded to 10 cm (a deployable does not move until picked up).
local function gateKey(actor)
    local guid = nil
    pcall(function()
        local s = actor.ItemData.DatabaseGUID:ToString()
        if s and #s > 0 then guid = s end
    end)
    if guid then return "guid:" .. guid end
    local loc = locationOf(actor)
    return string.format("loc:%d,%d,%d", math.floor(loc.X / 10 + 0.5), math.floor(loc.Y / 10 + 0.5), math.floor(loc.Z / 10 + 0.5))
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

-- Returns kind, defaultChannel for a gate actor, or nil when the actor is not a gate.
local function kindOf(actor)
    if not valid(actor) then return nil end
    local row = rowNameOf(actor)
    if not row then return nil end
    if CONFIG.KindRows[row] then return CONFIG.KindRows[row], CONFIG.Channels[1] end
    if row == CONFIG.LegacyRow then return "Anchor", CONFIG.Channels[1] end
    local kind, channel = row:match(CONFIG.LegacyRowPattern)
    if kind == "Anchor" or kind == "Resonator" then
        return kind, channelIndex(channel) and channel or CONFIG.Channels[1]
    end
    return nil
end

-- Returns kind, channel (stored channel wins over the row's default).
local function identify(actor)
    local kind, default = kindOf(actor)
    if not kind then return nil end
    local stored = loadStore()[gateKey(actor)]
    if stored and channelIndex(stored) then return kind, stored end
    return kind, default
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
-- Player feedback: local chat box for the local player, client RPC for remote players
------------------------------------------------------------------------------------------

local function tell(player, text)
    log("-> %s", text)
    pcall(function()
        local controller = player:GetController()
        if not valid(controller) then return end
        local isLocal = true
        pcall(function() isLocal = controller:IsLocalController() == true end)
        if isLocal then
            controller:AddLocalMessage("[Massgate] " .. text)
        else
            controller:ClientReceiveServerMessage("[Massgate] " .. text)
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

local function isVisibleComp(comp)
    local ok, vis = pcall(function() return comp:IsVisible() end)
    return not ok or vis ~= false
end

-- The tripod Blueprint may render through a static mesh, a skeletal mesh (moving light head),
-- or both. Strategy: swap every visible static mesh that is not a helper; if there was none to
-- swap, put our mesh on the base class' DeployableSM slot; hide any visible skeletal mesh.
local function applyGateLook(actor, kind)
    local ok, err = pcall(function()
        local mesh = loadMesh(kind)
        if not mesh then return end
        local swapped, hidden, seen = 0, 0, {}

        local smcClass = StaticFindObject("/Script/Engine.StaticMeshComponent")
        local statics = actor:K2_GetComponentsByClass(smcClass)
        for i = 1, #statics do
            local comp = statics[i]
            local current = comp.StaticMesh
            local name = valid(current) and fullName(current) or "(none)"
            local visible = isVisibleComp(comp)
            seen[#seen + 1] = string.format("SM %s vis=%s", name:match("[^%.]+$") or name, tostring(visible))
            if valid(current) and visible and not name:find("SphereHelper", 1, true) and not name:find("Sphere", 1, true) then
                comp:SetStaticMesh(mesh)
                swapped = swapped + 1
            end
        end

        local skClass = StaticFindObject("/Script/Engine.SkeletalMeshComponent")
        local skeletals = actor:K2_GetComponentsByClass(skClass)
        for i = 1, #skeletals do
            local comp = skeletals[i]
            local current = comp.SkeletalMesh
            local name = valid(current) and fullName(current) or "(none)"
            local visible = isVisibleComp(comp)
            seen[#seen + 1] = string.format("SK %s vis=%s", name:match("[^%.]+$") or name, tostring(visible))
            if valid(current) and visible then
                comp:SetVisibility(false, true)
                hidden = hidden + 1
            end
        end

        if swapped == 0 then
            local slot = actor.DeployableSM
            if valid(slot) then
                slot:SetStaticMesh(mesh)
                slot:SetVisibility(true, true)
                swapped = 1
                seen[#seen + 1] = "used DeployableSM slot"
            end
        end

        dbg("%s look applied to %s: swapped=%d hidden=%d [%s]", kind, fullName(actor):match("[^%.]+$"),
            swapped, hidden, table.concat(seen, "; "))
    end)
    if not ok then log("applyGateLook failed: %s", tostring(err)) end
end

------------------------------------------------------------------------------------------
-- Map icon: the game's map-icon component pointing at our D_MapIcons row Massgate_<Kind>_<Channel>
------------------------------------------------------------------------------------------

local function findMapIcon(actor, compClass)
    local found = nil
    pcall(function()
        local comps = actor:K2_GetComponentsByClass(compClass)
        if #comps > 0 then found = comps[1] end
    end)
    return found
end

local function pointMapIcon(comp, kind, channel)
    local rowName = "Massgate_" .. kind .. "_" .. channel
    local viaLibrary = pcall(function()
        local lib = StaticFindObject(CONFIG.MapIconsLibrary)
        comp.MapIconData = lib:MakeMapIcons(FName(rowName))
    end)
    if not viaLibrary then
        comp.MapIconData.RowName = FName(rowName)
        local table = StaticFindObject(CONFIG.MapIconsTable)
        if valid(table) then comp.MapIconData.DataTable = table end
    end
    return rowName, viaLibrary
end

local function addMapIcon(actor, kind, channel)
    if not CONFIG.MapIcons then return end
    local ok, err = pcall(function()
        local compClass = StaticFindObject(CONFIG.MapIconComponentClass)
        if not valid(compClass) then return log("map icon component class not found") end
        if findMapIcon(actor, compClass) then return end

        local comp = actor:AddComponentByClass(compClass, true, IDENTITY_TRANSFORM, true) -- deferred
        if not valid(comp) then return log("AddComponentByClass returned nothing") end
        local rowName, viaLibrary = pointMapIcon(comp, kind, channel)
        pcall(function() comp.bSetupIconAutomatically = true end)
        actor:FinishAddComponent(comp, true, IDENTITY_TRANSFORM)
        pcall(function() comp:TrySetupMapIcon() end)
        dbg("map icon %s attached to %s (row set via %s)", rowName, fullName(actor), viaLibrary and "library" or "fields")
    end)
    if not ok then log("addMapIcon failed: %s", tostring(err)) end
end

local function refreshMapIcon(actor, kind, channel)
    if not CONFIG.MapIcons then return end
    local ok, err = pcall(function()
        local compClass = StaticFindObject(CONFIG.MapIconComponentClass)
        local comp = valid(compClass) and findMapIcon(actor, compClass)
        if not comp then return addMapIcon(actor, kind, channel) end
        pcall(function() comp:TryRemoveMapIcon() end)
        pointMapIcon(comp, kind, channel)
        pcall(function() comp:TrySetupMapIcon() end)
    end)
    if not ok then log("refreshMapIcon failed: %s", tostring(err)) end
end

local function decorate(actor, kind, channel)
    applyGateLook(actor, kind)
    addMapIcon(actor, kind, channel)
end

------------------------------------------------------------------------------------------
-- Tuning: cycle the gate's channel
------------------------------------------------------------------------------------------

local function tune(gate, player)
    local kind, channel = identify(gate)
    local idx = channelIndex(channel) or 0
    local nextChannel = CONFIG.Channels[(idx % #CONFIG.Channels) + 1]
    loadStore()[gateKey(gate)] = nextChannel
    saveStore()
    refreshMapIcon(gate, kind, nextChannel)
    log("tuned %s %s: %s -> %s", kind, gateKey(gate), tostring(channel), nextChannel)
    tell(player, string.format("%s tuned to channel %s.", kind, nextChannel))
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
            0, false, { player, partner }, 0, hit, true,
            { R = 1, G = 0, B = 0, A = 1 }, { R = 0, G = 1, B = 0, A = 1 }, 0.0)
        if wasHit and hit.ImpactPoint then return hit.ImpactPoint.Z end
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
-- Tames: only your tames set to Follow that stand in the field travel along
------------------------------------------------------------------------------------------

local function ownsTame(player, tame)
    local ok, owns = pcall(function()
        local state = player:GetPlayerState()
        if not valid(state) then return true end
        return tame:IsMountOwner(state)
    end)
    if not ok then return true end
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
    local ok = pcall(function() tame:TeleportToSafeLocation(dest) end)
    if not ok then
        pcall(function() tame:K2_TeleportTo(dest, rotation) end)
    end
end

------------------------------------------------------------------------------------------
-- Transit rules
------------------------------------------------------------------------------------------

local lastTransit = {} -- gate full name -> os.time() of last use
local charging    = {} -- gate full name -> full name of the player it is charging for

local function otherKind(kind)
    return kind == "Anchor" and "Resonator" or "Anchor"
end

local function resolvePartner(gate, kind, channel, gates)
    local here = locationOf(gate)
    local partners, sameKindOnChannel = {}, 0
    local nearestOffender = nil

    for _, entry in ipairs(gates) do
        if fullName(entry.actor) ~= fullName(gate) then
            local d = distance(here, locationOf(entry.actor))
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
        return nil, string.format("Channel %s has more than one %s. Retune or remove the extra one.", channel, kind)
    end
    if #partners == 0 then
        return nil, string.format("No %s tuned to channel %s.", otherKind(kind), channel)
    end
    if #partners > 1 then
        return nil, string.format("Channel %s has %d %ss; only one may be tuned.", channel, #partners, otherKind(kind))
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
    local tames = tamesInField(gate, player)
    local exotics = (kind == "Anchor") and CONFIG.ExoticsOutbound or CONFIG.ExoticsInbound

    local ok, moved = pcall(function() return player:K2_TeleportTo(dest, rotation) end)
    if not ok then
        log("teleport error: %s", tostring(moved))
        return tell(player, "Transit failed (engine refused the move). See UE4SS.log.")
    end
    if moved == false then
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
        if charging[key] == fullName(player) then
            return tell(player, "Lattice already charging.")
        end
        return tell(player, "Lattice is charging for another prospector. Wait your turn.")
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

    charging[key] = fullName(player)
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
-- Hooking. Both "Engage Massgate" and "Tune channel" use the game's generic ButtonTrigger
-- behaviour; the behaviour's interaction row tells them apart.
------------------------------------------------------------------------------------------

local hooked = false

local function interactionRowOf(behaviour)
    local ok, row = pcall(function() return behaviour.InteractionsRowHandle.RowName:ToString() end)
    return ok and row or nil
end

local function onButtonInteract(self, Instigator, HitResult)
    local ok, err = pcall(function()
        local behaviour = self:get()
        local player = Instigator:get()
        if not valid(behaviour) or not valid(player) then return end

        local component = behaviour:GetInteractableComponent()
        if not valid(component) then return end
        local owner = component:GetOwner()
        if not isGate(owner) then return end
        if not hasAuthority(owner) then
            return dbg("interaction seen on a client; the server handles it")
        end

        local row = interactionRowOf(behaviour)
        if row == CONFIG.TuneRow then
            tune(owner, player)
        elseif row == CONFIG.EngageRow or row == nil then
            dbg("gate engaged by %s at %s", fullName(player), fmtLoc(locationOf(owner)))
            engage(owner, player)
        else
            dbg("ignoring button interaction %s on a gate", tostring(row))
        end
    end)
    if not ok then log("interact handler error: %s", tostring(err)) end
end

local function tryHook()
    if hooked then return true end
    local ok, err = pcall(RegisterHook, CONFIG.ButtonInteractHook, onButtonInteract)
    if ok then
        hooked = true
        log("hooked %s", CONFIG.ButtonInteractHook)
        for _, entry in ipairs(allGates()) do decorate(entry.actor, entry.kind, entry.channel) end
    else
        dbg("hook not available yet (%s)", tostring(err))
    end
    return hooked
end

LoopAsync(5000, function()
    ExecuteInGameThread(tryHook)
    return hooked
end)

pcall(NotifyOnNewObject, "/Game/BP/Objects/World/Items/Deployables/Lights/BP_Spotlight_Tripod.BP_Spotlight_Tripod_C",
    function(actor)
        ExecuteWithDelay(500, function()
            ExecuteInGameThread(function()
                local kind, channel = identify(actor)
                if kind then
                    log("%s [%s] spawned at %s key=%s powered=%s", kind, channel, fmtLoc(locationOf(actor)),
                        gateKey(actor), tostring(isPowered(actor)))
                    decorate(actor, kind, channel)
                end
            end)
        end)
    end)

pcall(RegisterConsoleCommandHandler, "massgate", function(FullCommand, Parameters, Ar)
    local gates = allGates()
    Ar:Log(string.format("[Massgate] %d gate(s); hooked=%s dev=%s channels=%s", #gates, tostring(hooked),
        tostring(DEV_MODE), table.concat(CONFIG.Channels, ",")))
    for i, entry in ipairs(gates) do
        Ar:Log(string.format("  #%d %s [%s] %s key=%s powered=%s", i, entry.kind, entry.channel,
            fmtLoc(locationOf(entry.actor)), gateKey(entry.actor), tostring(isPowered(entry.actor))))
    end
    return true
end)

local VERSION = (okCfg and type(userConfig) == "table" and userConfig.Version) or "repo"
log("Massgate v%s loaded (class %s, dev=%s, channels=%s)", tostring(VERSION), CONFIG.GateClass,
    tostring(DEV_MODE), table.concat(CONFIG.Channels, ","))
