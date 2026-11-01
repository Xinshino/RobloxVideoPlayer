
-- ============================================================
-- Multi Video Player Client
-- Legacy Black/White + Base64PaletteIndex Color
-- With Admin Video Panel
-- ============================================================

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- ============================================================
-- Remotes
-- ============================================================

local remotes = ReplicatedStorage:WaitForChild("BadAppleRemotes")

local getState = remotes:WaitForChild("GetPlaybackState")
local stateChanged = remotes:WaitForChild("PlaybackState")
local getAvailableVideos = remotes:WaitForChild("GetAvailableVideos")
local requestSelectVideo = remotes:WaitForChild("RequestSelectVideo")

-- ============================================================
-- State
-- ============================================================

local config = nil
local videoName = nil
local frameEncoding = nil

local paletteColors = nil
local chunkModules = nil

local cachedChunkIndex = -1
local cachedFrames = nil

local playbackActive = false
local playbackStartTime = 0
local playbackId = 0

local pixelParts = {}
local lastFrameData = nil

local wall = nil
local sound = nil

-- Pixel spacing: 0.15
local WALL_SPACING = 0.15

-- Admin panel state
local isAdmin = false
local refreshVideoList

-- ============================================================
-- Admin Video Panel
-- ============================================================

local adminGui = Instance.new("ScreenGui")
adminGui.Name = "VideoAdminPanel"
adminGui.ResetOnSpawn = false
adminGui.DisplayOrder = 20
adminGui.Parent = playerGui

local function makeButton(parent, name, text, size, position)
    local button = Instance.new("TextButton")
    button.Name = name
    button.Text = text
    button.Size = size
    button.Position = position
    button.BackgroundColor3 = Color3.fromRGB(45, 45, 55)
    button.TextColor3 = Color3.fromRGB(255, 255, 255)
    button.Font = Enum.Font.Gotham
    button.TextSize = 14
    button.BorderSizePixel = 0
    button.AutoButtonColor = true
    button.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 8)
    corner.Parent = button

    return button
end

local openButton = makeButton(
    adminGui,
    "OpenAdminPanel",
    "🎬 影片管理",
    UDim2.fromOffset(140, 40),
    UDim2.new(0, 16, 1, -56)
)

openButton.Visible = false

local panel = Instance.new("Frame")
panel.Name = "Panel"
panel.Size = UDim2.fromOffset(280, 330)
panel.Position = UDim2.new(0, 16, 1, -398)
panel.BackgroundColor3 = Color3.fromRGB(28, 28, 35)
panel.BorderSizePixel = 0
panel.Visible = false
panel.Parent = adminGui

local panelCorner = Instance.new("UICorner")
panelCorner.CornerRadius = UDim.new(0, 10)
panelCorner.Parent = panel

local title = Instance.new("TextLabel")
title.Name = "Title"
title.Size = UDim2.new(1, -50, 0, 38)
title.Position = UDim2.fromOffset(12, 4)
title.BackgroundTransparency = 1
title.Text = "影片管理員面板"
title.TextColor3 = Color3.new(1, 1, 1)
title.Font = Enum.Font.GothamBold
title.TextSize = 16
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = panel

local closeButton = makeButton(
    panel,
    "Close",
    "✕",
    UDim2.fromOffset(32, 30),
    UDim2.new(1, -40, 0, 8)
)

local statusLabel = Instance.new("TextLabel")
statusLabel.Name = "Status"
statusLabel.Size = UDim2.new(1, -24, 0, 38)
statusLabel.Position = UDim2.fromOffset(12, 42)
statusLabel.BackgroundTransparency = 1
statusLabel.Text = "正在取得影片清單..."
statusLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
statusLabel.Font = Enum.Font.Gotham
statusLabel.TextSize = 12
statusLabel.TextWrapped = true
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.Parent = panel

local videoListFrame = Instance.new("ScrollingFrame")
videoListFrame.Name = "VideoList"
videoListFrame.Size = UDim2.new(1, -24, 1, -94)
videoListFrame.Position = UDim2.fromOffset(12, 84)
videoListFrame.BackgroundColor3 = Color3.fromRGB(38, 38, 46)
videoListFrame.BorderSizePixel = 0
videoListFrame.ScrollBarThickness = 5
videoListFrame.CanvasSize = UDim2.fromOffset(0, 0)
videoListFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
videoListFrame.Parent = panel

local listCorner = Instance.new("UICorner")
listCorner.CornerRadius = UDim.new(0, 6)
listCorner.Parent = videoListFrame

local listLayout = Instance.new("UIListLayout")
listLayout.Padding = UDim.new(0, 6)
listLayout.SortOrder = Enum.SortOrder.LayoutOrder
listLayout.Parent = videoListFrame

local listPadding = Instance.new("UIPadding")
listPadding.PaddingTop = UDim.new(0, 8)
listPadding.PaddingBottom = UDim.new(0, 8)
listPadding.PaddingLeft = UDim.new(0, 8)
listPadding.PaddingRight = UDim.new(0, 8)
listPadding.Parent = videoListFrame

openButton.Activated:Connect(function()
    panel.Visible = not panel.Visible
end)

closeButton.Activated:Connect(function()
    panel.Visible = false
end)

refreshVideoList = function()
    statusLabel.Text = "正在取得影片清單..."

    local ok, videos, currentVideo, admin = pcall(function()
        return getAvailableVideos:InvokeServer()
    end)

    if not ok then
        statusLabel.Text = "取得清單失敗，請查看 Output"
        warn("取得影片清單失敗：", videos)
        return
    end

    isAdmin = admin == true
    openButton.Visible = isAdmin

    if not isAdmin then
        panel.Visible = false
        return
    end

    if typeof(videos) ~= "table" then
        statusLabel.Text = "影片清單格式錯誤"
        warn("GetAvailableVideos 沒有回傳有效的影片清單")
        return
    end

    statusLabel.Text = "目前影片：" .. tostring(currentVideo)

    for _, child in ipairs(videoListFrame:GetChildren()) do
        if child:IsA("TextButton") then
            child:Destroy()
        end
    end

    for index, name in ipairs(videos) do
        if typeof(name) == "string" then
            local buttonText = name

            if name == currentVideo then
                buttonText = "▶  " .. name .. "（目前）"
            end

            local videoButton = makeButton(
                videoListFrame,
                "Video_" .. name,
                buttonText,
                UDim2.new(1, -4, 0, 38),
                UDim2.fromOffset(0, 0)
            )

            videoButton.LayoutOrder = index

            videoButton.Activated:Connect(function()
                if not isAdmin then
                    statusLabel.Text = "你沒有管理員權限"
                    return
                end

                statusLabel.Text = "正在切換影片：" .. name

                local requestOK, result, message = pcall(function()
                    return requestSelectVideo:InvokeServer(name)
                end)

                if not requestOK then
                    statusLabel.Text = "請求失敗，請查看 Output"
                    warn("切換影片請求失敗：", result)
                    return
                end

                if result == false then
                    statusLabel.Text = tostring(
                        message or "切換失敗，可能正在播放"
                    )
                    return
                end

                statusLabel.Text =
                    "已送出切換請求，等待 Server 確認..."

                task.wait(0.3)
                refreshVideoList()
            end)
        end
    end
end

-- Check admin permission on startup
task.spawn(function()
    refreshVideoList()
end)

-- ============================================================
-- Base64 decoder
-- ============================================================

local BASE64 =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local BASE64_LOOKUP = {}

for i = 1, #BASE64 do
    BASE64_LOOKUP[string.byte(BASE64, i)] = i - 1
end

local function decodeBase64(data)
    local output = table.create(math.floor(#data * 3 / 4))

    local accumulator = 0
    local bits = 0
    local count = 0

    for i = 1, #data do
        local byte = string.byte(data, i)

        if byte == 61 then
            break
        end

        local value = BASE64_LOOKUP[byte]

        if value ~= nil then
            accumulator = accumulator * 64 + value
            bits += 6

            if bits >= 8 then
                bits -= 8

                local decodedByte = bit32.band(
                    bit32.rshift(accumulator, bits),
                    255
                )

                count += 1
                output[count] = string.char(decodedByte)

                accumulator = bit32.band(
                    accumulator,
                    bit32.lshift(1, bits) - 1
                )
            end
        end
    end

    return table.concat(output)
end

-- ============================================================
-- Cleanup
-- ============================================================

local function stopPlayback()
    playbackActive = false

    if sound then
        sound:Stop()
    end

    lastFrameData = nil
end

local function destroyWall()
    if wall then
        wall:Destroy()
        wall = nil
    end

    table.clear(pixelParts)
    lastFrameData = nil
end

-- ============================================================
-- Create pixel wall
-- ============================================================

local function createWall()
    destroyWall()

    if not config then
        return
    end

    wall = Instance.new("Folder")
    wall.Name = "BadApplePixelWall"
    wall.Parent = Workspace

    local width = config.Width
    local height = config.Height

    local origin = Vector3.new(
        -(width * WALL_SPACING) / 2,
        8,
        -20
    )

    for y = 1, height do
        for x = 1, width do
            local part = Instance.new("Part")

            part.Name = "Pixel"
            part.Anchored = true

            part.CanCollide = false
            part.CanTouch = false
            part.CanQuery = false

            part.Size = Vector3.new(
                WALL_SPACING * 0.92,
                WALL_SPACING * 0.92,
                0.15
            )

            part.Material = Enum.Material.SmoothPlastic
            part.Color = Color3.new(0, 0, 0)

            part.Position = origin + Vector3.new(
                (x - 0.5) * WALL_SPACING,
                (height - y + 0.5) * WALL_SPACING,
                0
            )

            part.Parent = wall

            local index = (y - 1) * width + x
            pixelParts[index] = part
        end
    end

    print(
        "像素牆建立完成：",
        videoName,
        width,
        "x",
        height,
        "間距：",
        WALL_SPACING
    )
end

-- ============================================================
-- Load video
-- ============================================================

local function loadVideo(name)
    if videoName == name and config then
        return true
    end

    print("正在載入影片：", name)

    local root = ReplicatedStorage:FindFirstChild(name)

    if not root or not root:IsA("Folder") then
        warn("找不到影片資料夾：" .. name)
        return false
    end

    local configModule = root:FindFirstChild("Config")
    local frameFolder = root:FindFirstChild("FrameChunks")
    local paletteModule = root:FindFirstChild("ColorPalette")

    if not configModule or not configModule:IsA("ModuleScript") then
        warn(name .. "：找不到 Config")
        return false
    end

    if not frameFolder or not frameFolder:IsA("Folder") then
        warn(name .. "：找不到 FrameChunks")
        return false
    end

    local configOK, newConfig = pcall(require, configModule)

    if not configOK or typeof(newConfig) ~= "table" then
        warn(name .. "：Config 載入失敗")
        return false
    end

    if
        typeof(newConfig.Width) ~= "number"
        or typeof(newConfig.Height) ~= "number"
        or typeof(newConfig.FPS) ~= "number"
        or typeof(newConfig.FrameCount) ~= "number"
        or newConfig.Width <= 0
        or newConfig.Height <= 0
        or newConfig.FPS <= 0
        or newConfig.FrameCount <= 0
    then
        warn(name .. "：Config 設定不完整")
        return false
    end

    -- Missing FrameEncoding means legacy black/white.
    local newEncoding = newConfig.FrameEncoding

    if newEncoding == nil then
        newEncoding = "LegacyBinary"
    elseif newEncoding ~= "Base64PaletteIndex" then
        warn(name .. "：不支援的格式：" .. tostring(newEncoding))
        return false
    end

    local newPaletteColors = nil

    if newEncoding == "Base64PaletteIndex" then
        if not paletteModule or not paletteModule:IsA("ModuleScript") then
            warn(name .. "：彩色影片缺少 ColorPalette")
            return false
        end

        local paletteOK, palette = pcall(require, paletteModule)

        if not paletteOK or typeof(palette) ~= "table" or #palette == 0 then
            warn(name .. "：ColorPalette 載入失敗")
            return false
        end

        newPaletteColors = {}

        for i, color in ipairs(palette) do
            if
                typeof(color) ~= "table"
                or typeof(color[1]) ~= "number"
                or typeof(color[2]) ~= "number"
                or typeof(color[3]) ~= "number"
            then
                warn(name .. "：調色盤資料錯誤，索引 " .. i)
                return false
            end

            newPaletteColors[i] = Color3.fromRGB(
                math.clamp(math.floor(color[1] + 0.5), 0, 255),
                math.clamp(math.floor(color[2] + 0.5), 0, 255),
                math.clamp(math.floor(color[3] + 0.5), 0, 255)
            )
        end
    end

    local newChunks = {}

    for _, object in ipairs(frameFolder:GetChildren()) do
        if object:IsA("ModuleScript") then
            table.insert(newChunks, object)
        end
    end

    table.sort(newChunks, function(a, b)
        return a.Name < b.Name
    end)

    local framesPerChunk = newConfig.FramesPerChunk or 60

    if framesPerChunk <= 0 then
        warn(name .. "：FramesPerChunk 設定錯誤")
        return false
    end

    local expectedChunks = math.ceil(
        newConfig.FrameCount / framesPerChunk
    )

    if #newChunks < expectedChunks then
        warn(
            name
            .. "：影格區塊不足，預期 "
            .. expectedChunks
            .. "，實際 "
            .. #newChunks
        )

        return false
    end

    if #newChunks == 0 then
        warn(name .. "：沒有影格資料")
        return false
    end

    stopPlayback()

    config = newConfig
    videoName = name
    frameEncoding = newEncoding

    paletteColors = newPaletteColors
    chunkModules = newChunks

    cachedChunkIndex = -1
    cachedFrames = nil

    createWall()

    print(
        "影片載入完成：",
        name,
        "格式：",
        frameEncoding,
        "影格：",
        config.FrameCount
    )

    return true
end

-- ============================================================
-- Load and decode one chunk
-- ============================================================

local function loadChunk(chunkIndex)
    if cachedChunkIndex == chunkIndex and cachedFrames then
        return cachedFrames
    end

    local moduleScript = chunkModules and chunkModules[chunkIndex]

    if not moduleScript then
        warn("找不到影格區塊：" .. tostring(chunkIndex))
        return nil
    end

    local ok, encodedFrames = pcall(require, moduleScript)

    if not ok or typeof(encodedFrames) ~= "table" then
        warn("影格區塊載入失敗：" .. moduleScript.Name)
        return nil
    end

    local decodedFrames = {}
    local expectedPixels = config.Width * config.Height

    for i, frame in ipairs(encodedFrames) do
        if typeof(frame) ~= "string" then
            warn("影格資料不是字串：" .. moduleScript.Name)
            return nil
        end

        local decoded

        if frameEncoding == "Base64PaletteIndex" then
            decoded = decodeBase64(frame)

            if #decoded ~= expectedPixels then
                warn(
                    moduleScript.Name
                    .. " 第 "
                    .. i
                    .. " 幀尺寸錯誤："
                    .. #decoded
                    .. " / "
                    .. expectedPixels
                )

                return nil
            end
        else
            decoded = frame

            if #decoded ~= expectedPixels then
                warn(
                    moduleScript.Name
                    .. " 第 "
                    .. i
                    .. " 幀尺寸錯誤："
                    .. #decoded
                    .. " / "
                    .. expectedPixels
                )

                return nil
            end
        end

        decodedFrames[i] = decoded
    end

    cachedChunkIndex = chunkIndex
    cachedFrames = decodedFrames

    return cachedFrames
end

-- ============================================================
-- Render frame
-- ============================================================

local function renderFrame(frameData)
    if not frameData or not config then
        return
    end

    local pixelCount = config.Width * config.Height

    if #frameData ~= pixelCount then
        return
    end

    if frameData == lastFrameData then
        return
    end

    local previous = lastFrameData

    if frameEncoding == "LegacyBinary" then
        for i = 1, pixelCount do
            local value = string.byte(frameData, i)
            local oldValue = previous and string.byte(previous, i) or -1

            if value ~= oldValue then
                local part = pixelParts[i]

                if part then
                    if value == 49 then
                        part.Color = Color3.new(1, 1, 1)
                    else
                        part.Color = Color3.new(0, 0, 0)
                    end
                end
            end
        end
    else
        for i = 1, pixelCount do
            local paletteIndex = string.byte(frameData, i)
            local oldIndex = previous and string.byte(previous, i) or -1

            if paletteIndex ~= oldIndex then
                local color = paletteColors[paletteIndex + 1]
                local part = pixelParts[i]

                if color and part then
                    part.Color = color
                end
            end
        end
    end

    lastFrameData = frameData
end

-- ============================================================
-- Sound
-- ============================================================

local function normalizeSoundId(soundId)
    if typeof(soundId) == "number" then
        return "rbxassetid://" .. tostring(soundId)
    end

    if typeof(soundId) ~= "string" or soundId == "" then
        return nil
    end

    if string.find(soundId, "rbxassetid://", 1, true) then
        return soundId
    end

    if string.match(soundId, "^%d+$") then
        return "rbxassetid://" .. soundId
    end

    return soundId
end

local function prepareSound(soundId)
    soundId = normalizeSoundId(soundId)

    if not soundId then
        warn(videoName .. "：SoundId 無效")
        return false
    end

    if not sound then
        sound = Instance.new("Sound")
        sound.Name = "BadAppleMusic"
        sound.Volume = 1
        sound.Looped = false
        sound.Parent = Workspace
    end

    if sound.SoundId == soundId and sound.IsLoaded then
        sound:Stop()
        sound.TimePosition = 0
        return true
    end

    sound:Stop()
    sound.SoundId = soundId

    local loaded = sound.IsLoaded
    local connection

    if not loaded then
        connection = sound.Loaded:Connect(function()
            loaded = true
        end)

        sound:Play()

        local deadline = os.clock() + 20

        while not loaded and not sound.IsLoaded and os.clock() < deadline do
            RunService.Heartbeat:Wait()
        end

        if connection then
            connection:Disconnect()
        end

        loaded = loaded or sound.IsLoaded
    end

    if not loaded then
        sound:Stop()
        warn("音訊載入失敗或逾時：" .. soundId)
        return false
    end

    sound:Stop()
    sound.TimePosition = 0

    return true
end

-- ============================================================
-- Start playback
-- ============================================================

local function startPlayback(startTime, newPlaybackId, name)
    playbackActive = false

    playbackStartTime = startTime
    playbackId = newPlaybackId

    if not loadVideo(name) then
        warn("無法載入影片：" .. name)
        return
    end

    if not prepareSound(config.SoundId) then
        warn("無法載入音訊：" .. name)
        return
    end

    lastFrameData = nil
    playbackActive = true

    print(
        "開始播放：",
        name,
        "Playback ID：",
        playbackId
    )
end

-- ============================================================
-- Render loop
-- ============================================================

RunService.RenderStepped:Connect(function()
    if not playbackActive or not config then
        return
    end

    local elapsed =
        Workspace:GetServerTimeNow() - playbackStartTime

    if elapsed < 0 then
        if sound and sound.IsPlaying then
            sound:Pause()
        end

        return
    end

    local frameIndex = math.floor(elapsed * config.FPS) + 1

    if frameIndex > config.FrameCount then
        playbackActive = false

        if sound then
            sound:Stop()
        end

        print("播放完成：", videoName)
        return
    end

    local framesPerChunk = config.FramesPerChunk or 60

    local chunkIndex = math.floor(
        (frameIndex - 1) / framesPerChunk
    ) + 1

    local frameInChunk = (
        (frameIndex - 1) % framesPerChunk
    ) + 1

    local frames = loadChunk(chunkIndex)

    if not frames then
        playbackActive = false
        return
    end

    local frameData = frames[frameInChunk]

    if frameData then
        renderFrame(frameData)
    end

    if sound then
        if not sound.IsPlaying then
            sound:Play()
        end

        local desiredPosition = math.max(0, elapsed)

        if math.abs(sound.TimePosition - desiredPosition) > 0.18 then
            pcall(function()
                sound.TimePosition = desiredPosition
            end)
        end
    end
end)

-- ============================================================
-- Server events
-- ============================================================

stateChanged.OnClientEvent:Connect(function(action, a, b, c)
    if action == "VideoChanged" then
        local name = a

        if typeof(name) ~= "string" then
            return
        end

        if not playbackActive then
            loadVideo(name)
        end

        print("收到影片切換通知：", name)

        if isAdmin then
            task.spawn(function()
                refreshVideoList()
            end)
        end

    elseif action == "Started" then
        local startTime = a
        local newPlaybackId = b
        local name = c

        if
            typeof(startTime) ~= "number"
            or typeof(newPlaybackId) ~= "number"
            or typeof(name) ~= "string"
        then
            warn("Started 事件資料不完整")
            return
        end

        startPlayback(startTime, newPlaybackId, name)

    elseif action == "Finished" then
        local finishedPlaybackId = b

        if finishedPlaybackId == playbackId then
            playbackActive = false

            if sound then
                sound:Stop()
            end

            print("Server 通知播放結束：", videoName)
        end
    end
end)

-- ============================================================
-- Initial synchronization
-- ============================================================

local success, isPlaying, startTime, serverPlaybackId, serverVideoName =
    pcall(function()
        return getState:InvokeServer()
    end)

if not success then
    warn("無法取得 Server 播放狀態：", isPlaying)
    return
end

if typeof(serverVideoName) ~= "string" then
    serverVideoName = "BadApple"
end

if loadVideo(serverVideoName) then
    if isPlaying then
        startPlayback(
            startTime,
            serverPlaybackId,
            serverVideoName
        )
    else
        print("等待播放指令，目前影片：" .. serverVideoName)
    end
end

print("多影片雙格式 Client 已啟動")