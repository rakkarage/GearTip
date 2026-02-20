local inspectCache = {}
local inspectQueue = {}
local queuedGuids = {}
local currentlyInspecting = nil
local inspectingUnit = nil
local inspectingTime = 0
local lastInspectTime = 0
local CACHE_TTL = 300
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

local function EnqueueInspect(unit)
	if not unit or not UnitExists(unit) or not UnitIsPlayer(unit) then return end
	if UnitIsUnit(unit, "player") then return end
	if not CanInspect(unit) then return end
	local guid = UnitGUID(unit)
	if not guid then return end
	local cached = inspectCache[guid]
	if cached and (GetTime() - cached.time) < CACHE_TTL then return end
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
		if not UnitExists(entry.unit) or UnitGUID(entry.unit) ~= entry.guid then
			entry = nil
		end
	until entry or #inspectQueue == 0
	if not entry then return end

	if not CanInspect(entry.unit) then return end
	NotifyInspect(entry.unit)
	currentlyInspecting = entry.guid
	inspectingUnit = entry.unit
	inspectingTime = GetTime()
	lastInspectTime = GetTime()
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("INSPECT_READY")
frame:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
frame:SetScript("OnEvent", function(_, event, guid)
	if event == "UPDATE_MOUSEOVER_UNIT" then
		local unit = "mouseover"
		if UnitExists(unit) and UnitIsPlayer(unit) and not UnitIsUnit(unit, "player") then
			EnqueueInspect(unit)
		end
	elseif event == "INSPECT_READY" then
		if guid ~= currentlyInspecting then
			ClearInspectPlayer()
			return
		end
		local unit = (UnitExists("mouseover") and UnitGUID("mouseover") == guid)
			and "mouseover" or inspectingUnit
		local ilvl = CalculateItemLevel(unit)
		if ilvl then
			inspectCache[guid] = { ilvl = ilvl, time = GetTime() }
			if UnitExists("mouseover") and UnitGUID("mouseover") == guid then
				GameTooltip:AddLine(string.format("Item Level: %.1f", ilvl), 1, 1, 0.5)
				GameTooltip:Show()
			end
		end
		currentlyInspecting = nil
		inspectingUnit = nil
		inspectingTime = 0
		ClearInspectPlayer()
	end
end)

frame:SetScript("OnUpdate", DrainQueue)

TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tooltip, data)
	if tooltip ~= GameTooltip or not data then return end
	local unit = data.unitToken
	if not unit and UnitExists("mouseover") then unit = "mouseover" end
	if not unit or not UnitIsPlayer(unit) then return end

	local ilvl
	if UnitIsUnit(unit, "player") then
		local _, equipped = GetAverageItemLevel()
		ilvl = equipped
	else
		local guid = UnitGUID(unit)
		local cached = guid and inspectCache[guid]
		if cached and (GetTime() - cached.time) < CACHE_TTL then
			ilvl = cached.ilvl
		else
			EnqueueInspect(unit)
		end
	end

	if ilvl then
		tooltip:AddLine(string.format("Item Level: %.1f", ilvl), 1, 1, 0.5)
		tooltip:Show()
	end
end)
