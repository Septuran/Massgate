--[[
    TameRegen - faster out-of-combat healing for tames set to Follow.
    UE4SS 3.0.1 Lua side; no data-table changes.

    Icarus heals tames by a flat "health regen per minute" stat (10-50 depending on the species),
    so a 2,200 HP mount takes hours to recover. This mod heals every tame that is set to Follow
    and has not been in combat for a few seconds by a percentage of its MAXIMUM health each
    second (default 0.5 %/s = full health in about 3.5 minutes), on top of the game's own regen.
    The rate scales with the creature talent "Nurtured Recovery": rank 4 gives the full rate,
    lower ranks their share of the top rank's bonus (5/15/30/60 % -> 8/25/50/100 %), no talent
    gives nothing by default (NoTalentFraction).

    How it works:
      * Tames are collected from the game's spawn notifications for BP_Mount_Base_C (every mount
        and pet, farm animals included, derives from it). No object-table walks: the registry is
        filled as actors are constructed and pruned when they go away.
      * Once a second, for each registered tame that we have authority over: alive, set to Follow,
        no current attack target, no damage taken in the last CombatGraceSeconds -> add
        PercentPerSecond of max health through the game's own UActorState:AddHealth, which also
        replicates it to clients.
      * Runs only where the game has authority (solo, host, or a UE4SS dedicated server).

    Console (needs a console enabler): `tameregen` lists the known tames and their state,
    `tameregen rate <percent>` changes the rate for this session, `tameregen scan` does a
    one-off FindAllOf to pick up tames that spawned before the mod hooked in (diagnostic only,
    it walks the object table once).

    Everything is wrapped in pcall and logged with the [TameRegen] prefix.
]]

local CONFIG = {
    PercentPerSecond    = 0.5,     -- % of max health healed per second while eligible
    TickMs              = 1000,
    RequireFollow       = true,    -- only tames whose movement behaviour is Follow
    FollowState         = 1,       -- EMountMovementBehaviourState::Follow
    CombatGraceSeconds  = 10,      -- no healing this long after taking damage or having a target
    HealWhileRidden     = true,    -- a ridden mount on Follow still heals when out of combat
    -- The heal scales with the creature talent "Nurtured Recovery" (one D_Talents row per species,
    -- 4 ranks, e.g. +5/+15/+30/+60 % regen). RegenTalents = { rowName = { bonus per rank } } is
    -- written by build.py. "reward": factor = this rank's bonus / top rank's bonus (8/25/50/100 %);
    -- "rank": factor = rank / 4. Top rank always gives the full PercentPerSecond.
    RegenTalents        = {},
    TalentScaling       = "reward",
    NoTalentFraction    = 0,       -- share of PercentPerSecond for a tame without the talent
    TalentRefreshTicks  = 10,      -- re-read the tame's talent list this often (ranks change rarely)
    BaseClass           = "/Game/BP/Mounts/BP_Mount_Base.BP_Mount_Base_C",
    MountClasses        = {},      -- concrete classes, written by build.py (belt and braces: the
                                   -- base-class notification already covers subclasses)
    ScanClass           = "BP_Mount_Base_C", -- for the explicit `tameregen scan` command only
    Version             = "dev",
    Debug               = true,
}

local function log(fmt, ...)
    print(string.format("[TameRegen] " .. fmt .. "\n", ...))
end

local function dbg(fmt, ...)
    if CONFIG.Debug then log(fmt, ...) end
end

-- config.lua (written by tools/build.py --install) may override any CONFIG key.
local okCfg, userConfig = pcall(require, "config")
if okCfg and type(userConfig) == "table" then
    for key, value in pairs(userConfig) do CONFIG[key] = value end
else
    log("config.lua not found or invalid (%s); using shipped defaults", tostring(userConfig))
end
log("TameRegen v%s loaded: %.2f%% of max health per second for tames on Follow, %d s combat grace",
    tostring(CONFIG.Version), CONFIG.PercentPerSecond, CONFIG.CombatGraceSeconds)

------------------------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------------------------

local function valid(obj)
    return obj ~= nil and obj:IsValid()
end

local function fullName(obj)
    local ok, name = pcall(function() return obj:GetFullName() end)
    return ok and name or "?"
end

local function shortName(obj)
    return fullName(obj):match("[^%.]+$") or "?"
end

local function hasAuthority(actor)
    local ok, auth = pcall(function() return actor:HasAuthority() end)
    return ok and auth == true
end

local function displayName(tame)
    local ok, name = pcall(function() return tame.MountName:ToString() end)
    if ok and name and name ~= "" then return name end
    return shortName(tame)
end

-- The game's health lives on the character's ActorState component (UCharacterState).
local function stateOf(tame)
    local ok, state = pcall(function() return tame.ActorState end)
    if ok and valid(state) then return state end
    return nil
end

local function isFollowing(tame)
    if not CONFIG.RequireFollow then return true end
    local ok, state = pcall(function() return tame.MovementBehaviourState end)
    return ok and tonumber(state) == CONFIG.FollowState
end

local function isRidden(tame)
    local ok, ridden = pcall(function() return tame:IsBeingRidden() end)
    return ok and ridden == true
end

local function hasTarget(tame)
    local ok, target = pcall(function() return tame.CurrentTarget end)
    return ok and valid(target)
end

local function recentDamage(state, seconds)
    local ok, dmg = pcall(function() return state:GetTotalRecentDamage(seconds) end)
    return ok and tonumber(dmg) or 0
end

-- UE4SS hands back RemoteUnrealParam wrappers for array elements; the value is behind :get().
local function unwrap(v)
    if type(v) == "userdata" then
        local ok, inner = pcall(function() return v:get() end)
        if ok and inner ~= nil then return inner end
    end
    return v
end

-- Nurtured Recovery rank from the mount's replicated talent list (UMountCharacterState.Talents,
-- FBackendTalent = { RowName, Rank }). Returns rank (0 = not unlocked) and the talent row name.
local function talentRank(state)
    local rank, row = 0, nil
    local ok, err = pcall(function()
        local talents = state.Talents
        if talents == nil then return end
        talents:ForEach(function(_, elem)
            local t = unwrap(elem)
            local okN, name = pcall(function() return t.RowName:ToString() end)
            if okN and CONFIG.RegenTalents[name] then
                local okR, r = pcall(function() return tonumber(t.Rank) end)
                if okR and r and r > rank then rank, row = r, name end
            end
        end)
    end)
    if not ok then dbg("talent read failed: %s", tostring(err)) end
    return rank, row
end

-- Share of PercentPerSecond this tame earns from its talent rank.
local function talentFactor(rank, row)
    if rank <= 0 or not row then return CONFIG.NoTalentFraction end
    local rewards = CONFIG.RegenTalents[row]
    if CONFIG.TalentScaling == "rank" or not rewards or #rewards == 0 then
        return math.min(rank, 4) / 4
    end
    local top = rewards[#rewards]
    local mine = rewards[math.min(rank, #rewards)]
    if not top or top <= 0 then return 1 end
    return math.min(mine / top, 1)
end

------------------------------------------------------------------------------------------
-- Registry: full name -> { actor, carry (fractional HP owed), lastHealth, damagedAt, healing,
--                          rank, row, factor, talentAt (tick of the last talent read) }
------------------------------------------------------------------------------------------

local registry = {}
local tick = 0           -- one per TickMs; timestamps below are in ticks

local function register(actor, source)
    if not valid(actor) then return end
    local key = fullName(actor)
    if registry[key] or key:find("Default__", 1, true) then return end -- skip class default objects
    registry[key] = { actor = actor, carry = 0, lastHealth = nil, damagedAt = -1e9, healing = false,
                      rank = 0, row = nil, factor = CONFIG.NoTalentFraction, talentAt = nil }
    dbg("registered %s (%s) via %s", displayName(actor), shortName(actor), source)
end

local function refreshTalent(entry, tame, state)
    if entry.talentAt and tick - entry.talentAt < CONFIG.TalentRefreshTicks then return end
    entry.talentAt = tick
    local rank, row = talentRank(state)
    local factor = talentFactor(rank, row)
    if rank ~= entry.rank or factor ~= entry.factor then
        dbg("%s: Nurtured Recovery rank %d (%s) -> %.0f%% of the heal rate", displayName(tame), rank,
            tostring(row), factor * 100)
    end
    entry.rank, entry.row, entry.factor = rank, row, factor
end

local function count()
    local n = 0
    for _ in pairs(registry) do n = n + 1 end
    return n
end

------------------------------------------------------------------------------------------
-- Heal tick
------------------------------------------------------------------------------------------

local function graceTicks()
    return CONFIG.CombatGraceSeconds * 1000 / CONFIG.TickMs
end

local function eligible(entry, tame, state)
    if not hasAuthority(tame) then return false, "no authority" end
    local okAlive, alive = pcall(function() return state:IsAlive() end)
    if not okAlive or alive ~= true then return false, "dead" end
    if not isFollowing(tame) then return false, "not on Follow" end
    if not CONFIG.HealWhileRidden and isRidden(tame) then return false, "ridden" end
    if hasTarget(tame) then
        entry.damagedAt = tick -- an active target counts as combat; the grace period follows
        return false, "has target"
    end
    if tick - entry.damagedAt < graceTicks() then
        return false, "recently in combat"
    end
    if recentDamage(state, CONFIG.CombatGraceSeconds) > 0 then
        entry.damagedAt = tick
        return false, "recent damage"
    end
    refreshTalent(entry, tame, state)
    if entry.factor <= 0 then return false, "no Nurtured Recovery talent" end
    return true, "eligible"
end

local function healTick()
    tick = tick + 1
    for key, entry in pairs(registry) do
        local tame = entry.actor
        if not valid(tame) then
            registry[key] = nil
        else
            local state = stateOf(tame)
            if state then
                local health, max = state:GetHealth(), state:GetMaxHealth()
                -- Our own damage detection: any drop in health since the last tick resets the grace.
                if entry.lastHealth and health < entry.lastHealth then entry.damagedAt = tick end
                local ok, why = eligible(entry, tame, state)
                if ok and health < max and max > 0 then
                    local owed = max * CONFIG.PercentPerSecond * entry.factor / 100 * (CONFIG.TickMs / 1000) + entry.carry
                    local amount = math.floor(owed)
                    entry.carry = owed - amount
                    if amount > max - health then amount = max - health end
                    if amount > 0 then
                        pcall(function() state:AddHealth(amount) end)
                        health = health + amount
                    end
                    if not entry.healing then
                        entry.healing = true
                        dbg("%s healing: %d/%d (+%d/s, talent rank %d = %.0f%%)", displayName(tame), health, max,
                            amount, entry.rank, entry.factor * 100)
                    end
                else
                    entry.carry = 0
                    if entry.healing then
                        entry.healing = false
                        dbg("%s stopped healing: %s (%d/%d)", displayName(tame), ok and "full" or why, health, max)
                    end
                end
                entry.lastHealth = health
            end
        end
    end
end

LoopAsync(CONFIG.TickMs, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(healTick)
        if not ok then log("heal tick failed: %s", tostring(err)) end
    end)
    return false
end)

------------------------------------------------------------------------------------------
-- Spawn notifications (inheritance-aware: the base class alone catches every tame)
------------------------------------------------------------------------------------------

local function watch(classPath)
    local ok, err = pcall(NotifyOnNewObject, classPath, function(actor)
        -- Give the actor a moment to finish construction before we touch it.
        ExecuteWithDelay(1000, function()
            ExecuteInGameThread(function() pcall(register, actor, "spawn") end)
        end)
    end)
    if not ok then dbg("could not watch %s (%s)", classPath, tostring(err)) end
end

watch(CONFIG.BaseClass)
for _, classPath in ipairs(CONFIG.MountClasses) do watch(classPath) end

------------------------------------------------------------------------------------------
-- Console
------------------------------------------------------------------------------------------

pcall(RegisterConsoleCommandHandler, "tameregen", function(FullCommand, Parameters, Ar)
    if Parameters[1] == "rate" and tonumber(Parameters[2]) then
        CONFIG.PercentPerSecond = tonumber(Parameters[2])
        Ar:Log(string.format("[TameRegen] rate set to %.2f%% of max health per second (this session only)", CONFIG.PercentPerSecond))
        log("rate set to %.2f%%/s from the console", CONFIG.PercentPerSecond)
        return true
    end
    if Parameters[1] == "scan" then
        -- Diagnostic only: walks the object table once to pick up tames that spawned before the mod hooked in.
        local ok, mounts = pcall(FindAllOf, CONFIG.ScanClass)
        local n = 0
        if ok and mounts then
            for _, actor in ipairs(mounts) do register(actor, "scan"); n = n + 1 end
        end
        Ar:Log(string.format("[TameRegen] scan found %d %s actors; %d registered", n, CONFIG.ScanClass, count()))
        return true
    end
    Ar:Log(string.format("[TameRegen] v%s  rate %.2f%%/s  grace %d s  tick %d  tames %d",
        tostring(CONFIG.Version), CONFIG.PercentPerSecond, CONFIG.CombatGraceSeconds, tick, count()))
    for _, entry in pairs(registry) do
        local tame = entry.actor
        if valid(tame) then
            local state = stateOf(tame)
            local hp, max = -1, -1
            if state then hp, max = state:GetHealth(), state:GetMaxHealth() end
            local okS, move = pcall(function() return tonumber(tame.MovementBehaviourState) end)
            local ok, why = true, "eligible"
            if state then ok, why = eligible(entry, tame, state) end
            if state then entry.talentAt = nil; refreshTalent(entry, tame, state) end
            Ar:Log(string.format("   %-24s %5d/%-5d move=%s ridden=%s target=%s recentDmg=%.0f talent=%d (%.0f%%, %s) -> %s",
                displayName(tame), hp, max, okS and tostring(move) or "?", tostring(isRidden(tame)),
                tostring(hasTarget(tame)), state and recentDamage(state, CONFIG.CombatGraceSeconds) or 0,
                entry.rank, entry.factor * 100, tostring(entry.row), ok and "healing" or why))
        end
    end
    Ar:Log("[TameRegen] usage: tameregen | tameregen rate <percent> | tameregen scan")
    return true
end)
