-- 頁面：③ 站點配置評估
-- 問題：各區的供需狀況如何？
-- 圖表：長條圖（X 軸：行政區；Y 軸：擴站候選站數、低使用率站數）＋ 表格
-- 更新：每小時
--
-- 門檻同 08、09：擴站候選 = 滿站率 ≥ 20%；低使用率 = 使用率 < 1%  ← 要調整門檻，只改 params 這一行
-- 使用率、滿站率的定義同 01_kpi_overview.sql
-- 未被使用的槍數 = 整段期間 0 次佔用的槍（全程故障的槍不算）
-- 同一區同時有擴站候選和低使用率的站，代表區內的分布不均

WITH params AS (
    SELECT 20 AS full_threshold_pct, 1 AS low_threshold_pct
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
per_station AS (
    SELECT
        pc.station_id,
        v.district,
        COUNT(*)         AS connectors,
        SUM(pc.samples)  AS samples,
        SUM(pc.occupied) AS occupied,
        SUM(pc.faulted)  AS faulted,
        SUM(pc.occupied = 0 AND pc.faulted < pc.samples) AS unused_connectors
    FROM per_connector pc
    JOIN v_station v ON v.station_id = pc.station_id
    GROUP BY pc.station_id, v.district
),
full_by_station AS (
    SELECT station_id, SUM(full_cnt) AS full_cnt, SUM(samples) AS samples
    FROM station_hourly_usage
    GROUP BY station_id
),
judged AS (
    SELECT
        s.*,
        fs.full_cnt,
        fs.samples AS station_samples,
        100 * fs.full_cnt / fs.samples >= p.full_threshold_pct                       AS is_candidate,
        100 * s.occupied / NULLIF(s.samples - s.faulted, 0) < p.low_threshold_pct     AS is_low
    FROM per_station s
    JOIN full_by_station fs ON fs.station_id = s.station_id
    CROSS JOIN params p
)
SELECT
    district                                                         AS `行政區`,
    COUNT(*)                                                         AS `充電站數`,
    SUM(connectors)                                                  AS `充電槍數`,
    ROUND(100 * SUM(occupied) / NULLIF(SUM(samples) - SUM(faulted), 0), 1) AS `使用率(%)`,
    ROUND(100 * SUM(full_cnt) / SUM(station_samples), 1)             AS `滿站率(%)`,
    SUM(COALESCE(is_candidate, 0))                                   AS `擴站候選站數`,
    SUM(COALESCE(is_low, 0))                                         AS `低使用率站數`,
    SUM(unused_connectors)                                           AS `未被使用的槍數`,
    ROUND(100 * SUM(unused_connectors) / SUM(connectors), 1)         AS `未被使用的槍占比(%)`
FROM judged
GROUP BY district
ORDER BY FIELD(district, '東區', '北區', '香山區', '未分類');
