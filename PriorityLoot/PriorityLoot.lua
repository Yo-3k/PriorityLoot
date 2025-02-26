-- PriorityLoot.lua
-- A loot priority system for WoW Classic (Season of Discovery)
-- Core functionality

-- Addon metadata
local addonName, PL = ...
PL.version = "1.0.0"
PL.interfaceVersion = 11506 -- Classic SoD

-- Initialize variables
PL.isHost = false
PL.sessionActive = false
PL.currentLootItem = nil
PL.participants = {}
PL.playerName = UnitName("player")
PL.playerFullName = nil -- Will store name-server format
PL.sessionHost = nil
PL.initialized = false
PL.timerDuration = 10 -- Default timer duration now 10 seconds
PL.timerActive = false
PL.timerEndTime = 0
PL.timerFrame = nil
PL.playerPriority = nil -- Track current player's selected priority

-- Communication
PL.COMM_PREFIX = "PriorityLoot"
PL.COMM_JOIN = "JOIN"
PL.COMM_START = "START"
PL.COMM_STOP = "STOP"
PL.COMM_TIMER = "TIMER" -- For timer sync
PL.COMM_LEAVE = "LEAVE" -- For removing player from roll

-- Class colors table
PL.CLASS_COLORS = {
    ["WARRIOR"] = "C79C6E",
    ["PALADIN"] = "F58CBA",
    ["HUNTER"] = "ABD473",
    ["ROGUE"] = "FFF569",
    ["PRIEST"] = "FFFFFF",
    ["SHAMAN"] = "0070DE",
    ["MAGE"] = "69CCF0",
    ["WARLOCK"] = "9482C9",
    ["DRUID"] = "FF7D0A"
}

-- Get player's full name with server
function PL:GetPlayerFullName()
    local name, realm = UnitFullName("player")
    if realm and realm ~= "" then
        return name .. "-" .. realm
    else
        return name
    end
end

-- Normalize a name to handle server names
function PL:NormalizeName(name)
    if not name then return nil end
    
    -- If the name contains a dash (indicating server name)
    if name:find("-") then
        return name
    else
        -- No server in the name, use the player's server if available
        local _, playerRealm = UnitFullName("player")
        if playerRealm and playerRealm ~= "" then
            return name .. "-" .. playerRealm
        else
            return name
        end
    end
end

-- Check if player is master looter
function PL:IsMasterLooter()
    if not IsInRaid() then return false end
    
    local lootMethod, masterLooterPartyID = GetLootMethod()
    if lootMethod ~= "master" then return false end
    
    if masterLooterPartyID == 0 then
        -- Player is master looter
        return true
    else
        -- Get master looter name
        local masterLooterName = UnitName("raid" .. masterLooterPartyID)
        local playerName = UnitName("player")
        return masterLooterName == playerName
    end
end

-- Get display name (without server)
function PL:GetDisplayName(fullName)
    if not fullName then return "" end
    
    local name = fullName
    local dashPos = fullName:find("-")
    if dashPos then
        name = fullName:sub(1, dashPos - 1)
    end
    return name
end

-- Format time as MM:SS
function PL:FormatTime(timeInSeconds)
    local minutes = math.floor(timeInSeconds / 60)
    local seconds = timeInSeconds % 60
    return string.format("%d:%02d", minutes, seconds)
end

-- Broadcast timer information to all raid members
function PL:BroadcastTimerInfo(remainingTime)
    if not self.isHost then return end
    
    local distribution = IsInRaid() and "RAID" or "PARTY"
    C_ChatInfo.SendAddonMessage(self.COMM_PREFIX, self.COMM_TIMER .. ":" .. remainingTime, distribution)
end

-- Get class color for a player
function PL:GetClassColor(name)
    -- Default to white if we can't get the class or if player not found
    local defaultColor = "FFFFFF"
    
    -- Extract name without server for comparison
    local displayName = self:GetDisplayName(name)
    
    -- Get color for yourself
    if displayName == self.playerName then
        local _, playerClass = UnitClass("player")
        return self.CLASS_COLORS[playerClass] or defaultColor
    end
    
    -- Try to get color for raid/party members
    local numGroupMembers = IsInRaid() and GetNumGroupMembers() or GetNumGroupMembers()
    
    if IsInRaid() then
        for i = 1, numGroupMembers do
            local raidName, _, _, _, _, raidClass = GetRaidRosterInfo(i)
            -- Extract name without server for comparison
            raidName = self:GetDisplayName(raidName)
            if raidName == displayName then
                return self.CLASS_COLORS[raidClass] or defaultColor
            end
        end
    else
        -- Check party members
        for i = 1, numGroupMembers - 1 do
            local unit = "party" .. i
            local partyName = UnitName(unit)
            if partyName == displayName then
                local _, partyClass = UnitClass(unit)
                return self.CLASS_COLORS[partyClass] or defaultColor
            end
        end
    end
    
    return defaultColor
end

-- Update player's priority in the participants list
function PL:UpdatePlayerPriority(newPriority)
    -- Store player's priority locally
    self.playerPriority = newPriority
    
    -- Find and update player in participants list
    local playerEntry = nil
    for i, data in ipairs(self.participants) do
        if self:NormalizeName(data.name) == self:NormalizeName(self.playerFullName) then
            playerEntry = data
            playerEntry.priority = newPriority
            break
        end
    end
    
    -- If not found, add player to list
    if not playerEntry then
        table.insert(self.participants, {name = self.playerFullName, priority = newPriority})
    end
    
    -- Broadcast join message with updated priority
    local distribution = IsInRaid() and "RAID" or "PARTY"
    C_ChatInfo.SendAddonMessage(self.COMM_PREFIX, self.COMM_JOIN .. ":" .. self.playerFullName .. "," .. newPriority, distribution)
    
    -- Update UI
    self:UpdateUI()
end

-- Clear player from the current roll
function PL:ClearPlayerRoll()
    if not self.sessionActive then return end
    
    -- Check if player has already joined
    if not self:HasPlayerJoined(self.playerFullName) then
        print("|cffff9900You have not yet joined this roll.|r")
        return
    end
    
    -- Remove player from participants list
    for i, data in ipairs(self.participants) do
        if self:NormalizeName(data.name) == self:NormalizeName(self.playerFullName) then
            table.remove(self.participants, i)
            break
        end
    end
    
    -- Reset player's priority
    self.playerPriority = nil
    
    -- Broadcast removal to all raid members
    local distribution = IsInRaid() and "RAID" or "PARTY"
    C_ChatInfo.SendAddonMessage(self.COMM_PREFIX, self.COMM_LEAVE .. ":" .. self.playerFullName, distribution)
    
    print("|cffff9900You have removed yourself from the roll.|r")
    
    -- Update UI
    self:UpdateUI()
end

-- Start timer for automatic roll stop
function PL:StartTimer(duration)
    if self.timerActive then
        self:StopTimer()
    end
    
    self.timerActive = true
    self.timerEndTime = GetTime() + duration
    
    -- Create or show timer frame
    if not self.timerFrame then
        self.timerFrame = CreateFrame("Frame")
    end
    
    self.timerFrame:SetScript("OnUpdate", function(frame, elapsed)
        if not self.timerActive then return end
        
        local remainingTime = self.timerEndTime - GetTime()
        if remainingTime <= 0 then
            -- Time's up - stop the roll
            self:StopTimer()
            if self.isHost then
                self:StopRollSession()
            end
            return
        end
        
        -- Update timer display every 0.1 seconds to avoid excessive updates
        if not frame.lastUpdate or (GetTime() - frame.lastUpdate) >= 0.1 then
            frame.lastUpdate = GetTime()
            self:UpdateTimerDisplay(remainingTime)
            
            -- Broadcast timer info to all raid members every second
            if self.isHost and (not frame.lastBroadcast or (GetTime() - frame.lastBroadcast) >= 1) then
                frame.lastBroadcast = GetTime()
                self:BroadcastTimerInfo(remainingTime)
            end
        end
    end)
    
    -- Initial update
    self:UpdateTimerDisplay(duration)
    
    -- Initial broadcast
    if self.isHost then
        self:BroadcastTimerInfo(duration)
    end
end

-- Stop the active timer
function PL:StopTimer()
    self.timerActive = false
    if self.timerFrame then
        self.timerFrame:SetScript("OnUpdate", nil)
    end
    
    -- Clear the timer display
    if self.timerDisplay then
        self.timerDisplay:SetText("")
    end
end

-- Start a roll session
function PL:StartRollSession()
    -- Check if in raid
    if not IsInRaid() then
        print("|cffff0000You must be in a raid to start a roll session.|r")
        return
    end
    
    -- Check if master looter
    if not self:IsMasterLooter() then
        print("|cffff0000Only the master looter can start a roll session.|r")
        return
    end
    
    -- Set host status - critical for the Stop button to work
    self.isHost = true
    self.sessionActive = true
    self.sessionHost = self.playerFullName
    self.participants = {}
    self.playerPriority = nil -- Reset player's priority
    
    -- Broadcast start message
    C_ChatInfo.SendAddonMessage(self.COMM_PREFIX, self.COMM_START, "RAID")
    
    print("|cff00ff00You started a roll session.|r")
    
    -- Start timer if enabled
    if self.timerCheckbox:GetChecked() then
        -- Get duration from edit box
        local inputDuration = tonumber(self.timerEditBox:GetText()) or self.timerDuration
        
        -- Ensure it's within reasonable bounds
        if inputDuration < 5 then inputDuration = 5 end
        if inputDuration > 300 then inputDuration = 300 end
        
        self.timerDuration = inputDuration
        self:StartTimer(inputDuration)
        print("|cff00ff00Auto-stop timer set for " .. inputDuration .. " seconds.|r")
    end
    
    -- Update UI
    self:UpdateUI()
end

-- Stop the current roll session
function PL:StopRollSession()
    if self.isHost and self.sessionActive then
        self.sessionActive = false
        
        -- Stop the timer if active
        if self.timerActive then
            self:StopTimer()
        end
        
        -- Broadcast stop message with participant list
        local message = self.COMM_STOP
        for i, data in ipairs(self.participants) do
            message = message .. ":" .. data.name .. "," .. data.priority
        end
        
        C_ChatInfo.SendAddonMessage(self.COMM_PREFIX, message, "RAID")
        
        print("|cffff9900Roll session ended. Results are displayed.|r")
        
        -- Update UI
        self:UpdateUI()
    else
        print("|cffff0000You're not the host or no session is active.|r")
    end
end

-- Join a roll with selected priority
function PL:JoinRoll(priority)
    if not self.sessionActive then return end
    
    -- Update player's priority (whether joining fresh or changing)
    self:UpdatePlayerPriority(priority)
    
    -- Highlight the selected button
    for i = 1, 19 do
        if i == priority then
            self.priorityButtons[i]:SetNormalFontObject("GameFontHighlight")
            self.priorityButtons[i]:LockHighlight()
        else
            self.priorityButtons[i]:SetNormalFontObject("GameFontNormal")
            self.priorityButtons[i]:UnlockHighlight()
        end
    end
    
    -- Print message based on whether this is a change or initial join
    if self:HasPlayerJoined(self.playerFullName) then
        print("|cff00ff00You changed your priority to " .. priority .. ".|r")
    else
        print("|cff00ff00You joined the roll with priority " .. priority .. ".|r")
    end
end

-- Check if player has already joined
function PL:HasPlayerJoined(name)
    for _, data in ipairs(self.participants) do
        -- Normalize both names to ensure consistent comparison
        if self:NormalizeName(data.name) == self:NormalizeName(name) then
            return true
        end
    end
    return false
end

-- Handle addon communication
function PL:OnCommReceived(prefix, message, distribution, sender)
    if prefix ~= self.COMM_PREFIX then return end
    
    -- Normalize the sender name for consistent comparison
    local normalizedSender = self:NormalizeName(sender)
    local normalizedPlayer = self:NormalizeName(self.playerFullName)
    
    if message:find(self.COMM_START) == 1 then
        -- Someone started a roll session
        self.sessionActive = true
        
        -- Show the window for all players when a session starts
        self.PriorityLootFrame:Show()
        
        -- Set host status only if we started the session
        if normalizedSender == normalizedPlayer then
            self.isHost = true
        else
            self.isHost = false
        end
        
        self.sessionHost = sender
        self.participants = {}
        self.playerPriority = nil -- Reset player's priority
        print("|cff00ff00" .. self:GetDisplayName(sender) .. " started a roll session.|r")
        self:UpdateUI()
        
    elseif message:find(self.COMM_JOIN) == 1 then
        -- Someone joined the roll or changed their priority
        local parts = {strsplit(":", message)}
        if parts[2] then
            local namePriority = {strsplit(",", parts[2])}
            if namePriority[1] and namePriority[2] then
                local name = namePriority[1]
                local priority = tonumber(namePriority[2])
                
                -- Check if this is the current player
                if self:NormalizeName(name) == normalizedPlayer then
                    self.playerPriority = priority
                end
                
                -- Add or update participant in the list
                local existingEntry = nil
                for i, data in ipairs(self.participants) do
                    if self:NormalizeName(data.name) == self:NormalizeName(name) then
                        data.priority = priority
                        existingEntry = data
                        break
                    end
                end
                
                if not existingEntry then
                    -- New participant
                    table.insert(self.participants, {name = name, priority = priority})
                    print("|cff00ff00" .. self:GetDisplayName(name) .. " joined the roll.|r")
                else
                    -- Existing participant changed priority
                    print("|cff00ff00" .. self:GetDisplayName(name) .. " changed priority.|r")
                end
                
                self:UpdateUI()
            end
        end
        
    elseif message:find(self.COMM_LEAVE) == 1 then
        -- Someone left the roll
        local parts = {strsplit(":", message)}
        if parts[2] then
            local leavingPlayer = parts[2]
            
            -- Remove player from participants list
            for i, data in ipairs(self.participants) do
                if self:NormalizeName(data.name) == self:NormalizeName(leavingPlayer) then
                    table.remove(self.participants, i)
                    print("|cffff9900" .. self:GetDisplayName(leavingPlayer) .. " left the roll.|r")
                    break
                end
            end
            
            self:UpdateUI()
        end
        
    elseif message:find(self.COMM_TIMER) == 1 then
        -- Timer sync from host
        local parts = {strsplit(":", message)}
        if parts[2] and not self.isHost then
            local remainingTime = tonumber(parts[2])
            if remainingTime and remainingTime > 0 then
                -- Update the timer display for non-hosts
                if not self.timerActive then
                    -- Start a local timer for display purposes only
                    self.timerActive = true
                    
                    if not self.timerFrame then
                        self.timerFrame = CreateFrame("Frame")
                    end
                    
                    self.timerFrame:SetScript("OnUpdate", nil)
                end
                
                self:UpdateTimerDisplay(remainingTime)
            elseif remainingTime and remainingTime <= 0 then
                -- Timer ended
                self:StopTimer()
            end
        end
        
    elseif message:find(self.COMM_STOP) == 1 then
        -- Session ended with results
        self.sessionActive = false
        
        -- Stop the timer if active
        if self.timerActive then
            self:StopTimer()
        end
        
        -- Parse participant list with priorities
        self.participants = {}
        local parts = {strsplit(":", message)}
        for i = 2, #parts do
            local namePriority = {strsplit(",", parts[i])}
            if namePriority[1] and namePriority[2] then
                table.insert(self.participants, {
                    name = namePriority[1],
                    priority = tonumber(namePriority[2])
                })
            end
        end
        
        -- Sort participants by priority (lower is better)
        table.sort(self.participants, function(a, b)
            return a.priority < b.priority
        end)
        
        print("|cffff9900Roll session ended by " .. self:GetDisplayName(sender) .. ". Results are displayed.|r")
        self:UpdateUI()
    end
end

-- Define slash command handler
function PL:SlashCommandHandler(msg)
    if not self.initialized then
        print("|cffff0000PriorityLoot is still initializing. Please try again in a moment.|r")
        return
    end
    
    -- Only allow opening if in a raid
    if not IsInRaid() then
        print("|cffff0000PriorityLoot can only be used while in a raid.|r")
        return
    end
    
    if self.PriorityLootFrame:IsVisible() then
        self.PriorityLootFrame:Hide()
    else
        self.PriorityLootFrame:Show()
    end
end

-- Initialize the addon
local function OnEvent(self, event, ...)
    if event == "ADDON_LOADED" and ... == addonName then
        -- Register comm prefix
        C_ChatInfo.RegisterAddonMessagePrefix(PL.COMM_PREFIX)
        
        -- Get player's full name (with server)
        PL.playerFullName = PL:GetPlayerFullName()
        
        -- Load UI module
        PL:InitUI()
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Get player's full name (with server) when entering world
        PL.playerFullName = PL:GetPlayerFullName()
    elseif event == "CHAT_MSG_ADDON" then
        PL:OnCommReceived(...)
    elseif event == "GROUP_ROSTER_UPDATE" or event == "PARTY_LOOT_METHOD_CHANGED" then
        if PL.initialized then
            PL:UpdateUI()
        end
    end
end

-- Register slash commands
SLASH_PRIORITYLOOT1 = "/priorityloot"
SLASH_PRIORITYLOOT2 = "/pl"
SlashCmdList["PRIORITYLOOT"] = function(msg) PL:SlashCommandHandler(msg) end

-- Create and register events frame
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("CHAT_MSG_ADDON")
eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PARTY_LOOT_METHOD_CHANGED")
eventFrame:SetScript("OnEvent", OnEvent)