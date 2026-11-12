-- 頁面：④ 維運監控
-- 問題：故障大多是哪一種？
-- 圖表：表格 ＋ 長條圖（X 軸：分類；Y 軸：次數，只有前兩類有值）
-- 更新：每小時（connector_event 每天 00:15 更新；v_connector_flag 每次約需 20 秒）
--
-- 前兩類是「故障事件」，單位是次數；後兩類是「充電槍」，單位是槍數
-- 單位不同，分成「次數」和「槍數」兩欄，長條圖只用「次數」欄
-- 故障持續時間 = end_at − start_at + 10 分鐘（包含合併進來的收集中斷）
--   單一樣本故障：持續 10 分鐘（只出現 1 批）
--   連續故障：持續 ≥ 20 分鐘
-- 期間內全程故障、超過 24 小時未更新：規則見 db/migrations/006_connector_flag.sql
-- 同一支槍可能同時屬於多類（例如全程故障的槍，它的故障也算在連續故障裡）

WITH fault_event AS (
    SELECT
        e.station_id, e.charging_point_id, e.connector_id,
        TIMESTAMPDIFF(MINUTE, e.start_at, e.end_at) + 10 AS minutes
    FROM connector_event e
    JOIN v_station v ON v.station_id = e.station_id
    WHERE v.in_scope = 1
      AND e.event_type = 'faulted'
),
-- v_connector_flag 只讀一次，兩類一起算好（分開讀會花兩倍時間）
flag_sum AS (
    SELECT
        SUM(f.is_all_faulted)                                   AS all_faulted,
        COUNT(DISTINCT CASE WHEN f.is_all_faulted THEN f.station_id END) AS all_faulted_stations,
        SUM(f.is_stale)                                         AS stale,
        COUNT(DISTINCT CASE WHEN f.is_stale THEN f.station_id END)       AS stale_stations
    FROM v_connector_flag f
    JOIN v_station v ON v.station_id = f.station_id
    WHERE v.in_scope = 1
)
SELECT
    '單一樣本故障'                                              AS `分類`,
    COUNT(*)                                                    AS `次數`,
    COUNT(DISTINCT station_id, charging_point_id, connector_id) AS `槍數`,
    COUNT(DISTINCT station_id)                                  AS `站數`,
    '只出現 1 批（約 10 分鐘），下一批就恢復'                    AS `說明`
FROM fault_event
WHERE minutes = 10
UNION ALL
SELECT
    '連續故障（≥20 分鐘）',
    COUNT(*),
    COUNT(DISTINCT station_id, charging_point_id, connector_id),
    COUNT(DISTINCT station_id),
    '連續 2 批以上都是故障'
FROM fault_event
WHERE minutes >= 20
UNION ALL
SELECT
    '期間內全程故障',
    NULL,
    all_faulted,
    all_faulted_stations,
    '有 24 小時以上的資料，而且每一批都是故障'
FROM flag_sum
UNION ALL
SELECT
    '超過 24 小時未更新',
    NULL,
    stale,
    stale_stations,
    'TDX 最後更新時間距今超過 24 小時（不一定是故障）'
FROM flag_sum;
