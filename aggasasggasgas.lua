if game.Players.LocalPlayer.Name ~= "GrowGardenDelivery" then return end

local HttpService = game:GetService("HttpService")
local TextChatService = game:GetService("TextChatService")
local VirtualInputManager = game:GetService("VirtualInputManager")

local API_BASE = "http://144.172.97.170:3000"
local API_HEADERS = {
    ["Content-Type"] = "application/json",
    ["X-Shopify-Access-Token"] = "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"
}

local PETS = {
    ["8922681868503"] = "Dragonfly", ["8922681934039"] = "Queen Bee", ["8922682065111"] = "Chicken Zombie",
    ["8922682097879"] = "Red Fox", ["8922682196183"] = "Night Owl", ["8922682261719"] = "Blood Owl",
    ["8922682360023"] = "Praying Mantis", ["8922682458327"] = "Raccoon", ["8928249020631"] = "Disco Bee",
    ["8928249217239"] = "Butterfly", ["8971039670487"] = "Mimic Octopus", ["8971036229847"] = "Fennec Fox",
    ["8971036360919"] = "T-Rex", ["8971038326999"] = "Raptor"
}

-- Pets handled by backup bot
local BACKUP_BOT_PETS = {
    ["Mimic Octopus"] = true,
    ["Fennec Fox"] = true,
    ["T-Rex"] = true,
    ["Raptor"] = true
}

local Queue = {}
local CurrentDelivery = nil
local SystemReady = false

-- UPDATED STOCK SYSTEM: {min, max} - When at or below min, request to max
local StockThresholds = {
    ["Queen Bee"] = {min = 2, max = 5},
    ["Dragonfly"] = {min = 2, max = 10}, 
    ["Chicken Zombie"] = {min = 2, max = 10}, 
    ["Red Fox"] = {min = 2, max = 10}, 
    ["Raccoon"] = {min = 2, max = 10},
    ["Disco Bee"] = {min = 2, max = 10}, 
    ["Butterfly"] = {min = 1, max = 3},
}

local RestockWebhook = "https://discord.com/api/webhooks/1394915354609979432/21PJ6IE18uiNlnfC73rqStejSlaA_qC6yau-h7kjVsXXk8GBhQSAEjdFrcg3P2F34Y_G"

-- UNIFIED restock bot list (matches API and backup bot)
local RESTOCK_BOTS = {
    "disco_stocks", "Racc_stocks", "dragon_flystocks", "chickenz_stocks",
    "red_foxstocks", "queen_stocks", "butterfly_stocks", "night_owlstocks",
    "blood_owlstocks", "praying_mantisstocks"
}

local RequestedRestocks = {}

-- Forward declaration
local ProcessQueue

-- API Helper Functions
local function SendAPIRequest(method, endpoint, data)
    local success, response = pcall(function()
        return request({
            Url = API_BASE .. endpoint,
            Method = method,
            Headers = {["Content-Type"] = "application/json"},
            Body = data and HttpService:JSONEncode(data) or nil
        })
    end)
    
    if success and response then
        local parseSuccess, parsedData = pcall(function()
            return HttpService:JSONDecode(response.Body)
        end)
        return parseSuccess and parsedData or nil
    end
    return nil
end

local function AnnounceJoined()
    SendAPIRequest("POST", "/bot-joined", {botName = "GrowGardenDelivery"})
    print("📢 Announced main bot joined to API")
end

local function AnnounceLeaving()
    SendAPIRequest("POST", "/bot-left", {botName = "GrowGardenDelivery"})
    print("📢 Announced main bot leaving to API")
end

-- Report restock bot presence to API for global coordination
local function ReportRestockBotStatus(action, restockBots)
    local response = SendAPIRequest("POST", "/restock-bot-status", {
        botName = "GrowGardenDelivery",
        restockBots = restockBots,
        action = action  -- "joined" or "left"
    })
    
    if response and response.success then
        print("📡 Reported restock bot status to API:", action, table.concat(restockBots, ", "))
        return response.globalState
    else
        print("❌ Failed to report restock bot status")
        return nil
    end
end

local function CheckSystemStatus()
    local status = SendAPIRequest("GET", "/status")
    if status then
        local wasReady = SystemReady
        SystemReady = status.systemActive
        
        if not wasReady and SystemReady then
            print("✅ SYSTEM READY - Starting delivery system")
            task.delay(1, function()
                ProcessQueue()
            end)
        elseif wasReady and not SystemReady then
            print("❌ SYSTEM PAUSED - Global pause active")
            if status.globalState and status.globalState.restockBotsPresent then
                print("📋 Restock bots present:", table.concat(status.globalState.restockBotsPresent, ", "))
            end
        end
        
        if status.readyIn and status.readyIn > 0 then
            print("⏳ Backup bot ready in", status.readyIn, "seconds")
        end
    else
        if SystemReady then
            SystemReady = false
            print("❌ API connection lost - System paused")
        end
    end
end

local function SplitPetsForDelivery(orderPets)
    local mainBotPets = {}
    local backupBotPets = {}
    
    for _, pet in ipairs(orderPets) do
        if BACKUP_BOT_PETS[pet.name] then
            table.insert(backupBotPets, pet)
        else
            table.insert(mainBotPets, pet)
        end
    end
    
    return mainBotPets, backupBotPets
end

local function CheckBackupBotPets(customerName, pets)
    print("🔍 Checking if backup bot has required pets for", customerName)
    
    local response = SendAPIRequest("POST", "/check-pets", {
        customerName = customerName,
        pets = pets
    })
    
    if response then
        if response.globalPaused then
            print("❌ System globally paused - cannot check pets")
            print("📋 Restock bots present:", table.concat(response.restockBots or {}, ", "))
            return nil
        elseif response.success then
            print("✅ Backup bot pet check request sent, ID:", response.checkId)
            return response.checkId
        else
            print("❌ Failed to request backup bot pet check:", response.error or "Unknown error")
            return nil
        end
    end
    
    return nil
end

local function WaitForBackupBotPetCheck(checkId)
    print("⏳ Waiting for backup bot pet check response (no timeout)...")
    
    while true do
        local status = SendAPIRequest("GET", "/status")
        if status then
            if status.globalState and status.globalState.systemPaused then
                print("❌ System became globally paused during pet check")
                return false, {{name = "System Paused", quantity = 1}}
            end
            
            if status.activeDeliveries then
                for _, delivery in ipairs(status.activeDeliveries) do
                    if delivery.id == checkId and delivery.type == "check" and delivery.checkResponse then
                        local response = delivery.checkResponse
                        print("📋 Backup bot pet check result:", response.hasPets and "✅ HAS PETS" or "❌ MISSING PETS")
                        if not response.hasPets and response.missingPets then
                            print("📋 Missing pets from backup bot:")
                            for _, pet in ipairs(response.missingPets) do
                                print("  - " .. pet.quantity .. "x " .. pet.name)
                            end
                        end
                        return response.hasPets, response.missingPets or {}
                    end
                end
            end
        end
        task.wait(1) -- Check every second instead of every 2 seconds
    end
end

local function RequestBackupBotDelivery(customerName, pets)
    print("📞 Requesting backup bot delivery for", customerName, ":", #pets, "pets")
    
    local response = SendAPIRequest("POST", "/deliver-pets", {
        customerName = customerName,
        pets = pets
    })
    
    if response then
        if response.globalPaused then
            print("❌ System globally paused - cannot start delivery")
            print("📋 Restock bots present:", table.concat(response.restockBots or {}, ", "))
            return nil
        elseif response.success then
            print("✅ Backup bot delivery request sent, ID:", response.deliveryId)
            return response.deliveryId
        else
            print("❌ Failed to request backup bot delivery:", response.error or "Unknown error")
            return nil
        end
    end
    
    return nil
end

local function WaitForBackupBotDelivery(deliveryId)
    print("⏳ Waiting for backup bot delivery completion (no timeout)...")
    
    while true do
        local status = SendAPIRequest("GET", "/status")
        if status then
            if status.globalState and status.globalState.systemPaused then
                print("❌ System became globally paused during delivery")
                return false
            end
            
            if status.activeDeliveries then
                for _, delivery in ipairs(status.activeDeliveries) do
                    if delivery.id == deliveryId then
                        if delivery.status == "completed" then
                            print("✅ Backup bot delivery completed!")
                            return true
                        elseif delivery.status == "failed" then
                            print("❌ Backup bot delivery failed!")
                            return false
                        end
                    end
                end
            end
        end
        task.wait(1) -- Check every second
    end
end

local function SendRestockWebhook(missingPets)
    if #missingPets == 0 then return end
    
    local newPets = {}
    for _, pet in ipairs(missingPets) do
        if not RequestedRestocks[pet.name] then
            RequestedRestocks[pet.name] = true
            table.insert(newPets, pet)
        end
    end
    
    if #newPets == 0 then return end
    
    pcall(function()
        local petList = {}
        for _, pet in ipairs(newPets) do
            table.insert(petList, string.format("%dx %s", pet.quantity, pet.name))
        end
        
        local petString = table.concat(petList, ", ")
        print("📢 Sending restock request:", petString)
        
        request({
            Url = RestockWebhook,
            Method = "POST",
            Headers = {["Content-Type"] = "application/json"},
            Body = HttpService:JSONEncode({
                content = string.format("@everyone \n\n# %s , GrowGardenDelivery\nPlease join the server and give ``GrowGardenDelivery`` %s \n\nhttps://www.roblox.com/share?code=20a158671d2f1a429cd8d67e9f3b07fb&type=Server", 
                    petString, petString, game.PlaceId, game.JobId)
            })
        })
    end)
end

-- UPDATED STOCK CHECKING WITH MAX/MIN SYSTEM
local function CheckStockLevels()
    if not SystemReady then return end
    
    pcall(function()
        local backpack = game.Players.LocalPlayer.Backpack
        if not backpack then return end
        
        local missingPets = {}
        
        for petName, config in pairs(StockThresholds) do
            local count = 0
            for _, tool in ipairs(backpack:GetChildren()) do
                if tool:IsA("Tool") and tool.Name and tool.Name:lower():find(petName:lower(), 1, true) then
                    count += 1
                end
            end
            
            -- NEW LOGIC: If at or below minimum, request enough to reach maximum
            if count <= config.min and not RequestedRestocks[petName] then
                local requestAmount = config.max - count
                print("📉 Low stock:", petName, "- Have:", count, "Min:", config.min, "Requesting:", requestAmount, "to reach max:", config.max)
                table.insert(missingPets, {name = petName, quantity = requestAmount})
            end
        end
        
        if #missingPets > 0 then
            SendRestockWebhook(missingPets)
        end
    end)
end

-- Function to check if we have any sheckles (tools with Weight value)
local function HasSheckles()
    local backpack = game.Players.LocalPlayer.Backpack
    if not backpack then return false end
    
    for _, tool in ipairs(backpack:GetChildren()) do
        if tool:IsA("Tool") and tool:FindFirstChild("Weight") then
            return true
        end
    end
    return false
end

-- Auto-accept gifts from restock bots
task.spawn(function()
    local gui = game.Players.LocalPlayer:WaitForChild("PlayerGui")
    while game.Players.LocalPlayer.Parent do
        pcall(function()
            local giftNotif = gui:FindFirstChild("Gift_Notification")
            if not giftNotif then return end
            
            local frame = giftNotif:FindFirstChild("Frame")
            if not frame then return end
            
            local giftNotif2 = frame:FindFirstChild("Gift_Notification")
            if not giftNotif2 then return end
            
            local holder = giftNotif2:FindFirstChild("Holder")
            if not holder then return end
            
            local innerFrame = holder:FindFirstChild("Frame")
            local notificationUI = holder:FindFirstChild("Notification_UI")
            if not innerFrame or not notificationUI then return end
            
            local acceptButton = innerFrame:FindFirstChild("Accept")
            local textLabel = notificationUI:FindFirstChild("TextLabel")
            if not acceptButton or not textLabel or not acceptButton.Visible then return end
            
            local username = textLabel.Text:match("Gift from @(.+)")
            if username then
                for _, restockBot in ipairs(RESTOCK_BOTS) do
                    if username:lower() == restockBot:lower() then
                        print("🎁 Auto-accepting gift from Restock bot:", username)
                        local x = acceptButton.AbsolutePosition.X + acceptButton.AbsoluteSize.X / 2
                        local y = acceptButton.AbsolutePosition.Y + 66
                        VirtualInputManager:SendMouseButtonEvent(x, y, 0, true, game, 1)
                        task.wait(0.05)
                        VirtualInputManager:SendMouseButtonEvent(x, y, 0, false, game, 1)
                        task.wait(1)
                        break
                    end
                end
            end
        end)
        task.wait(0.5)
    end
end)

local function SendPet(petName, target)
    print("📤 Attempting to send", petName, "to", target)
    
    while true do -- Keep trying indefinitely until accepted
        local success = false
        
        pcall(function()
            local backpack = game.Players.LocalPlayer.Backpack
            local char = game.Players.LocalPlayer.Character
            if not backpack or not char then return end
            
            local foundTool = nil
            for _, tool in ipairs(backpack:GetChildren()) do
                if tool:IsA("Tool") and tool.Name and tool.Name:lower():find(petName:lower(), 1, true) then
                    foundTool = tool
                    break
                end
            end
            
            if not foundTool then
                print("❌ Pet not found in backpack:", petName)
                return
            end
            
            local humanoid = char:FindFirstChild("Humanoid")
            if humanoid then
                humanoid:EquipTool(foundTool)
                task.wait(0.5)
                
                print("📤 Sending", foundTool.Name, "to", target)
                local args = {"GivePet", game:GetService("Players"):WaitForChild(target, 5)}
                local rs = game:GetService("ReplicatedStorage")
                local gameEvents = rs:WaitForChild("GameEvents", 5)
                local petService = gameEvents and gameEvents:WaitForChild("PetGiftingService", 5)
                
                if petService then
                    petService:FireServer(unpack(args))
                end
                
                -- Check if sent (pet removed from inventory)
                local checkAttempts = 0
                while checkAttempts < 15 and (foundTool:IsDescendantOf(backpack) or foundTool:IsDescendantOf(char)) do
                    checkAttempts += 1
                    task.wait(1)
                end
                
                -- Verify pet was actually removed
                if not foundTool:IsDescendantOf(backpack) and not foundTool:IsDescendantOf(char) then
                    print("✅ Pet confirmed sent and removed:", foundTool.Name)
                    success = true
                else
                    print("❌ Pet still in inventory, retrying...")
                end
            end
        end)
        
        if success then return true end
        task.wait(2) -- Wait before retry
    end
end

-- Separate function for coin delivery with proper verification
local function DeliverCoins(player)
    local char = game.Players.LocalPlayer.Character
    if not char then
        print("❌ No character available for coin delivery")
        return false
    end
    
    local backpack = game.Players.LocalPlayer.Backpack
    if not backpack then
        print("❌ No backpack available for coin delivery")
        return false
    end
    
    local bestTool, bestValue = nil, 0
    
    for _, tool in ipairs(backpack:GetChildren()) do
        if tool:IsA("Tool") and tool:FindFirstChild("Weight") then
            local weight = tool.Weight.Value or 0
            if weight > bestValue then
                bestValue, bestTool = weight, tool
            end
        end
    end
    
    if not bestTool then
        print("❌ No suitable tool found for coin delivery")
        return false
    end
    
    print("📤 Sending coins with", bestTool.Name, "to", player.Name)
    local humanoid = char:FindFirstChild("Humanoid")
    if not humanoid then
        print("❌ No humanoid found for coin delivery")
        return false
    end
    
    humanoid:EquipTool(bestTool)
    task.wait(0.5)
    
    local attempts = 0
    local maxAttempts = 60 -- 2 minutes timeout
    
    while (bestTool:IsDescendantOf(backpack) or bestTool:IsDescendantOf(char)) and attempts < maxAttempts do
        attempts += 1
        
        -- Check if player still exists
        if not player.Parent then
            print("❌ Player left during coin delivery")
            return false
        end
        
        local hrp = char:FindFirstChild("HumanoidRootPart")
        local targetChar = player.Character
        local targetHRP = targetChar and targetChar:FindFirstChild("HumanoidRootPart")
        local prompt = targetHRP and targetHRP:FindFirstChild("ProximityPrompt")
        
        if hrp and targetHRP and prompt then
            hrp.CFrame = targetHRP.CFrame
            task.wait(0.5)
            fireproximityprompt(prompt)
        else
            print("❌ Missing components for coin delivery - attempt", attempts)
        end
        task.wait(2)
    end
    
    -- Verify coins were actually delivered
    if not bestTool:IsDescendantOf(backpack) and not bestTool:IsDescendantOf(char) then
        print("✅ Coins delivered successfully!")
        return true
    else
        print("❌ Coin delivery failed - tool still in inventory")
        return false
    end
end

-- IMPROVED ProcessPlayer function without global pcall
local function ProcessPlayer(player)
    if not player or not player.Parent then 
        print("❌ Player no longer exists:", player and player.Name or "unknown")
        return false
    end
    
    -- Double-check system is ready before processing
    if not SystemReady then
        print("❌ System not ready - aborting order processing for:", player.Name)
        return false
    end
    
    print("🔍 Checking orders for:", player.Name)
    
    -- Add timeout for API request
    local orders
    local apiSuccess = pcall(function()
        orders = request({
            Url = "https://3r14ih-6j.myshopify.com/admin/api/2024-04/orders.json",
            Method = "GET",
            Headers = API_HEADERS
        })
    end)
    
    if not apiSuccess or not orders then
        print("❌ Failed to fetch orders for:", player.Name)
        return false
    end
    
    local decoded
    local parseSuccess = pcall(function()
        decoded = HttpService:JSONDecode(orders.Body)
    end)
    
    if not parseSuccess or not decoded or not decoded.orders then
        print("❌ Failed to parse orders for:", player.Name)
        return false
    end
    
    local order = nil
    for _, o in pairs(decoded.orders) do
        if o.note and o.note:lower() == player.Name:lower() and o.confirmed and o.financial_status == "paid" then
            local petItems, coinQty = {}, 0
            
            for _, item in ipairs(o.line_items or {}) do
                local productId = tostring(item.product_id)
                if PETS[productId] then
                    table.insert(petItems, {name = PETS[productId], quantity = item.quantity or 1})
                elseif productId == "8942278246615" then
                    coinQty += item.quantity or 1
                end
            end
            
            if #petItems > 0 or coinQty > 0 then
                order = {id = o.id, pets = petItems, coins = coinQty}
                break
            end
        end
    end
    
    if not order then 
        print("❌ No valid order found for:", player.Name)
        return false
    end
    
    print("✅ Found order for:", player.Name, "- Pets:", #order.pets, "Coins:", order.coins)
    
    -- Check if player still exists before proceeding
    if not player.Parent then
        print("❌ Player left during order processing:", player.Name)
        return false
    end
    
    -- Check if we have sheckles for coin orders
    if order.coins and order.coins > 0 and not HasSheckles() then
        print("❌ No sheckles available for coin order for:", player.Name)
        pcall(function()
            TextChatService.TextChannels.RBXGeneral:SendAsync("Sorry " .. player.Name .. ", we are currently out of sheckles. Please rejoin later when we have restocked!")
        end)
        return false
    end
    
    -- Final system check before delivery
    if not SystemReady then
        print("❌ System became unavailable during order processing for:", player.Name)
        return false
    end
    
    -- Split pets between main and backup bots
    local mainBotPets, backupBotPets = SplitPetsForDelivery(order.pets or {})
    
    print("📊 Order split for", player.Name, "- Main bot:", #mainBotPets, "pets, Backup bot:", #backupBotPets, "pets")
    
    -- Check stock for main bot pets
    local backpack = game.Players.LocalPlayer.Backpack
    if not backpack then 
        print("❌ No backpack available for:", player.Name)
        return false
    end
    
    local missingMainPets = {}
    
    for _, pet in ipairs(mainBotPets) do
        local count = 0
        for _, tool in ipairs(backpack:GetChildren()) do
            if tool:IsA("Tool") and tool.Name and tool.Name:lower():find(pet.name:lower(), 1, true) then
                count += 1
            end
        end
        
        if count < pet.quantity then
            table.insert(missingMainPets, {name = pet.name, quantity = pet.quantity - count})
        end
    end
    
    -- Check if backup bot has its required pets (if any)
    local backupHasPets = true
    local backupMissingPets = {}
    
    if #backupBotPets > 0 then
        print("🔍 Checking backup bot inventory for", player.Name, "- pets:", #backupBotPets)
        local checkId = CheckBackupBotPets(player.Name, backupBotPets)
        if checkId then
            backupHasPets, backupMissingPets = WaitForBackupBotPetCheck(checkId)
        else
            print("❌ Failed to check backup bot pets for:", player.Name)
            backupHasPets = false
            table.insert(backupMissingPets, {name = "Backup Bot Check Failed", quantity = 1})
        end
    end
    
    -- Combine all missing pets from both bots
    local allMissingPets = {}
    
    for _, pet in ipairs(missingMainPets) do
        table.insert(allMissingPets, pet)
    end
    
    for _, pet in ipairs(backupMissingPets) do
        table.insert(allMissingPets, pet)
    end
    
    -- If EITHER bot is missing pets, send restock webhook and abort delivery
    if #allMissingPets > 0 then
        print("❌ ORDER CANNOT BE FULFILLED for", player.Name, "- Missing pets from one or both bots:")
        print("📋 Main bot missing:", #missingMainPets, "pets")
        print("📋 Backup bot missing:", #backupMissingPets, "pets")
        
        for _, pet in ipairs(allMissingPets) do
            print("  ❌ Need", pet.quantity .. "x", pet.name)
        end
        
        SendRestockWebhook(allMissingPets)
        pcall(function()
            local petNames = {}
            for _, pet in ipairs(allMissingPets) do
                table.insert(petNames, pet.name)
            end
            TextChatService.TextChannels.RBXGeneral:SendAsync("Sorry " .. player.Name .. ", we are currently out of " .. table.concat(petNames, ", ") .. ". Please rejoin later when we have restocked!")
        end)
        return false
    end
    
    -- ✅ BOTH BOTS HAVE ALL REQUIRED PETS - START DELIVERY
    print("🎉 BOTH BOTS HAVE ALL PETS - Starting delivery for", player.Name)
    
    -- Check if player still exists before starting delivery
    if not player.Parent then
        print("❌ Player left before delivery started:", player.Name)
        return false
    end
    
    pcall(function()
        TextChatService.TextChannels.RBXGeneral:SendAsync(("Hello %s, thank you for choosing growgarden . gg!"):format(player.Name))
        TextChatService.TextChannels.RBXGeneral:SendAsync("Please accept my trade offers, do NOT leave the game during the delivery process!")
    end)
    
    -- Handle coins first (main bot only)
    if order.coins and order.coins > 0 then
        print("💰 Delivering coins to", player.Name)
        if not DeliverCoins(player) then
            print("❌ Failed to deliver coins to:", player.Name)
            return false
        end
    end
    
    -- Start backup bot delivery first (if needed)
    local backupDeliveryId = nil
    if #backupBotPets > 0 then
        backupDeliveryId = RequestBackupBotDelivery(player.Name, backupBotPets)
        if not backupDeliveryId then
            print("❌ Failed to start backup bot delivery for:", player.Name)
            pcall(function()
                TextChatService.TextChannels.RBXGeneral:SendAsync("⚠️ Backup delivery failed to start - please contact support")
            end)
            return false
        end
    end
    
    -- Deliver main bot pets
    local deliveredPets = {}
    for _, pet in ipairs(mainBotPets) do
        for i = 1, pet.quantity do
            if not player.Parent then 
                print("❌ Player left during pet delivery:", player.Name)
                return false
            end
            if not SystemReady then
                print("❌ System became unavailable during pet delivery for:", player.Name)
                return false
            end
            
            local success = SendPet(pet.name, player.Name)
            if not success then
                print("❌ Failed to send pet", pet.name, "to:", player.Name)
                return false
            end
            table.insert(deliveredPets, pet.name)
        end
    end
    
    -- Wait for backup bot delivery if requested
    if backupDeliveryId then
        print("⏳ Waiting for backup bot to complete delivery for:", player.Name)
        local backupSuccess = WaitForBackupBotDelivery(backupDeliveryId)
        if not backupSuccess then
            print("❌ Backup bot delivery failed for:", player.Name)
            pcall(function()
                TextChatService.TextChannels.RBXGeneral:SendAsync("⚠️ Backup delivery failed - please contact support")
            end)
            return false
        end
    end
    
    pcall(function()
        TextChatService.TextChannels.RBXGeneral:SendAsync("Your order has successfully been delivered!")
        TextChatService.TextChannels.RBXGeneral:SendAsync("Please don't forget to leave a review on Trustpilot ❤️")
    end)
    
    print("🎉 Delivery completed for", player.Name)
    
    -- Only fulfill order if ALL pets were successfully delivered
    print("📋 All pets delivered successfully, fulfilling order...")
    local fulfillSuccess = pcall(function()
        local fulfillmentOrdersData = HttpService:JSONDecode(request({
            Url = string.format("https://3r14ih-6j.myshopify.com/admin/api/2023-04/orders/%d/fulfillment_orders.json", order.id),
            Method = "GET",
            Headers = API_HEADERS
        }).Body)

        for _, fOrder in ipairs(fulfillmentOrdersData.fulfillment_orders or {}) do
            if fOrder.status == "open" then
                request({
                    Url = "https://3r14ih-6j.myshopify.com/admin/api/2023-04/fulfillments.json",
                    Method = "POST",
                    Headers = API_HEADERS,
                    Body = HttpService:JSONEncode({fulfillment = {line_items_by_fulfillment_order = {{fulfillment_order_id = fOrder.id}}}})
                })
                print("✅ Order fulfilled successfully")
                break
            end
        end
    end)
    
    if not fulfillSuccess then
        print("❌ Failed to fulfill order for:", player.Name)
    end
    
    return true -- Success
end

-- IMPROVED ProcessQueue function with better error handling
function ProcessQueue()
    print("🔄 ProcessQueue called - Queue size:", #Queue, "Current delivery:", CurrentDelivery and CurrentDelivery.Name or "none", "System ready:", SystemReady)
    
    if CurrentDelivery then
        print("⏸️ Already processing delivery for:", CurrentDelivery.Name)
        return
    end
    
    if #Queue == 0 then
        print("📭 Queue is empty")
        return
    end
    
    if not SystemReady then
        print("⏸️ Queue paused - System not ready")
        return
    end
    
    local player = table.remove(Queue, 1)
    if not player or not player.Parent then
        print("❌ Player no longer exists, skipping...")
        -- Try next player
        task.delay(1, ProcessQueue)
        return
    end
    
    CurrentDelivery = player
    print("🚀 Starting delivery processing for:", player.Name)
    
    -- Process with timeout mechanism
    local success = false
    local processingThread = task.spawn(function()
        success = ProcessPlayer(player)
        if success then
            print("✅ Successfully processed delivery for:", player.Name)
        else
            print("❌ Failed to process delivery for:", player.Name)
        end
    end)
    
    -- Wait for processing to complete or timeout (5 minutes)
    local timeout = 300
    local elapsed = 0
    
    while elapsed < timeout do
        task.wait(1)
        elapsed += 1
        
        -- Check if processing completed
        if success or not CurrentDelivery then
            break
        end
        
        -- Check if player left during processing
        if not player.Parent then
            print("❌ Player left during processing, canceling...")
            task.cancel(processingThread)
            break
        end
    end
    
    if elapsed >= timeout then
        print("⏰ Processing timed out for:", player.Name)
        task.cancel(processingThread)
    end
    
    -- Always reset CurrentDelivery
    CurrentDelivery = nil
    print("✅ Delivery processing completed for:", player.Name)
    
    -- Process next player after delay
    task.delay(2, ProcessQueue)
end

-- Announce main bot joined on startup
AnnounceJoined()

-- Monitor system status every 3 seconds
task.spawn(function()
    print("🔍 Starting system status monitoring")
    while game.Players.LocalPlayer.Parent do
        CheckSystemStatus()
        task.wait(3)
    end
end)

-- Monitor restock bots and report to API
game.Players.PlayerAdded:Connect(function(player)
    local restockBotsJoined = {}
    for _, restockBot in ipairs(RESTOCK_BOTS) do
        if player.Name == restockBot then
            table.insert(restockBotsJoined, restockBot)
            print("🛑 Restock bot joined:", restockBot)
        end
    end
    
    if #restockBotsJoined > 0 then
        ReportRestockBotStatus("joined", restockBotsJoined)
        return
    end
    
    -- Check if player has valid order before adding to queue
    print("🔍 Checking if", player.Name, "has a valid order...")
    
    -- Regular player joined - check for order before adding to queue
    player.CharacterAdded:Once(function()
        local hasOrder = false
        
        -- Check for valid order
        pcall(function()
            local orders = request({
                Url = "https://3r14ih-6j.myshopify.com/admin/api/2024-04/orders.json",
                Method = "GET",
                Headers = API_HEADERS
            })
            
            local decoded = HttpService:JSONDecode(orders.Body)
            if decoded and decoded.orders then
                for _, o in pairs(decoded.orders) do
                    if o.note and o.note:lower() == player.Name:lower() and o.confirmed and o.financial_status == "paid" then
                        -- Check if order has any valid items
                        for _, item in ipairs(o.line_items or {}) do
                            local productId = tostring(item.product_id)
                            if PETS[productId] or productId == "8942278246615" then -- Pets or coins
                                hasOrder = true
                                break
                            end
                        end
                        if hasOrder then break end
                    end
                end
            end
        end)
        
        if hasOrder then
            table.insert(Queue, player)
            print("➕ Added to queue:", player.Name, "- Position:", #Queue, "(Has valid order)")
            task.wait(5)
            ProcessQueue()
        else
            print("❌ No valid order found for:", player.Name, "- Not adding to queue")
        end
    end)
end)

game.Players.PlayerRemoving:Connect(function(player)
    if player == game.Players.LocalPlayer then
        print("👋 Main bot leaving server via PlayerRemoving")
        AnnounceLeaving()
        return
    end
    
    local restockBotsLeft = {}
    for _, restockBot in ipairs(RESTOCK_BOTS) do
        if player.Name == restockBot then
            table.insert(restockBotsLeft, restockBot)
            print("👋 Restock bot left:", restockBot)
        end
    end
    
    if #restockBotsLeft > 0 then
        ReportRestockBotStatus("left", restockBotsLeft)
        RequestedRestocks = {} -- Reset restock requests when restock bots leave
        return
    end
    
    -- Regular player left
    for i, p in ipairs(Queue) do
        if p == player then
            table.remove(Queue, i)
            print("➖ Removed from queue:", player.Name)
            break
        end
    end
    
    if CurrentDelivery == player then
        print("❌ Player left during delivery:", player.Name)
        CurrentDelivery = nil
        task.delay(1, ProcessQueue)
    end
end)

-- Add existing players to queue (only if they have valid orders)
for _, player in ipairs(game.Players:GetPlayers()) do
    if player ~= game.Players.LocalPlayer then
        local isRestockBot = false
        for _, restockBot in ipairs(RESTOCK_BOTS) do
            if player.Name == restockBot then
                isRestockBot = true
                break
            end
        end
        
        if not isRestockBot then
            -- Check if existing player has valid order
            local hasOrder = false
            pcall(function()
                local orders = request({
                    Url = "https://3r14ih-6j.myshopify.com/admin/api/2024-04/orders.json",
                    Method = "GET",
                    Headers = API_HEADERS
                })
                
                local decoded = HttpService:JSONDecode(orders.Body)
                if decoded and decoded.orders then
                    for _, o in pairs(decoded.orders) do
                        if o.note and o.note:lower() == player.Name:lower() and o.confirmed and o.financial_status == "paid" then
                            -- Check if order has any valid items
                            for _, item in ipairs(o.line_items or {}) do
                                local productId = tostring(item.product_id)
                                if PETS[productId] or productId == "8942278246615" then -- Pets or coins
                                    hasOrder = true
                                    break
                                end
                            end
                            if hasOrder then break end
                        end
                    end
                end
            end)
            
            if hasOrder then
                table.insert(Queue, player)
                print("➕ Added existing player to queue:", player.Name, "(Has valid order)")
            else
                print("❌ Existing player has no valid order:", player.Name, "- Not adding to queue")
            end
        end
    end
end

-- Check for existing restock bots and report
local existingRestockBots = {}
for _, player in ipairs(game.Players:GetPlayers()) do
    for _, restockBot in ipairs(RESTOCK_BOTS) do
        if player.Name == restockBot then
            table.insert(existingRestockBots, restockBot)
            print("🛑 Restock bot already in server:", restockBot)
        end
    end
end

if #existingRestockBots > 0 then
    ReportRestockBotStatus("joined", existingRestockBots)
end

-- Check initial system status
print("🔍 Checking initial system status...")
CheckSystemStatus()

-- Start stock monitoring
task.spawn(function()
    print("📊 Starting periodic stock monitoring (every 30 seconds)")
    while game.Players.LocalPlayer.Parent do
        CheckStockLevels()
        task.wait(30)
    end
end)
