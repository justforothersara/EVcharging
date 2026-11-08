-- 頁面：③ 站點配置評估
-- 問題：哪些站用得很少？
-- 圖表：表格（依使用率由低到高排序）
-- 更新：每小時（v_connector_flag 每次約需 20 秒）
--
-- 門檻：低使用率 = 使用率 < 1%（平均每支槍每天被使用不到 15 分鐘）← 要調整門檻，只改 params 這一行
-- 使用率、可用率的定義同 01_kpi_overview.sql
-- 可用率用來區分「沒人用」和「故障不能用」
-- 未被使用的槍數 = 整段期間 0 次佔用的槍（全程故障的槍不算，另見 ⚠️ 全程故障）
-- 全部樣本都是故障的站，使用率沒有分母（NULL），不列在這裡，見 ④ 維運監控
-- ⚠️ 欄位定義同 06_station_ranking.sql

WITH params AS (
    SELECT 1 AS low_threshold_pct
),
per_connector AS (
    SELECT
        c.station_id, c.charging_point_id, c.connector_id,
        SUM(c.samples)      AS samples,
        SUM(c.occupied_cnt) AS occupied,
        SUM(c.faulted_cnt)  AS faulted
    FROM connector_hourly_usage c
    JOIN v_station v ON v.station_id = c.station_id
    WHERE v.in_scope = 1
    GROUP BY c.station_id, c.charging_point_id, c.connector_id
),
usage_by_station AS (
    SELECT
        station_id,
        COUNT(*)      AS connectors,
        SUM(samples)  AS samples,
        SUM(occupied) AS occupied,
        SUM(faulted)  AS faulted,
        SUM(occupied = 0 AND faulted < samples) AS unused_connectors
    FROM per_connector
    GROUP BY station_id
),
flag_by_station AS (
    SELECT
        station_id,
        SUM(is_unchanged) AS unchanged,
        GROUP_CONCAT(DISTINCT CASE WHEN is_unchanged THEN
            CASE latest_status WHEN 1 THEN '閒置' WHEN 2 THEN '佔用' WHEN 3 THEN '故障' END
        END ORDER BY latest_status SEPARATOR '、') AS unchanged_states,
        SUM(is_stale)       AS stale,
        SUM(is_all_faulted) AS all_faulted
    FROM v_connector_flag
    GROUP BY station_id
),
judged AS (
    SELECT
        v.name_zh,
        v.district,
        u.connectors,
        u.unused_connectors,
        100 * u.occupied / NULLIF(u.samples - u.faulted, 0) AS usage_pct,
        100 * (u.samples - u.faulted) / u.samples           AS availability_pct,
        f.unchanged, f.unchanged_states, f.stale, f.all_faulted
    FROM usage_by_station u
    JOIN v_station v       ON v.station_id = u.station_id
    JOIN flag_by_station f ON f.station_id = u.station_id
)
SELECT
    j.name_zh                                       AS `充電站`,
    j.district                                      AS `行政區`,
    j.connectors                                    AS `充電槍數`,
    ROUND(j.usage_pct, 2)                           AS `使用率(%)`,
    ROUND(j.availability_pct, 1)                    AS `可用率(%)`,
    j.unused_connectors                             AS `未被使用的槍數`,
    CASE WHEN j.unchanged > 0 THEN CONCAT(j.unchanged, '（', j.unchanged_states, '）')
         ELSE '0' END                               AS `⚠️ 狀態未變化`,
    j.stale                                         AS `⚠️ 超過24h未更新`,
    j.all_faulted                                   AS `⚠️ 全程故障`
FROM judged j
CROSS JOIN params p
WHERE j.usage_pct < p.low_threshold_pct
ORDER BY j.usage_pct, j.name_zh;
