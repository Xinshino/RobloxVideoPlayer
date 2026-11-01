
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local BadgeService = game:GetService("BadgeService")

-- =====================================================
-- 設定
-- =====================================================

local BADGE_ID = 10770140747
local START_DELAY = 5
local WATCH_PERCENT = 0.95

-- 改成你自己的 Roblox UserId
local ADMIN_USER_IDS = {
	[1362542608] = true,
}

-- 新增影片時，在這裡登記資料夾名稱
local VIDEO_CATALOG = {
    "BadApple",
	"Rick",
	"Grass",
}

local DEFAULT_VIDEO = "BadApple"

local remotes = ReplicatedStorage:FindFirstChild("BadAppleRemotes")

if not remotes then
    remotes = Instance.new("Folder")
    remotes.Name = "BadAppleRemotes"
    remotes.Parent = ReplicatedStorage
end

local function getRemote(name, className)
    local remote = remotes:FindFirstChild(name)

    if not remote then
        remote = Instance.new(className)
        remote.Name = name
        remote.Parent = remotes
    end

    assert(
        remote.ClassName == className,
        name .. " 類型錯誤"
    )

    return remote
end

local sync = getRemote("GetSyncInfo", "RemoteFunction")
local requestPlay = getRemote("RequestPlay", "RemoteFunction")
local getState = getRemote("GetPlaybackState", "RemoteFunction")
local stateChanged = getRemote("PlaybackState", "RemoteEvent")

local getAvailableVideos = getRemote(
    "GetAvailableVideos",
    "RemoteFunction"
)

local requestSelectVideo = getRemote(
    "RequestSelectVideo",
    "RemoteFunction"
)

-- =====================================================
-- 權限及影片資料
-- =====================================================

local function isAdmin(player)
    return ADMIN_USER_IDS[player.UserId] == true
end

local function getVideoData(videoName)
    if typeof(videoName) ~= "string" then
        return nil, nil, nil
    end

    local allowed = false

    for _, name in ipairs(VIDEO_CATALOG) do
        if name == videoName then
            allowed = true
            break
        end
    end

    if not allowed then
        return nil, nil, nil
    end

    local root = ReplicatedStorage:FindFirstChild(videoName)

    if not root or not root:IsA("Folder") then
        return nil, nil, nil
    end

    local configModule = root:FindFirstChild("Config")
    local frameFolder = root:FindFirstChild("FrameChunks")

    if not configModule or not configModule:IsA("ModuleScript") then
        return nil, nil, nil
    end

    if not frameFolder or not frameFolder:IsA("Folder") then
        return nil, nil, nil
    end

    local ok, config = pcall(require, configModule)

    if not ok or typeof(config) ~= "table" then
        warn("影片設定載入失敗：" .. videoName)
        return nil, nil, nil
    end

    if
        typeof(config.Width) ~= "number"
        or typeof(config.Height) ~= "number"
        or typeof(config.FPS) ~= "number"
        or typeof(config.FrameCount) ~= "number"
        or config.Width <= 0
        or config.Height <= 0
        or config.FPS <= 0
        or config.FrameCount <= 0
    then
        warn("影片設定不完整：" .. videoName)
        return nil, nil, nil
    end

    return root, config, frameFolder
end

local function getVideoList()
    local result = {}

    for _, videoName in ipairs(VIDEO_CATALOG) do
        local root = getVideoData(videoName)

        if root then
            table.insert(result, videoName)
        end
    end

    return result
end

local currentVideoName = DEFAULT_VIDEO

do
    local root = getVideoData(DEFAULT_VIDEO)

    if not root then
        error("預設影片不存在或設定錯誤：" .. DEFAULT_VIDEO)
    end
end

-- =====================================================
-- 播放狀態
-- =====================================================

local playing = false
local startTime = 0
local playbackId = 0

local activeDuration = 0
local activeRequiredWatchTime = 0
local activeVideoName = DEFAULT_VIDEO

local participantStartTimes = {}

sync.OnServerInvoke = function()
    if playing then
        return startTime
    end

    return 0
end

getState.OnServerInvoke = function()
    return playing, startTime, playbackId, currentVideoName
end

getAvailableVideos.OnServerInvoke = function(player)
    return getVideoList(), currentVideoName, isAdmin(player)
end

-- =====================================================
-- 管理員切換影片
-- =====================================================

requestSelectVideo.OnServerInvoke = function(player, videoName)
    if not isAdmin(player) then
        warn("未授權的影片切換請求：" .. player.Name)
        return false, "你沒有管理員權限。"
    end

    if playing then
        return false, "影片播放中，暫時不能切換。"
    end

    local root = getVideoData(videoName)

    if not root then
        return false, "影片不存在或尚未設定完成。"
    end

    currentVideoName = videoName

    -- 通知所有客戶端切換影片資料
    stateChanged:FireAllClients(
        "VideoChanged",
        currentVideoName
    )

    print("管理員 " .. player.Name .. " 切換影片：" .. videoName)

    return true, "已切換至 " .. videoName
end

-- =====================================================
-- 玩家加入及離開
-- =====================================================

Players.PlayerAdded:Connect(function(player)
    if playing then
        participantStartTimes[player.UserId] = math.max(
            startTime,
            Workspace:GetServerTimeNow()
        )
    end
end)

Players.PlayerRemoving:Connect(function(player)
    participantStartTimes[player.UserId] = nil
end)

-- =====================================================
-- 徽章
-- =====================================================

local function awardBadge(player)
    task.spawn(function()
        local success, hasBadge = pcall(function()
            return BadgeService:UserHasBadgeAsync(
                player.UserId,
                BADGE_ID
            )
        end)

        if not success then
            warn("Bad Apple：檢查徽章失敗：" .. player.Name)
            return
        end

        if hasBadge then
            return
        end

        local awarded, result = pcall(function()
            return BadgeService:AwardBadge(
                player.UserId,
                BADGE_ID
            )
        end)

        if awarded and result then
            print("Bad Apple：成功發放徽章給 " .. player.Name)
        else
            warn("Bad Apple：徽章發放失敗：" .. player.Name)
        end
    end)
end

-- =====================================================
-- 開始播放
-- =====================================================

requestPlay.OnServerInvoke = function(player)
    if playing then
        return false, startTime, playbackId
    end

    local root, config = getVideoData(currentVideoName)

    if not root or not config then
        return false, 0, playbackId
    end

    playing = true
    playbackId += 1

    activeVideoName = currentVideoName
    activeDuration = config.FrameCount / config.FPS
    activeRequiredWatchTime = activeDuration * WATCH_PERCENT

    startTime = Workspace:GetServerTimeNow() + START_DELAY

    participantStartTimes = {}

    for _, currentPlayer in ipairs(Players:GetPlayers()) do
        participantStartTimes[currentPlayer.UserId] = startTime
    end

    stateChanged:FireAllClients(
        "Started",
        startTime,
        playbackId,
        activeVideoName
    )

    local thisPlaybackId = playbackId
    local thisVideoName = activeVideoName

    task.delay(START_DELAY + activeDuration, function()
        if playbackId ~= thisPlaybackId or not playing then
            return
        end

        local finishTime = Workspace:GetServerTimeNow()

        playing = false

        stateChanged:FireAllClients(
            "Finished",
            startTime,
            playbackId,
            thisVideoName
        )

        -- 只有完整觀看 Bad Apple 才發放原本的徽章
        if thisVideoName == "BadApple" then
            for _, currentPlayer in ipairs(Players:GetPlayers()) do
                local joinedWatchTime =
                    participantStartTimes[currentPlayer.UserId]

                if joinedWatchTime then
                    local actualWatchStart = math.max(
                        startTime,
                        joinedWatchTime
                    )

                    local watchedTime = math.max(
                        0,
                        finishTime - actualWatchStart
                    )

                    if watchedTime >= activeRequiredWatchTime then
                        awardBadge(currentPlayer)
                    else
                        print(
                            "Bad Apple：觀看時間不足：",
                            currentPlayer.Name,
                            math.floor(watchedTime),
                            "/",
                            math.ceil(activeRequiredWatchTime)
                        )
                    end
                end
            end
        end

        participantStartTimes = {}
    end)

    return true, startTime, playbackId
end

print("多影片同步播放 Server 已啟動")
print("預設影片：" .. DEFAULT_VIDEO)
print("徽章 ID：" .. BADGE_ID)