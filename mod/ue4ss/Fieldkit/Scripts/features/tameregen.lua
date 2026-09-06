--[[
    Fieldkit feature: tameregen - faster out-of-combat healing for tames set to Follow.

    Icarus heals tames by a flat "health regen per minute" stat (10-50 depending on the species),
    so a 2,200 HP mount takes hours to recover. This feature heals every tame that is set to Follow
    and has not been in combat for a few seconds by a percentage of its MAXIMUM health each second,
    on top of the game's own regen. The rate scales with the creature talent "Nurtured Recovery":
    rank 4 gives the full rate, lower ranks their share of the top rank's bonus (5/15/30/60 % ->
    8/25/50/100 %), no talent gives nothing by default (NoTalentFraction).

    Custom World Settings rows (added by the Fieldkit pak, Creatures section):
      Fieldkit_TameRegen      Bool  on/off (default on)
      Fieldkit_TameRegenRate  Int   % of max health per MINUTE at rank 4, 1-60 (default 15 = 0.25 %/s)
    A prospect where the host never applied them runs on the defaults below.

    Health lives on the character's ActorState component (UCharacterState): GetHealth, GetMaxHealth,
    AddHealth (replicates), IsAlive, GetTotalRecentDamage. The talent rank comes from the mount's
    replicated talent list (UMountCharacterState.Talents, FBackendTalent = { RowName, Rank }).

    Console: `fieldkit tameregen` lists tames with health and why each is or is not healing;
    `fieldkit tameregen rate <percent per second>` overrides the rate until settings are applied again.
]]

local F = { id = "tameregen", title = "Tame Regeneration" }

local CONFIG = {
    PercentPerSecond    = 0.25,    -- % of max health per second at rank 4 when no rate setting is applied
    RequireFollow       = true,    -- only tames whose movement behaviour is Follow
    FollowState         = 1,       -- EMountMovementBehaviourState::Follow
    CombatGraceSeconds  = 10,      -- no healing this long after taking damage or having a target
    HealWhileRidden     = true,    -- a ridden mount on Follow still heals when out of combat
    RegenTalents        = {},      -- { talentRow = { bonus per rank } }, written by build.py from D_Talents
    TalentScaling       = "reward",-- "reward": rank bonus / top-rank bonus; "rank": rank / 4
    NoTalentFraction    = 0,       -- share of the rate for a tame without the talent
    TalentRefreshTicks  = 10,      -- re-read the tame's talent list this often (ranks change rarely)
    SettingEnabledRow   = "Fieldkit_TameRegen",
    SettingRateRow      = "Fieldkit_TameRegenRate",
}

local L            -- logger
local DEFAULT_RATE -- shipped/config rate, used when the prospect has no rate row
local manualRate = false
local enabled = true

function F.init(core, config)
    for k, v in pairs(config) do CONFIG[k] = v end
    L = core.logger(F.id)
    DEFAULT_RATE = CONFIG.PercentPerSecond
    L.log("%.2f%% of max health per second at Nurtured Recovery rank 4, %d s combat grace, %d talent rows",
        CONFIG.PercentPerSecond, CONFIG.CombatGraceSeconds, (function() local n = 0; for _ in pairs(CONFIG.RegenTalents) do n = n + 1 end; return n end)())
end

------------------------------------------------------------------------------------------
-- Tame state reads
------------------------------------------------------------------------------------------

local function stateOf(core, tame)
    local ok, state = pcall(function() return tame.ActorState end)
    if ok and core.valid(state) then return state end
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

local function hasTarget(core, tame)
    local ok, target = pcall(function() return tame.CurrentTarget end)
    return ok and core.valid(target)
end

local function recentDamage(state, seconds)
    local ok, dmg = pcall(function() return state:GetTotalRecentDamage(seconds) end)
    return ok and tonumber(dmg) or 0
end

-- Nurtured Recovery rank from the mount's replicated talent list. 0 = not unlocked.
local function talentRank(core, state)
    local rank, row = 0, nil
    local ok, err = pcall(function()
        local talents = state.Talents
        if talents == nil then return end
        talents:ForEach(function(_, elem)
            local t = core.unwrap(elem)
            local okN, name = pcall(function() return t.RowName:ToString() end)
            if okN and CONFIG.RegenTalents[name] then
                local okR, r = pcall(function() return tonumber(t.Rank) end)
                if okR and r and r > rank then rank, row = r, name end
            end
        end)
    end)
    if not ok then L.dbg("talent read failed: %s", tostring(err)) end
    return rank, row
end

-- Share of the rate this tame earns from its talent rank.
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
-- Per-tame state lives in entry.tameregen on the shared registry entry
------------------------------------------------------------------------------------------

local function stateFor(entry)
    if not entry.tameregen then
        entry.tameregen = { carry = 0, lastHealth = nil, damagedAt = -1e9, healing = false,
                            rank = 0, row = nil, factor = CONFIG.NoTalentFraction, talentAt = nil }
    end
    return entry.tameregen
end

local function refreshTalent(core, s, tame, state)
    local tick = core.tick()
    if s.talentAt and tick - s.talentAt < CONFIG.TalentRefreshTicks then return end
    s.talentAt = tick
    local rank, row = talentRank(core, state)
    local factor = talentFactor(rank, row)
    if rank ~= s.rank or factor ~= s.factor then
        L.dbg("%s: Nurtured Recovery rank %d (%s) -> %.0f%% of the heal rate", core.displayName(tame), rank,
            tostring(row), factor * 100)
    end
    s.rank, s.row, s.factor = rank, row, factor
end

local function graceTicks(core)
    return CONFIG.CombatGraceSeconds * 1000 / core.CONFIG.TickMs
end

local function eligible(core, s, tame, state)
    local tick = core.tick()
    if not core.hasAuthority(tame) then return false, "no authority" end
    if not enabled then return false, "off in Custom World Settings" end
    local okAlive, alive = pcall(function() return state:IsAlive() end)
    if not okAlive or alive ~= true then return false, "dead" end
    if not isFollowing(tame) then return false, "not on Follow" end
    if not CONFIG.HealWhileRidden and isRidden(tame) then return false, "ridden" end
    if hasTarget(core, tame) then
        s.damagedAt = tick -- an active target counts as combat; the grace period follows
        return false, "has target"
    end
    if tick - s.damagedAt < graceTicks(core) then return false, "recently in combat" end
    if recentDamage(state, CONFIG.CombatGraceSeconds) > 0 then
        s.damagedAt = tick
        return false, "recent damage"
    end
    refreshTalent(core, s, tame, state)
    if s.factor <= 0 then return false, "no Nurtured Recovery talent" end
    return true, "eligible"
end

------------------------------------------------------------------------------------------
-- Settings and tick
------------------------------------------------------------------------------------------

local function applySettings(core)
    local newEnabled = core.setting(CONFIG.SettingEnabledRow, 1) ~= 0
    local perMinute = core.setting(CONFIG.SettingRateRow, nil)
    local newRate = manualRate and CONFIG.PercentPerSecond or (perMinute and perMinute / 60 or DEFAULT_RATE)
    if newEnabled ~= enabled or newRate ~= CONFIG.PercentPerSecond then
        L.log("%s, %.3f%% of max health per second at rank 4 (%s)", newEnabled and "ON" or "OFF", newRate, core.settingsSource())
    end
    enabled, CONFIG.PercentPerSecond = newEnabled, newRate
end

function F.settingsChanged(core)
    manualRate = false
    applySettings(core)
end

function F.tick(core)
    applySettings(core) -- cheap table lookups; keeps the console override and defaults consistent
    local tick = core.tick()
    for _, entry in pairs(core.tames.all()) do
        local tame = entry.actor
        local state = core.valid(tame) and stateOf(core, tame) or nil
        if state then
            local s = stateFor(entry)
            local health, max = state:GetHealth(), state:GetMaxHealth()
            -- Our own damage detection: any drop in health since the last tick resets the grace.
            if s.lastHealth and health < s.lastHealth then s.damagedAt = tick end
            local ok, why = eligible(core, s, tame, state)
            if ok and health < max and max > 0 then
                local owed = max * CONFIG.PercentPerSecond * s.factor / 100 * (core.CONFIG.TickMs / 1000) + s.carry
                local amount = math.floor(owed)
                s.carry = owed - amount
                if amount > max - health then amount = max - health end
                if amount > 0 then
                    pcall(function() state:AddHealth(amount) end)
                    health = health + amount
                end
                if not s.healing then
                    s.healing = true
                    L.dbg("%s healing: %d/%d (+%d/s, talent rank %d = %.0f%%)", core.displayName(tame), health, max,
                        amount, s.rank, s.factor * 100)
                end
            else
                s.carry = 0
                if s.healing then
                    s.healing = false
                    L.dbg("%s stopped healing: %s (%d/%d)", core.displayName(tame), ok and "full" or why, health, max)
                end
            end
            s.lastHealth = health
        end
    end
end

------------------------------------------------------------------------------------------
-- Console
------------------------------------------------------------------------------------------

function F.status(core)
    return string.format("%s  %.3f%%/s at rank 4  grace %d s  %s", enabled and "ON" or "OFF",
        CONFIG.PercentPerSecond, CONFIG.CombatGraceSeconds, manualRate and "(console override)" or "")
end

function F.console(core, params, Ar)
    if params[1] == "rate" and tonumber(params[2]) then
        CONFIG.PercentPerSecond = tonumber(params[2])
        manualRate = true
        Ar:Log(string.format("[Fieldkit:tameregen] rate set to %.3f%% of max health per second (until Custom World Settings are applied again)", CONFIG.PercentPerSecond))
        L.log("rate set to %.3f%%/s from the console", CONFIG.PercentPerSecond)
        return
    end
    Ar:Log("[Fieldkit:tameregen] " .. F.status(core))
    for _, entry in pairs(core.tames.all()) do
        local tame = entry.actor
        local state = core.valid(tame) and stateOf(core, tame) or nil
        if state then
            local s = stateFor(entry)
            s.talentAt = nil
            refreshTalent(core, s, tame, state)
            local okS, move = pcall(function() return tonumber(tame.MovementBehaviourState) end)
            local ok, why = eligible(core, s, tame, state)
            Ar:Log(string.format("   %-24s %5d/%-5d move=%s ridden=%s target=%s recentDmg=%.0f talent=%d (%.0f%%, %s) -> %s",
                core.displayName(tame), state:GetHealth(), state:GetMaxHealth(), okS and tostring(move) or "?",
                tostring(isRidden(tame)), tostring(hasTarget(core, tame)), recentDamage(state, CONFIG.CombatGraceSeconds),
                s.rank, s.factor * 100, tostring(s.row), ok and "healing" or why))
        end
    end
    Ar:Log("[Fieldkit:tameregen] usage: fieldkit tameregen | fieldkit tameregen rate <percent per second>")
end

return F
