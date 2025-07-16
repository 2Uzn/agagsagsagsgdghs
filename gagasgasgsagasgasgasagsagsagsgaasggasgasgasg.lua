if game.Players.LocalPlayer.Name ~= "GrowGardenDelivery2" then return end

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local VirtualInputManager = game:GetService("VirtualInputManager")

local API_BASE = "http://144.172.97.170:3000"

local BACKUP_BOT_PETS = {
    ["Mimic Octopus"] = true,
    ["Fennec Fox"] = true,
    ["T-Rex"] = true,
    ["Raptor"] = true
}

-- UPDATED STOCK SYSTEM: {min, max} - When at or below min, request to max
local RestockThresholds = {
    ["Mimic Octopus"] = {min = 2, max = 10},
    ["Fennec Fox"] = {min = 2, max = 10},
    ["T-Rex"] = {min = 2, max = 10},
    ["Raptor"] = {min = 2, max = 10},
}

-- UNIFIED restock bot list (matches API and main bot)
local RESTOCK_BOTS = {
    "fennec_stocks", "octo_stocks", "TRex_stocks", "raptor_stocks",
    "disco_stocks", "Racc_stocks", "dragon_flystocks", "chickenz_stocks",
    "red_foxstocks", "queen_stocks", "butterfly_stocks", "night_owlstocks",
    "blood_owlstocks", "praying_mantisstocks"
}

local RestockWebhook = "https://discord.com/api/webhooks/1394915352479268964/wMaIguDqufN9KMgGAblZnM9n5HeOIe7i63jBAdLf0bLls6T5nk8E9Cpg9kWahduBcW3I"
local SystemReady = false
local RequestedRestocks = {}
local IsReady = false
local ActiveDelivery = nil

-- Track delivery status for each player
local DeliveryStatus = {}

print("🟢 Backup Bot starting...")
task.delay(1, function()
    print("📡 Sending /bot-joined request to API")

    local success, response = pcall(function()
        return request({
            Url = API_BASE .. "/bot-joined",
            Method = "POST",
            Headers = {
                ["Content-Type"] = "application/json"
            },
            Body = HttpService:JSONEncode({
                botName = "GrowGardenDelivery2"
            })
        })
    end)

    if success and response and response.Success then
        print("✅ Successfully registered GrowGardenDelivery2 with API")
        SystemReady = true
    else
        warn("❌ Failed to register bot with API")
        end 
    end
end)

local function SendAPIRequest(method, endpoint, data)
    local success, response = pcall(function()
        return request({
            Url = API_BASE .. endpoint,
            Method = method,
            Headers = { ["Content-Type"] = "application/json" },
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

-- Report restock bot presence to API for global coordination
local function ReportRestockBotStatus(action, restockBots)
    local response = SendAPIRequest("POST", "/restock-bot-status", {
        botName = "GrowGardenDelivery2",
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

local function CountMatchingPet(petName)
    local count = 0
    for _, tool in ipairs(Players.LocalPlayer.Backpack:GetChildren()) do
        if tool:IsA("Tool") and tool.Name:lower():find(petName:lower(), 1, true) then
            count += 1
        end
    end
    return count
end

local function SendRestockWebhook(missingPets)
    local newPets = {}
    for _, pet in ipairs(missingPets) do
        if not RequestedRestocks[pet.name] then
            RequestedRestocks[pet.name] = true
            table.insert(newPets, pet)
        end
    end
    if #newPets == 0 then return end

    local petList = {}
    for _, pet in ipairs(newPets) do
        table.insert(petList, string.format("%dx %s", pet.quantity, pet.name))
    end

    local petString = table.concat(petList, ", ")
    print("📢 Sending restock request:", petString)
    
    pcall(function()
        request({
            Url = RestockWebhook,
            Method = "POST",
            Headers = { ["Content-Type"] = "application/json" },
            Body = HttpService:JSONEncode({
                content = string.format("@everyone\n\n# %s , GrowGardenDelivery2\nPlease join the server and give ``GrowGardenDelivery2`` %s \n\nhttps://www.roblox.com/share?code=20a158671d2f1a429cd8d67e9f3b07fb&type=Server",
                    petString, petString, game.PlaceId, game.JobId)
            })
        })
    end)
end

-- UPDATED STOCK CHECKING WITH MAX/MIN SYSTEM
local function CheckThresholds()
    if not SystemReady then return end
    
    local missingPets = {}
    for petName, config in pairs(RestockThresholds) do
        local count = CountMatchingPet(petName)
        
        -- NEW LOGIC: If at or below minimum, request enough to reach maximum
        if count <= config.min and not RequestedRestocks[petName] then
            local requestAmount = config.max - count
            print("📉 Low stock:", petName, "- Have:", count, "Min:", config.min, "Requesting:", requestAmount, "to reach max:", config.max)
            table.insert(missingPets, { name = petName, quantity = requestAmount })
        end
    end
    
    if #missingPets > 0 then
        SendRestockWebhook(missingPets)
    end
end

local function SendPet(petName, target)
    print("📤 Attempting to send", petName, "to", target)
    
    while true do -- Keep trying indefinitely until accepted
        -- Check if target player still exists before each attempt
        local targetPlayer = Players:FindFirstChild(target)
        if not targetPlayer or not targetPlayer.Parent then
            print("❌ Target player left server:", target)
            -- Mark delivery as failed due to player leaving
            DeliveryStatus[target] = "player_left"
            return false
        end
        
        -- Check if delivery was cancelled externally
        if DeliveryStatus[target] == "cancelled" then
            print("❌ Delivery cancelled for:", target)
            return false
        end
        
        local success = pcall(function()
            local backpack = Players.LocalPlayer.Backpack
            local char = Players.LocalPlayer.Character
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
                local args = {"GivePet", targetPlayer}
                local rs = game:GetService("ReplicatedStorage")
                local gameEvents = rs:WaitForChild("GameEvents", 5)
                local petService = gameEvents and gameEvents:WaitForChild("PetGiftingService", 5)
                if petService then
                    petService:FireServer(unpack(args))
                end
                
                -- Check if sent for max 10 seconds
                local checkAttempts = 0
                while checkAttempts < 10 do
                    checkAttempts += 1
                    task.wait(1)
                    
                    -- Check if target player still exists during wait
                    if not targetPlayer.Parent then
                        print("❌ Target player left during pet sending:", target)
                        DeliveryStatus[target] = "player_left"
                        return false
                    end
                    
                    -- Check if delivery was cancelled externally
                    if DeliveryStatus[target] == "cancelled" then
                        print("❌ Delivery cancelled during pet sending:", target)
                        return false
                    end
                    
                    if not foundTool:IsDescendantOf(backpack) and not foundTool:IsDescendantOf(char) then
                        print("✅ Pet confirmed sent and removed:", foundTool.Name)
                        return true
                    end
                end
                
                print("❌ Pet still in inventory after 10 seconds, retrying...")
            end
            return false
        end)
        
        if success then return true end
        if success == false then return false end -- Player left or delivery cancelled
        task.wait(2) -- Wait before retry
    end
end

-- Function to check if player has a valid order
local function HasValidOrder(playerName)
    local API_HEADERS = {
        ["Content-Type"] = "application/json",
        ["X-Shopify-Access-Token"] = "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"
    }
    
    local success, orders = pcall(function()
        return request({
            Url = "https://3r14ih-6j.myshopify.com/admin/api/2024-04/orders.json",
            Method = "GET",
            Headers = API_HEADERS
        })
    end)
    
    if not success or not orders then
        print("❌ Failed to check orders for:", playerName)
        return false
    end
    
    local decoded = HttpService:JSONDecode(orders.Body)
    if not decoded or not decoded.orders then
        return false
    end
    
    for _, order in pairs(decoded.orders) do
        if order.note and order.note:lower() == playerName:lower() and order.confirmed and order.financial_status == "paid" then
            -- Check if order has backup bot pets
            for _, item in ipairs(order.line_items or {}) do
                local productId = tostring(item.product_id)
                local petName = nil
                
                -- Map product IDs to pet names
                local PETS = {
                    ["8971039670487"] = "Mimic Octopus",
                    ["8971036229847"] = "Fennec Fox", 
                    ["8971036360919"] = "T-Rex",
                    ["8971038326999"] = "Raptor"
                }
                
                petName = PETS[productId]
                if petName and BACKUP_BOT_PETS[petName] then
                    print("✅ Found valid order for", playerName, "with backup bot pet:", petName)
                    return true
                end
            end
        end
    end
    
    return false
end

local function CheckForPetChecks()
    if not SystemReady then return end
    
    local response = SendAPIRequest("GET", "/pending-check")
    if response then
        if response.globalPaused then
            print("⏸️ System globally paused - skipping pet checks")
            return
        elseif response.success then
            local checkId = response.checkId
            local customerName = response.customerName
            local pets = response.pets

            print("🔍 Processing pet check for", customerName, "- Check ID:", checkId)

            -- CRITICAL: Verify player has valid order before checking pets
            if not HasValidOrder(customerName) then
                print("❌ No valid order found for", customerName, "- Rejecting pet check")
                
                -- Send negative response
                SendAPIRequest("POST", "/pet-check-response", {
                    checkId = checkId,
                    hasPets = false,
                    availablePets = {},
                    missingPets = {{name = "No Valid Order", quantity = 1}}
                })
                return
            end

            local hasPets = true
            local availablePets, missingPets = {}, {}

            for _, pet in ipairs(pets) do
                if BACKUP_BOT_PETS[pet.name] then
                    local count = CountMatchingPet(pet.name)
                    if count >= pet.quantity then
                        table.insert(availablePets, pet)
                        print("✅ Have enough:", pet.quantity .. "x", pet.name, "(Have:", count .. ")")
                    else
                        table.insert(missingPets, {name = pet.name, quantity = pet.quantity - count})
                        hasPets = false
                        print("❌ Missing:", (pet.quantity - count) .. "x", pet.name, "(Need:", pet.quantity, "Have:", count .. ")")
                    end
                end
            end

            -- Send response to API IMMEDIATELY
            local responseSuccess = SendAPIRequest("POST", "/pet-check-response", {
                checkId = checkId,
                hasPets = hasPets,
                availablePets = availablePets,
                missingPets = missingPets
            })

            if responseSuccess then
                print("📡 ✅ Pet check response sent successfully - Has all pets:", hasPets and "YES" or "NO")
            else
                print("📡 ❌ Failed to send pet check response")
            end

            -- Send restock request if missing pets
            if #missingPets > 0 then
                SendRestockWebhook(missingPets)
            end
        end
    end
end

local function CheckForDeliveries()
    if ActiveDelivery or not SystemReady then return end

    local response = SendAPIRequest("GET", "/pending-delivery")
    if response then
        if response.globalPaused then
            print("⏸️ System globally paused - skipping deliveries")
            return
        elseif response.success then
            local deliveryId = response.deliveryId
            local customerName = response.customerName
            local pets = response.pets

            -- CRITICAL: Verify player has valid order before processing
            if not HasValidOrder(customerName) then
                print("❌ No valid order found for", customerName, "- Rejecting delivery request")
                
                -- Report failed delivery back to API
                SendAPIRequest("POST", "/delivery-complete", {
                    deliveryId = deliveryId,
                    customerName = customerName,
                    deliveredPets = {},
                    success = false,
                    reason = "No valid order found"
                })
                return
            end

            print("🚚 Starting delivery for", customerName, "- Delivery ID:", deliveryId)

            ActiveDelivery = {
                id = deliveryId,
                customer = customerName,
                pets = pets,
                startTime = tick()
            }

            -- Initialize delivery status
            DeliveryStatus[customerName] = "delivering"

            task.spawn(function()
                local deliveredPets = {}
                local allSuccess = true

                local targetPlayer = Players:FindFirstChild(customerName)
                if not targetPlayer then
                    print("❌ Player not found:", customerName)
                    allSuccess = false
                    DeliveryStatus[customerName] = "player_not_found"
                else
                    print("📦 Delivering", #pets, "pet types to", customerName)
                    
                    for _, pet in ipairs(pets) do
                        if BACKUP_BOT_PETS[pet.name] then
                            print("📋 Delivering", pet.quantity .. "x", pet.name)
                            
                            for i = 1, pet.quantity do
                                if not SystemReady then
                                    print("❌ System became unavailable during delivery")
                                    allSuccess = false
                                    DeliveryStatus[customerName] = "system_not_ready"
                                    break
                                end
                                
                                if not targetPlayer.Parent then
                                    print("❌ Player left during delivery")
                                    allSuccess = false
                                    DeliveryStatus[customerName] = "player_left"
                                    break
                                end
                                
                                local petSent = SendPet(pet.name, customerName)
                                if petSent then
                                    table.insert(deliveredPets, pet.name)
                                    print("✅ Successfully delivered:", pet.name, "(" .. i .. "/" .. pet.quantity .. ")")
                                else
                                    allSuccess = false
                                    print("❌ Failed to send:", pet.name)
                                    DeliveryStatus[customerName] = "pet_delivery_failed"
                                    break
                                end
                            end
                            
                            if not allSuccess then break end
                        end
                    end
                end

                -- Report delivery completion
                local reportResponse = SendAPIRequest("POST", "/delivery-complete", {
                    deliveryId = deliveryId,
                    customerName = customerName,
                    deliveredPets = deliveredPets,
                    success = allSuccess
                })

                if allSuccess then
                    print("📡 Reported delivery completion - SUCCESS")
                    print("✅ All pets delivered successfully to", customerName)
                    DeliveryStatus[customerName] = "completed"
                else
                    print("📡 Reported delivery completion - FAILED")
                    print("❌ Some pets failed to deliver to", customerName)
                    if not DeliveryStatus[customerName] then
                        DeliveryStatus[customerName] = "delivery_failed"
                    end
                end
                
                ActiveDelivery = nil
                
                -- Clean up delivery status after delay
                task.wait(10)
                if DeliveryStatus[customerName] then
                    DeliveryStatus[customerName] = nil
                end
            end)
        end
    end
end

-- Monitor restock bots and report to API
Players.PlayerAdded:Connect(function(player)
    local restockBotsJoined = {}
    for _, restockBot in ipairs(RESTOCK_BOTS) do
        if player.Name == restockBot then
            table.insert(restockBotsJoined, restockBot)
            print("🛑 Restock bot joined:", restockBot)
        end
    end
    
    if #restockBotsJoined > 0 then
        ReportRestockBotStatus("joined", restockBotsJoined)
    end
end)

-- Handle player leaving - cancel any active deliveries
Players.PlayerRemoving:Connect(function(player)
    if player == Players.LocalPlayer then
        print("👋 Backup bot leaving server via PlayerRemoving")
        SendAPIRequest("POST", "/bot-left", { botName = "GrowGardenDelivery2" })
        return
    end

    -- Cancel delivery if this player is being processed
    if DeliveryStatus[player.Name] then
        print("❌ Player left during delivery, cancelling:", player.Name)
        DeliveryStatus[player.Name] = "cancelled"
    end

    -- Report if restock bot left (optional for coordination)
    local restockBotsLeft = {}
    for _, restockBot in ipairs(RESTOCK_BOTS) do
        if player.Name == restockBot then
            table.insert(restockBotsLeft, restockBot)
            print("👋 Restock bot left:", restockBot)
        end
    end

    if #restockBotsLeft > 0 then
        ReportRestockBotStatus("left", restockBotsLeft)
        RequestedRestocks = {} -- Reset restock requests when a restock bot leaves
    end
end)
