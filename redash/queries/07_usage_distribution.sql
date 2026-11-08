-- 頁面：② 使用率分析
-- 問題：大部分的充電槍，平均一天被使用幾小時？
-- 圖表：長條圖（X 軸：區間；Y 軸：槍數）
-- 更新：每小時
--
-- 每天平均使用時數 = 佔用樣本 ÷ 全部樣本 × 24 小時
--   用「有資料的時間」換算，缺漏的批次不影響
-- 全部期間都是故障的槍無法使用，另外列為「全程故障」，不放進 0 小時
-- 沒有槍的區間也會列出，顯示 0

WITH per_connector AS (
    SELECT
        c.station_id, c.charging_point_id, c.connector_id,
        SUM(c.occupied_cnt) / SUM(c.samples) * 24 AS hours_per_day,
        SUM(c.faulted_cnt) = SUM(c.samples)       AS all_faulted
    FROM connector_hourly_usage c
    JOIN v_station v ON v.station_id = c.station_id
    WHERE v.in_scope = 1
    GROUP BY c.station_id, c.charging_point_id, c.connector_id
),
bucketed AS (
    SELECT
        CASE WHEN all_faulted          THEN 7
             WHEN hours_per_day = 0    THEN 1
             WHEN hours_per_day < 1    THEN 2
             WHEN hours_per_day < 2    THEN 3
             WHEN hours_per_day < 4    THEN 4
             WHEN hours_per_day < 8    THEN 5
             ELSE 6 END AS bucket
    FROM per_connector
),
buckets AS (
    SELECT 1 AS bucket, '0 小時（未被使用）' AS label UNION ALL
    SELECT 2, '未滿 1 小時' UNION ALL
    SELECT 3, '1～2 小時'   UNION ALL
    SELECT 4, '2～4 小時'   UNION ALL
    SELECT 5, '4～8 小時'   UNION ALL
    SELECT 6, '8 小時以上'  UNION ALL
    SELECT 7, '全程故障'
)
SELECT
    b.label                                                    AS `每天平均使用時數`,
    COUNT(x.bucket)                                            AS `充電槍數`,
    ROUND(100 * COUNT(x.bucket) / (SELECT COUNT(*) FROM bucketed), 1) AS `占比(%)`
FROM buckets b
LEFT JOIN bucketed x ON x.bucket = b.bucket
GROUP BY b.bucket, b.label
ORDER BY b.bucket;
