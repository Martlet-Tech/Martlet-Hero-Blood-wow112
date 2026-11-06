# Martlet Hero Blood（wow112）

魔兽世界 **1.12.1**（Interface 11200，水豚服 / Turtle WoW）用的**英雄之血**世界地图标记插件。

在西瘟疫之地、东瘟疫之地的区域地图上标出全部英雄之血刷新点，鼠标悬停可看精确坐标。

> 原版 `bloodOfHeros` 1.2（作者 Demonass，2020）依赖经典旧世 1.13 的 `C_Map` + HereBeDragons-2.0，
> 在 1.12 客户端上必然空白报错。本插件保留其坐标数据，按 1.12 原生 API 重写显示逻辑。

## 功能

- 西瘟疫之地 **49** 点 / 东瘟疫之地 **91** 点，共 140 个刷新位置
- 钉子用物品 12938【英雄之血】的图标（自带 64×64 TGA 贴图，不依赖客户端内建图标）
- 悬停显示：区域名 + 精确坐标（如 `西瘟疫之地  35.9, 57.5`）
- 只使用 1.12 原生 API，**不依赖任何库**，与 pfUI / pfQuest / S_WorldMap / ModernMapMarkers 不冲突

## 安装

1. 下载或克隆本仓库
2. 把 `BloodOfHeroesMap` 整个文件夹放进：

   ```
   <游戏目录>\Interface\AddOns\BloodOfHeroesMap\
   ```

3. 确认该目录下能直接看到 `BloodOfHeroesMap.toc`（不能多套一层文件夹）
4. 进游戏，`/reload` 或重启客户端

1.12.1 默认加载所有插件，**不需要**勾选"加载过期插件"（这个版本还没有该功能）。

## 使用

| 操作 | 说明 |
| --- | --- |
| 打开地图（`M`）→ 切到西瘟疫之地 / 东瘟疫之地 | 自动铺图钉 |
| 鼠标悬停图钉 | 显示区域与坐标 |
| `/bh` | 开关显示（设置会被记住） |
| `/bh on` / `/bh off` | 显式开关 |
| `/bh debug` | 屏幕自检面板 + 聊天框输出判定过程 |

设置保存在 `WTF\Account\<账号>\SavedVariables\BloodOfHeroesMap.lua`。

### 只有区域地图有钉子

看**东部王国大陆图**时不会显示——1.12 的大陆图没有精确投影，任何插件都无法定位。请切换到具体的区域地图。

## 坐标数据

`coords.lua`，共 140 点，搬自 `bloodOfHeros` 1.2 的坐标表，做了两处处理：

- 去掉原表中的重复键（`enorth4` / `north4` / `eorth4` 各写了两遍，后者会覆盖前者，实际丢了 3 个点），改为数组结构后 **140 点一个不少**
- 按区域拆成 `WPL` / `EPL` 两组

数据是那只 2020 年插件的静态点位。若服务器自行增删过刷新点，未收录的点需要手动补充，格式：

```lua
BHM_COORDS = {
  WPL = { {35.9, 57.5}, ... },   -- 西瘟疫之地，x, y 均为 0-100 的地图百分比
  EPL = { {12.3, 45.6}, ... },   -- 东瘟疫之地
}
```

## 实现要点（1.12 客户端踩坑记录）

这套客户端有几个和教科书不一样的行为，本插件的写法都是按实测结果定下的：

| 现象 | 处理 |
| --- | --- |
| `WorldMapFrame:IsVisible()` 返回 `nil` | 完全不做可见性判断；钉子挂在 `WorldMapButton` 下，地图关闭时自然隐藏 |
| `GetMapInfo()` 会滞后一个区域（换图后仍返回上一张图的名字） | 区域识别改用**序号比对**：启动时从 `GetMapZones(大陆)` 扫出西/东瘟疫之地的序号，之后只比较 `GetCurrentMapZone()` 的数字 |
| `GetMapZones()` 有的实现返回表、有的返回多个值 | 两种都兼容 |
| `SetTexture("Interface\\Icons\\...")` 渲染为全黑 | 自带 TGA 贴图；且**必须写全 `.tga` 扩展名**，否则客户端只补 `.blp` |
| 换区时 `WORLD_MAP_UPDATE` 连发、地图框尺寸未定型 | 事件触发 + 0.3 秒防抖补帧，另挂 `WorldMapFrame_Update` 与 0.25 秒轮询兜底 |

## 目录结构

```
BloodOfHeroesMap/
├── BloodOfHeroesMap.toc   # 加载清单，Interface: 11200
├── BloodOfHeroesMap.lua   # 显示逻辑
├── coords.lua             # 140 个坐标
└── textures/
    └── blood.tga          # 64×64 / 32 位 RLE，图标为物品 12938
```

## 更新日志

- **4.2** 图标改为自带 TGA 贴图（解决内建图标渲染全黑）
- **4.1** 钉子改用物品图标（原为纯色方块）
- **4.0** 修复"插件已加载但地图无标记"：不再依赖 `WorldMapFrame:IsVisible()`，区域识别改为序号比对，刷新改用 `WORLD_MAP_UPDATE`
- **3.0** 锚点回退到 `WorldMapDetailFrame`，父级改为 `WorldMapFrame`
- **1.0** 初版，坐标数据搬自 `bloodOfHeros` 1.2

## 致谢

- 坐标数据：`bloodOfHeros` 1.2 by **Demonass**
- 1.12 地图绘制写法参考：**pfQuest**、**ModernMapMarkers**
