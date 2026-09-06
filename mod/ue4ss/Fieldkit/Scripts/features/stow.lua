--[[
    Fieldkit feature: stow - one key sends your backpack items to the chests they belong in.

    Every storage container can be PINNED to a set of item types. Open the chest, put in what belongs
    there and press the pin key (Shift+P) or the "Pin contents" button in the chest window: the chest
    is now pinned to exactly the item types it holds. Pinning an EMPTY chest clears its pins. With
    learning on (default), opening a chest also adds whatever it holds to its pins, so chests you
    use normally attract those items later even after crafting drained them.

    The deposit key (Shift+E) then moves every backpack stack whose type is pinned on a chest within
    range into that chest (nearest first, spilling over to the next pinned chest when one is full).
    The hotbar is never touched, and items without a pinned chest stay in the backpack.

    In game you can tell what a chest is pinned to by:
      * the chest window's title bar ("Wood Crate - pinned: Wood, Stone"),
      * the in-world tooltip when you look at the chest,
      * the message lines after pinning and depositing (chat/log area).

    Pins are saved per prospect in <ue4ss>/FieldkitData/stow/<prospect id>.lua, keyed by the chest's
    class and its rounded world position (pick a chest up and place it again = new key, pins gone).

    Custom World Settings rows (Fieldkit pak, Misc section):
      Fieldkit_Stow       Bool  on/off (default on)
      Fieldkit_StowRange  Int   deposit range in metres, 5-100 (default 30)
      Fieldkit_StowLearn  Bool  opening a chest adds its contents to its pins (default on)

    Game API used (all pointer/int parameters, no structs passed in; see README on struct crashes):
      AIcarusPlayerControllerSurvival:ClientOpenContainer(Inventory, ...)   hooked: which chest is open
      AIcarusController:OnServer_ShiftItemAuto(SourceInv, SourceSlot, DestInv)  the move itself
      UInventory:HasValidItemInSlot/GetItem(slot).ItemStaticData.RowName     what a slot holds
      UMG_Chest_C (chest window): UMG_DeviceInventory.UMG_DarkTitlebar:UpdateText, InventoryVertBox
      UMG_TooltipInworld_C:UpdateTooltip(Actor)                             hooked: tooltip text

    Console: `fieldkit stow` (status + nearby chests), `fieldkit stow pins` (every pinned chest),
    `fieldkit stow deposit`, `fieldkit stow pin|unpin <item row>` / `fieldkit stow clear` (open chest),
    `fieldkit stow names <text>` (find item rows by display name), `fieldkit stow scan` (diagnostic).
]]

local F = { id = "stow", title = "Stow (pinned chests)" }

local CONFIG = {
    RangeMetres        = 30,      -- deposit range when the prospect has no range row applied
    Learn              = true,    -- opening a chest adds its contents to its pins
    Keys = {
        Deposit = { Key = "E", Modifiers = { "SHIFT" } },
        Pin     = { Key = "P", Modifiers = { "SHIFT" } },
    },
    TitleBar           = true,    -- rewrite the chest window title with the pins
    PinButton          = true,    -- add a "Pin contents" button to the chest window
    Tooltip            = true,    -- show the pins in the in-world tooltip
    ExcludedContainers = {},      -- container class names never used, e.g. { "BP_Deep_Freeze_C" }
    MaxBackpackSlots   = 80,      -- upper bound when the slot count cannot be read
    MaxChestSlots      = 200,
    ItemNames          = {},      -- item row -> display name, written by build.py from D_ItemsStatic/D_Itemable
    StackProperty      = 7,       -- EDynamicItemProperties::ItemableStack
    PruneTicks         = 5,
    ContainerClass     = "/Game/BP/Objects/World/Items/Deployables/Containers/BP_DeployableContainerBase.BP_DeployableContainerBase_C",
    ScanClass          = "BP_DeployableContainerBase_C",
    InventoryComponent = "/Script/Icarus.InventoryComponent",
    OpenHook           = "/Script/Icarus.IcarusPlayerControllerSurvival:ClientOpenContainer",
    ChestWidgetClass   = "/Game/UI/Windows/UMG_Chest.UMG_Chest_C",
    CloseHook          = "/Game/UI/Components/UMG_IcarusLinkedActorPanel.UMG_IcarusLinkedActorPanel_C:ClosePanel",
    TooltipHook        = "/Game/UI/Popups/UMG_TooltipInworld.UMG_TooltipInworld_C:UpdateTooltip",
    ButtonClass        = "/Game/UI/Components/UMG_BasicButton_2.UMG_BasicButton_2_C",
    ButtonClickHook    = "/Game/UI/Components/UMG_ButtonBase.UMG_ButtonBase_C:OnClicked",
    WidgetLibrary      = "/Script/UMG.Default__WidgetBlueprintLibrary",
    SettingEnabledRow  = "Fieldkit_Stow",
    SettingRangeRow    = "Fieldkit_StowRange",
    SettingLearnRow    = "Fieldkit_StowLearn",
    TitleSeparator     = "  -  ",
}

local L
local core
local enabled = true
local containers = {}      -- actor full name -> { actor, key, name, inv }
local pins = {}            -- chest key -> { rows = { [row] = true }, name = "Wood Crate" }
local pinsProspect = nil   -- prospect id the pins table was loaded for
local pinsDirty = false
local openChest = nil      -- registry entry of the chest whose window is open
local openInv = nil
local chestWidget = nil    -- the last UMG_Chest_C widget the game created
local pinButtons = {}      -- our button full name -> chest widget
local hooks = {}           -- hook path -> true once registered
local warned = {}

------------------------------------------------------------------------------------------
-- Small helpers
------------------------------------------------------------------------------------------

local function valid(o) return core.valid(o) end

local function once(key, fmt, ...)
    if warned[key] then return end
    warned[key] = true
    L.log(fmt, ...)
end

local function itemName(row)
    return CONFIG.ItemNames[row] or row
end

local function joinNames(rows)
    local names = {}
    for row in pairs(rows) do names[#names + 1] = itemName(row) end
    table.sort(names)
    return table.concat(names, ", "), #names
end

local function excluded(className)
    for _, name in ipairs(CONFIG.ExcludedContainers) do
        if name == className then return true end
    end
    return false
end

local function makeText(s)
    local ok, text = pcall(FText, s)
    if ok and text ~= nil then return text end
    once("ftext", "FText() is not available in this UE4SS build; chest titles and tooltips stay unchanged")
    return nil
end

local function stackOf(item)
    local count = 1
    pcall(function()
        local dyn = core.unwrap(item.ItemDynamicData)
        local function consider(entry)
            entry = core.unwrap(entry)
            local ptype, value
            pcall(function() ptype, value = entry.PropertyType, entry.Value end)
            local isStack = tonumber(ptype) == CONFIG.StackProperty or tostring(ptype):find("ItemableStack", 1, true) ~= nil
            if isStack and tonumber(value) then count = tonumber(value) end
        end
        if type(dyn) == "table" then
            for _, entry in pairs(dyn) do consider(entry) end
        elseif type(dyn) == "userdata" and dyn.ForEach ~= nil then
            dyn:ForEach(function(_, entry) consider(entry) end)
        end
    end)
    return count
end

-- Row name and stack count of a slot, or nil when it is empty.
local function slotItem(inv, slot)
    local row, count = nil, 0
    pcall(function()
        if inv:HasValidItemInSlot(slot) then
            local item = inv:GetItem(slot)
            row = item.ItemStaticData.RowName:ToString()
            count = stackOf(item)
        end
    end)
    if row == "" or row == "None" then row = nil end
    return row, count
end

local function slotCount(inv, fallback)
    local n = nil
    pcall(function() n = inv.Slots.Slots:GetArrayNum() end)
    if not n or n <= 0 then pcall(function() n = #inv.Slots.Slots end) end
    if not n or n <= 0 then return fallback end
    return math.min(n, fallback)
end

-- { [row] = total count } of an inventory.
local function contentsOf(inv, maxSlots)
    local rows = {}
    if not valid(inv) then return rows end
    for slot = 0, slotCount(inv, maxSlots) - 1 do
        local row, count = slotItem(inv, slot)
        if row then rows[row] = (rows[row] or 0) + count end
    end
    return rows
end

local function locationOf(actor)
    local ok, loc = pcall(function() return actor:K2_GetActorLocation() end)
    if ok and loc then return loc end
    return nil
end

local function distanceM(a, b)
    if not a or not b then return math.huge end
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz) / 100
end

------------------------------------------------------------------------------------------
-- Container registry (spawn notifications for the container base class; no object walks)
------------------------------------------------------------------------------------------

local function classNameOf(actor)
    local ok, name = pcall(function() return actor:GetClass():GetFullName():match("[^%.]+$") end)
    return ok and name or "?"
end

local function chestName(actor, className)
    local ok, row = pcall(function() return actor.ItemData.ItemStaticData.RowName:ToString() end)
    if ok and row and row ~= "" and row ~= "None" then return itemName(row) end
    local name = (className or "?"):gsub("_C$", ""):gsub("^BP_", ""):gsub("_", " ")
    return name
end

local function registerContainer(actor, source)
    if not valid(actor) then return end
    local fullName = core.fullName(actor)
    if containers[fullName] or fullName:find("Default__", 1, true) then return end
    local className = classNameOf(actor)
    if excluded(className) then return end
    local entry = { actor = actor, className = className, name = chestName(actor, className) }
    containers[fullName] = entry
    core.setContext(actor)
    L.dbg("container registered: %s (%s) via %s", entry.name, className, source)
end

-- Stable key: class + world position rounded to 10 cm.
local function keyOf(entry)
    if entry.key then return entry.key end
    local loc = locationOf(entry.actor)
    if not loc then return nil end
    entry.key = string.format("%s@%d,%d,%d", entry.className,
        math.floor(loc.X / 10 + 0.5), math.floor(loc.Y / 10 + 0.5), math.floor(loc.Z / 10 + 0.5))
    return entry.key
end

local function inventoryOf(entry)
    if valid(entry.inv) then return entry.inv end
    entry.inv = nil
    pcall(function()
        local cls = StaticFindObject(CONFIG.InventoryComponent)
        local comps = entry.actor:K2_GetComponentsByClass(cls)
        for i = 1, #comps do
            local comp = core.unwrap(comps[i])
            if valid(comp) then
                pcall(function()
                    comp.Inventories:ForEach(function(_, v)
                        local inv = v:get()
                        if not entry.inv and valid(inv) then entry.inv = inv end
                    end)
                end)
                if entry.inv then break end
            end
        end
    end)
    return entry.inv
end

local function pruneContainers()
    for name, entry in pairs(containers) do
        if not valid(entry.actor) then containers[name] = nil end
    end
end

local function countContainers()
    local n = 0
    for _ in pairs(containers) do n = n + 1 end
    return n
end

-- The registry entry an inventory belongs to, through its outer chain (inventory -> component -> actor).
local function entryOfInventory(inv)
    local obj = inv
    for _ = 1, 5 do
        if not valid(obj) then return nil end
        local entry = containers[core.fullName(obj)]
        if entry then return entry end
        local ok, outer = pcall(function() return obj:GetOuter() end)
        if not ok then return nil end
        obj = outer
    end
    return nil
end

------------------------------------------------------------------------------------------
-- Pins: per prospect, saved as a Lua table file outside the mod folder (installs replace it)
------------------------------------------------------------------------------------------

local function pinsPath(prospect)
    return string.format("%s/stow/%s.lua", core.dataDir, (prospect or "default"):gsub("[^%w%-_]", "_"))
end

local function loadPins(prospect)
    pins, pinsProspect, pinsDirty = {}, prospect, false
    local path = pinsPath(prospect)
    local fh = io.open(path, "r")
    if not fh then L.dbg("no pins file yet at %s", path); return end
    local body = fh:read("a")
    fh:close()
    local chunk, err = load(body, "stow pins", "t", {})
    local ok, data = pcall(chunk or function() error(err) end)
    if not ok or type(data) ~= "table" then
        L.log("pins file %s is unreadable (%s); starting empty", path, tostring(data))
        return
    end
    local n = 0
    for key, rec in pairs(data) do
        if type(rec) == "table" and type(rec.rows) == "table" then
            local rows = {}
            for _, row in ipairs(rec.rows) do rows[row] = true end
            pins[key] = { rows = rows, name = tostring(rec.name or "?") }
            n = n + 1
        end
    end
    L.log("loaded %d pinned chest(s) for prospect %s", n, tostring(prospect))
end

local function quote(s)
    return string.format("%q", tostring(s))
end

local function savePins()
    if not pinsProspect then return end
    local path = pinsPath(pinsProspect)
    local keys = {}
    for key in pairs(pins) do keys[#keys + 1] = key end
    table.sort(keys)
    local out = { "-- Fieldkit stow pins for prospect " .. tostring(pinsProspect) .. " (written by the mod; safe to delete)\nreturn {\n" }
    for _, key in ipairs(keys) do
        local rec = pins[key]
        local rows = {}
        for row in pairs(rec.rows) do rows[#rows + 1] = quote(row) end
        table.sort(rows)
        out[#out + 1] = string.format("    [%s] = { name = %s, rows = { %s } },\n", quote(key), quote(rec.name), table.concat(rows, ", "))
    end
    out[#out + 1] = "}\n"
    local fh, err = io.open(path, "w")
    if not fh then
        -- build.py creates the folder on install; make it here if it is missing (fresh copy of the mod).
        pcall(function()
            local dir = path:match("^(.*)/[^/]+$"):gsub("/", "\\")
            os.execute(string.format('mkdir "%s" >nul 2>&1', dir))
        end)
        fh, err = io.open(path, "w")
    end
    if not fh then L.log("could not write pins to %s: %s", path, tostring(err)); return end
    fh:write(table.concat(out))
    fh:close()
    pinsDirty = false
    L.dbg("pins saved to %s", path)
end

local function ensurePins()
    local prospect = core.prospectId() or pinsProspect or "default"
    if prospect ~= pinsProspect then
        if pinsDirty then savePins() end
        loadPins(prospect)
    end
end

local function pinsOf(entry)
    local key = keyOf(entry)
    return key and pins[key] or nil
end

local function setPins(entry, rows)
    local key = keyOf(entry)
    if not key then return false end
    local n = 0
    for _ in pairs(rows) do n = n + 1 end
    if n == 0 then pins[key] = nil else pins[key] = { rows = rows, name = entry.name } end
    pinsDirty = true
    savePins()
    return true
end

------------------------------------------------------------------------------------------
-- Chest window: title bar and pin button
------------------------------------------------------------------------------------------

local function titleFor(entry)
    local rec = pinsOf(entry)
    if rec then
        local names = joinNames(rec.rows)
        return string.format("%s%spinned: %s", entry.name, CONFIG.TitleSeparator, names)
    end
    return string.format("%s%snot pinned (Shift+P pins the contents)", entry.name, CONFIG.TitleSeparator)
end

local function refreshTitle()
    if not CONFIG.TitleBar or not openChest or not valid(chestWidget) then return end
    local ok, err = pcall(function()
        local bar = chestWidget.UMG_DeviceInventory.UMG_DarkTitlebar
        if not valid(bar) then return end
        local text = makeText(titleFor(openChest))
        if text then bar:UpdateText(text) end
    end)
    if not ok then once("title", "chest title update failed: %s", tostring(err)) end
end

local function buttonLabel()
    if openChest and pinsOf(openChest) then return "Re-pin contents  (Shift+P)" end
    return "Pin contents  (Shift+P)"
end

local function refreshButton()
    for name, rec in pairs(pinButtons) do
        if not valid(rec.btn) or not valid(rec.widget) then
            pinButtons[name] = nil
        elseif rec.widget == chestWidget then
            pcall(function()
                local text = makeText(buttonLabel())
                if text then rec.btn.ButtonText:SetText(text) end
            end)
        end
    end
end

local function addPinButton(widget)
    if not CONFIG.PinButton or not valid(widget) then return end
    local ok, err = pcall(function()
        local controller = core.controller()
        local lib = StaticFindObject(CONFIG.WidgetLibrary)
        local cls = StaticFindObject(CONFIG.ButtonClass)
        if not valid(lib) or not valid(cls) or not valid(controller) then error("widget library, button class or controller missing") end
        local btn = lib:Create(controller, cls, controller)
        if not valid(btn) then error("Create returned nothing") end
        widget.InventoryVertBox:AddChildToVerticalBox(btn)
        local text = makeText(buttonLabel())
        if text then btn.ButtonText:SetText(text) end
        pinButtons[core.fullName(btn)] = { btn = btn, widget = widget }
        L.dbg("pin button added to %s", core.shortName(widget))
    end)
    if not ok then once("button", "pin button not added (%s); the pin key still works", tostring(err)) end
end

------------------------------------------------------------------------------------------
-- Pin and deposit
------------------------------------------------------------------------------------------

local function pinOpenChest()
    ensurePins()
    if not openChest or not valid(openChest.actor) or not valid(openInv) then
        core.tell("Stow: open a chest first, then press the pin key")
        return
    end
    local rows = {}
    for row in pairs(contentsOf(openInv, CONFIG.MaxChestSlots)) do rows[row] = true end
    if not setPins(openChest, rows) then
        core.tell("Stow: could not read the chest position; try again")
        return
    end
    local names, n = joinNames(rows)
    if n == 0 then
        core.tell(string.format("Stow: %s unpinned", openChest.name))
    else
        core.tell(string.format("Stow: %s pinned to %s", openChest.name, names))
    end
    refreshTitle()
    refreshButton()
end

local function learnOpenChest()
    if not CONFIG.Learn or not openChest or not valid(openInv) then return end
    local rec = pinsOf(openChest)
    local rows, added = {}, 0
    if rec then for row in pairs(rec.rows) do rows[row] = true end end
    for row in pairs(contentsOf(openInv, CONFIG.MaxChestSlots)) do
        if not rows[row] then rows[row], added = true, added + 1 end
    end
    if added > 0 then
        setPins(openChest, rows)
        L.dbg("%s learned %d type(s): %s", openChest.name, added, (joinNames(rows)))
    end
end

-- Pinned chests within range of `origin`, nearest first.
local function pinnedNearby(origin, rangeM)
    local list = {}
    for _, entry in pairs(containers) do
        if valid(entry.actor) then
            local rec = pinsOf(entry)
            if rec then
                local d = distanceM(origin, locationOf(entry.actor))
                if d <= rangeM then list[#list + 1] = { entry = entry, rec = rec, dist = d } end
            end
        end
    end
    table.sort(list, function(a, b) return a.dist < b.dist end)
    return list
end

local function deposit()
    ensurePins()
    if not enabled then core.tell("Stow is off in Custom World Settings"); return end
    local controller = core.controller()
    if not valid(controller) then core.tell("Stow: no player controller yet"); return end
    local pawn, backpack
    pcall(function() pawn = controller:GetPawn() end)
    pcall(function() backpack = pawn.BackpackInventory end)
    if not valid(pawn) or not valid(backpack) then core.tell("Stow: backpack not found"); return end
    local origin = locationOf(pawn)
    local nearby = pinnedNearby(origin, CONFIG.RangeMetres)
    if #nearby == 0 then
        core.tell(string.format("Stow: no pinned chest within %d m", CONFIG.RangeMetres))
        return
    end
    local moved, kept, movedCount = {}, {}, 0
    for slot = 0, slotCount(backpack, CONFIG.MaxBackpackSlots) - 1 do
        local row, count = slotItem(backpack, slot)
        if row then
            local before = count
            local target = nil
            for _, cand in ipairs(nearby) do
                if cand.rec.rows[row] then
                    local inv = inventoryOf(cand.entry)
                    if valid(inv) then
                        local ok, err = pcall(function() controller:OnServer_ShiftItemAuto(backpack, slot, inv) end)
                        if not ok then once("shift", "OnServer_ShiftItemAuto failed: %s", tostring(err)); break end
                        local rowAfter, after = slotItem(backpack, slot)
                        local delta = (rowAfter == row) and (before - after) or before
                        if delta > 0 then
                            moved[#moved + 1] = string.format("%d %s -> %s (%.0f m)", delta, itemName(row), cand.entry.name, cand.dist)
                            movedCount = movedCount + delta
                            target = cand
                        end
                        if rowAfter ~= row then break end -- slot emptied (or now holds something else)
                        before = after
                    end
                end
            end
            if not target then
                local hasHome = false
                for _, cand in ipairs(nearby) do if cand.rec.rows[row] then hasHome = true end end
                if hasHome then kept[itemName(row)] = "full" end
            end
        end
    end
    if #moved == 0 then
        local full = {}
        for name in pairs(kept) do full[#full + 1] = name end
        table.sort(full)
        core.tell(#full > 0 and ("Stow: nothing moved; pinned chests are full for " .. table.concat(full, ", "))
            or "Stow: nothing in the backpack is pinned to a chest nearby")
        return
    end
    core.tell(string.format("Stow: %d item(s) put away", movedCount))
    for i, line in ipairs(moved) do
        if i > 6 then core.tell(string.format("   ... and %d more line(s) in UE4SS.log", #moved - 6)); break end
        core.tell("   " .. line)
    end
    for _, line in ipairs(moved) do L.log("moved %s", line) end
end

------------------------------------------------------------------------------------------
-- Hooks: chest open/close, chest widget, tooltip, pin button
------------------------------------------------------------------------------------------

local function hookOnce(path, pre, post)
    if hooks[path] then return true end
    local ok, err = pcall(RegisterHook, path, pre, post)
    if ok then
        hooks[path] = true
        L.dbg("hooked %s", path)
    end
    return ok, err
end

local function onContainerOpened(self, invParam)
    local inv = core.unwrap(invParam)
    if not valid(inv) then return end
    local entry = entryOfInventory(inv)
    if not entry then
        L.dbg("opened an inventory that is not a registered container (%s)", core.shortName(inv))
        openChest, openInv = nil, nil
        return
    end
    openChest, openInv = entry, inv
    ensurePins()
    learnOpenChest()
    L.dbg("chest opened: %s [%s] %s", entry.name, tostring(keyOf(entry)), pinsOf(entry) and ("pinned: " .. (joinNames(pinsOf(entry).rows))) or "not pinned")
    ExecuteWithDelay(250, function()
        ExecuteInGameThread(function()
            pcall(refreshTitle)
            pcall(refreshButton)
        end)
    end)
end

local function onPanelClosed(self)
    if valid(chestWidget) and core.fullName(core.unwrap(self)) == core.fullName(chestWidget) then
        openChest, openInv = nil, nil
    end
end

local function onTooltip(self, actorParam)
    if not CONFIG.Tooltip then return end
    local actor = core.unwrap(actorParam)
    if not valid(actor) then return end
    local entry = containers[core.fullName(actor)]
    if not entry then return end
    local rec = pinsOf(entry)
    if not rec then return end
    local widget = core.unwrap(self)
    pcall(function()
        local text = makeText("Pinned: " .. (joinNames(rec.rows)))
        if not text then return end
        widget.Description:SetText(text)
        widget.Description:SetVisibility(4) -- SelfHitTestInvisible
    end)
end

local function onButtonClicked(self)
    local btn = core.unwrap(self)
    if not valid(btn) then return end
    if pinButtons[core.fullName(btn)] then
        ExecuteInGameThread(function() pcall(pinOpenChest) end)
    end
end

-- Blueprint classes only exist once the game loaded them; retry those hooks every tick.
local function tryLateHooks()
    if CONFIG.TitleBar or CONFIG.PinButton then
        hookOnce(CONFIG.CloseHook, function(self) pcall(onPanelClosed, self) end)
    end
    if CONFIG.Tooltip then
        hookOnce(CONFIG.TooltipHook, function() end, function(self, actor) pcall(onTooltip, self, actor) end)
    end
    if CONFIG.PinButton then
        hookOnce(CONFIG.ButtonClickHook, function(self) pcall(onButtonClicked, self) end)
    end
end

local function bindKey(spec, what, fn)
    local key = Key[spec.Key]
    local mods = {}
    for _, m in ipairs(spec.Modifiers or {}) do mods[#mods + 1] = ModifierKey[m] end
    if not key then L.log("%s key '%s' is not a valid UE4SS key name", what, tostring(spec.Key)); return end
    local label = table.concat(spec.Modifiers or {}, "+") .. (#mods > 0 and "+" or "") .. spec.Key
    local taken = false
    pcall(function() taken = IsKeyBindRegistered(key, mods) == true end)
    if taken then
        L.log("%s key %s is already bound by another mod (NearbyCrafting's Quick Deposit?); binding anyway, both may fire", what, label)
    end
    local ok, err = pcall(RegisterKeyBind, key, mods, function()
        ExecuteInGameThread(function()
            local okRun, runErr = pcall(fn)
            if not okRun then L.log("%s failed: %s", what, tostring(runErr)) end
        end)
    end)
    if ok then L.log("%s bound to %s", what, label) else L.log("could not bind %s to %s: %s", what, label, tostring(err)) end
end

------------------------------------------------------------------------------------------
-- Feature contract
------------------------------------------------------------------------------------------

function F.init(coreRef, config)
    core = coreRef
    for k, v in pairs(config) do CONFIG[k] = v end
    L = core.logger(F.id)
    local names = 0
    for _ in pairs(CONFIG.ItemNames) do names = names + 1 end
    L.log("range %s m, learn %s, %d item names, pins under %s/stow/", tostring(CONFIG.RangeMetres), tostring(CONFIG.Learn), names, core.dataDir)

    local ok, err = pcall(NotifyOnNewObject, CONFIG.ContainerClass, function(actor)
        ExecuteWithDelay(1000, function()
            ExecuteInGameThread(function() pcall(registerContainer, actor, "spawn") end)
        end)
    end)
    if not ok then L.log("could not watch %s (%s)", CONFIG.ContainerClass, tostring(err)) end

    if CONFIG.TitleBar or CONFIG.PinButton then
        pcall(NotifyOnNewObject, CONFIG.ChestWidgetClass, function(widget)
            if core.fullName(widget):find("Default__", 1, true) then return end
            chestWidget = widget
            ExecuteWithDelay(300, function()
                ExecuteInGameThread(function()
                    pcall(addPinButton, widget)
                    pcall(refreshTitle)
                end)
            end)
        end)
    end

    local okHook, hookErr = hookOnce(CONFIG.OpenHook, function(self, inv) pcall(onContainerOpened, self, inv) end)
    if not okHook then L.log("could not hook %s (%s): pinning by key needs it", CONFIG.OpenHook, tostring(hookErr)) end

    bindKey(CONFIG.Keys.Deposit, "deposit", deposit)
    bindKey(CONFIG.Keys.Pin, "pin", pinOpenChest)
end

local function applySettings()
    local newEnabled = core.setting(CONFIG.SettingEnabledRow, 1) ~= 0
    local range = core.setting(CONFIG.SettingRangeRow, nil)
    local learn = core.setting(CONFIG.SettingLearnRow, nil)
    local newRange = range or CONFIG.RangeMetres
    local newLearn = (learn == nil) and CONFIG.Learn or (learn ~= 0)
    if newEnabled ~= enabled or newRange ~= CONFIG.RangeMetres or newLearn ~= CONFIG.Learn then
        L.log("%s, range %s m, learn %s (%s)", newEnabled and "ON" or "OFF", tostring(newRange), tostring(newLearn), core.settingsSource())
    end
    enabled, CONFIG.RangeMetres, CONFIG.Learn = newEnabled, newRange, newLearn
end

function F.settingsChanged() applySettings() end

function F.tick()
    applySettings()
    tryLateHooks()
    if core.tick() % CONFIG.PruneTicks == 0 then pruneContainers() end
    if openChest and not valid(openChest.actor) then openChest, openInv = nil, nil end
end

function F.status()
    local n = 0
    for _ in pairs(pins) do n = n + 1 end
    return string.format("%s  range %d m  learn %s  %d container(s)  %d pinned  prospect %s",
        enabled and "ON" or "OFF", CONFIG.RangeMetres, tostring(CONFIG.Learn), countContainers(), n, tostring(pinsProspect))
end

function F.console(_, params, Ar)
    local word = params[1]
    ensurePins()
    if word == "deposit" then deposit(); return end
    if word == "pin" or word == "unpin" then
        local row = params[2]
        if not row then Ar:Log("[Fieldkit:stow] usage: fieldkit stow pin|unpin <item row>  (fieldkit stow names <text> finds rows)"); return end
        if not openChest then Ar:Log("[Fieldkit:stow] open a chest first"); return end
        local rec = pinsOf(openChest)
        local rows = {}
        if rec then for r in pairs(rec.rows) do rows[r] = true end end
        rows[row] = (word == "pin") and true or nil
        setPins(openChest, rows)
        Ar:Log(string.format("[Fieldkit:stow] %s now pinned to: %s", openChest.name, (joinNames(rows))))
        refreshTitle(); refreshButton()
        return
    end
    if word == "clear" then
        if not openChest then Ar:Log("[Fieldkit:stow] open a chest first"); return end
        setPins(openChest, {})
        Ar:Log(string.format("[Fieldkit:stow] %s unpinned", openChest.name))
        refreshTitle(); refreshButton()
        return
    end
    if word == "names" then
        local needle = (params[2] or ""):lower()
        local hits = {}
        for row, name in pairs(CONFIG.ItemNames) do
            if name:lower():find(needle, 1, true) then hits[#hits + 1] = string.format("%-40s %s", row, name) end
        end
        table.sort(hits)
        for i, line in ipairs(hits) do
            if i > 30 then Ar:Log(string.format("   ... %d more", #hits - 30)); break end
            Ar:Log("   " .. line)
        end
        Ar:Log(string.format("[Fieldkit:stow] %d item row(s) match '%s'", #hits, needle))
        return
    end
    if word == "pins" then
        local keys = {}
        for key in pairs(pins) do keys[#keys + 1] = key end
        table.sort(keys)
        for _, key in ipairs(keys) do
            Ar:Log(string.format("   %-20s %-40s %s", pins[key].name, key, (joinNames(pins[key].rows))))
        end
        Ar:Log(string.format("[Fieldkit:stow] %d pinned chest(s) in %s", #keys, pinsPath(pinsProspect)))
        return
    end
    if word == "scan" then
        local ok, list = pcall(FindAllOf, CONFIG.ScanClass)
        local n = 0
        if ok and list then for _, actor in ipairs(list) do registerContainer(actor, "scan"); n = n + 1 end end
        Ar:Log(string.format("[Fieldkit:stow] scan found %d container(s); %d registered", n, countContainers()))
        return
    end
    Ar:Log("[Fieldkit:stow] " .. F.status())
    local controller = core.controller()
    local pawn
    pcall(function() pawn = controller:GetPawn() end)
    local origin = valid(pawn) and locationOf(pawn) or nil
    local list = {}
    for _, entry in pairs(containers) do
        if valid(entry.actor) then
            local d = distanceM(origin, locationOf(entry.actor))
            if d <= CONFIG.RangeMetres then
                local rec = pinsOf(entry)
                list[#list + 1] = { d = d, line = string.format("   %5.0f m  %-20s %s", d, entry.name, rec and ("pinned: " .. (joinNames(rec.rows))) or "-") }
            end
        end
    end
    table.sort(list, function(a, b) return a.d < b.d end)
    for _, item in ipairs(list) do Ar:Log(item.line) end
    Ar:Log(string.format("[Fieldkit:stow] %d container(s) within %d m; open chest: %s; hooks: open %s close %s tooltip %s button %s",
        #list, CONFIG.RangeMetres, openChest and openChest.name or "none",
        hooks[CONFIG.OpenHook] and "ok" or "no", hooks[CONFIG.CloseHook] and "ok" or "no",
        hooks[CONFIG.TooltipHook] and "ok" or "no", hooks[CONFIG.ButtonClickHook] and "ok" or "no"))
    Ar:Log("[Fieldkit:stow] usage: fieldkit stow | deposit | pins | pin|unpin <row> | clear | names <text> | scan")
end

return F
