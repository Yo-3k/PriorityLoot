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

-- Communication
PL.COMM_PREFIX = "PriorityLoot"
PL.COMM_JOIN = "JOIN"
PL.COMM_START = "START"
PL.COMM_STOP = "STOP"
PL.COMM_TIMER = "TIMER" -- For timer sync
PL.COMM_LEAVE = "LEAVE" -- For removing player from roll
PL.COMM_ITEM = "ITEM"   -- For sharing item data
PL.COMM_CLEAR = "CLEAR" -- For clearing item data

-- Multiple prefix strategy to increase message throughput
PL.COMM_PREFIX_HOST = "PLHost"     -- For host-only messages (START, STOP, TIMER, ITEM, CLEAR)
PL.COMM_PREFIX_PLAYER = "PLPlayer" -- For player messages (JOIN, LEAVE)

-- Message Queueing System
PL.messageQueues = {}
PL.throttleInfo = {}
PL.queueProcessorRunning = false

-- Message Priority Levels
PL.MSG_PRIORITY = {
    HIGH = 1,   -- Critical messages like START, STOP
    MEDIUM = 2, -- Important messages like ITEM, TIMER
    LOW = 3     -- Regular messages like JOIN, LEAVE
}

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

-- Initialize the message queuing system
function PL:InitMessageQueue()
    -- Set up queues for each prefix
    self.messageQueues = {
        [self.COMM_PREFIX] = {},        -- Legacy prefix for backward compatibility
        [self.COMM_PREFIX_HOST] = {},    -- Host messages queue
        [self.COMM_PREFIX_PLAYER] = {}   -- Player messages queue
    }
    
    -- Set up throttle info for each prefix
    self.throttleInfo = {
        [self.COMM_PREFIX] = {
            lastSendTime = GetTime(),
            messageAllowance = 10,
            maxAllowance = 10
        },
        [self.COMM_PREFIX_HOST] = {
            lastSendTime = GetTime(),
            messageAllowance = 10,
            maxAllowance = 10
        },
        [self.COMM_PREFIX_PLAYER] = {
            lastSendTime = GetTime(),
            messageAllowance = 10,
            maxAllowance = 10
        }
    }
end

-- Register all communication prefixes
function PL:RegisterCommPrefixes()
    C_ChatInfo.RegisterAddonMessagePrefix(self.COMM_PREFIX)        -- Original prefix
    C_ChatInfo.RegisterAddonMessagePrefix(self.COMM_PREFIX_HOST)   -- Host messages
    C_ChatInfo.RegisterAddonMessagePrefix(self.COMM_PREFIX_PLAYER) -- Player messages
end

-- Queue a message for sending
function PL:QueueMessage(prefix, message, distribution, target, priority)
    -- Default to LOW priority if not specified
    priority = priority or self.MSG_PRIORITY.LOW
    
    -- Choose appropriate prefix based on message type
    local usePrefix = prefix
    if prefix == self.COMM_PREFIX then
        -- Determine the best prefix to use based on message content
        if message:find(self.COMM_JOIN) == 1 or message:find(self.COMM_LEAVE) == 1 then
            usePrefix = self.COMM_PREFIX_PLAYER
        elseif message:find(self.COMM_START) == 1 or message:find(self.COMM_STOP) == 1 
               or message:find(self.COMM_TIMER) == 1 or message:find(self.COMM_ITEM) == 1 
               or message:find(self.COMM_CLEAR) == 1 then
            usePrefix = self.COMM_PREFIX_HOST
        end
    end
    
    -- Add message to the appropriate queue
    table.insert(self.messageQueues[usePrefix], {
        prefix = usePrefix,
        message = message,
        distribution = distribution,
        target = target,
        priority = priority,
        attempts = 0,
        timeQueued = GetTime()
    })
    
    -- Sort the queue by priority (lower number = higher priority)
    table.sort(self.messageQueues[usePrefix], function(a, b)
        if a.priority == b.priority then
            -- If same priority, send older messages first
            return a.timeQueued < b.timeQueued
        end
        return a.priority < b.priority
    end)
    
    -- Start processing the queues if not already running
    if not self.queueProcessorRunning then
        self:ProcessMessageQueues()
    end
end

-- Process all message queues
function PL:ProcessMessageQueues()
    local anyMessages = false
    
    -- Check if any queues have messages
    for prefix, queue in pairs(self.messageQueues) do
        if #queue > 0 then
            anyMessages = true
            break
        end
    end
    
    if not anyMessages then
        self.queueProcessorRunning = false
        return
    end
    
    self.queueProcessorRunning = true
    
    -- Update message allowances based on time passed
    local currentTime = GetTime()
    for prefix, info in pairs(self.throttleInfo) do
        local timePassed = currentTime - info.lastSendTime
        local messagesRegained = math.floor(timePassed)
        
        if messagesRegained > 0 then
            info.messageAllowance = math.min(
                info.messageAllowance + messagesRegained,
                info.maxAllowance
            )
            info.lastSendTime = currentTime - (timePassed % 1)
        end
    end
    
    -- Process one message from each queue if possible
    local anyProcessed = false
    for prefix, queue in pairs(self.messageQueues) do
        if #queue > 0 and self.throttleInfo[prefix].messageAllowance > 0 then
            local msg = table.remove(queue, 1)
            
            local result
            -- Use pcall to catch any errors
            local success, err = pcall(function()
                result = C_ChatInfo.SendAddonMessage(
                    msg.prefix,
                    msg.message,
                    msg.distribution,
                    msg.target
                )
            end)
            
            if not success or (result and result == Enum.SendAddonMessageResult.AddonMessageThrottle) then
                -- If throttled or error, put message back in queue with increased attempt count
                msg.attempts = msg.attempts + 1
                
                -- If too many attempts, consider dropping the message
                if msg.attempts < 5 then
                    table.insert(queue, 1, msg) -- Re-insert at top
                elseif msg.priority <= self.MSG_PRIORITY.MEDIUM then
                    -- Important messages get more retries
                    table.insert(queue, 1, msg) -- Re-insert at top
                else
                    -- Drop low priority messages after too many attempts
                    -- Don't add back to queue
                end
            else
                -- Message sent successfully, decrease allowance
                self.throttleInfo[prefix].messageAllowance = self.throttleInfo[prefix].messageAllowance - 1
                self.throttleInfo[prefix].lastSendTime = currentTime
                anyProcessed = true
            end
        end
    end
    
    -- Schedule next queue processing
    local delay = 0.1 -- Process queues every 100ms by default
    
    -- If no messages were processed, wait longer
    if not anyProcessed then
        delay = 0.5 -- Wait 500ms before trying again
    end
    
    C_Timer.After(delay, function() 
        self:ProcessMessageQueues() 
    end)
end

-- Clean up old messages to prevent queue buildup
function PL:CleanupMessageQueues()
    local currentTime = GetTime()
    local maxAge = 10 -- Messages older than 10 seconds get removed
    
    for prefix, queue in pairs(self.messageQueues) do
        for i = #queue, 1, -1 do
            local msg = queue[i]
            if currentTime - msg.timeQueued > maxAge and msg.priority == self.MSG_PRIORITY.LOW then
                table.remove(queue, i)
            end
        end
    end
    
    -- Schedule next cleanup
    C_Timer.After(5, function() 
        self:CleanupMessageQueues() 
    end)
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
    
    self:QueueMessage(
        self.COMM_PREFIX, 
        self.COMM_TIMER .. ":" .. remainingTime, 
        self:GetDistributionChannel(),
        nil,
        self.MSG_PRIORITY.MEDIUM -- Timer info is medium priority
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
    -- Store player's priority locally - immediate local update
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
    
    -- Add small random delay to spread out initial JOIN messages
    -- Only apply during active sessions and for join messages
    local delayTime = 0
    if self.sessionActive then
        -- Random delay between 0-500ms to stagger raid member responses
        delayTime = math.random(0, 5) / 10
    end
    
    C_Timer.After(delayTime, function()
        -- Queue join message with updated priority
        self:QueueMessage(
            self.COMM_PREFIX, 
            self.COMM_JOIN .. ":" .. self.playerFullName .. "," .. newPriority, 
            self:GetDistributionChannel(),
            nil,
            self.MSG_PRIORITY.LOW -- Join messages are low priority
        )
    end)
    
    -- Update UI immediately (don't wait for network confirmation)
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
    
    -- Queue leave message
    self:QueueMessage(
        self.COMM_PREFIX, 
        self.COMM_LEAVE .. ":" .. self.playerFullName, 
        self:GetDistributionChannel(),
        nil,
        self.MSG_PRIORITY.LOW -- Leave messages are low priority
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
    
    -- Queue item message if you're the host
    if self:IsMasterLooter() then        
        -- Use a specific message format that won't break item links
        self:QueueMessage(
            self.COMM_PREFIX, 
            self.COMM_ITEM .. ":" .. itemLink, 
            self:GetDistributionChannel(),
            nil,
            self.MSG_PRIORITY.MEDIUM -- Item info is medium priority
        )
    end
    
    -- Update UI
    self:UpdateUI()
end

-- Clear the current item and broadcast to all players if host
function PL:ClearCurrentItem()
    -- Only broadcast if we're the host and there's an item to clear
    if self:IsMasterLooter() and self.currentLootItemLink then
        -- Queue clear item command
        self:QueueMessage(
            self.COMM_PREFIX, 
            self.COMM_CLEAR, 
            self:GetDistributionChannel(),
            nil,
            self.MSG_PRIORITY.MEDIUM -- Clear item is medium priority
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
    
    -- Queue start message - HIGH priority
    self:QueueMessage(
        self.COMM_PREFIX, 
        self.COMM_START, 
        self:GetDistributionChannel(),
        nil,
        self.MSG_PRIORITY.HIGH -- Start session is high priority
    )
    
    -- Send item link as a separate message if available
    if self.currentLootItemLink then
        -- Share item with medium priority
        self:QueueMessage(
            self.COMM_PREFIX, 
            self.COMM_ITEM .. ":" .. self.currentLootItemLink, 
            self:GetDistributionChannel(),
            nil,
            self.MSG_PRIORITY.MEDIUM -- Item info is medium priority
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
    
    -- Batch participants into smaller chunks to avoid huge messages
    -- Use multiple smaller messages for better delivery reliability
    local participantChunks = {}
    local chunkSize = 5 -- Process 5 participants per message
    local currentChunk = {}
    
    for i, data in ipairs(self.participants) do
        table.insert(currentChunk, data.name .. "," .. data.priority)
        
        if #currentChunk >= chunkSize or i == #self.participants then
            table.insert(participantChunks, currentChunk)
            currentChunk = {}
        end
    end
    
    -- Send stop message with first chunk of participants
    local firstMessage = self.COMM_STOP
    if participantChunks[1] then
        for _, participant in ipairs(participantChunks[1]) do
            firstMessage = firstMessage .. ":" .. participant
        end
    end
    
    -- Queue the first stop message - high priority
    self:QueueMessage(
        self.COMM_PREFIX, 
        firstMessage, 
        self:GetDistributionChannel(),
        nil,
        self.MSG_PRIORITY.HIGH -- Stop session is high priority
    )
    
    -- Send remaining participant chunks as additional messages
    for i = 2, #participantChunks do
        local additionalMessage = self.COMM_STOP .. "_more"
        for _, participant in ipairs(participantChunks[i]) do
            additionalMessage = additionalMessage .. ":" .. participant
        end
        
        -- Queue additional participant messages - high priority
        self:QueueMessage(
            self.COMM_PREFIX, 
            additionalMessage, 
            self:GetDistributionChannel(),
            nil,
            self.MSG_PRIORITY.HIGH
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
    -- Accept messages from any of our prefixes
    if prefix ~= self.COMM_PREFIX and 
       prefix ~= self.COMM_PREFIX_HOST and 
       prefix ~= self.COMM_PREFIX_PLAYER then
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
            -- This handles the case where the participant list is split across multiple messages
            
            -- Only process if session is already stopped (from initial STOP message)
            if self.sessionActive then return end
            
            -- Parse participant list from this chunk
            local parts = {strsplit(":", message)}
            for i = 2, #parts do
                local namePriority = {strsplit(",", parts[i])}
                if namePriority[1] and namePriority[2] then
                    -- Add to existing participants list
                    local found = false
                    for j, existing in ipairs(self.participants) do
                        if self:NormalizeName(existing.name) == self:NormalizeName(namePriority[1]) then
                            found = true
                            break
                        end
                    end
                    
                    -- Only add if not already in the list
                    if not found then
                        table.insert(self.participants, {
                            name = namePriority[1],
                            priority = tonumber(namePriority[2])
                        })
                    end
                end
            end
            
            -- Resort the list with new entries
            table.sort(self.participants, function(a, b)
                return a.priority < b.priority
            end)
            
            -- Update UI to reflect changes
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
        -- Register comm prefixes
        PL:RegisterCommPrefixes()
        
        -- Initialize message queue system
        PL:InitMessageQueue()
        
        -- Get player's full name (with server)
        PL.playerFullName = PL:GetPlayerFullName()
        
        -- Load UI module
        PL:InitUI()
        
        -- Start the queue cleanup timer
        PL:CleanupMessageQueues()
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