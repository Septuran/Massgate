--[[
    Fieldkit feature: scour - the Sonic Scourer clears snow, sand and ash off buildings.

    The game piles snow, sand or ash onto every building piece during storms (BP_Building_Base has a
    BPC_AccumulationComponent with Amount, AccumulationType and a ServerClear function). The Sonic
    Scourer is a craftable, powered deployable (Fieldkit pak: item, recipe, energy and inventory
    rows; placed as the small metal crate actor with the thumper mesh, like Massgate's gates). Every
    SampleSeconds it re-reads the build-up on every building piece within RadiusMetres and notes
    when each piece last grew. Every IntervalSeconds, while switched on and powered, it pulses:
    every piece whose build-up has been quiet for QuietSeconds (so a running storm is waited out)
    is cleared, and one matching cartridge from its hopper is spent per PiecesPerCartridge pieces
    of that type (Thermal Cartridge = snow, Cyclone Filter = sand, Scrubber Filter = ash). The
    first pulse after placement comes once the quiet time has passed, not a full interval later.

    Costs: power (D_Energy row, 1 kW while on), the cartridges, and the pulse interval. A --dev build
    sets DevMode = true in config.lua: no power and no cartridges needed.

    Custom World Settings rows (Misc): Fieldkit_Scour (on/off), Fieldkit_ScourInterval (seconds),
    Fieldkit_ScourRadius (metres).

    Registries (no object walks): building pieces from the spawn notification for BP_Building_Base_C,
    queued and registered a batch per tick; scourers from the small-crate notification filtered by
    item row. The core's one-time catch-up scan fills both after a reload. Each scourer keeps the
    list of pieces in its radius and recomputes it only when pieces were added since.

    Console: `fieldkit scour` (each scourer: power, cartridges, pieces in range, last pulse),
    `fieldkit scour pulse` (pulse now, ignoring the interval and the storm wait),
    `fieldkit scour probe` (the 15 nearest pieces with raw amount and type, to confirm the type
    numbers), `fieldkit scour scan`.

    Game API used: BPC_AccumulationComponent.Amount / .AccumulationType (read), :ServerClear() (no
    params); ResourceComponent:IsDeviceTurnedOn, EnergyComponent:IsConnectedAndReceivingFullFlow
    (as Massgate); UInventory:RemoveItem(slot, amount, false) for the cartridges (ints only).
]]

local F = { id = "scour", title = "Sonic Scourer" }

local CONFIG = {
    IntervalSeconds    = 180,     -- between pulses (the in-game row wins)
    RadiusMetres       = 25,      -- pulse reach (the in-game row wins)
    MinAmount          = 0.05,    -- build-up below this is ignored (Amount is roughly 0..1)
    SampleSeconds      = 20,      -- how often each scourer re-reads the build-up on its pieces
    QuietSeconds       = 60,      -- a piece is cleared once its build-up has not grown for this long
    GrowthTolerance    = 0.002,   -- growth below this between two samples counts as "not growing"
    PiecesPerCartridge = 10,      -- one cartridge per this many pieces cleared, per type, per pulse
    RequirePower       = true,
    RequireCartridge   = true,
    DevMode            = false,   -- written by build.py --dev: no power, no cartridges
    -- AccumulationType value -> what it is and which cartridge clears it. The enum is unnamed in
    -- the game (NewEnumerator0..3); 0 is taken as "none". `fieldkit scour probe` shows raw values.
    Types = {
        [1] = { name = "snow", cartridge = "Fieldkit_Cartridge_Snow" },
        [2] = { name = "sand", cartridge = "Fieldkit_Cartridge_Sand" },
        [3] = { name = "ash",  cartridge = "Fieldkit_Cartridge_Ash" },
    },
    ItemRow            = "Fieldkit_Scourer",
    BaseClass          = "/Game/BP/Objects/World/Items/Deployables/Containers/BP_Metal_Crate_Small.BP_Metal_Crate_Small_C",
    ScanClass          = "BP_Metal_Crate_Small_C",
    BuildingClass      = "/Game/BP/Building/BP_Building_Base.BP_Building_Base_C",
    BuildingScanClass  = "BP_Building_Base_C",
    ComponentProperty  = "BPC_AccumulationComponent",
    InventoryComponent = "/Script/Icarus.InventoryComponent",
    ResourceComponent  = "/Script/Icarus.ResourceComponent",
    Mesh               = "/Game/ASS/DEP/SM_DEP_Thumper_Mini.SM_DEP_Thumper_Mini",
    HideComponents     = { "DeployableSK", "SM_DEP_Crate_SML_Metal", "SM_DEP_Crate_SML_Metal1" },
    HopperSlots        = 6,
    RegisterPerTick    = 400,     -- building pieces taken off the spawn queue per tick
    SettleTicks        = 2,       -- ticks a spawned piece waits in the queue before it is touched
    PruneTicks         = 30,
    SettingEnabledRow  = "Fieldkit_Scour",
    SettingIntervalRow = "Fieldkit_ScourInterval",
    SettingRadiusRow   = "Fieldkit_ScourRadius",
}

local L, core
local enabled = true
local buildings = {}     -- full name -> { actor, loc, comp }
local buildingsGen = 0   -- bumped on registration; scourers recompute their piece lists when it changed
local pending = {}       -- spawn queue of building actors
local scourers = {}      -- full name -> { actor, name, inv, pieces, piecesGen, last = {piece full name -> amount},
                         --   quietSince = {piece full name -> tick}, sampleTick, lastPulse, firstPulseAt, powered, report }
local warned = {}
local meshCache = nil

local function valid(o) return core.valid(o) end
local function ticksOf(seconds) return math.ceil(seconds * 1000 / core.CONFIG.TickMs) end

local function once(key, fmt, ...)
    if warned[key] then return end
    warned[key] = true
    L.log(fmt, ...)
end

------------------------------------------------------------------------------------------
-- Building pieces
------------------------------------------------------------------------------------------

local function locationOf(actor)
    local ok, loc = pcall(function() return actor:K2_GetActorLocation() end)
    if ok and loc then return { X = loc.X, Y = loc.Y, Z = loc.Z } end
    return nil
end

local function distanceM(a, b)
    if not a or not b then return math.huge end
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz) / 100
end

local function countBuildings()
    local n = 0
    for _ in pairs(buildings) do n = n + 1 end
    return n
end

-- Only placed pieces in the level: the spawn notification also fires for class defaults, reinstanced
-- classes, placement ghosts and pieces the game replaces, some of which are gone again within a
-- tick. Touching one of those is a native crash, not a Lua error, so filter by name first.
local function isLevelActor(name)
    if not name:find(":PersistentLevel.", 1, true) then return false end
    if name:find("Default__", 1, true) or name:find("REINST_", 1, true) or name:find("TRASH", 1, true)
        or name:find("Preview", 1, true) or name:find("Ghost", 1, true) then return false end
    return true
end

local function registerBuilding(actor)
    if not valid(actor) then return end
    local name = core.fullName(actor)
    if buildings[name] or not isLevelActor(name) then return end
    local loc = locationOf(actor)
    if not loc then return end
    buildings[name] = { actor = actor, loc = loc }
    buildingsGen = buildingsGen + 1
end

-- Queued actors wait SettleTicks before they are touched, so construction has finished and
-- short-lived ones are already invalid (and skipped) by then.
local function drainPending()
    local n, tick = 0, core.tick()
    local keep = {}
    for i = #pending, 1, -1 do
        local item = pending[i]
        if n < CONFIG.RegisterPerTick and tick - item.tick >= CONFIG.SettleTicks then
            pending[i] = nil
            pcall(registerBuilding, item.actor)
            n = n + 1
        end
    end
    if n > 0 then
        -- compact the queue (entries were removed from the end first, but not only from the end)
        for _, item in ipairs(pending) do keep[#keep + 1] = item end
        pending = keep
        L.dbg("registered %d building piece(s), %d queued, %d total", n, #pending, countBuildings())
    end
end

local function accumulationOf(rec)
    if valid(rec.comp) then return rec.comp end
    rec.comp = nil
    pcall(function() rec.comp = rec.actor[CONFIG.ComponentProperty] end)
    return valid(rec.comp) and rec.comp or nil
end

local function readBuildup(rec)
    local comp = accumulationOf(rec)
    if not comp then return nil, nil end
    local amount, kind
    pcall(function() amount = tonumber(comp.Amount) end)
    pcall(function() kind = tonumber(comp.AccumulationType) end)
    return amount, kind
end

------------------------------------------------------------------------------------------
-- Scourers (small-crate actors carrying our item row)
------------------------------------------------------------------------------------------

local function rowOf(actor)
    local ok, row = pcall(function() return actor.ItemData.ItemStaticData.RowName:ToString() end)
    return ok and row or nil
end

local function loadMesh()
    if valid(meshCache) then return meshCache end
    local ok, mesh = pcall(StaticFindObject, CONFIG.Mesh)
    if not (ok and valid(mesh)) then
        ok, mesh = pcall(LoadAsset, CONFIG.Mesh)
        if not (ok and valid(mesh)) then
            local ok2, mesh2 = pcall(LoadAsset, (CONFIG.Mesh:gsub("%.[^./]+$", "")))
            if ok2 and valid(mesh2) then ok, mesh = ok2, mesh2 end
        end
    end
    if ok and valid(mesh) then meshCache = mesh; return mesh end
    once("mesh", "could not load the scourer mesh %s; it keeps the crate look", CONFIG.Mesh)
    return nil
end

-- Same trick as Massgate's gates: hide the crate's meshes and put ours on the static-mesh slot.
local function applyLook(actor)
    local ok, err = pcall(function()
        local mesh = loadMesh()
        if not mesh then return end
        local slot = actor.DeployableSM
        if not valid(slot) then error("no DeployableSM") end
        local slotName = core.fullName(slot)
        for _, name in ipairs(CONFIG.HideComponents) do
            local comp
            pcall(function() comp = core.unwrap(actor[name]) end)
            if valid(comp) and core.fullName(comp) ~= slotName then
                pcall(function() comp:SetVisibility(false, true) end)
                pcall(function() comp:SetHiddenInGame(true, true) end)
            end
        end
        pcall(function() slot:SetMobility(2) end)
        slot:SetStaticMesh(mesh)
        slot:SetVisibility(true, true)
        pcall(function() slot:SetHiddenInGame(false, true) end)
    end)
    if not ok then once("look", "scourer look failed: %s", tostring(err)) end
end

local function inventoryOf(rec)
    if valid(rec.inv) then return rec.inv end
    rec.inv = nil
    pcall(function()
        local cls = StaticFindObject(CONFIG.InventoryComponent)
        local comps = rec.actor:K2_GetComponentsByClass(cls)
        for i = 1, #comps do
            local comp = core.unwrap(comps[i])
            if valid(comp) then
                pcall(function()
                    comp.Inventories:ForEach(function(_, v)
                        local inv = v:get()
                        if not rec.inv and valid(inv) then rec.inv = inv end
                    end)
                end)
                if rec.inv then break end
            end
        end
    end)
    return rec.inv
end

-- Ported from Massgate: switched on, wired, and receiving its full draw.
local function isPowered(actor)
    local ok, powered = pcall(function()
        local cls = StaticFindObject(CONFIG.ResourceComponent)
        local comps = actor:K2_GetComponentsByClass(cls)
        if #comps == 0 then return nil end
        local res = core.unwrap(comps[1])
        if res:IsDeviceTurnedOn() ~= true then return false end
        local energy = res.EnergyComponent:Get()
        if not valid(energy) then return false end
        return energy:IsConnectedAndReceivingFullFlow() == true
    end)
    if ok and powered ~= nil then return powered end
    local ok2, running = pcall(function() return actor.bIsDeviceRunning end)
    return ok2 and running == true
end

local function registerScourer(actor, source)
    if not valid(actor) then return end
    local name = core.fullName(actor)
    if scourers[name] or name:find("Default__", 1, true) then return end
    if rowOf(actor) ~= CONFIG.ItemRow then return end
    local now = core.tick()
    scourers[name] = { actor = actor, name = "Sonic Scourer", last = {}, quietSince = {}, lastPulse = now, pulses = 0, cleared = 0,
        firstPulseAt = now + ticksOf(CONFIG.QuietSeconds + CONFIG.SampleSeconds) }
    core.setContext(actor)
    applyLook(actor)
    L.log("scourer registered (%s) at %s", source, (function() local l = locationOf(actor); return l and string.format("%.0f, %.0f, %.0f", l.X, l.Y, l.Z) or "?" end)())
end

local function countScourers()
    local n = 0
    for _ in pairs(scourers) do n = n + 1 end
    return n
end

local function prune()
    for name, rec in pairs(buildings) do if not valid(rec.actor) then buildings[name] = nil; buildingsGen = buildingsGen + 1 end end
    for name, rec in pairs(scourers) do if not valid(rec.actor) then scourers[name] = nil end end
end

-- Building pieces within the radius; cached until pieces were added or removed.
local function piecesOf(rec)
    if rec.pieces and rec.piecesGen == buildingsGen and rec.piecesRadius == CONFIG.RadiusMetres then return rec.pieces end
    local origin = locationOf(rec.actor)
    local list = {}
    if origin then
        for name, b in pairs(buildings) do
            if distanceM(origin, b.loc) <= CONFIG.RadiusMetres then list[#list + 1] = { name = name, rec = b } end
        end
    end
    rec.pieces, rec.piecesGen, rec.piecesRadius = list, buildingsGen, CONFIG.RadiusMetres
    L.dbg("scourer at %s: %d building piece(s) within %d m", origin and string.format("%.0f, %.0f", origin.X, origin.Y) or "?", #list, CONFIG.RadiusMetres)
    return list
end

-- Re-read the build-up on every piece in range and note when each one last grew. A pulse only
-- clears pieces that have been quiet for QuietSeconds, so a running storm is waited out. After a
-- long gap without samples (feature switched off, game paused) the history is dropped, or stale
-- quiet times would clear pieces in the middle of a storm.
local function sample(rec)
    local now = core.tick()
    if rec.sampleTick and now - rec.sampleTick > 3 * ticksOf(CONFIG.SampleSeconds) then rec.last, rec.quietSince = {}, {} end
    rec.sampleTick = now
    local growing, covered = 0, 0
    for _, p in ipairs(piecesOf(rec)) do
        if valid(p.rec.actor) then
            local amount = readBuildup(p.rec)
            if amount then
                local last = rec.last[p.name]
                if last == nil or amount > last + CONFIG.GrowthTolerance then
                    rec.quietSince[p.name] = now
                    if last ~= nil then growing = growing + 1 end
                end
                rec.last[p.name] = amount
                if amount > CONFIG.MinAmount then covered = covered + 1 end
            end
        end
    end
    rec.growing, rec.covered = growing, covered
    return growing, covered
end

-- Ready / waiting counts from the last sample, for the status line.
local function readiness(rec)
    local now, quiet = core.tick(), ticksOf(CONFIG.QuietSeconds)
    local ready, waiting = 0, 0
    for name, amount in pairs(rec.last) do
        if amount > CONFIG.MinAmount then
            if now - (rec.quietSince[name] or now) >= quiet then ready = ready + 1 else waiting = waiting + 1 end
        end
    end
    return ready, waiting
end

------------------------------------------------------------------------------------------
-- Cartridges in the hopper
------------------------------------------------------------------------------------------

local function stackOf(item)
    local count = 1
    pcall(function()
        local dyn = core.unwrap(item.ItemDynamicData)
        local function consider(entry)
            entry = core.unwrap(entry)
            local ptype, value
            pcall(function() ptype, value = entry.PropertyType, entry.Value end)
            if (tonumber(ptype) == 7 or tostring(ptype):find("ItemableStack", 1, true)) and tonumber(value) then count = tonumber(value) end
        end
        if type(dyn) == "table" then for _, e in pairs(dyn) do consider(e) end
        elseif type(dyn) == "userdata" and dyn.ForEach ~= nil then dyn:ForEach(function(_, e) consider(e) end) end
    end)
    return count
end

-- { slot, count } stacks of `row` in the hopper, and their total.
local function cartridgesIn(inv, row)
    local stacks, total = {}, 0
    if not valid(inv) then return stacks, 0 end
    for slot = 0, CONFIG.HopperSlots - 1 do
        -- Read through the live slot array, never a GetItem copy (see stow.lua slotItem).
        pcall(function()
            if inv:HasValidItemInSlot(slot) then
                local s = core.unwrap(inv.Slots.Slots[slot + 1])
                if s.ItemData.ItemStaticData.RowName:ToString() == row then
                    local n = stackOf(s.ItemData)
                    stacks[#stacks + 1] = { slot = slot, count = n }
                    total = total + n
                end
            end
        end)
    end
    return stacks, total
end

local function consumeCartridges(inv, row, amount)
    local stacks = cartridgesIn(inv, row)
    local left = amount
    for _, s in ipairs(stacks) do
        if left <= 0 then break end
        local take = math.min(left, s.count)
        local ok = pcall(function() inv:RemoveItem(s.slot, take, false) end)
        if ok then left = left - take end
    end
    return amount - left
end

------------------------------------------------------------------------------------------
-- The pulse
------------------------------------------------------------------------------------------

local function pulse(rec, force)
    rec.lastPulse = core.tick()
    rec.pulses = rec.pulses + 1
    L.dbg("pulse %d starting (%s)", rec.pulses, force and "forced" or "timer")
    local free = CONFIG.DevMode
    local powered = free or not CONFIG.RequirePower or isPowered(rec.actor)
    if powered ~= rec.powered then
        rec.powered = powered
        L.dbg("scourer %s", powered and "powered" or "unpowered or switched off")
    end
    if not powered then rec.report = "no power"; return end

    -- Pieces per type whose build-up has been quiet for QuietSeconds (fresh sample first).
    sample(rec)
    local now, quietTicks = core.tick(), ticksOf(CONFIG.QuietSeconds)
    local byType, seen, waiting = {}, 0, 0
    for _, p in ipairs(piecesOf(rec)) do
        local amount = rec.last[p.name]
        if amount and amount > CONFIG.MinAmount and valid(p.rec.actor) then
            seen = seen + 1
            if force or now - (rec.quietSince[p.name] or now) >= quietTicks then
                local _, kind = readBuildup(p.rec)
                byType[kind or 0] = byType[kind or 0] or {}
                table.insert(byType[kind or 0], p)
            else
                waiting = waiting + 1
            end
        end
    end
    L.dbg("pulse %d: %d piece(s) with build-up, %d waiting", rec.pulses, seen, waiting)

    local needCartridges = not free and CONFIG.RequireCartridge
    local inv = needCartridges and inventoryOf(rec) or nil
    if needCartridges and not inv then
        rec.report = "hopper inventory not found"
        once("hopper", "scourer hopper inventory not found; pulses skipped until it is")
        return
    end
    local parts, clearedTotal = {}, 0
    for kind, list in pairs(byType) do
        local spec = CONFIG.Types[kind]
        if not spec then
            once("type" .. tostring(kind), "build-up type %s has no cartridge mapping (fieldkit scour probe); skipped", tostring(kind))
        else
            local allowed = #list
            local cartridges = 0
            if inv then
                local _, have = cartridgesIn(inv, spec.cartridge)
                allowed = math.min(#list, have * CONFIG.PiecesPerCartridge)
                if allowed == 0 then
                    parts[#parts + 1] = string.format("%s: no %s in the hopper", spec.name, core.CONFIG.FeatureConfig.stow and (core.CONFIG.FeatureConfig.stow.ItemNames or {})[spec.cartridge] or spec.cartridge)
                end
            end
            local cleared = 0
            for i = 1, allowed do
                local comp = accumulationOf(list[i].rec)
                if comp and pcall(function() comp:ServerClear() end) then
                    cleared = cleared + 1
                    rec.last[list[i].name], rec.quietSince[list[i].name] = nil, nil
                end
            end
            if cleared > 0 and inv then
                cartridges = consumeCartridges(inv, spec.cartridge, math.ceil(cleared / CONFIG.PiecesPerCartridge))
            end
            if cleared > 0 then
                clearedTotal = clearedTotal + cleared
                parts[#parts + 1] = string.format("%d piece(s) of %s%s", cleared, spec.name,
                    inv and string.format(", %d cartridge(s)", cartridges) or "")
            end
        end
    end
    rec.cleared = rec.cleared + clearedTotal
    if #parts > 0 then
        rec.report = table.concat(parts, "; ")
        core.tell("Scourer: " .. rec.report)
        rec.toldWaiting = false
    elseif waiting > 0 then
        rec.report = string.format("%d piece(s) still gaining build-up; waiting for the storm to pass", waiting)
        L.dbg(rec.report)
        -- once per storm, not every pulse
        if not rec.toldWaiting then core.tell("Scourer: " .. rec.report); rec.toldWaiting = true end
    else
        rec.report = seen > 0 and "nothing ready" or "clean"
        rec.toldWaiting = false
    end
end

------------------------------------------------------------------------------------------
-- Feature contract
------------------------------------------------------------------------------------------

local function applySettings()
    local newEnabled = core.setting(CONFIG.SettingEnabledRow, 1) ~= 0
    local interval = core.setting(CONFIG.SettingIntervalRow, nil) or CONFIG.IntervalSeconds
    local radius = core.setting(CONFIG.SettingRadiusRow, nil) or CONFIG.RadiusMetres
    if newEnabled ~= enabled or interval ~= CONFIG.IntervalSeconds or radius ~= CONFIG.RadiusMetres then
        L.log("%s, pulse every %s s, range %s m (%s)", newEnabled and "ON" or "OFF", tostring(interval), tostring(radius), core.settingsSource())
    end
    enabled, CONFIG.IntervalSeconds, CONFIG.RadiusMetres = newEnabled, interval, radius
end

function F.init(coreRef, config)
    core = coreRef
    for k, v in pairs(config) do CONFIG[k] = v end
    L = core.logger(F.id)
    L.log("pulse every %d s, range %d m, %d pieces per cartridge%s", CONFIG.IntervalSeconds, CONFIG.RadiusMetres,
        CONFIG.PiecesPerCartridge, CONFIG.DevMode and "  [DEV MODE: no power, no cartridges]" or "")
    pcall(NotifyOnNewObject, CONFIG.BuildingClass, function(actor)
        pending[#pending + 1] = { actor = actor, tick = core.tick() }
    end)
    pcall(NotifyOnNewObject, CONFIG.BaseClass, function(actor)
        ExecuteWithDelay(500, function()
            ExecuteInGameThread(function() pcall(registerScourer, actor, "spawn") end)
        end)
    end)
end

function F.settingsChanged() applySettings() end

function F.rescan(_, reason)
    local okB, list = pcall(FindAllOf, CONFIG.BuildingScanClass)
    local nb = 0
    if okB and list then
        for _, actor in ipairs(list) do pending[#pending + 1] = { actor = actor, tick = core.tick() }; nb = nb + 1 end
    end
    local okS, crates = pcall(FindAllOf, CONFIG.ScanClass)
    local ns = 0
    if okS and crates then for _, actor in ipairs(crates) do registerScourer(actor, "scan:" .. reason); ns = ns + 1 end end
    return string.format("%d building piece(s) queued, %d crate(s) seen, %d scourer(s)", nb, ns, countScourers())
end

function F.tick()
    applySettings()
    drainPending()
    local tick = core.tick()
    if tick % CONFIG.PruneTicks == 0 then prune() end
    if not enabled then return end
    local intervalTicks, sampleTicks = ticksOf(CONFIG.IntervalSeconds), ticksOf(CONFIG.SampleSeconds)
    for _, rec in pairs(scourers) do
        if valid(rec.actor) and core.hasAuthority(rec.actor) then
            if rec.sampleTick == nil or tick - rec.sampleTick >= sampleTicks then sample(rec) end
            local due = rec.firstPulseAt or (rec.lastPulse + intervalTicks)
            if tick >= due then
                rec.firstPulseAt = nil
                pulse(rec, false)
            end
        end
    end
end

function F.status()
    return string.format("%s  every %d s  range %d m  %d scourer(s)  %d building piece(s)%s", enabled and "ON" or "OFF",
        CONFIG.IntervalSeconds, CONFIG.RadiusMetres, countScourers(), countBuildings(), CONFIG.DevMode and "  DEV" or "")
end

function F.console(_, params, Ar)
    local word = params[1]
    if word == "scan" then Ar:Log("[Fieldkit:scour] " .. F.rescan(nil, "console")); return end
    if word == "pulse" then
        local n = 0
        for _, rec in pairs(scourers) do
            if valid(rec.actor) then pulse(rec, true); n = n + 1; Ar:Log("[Fieldkit:scour] pulse: " .. tostring(rec.report)); L.log("forced pulse: %s", tostring(rec.report)) end
        end
        if n == 0 then Ar:Log("[Fieldkit:scour] no scourer placed") end
        return
    end
    if word == "probe" then
        local controller = core.controller()
        local pawn
        pcall(function() pawn = controller.Pawn end)
        local origin = valid(pawn) and locationOf(pawn) or nil
        local list = {}
        for name, b in pairs(buildings) do
            if valid(b.actor) then
                local d = distanceM(origin, b.loc)
                if d < 60 then list[#list + 1] = { d = d, name = name, rec = b } end
            end
        end
        table.sort(list, function(a, b) return a.d < b.d end)
        L.log("probe: %d piece(s) within 60 m of the player", #list)
        for i = 1, math.min(15, #list) do
            local amount, kind = readBuildup(list[i].rec)
            local line = string.format("   %5.1f m  %-40s amount=%s type=%s", list[i].d, core.shortName(list[i].rec.actor), tostring(amount), tostring(kind))
            Ar:Log(line); L.log("%s", line)
        end
        Ar:Log(string.format("[Fieldkit:scour] %d piece(s) within 60 m (%d registered); type numbers map through FeatureConfig.scour.Types", #list, countBuildings()))
        return
    end
    Ar:Log("[Fieldkit:scour] " .. F.status())
    for _, rec in pairs(scourers) do
        if valid(rec.actor) then
            local inv = inventoryOf(rec)
            local carts = {}
            for kind, spec in pairs(CONFIG.Types) do
                local _, n = cartridgesIn(inv, spec.cartridge)
                carts[#carts + 1] = string.format("%s %d", spec.name, n)
            end
            table.sort(carts)
            local due = rec.firstPulseAt or (rec.lastPulse + ticksOf(CONFIG.IntervalSeconds))
            local nextIn = math.max(0, (due - core.tick()) * core.CONFIG.TickMs / 1000)
            local ready, waiting = readiness(rec)
            local line = string.format("   powered=%s  pieces in range=%d (%d ready, %d still gaining)  hopper: %s  pulses=%d cleared=%d  next in %.0f s  last: %s",
                tostring(CONFIG.DevMode or isPowered(rec.actor)), #piecesOf(rec), ready, waiting, table.concat(carts, ", "), rec.pulses, rec.cleared, nextIn, tostring(rec.report))
            Ar:Log(line); L.log("%s", line)
        end
    end
    Ar:Log("[Fieldkit:scour] usage: fieldkit scour | pulse | probe | scan")
end

return F
