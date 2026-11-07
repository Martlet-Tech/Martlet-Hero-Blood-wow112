-- 坐标数据：8 个真实刷新点（1.12 服务端数据库精确值）
--
-- 来源：cmangos/classic-db 的 Full_DB/ClassicDB_1_12_1_z2815.sql.gz，
--       gameobject 表 entry 176213（Blood of Heroes），共 158 条刷点记录。
--       ClassicDB 站（?object=176213）对同一份数据只筛出 8 个确认点：
--       Eastern Plaguelands (6) + Western Plaguelands (2)，与本表一致。
--
-- 说明：原 bloodOfHeros 1.2 插件那 140 个点，就是把这张表里 158 条冗余记录
--       去重后得来的，其中大部分在本服不存在（实测西瘟疫只有 2 个）。
--
-- 刷新时间：该表 158 条记录的 spawntimesecsmin 与 spawntimesecsmax 全部为 7200，
--           即固定 2 小时，无随机浮动。
--
-- 坐标格式：{x, y}，取值 0-100（游戏内百分比坐标，非 0-1）。
BHM_COORDS = {
  EPL = {
  {33.58, 32.62},
  {49.11, 35.32},
  {59.26, 62.27},
  {64.73, 65.25},
  {27.28, 64.15},
  {25.94, 74.64},
  },
  WPL = {
  {49.73, 33.28},
  {52.35, 54.95},
  },
}
