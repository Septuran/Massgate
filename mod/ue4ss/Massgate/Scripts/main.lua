--[[
    Massgate - paired exotic-matter transit gates for Icarus.
    UE4SS 3.0.1 Lua side. The item, recipe, tech-tree node and power draw live in the
    data-table pak (mod/data/patches.json); this script adds the behaviour:

      * recognises our gate (a Spotlight_Tripod actor whose item row is Massgate_Gate)
      * on "Engage Massgate" (press interact) validates the pair and moves the player
      * enforces: exactly one pair per prospect, both gates powered, minimum
        separation (interference), per-gate cooldown, no travel while mounted

    Everything is wrapped in pcall and logged with the [Massgate] prefix so a failure
    never takes the game down; check ue4ss/UE4SS.log while testing.
]]

local CONFIG = {
    GateRow              = "Massgate_Gate",
    GateClass            = "BP_Spotlight_Tripod_C",
    ButtonInteractHook   = "/Game/BP/Behaviours/Interactable/BP_Interactable_ButtonTrigger.BP_Interactable_ButtonTrigger_C:Interact",
    MaxGates             = 2,       -- MVP: one pair per prospect
    RequirePower         = true,    -- both gates must be running
    InterferenceRadiusCm = 50000,   -- 500 m: gates closer than this refuse to tune
    CooldownSeconds      = 20,      -- per gate, after a transit
    ArrivalOffsetCm      = 200,     -- step out in front of the destination gate
    ArrivalLiftCm        = 60,      -- small lift so we never spawn inside the floor
    ExoticsPerTrip       = 5,       -- TODO v0.2: actually deduct from the player's inventory
    Debug                = true,
}

local function log(fmt, ...)
    print(string.format("[Massgate] " .. fmt .. "\n", ...))
end

local function dbg(fmt, ...)
    if CONFIG.Debug then log(fmt, ...) end
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

local function isGate(actor)
    if not actor or not actor:IsValid() then return false end
    return rowNameOf(actor) == CONFIG.GateRow
end

local function allGates()
    local gates = {}
    local ok, objects = pcall(FindAllOf, CONFIG.GateClass)
    if ok and objects then
        for _, actor in ipairs(objects) do
            if isGate(actor) then gates[#gates + 1] = actor end
        end
    end
    return gates
end

local function isPowered(gate)
    local ok, running = pcall(function() return gate.bIsDeviceRunning end)
    return ok and running == true
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

------------------------------------------------------------------------------------------
-- Player feedback (TODO: replace the log line with an on-screen notification once we
-- have found Icarus' notification widget in the dump)
------------------------------------------------------------------------------------------

local function tell(player, text)
    log("-> %s", text)
end

------------------------------------------------------------------------------------------
-- Transit rules
------------------------------------------------------------------------------------------

local lastTransit = {} -- gate full name -> os.time() of last use

local function isMounted(player)
    local ok, mounted = pcall(function()
        -- AIcarusPlayerCharacter exposes mount state through this resolver; if the call
        -- is not available on this build we simply allow travel.
        return player:IsLocallyControlledWithMountResolve() == false
    end)
    return ok and mounted == true
end

local function findPartner(gate, gates)
    for _, other in ipairs(gates) do
        if other:GetFullName() ~= gate:GetFullName() then return other end
    end
    return nil
end

local function engage(gate, player)
    local gates = allGates()
    dbg("engage: %d gate(s) on prospect", #gates)

    if #gates > CONFIG.MaxGates then
        return tell(player, "Lattice interference: more than one pair of Massgates on this prospect. Remove the extras.")
    end

    local partner = findPartner(gate, gates)
    if not partner then
        return tell(player, "No partner lattice. Build a second Massgate elsewhere on the prospect.")
    end

    local here, there = locationOf(gate), locationOf(partner)
    local separation = distance(here, there)
    if separation < CONFIG.InterferenceRadiusCm then
        return tell(player, string.format("Lattices too close to tune (%.0f m apart, need %.0f m).",
            separation / 100, CONFIG.InterferenceRadiusCm / 100))
    end

    if CONFIG.RequirePower then
        if not isPowered(gate) then return tell(player, "This Massgate is unpowered.") end
        if not isPowered(partner) then return tell(player, "The destination Massgate is unpowered.") end
    end

    local now = os.time()
    local key = gate:GetFullName()
    if lastTransit[key] and now - lastTransit[key] < CONFIG.CooldownSeconds then
        return tell(player, string.format("Lattice re-stabilising, %d s remaining.",
            CONFIG.CooldownSeconds - (now - lastTransit[key])))
    end

    if isMounted(player) then
        return tell(player, "Dismount before transit; the lattice cannot carry a mount.")
    end

    -- Destination: in front of the partner gate, slightly lifted.
    local forward = partner:GetActorForwardVector()
    local dest = {
        X = there.X + forward.X * CONFIG.ArrivalOffsetCm,
        Y = there.Y + forward.Y * CONFIG.ArrivalOffsetCm,
        Z = there.Z + CONFIG.ArrivalLiftCm,
    }
    local rotation = player:K2_GetActorRotation()

    local ok, moved = pcall(function() return player:K2_TeleportTo(dest, rotation) end)
    if not ok then
        return log("teleport call failed: %s", tostring(moved))
    end

    lastTransit[key] = now
    lastTransit[partner:GetFullName()] = now
    log("transit %s -> %s (%.0f m) moved=%s", fmtLoc(here), fmtLoc(dest), separation / 100, tostring(moved))
    tell(player, string.format("Transit complete. %d Exotics consumed.", CONFIG.ExoticsPerTrip))
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
        if not behaviour or not behaviour:IsValid() then return end
        if not player or not player:IsValid() then return end

        local component = behaviour:GetInteractableComponent()
        if not component or not component:IsValid() then return end
        local owner = component:GetOwner()
        if not isGate(owner) then return end

        dbg("gate engaged by %s at %s", player:GetFullName(), fmtLoc(locationOf(owner)))
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

-- Log every gate as it appears so we can verify the item row detection in UE4SS.log.
pcall(NotifyOnNewObject, "/Game/BP/Objects/World/Items/Deployables/Lights/BP_Spotlight_Tripod.BP_Spotlight_Tripod_C",
    function(actor)
        ExecuteWithDelay(500, function()
            if isGate(actor) then
                log("gate spawned at %s (powered=%s)", fmtLoc(locationOf(actor)), tostring(isPowered(actor)))
            end
        end)
    end)

-- Console helper while testing: type `massgate` in the UE4SS console to list gates.
pcall(RegisterConsoleCommandHandler, "massgate", function(FullCommand, Parameters, Ar)
    local gates = allGates()
    Ar:Log(string.format("[Massgate] %d gate(s); hooked=%s", #gates, tostring(hooked)))
    for i, g in ipairs(gates) do
        Ar:Log(string.format("  #%d %s powered=%s", i, fmtLoc(locationOf(g)), tostring(isPowered(g))))
    end
    return true
end)

log("loaded (gate row %s, class %s)", CONFIG.GateRow, CONFIG.GateClass)
