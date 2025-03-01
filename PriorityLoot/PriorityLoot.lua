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
PL.timerLagCompensation = 0.1 -- 100ms lag compensation for initial timer sync
PL.timerActive = false
PL.timerEndTime = 0
PL.timerFrame = nil
PL.playerPriority = nil -- Track current player's selected priority

-- Item tracking variables
PL.currentLootItemLink = nil
PL.currentLootItemTexture = nil

-- Communication constants
PL.COMM_PREFIX = "PriorityLoot"
PL.COMM_JOIN = "JOIN"
PL.COMM_START = "START"
PL.COMM_STOP = "STOP"
PL.COMM_TIMER = "TIMER" -- For timer sync
PL.COMM_LEAVE = "LEAVE" -- For removing player from roll
PL.COMM_ITEM = "ITEM"   -- For sharing item data
PL.COMM_CLEAR = "CLEAR" -- For clearing item data
PL.COMM_PREFIXLIST = "PREFIXLIST" -- For sharing prefix list

-- For the multi-prefix solution
PL.prefixFormat = "PL%d" -- Will create PL1, PL2, PL3, etc.
PL.myPrefixIndex = nil -- This will be assigned during initialization
PL.registeredPrefixes = {} -- Track which prefixes we've registered
PL.availablePrefixes = {} -- Prefix pool that all raid members will share
PL.MAX_PREFIXES = 10 -- Maximum number of different prefixes we'll use
PL.retryMessages = {} -- Simple structure to store messages that need to be retried
PL.retryInterval = 0.5 -- Retry every 0.5 seconds
PL.maxRetries = 10 -- Maximum number of retry attempts
PL.retryFrame = nil -- Frame for handling message retries

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

-- Initialize the multi-prefix system
function PL:InitPrefixSystem()
    -- Create available prefix pool
    for i = 1, self.MAX_PREFIXES do
        table.insert(self.availablePrefixes, string.format(self.prefixFormat, i))
    end
    
    -- Register our main prefix (always used for coordination)
    C_ChatInfo.RegisterAddonMessagePrefix(self.COMM_PREFIX)
    self.registeredPrefixes[self.COMM_PREFIX] = true
    
    -- Register all available prefixes (this ensures everyone listens to all prefixes)
    for _, prefix in ipairs(self.availablePrefixes) do
        C_ChatInfo.RegisterAddonMessagePrefix(prefix)
        self.registeredPrefixes[prefix] = true
    end
    
    -- Assign our own prefix based on a hash of the player name for consistency
    local playerName = UnitName("player")
    local hash = 0
    for i = 1, #playerName do
        hash = hash + string.byte(playerName, i)
    end
    self.myPrefixIndex = (hash % self.MAX_PREFIXES) + 1
    
    -- Create frame for retry handling
    self.retryFrame = CreateFrame("Frame")
    self.retryFrame:SetScript("OnUpdate", function(frame, elapsed)
        frame.elapsed = (frame.elapsed or 0) + elapsed
        if frame.elapsed < self.retryInterval then return end
        frame.elapsed = 0
        
        -- Process any pending retries
        self:ProcessRetries()
    end)
end

-- Get our assigned prefix 
function PL:GetMyPrefix()
    if not self.myPrefixIndex then return self.COMM_PREFIX end
    return self.availablePrefixes[self.myPrefixIndex]
end

-- Process message retries
function PL:ProcessRetries()
    if #self.retryMessages == 0 then return end
    
    -- Process the first message in the retry list
    local msg = table.remove(self.retryMessages, 1)
    
    -- Try to send the message
    local success, result = pcall(function()
        return C_ChatInfo.SendAddonMessage(
            msg.prefix,
            msg.message,
            msg.distribution,
            msg.target
        )
    end)
    
    -- Check if there was an error or throttling
    if not success or result == Enum.SendAddonMessageResult.AddonMessageThrottle then
        -- Increment retry count
        msg.retries = msg.retries + 1
        
        -- If we haven't exceeded max retries, queue for retry
        if msg.retries <= self.maxRetries then
            -- If it was specifically a throttle issue, try a different prefix
            if result == Enum.SendAddonMessageResult.AddonMessageThrottle and msg.prefix ~= self.COMM_PREFIX then
                local nextPrefixIndex = (msg.prefixIndex % self.MAX_PREFIXES) + 1
                msg.prefix = self.availablePrefixes[nextPrefixIndex]
                msg.prefixIndex = nextPrefixIndex
            end
            
            -- Put back at the end of the retry queue
            table.insert(self.retryMessages, msg)
        else
            -- Try again with the main prefix as a fallback
            if msg.prefix ~= self.COMM_PREFIX then
                msg.prefix = self.COMM_PREFIX
                msg.retries = 0
                table.insert(self.retryMessages, msg)
            else
                -- Exceeded max retries - this is bad, we're just going to force it
                -- We don't want to lose messages, so we'll keep trying, but less frequently
                msg.retries = msg.retries - 5 -- Reset some of the retry count
                table.insert(self.retryMessages, msg)
                
                -- Print a warning since this is unusual
                if not msg.warningPrinted then
                    print("|cffff0000Warning: Having trouble sending addon messages. If this persists, try reloading UI.|r")
                    msg.warningPrinted = true
                end
            end
        end
        
        -- Update throttle display to indicate retry state
        self:UpdateThrottleDisplay(#self.retryMessages)
    else
        -- Message sent successfully - update throttle display if any messages left
        if #self.retryMessages > 0 then
            self:UpdateThrottleDisplay(#self.retryMessages)
        else
            self:UpdateThrottleDisplay(0)
        end
    end
end

-- Send message with automatic retry if it fails, using our unique prefix
function PL:SendMessageWithRetry(message, distribution, target)
    -- The prefix we'll try initially
    local prefix = self:GetMyPrefix()
    local prefixIndex = self.myPrefixIndex
    
    -- For coordination messages, always use the main prefix
    if message:find(self.COMM_PREFIXLIST) == 1 then
        prefix = self.COMM_PREFIX
    end
    
    -- First try to send the message directly
    local success, result = pcall(function()
        return C_ChatInfo.SendAddonMessage(
            prefix,
            message,
            distribution,
            target
        )
    end)
    
    -- If there was a problem, add to retry list
    if not success or result == Enum.SendAddonMessageResult.AddonMessageThrottle then
        table.insert(self.retryMessages, {
            prefix = prefix,
            message = message,
            distribution = distribution,
            target = target,
            retries = 0,
            prefixIndex = prefixIndex,
            warningPrinted = false
        })
        
        -- Update throttle display to show pending retries
        self:UpdateThrottleDisplay(#self.retryMessages)
        return false
    end
    
    return true
end

-- Update the throttle display for retries
function PL:UpdateThrottleDisplay(retryCount)
    if not self.throttleDisplay then return end
    
    if retryCount and retryCount > 0 then
        if retryCount > 5 then
            self.throttleDisplay:SetText("Messages pending: " .. retryCount)
            self.throttleDisplay:SetTextColor(1, 0, 0) -- Red
        else
            self.throttleDisplay:SetText("Messages pending: " .. retryCount)
            self.throttleDisplay:SetTextColor(1, 0.5, 0) -- Orange
        end
    else
        self.throttleDisplay:SetText("Message system: Ready")
        self.throttleDisplay:SetTextColor(0, 1, 0) -- Green
    end
end

-- Get player's full name with server
function PL:GetPlayerFullName()
    local name, realm = UnitFullName("player")
    if realm and realm ~= "" then
        return name .. "-" .. realm
    else
        return name
    end
end

-- Get the appropriate distribution channel based on current group
function PL:GetDistributionChannel()
    return IsInRaid() and "RAID" or (IsInGroup() and "PARTY" or "WHISPER")
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
    
    local lootMethod, masterLooterPartyID, masterlooterRaidID = GetLootMethod()
    if lootMethod ~= "master" then return false end
    
    if masterLooterPartyID == 0 then
        -- Player is master looter
        return true
    else
        -- Get master looter name
        local masterLooterName = UnitName("raid" .. masterlooterRaidID)
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
    
    self:SendMessageWithRetry(
        self.COMM_TIMER .. ":" .. remainingTime,
        self:GetDistributionChannel()
    )
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
    
    -- Send JOIN message using player's unique prefix
    self:SendMessageWithRetry(
        self.COMM_JOIN .. ":" .. self.playerFullName .. "," .. newPriority,
        self:GetDistributionChannel()
    )
    
    -- Update UI
    self:UpdateUI()
    
    -- Highlight the selected button
    for i = 1, 19 do
        if i == newPriority then
            self.priorityButtons[i]:SetNormalFontObject("GameFontHighlight")
            self.priorityButtons[i]:LockHighlight()
        else
            self.priorityButtons[i]:SetNormalFontObject("GameFontNormal")
            self.priorityButtons[i]:UnlockHighlight()
        end
    end
    
    -- Print message based on whether this is a change or initial join
    if self:HasPlayerJoined(self.playerFullName) then
        print("|cff00ff00You changed your priority to " .. newPriority .. ".|r")
    else
        print("|cff00ff00You joined the roll with priority " .. newPriority .. ".|r")
    end
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
    
    -- Broadcast leave message
    self:SendMessageWithRetry(
        self.COMM_LEAVE .. ":" .. self.playerFullName,
        self:GetDistributionChannel()
    )
    
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
        end
    end)
    
    -- Initial update
    self:UpdateTimerDisplay(duration)
    
    -- Initial broadcast
    if self.isHost then
        self:BroadcastTimerInfo(duration - self.timerLagCompensation)
    end
end

-- Stop the active timer
function PL:StopTimer()
    if not self.timerActive then return end

    self.timerActive = false

    if self.timerFrame then
        self.timerFrame:SetScript("OnUpdate", nil)
    end
    
    -- Clear the timer display
    if self.timerDisplay then
        self.timerDisplay:SetText("")
    end
    
    -- Force UI update to ensure consistent state
    self:UpdateUI(true)
end

-- Set current item for loot roll
function PL:SetCurrentItem(itemLink)
    if not itemLink then return end
    
    -- Store the item link
    self.currentLootItemLink = itemLink
    
    -- Extract the item texture (for display purposes)
    local _, _, _, _, _, _, _, _, _, itemTexture = GetItemInfo(itemLink)
    self.currentLootItemTexture = itemTexture
    
    -- Broadcast item to other players if you're the host
    if self:IsMasterLooter() then        
        self:SendMessageWithRetry(
            self.COMM_ITEM .. ":" .. itemLink,
            self:GetDistributionChannel()
        )
    end
    
    -- Update UI
    self:UpdateUI()
end

-- Clear the current item and broadcast to all players if host
function PL:ClearCurrentItem()
    -- Only broadcast if we're the host and there's an item to clear
    if self:IsMasterLooter() and self.currentLootItemLink then
        -- Broadcast clear item command
        self:SendMessageWithRetry(
            self.COMM_CLEAR,
            self:GetDistributionChannel()
        )
        print("|cffff9900Item cleared.|r")
    end
    
    -- Clear local item data
    self.currentLootItemLink = nil
    self.currentLootItemTexture = nil
    
    -- Update UI
    self:UpdateUI()
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
    
    -- Update UI immediately to reflect state change
    self:UpdateUI(true)
    
    -- Broadcast start message
    self:SendMessageWithRetry(
        self.COMM_START,
        self:GetDistributionChannel()
    )
    
    -- Send item link as a separate message if available
    if self.currentLootItemLink then
        self:SendMessageWithRetry(
            self.COMM_ITEM .. ":" .. self.currentLootItemLink,
            self:GetDistributionChannel()
        )
        
        -- Show raid warning with item
        local message = "Roll started for " .. self.currentLootItemLink
        if IsInRaid() then
            SendChatMessage(message, "RAID_WARNING")
        else
            SendChatMessage(message, "PARTY")
        end
    else
        local message = "Roll started"
        if IsInRaid() then
            SendChatMessage(message, "RAID_WARNING")
        else
            SendChatMessage(message, "PARTY")
        end
    end
    
    print("|cff00ff00You started a roll session.|r")
    
    -- Start timer if enabled
    if self.timerCheckbox and self.timerCheckbox:GetChecked() then
        -- Get duration from edit box
        local inputDuration = tonumber(self.timerEditBox:GetText()) or self.timerDuration
        
        -- Ensure it's within reasonable bounds
        if inputDuration < 5 then inputDuration = 5 end
        if inputDuration > 60 then inputDuration = 60 end
        
        self.timerDuration = inputDuration
        self:StartTimer(inputDuration)
        print("|cff00ff00Auto-stop timer set for " .. inputDuration .. " seconds.|r")
    end
    
    -- Final UI update
    self:UpdateUI(true)
end

-- Stop the current roll session
function PL:StopRollSession()
    if not self.isHost or not self.sessionActive then
        print("|cffff0000You're not the host or no session is active.|r")
        return
    end
    
    -- Update the state variables
    self.sessionActive = false
    
    -- Stop the timer if active
    if self.timerActive then
        self:StopTimer()
    end
    
    -- Update UI immediately to reflect state change
    self:UpdateUI(true)
    
    -- We need to break the participant list into chunks if it's large
    local chunkSize = 5 -- Maximum participants per message
    local participantChunks = {}
    local chunk = {}
    
    for i, data in ipairs(self.participants) do
        table.insert(chunk, data.name .. "," .. data.priority)
        
        if #chunk >= chunkSize or i == #self.participants then
            table.insert(participantChunks, chunk)
            chunk = {}
        end
    end
    
    -- Send first chunk with main stop message
    local message = self.COMM_STOP
    if #participantChunks > 0 then
        for _, participant in ipairs(participantChunks[1]) do
            message = message .. ":" .. participant
        end
    end
    
    self:SendMessageWithRetry(
        message,
        self:GetDistributionChannel()
    )
    
    -- Send additional chunks if there are more
    for i = 2, #participantChunks do
        local additionalMessage = self.COMM_STOP .. "_more"
        for _, participant in ipairs(participantChunks[i]) do
            additionalMessage = additionalMessage .. ":" .. participant
        end
        
        self:SendMessageWithRetry(
            additionalMessage,
            self:GetDistributionChannel()
        )
    end
    
    print("|cffff9900Roll session ended. Results are displayed.|r")
    
    -- Sort participants by priority (lower is better)
    table.sort(self.participants, function(a, b)
        return a.priority < b.priority
    end)
    
    -- Display raid warning with results
    if #self.participants > 0 then
        local resultMessage = ""
        if self.currentLootItemLink then
            resultMessage = "Roll results for " .. self.currentLootItemLink .. ": "
        else
            resultMessage = "Roll results: "
        end
        
        -- Find all players with the same highest priority
        local highestPriority = self.participants[1].priority
        local winners = {}
        
        for i, data in ipairs(self.participants) do
            if data.priority == highestPriority then
                table.insert(winners, self:GetDisplayName(data.name) .. " (" .. data.priority .. ")")
            else
                -- Stop once we reach a different priority
                break
            end
        end
        
        -- Add all winners to the message
        resultMessage = resultMessage .. table.concat(winners, ", ")
        
        -- Use consistent channel for announcements
        local chatChannel = IsInRaid() and "RAID_WARNING" or "PARTY"
        SendChatMessage(resultMessage, chatChannel)
    end

    -- Final UI update
    self:UpdateUI(true)
end

-- Join a roll with selected priority
function PL:JoinRoll(priority)
    if not self.sessionActive then return end
    
    -- Update player's priority (whether joining fresh or changing)
    self:UpdatePlayerPriority(priority)
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
    -- Accept messages from our main prefix
    local isOurPrefix = (prefix == self.COMM_PREFIX)
    
    -- Or from any of our available prefixes
    for _, availablePrefix in ipairs(self.availablePrefixes) do
        if prefix == availablePrefix then
            isOurPrefix = true
            break
        end
    end
    
    -- Early return if not our prefix
    if not isOurPrefix then
        return
    end
    
    -- Normalize the sender name for consistent comparison
    local normalizedSender = self:NormalizeName(sender)
    local normalizedPlayer = self:NormalizeName(self.playerFullName)
    
    if normalizedPlayer ~= normalizedSender then
        if message:find(self.COMM_START) == 1 then
            -- Someone started a roll session
            self.sessionActive = true
            
            -- Show the window for all players when a session starts
            self.PriorityLootFrame:Show()

            self.isHost = false
            self.sessionHost = sender
            self.participants = {}
            self.playerPriority = nil -- Reset player's priority
            
            -- Don't try to parse item from START message
            -- Item will come in a separate ITEM message
            print("|cff00ff00" .. self:GetDisplayName(sender) .. " started a roll session.|r")
            
            self:UpdateUI()

        elseif message:find(self.COMM_ITEM) == 1 then
            -- Show the window for all players when an item is selected
            self.PriorityLootFrame:Show()

            -- Item info from host
            -- Extract the item link portion after the COMM_ITEM: prefix
            local itemLink = message:sub(#(self.COMM_ITEM .. ":") + 1)
            
            if itemLink and itemLink ~= "" then
                self:SetCurrentItem(itemLink)
                
                print("|cff00ff00" .. self:GetDisplayName(sender) .. " shared item: " .. itemLink .. ".|r")
            end
        
        elseif message == self.COMM_CLEAR then
            -- Host has cleared the item, clear it for everyone
            print("|cffff9900Item cleared by " .. self:GetDisplayName(sender) .. ".|r")
            
            -- Clear local item data but don't re-broadcast
            self.currentLootItemLink = nil
            self.currentLootItemTexture = nil
            
            -- Update UI
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
                    -- Start Timer
                    self:StartTimer(remainingTime)
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
            
            -- Important: We no longer clear the item on roll end
            -- The item remains displayed until cleared manually or a new roll starts
            
            self:UpdateUI()
            
        elseif message:find(self.COMM_STOP .. "_more") == 1 then
            -- Process additional participant chunks from a stop message
            -- Only process if session is already stopped
            if self.sessionActive then return end
            
            -- Parse additional participant list
            local parts = {strsplit(":", message)}
            for i = 2, #parts do
                local namePriority = {strsplit(",", parts[i])}
                if namePriority[1] and namePriority[2] then
                    -- Check if this player is already in the list
                    local found = false
                    for j, data in ipairs(self.participants) do
                        if self:NormalizeName(data.name) == self:NormalizeName(namePriority[1]) then
                            found = true
                            break
                        end
                    end
                    
                    -- Add only if not already in the list
                    if not found then
                        table.insert(self.participants, {
                            name = namePriority[1],
                            priority = tonumber(namePriority[2])
                        })
                    end
                end
            end
            
            -- Sort participants by priority
            table.sort(self.participants, function(a, b)
                return a.priority < b.priority
            end)
            
            -- Update UI with new participant list
            self:UpdateUI()
        end
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
        -- Initialize prefix system
        PL:InitPrefixSystem()
        
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