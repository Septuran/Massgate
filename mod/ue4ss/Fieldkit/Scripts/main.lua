--[[
    Fieldkit - a kit of small quality-of-life features for Icarus.
    UE4SS 3.0.1 Lua. Each feature is one file under Scripts/features/ and one or more rows in the
    game's Custom World Settings screen (Escape -> Custom World Settings, host only), added by the
    Fieldkit pak (mod/data/fieldkit_patches.json). The game renders, saves and replicates those
    settings; this core reads them from the ProspectSubsystem and hands them to the features.

    Features (Scripts/features/<id>.lua, listed in CONFIG.Features):
      * tameregen : tames set to Follow heal a share of their maximum health every second while out
                    of combat, scaled by their Nurtured Recovery talent rank.
      * stow      : pin chests to item types (open the chest, Shift+P) and put the backpack away
                    into the pinned chests nearby with one key (Shift+E).

    The core owns:
      * the tick (once a second on the game thread), with every feature call wrapped in pcall;
      * the Custom World Settings reader (re-read every SettingsRefreshTicks and right after the
        host presses Apply, via a hook on ProspectSubsystem:SetCustomProspectSettings);
      * the tame registry, shared by features: filled from the game's spawn notifications for
        BP_Mount_Base_C (every mount, pet and farm animal derives from it), pruned as actors go.
        No object-table walks (see README); the explicit `fieldkit scan` console command is the
        one exception, for diagnostics;
      * the console: `fieldkit` (overview), `fieldkit tames`, `fieldkit scan`,
        `fieldkit <feature> ...` (handed to the feature).

    Everything logs with the [Fieldkit] prefix (features: [Fieldkit:<id>]). Gameplay runs only where
    the game has authority (solo, host, or a UE4SS dedicated server).

    A feature module returns a table:
      id, title                       -- id = file name = console word
      init(core, config)              -- once, after config.lua is merged; config = its FeatureConfig
      tick(core)                      -- every core tick
      settingsChanged(core)           -- after the host applied Custom World Settings (optional)
      console(core, params, Ar)       -- `fieldkit <id> ...` (optional)
      status(core) -> string          -- one line for the `fieldkit` overview (optional)
]]

local CONFIG = {
    TickMs               = 1000,
    Features             = { "tameregen", "stow" },
    FeatureConfig        = {},       -- per-feature overrides, e.g. FeatureConfig.tameregen.PercentPerSecond
    -- Custom World Settings
    CustomWorldSettings  = true,     -- false: features run on their own defaults only
    SettingsRefreshTicks = 5,        -- re-read this often (a handful of array reads)
    SubsystemClass       = "/Script/Icarus.ProspectSubsystem",
    SubsystemLibrary     = "/Script/Engine.Default__SubsystemBlueprintLibrary",
    SubsystemSetHook     = "/Script/Icarus.ProspectSubsystem:SetCustomProspectSettings",
    -- Tame registry
    Tames = {
        BaseClass    = "/Game/BP/Mounts/BP_Mount_Base.BP_Mount_Base_C",
        MountClasses = {},           -- concrete classes, written by build.py from D_AISetup (belt and
                                     -- braces: the base-class notification already covers subclasses)
        ScanClass    = "BP_Mount_Base_C",
    },
    Version              = "dev",
    Debug                = true,
}

local function log(fmt, ...)
    print(string.format("[Fieldkit] " .. fmt .. "\n", ...))
end

local function dbg(fmt, ...)
    if CONFIG.Debug then log(fmt, ...) end
end

-- Deep-merge config.lua (written by tools/build.py --install) into CONFIG. Tables merge key by
-- key; lists (integer keys) are replaced whole.
local function isList(t)
    return type(t) == "table" and (#t > 0 or next(t) == nil)
end

local function merge(dst, src)
    for key, value in pairs(src) do
        if type(value) == "table" and type(dst[key]) == "table" and not isList(value) and not isList(dst[key]) then
            merge(dst[key], value)
        else
            dst[key] = value
        end
    end
end

local okCfg, userConfig = pcall(require, "config")
if okCfg and type(userConfig) == "table" then
    merge(CONFIG, userConfig)
else
    log("config.lua not found or invalid (%s); using shipped defaults", tostring(userConfig))
end
log("Fieldkit v%s loading: features %s", tostring(CONFIG.Version), table.concat(CONFIG.Features, ", "))

------------------------------------------------------------------------------------------
-- Shared helpers (exposed to features through `core`)
------------------------------------------------------------------------------------------

local function valid(obj)
    return obj ~= nil and obj:IsValid()
end

-- UE4SS hands back RemoteUnrealParam wrappers for array elements; the value is behind :get().
local function unwrap(v)
    if type(v) == "userdata" then
        local ok, inner = pcall(function() return v:get() end)
        if ok and inner ~= nil then return inner end
    end
    return v
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

local tick = 0 -- one per TickMs; every timestamp in Fieldkit is in ticks

------------------------------------------------------------------------------------------
-- Custom World Settings: row name -> integer, from the ProspectSubsystem's settings array
-- (FCustomGameSetting = { SettingRowName, SettingValue }). Rows the host never applied are
-- absent, and features fall back to their defaults.
------------------------------------------------------------------------------------------

local settings = { values = {}, source = "defaults", dirty = true, readAt = nil, changed = false }
local subsystem = nil

-- Direct lookup through the engine's subsystem library (no object-table walk). Needs any
-- world-bound object as context; a registered tame does.
local function prospectSubsystem(context)
    if valid(subsystem) then return subsystem end
    subsystem = nil
    if context == nil then return nil end
    local ok, err = pcall(function()
        local lib = StaticFindObject(CONFIG.SubsystemLibrary)
        local cls = StaticFindObject(CONFIG.SubsystemClass)
        if not valid(lib) or not valid(cls) then error("library or class not found") end
        local sub = lib:GetGameInstanceSubsystem(context, cls)
        if valid(sub) then subsystem = sub end
    end)
    if not ok then dbg("ProspectSubsystem lookup failed: %s", tostring(err)) end
    if subsystem then dbg("ProspectSubsystem found: %s", shortName(subsystem)) end
    return subsystem
end

local function readSettings(context)
    if not CONFIG.CustomWorldSettings then return end
    if not settings.dirty and settings.readAt and tick - settings.readAt < CONFIG.SettingsRefreshTicks then return end
    local sub = prospectSubsystem(context)
    if not sub then return end
    settings.readAt, settings.dirty = tick, false
    local values, n = {}, 0
    local ok, err = pcall(function()
        local list = sub.CustomGameSettings
        if list == nil then return end
        list:ForEach(function(_, elem)
            local s = unwrap(elem)
            local okN, name = pcall(function() return s.SettingRowName:ToString() end)
            local okV, value = pcall(function() return tonumber(s.SettingValue) end)
            if okN and okV and name and value then values[name], n = value, n + 1 end
        end)
    end)
    if not ok then dbg("settings read failed: %s", tostring(err)); return end
    local changed = false
    for k, v in pairs(values) do if settings.values[k] ~= v then changed = true end end
    for k in pairs(settings.values) do if values[k] == nil then changed = true end end
    settings.values = values
    settings.source = n > 0 and string.format("Custom World Settings (%d rows)", n) or "defaults (no rows applied in this prospect yet)"
    if changed then
        settings.changed = true
        local parts = {}
        for k, v in pairs(values) do if k:find("^Fieldkit_") then parts[#parts + 1] = k .. "=" .. v end end
        table.sort(parts)
        log("settings: %s", #parts > 0 and table.concat(parts, " ") or settings.source)
    end
end

-- The host pressing Apply calls this on the subsystem; re-read right after it ran.
if CONFIG.CustomWorldSettings then
    local ok, err = pcall(RegisterHook, CONFIG.SubsystemSetHook,
        function(self) subsystem = valid(self) and self or subsystem end,
        function(self)
            subsystem = valid(self) and self or subsystem
            settings.dirty = true
            dbg("Custom World Settings applied; re-reading")
        end)
    if ok then dbg("hooked %s", CONFIG.SubsystemSetHook)
    else log("could not hook %s (%s); settings still refresh every %d ticks", CONFIG.SubsystemSetHook, tostring(err), CONFIG.SettingsRefreshTicks) end
end

------------------------------------------------------------------------------------------
-- Tame registry: full name -> { actor, <feature id> = feature-private state }
------------------------------------------------------------------------------------------

local registry = {}

local function registerTame(actor, source)
    if not valid(actor) then return end
    local key = fullName(actor)
    if registry[key] or key:find("Default__", 1, true) then return end -- skip class default objects
    registry[key] = { actor = actor }
    dbg("tame registered: %s (%s) via %s", displayName(actor), shortName(actor), source)
end

local function pruneTames()
    for key, entry in pairs(registry) do
        if not valid(entry.actor) then registry[key] = nil end
    end
end

local function countTames()
    local n = 0
    for _ in pairs(registry) do n = n + 1 end
    return n
end

local function anyTame()
    for _, entry in pairs(registry) do
        if valid(entry.actor) then return entry.actor end
    end
    return nil
end

-- Any world-bound object, for engine calls that need a world context (subsystem and player
-- lookups). Features hand in the actors they register (containers, ...); tames work too.
local contextObject = nil
local knownController = nil   -- the local player's controller, from its ClientRestart

local function anyContext()
    if valid(contextObject) then return contextObject end
    contextObject = valid(knownController) and knownController or anyTame()
    return contextObject
end

-- Where features keep files that must survive a reinstall (build.py replaces the mod folder):
-- <ue4ss>/FieldkitData/, next to the Mods folder.
local function dataDir()
    local source = (debug.getinfo(1, "S").source or ""):gsub("^@", ""):gsub("\\", "/")
    local ue4ss = source:match("^(.*)/[Mm]ods/[^/]+/Scripts/[^/]+$")
    if ue4ss then return ue4ss .. "/FieldkitData" end
    return "ue4ss/FieldkitData" -- relative to the game's Binaries/Win64 working directory
end

local function watch(classPath)
    local ok, err = pcall(NotifyOnNewObject, classPath, function(actor)
        -- Give the actor a moment to finish construction before we touch it.
        ExecuteWithDelay(1000, function()
            ExecuteInGameThread(function() pcall(registerTame, actor, "spawn") end)
        end)
    end)
    if not ok then dbg("could not watch %s (%s)", classPath, tostring(err)) end
end

watch(CONFIG.Tames.BaseClass)
for _, classPath in ipairs(CONFIG.Tames.MountClasses) do watch(classPath) end

------------------------------------------------------------------------------------------
-- The core handed to features
------------------------------------------------------------------------------------------

local core = {
    CONFIG = CONFIG,
    valid = valid, unwrap = unwrap, fullName = fullName, shortName = shortName,
    hasAuthority = hasAuthority, displayName = displayName,
    tick = function() return tick end,
    -- Custom World Settings value of a row, or `default` when the host never applied it.
    setting = function(row, default)
        local v = settings.values[row]
        if v == nil then return default end
        return v
    end,
    settingsSource = function() return settings.source end,
    tames = { all = function() return registry end, count = countTames },
    dataDir = dataDir(),
    setContext = function(obj) if not valid(contextObject) and valid(obj) then contextObject = obj end end,
    anyContext = anyContext,
    subsystem = function() return prospectSubsystem(anyContext()) end,
}

-- The local player's controller (player 0): remembered from its ClientRestart, else through the
-- engine's GameplayStatics.
function core.controller()
    if valid(knownController) then return knownController end
    local controller = nil
    pcall(function()
        local gs = StaticFindObject("/Script/Engine.Default__GameplayStatics")
        local ctx = anyContext()
        if valid(gs) and ctx then controller = gs:GetPlayerController(ctx, 0) end
    end)
    return valid(controller) and controller or nil
end

-- Backend id of the loaded prospect (its save), or nil before one is known.
function core.prospectId()
    local sub = prospectSubsystem(anyContext())
    if not sub then return nil end
    local ok, id = pcall(function() return sub.ActiveProspect.ProspectID:ToString() end)
    if ok and id and id ~= "" then return id end
    return nil
end

-- A line in the local player's message area (chat/log), plus UE4SS.log.
function core.tell(text)
    log("-> %s", text)
    pcall(function()
        local controller = core.controller()
        if controller then controller:AddLocalMessage("[Fieldkit] " .. text) end
    end)
end

function core.logger(id)
    local prefix = "[Fieldkit:" .. id .. "] "
    local l = {}
    function l.log(fmt, ...) print(string.format(prefix .. fmt .. "\n", ...)) end
    function l.dbg(fmt, ...) if CONFIG.Debug then l.log(fmt, ...) end end
    return l
end

------------------------------------------------------------------------------------------
-- Features
------------------------------------------------------------------------------------------

local features = {}   -- ordered list of loaded feature modules
local byId = {}

local function loadFeature(id)
    local mod, err
    for _, name in ipairs({ "features." .. id, "features/" .. id }) do
        local ok, result = pcall(require, name)
        if ok and type(result) == "table" then mod = result; break end
        err = result
    end
    if not mod then
        log("feature '%s' failed to load: %s", id, tostring(err))
        return
    end
    mod.id = mod.id or id
    mod.failures = 0
    local ok, initErr = pcall(function() if mod.init then mod.init(core, CONFIG.FeatureConfig[mod.id] or {}) end end)
    if not ok then
        log("feature '%s' failed to init: %s", id, tostring(initErr))
        return
    end
    features[#features + 1] = mod
    byId[mod.id] = mod
    log("feature loaded: %s (%s)", mod.id, tostring(mod.title))
end

for _, id in ipairs(CONFIG.Features) do loadFeature(id) end
log("Fieldkit v%s loaded with %d feature(s)", tostring(CONFIG.Version), #features)

------------------------------------------------------------------------------------------
-- Catch-up scan. The registries fill from spawn notifications, which miss every actor that
-- already existed when this code started: after a Ctrl+R hot reload, or when the mod comes up
-- after the world (a slow start). So the object table is walked ONCE per trigger: right after
-- load (a no-op on a fresh start, where no world exists yet) and once more when the local
-- player's pawn is set up. Never periodic, never per event (see README).
------------------------------------------------------------------------------------------

local function rescan(reason)
    local okT, mounts = pcall(FindAllOf, CONFIG.Tames.ScanClass)
    local tames = 0
    if okT and mounts then
        for _, actor in ipairs(mounts) do registerTame(actor, "scan"); tames = tames + 1 end
    end
    local parts = { string.format("%d tame(s)", tames) }
    for _, f in ipairs(features) do
        if f.rescan and not f.disabled then
            local ok, result = pcall(f.rescan, core, reason)
            parts[#parts + 1] = ok and tostring(result) or (f.id .. " scan failed: " .. tostring(result))
        end
    end
    log("catch-up scan (%s): %s", reason, table.concat(parts, ", "))
end

local scans = {}
local function scanOnce(reason, delayMs)
    if scans[reason] then return end
    scans[reason] = true
    ExecuteWithDelay(delayMs, function()
        ExecuteInGameThread(function()
            local ok, err = pcall(rescan, reason)
            if not ok then log("catch-up scan (%s) failed: %s", reason, tostring(err)) end
        end)
    end)
end

scanOnce("load", 1500)

-- The local player's pawn was (re)started: the world is up. Remember the controller.
pcall(RegisterHook, "/Script/Engine.PlayerController:ClientRestart", function() end, function(self)
    local controller = self
    pcall(function() controller = self:get() end)
    if not valid(controller) then return end
    local isLocal = false
    pcall(function() isLocal = controller:IsLocalController() == true end)
    if not isLocal then return end
    knownController = controller
    contextObject = controller
    scanOnce("player spawned", 3000)
end)

local announced = false

local function coreTick()
    tick = tick + 1
    pruneTames()
    readSettings(anyContext())
    -- One line in the player's message area once the world is up (also after a Ctrl+R reload),
    -- so a reload is visible without opening the log.
    if not announced and core.controller() then
        announced = true
        local ids = {}
        for _, f in ipairs(features) do ids[#ids + 1] = f.id .. (f.disabled and " (disabled)" or "") end
        core.tell(string.format("Fieldkit v%s loaded: %s", tostring(CONFIG.Version), table.concat(ids, ", ")))
    end
    local changed = settings.changed
    settings.changed = false
    for _, f in ipairs(features) do
        if f.disabled then goto continue end
        local ok, err = pcall(function()
            if changed and f.settingsChanged then f.settingsChanged(core) end
            if f.tick then f.tick(core) end
        end)
        if ok then
            f.failures = 0
        else
            f.failures = f.failures + 1
            log("feature '%s' tick failed (%d): %s", f.id, f.failures, tostring(err))
            if f.failures >= 10 then
                f.disabled = true
                log("feature '%s' DISABLED after repeated failures; fix and reload (Ctrl+R)", f.id)
            end
        end
        ::continue::
    end
end

LoopAsync(CONFIG.TickMs, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(coreTick)
        if not ok then log("core tick failed: %s", tostring(err)) end
    end)
    return false
end)

------------------------------------------------------------------------------------------
-- Console
------------------------------------------------------------------------------------------

pcall(RegisterConsoleCommandHandler, "fieldkit", function(FullCommand, Parameters, Ar)
    local word = Parameters[1]
    if word == "scan" then
        -- Manual catch-up scan (one object-table walk); see rescan() above.
        local ok, err = pcall(rescan, "console")
        Ar:Log(ok and string.format("[Fieldkit] scan done: %d tame(s) registered; details in UE4SS.log", countTames())
            or ("[Fieldkit] scan failed: " .. tostring(err)))
        return true
    end
    if word == "tames" then
        Ar:Log(string.format("[Fieldkit] %d tame(s) registered", countTames()))
        for _, entry in pairs(registry) do
            if valid(entry.actor) then
                Ar:Log(string.format("   %-24s %s", displayName(entry.actor), shortName(entry.actor)))
            end
        end
        return true
    end
    if word and byId[word] then
        local f = byId[word]
        if f.console then
            local rest = {}
            for i = 2, #Parameters do rest[#rest + 1] = Parameters[i] end
            local ok, err = pcall(f.console, core, rest, Ar)
            if not ok then Ar:Log(string.format("[Fieldkit:%s] console error: %s", f.id, tostring(err))) end
        else
            Ar:Log(string.format("[Fieldkit] feature '%s' has no console commands", f.id))
        end
        return true
    end
    Ar:Log(string.format("[Fieldkit] v%s  tick %d  tames %d  settings from %s (subsystem %s)",
        tostring(CONFIG.Version), tick, countTames(), settings.source, valid(subsystem) and "found" or "not found yet"))
    for _, f in ipairs(features) do
        local status = f.disabled and "DISABLED (errors)" or (f.status and (pcall(f.status, core) and select(2, pcall(f.status, core)) or "?") or "")
        Ar:Log(string.format("   %-12s %s", f.id, tostring(status)))
    end
    Ar:Log("[Fieldkit] usage: fieldkit | fieldkit tames | fieldkit scan | fieldkit <feature> [args]")
    return true
end)
