local inspectCache = {}
local inspectQueue = {}
local queuedGuids = {}
local currentlyInspecting = nil
local inspectingUnit = nil
local inspectingTime = 0
local lastInspectTime = 0
local CACHE_TTL = 300
local SELF_CACHE_TTL = 30
local INSPECT_TIMEOUT = 5

local function CalculateItemLevel(unit)
	if not unit or not UnitExists(unit) or not UnitIsPlayer(unit) then return nil end
	local totalItemLevel, itemCount = 0, 0
	for _, slotId in ipairs({ 1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17 }) do
		local itemLink = GetInventoryItemLink(unit, slotId)
		if itemLink then
			local itemLevel = C_Item.GetDetailedItemLevelInfo(itemLink)
			if itemLevel and itemLevel > 0 then
				totalItemLevel = totalItemLevel + itemLevel
				itemCount = itemCount + 1
			end
		end
	end
	return itemCount > 0 and (totalItemLevel / itemCount) or nil
end

local function GetSelfIlvl()
	local selfGuid = UnitGUID("player")
	local cached = inspectCache[selfGuid]
	if cached and (GetTime() - cached.time) < SELF_CACHE_TTL then
		return cached.ilvl
	end
	local _, equipped = GetAverageItemLevel()
	inspectCache[selfGuid] = { ilvl = equipped, time = GetTime() }
	return equipped
end

local function AddIlvlLine(tooltip, ilvl, selfIlvl)
	local icon = ilvl >= selfIlvl
		and "|TInterface\\Icons\\Inv_10_engineering_manufacturedparts_gear_firey:14|t"
		or "|TInterface\\Icons\\Inv_misc_gear_01:14|t"
	local color = ilvl >= selfIlvl and "|cFF1eff00" or "|cFFaaaaaa"
	tooltip:AddLine(icon .. color .. string.format(" %.1f", ilvl) .. "|r")
	tooltip:Show()
end

local function EnqueueInspect(unit)
	if not unit or not UnitExists(unit) or not UnitIsPlayer(unit) then return end
	if UnitIsUnit(unit, "player") then return end
	if not CanInspect(unit) then return end
	local guid = UnitGUID(unit)
	if not guid or issecretvalue(guid) then return end
	if inspectCache[guid] and (GetTime() - inspectCache[guid].time) < CACHE_TTL then return end
	if queuedGuids[guid] or currentlyInspecting == guid then return end
	table.insert(inspectQueue, { guid = guid, unit = unit })
	queuedGuids[guid] = true
end

local function DrainQueue()
	if currentlyInspecting and (GetTime() - inspectingTime) > INSPECT_TIMEOUT then
		queuedGuids[currentlyInspecting] = nil
		currentlyInspecting = nil
		inspectingUnit = nil
		inspectingTime = 0
		ClearInspectPlayer()
	end

	if currentlyInspecting then return end
	if #inspectQueue == 0 then return end
	if (GetTime() - lastInspectTime) < 1 then return end

	local entry
	repeat
		entry = table.remove(inspectQueue, 1)
		if not entry then return end
		queuedGuids[entry.guid] = nil
		if not UnitExists(entry.unit) or not CanInspect(entry.unit) then
			entry = nil
		end
	until entry or #inspectQueue == 0
	if not entry then return end

	NotifyInspect(entry.unit)
	currentlyInspecting = entry.guid
	inspectingUnit = entry.unit
	inspectingTime = GetTime()
	lastInspectTime = GetTime()
end

local function InvalidateSelfCache()
	local selfGuid = UnitGUID("player")
	inspectCache[selfGuid] = nil
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("INSPECT_READY")
frame:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
frame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
frame:RegisterEvent("ACTIVE_PLAYER_SPECIALIZATION_CHANGED")
frame:SetScript("OnEvent", function(_, event)
	if event == "UPDATE_MOUSEOVER_UNIT" then
		if UnitExists("mouseover") and UnitIsPlayer("mouseover") and not UnitIsUnit("mouseover", "player") then
			EnqueueInspect("mouseover")
		end
	elseif event == "PLAYER_EQUIPMENT_CHANGED" or event == "ACTIVE_PLAYER_SPECIALIZATION_CHANGED" then
		InvalidateSelfCache()
	elseif event == "INSPECT_READY" then
		if not currentlyInspecting then
			ClearInspectPlayer()
			return
		end
		local ilvl = CalculateItemLevel(inspectingUnit)
		if ilvl then
			inspectCache[currentlyInspecting] = { ilvl = ilvl, time = GetTime() }
			if UnitExists("mouseover") and inspectingUnit == "mouseover" then
				AddIlvlLine(GameTooltip, ilvl, GetSelfIlvl())
			end
		end
		currentlyInspecting = nil
		inspectingUnit = nil
		inspectingTime = 0
		ClearInspectPlayer()
	end
end)

C_Timer.NewTicker(0.1, DrainQueue)

TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tooltip, data)
	if tooltip ~= GameTooltip or not data then return end
	local unit = data.unitToken
	if not unit and UnitExists("mouseover") then unit = "mouseover" end
	if not unit or not UnitIsPlayer(unit) then return end

	local ilvl
	if UnitIsUnit(unit, "player") then
		ilvl = GetSelfIlvl()
	else
		local guid = UnitGUID(unit)
		if not guid or issecretvalue(guid) then return end
		local cached = inspectCache[guid]
		if cached and (GetTime() - cached.time) < CACHE_TTL then
			ilvl = cached.ilvl
		else
			EnqueueInspect(unit)
		end
	end

	if ilvl then
		AddIlvlLine(tooltip, ilvl, GetSelfIlvl())
	end
end)
