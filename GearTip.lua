-- ⚙️ GearTip: Shows average item level on unit tooltips.

local _, ns = ...

ns.GearTip = {
	CACHE_TTL = 300,
	SELF_CACHE_TTL = 30,
	INSPECT_TIMEOUT = 5,
	MAX_QUEUE_SIZE = 50, -- Prevent unbounded queue growth in large raids
	inspectCache = {},
	inspectQueue = {},
	queuedGuids = {},
	currentlyInspecting = nil,
	inspectingTime = 0,
	lastInspectTime = 0,
}
local GearTip = ns.GearTip

local UNIT_TOKENS = { "player", "target", "mouseover", "focus", "targettarget" }
for i = 1, 4 do UNIT_TOKENS[#UNIT_TOKENS + 1] = "party" .. i end
for i = 1, 40 do UNIT_TOKENS[#UNIT_TOKENS + 1] = "raid" .. i end
for i = 1, 40 do UNIT_TOKENS[#UNIT_TOKENS + 1] = "nameplate" .. i end

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

function GearTip:GetSelfIlvl()
	local selfGuid = UnitGUID("player")
	local cached = self.inspectCache[selfGuid]
	if cached and (GetTime() - cached.time) < self.SELF_CACHE_TTL then
		return cached.ilvl
	end
	local _, equipped = GetAverageItemLevel()
	self.inspectCache[selfGuid] = { ilvl = equipped, time = GetTime() }
	return equipped
end

local function GetGradientColor(ilvl, selfIlvl)
	local diff = ilvl - selfIlvl
	local t = math.max(-1, math.min(1, diff / 15)) -- -1 = grey, 0 = white, 1 = green
	local r, g, b
	if t < 0 then
		-- grey (#999999) → white (#ffffff)
		local s = t + 1 -- 0..1
		r = 0.6 + (0.4 * s)
		g = 0.6 + (0.4 * s)
		b = 0.6 + (0.4 * s)
	else
		-- white (#ffffff) → green (#00ff00)
		r = 1 - t
		g = 1
		b = 1 - t
	end
	return r, g, b
end

function GearTip:AddIlvlLine(tooltip, ilvl, selfIlvl)
	local r, g, b = GetGradientColor(ilvl, selfIlvl)
	local hex = string.format("%02x%02x%02x", r * 255, g * 255, b * 255)
	local icon = ilvl >= selfIlvl
		and "|TInterface\\Icons\\Inv_10_engineering_manufacturedparts_gear_firey:14|t"
		or "|TInterface\\Icons\\Inv_misc_gear_01:14|t"
	tooltip:AddLine(icon .. "|cFF" .. hex .. string.format(" %.1f", ilvl) .. "|r")
	tooltip:Show()
end

function GearTip:ResolveGuidToUnit(guid)
	for _, token in ipairs(UNIT_TOKENS) do
		if UnitExists(token) then
			local tokenGuid = UnitGUID(token)
			if tokenGuid and not issecretvalue(tokenGuid) and tokenGuid == guid then
				return token -- Found match, return immediately (early exit optimization)
			end
		end
	end
	return nil
end

function GearTip:EnqueueInspect(unit)
	if not unit or not UnitExists(unit) or not UnitIsPlayer(unit) then return end
	if UnitIsUnit(unit, "player") then return end
	if not CanInspect(unit) then return end
	local guid = UnitGUID(unit)
	if not guid or issecretvalue(guid) then return end
	if self.inspectCache[guid] and (GetTime() - self.inspectCache[guid].time) < self.CACHE_TTL then return end
	if self.queuedGuids[guid] or self.currentlyInspecting == guid then return end
	-- Prevent unbounded queue growth in large raids by capping queue size
	if #self.inspectQueue >= self.MAX_QUEUE_SIZE then return end
	table.insert(self.inspectQueue, guid)
	self.queuedGuids[guid] = true
end

function GearTip:DrainQueue()
	if self.currentlyInspecting and (GetTime() - self.inspectingTime) > self.INSPECT_TIMEOUT then
		self.queuedGuids[self.currentlyInspecting] = nil
		self.currentlyInspecting = nil
		self.inspectingTime = 0
		ClearInspectPlayer()
	end

	if self.currentlyInspecting then return end
	if #self.inspectQueue == 0 then return end
	if (GetTime() - self.lastInspectTime) < 1 then return end

	local guid, unit
	repeat
		guid = table.remove(self.inspectQueue, 1)
		if not guid then return end
		self.queuedGuids[guid] = nil
		unit = self:ResolveGuidToUnit(guid)
		if not unit or not CanInspect(unit) then
			guid = nil
			unit = nil
		end
	until guid or #self.inspectQueue == 0
	if not guid then return end

	NotifyInspect(unit)
	self.currentlyInspecting = guid
	self.inspectingTime = GetTime()
	self.lastInspectTime = GetTime()
end

function GearTip:InvalidateSelfCache()
	self.inspectCache[UnitGUID("player")] = nil
end

function GearTip:EnqueueGroupMembers()
	if GetNumGroupMembers() == 0 then return end
	local prefix = IsInRaid() and "raid" or "party"
	local limit  = IsInRaid() and 40 or 4
	for i = 1, limit do
		local token = prefix .. i
		if UnitExists(token) then
			self:EnqueueInspect(token)
		end
	end
end

GearTip.frame = CreateFrame("Frame")
GearTip.frame:RegisterEvent("INSPECT_READY")
GearTip.frame:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
GearTip.frame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
GearTip.frame:RegisterEvent("ACTIVE_PLAYER_SPECIALIZATION_CHANGED")
GearTip.frame:RegisterEvent("GROUP_ROSTER_UPDATE")
GearTip.frame:SetScript("OnEvent", function(_, event)
	if event == "GROUP_ROSTER_UPDATE" then
		GearTip:EnqueueGroupMembers()
	elseif event == "UPDATE_MOUSEOVER_UNIT" then
		if UnitExists("mouseover") and UnitIsPlayer("mouseover") and not UnitIsUnit("mouseover", "player") then
			GearTip:EnqueueInspect("mouseover")
		end
	elseif event == "PLAYER_EQUIPMENT_CHANGED" or event == "ACTIVE_PLAYER_SPECIALIZATION_CHANGED" then
		GearTip:InvalidateSelfCache()
	elseif event == "INSPECT_READY" then
		if not GearTip.currentlyInspecting then
			ClearInspectPlayer()
			return
		end
		local unit = GearTip:ResolveGuidToUnit(GearTip.currentlyInspecting)
		local ilvl = unit and CalculateItemLevel(unit) or nil
		if ilvl then
			GearTip.inspectCache[GearTip.currentlyInspecting] = { ilvl = ilvl, time = GetTime() }
			local mouseGuid = UnitGUID("mouseover")
			if UnitExists("mouseover") and mouseGuid and not issecretvalue(mouseGuid) and mouseGuid == GearTip.currentlyInspecting then
				GearTip:AddIlvlLine(GameTooltip, ilvl, GearTip:GetSelfIlvl())
			end
		end
		GearTip.currentlyInspecting = nil
		GearTip.inspectingTime = 0
		ClearInspectPlayer()
	end
end)

C_Timer.NewTicker(0.1, function()
	GearTip:DrainQueue()
end)

TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tooltip, data)
	if tooltip ~= GameTooltip or not data then return end
	local unit = data.unitToken
	if not unit and UnitExists("mouseover") then unit = "mouseover" end
	if not unit or not UnitIsPlayer(unit) then return end

	local ilvl
	if UnitIsUnit(unit, "player") then
		ilvl = GearTip:GetSelfIlvl()
	else
		local guid = UnitGUID(unit)
		if not guid or issecretvalue(guid) then return end
		local cached = GearTip.inspectCache[guid]
		if cached and (GetTime() - cached.time) < GearTip.CACHE_TTL then
			ilvl = cached.ilvl
		else
			GearTip:EnqueueInspect(unit)
		end
	end

	if ilvl then
		GearTip:AddIlvlLine(tooltip, ilvl, GearTip:GetSelfIlvl())
	end
end)
