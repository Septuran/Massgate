--[[
    Massgate - exotic-matter transit gates for Icarus.
    UE4SS 3.0.1 Lua side. The items, recipes, tech-tree node, power draw, meshes and panel
    layout live in the data-table pak (mod/data/patches.json); this script adds the behaviour.

    Two craftable gates, both built on the game's small metal crate actor so they get the
    standard storage panel (hold interact):
      * Anchor    (item row Massgate_Anchor)    : the base end. Heavy, power hungry. Anchors ignore
                                                  each other for interference.
      * Resonator (item row Massgate_Resonator) : the field end. Light, cheap, unshielded: refuses
                                                  to tune when ANY other gate is within the
                                                  interference radius, its own anchor included.
    The panel has six slots: 0-3 Exotics (the buffer), 4 one module, 5 one Tuning Crystal.
    The crystal in slot 5 IS the gate's colour charge (Red, Green or Blue); no crystal, no channel.
    A pair is one anchor and one resonator carrying the same colour.

    On "Engage Massgate" (press interact): validate the pair, charge up while the player stays in
    the field, then move the player (and any of their tames set to Follow inside the field) to
    the partner gate, landing on traced ground. Inbound trips (to the anchor) are free; outbound
    trips (to a resonator) burn Exotics from the anchor's buffer, more when a Phase Coupler is
    slotted, which in turn lets the anchor power its resonator without a grid.

    Gameplay runs only where the game has authority (solo, host, or a UE4SS dedicated server).
    Map icons are local and run everywhere the Lua is installed.

    Everything is wrapped in pcall and logged with the [Massgate] prefix so a failure never
    takes the game down; check ue4ss/UE4SS.log while testing.
]]

local CONFIG = {
    KindRows = { Massgate_Anchor = "Anchor", Massgate_Resonator = "Resonator" },
    LegacyRowPattern     = "^Massgate_(%a+)_(%w+)$",  -- old per-channel items: kind, ignored colour
    LegacyRow            = "Massgate_Gate",
    GateClasses          = { "BP_Metal_Crate_Small_C", "BP_Spotlight_Tripod_C" },
    GateBlueprints       = {
        "/Game/BP/Objects/World/Items/Deployables/Containers/BP_Metal_Crate_Small.BP_Metal_Crate_Small_C",
        "/Game/BP/Objects/World/Items/Deployables/Lights/BP_Spotlight_Tripod.BP_Spotlight_Tripod_C",
    },
    ButtonInteractHook   = "/Game/BP/Behaviours/Interactable/BP_Interactable_ButtonTrigger.BP_Interactable_ButtonTrigger_C:Interact",
    EngageRow            = "Massgate_Activate",
    Channels             = { "Red", "Green", "Blue" },  -- overridden from config.lua
    ExoticsRow           = "MetaResource",
    BufferSlots          = 4,                          -- slots 0-3 hold Exotics
    ModuleSlot           = 4,
    TuningSlot           = 5,
    CrystalRowPrefix     = "Massgate_Crystal_",        -- Massgate_Crystal_<Colour>
    CouplerRow           = "Massgate_Coupler",
    CouplerExtraExotics  = 3,
    StackProperty        = 7,                          -- EDynamicItemProperties::ItemableStack
    RequirePower         = true,
    DevAnchorsPowered    = false,
    InterferenceRadiusCm = 50000,                      -- 500 m
    CooldownSeconds      = 20,
    ChargeSeconds        = 3,
    FieldRadiusCm        = 800,
    BringTames           = true,
    FollowingTamesOnly   = true,
    MountClass           = "BP_Mount_Base_C",
    FollowState          = 1,                          -- EMountMovementBehaviourState::Follow
    TameSpacingCm        = 250,
    ArrivalOffsetCm      = 150,
    ArrivalLiftCm        = 100,
    TraceUpCm            = 300,
    TraceDownCm          = 800,
    ExoticsOutbound      = 5,
    ExoticsInbound       = 0,
    -- Looks: the crate actor draws its own box through components we cannot read from Lua, so we
    -- hide every mesh component except the base class' DeployableSM slot and put our mesh there.
    Meshes = {
        Anchor    = "/Game/ASS/DEP/DEP_OEI_LandingPad/SM_DEP_OEI_LandingPad_T4.SM_DEP_OEI_LandingPad_T4",
        Resonator = "/Game/ASS/DEP/SM_DEP_Laser_Uplink.SM_DEP_Laser_Uplink",
    },
    MapIcons             = true,
    MapIconComponentClass = "/Script/Icarus.IcarusMapIconComponent",
    MapIconsLibrary      = "/Script/Icarus.Default__MapIconsLibrary",
    MapIconsTable        = "/Engine/Transient.D_MapIcons",
    IconRefreshMs        = 15000,                      -- re-check crystals and repoint icons
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

local okCfg, userConfig = pcall(require, "config")
local DEV_MODE = okCfg and type(userConfig) == "table" and userConfig.DevMode == true
if DEV_MODE then
    CONFIG.DevAnchorsPowered    = true
    CONFIG.CooldownSeconds      = 0
    CONFIG.InterferenceRadiusCm = 1000 -- 10 m
    log("DEV MODE: anchors always powered, resonators need power or a coupler, no cooldown, 10 m interference")
elseif not okCfg then
    log("config.lua not found or invalid (%s); using shipped defaults", tostring(userConfig))
end
if okCfg and type(userConfig) == "table" and type(userConfig.Channels) == "table" and #userConfig.Channels > 0 then
    CONFIG.Channels = userConfig.Channels
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

local function shortName(obj)
    return fullName(obj):match("[^%.]+$") or "?"
end

local function metres(cm)
    return string.format("%.0f m", cm / 100)
end

local function hasAuthority(actor)
    local ok, auth = pcall(function() return actor:HasAuthority() end)
    return ok and auth == true
end

local function isChannel(name)
    for _, c in ipairs(CONFIG.Channels) do
        if c == name then return true end
    end
    return false
end

------------------------------------------------------------------------------------------
-- Gate identity: kind from the item row, colour from the crystal in the tuning slot
------------------------------------------------------------------------------------------

local function rowNameOf(actor)
    local ok, name = pcall(function()
        return actor.ItemData.ItemStaticData.RowName:ToString()
    end)
    if ok then return name end
    return nil
end

local function kindOf(actor)
    if not valid(actor) then return nil end
    local row = rowNameOf(actor)
    if not row then return nil end
    if CONFIG.KindRows[row] then return CONFIG.KindRows[row] end
    if row == CONFIG.LegacyRow then return "Anchor" end
    local kind = row:match(CONFIG.LegacyRowPattern)
    if kind == "Anchor" or kind == "Resonator" then return kind end
    return nil
end

-- The gate's own storage inventory (the panel). UInventory objects are created by the gate's
-- InventoryComponent; we find the one whose outer chain leads back to this gate.
local panelCache = {}   -- gate full name -> UInventory
local panelDebugged = false

local function outerChainHits(obj, targetNames, depth)
    local cur = obj
    for _ = 1, depth do
        local nxt = nil
        pcall(function() nxt = cur:GetOuter() end)
        if not (nxt and nxt:IsValid()) then return false end
        if targetNames[fullName(nxt)] then return true end
        cur = nxt
    end
    return false
end

local function panelOf(gate)
    local key = fullName(gate)
    local cached = panelCache[key]
    if cached and cached:IsValid() then return cached end
    local found = nil
    pcall(function()
        local targets = { [key] = true }
        local cls = StaticFindObject("/Script/Icarus.InventoryComponent")
        local comps = gate:K2_GetComponentsByClass(cls)
        for i = 1, #comps do targets[fullName(comps[i])] = true end
        -- First choice: the component's own map of inventories.
        if #comps > 0 then
            pcall(function()
                comps[1].Inventories:ForEach(function(k, v)
                    local inv = v:get()
                    if not found and inv and inv:IsValid() then found = inv end
                end)
            end)
        end
        -- Fallback: every UInventory in the world whose outer chain hits the gate or its component.
        if not found then
            local ok, all = pcall(FindAllOf, "Inventory")
            if ok and all then
                for _, inv in ipairs(all) do
                    if outerChainHits(inv, targets, 4) then found = inv break end
                end
                if not found and not panelDebugged then
                    panelDebugged = true
                    log("panel lookup failed for %s: %d inventories, %d inventory components; sample outer chain: %s",
                        shortName(gate), #all, #comps, (function()
                            local inv = all[1]; if not inv then return "none" end
                            local parts, cur = {}, inv
                            for _ = 1, 4 do
                                local nxt = nil; pcall(function() nxt = cur:GetOuter() end)
                                if not (nxt and nxt:IsValid()) then break end
                                parts[#parts + 1] = shortName(nxt); cur = nxt
                            end
                            return table.concat(parts, " > ")
                        end)())
                end
            end
        end
    end)
    if found then panelCache[key] = found end
    return found
end

local function rowInSlot(inv, slot)
    local row = nil
    pcall(function()
        if inv and inv:HasValidItemInSlot(slot) then
            row = inv:GetItem(slot).ItemStaticData.RowName:ToString()
        end
    end)
    return row
end

-- Colour charge of a gate, or nil when no (valid) crystal is slotted.
local function channelOf(gate, inv)
    local row = rowInSlot(inv or panelOf(gate), CONFIG.TuningSlot)
    if row and row:sub(1, #CONFIG.CrystalRowPrefix) == CONFIG.CrystalRowPrefix then
        local colour = row:sub(#CONFIG.CrystalRowPrefix + 1)
        if isChannel(colour) then return colour end
    end
    return nil
end

local function identify(actor)
    local kind = kindOf(actor)
    if not kind then return nil end
    return kind, channelOf(actor)
end

local function isGate(actor)
    return kindOf(actor) ~= nil
end

-- Registry of gate actors. Filled once by a world scan when the mod hooks in, then kept
-- current by the spawn notifications; never rescanned on a timer (scanning every object in the
-- game every few seconds is what caused the stutter).
local registry = {} -- full name -> actor

local function register(actor)
    if isGate(actor) then registry[fullName(actor)] = actor end
end

local function scanWorldForGates()
    for _, className in ipairs(CONFIG.GateClasses) do
        local ok, objects = pcall(FindAllOf, className)
        if ok and objects then
            for _, actor in ipairs(objects) do register(actor) end
        end
    end
end

local function allGates()
    local gates = {}
    for name, actor in pairs(registry) do
        if valid(actor) then
            local kind, channel = identify(actor)
            if kind then gates[#gates + 1] = { actor = actor, kind = kind, channel = channel } end
        else
            registry[name] = nil
        end
    end
    return gates
end

------------------------------------------------------------------------------------------
-- Power (game's resource trait component) and the Exotics buffer
------------------------------------------------------------------------------------------

local function isPowered(gate)
    local ok, powered = pcall(function()
        local cls = StaticFindObject("/Script/Icarus.ResourceComponent")
        local comps = gate:K2_GetComponentsByClass(cls)
        if #comps == 0 then return nil end
        local res = comps[1]
        if res:IsDeviceTurnedOn() ~= true then return false end
        local energy = res.EnergyComponent:Get()
        if not valid(energy) then return false end
        return energy:IsConnectedAndReceivingFullFlow() == true
    end)
    if ok and powered ~= nil then return powered end
    local ok2, running = pcall(function() return gate.bIsDeviceRunning end)
    return ok2 and running == true
end

-- Stack size lives in the item's dynamic data as (PropertyType = ItemableStack, Value = n).
-- Never hand the item struct to a native function: that crashed the game.
local stackDebugged = false
local function stackOf(item)
    local count, seen = nil, {}
    local ok, err = pcall(function()
        item.ItemDynamicData:ForEach(function(index, elem)
            local entry = elem:get()
            local ptype, value = tonumber(entry.PropertyType), tonumber(entry.Value)
            seen[#seen + 1] = tostring(entry.PropertyType) .. "=" .. tostring(entry.Value)
            if ptype == CONFIG.StackProperty then count = value end
        end)
    end)
    if not ok and not stackDebugged then
        stackDebugged = true
        log("stack read failed: %s", tostring(err))
    end
    if count == nil and not stackDebugged then
        stackDebugged = true
        dbg("stack property not found; dynamic data = [%s]", table.concat(seen, ", "))
    end
    return count or 1
end

local function exoticsIn(inv)
    local total, slots = 0, {}
    if not inv then return 0, slots end
    for slot = 0, CONFIG.BufferSlots - 1 do
        pcall(function()
            if inv:HasValidItemInSlot(slot) then
                local item = inv:GetItem(slot)
                if item.ItemStaticData.RowName:ToString() == CONFIG.ExoticsRow then
                    local n = stackOf(item)
                    total = total + n
                    slots[#slots + 1] = { slot = slot, count = n }
                end
            end
        end)
    end
    return total, slots
end

local function consumeExotics(inv, amount)
    local _, slots = exoticsIn(inv)
    local left = amount
    for _, s in ipairs(slots) do
        if left <= 0 then break end
        local take = math.min(left, s.count)
        local ok = pcall(function() inv:RemoveItem(s.slot, take, false) end)
        if ok then left = left - take end
    end
    return amount - left
end

local function hasCoupler(anchor)
    return rowInSlot(panelOf(anchor), CONFIG.ModuleSlot) == CONFIG.CouplerRow
end

------------------------------------------------------------------------------------------
-- Player feedback
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
-- Look: hide every mesh component on the crate actor, then show our mesh in DeployableSM
------------------------------------------------------------------------------------------

local meshCache = {}
local lookDone = {}

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

-- Every object whose outer is this actor: its components, found by walking the object table.
-- K2_GetComponentsByClass gave us entries Lua could not use, so this is the reliable route.
local function componentsOf(actor)
    local list, actorName = {}, fullName(actor)
    pcall(function()
        ForEachUObject(function(obj)
            pcall(function()
                local outer = obj:GetOuter()
                if outer and outer:IsValid() and fullName(outer) == actorName then
                    list[#list + 1] = obj
                end
            end)
        end)
    end)
    return list
end

local function className(obj)
    local ok, name = pcall(function() return obj:GetClass():GetFName():ToString() end)
    if ok and name then return name end
    return (fullName(obj):match("^(%S+)") or "?")
end

local function applyLook(actor, kind)
    local key = fullName(actor)
    if lookDone[key] then return end
    local ok, err = pcall(function()
        local mesh = loadMesh(kind)
        if not mesh then return end
        local slot = actor.DeployableSM
        if not valid(slot) then return log("no DeployableSM on %s", shortName(actor)) end
        local slotName = fullName(slot)
        local report, hidden = {}, 0

        for _, comp in ipairs(componentsOf(actor)) do
            local cls = className(comp)
            if cls:find("MeshComponent", 1, true) and fullName(comp) ~= slotName then
                local vis = nil
                pcall(function() vis = comp:IsVisible() end)
                pcall(function() comp:SetVisibility(false, true) end)
                pcall(function() comp:SetHiddenInGame(true, true) end)
                hidden = hidden + 1
                report[#report + 1] = string.format("%s(%s) was vis=%s", shortName(comp), cls, tostring(vis))
            end
        end

        pcall(function() slot:SetMobility(2) end) -- EComponentMobility::Movable
        local set = slot:SetStaticMesh(mesh)
        slot:SetVisibility(true, true)
        pcall(function() slot:SetHiddenInGame(false, true) end)

        if set ~= false then lookDone[key] = true end
        log("%s look on %s: hid %d mesh component(s) [%s]; slot set=%s", kind, shortName(actor), hidden,
            table.concat(report, "; "), tostring(set))
    end)
    if not ok then log("applyLook failed: %s", tostring(err)) end
end

-- One-time diagnostic: a few seconds after the look pass, list every component on the actor
-- so whatever still draws a box can be identified.
local dumped = {}
local function dumpComponentsLater(actor)
    local key = fullName(actor)
    if dumped[key] then return end
    dumped[key] = true
    ExecuteWithDelay(3000, function()
        ExecuteInGameThread(function()
            pcall(function()
                if not valid(actor) then return end
                local comps = componentsOf(actor)
                local parts = {}
                for _, c in ipairs(comps) do
                    local vis = "-"
                    pcall(function() vis = tostring(c:IsVisible()) end)
                    parts[#parts + 1] = string.format("%s:%s vis=%s", className(c), shortName(c), vis)
                end
                log("components of %s (%d): %s", shortName(actor), #comps, table.concat(parts, " | "))
                pcall(function()
                    local out = {}
                    actor:GetAttachedActors(out, true)
                    if #out > 0 then
                        local names = {}
                        for i = 1, #out do names[#names + 1] = fullName(out[i]) end
                        log("attached actors of %s: %s", shortName(actor), table.concat(names, " | "))
                    end
                end)
            end)
        end)
    end)
end

------------------------------------------------------------------------------------------
-- Map icon: the game's map-icon component pointing at Massgate_<Kind>_<Colour|None>
------------------------------------------------------------------------------------------

local iconState = {} -- gate full name -> row currently applied

local function iconRow(kind, channel)
    return "Massgate_" .. kind .. "_" .. (channel or "None")
end

local function findMapIcon(actor, compClass)
    local found = nil
    pcall(function()
        local comps = actor:K2_GetComponentsByClass(compClass)
        if #comps > 0 then found = comps[1] end
    end)
    return found
end

local function pointMapIcon(comp, rowName)
    local viaLibrary, libErr = pcall(function()
        local lib = StaticFindObject(CONFIG.MapIconsLibrary)
        if not valid(lib) then error("map icons library not found") end
        comp.MapIconData = lib:MakeMapIcons(FName(rowName))
    end)
    if not viaLibrary then
        dbg("map icon library path failed (%s); writing fields on %s", tostring(libErr), fullName(comp))
        comp.MapIconData.RowName = FName(rowName)
        local table = StaticFindObject(CONFIG.MapIconsTable)
        if valid(table) then comp.MapIconData.DataTable = table end
    end
end

local iconRetryAt = {} -- gate full name -> os.time() after which to try again

local function updateMapIcon(actor, kind, channel)
    if not CONFIG.MapIcons then return end
    local row = iconRow(kind, channel)
    local key = fullName(actor)
    if iconState[key] == row then return end
    if iconRetryAt[key] and os.time() < iconRetryAt[key] then return end
    iconRetryAt[key] = os.time() + 30 -- on failure, do not spam: retry in 30 s
    local ok, err = pcall(function()
        local compClass = StaticFindObject(CONFIG.MapIconComponentClass)
        if not valid(compClass) then return log("map icon component class not found") end
        local comp = findMapIcon(actor, compClass)
        if comp then
            pcall(function() comp:TryRemoveMapIcon() end)
            pointMapIcon(comp, row)
            pcall(function() comp:TrySetupMapIcon() end)
        else
            comp = actor:AddComponentByClass(compClass, true, IDENTITY_TRANSFORM, true)
            if not valid(comp) then return log("AddComponentByClass returned nothing") end
            pointMapIcon(comp, row)
            pcall(function() comp.bSetupIconAutomatically = true end)
            actor:FinishAddComponent(comp, true, IDENTITY_TRANSFORM)
            pcall(function() comp:TrySetupMapIcon() end)
        end
        iconState[key] = row
        iconRetryAt[key] = nil
        dbg("map icon %s on %s", row, shortName(actor))
    end)
    if not ok then log("updateMapIcon failed: %s", tostring(err)) end
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
            if channel and entry.channel == channel then
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
    if not channel then
        return nil, "No colour charge. Slot a Tuning Crystal into the last slot of this lattice's panel."
    end
    if sameKindOnChannel > 0 then
        return nil, string.format("More than one %s carries %s. Change a crystal.", kind, channel)
    end
    if #partners == 0 then
        return nil, string.format("No %s carries %s.", otherKind(kind), channel)
    end
    if #partners > 1 then
        return nil, string.format("%d %ss carry %s; only one may.", #partners, otherKind(kind), channel)
    end
    return partners[1], nil
end

local function tripCost(kind, anchor)
    if kind ~= "Anchor" then return CONFIG.ExoticsInbound end
    local cost = CONFIG.ExoticsOutbound
    if anchor and hasCoupler(anchor) then cost = cost + CONFIG.CouplerExtraExotics end
    return cost
end

-- Returns powered, source ("grid" | "coupled" | "dev" | "none").
local function powerState(gate, kind, otherGate)
    if kind == "Anchor" then
        if CONFIG.DevAnchorsPowered then return true, "dev" end
        return isPowered(gate), "grid"
    end
    if isPowered(gate) then return true, "grid" end
    if otherGate and hasCoupler(otherGate) then
        local anchorOk = CONFIG.DevAnchorsPowered or isPowered(otherGate)
        if anchorOk then return true, "coupled" end
    end
    return false, "none"
end

local function checkReady(gate, kind, partner)
    local anchor = (kind == "Anchor") and gate or partner
    if CONFIG.RequirePower then
        local hereOk = powerState(gate, kind, partner)
        if not hereOk then
            return kind == "Resonator"
                and "This Resonator is unpowered. Give it power, or slot a Phase Coupler into its Anchor."
                or "This lattice is unpowered."
        end
        local thereOk = powerState(partner, otherKind(kind), gate)
        if not thereOk then
            return kind == "Anchor"
                and "The destination Resonator is unpowered. Give it power, or slot a Phase Coupler here."
                or "The destination Anchor is unpowered."
        end
    end
    local cost = tripCost(kind, anchor)
    if cost > 0 then
        local have = exoticsIn(panelOf(anchor))
        if have < cost then
            return string.format("Anchor holds %d Exotics, %d needed. Hold interact on it to load.", have, cost)
        end
    end
    return nil
end

local function performTransit(gate, kind, channel, player, partner)
    local here = locationOf(gate)
    local dest = groundedDestination(partner, player)
    local rotation = player:K2_GetActorRotation()
    local tames = tamesInField(gate, player)
    local anchor = (kind == "Anchor") and gate or partner
    local exotics = tripCost(kind, anchor)
    if exotics > 0 then
        local taken = consumeExotics(panelOf(anchor), exotics)
        if taken < exotics then
            return tell(player, string.format("Transit aborted: the anchor could only spare %d of %d Exotics.", taken, exotics))
        end
    end

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
    do
        local resonator = (kind == "Anchor") and partner or gate
        local _, source = powerState(resonator, "Resonator", anchor)
        if source == "coupled" then parts[#parts + 1] = "Resonator powered by phase coupling." end
    end
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
    dbg("engage %s [%s]: %d gate(s) on prospect", kind, tostring(channel), #gates)

    local partnerEntry, why = resolvePartner(gate, kind, channel, gates)
    if not partnerEntry then return tell(player, why) end
    local partner = partnerEntry.actor

    local now = os.time()
    if lastTransit[key] and now - lastTransit[key] < CONFIG.CooldownSeconds then
        return tell(player, string.format("Lattice re-stabilising, %d s remaining.",
            CONFIG.CooldownSeconds - (now - lastTransit[key])))
    end

    local notReady = checkReady(gate, kind, partner)
    if notReady then return tell(player, notReady) end

    if CONFIG.ChargeSeconds <= 0 then
        return performTransit(gate, kind, channel, player, partner)
    end

    charging[key] = fullName(player)
    tell(player, string.format("Lattice charging: %s to %s on %s. Stay in the field for %d s.",
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
                local _, nowChannel = identify(gate)
                if nowChannel ~= channel or channelOf(partner) ~= channel then
                    return tell(player, "Transit aborted: a crystal was changed while charging.")
                end
                local stillNotReady = checkReady(gate, kind, partner)
                if stillNotReady then return tell(player, "Transit aborted: " .. stillNotReady) end
                performTransit(gate, kind, channel, player, partner)
            end)
            if not ok then log("charge completion error: %s", tostring(err)) end
        end)
    end)
end

------------------------------------------------------------------------------------------
-- Hooking: "Engage Massgate" is the game's generic ButtonTrigger behaviour, so we hook its
-- Interact and act only when the owning actor is one of our gates.
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
        if not hasAuthority(owner) then
            return dbg("interaction seen on a client; the server handles it")
        end
        local row = nil
        pcall(function() row = behaviour.InteractionsRowHandle.RowName:ToString() end)
        if row ~= nil and row ~= CONFIG.EngageRow then
            return dbg("ignoring button interaction %s on a gate", tostring(row))
        end
        dbg("gate engaged by %s at %s", shortName(player), fmtLoc(locationOf(owner)))
        engage(owner, player)
    end)
    if not ok then log("interact handler error: %s", tostring(err)) end
end

local function refreshAllIcons()
    for _, entry in ipairs(allGates()) do
        applyLook(entry.actor, entry.kind)
        updateMapIcon(entry.actor, entry.kind, entry.channel)
    end
end

local function tryHook()
    if hooked then return true end
    local ok, err = pcall(RegisterHook, CONFIG.ButtonInteractHook, onButtonInteract)
    if ok then
        hooked = true
        log("hooked %s", CONFIG.ButtonInteractHook)
        scanWorldForGates()
        refreshAllIcons()
    else
        dbg("hook not available yet (%s)", tostring(err))
    end
    return hooked
end

LoopAsync(5000, function()
    ExecuteInGameThread(tryHook)
    return hooked
end)

-- Crystals can be swapped in the panel at any time. Re-read them from the registry (cheap: a few
-- inventory slot reads, no world scan) every IconRefreshMs.
LoopAsync(CONFIG.IconRefreshMs, function()
    if hooked then ExecuteInGameThread(function() pcall(refreshAllIcons) end) end
    return false
end)

for _, bpPath in ipairs(CONFIG.GateBlueprints) do
    pcall(NotifyOnNewObject, bpPath, function(actor)
        ExecuteWithDelay(500, function()
            ExecuteInGameThread(function()
                local kind, channel = identify(actor)
                if kind then
                    register(actor)
                    log("%s [%s] spawned at %s powered=%s exotics=%d panel=%s", kind, tostring(channel), fmtLoc(locationOf(actor)),
                        tostring(isPowered(actor)), (exoticsIn(panelOf(actor))), tostring(panelOf(actor) ~= nil))
                    applyLook(actor, kind)
                    updateMapIcon(actor, kind, channel)
                    dumpComponentsLater(actor)
                end
            end)
        end)
    end)
end

pcall(RegisterConsoleCommandHandler, "massgate", function(FullCommand, Parameters, Ar)
    local gates = allGates()
    Ar:Log(string.format("[Massgate] %d gate(s); hooked=%s dev=%s", #gates, tostring(hooked), tostring(DEV_MODE)))
    for i, entry in ipairs(gates) do
        Ar:Log(string.format("  #%d %s [%s] %s powered=%s exotics=%d coupler=%s", i, entry.kind, tostring(entry.channel),
            fmtLoc(locationOf(entry.actor)), tostring(isPowered(entry.actor)), (exoticsIn(panelOf(entry.actor))),
            tostring(entry.kind == "Anchor" and hasCoupler(entry.actor))))
    end
    return true
end)

local VERSION = (okCfg and type(userConfig) == "table" and userConfig.Version) or "repo"
log("Massgate v%s loaded (dev=%s, channels=%s)", tostring(VERSION), tostring(DEV_MODE), table.concat(CONFIG.Channels, ","))
