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
      UMG_Chest_C (chest window): LinkedActor + Inventory say which chest is open (its
        SetupObjectInventory is hooked; the controller's ClientOpenContainer never fires for chests),
        UMG_DeviceInventory.UMG_DarkTitlebar:UpdateText for the title, InventoryVertBox for our button
      AIcarusController:OnServer_ShiftItemAuto(SourceInv, SourceSlot, DestInv)  the move itself
      UInventory:HasValidItemInSlot + Slots.Slots[i].ItemData (live array)  what a slot holds
      UMG_TooltipInworld_C (in-world tooltip): ProjectionActor:GetOwner() is the chest; its own
        graph functions cannot be hooked, so the visible tooltips are polled a few times a second

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
    ChestWidgetClass   = "/Game/UI/Windows/UMG_Chest.UMG_Chest_C",
    SetupHook          = "/Game/UI/Windows/UMG_Chest.UMG_Chest_C:SetupObjectInventory",
    CloseHook          = "/Game/UI/Components/UMG_IcarusLinkedActorPanel.UMG_IcarusLinkedActorPanel_C:ClosePanel",
    TooltipClass       = "/Game/UI/Popups/UMG_TooltipInworld.UMG_TooltipInworld_C",
    TooltipPollMs      = 300,     -- how often the visible tooltips get their pin line
    TooltipBudgetMs    = 2,       -- a poll slower than this three times switches the tooltip pins off
    ButtonClass        = "/Game/UI/Components/UMG_BasicButton_2.UMG_BasicButton_2_C",
    ButtonClickHook    = "/Game/UI/Components/UMG_ButtonBase.UMG_ButtonBase_C:OnClicked",
    WidgetLibrary      = "/Script/UMG.Default__WidgetBlueprintLibrary",
    SettingEnabledRow  = "Fieldkit_Stow",
    SettingRangeRow    = "Fieldkit_StowRange",
    SettingLearnRow    = "Fieldkit_StowLearn",
    TitleSeparator     = "  -  ",
    MaxTitleChars      = 20,      -- pin names that fit in the title bar next to the Type/Sort controls
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

-- Row name and stack count of a slot, or nil when it is empty. Read through the inventory's live
-- slot array (a property chain, no temporaries): GetItem returns a copy of the 0x1F0-byte item
-- struct, and walking the dynamic-data array inside such a copy crashed the game twice on a full
-- backpack (2026-09-06). GetItem stays as the fallback when the array read is unavailable.
local slotReadMode = nil

local function slotItem(inv, slot)
    local row, count = nil, 0
    local okArr = pcall(function()
        if not inv:HasValidItemInSlot(slot) then return end
        local elem = inv.Slots.Slots[slot + 1]
        local s = core.unwrap(elem)
        row = s.ItemData.ItemStaticData.RowName:ToString()
        count = stackOf(s.ItemData)
    end)
    if okArr then
        if slotReadMode ~= "array" then slotReadMode = "array"; L.dbg("slot reads through Slots.Slots") end
    else
        if slotReadMode ~= "getitem" then slotReadMode = "getitem"; L.log("slot array read failed; falling back to GetItem copies") end
        row, count = nil, 0
        pcall(function()
            if inv:HasValidItemInSlot(slot) then
                local item = inv:GetItem(slot)
                row = item.ItemStaticData.RowName:ToString()
                count = stackOf(item)
            end
        end)
    end
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

-- The title bar shares its row with the Type/Sort controls, so it only has room for a short line;
-- the full pin list goes on the wide Pin bar under the player inventory.
local function shortPins(rows, maxChars)
    local names = {}
    for row in pairs(rows) do names[#names + 1] = itemName(row) end
    table.sort(names)
    local out, used = {}, 0
    for i, name in ipairs(names) do
        local next = used + #name + (i > 1 and 2 or 0)
        if i > 1 and next > maxChars then
            return table.concat(out, ", ") .. string.format(" +%d", #names - #out)
        end
        out[#out + 1] = name
        used = next
    end
    return table.concat(out, ", ")
end

local function titleFor(entry)
    local rec = pinsOf(entry)
    if rec then return "Pinned: " .. shortPins(rec.rows, CONFIG.MaxTitleChars) end
    return entry.name .. CONFIG.TitleSeparator .. "not pinned"
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
    local rec = openChest and pinsOf(openChest) or nil
    if rec then return string.format("Pinned (Shift+P): %s", (joinNames(rec.rows))) end
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

-- The chest behind a chest window: the widget links the actor and holds the container inventory.
local function resolveOpenChest(widget, source)
    if not valid(widget) then return false end
    local actor, inv
    pcall(function() actor = widget.LinkedActor end)
    if not valid(actor) then pcall(function() actor = widget:GetLinkedActor() end) end
    if not valid(actor) then
        L.dbg("chest window %s has no linked actor yet (%s)", core.shortName(widget), source)
        return false
    end
    local entry = containers[core.fullName(actor)]
    if not entry then
        registerContainer(actor, "chest window")
        entry = containers[core.fullName(actor)]
    end
    if not entry then
        L.dbg("chest window is for %s, not a storage container (%s)", core.shortName(actor), source)
        return false
    end
    pcall(function() inv = widget.Inventory end)
    if not valid(inv) then inv = inventoryOf(entry) end
    if not valid(inv) then
        L.dbg("no inventory found for %s (%s)", entry.name, source)
        return false
    end
    local first = openChest ~= entry or openInv ~= inv
    openChest, openInv, chestWidget = entry, inv, widget
    if first then
        ensurePins()
        learnOpenChest()
        L.dbg("chest opened: %s [%s] %s (%s)", entry.name, tostring(keyOf(entry)),
            pinsOf(entry) and ("pinned: " .. (joinNames(pinsOf(entry).rows))) or "not pinned", source)
    end
    return true
end

local function pinOpenChest()
    ensurePins()
    if not openChest and valid(chestWidget) then resolveOpenChest(chestWidget, "pin key") end
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
    pcall(function() pawn = controller.Pawn end)
    if not valid(pawn) then pcall(function() pawn = controller:K2_GetPawn() end) end
    if not valid(pawn) then core.tell("Stow: player character not found"); return end
    pcall(function() backpack = pawn.BackpackInventory end)
    if not valid(backpack) then core.tell(string.format("Stow: backpack not found on %s", core.shortName(pawn))); return end
    local origin = locationOf(pawn)
    local nearby = pinnedNearby(origin, CONFIG.RangeMetres)
    if #nearby == 0 then
        core.tell(string.format("Stow: no pinned chest within %d m", CONFIG.RangeMetres))
        return
    end
    local moved, kept, movedCount = {}, {}, 0
    local slots = slotCount(backpack, CONFIG.MaxBackpackSlots)
    L.dbg("deposit: %d backpack slot(s), %d pinned chest(s) in range", slots, #nearby)
    for slot = 0, slots - 1 do
        local row, count = slotItem(backpack, slot)
        if row then
            L.dbg("deposit: slot %d = %d x %s", slot, count, row)
            local before = count
            local target = nil
            for _, cand in ipairs(nearby) do
                if cand.rec.rows[row] then
                    local inv = inventoryOf(cand.entry)
                    if valid(inv) then
                        L.dbg("deposit: slot %d -> %s", slot, cand.entry.name)
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

-- The chest window's SetupObjectInventory(ContainerInventory) runs when the game fills it in.
local function onChestSetup(self)
    local widget = core.unwrap(self)
    if not valid(widget) then return end
    ExecuteWithDelay(100, function()
        ExecuteInGameThread(function()
            if pcall(resolveOpenChest, widget, "setup") then
                pcall(refreshTitle)
                pcall(refreshButton)
            end
        end)
    end)
end

local function onPanelClosed(self)
    if valid(chestWidget) and core.fullName(core.unwrap(self)) == core.fullName(chestWidget) then
        openChest, openInv = nil, nil
    end
end

-- In-world tooltip (UMG_TooltipInworld_C, one per projection component in view). Its own graph
-- functions (UpdateTooltip, UpdateVisuals) are not reachable by hooks, so the mod remembers the
-- widgets the game creates and, a few times a second, appends the pin line to the description of
-- those whose projection component sits on a pinned chest.
local tooltips = {}        -- tooltip widget full name -> { widget, entry (resolved once), checked }

-- The game rewrites the tooltip's own text blocks every frame, so the pin line lives in a text
-- block of ours, inserted once next to the description and only written when the target changes.
local function tooltipLabel(rec)
    if valid(rec.label) then return rec.label end
    if rec.labelFailed then return nil end
    local ok, err = pcall(function()
        local desc = rec.widget.Description
        if not valid(desc) then error("no Description block") end
        local parent = desc:GetParent()
        if not valid(parent) then error("description has no parent panel") end
        local cls = StaticFindObject("/Script/UMG.TextBlock")
        if not valid(cls) then error("TextBlock class not found") end
        local block = StaticConstructObject(cls, rec.widget)
        if not valid(block) then error("could not construct a TextBlock") end
        local parentClass = core.fullName(parent):match("^(%S+)") or "?"
        if parentClass:find("VerticalBox", 1, true) then parent:AddChildToVerticalBox(block)
        elseif parentClass:find("HorizontalBox", 1, true) then parent:AddChildToHorizontalBox(block)
        elseif parentClass:find("Overlay", 1, true) then parent:AddChildToOverlay(block)
        else error("description sits in a " .. parentClass .. ", which cannot take another child") end
        -- Same face as the description, copied FIELD BY FIELD. Never assign the whole Font struct:
        -- FSlateFontInfo carries a shared pointer reflection does not see, so a struct copy is a raw
        -- byte copy that corrupts the font's reference count and crashes Slate layout later
        -- (SBoxPanel::ComputeDesiredSize, 2026-09-06).
        pcall(function() block.Font.FontObject = desc.Font.FontObject end)
        pcall(function() block.Font.TypefaceFontName = desc.Font.TypefaceFontName end)
        pcall(function() block.Font.Size = desc.Font.Size end)
        pcall(function() block.ColorAndOpacity.SpecifiedColor = desc.ColorAndOpacity.SpecifiedColor end)
        pcall(function() block:SetAutoWrapText(true) end)
        block:SetVisibility(1) -- Collapsed until there is something to show
        rec.label = block
        L.dbg("tooltip label added to %s under a %s", core.shortName(rec.widget), parentClass)
    end)
    if not ok then
        rec.labelFailed = true
        once("tooltipLabel", "tooltip pin line not added (%s)", tostring(err))
    end
    return rec.label
end

-- Show `line` (or nothing when nil) in the tooltip's pin label; writes only on change.
local function showTooltipLine(rec, line)
    if rec.shown == line then return end
    local block = tooltipLabel(rec)
    if not block then return end
    local ok, err = pcall(function()
        if line then
            local text = makeText(line)
            if not text then return end
            block:SetText(text)
            block:SetVisibility(4) -- SelfHitTestInvisible
        else
            block:SetVisibility(1) -- Collapsed
        end
    end)
    if ok then rec.shown = line else once("tooltipShow", "tooltip pin line update failed: %s", tostring(err)) end
end

-- The container a tooltip widget shows right now. The projection component
-- (BP_UIProjectionComponent_Tooltip) is one shared helper that follows the player's aim; its
-- CurrentItem is the actor in view, so this is re-read on every poll (one property read).
local function tooltipEntryOf(rec)
    if not valid(rec.projection) then
        rec.projection = nil
        pcall(function() rec.projection = rec.widget.ProjectionActor end)
        if not valid(rec.projection) then return nil, false end
    end
    local target
    pcall(function() target = rec.projection.CurrentItem end)
    if not valid(target) then return nil, true end
    return containers[core.fullName(target)], true
end

-- Bounded by design: a widget is resolved once (two property reads) and forgotten when it is not
-- on a container; only widgets on PINNED chests do any work per poll (one text read, a write when
-- the game reset it). The poll times itself and stops for good if it ever gets slow.
local pollStats = { polls = 0, tracked = 0, pinnedWidgets = 0, slow = 0, lastMs = 0, worstMs = 0 }

local function pollTooltips()
    if not CONFIG.Tooltip then return end
    local started = os.clock()
    local tracked, pinned = 0, 0
    for name, rec in pairs(tooltips) do
        if not valid(rec.widget) then
            tooltips[name] = nil
        else
            tracked = tracked + 1
            local entry = tooltipEntryOf(rec)
            if entry ~= rec.entry then
                rec.entry = entry
                L.dbg("tooltip %s -> %s", core.shortName(rec.widget), entry and entry.name or "not a container")
            end
            local pinsRec = entry and valid(entry.actor) and pinsOf(entry) or nil
            if pinsRec then
                pinned = pinned + 1
                showTooltipLine(rec, "Pinned: " .. (joinNames(pinsRec.rows)))
            elseif rec.shown then
                showTooltipLine(rec, nil)
            end
        end
    end
    local ms = (os.clock() - started) * 1000
    pollStats.polls, pollStats.tracked, pollStats.pinnedWidgets, pollStats.lastMs = pollStats.polls + 1, tracked, pinned, ms
    if ms > pollStats.worstMs then pollStats.worstMs = ms end
    if ms > CONFIG.TooltipBudgetMs then
        pollStats.slow = pollStats.slow + 1
        if pollStats.slow >= 3 then
            CONFIG.Tooltip = false
            L.log("tooltip poll took %.1f ms three times (%d widgets); tooltip pins switched OFF for this session", ms, tracked)
        end
    end
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
    hookOnce(CONFIG.SetupHook, function(self) pcall(onChestSetup, self) end)
    hookOnce(CONFIG.CloseHook, function(self) pcall(onPanelClosed, self) end)
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
                    pcall(resolveOpenChest, widget, "window")
                    pcall(refreshTitle)
                    pcall(refreshButton)
                end)
            end)
        end)
    end
    tryLateHooks()

    if CONFIG.Tooltip then
        pcall(NotifyOnNewObject, CONFIG.TooltipClass, function(widget)
            if core.fullName(widget):find("Default__", 1, true) then return end
            tooltips[core.fullName(widget)] = { widget = widget }
        end)
        LoopAsync(CONFIG.TooltipPollMs, function()
            if not CONFIG.Tooltip then return true end -- switched off: the loop ends for good
            ExecuteInGameThread(function()
                local ok, err = pcall(pollTooltips)
                if not ok then once("tooltipPoll", "tooltip poll failed: %s", tostring(err)) end
            end)
            return false
        end)
    end

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

-- Core's one-time catch-up scan (after load / player spawn): containers that existed already.
function F.rescan(_, reason)
    local ok, list = pcall(FindAllOf, CONFIG.ScanClass)
    local n = 0
    if ok and list then
        for _, actor in ipairs(list) do registerContainer(actor, "scan:" .. reason); n = n + 1 end
    end
    return string.format("%d container(s) seen, %d registered", n, countContainers())
end

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
        Ar:Log("[Fieldkit:stow] " .. F.rescan(nil, "console"))
        return
    end
    Ar:Log("[Fieldkit:stow] " .. F.status())
    local controller = core.controller()
    local pawn
    pcall(function() pawn = controller.Pawn end)
    if not valid(pawn) then pcall(function() pawn = controller:K2_GetPawn() end) end
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
    Ar:Log(string.format("[Fieldkit:stow] %d container(s) within %d m; open chest: %s; hooks: setup %s close %s tooltip %s button %s",
        #list, CONFIG.RangeMetres, openChest and openChest.name or "none",
        hooks[CONFIG.SetupHook] and "ok" or "no", hooks[CONFIG.CloseHook] and "ok" or "no",
        string.format("%s (%d tracked, %d pinned, last %.2f ms, worst %.2f ms, %d polls)", CONFIG.Tooltip and "polling" or "OFF",
            pollStats.tracked, pollStats.pinnedWidgets, pollStats.lastMs, pollStats.worstMs, pollStats.polls),
        hooks[CONFIG.ButtonClickHook] and "ok" or "no"))
    Ar:Log("[Fieldkit:stow] usage: fieldkit stow | deposit | pins | pin|unpin <row> | clear | names <text> | scan")
end

return F
