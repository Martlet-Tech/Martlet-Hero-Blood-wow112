-- ============================================================================
--  BloodOfHeroesMap  -  英雄之血地图  v6
--  适用客户端：WoW 1.12.1（水豚服 / Turtle WoW 1.18.x），Interface 11200
--
--  v4 变更（依据 /bh debug 实测数据）：
--    实测：zone=28 大陆=2 区域名=西瘟疫之地 GetMapInfo=WesternPlaguelands
--          但 WorldMapFrame:IsVisible() 返回 nil，且 GetMapInfo() 会返回上一个区域的旧值
--          （判定=EPL 却显示西瘟疫），导致：
--            1) 可见性判断失败 -> 每帧 HideAll -> 图钉全部隐藏（有 N 个却显示 0）
--            2) 区域判断用 GetMapInfo -> 拿到旧区域 -> 画错地图的点
--
--    改法（完全照抄 pfQuest / ModernMapMarkers 在本客户端验证过的写法）：
--      * 父级 = WorldMapButton，锚点 = WorldMapButton:GetTopLeft()，
--        坐标 x/100*w, -y/100*h —— 与 pfQuest 完全一致，分毫不差。
--      * 不再判断地图是否可见：图钉是 WorldMapButton 的子控件，地图关掉自然跟着隐藏。
--      * 区域识别改为「序号比对」：启动时从 GetMapZones(大陆) 里扫出西/东瘟疫之地
--        的序号（你这客户端是 28/29），之后只比较 GetCurrentMapZone() 的数字。
--        GetMapInfo / 贴图 仅作兜底，不再作为主判据。
--      * 刷新触发用 WORLD_MAP_UPDATE 事件（pfQuest 同款）+ 0.3 秒防抖，
--        外加 1 秒轮询兜底。
--
--  v6 新增：刷新计时
--    依据：cmangos/classic-db 的 1.12.1 world 库里，gameobject 表 entry 176213
--          （Blood of Heroes）共 158 条刷点记录，spawntimesecsmin 与
--          spawntimesecsmax 全部为 7200（2 小时），无一例外。
--          ClassicDB 站同源显示 "Respawn: 2hr"。
--    做法：拾取到物品 12938 时（CHAT_MSG_LOOT）用 GetPlayerMapPosition 定位到
--          最近的已知点，记下 time()；地图上每个钉子下面显示剩余时间，
--          到点后显示「可刷」。也可以直接左键点钉子手工标记。
-- ============================================================================

BHM_SIZE = 16
BHM_ITEM_ID = 12938   -- 英雄之血，图标直接取物品自身的贴图
BHM_RESPAWN = 7200    -- 秒；1.12 gameobject 表 176213 的 spawntimesecs，158 条记录全一致

if not BHM_DB then BHM_DB = {} end
if BHM_DB.enabled == nil then BHM_DB.enabled = true end
if not BHM_DB.seen then BHM_DB.seen = {} end
if not BHM_DB.respawn then BHM_DB.respawn = BHM_RESPAWN end

local pins      = {}
local drawnKey  = nil      -- 已绘制的区域键
local drawnSig  = nil      -- 已绘制的地图签名（大陆:区域:宽x高）
local drawnAnchor = nil    -- 已绘制所用锚点
local shownAny  = false
local lastKey     = nil
local lastReason  = ""
local lastZone    = nil
local lastCont    = nil
local acc         = 0
local textAcc     = 0
local pendingAt   = nil

-- 区域识别 ------------------------------------------------------------------

local function Identify(name)
    if not name then return nil end
    local low = string.lower(name)
    if string.find(name, "西瘟疫", 1, true) then return "WPL" end
    if string.find(name, "东瘟疫", 1, true) then return "EPL" end
    if string.find(low, "plague", 1, true) then
        if string.find(low, "west", 1, true) then return "WPL" end
        if string.find(low, "east", 1, true) then return "EPL" end
    end
    return nil
end

-- GetMapZones 在不同客户端可能返回表，也可能返回多个值
local function ZoneList(continent)
    if not GetMapZones or not continent or continent < 0 then return nil end
    local ok, r = pcall(GetMapZones, continent)
    if not ok or not r then return nil end
    local t = { GetMapZones(continent) }
    if type(t[1]) == "table" then return t[1] end
    return t
end

-- 每个大陆只扫一次，缓存 { WPL = 序号, EPL = 序号 }
local ZONE_INDEX = {}
local function BuildIndex(continent)
    if ZONE_INDEX[continent] then return ZONE_INDEX[continent] end
    local list = ZoneList(continent)
    if not list then return nil end
    local t = {}
    for i = 1, table.getn(list) do
        local k = Identify(list[i])
        if k and not t[k] then t[k] = i end
    end
    if t.WPL or t.EPL then
        ZONE_INDEX[continent] = t
        return t
    end
    return nil
end

-- 判断当前看的是哪张地图 -----------------------------------------------------
local function ZoneKey()
    local zone = GetCurrentMapZone and GetCurrentMapZone() or 0
    local continent = GetCurrentMapContinent and GetCurrentMapContinent() or -1
    lastZone, lastCont = zone, continent

    if not zone or zone == 0 then
        lastReason = "zone=0（大陆/世界地图）"
        return nil
    end

    local idx = BuildIndex(continent)
    if idx then
        if idx.WPL == zone then lastReason = "序号 WPL=" .. zone return "WPL" end
        if idx.EPL == zone then lastReason = "序号 EPL=" .. zone return "EPL" end
    end

    -- 兜底 1：该序号对应的区域名
    local list = ZoneList(continent)
    local name = list and list[zone] or nil
    local k = Identify(name)
    if k then lastReason = "区域名 " .. tostring(name) return k end

    -- 兜底 2：GetMapInfo（注意：本客户端此函数会滞后，只作兜底）
    local info = GetMapInfo and GetMapInfo() or nil
    k = Identify(info)
    if k then lastReason = "GetMapInfo " .. tostring(info) return k end

    -- 兜底 3：地图贴图路径
    if WorldMapDetailFrame and WorldMapDetailFrame.GetTexture then
        local tex = WorldMapDetailFrame:GetTexture()
        k = Identify(tex)
        if k then lastReason = "贴图 " .. tostring(tex) return k end
    end

    lastReason = string.format("未匹配 zone=%s cont=%s 区域名=%s info=%s",
        tostring(zone), tostring(continent), tostring(name), tostring(info))
    return nil
end

-- 物品图标 ------------------------------------------------------------------
-- 客户端自带的 Interface\Icons\INV_Potion_33 在这套客户端上 SetTexture 出来是全黑
-- （物品栏里能显示，说明是它内部路径/格式的特殊问题），所以改为自带贴图：
-- textures\blood.tga，64x64 / 32 位 RLE TGA，格式与 ModernMapMarkers 的贴图一致。
-- 注意：客户端默认只给路径补 .blp，所以用完 tga 必须把扩展名写全。
local BHM_ICON = "Interface\\AddOns\\BloodOfHeroesMap\\textures\\blood.tga"
local iconName = nil

local function ItemName()
    if iconName then return iconName end
    if not GetItemInfo then return nil end
    local name = GetItemInfo(BHM_ITEM_ID)
    if name then iconName = name end
    return iconName
end

local function PaintIcon(t)
    t:SetTexture(BHM_ICON)
end

-- 输出 ----------------------------------------------------------------------
local function Say(msg)
    DEFAULT_CHAT_FRAME:AddMessage(msg, 1, 0.35, 0.35)
end

-- 刷新计时 ------------------------------------------------------------------
-- 点位键用坐标而不是序号：以后改坐标表顺序，已记录的时间不会错位。
local function PointKey(zone, c)
    return zone .. ":" .. string.format("%.2f,%.2f", c[1], c[2])
end

-- 返回：显示文字, r, g, b
local function RemainOf(ts)
    if not ts then return nil end
    local cycle = BHM_DB.respawn or BHM_RESPAWN
    local left = ts + cycle - time()
    if left <= 0 then
        return "可刷", 0.4, 1, 0.4
    end
    local h = math.floor(left / 3600)
    local m = math.floor((left - h * 3600) / 60)
    if h > 0 then
        return string.format("%dh%02d", h, m), 1, 0.82, 0.2
    end
    return string.format("%dm", m), 1, 0.82, 0.2
end

local function PlayerPos()
    if not GetPlayerMapPosition then return nil end
    local x, y = GetPlayerMapPosition("player")
    if not x or not y or (x == 0 and y == 0) then return nil end
    return x * 100, y * 100
end

local function PlayerZone()
    local t = {}
    if GetRealZoneText then t[table.getn(t) + 1] = GetRealZoneText() end
    if GetZoneText then t[table.getn(t) + 1] = GetZoneText() end
    for i = 1, table.getn(t) do
        local k = Identify(t[i])
        if k then return k end
    end
    return nil
end

local function NearestPoint(zone, x, y)
    local coords = BHM_COORDS[zone]
    if not coords then return nil end
    local best, bestD = nil, 9999
    local n = table.getn(coords)
    for i = 1, n do
        local c = coords[i]
        local dx, dy = c[1] - x, c[2] - y
        local d = math.sqrt(dx * dx + dy * dy)
        if d < bestD then bestD, best = d, i end
    end
    return best, bestD
end

-- 记下某个点「刚刚被采走」
local function MarkPoint(zone, index, quiet)
    local coords = BHM_COORDS[zone]
    if not coords or not coords[index] then return end
    local c = coords[index]
    BHM_DB.seen[PointKey(zone, c)] = time()
    drawnSig = nil            -- 强制下一帧重绘，倒计时立刻出现
    if not quiet then
        Say(string.format("|cffff2020英雄之血|r 已记录 %s %.2f, %.2f，%d 分钟后再看",
            (zone == "WPL") and "西瘟疫之地" or "东瘟疫之地", c[1], c[2],
            math.floor((BHM_DB.respawn or BHM_RESPAWN) / 60)))
    end
end

-- 用玩家当前坐标认领最近的点；拾取时自动调用，也可 /bh mark 手动
local function MarkHere(quiet)
    local zone = PlayerZone()
    if not zone then
        if not quiet then Say("|cffff2020英雄之血|r 当前不在西/东瘟疫之地，没法记") end
        return
    end
    local x, y = PlayerPos()
    if not x then
        if not quiet then Say("|cffff2020英雄之血|r 取不到自己的地图坐标") end
        return
    end
    local idx, d = NearestPoint(zone, x, y)
    if not idx or d > 2.5 then
        if not quiet then
            Say(string.format("|cffff2020英雄之血|r 附近没有已知刷新点（最近的差 %.1f%%）", d or 99))
        end
        return
    end
    MarkPoint(zone, idx, quiet)
end

-- 图钉 ----------------------------------------------------------------------
local function AcquirePin(index, parent)
    if pins[index] then return pins[index] end

    local p = CreateFrame("Button", "BloodOfHeroesMapPin" .. index, parent)
    p:SetWidth(BHM_SIZE)
    p:SetHeight(BHM_SIZE)

    -- 黑色衬底当边框（比图标大一圈，四边露 1 像素）
    local ring = p:CreateTexture(nil, "BACKGROUND")
    ring:SetAllPoints(p)
    ring:SetTexture(0.05, 0.05, 0.05, 1)

    -- 图标本体，内缩 1 像素
    local icon = p:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", p, "TOPLEFT", 1, -1)
    icon:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -1, 1)

    PaintIcon(icon)

    p.ring, p.icon = ring, icon
    p.label = "英雄之血"

    -- 倒计时文字（在图标下方，带描边，压在浅色地图上也看得清）
    local fs = p:CreateFontString(nil, "OVERLAY")
    local fontPath = GameFontNormal and GameFontNormal.GetFont and GameFontNormal:GetFont()
    if fontPath then
        fs:SetFont(fontPath, 9, "OUTLINE")
    elseif GameFontNormalSmall then
        fs:SetFontObject(GameFontNormalSmall)
    end
    fs:SetPoint("TOP", p, "BOTTOM", 0, 1)
    fs:SetJustifyH("CENTER")
    fs:Hide()
    p.text = fs

    p:SetScript("OnEnter", function()
        local tip = WorldMapTooltip or GameTooltip
        tip:SetOwner(p, "ANCHOR_RIGHT")
        tip:AddLine(ItemName() or p.label, 1, 0.2, 0.2)
        tip:AddLine(p.zoneText or "", 1, 1, 1)
        local cycle = BHM_DB.respawn or BHM_RESPAWN
        tip:AddLine(string.format("刷新周期：%d 分钟", math.floor(cycle / 60)), 0.7, 0.7, 0.7)
        if p.seenAt then
            local ago = math.floor((time() - p.seenAt) / 60)
            local left = p.seenAt + cycle - time()
            if left > 0 then
                tip:AddLine(string.format("上次采走：%d 分钟前，还剩 %d 分钟", ago, math.ceil(left / 60)),
                    1, 0.82, 0.2)
            else
                tip:AddLine(string.format("上次采走：%d 分钟前，应该已刷新", ago), 0.4, 1, 0.4)
            end
        else
            tip:AddLine("还没有采集记录", 0.6, 0.6, 0.6)
        end
        tip:AddLine("左键点击：记为刚采走", 0.55, 0.55, 0.55)
        tip:Show()
    end)
    p:SetScript("OnLeave", function()
        local tip = WorldMapTooltip or GameTooltip
        tip:Hide()
    end)
    p:SetScript("OnClick", function()
        if p.zoneKey and p.pointIndex then
            MarkPoint(p.zoneKey, p.pointIndex, false)
        end
    end)

    pins[index] = p
    return p
end

-- 地图绘制锚点：优先 WorldMapButton（pfQuest 用的就是它），尺寸为 0 时退到 DetailFrame
local function PickAnchor()
    local f = WorldMapButton
    if f and f.GetWidth then
        local w, h = f:GetWidth(), f:GetHeight()
        if w and h and w > 1 and h > 1 then return f, w, h end
    end
    f = WorldMapDetailFrame
    if f and f.GetWidth then
        local w, h = f:GetWidth(), f:GetHeight()
        if w and h and w > 1 and h > 1 then return f, w, h end
    end
    return nil
end

local function HideAll()
    local n = table.getn(pins)
    for i = 1, n do
        if pins[i] then pins[i]:Hide() end
    end
    shownAny, drawnKey, drawnSig, drawnAnchor = false, nil, nil, nil
end

-- 只更新倒计时文字，不重排图钉（每 15 秒跑一次就够）
local function CountSeen()
    local n = 0
    for _ in pairs(BHM_DB.seen) do n = n + 1 end
    return n
end

local function UpdateTexts()
    local total = table.getn(pins)
    for i = 1, total do
        local p = pins[i]
        if p and p.text then
            local txt, r, g, b = RemainOf(p.seenAt)
            if txt and p:IsShown() then
                p.text:SetText(txt)
                p.text:SetTextColor(r, g, b)
                p.text:Show()
            else
                p.text:Hide()
            end
        end
    end
end

-- 主刷新 --------------------------------------------------------------------
local function Refresh(force)
    if not BHM_DB.enabled then
        if shownAny then HideAll() end
        return
    end

    local key = ZoneKey()
    lastKey = key
    if not key then
        if shownAny then HideAll() end
        return
    end

    local anchor, w, h = PickAnchor()
    if not anchor then
        lastReason = "拿不到地图尺寸（Button 和 DetailFrame 都为 0）"
        if shownAny then HideAll() end
        return
    end

    -- 签名含大陆+区域序号，避免两个大陆同序号区域被误判成"没变"
    local sig = tostring(lastCont) .. ":" .. tostring(lastZone) .. ":" .. w .. "x" .. h
    if not force and key == drawnKey and sig == drawnSig and anchor == drawnAnchor then return end

    local coords = BHM_COORDS[key]
    if not coords then return end

    local zoneName = (key == "WPL") and "西瘟疫之地" or "东瘟疫之地"
    local n = table.getn(coords)
    for i = 1, n do
        local c = coords[i]
        local p = AcquirePin(i, anchor)
        p.zoneKey = key
        p.pointIndex = i
        p.zoneText = string.format("%s  %.2f, %.2f", zoneName, c[1], c[2])
        p.seenAt = BHM_DB.seen[PointKey(key, c)]
        p:ClearAllPoints()
        p:SetPoint("CENTER", anchor, "TOPLEFT", c[1] / 100 * w, -(c[2] / 100 * h))
        p:Show()
    end
    UpdateTexts()

    local total = table.getn(pins)
    for i = n + 1, total do
        if pins[i] then pins[i]:Hide() end
    end

    drawnKey, drawnSig, drawnAnchor, shownAny = key, sig, anchor, true
end

-- 事件：WORLD_MAP_UPDATE（pfQuest 同款）+ 窗口尺寸定型后再补一帧 ---------------
local ev = CreateFrame("Frame", "BloodOfHeroesMapEvents")
ev:RegisterEvent("WORLD_MAP_UPDATE")
ev:RegisterEvent("CHAT_MSG_LOOT")
ev:SetScript("OnEvent", function(self, event, arg1)
    if event == "CHAT_MSG_LOOT" then
        -- 拾取到英雄之血就记下当前位置对应的刷新点
        local msg = arg1 or ""
        if string.find(msg, "12938", 1, true)
            or string.find(msg, "英雄之血", 1, true)
            or string.find(msg, "Blood of Heroes", 1, true) then
            MarkHere(false)
        end
        return
    end
    Refresh(true)
    -- 换区瞬间事件会连发、地图框尺寸可能还没定型，0.3 秒后再画一次干净的
    pendingAt = (GetTime and GetTime() or 0) + 0.3
end)

-- 轮询兜底 ------------------------------------------------------------------
local ticker = CreateFrame("Frame", "BloodOfHeroesMapTicker")
ticker:SetScript("OnUpdate", function()
    local elapsed = arg1 or 0.05
    acc = acc + elapsed
    textAcc = textAcc + elapsed
    if textAcc >= 15 then
        textAcc = 0
        if shownAny then UpdateTexts() end
    end
    if acc < 0.25 then return end
    acc = 0
    if pendingAt then
        if (GetTime and GetTime() or 0) >= pendingAt then
            pendingAt = nil
            Refresh(true)
            return
        end
    end
    Refresh(false)
end)
ticker:Show()

-- 双保险：再挂一层 WorldMapFrame_Update（ModernMapMarkers 在本客户端用的就是它），
-- 以防某些情况下换区不发 WORLD_MAP_UPDATE。注意 1.12 是 Lua 5.0，别用 ... 转发参数。
if WorldMapFrame_Update then
    local origUpdate = WorldMapFrame_Update
    WorldMapFrame_Update = function()
        if origUpdate then origUpdate() end
        Refresh(false)
        pendingAt = (GetTime and GetTime() or 0) + 0.3
    end
end

-- 命令 ----------------------------------------------------------------------
local panel, panelLines = nil, {}
local function ShowPanel(lines)
    if not panel then
        panel = CreateFrame("Frame", "BloodOfHeroesMapDebug", UIParent)
        panel:SetWidth(640)
        panel:SetHeight(24 + 17 * 12)
        panel:SetPoint("TOP", UIParent, "TOP", 0, -60)
        panel:SetFrameStrata("TOOLTIP")
        local bg = panel:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(panel)
        bg:SetTexture(0, 0, 0, 0.85)
        for i = 1, 12 do
            local fs = panel:CreateFontString(nil, "OVERLAY")
            fs:SetFontObject(GameFontNormal)
            fs:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -(8 + (i - 1) * 17))
            fs:SetJustifyH("LEFT")
            panelLines[i] = fs
        end
        panel:SetScript("OnMouseDown", function() panel:Hide() end)
    end
    for i = 1, 12 do
        local fs = panelLines[i]
        if lines[i] then
            fs:SetText(lines[i])
            fs:SetTextColor(1, 0.4, 0.4)
            fs:Show()
        else
            fs:Hide()
        end
    end
    panel:Show()
end

local function Debug()
    Refresh(true)
    local shown, total = 0, table.getn(pins)
    for i = 1, total do
        if pins[i] and pins[i]:IsShown() then shown = shown + 1 end
    end

    local zone = GetCurrentMapZone and GetCurrentMapZone()
    local continent = GetCurrentMapContinent and GetCurrentMapContinent()
    local list = ZoneList(continent)
    local name = list and list[zone] or nil
    local idx = BuildIndex(continent)
    local dw, dh, bw, bh = 0, 0, 0, 0
    if WorldMapDetailFrame and WorldMapDetailFrame.GetWidth then
        dw, dh = WorldMapDetailFrame:GetWidth(), WorldMapDetailFrame:GetHeight()
    end
    if WorldMapButton and WorldMapButton.GetWidth then
        bw, bh = WorldMapButton:GetWidth(), WorldMapButton:GetHeight()
    end

    local lines = {
        "英雄之血地图 v6 自检（点击关闭）",
        "开关=" .. tostring(BHM_DB.enabled)
            .. "  Button显示=" .. tostring(WorldMapButton and WorldMapButton:IsShown()),
        "zone=" .. tostring(zone) .. "  大陆=" .. tostring(continent)
            .. "  区域名=" .. tostring(name),
        "索引表: WPL=" .. tostring(idx and idx.WPL) .. "  EPL=" .. tostring(idx and idx.EPL),
        "GetMapInfo=" .. tostring(GetMapInfo and GetMapInfo()),
        "Button=" .. bw .. " x " .. bh .. "   DetailFrame=" .. dw .. " x " .. dh,
        "判定=" .. tostring(lastKey) .. "  依据=" .. tostring(lastReason),
        "图钉：共 " .. total .. "，显示 " .. shown,
        "已绘制=" .. tostring(drawnKey) .. "  签名=" .. tostring(drawnSig),
        "图标=" .. BHM_ICON .. "  物品=" .. tostring(ItemName()),
        "数据：西瘟疫 " .. table.getn(BHM_COORDS.WPL) .. " / 东瘟疫 " .. table.getn(BHM_COORDS.EPL),
        "计时：已记 " .. CountSeen() .. " 点，周期 "
            .. math.floor((BHM_DB.respawn or BHM_RESPAWN) / 60) .. " 分钟",
    }
    ShowPanel(lines)
    for i = 1, table.getn(lines) do
        DEFAULT_CHAT_FRAME:AddMessage(lines[i], 1, 0.4, 0.4)
    end
end

SLASH_BLOODOFHEROESMAP1 = "/bh"
SLASH_BLOODOFHEROESMAP2 = "/bloodhero"
SlashCmdList["BLOODOFHEROESMAP"] = function(msg)
    msg = string.lower(msg or "")

    if msg == "debug" or msg == "d" then
        Debug()
        return
    end

    -- /bh mark：把自己脚下最近的刷新点记为「刚采走」
    if msg == "mark" or msg == "m" then
        MarkHere(false)
        return
    end

    -- /bh clear：清空所有计时记录
    if msg == "clear" or msg == "c" then
        BHM_DB.seen = {}
        drawnSig = nil
        Say("|cffff2020英雄之血|r 计时记录已清空")
        return
    end

    -- /bh 120 或 /bh respawn 120：改刷新周期（分钟）
    local _, _, mins = string.find(msg, "^%s*(%d+)%s*$")
    if not mins then
        local _, _, m2 = string.find(msg, "^respawn%s+(%d+)")
        mins = m2
    end
    if mins then
        local v = tonumber(mins)
        if v and v >= 1 and v <= 1440 then
            BHM_DB.respawn = v * 60
            drawnSig = nil
            Say("|cffff2020英雄之血|r 刷新周期设为 " .. v .. " 分钟")
        else
            Say("|cffff2020英雄之血|r 分钟数要在 1 到 1440 之间")
        end
        return
    end

    if msg == "on" then
        BHM_DB.enabled = true
    elseif msg == "off" then
        BHM_DB.enabled = false
    else
        BHM_DB.enabled = not BHM_DB.enabled
    end
    if BHM_DB.enabled then
        Say("|cffff2020英雄之血地图|r：已开启")
    else
        Say("|cffff2020英雄之血地图|r：已关闭")
    end
    Refresh(true)
end

DEFAULT_CHAT_FRAME:AddMessage("|cffff2020英雄之血地图|r v6 已加载：开图看标记，采到会自动计时（|cffffff00/bh|r 开关  |cffffff00/bh mark|r 手动记  |cffffff00/bh clear|r 清空  |cffffff00/bh debug|r 自检）。", 1, 0.35, 0.35)
