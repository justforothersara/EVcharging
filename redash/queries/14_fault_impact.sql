-- 頁面：④ 維運監控
-- 問題：應該先修哪裡？
-- 圖表：表格（依故障影響度排序）
-- 更新：每小時（connector_event 每天 00:15 更新）
--
-- 故障影響度 = 連續故障總時數 × 該站使用率
--   約等於「如果沒壞，這段時間預估會被使用的時數」；越常被使用的站壞越久，排越前面
-- 連續故障 = 持續 ≥ 20 分鐘；持續時間 = end_at − start_at + 10 分鐘
--   尚未修復的故障，時數算到事件建立時的最後一批
-- 使用率的定義同 01_kpi_overview.sql（全部期間）
-- 全部樣本都是故障的站沒有使用率（沒有分母），影響度無法計算，照常列出、排在最後
-- 沒有連續故障的站不列出

WITH build AS (
    SELECT MAX(s.batch_at) AS last_batch
    FROM connector_status_snapshot s
    WHERE s.batch_at <= (SELECT MAX(built_at) FROM connector_event)
),
fault_by_station AS (
    SELECT
        e.station_id,
        COUNT(*)                                                       AS faults,
        SUM(TIMESTAMPDIFF(MINUTE, e.start_at, e.end_at) + 10) / 60     AS fault_hours,
        SUM(e.end_at >= b.last_batch)                                  AS ongoing
    FROM connector_event e
    JOIN v_station v ON v.station_id = e.station_id
    CROSS JOIN build b
    WHERE v.in_scope = 1
      AND e.event_type = 'faulted'
      AND TIMESTAMPDIFF(MINUTE, e.start_at, e.end_at) + 10 >= 20
    GROUP BY e.station_id
),
usage_by_station AS (
    SELECT
        c.station_id,
        COUNT(DISTINCT c.charging_point_id, c.connector_id) AS connectors,
        100 * SUM(c.occupied_cnt) / NULLIF(SUM(c.samples) - SUM(c.faulted_cnt), 0) AS usage_pct
    FROM connector_hourly_usage c
    JOIN v_station v ON v.station_id = c.station_id
    WHERE v.in_scope = 1
    GROUP BY c.station_id
),
scored AS (
    SELECT
        v.name_zh,
        v.district,
        u.connectors,
        f.faults,
        f.fault_hours,
        f.ongoing,
        u.usage_pct,
        f.fault_hours * u.usage_pct / 100 AS impact
    FROM fault_by_station f
    JOIN v_station v        ON v.station_id = f.station_id
    JOIN usage_by_station u ON u.station_id = f.station_id
)
SELECT
    CASE WHEN impact IS NOT NULL
         THEN RANK() OVER (ORDER BY impact IS NULL, impact DESC) END AS `排名`,
    name_zh                                                     AS `充電站`,
    district                                                    AS `行政區`,
    connectors                                                  AS `充電槍數`,
    faults                                                      AS `連續故障次數`,
    ROUND(fault_hours, 1)                                       AS `連續故障總時數`,
    ongoing                                                     AS `尚未修復`,
    ROUND(usage_pct, 1)                                         AS `使用率(%)`,
    ROUND(impact, 1)                                            AS `故障影響度(小時)`,
    CASE WHEN impact IS NULL THEN '無法計算（全程故障）' ELSE '' END AS `備註`
FROM scored
ORDER BY impact IS NULL, impact DESC, fault_hours DESC, name_zh;
