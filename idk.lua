--[[ 
    CAC Firebase Outfit Fetcher (2026 Optimized)
    - Fixed: Prevents infinite retry after token expires
    - Improved logging and Firebase request error handling
]]

-- Services
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local VirtualUser = game:GetService("VirtualUser")
local Player = Players.LocalPlayer

-- Firebase
local FIREBASE_URL = "https://cacc-c57bf-default-rtdb.firebaseio.com"
local API_KEY = "AIzaSyBquxKffIm2lBtpi90GLLDdrQG_0yvlo4Y"
local currentIdToken = nil
local lastAuthTime = 0

-- Remotes
local CommunityRemote = ReplicatedStorage:WaitForChild("CommunityOutfitsRemote")
local CatalogGuiRemote = ReplicatedStorage:WaitForChild("CatalogGuiRemote")
local UpdateStatusRemote = ReplicatedStorage:WaitForChild("Events"):WaitForChild("UpdatePlayerStatus")

local active = true
local isProcessing = false

-- Logger
local function createLogger()
    local gui = Instance.new("ScreenGui")
    gui.Name = "CACLogger"
    gui.ResetOnSpawn = false
    gui.Parent = Player:WaitForChild("PlayerGui")

    local box = Instance.new("TextLabel", gui)
    box.Size = UDim2.fromOffset(520, 300)
    box.Position = UDim2.fromOffset(20, 20)
    box.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
    box.TextColor3 = Color3.fromRGB(200, 255, 200)
    box.Font = Enum.Font.Code
    box.TextSize = 14
    box.TextWrapped = true
    box.TextXAlignment = Enum.TextXAlignment.Left
    box.TextYAlignment = Enum.TextYAlignment.Top
    box.Text = "[CAC] Started @ " .. os.date("%X")

    local btn = Instance.new("TextButton", gui)
    btn.Size = UDim2.fromOffset(100, 30)
    btn.Position = UDim2.fromOffset(20, 330)
    btn.Text = "End Script"
    btn.Font = Enum.Font.Code
    btn.TextSize = 14
    btn.BackgroundColor3 = Color3.fromRGB(200, 60, 60)
    btn.TextColor3 = Color3.new(1, 1, 1)
    btn.MouseButton1Click:Connect(function()
        active = false
        gui:Destroy()
        warn("[CAC] Script manually stopped")
    end)

    task.spawn(function()
        while active and box.Parent do
            task.wait(1800)
            if box and box.Parent then
                box.Text = "[CAC] Log cleared @ " .. os.date("%X")
            end
        end
    end)

    return function(msg)
        print("[CAC]", msg)
        if box and box.Parent then
            box.Text ..= "\n" .. msg
            if #box.Text > 5000 then
                box.Text = "[...]\n" .. box.Text:sub(-4000)
            end
        end
    end
end

local log = createLogger()

-- HTTP Helper with error log
local function requestHttp(method, url, body)
    local req = (syn and syn.request) or (http and http.request) or request
    if not req then return end

    local res = req({
        Url = url,
        Method = method,
        Headers = { ["Content-Type"] = "application/json" },
        Body = body and HttpService:JSONEncode(body) or nil
    })

    if not res then
        log("❌ No response from request: " .. url)
        return nil
    end

    if res.StatusCode ~= 200 then
        log("❌ HTTP " .. res.StatusCode .. " on " .. method .. " " .. url)
        return nil
    end

    local ok, data = pcall(function()
        return HttpService:JSONDecode(res.Body)
    end)

    if ok then
        return data
    else
        log("❌ JSON decode failed: " .. res.Body)
    end
end

-- Firebase Auth
local function auth(force)
    if not force and tick() - lastAuthTime < 3300 then return true end
    log("🔐 Authenticating with Firebase...")
    local data = requestHttp(
        "POST",
        "https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=" .. API_KEY,
        { returnSecureToken = true }
    )

    if data and data.idToken then
        currentIdToken = data.idToken
        lastAuthTime = tick()
        log("✅ Firebase authed")
        return true
    else
        log("❌ Firebase auth failed")
        return false
    end
end

-- Firebase Ops (with retry on auth fail)
local function getRequests()
    return requestHttp("GET", FIREBASE_URL .. "/requests.json?auth=" .. currentIdToken) or {}
end

local function sendResult(requestId, payload)
    local success = requestHttp("PATCH", FIREBASE_URL .. "/requests/" .. requestId .. ".json?auth=" .. currentIdToken, {
        result = payload
    })
    if not success then
        log("⚠️ sendResult failed — retrying auth")
        if auth(true) then
            requestHttp("PATCH", FIREBASE_URL .. "/requests/" .. requestId .. ".json?auth=" .. currentIdToken, {
                result = payload
            })
        end
    else
        log("📤 Sent result to " .. requestId)
    end
end

local function markProcessing(requestId, value)
    local success = requestHttp("PATCH", FIREBASE_URL .. "/requests/" .. requestId .. ".json?auth=" .. currentIdToken, {
        processing = value
    })
    if not success then
        log("⚠️ markProcessing failed — retrying auth")
        if auth(true) then
            requestHttp("PATCH", FIREBASE_URL .. "/requests/" .. requestId .. ".json?auth=" .. currentIdToken, {
                processing = value
            })
        end
    end
end

-- Force Reset
local function forceReset()
    pcall(function()
        CatalogGuiRemote:InvokeServer({
            Action = "MorphIntoPlayer",
            UserId = Player.UserId,
            RigType = Enum.HumanoidRigType.R15
        })
    end)
    pcall(function()
        UpdateStatusRemote:FireServer("None")
    end)
    log("♻️ Character reset triggered")
end

-- Core Handler
local function handleCode(requestId, rawHex)
    isProcessing = true
    markProcessing(requestId, true)

    local code = tonumber(rawHex, 16)
    if not code then
        sendResult(requestId, { error = "Invalid hex" })
        isProcessing = false
        return
    end

    log("📨 Processing CAC " .. code .. " (req: " .. requestId .. ")")

    local success, outfit = pcall(function()
        return CommunityRemote:InvokeServer({
            Action = "GetFromOutfitCode",
            OutfitCode = code
        })
    end)

    if not success or not outfit then
        sendResult(requestId, { error = "Failed to fetch outfit" })
        isProcessing = false
        return
    end

    local ok = pcall(function()
        CommunityRemote:InvokeServer({
            Action = "WearCommunityOutfit",
            OutfitInfo = outfit
        })
    end)

    if not ok then
        sendResult(requestId, { error = "Failed to apply outfit" })
        isProcessing = false
        return
    end

    local char = Player.Character or Player.CharacterAdded:Wait()
    local hum
    repeat task.wait(0.2) hum = char:FindFirstChildOfClass("Humanoid") until hum

    local desc = hum:FindFirstChildOfClass("HumanoidDescription")
    if not desc then
        sendResult(requestId, { error = "No HumanoidDescription" })
        isProcessing = false
        return
    end

    local rigType = hum.RigType == Enum.HumanoidRigType.R15 and "R15" or "R6"
    log("👤 Rig Type: " .. rigType)

    local otherAccessories = {}
    for _, acc in ipairs(desc:GetAccessories(true)) do
        local entry = {
            assetId = acc.AssetId,
            isLayered = acc.IsLayered,
            type = acc.AccessoryType.Name,
        }
        if acc.Order then entry.order = acc.Order end
        table.insert(otherAccessories, entry)
    end

    local result = {
        RigType = rigType,
        Colors = {
            RightArm = desc.RightArmColor:ToHex(),
            Head = desc.HeadColor:ToHex(),
            RightLeg = desc.RightLegColor:ToHex(),
            Torso = desc.TorsoColor:ToHex(),
            LeftArm = desc.LeftArmColor:ToHex(),
            LeftLeg = desc.LeftLegColor:ToHex(),
        },
        Clothing = {
            Shirt = desc.Shirt,
            Pants = desc.Pants,
        },
        Accessories = {
            Other = otherAccessories
        },
        Scales = {
            BodyType = desc.BodyTypeScale,
            Head = desc.HeadScale,
            Height = desc.HeightScale,
            Depth = desc.DepthScale,
            Proportion = desc.ProportionScale,
            Width = desc.WidthScale,
        },
        Body = {
            RightArm = desc.RightArm,
            RightLeg = desc.RightLeg,
            Head = desc.Head,
            LeftArm = desc.LeftArm,
            Face = desc.Face,
            Torso = desc.Torso,
            LeftLeg = desc.LeftLeg,
        }
    }

    sendResult(requestId, result)
    log("✅ Sent outfit (" .. #otherAccessories .. " accessories)")

    task.delay(3, function()
        forceReset()
        isProcessing = false
    end)
end

-- Main Loop
task.spawn(function()
    if not auth() then return end
    while active do
        task.wait(1.5)
        if isProcessing then continue end

        local requests = getRequests()
        for requestId, data in pairs(requests) do
            if data.code and not data.result and not data.processing then
                handleCode(requestId, data.code)
                break
            end
        end
    end
end)

-- Anti-AFK
task.spawn(function()
    while active do
        Player.Idled:Wait()
        log("⚙️ Anti-AFK triggered")
        VirtualUser:Button2Down(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
        task.wait(1)
        VirtualUser:Button2Up(Vector2.new(0, 0), workspace.CurrentCamera.CFrame)
        task.wait(300)
    end
end)

log("🟢 CAC listener active")
