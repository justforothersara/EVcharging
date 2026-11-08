-- 頁面：② 使用率分析
-- 問題：哪些站最常被使用？排名前面的站，資料有沒有需要注意的地方？
-- 圖表：表格（依使用率排名）
-- 更新：每小時（v_connector_flag 每次約需 20 秒）
--
-- 使用率、可用率、滿站率的定義同 01_kpi_overview.sql
-- 事實欄位與 ⚠️ 計數來自 v_connector_flag（規則見 db/migrations/006_connector_flag.sql）：
--   狀態變化次數：站內所有槍的合計
--   最長連續相同狀態：站內各槍的最大值（小時）
--   TDX 最後更新：站內各槍最新一批的 TDX 更新時間中，最新的一個
--   ⚠️ 欄位：站內符合該規則的槍數；完整的每支槍標記見 ⑥ 資料品質
-- 有異常的站照常排名，不排除

WITH usage_by_station AS (
    SELECT
        c.station_id,
        COUNT(DISTINCT c.charging_point_id, c.connector_id) AS connectors,
        SUM(c.samples)      AS samples,
        SUM(c.occupied_cnt) AS occupied,
        SUM(c.faulted_cnt)  AS faulted
    FROM connector_hourly_usage c
    JOIN v_station v ON v.station_id = c.station_id
    WHERE v.in_scope = 1
    GROUP BY c.station_id
),
full_by_station AS (
    SELECT station_id, SUM(full_cnt) AS full_cnt, SUM(samples) AS samples
    FROM station_hourly_usage
    GROUP BY station_id
),
flag_by_station AS (
    SELECT
        station_id,
        SUM(status_changes)      AS status_changes,
        MAX(longest_run_samples) AS longest_run_samples,
        MAX(latest_update)       AS latest_update,
        SUM(is_unchanged)        AS unchanged,
        GROUP_CONCAT(DISTINCT CASE WHEN is_unchanged THEN
            CASE latest_status WHEN 1 THEN '閒置' WHEN 2 THEN '佔用' WHEN 3 THEN '故障' END
        END ORDER BY latest_status SEPARATOR '、') AS unchanged_states,
        SUM(is_stale)            AS stale,
        SUM(is_all_faulted)      AS all_faulted
    FROM v_connector_flag
    GROUP BY station_id
),
ranked AS (
    SELECT
        v.name_zh,
        v.district,
        u.connectors,
        100 * u.occupied / NULLIF(u.samples - u.faulted, 0) AS usage_pct,
        100 * (u.samples - u.faulted) / u.samples           AS availability_pct,
        100 * fs.full_cnt / fs.samples                      AS full_pct,
        f.status_changes,
        f.longest_run_samples,
        f.latest_update,
        f.unchanged,
        f.unchanged_states,
        f.stale,
        f.all_faulted
    FROM usage_by_station u
    JOIN v_station v        ON v.station_id = u.station_id
    JOIN full_by_station fs ON fs.station_id = u.station_id
    JOIN flag_by_station f  ON f.station_id = u.station_id
)
SELECT
    RANK() OVER (ORDER BY usage_pct DESC)          AS `排名`,
    name_zh                                        AS `充電站`,
    district                                       AS `行政區`,
    connectors                                     AS `充電槍數`,
    ROUND(usage_pct, 1)                            AS `使用率(%)`,
    ROUND(availability_pct, 1)                     AS `可用率(%)`,
    ROUND(full_pct, 1)                             AS `滿站率(%)`,
    status_changes                                 AS `狀態變化次數`,
    ROUND(longest_run_samples / 6, 1)              AS `最長連續相同狀態(小時)`,
    latest_update                                  AS `TDX 最後更新`,
    CASE WHEN unchanged > 0 THEN CONCAT(unchanged, '（', unchanged_states, '）')
         ELSE '0' END                              AS `⚠️ 狀態未變化`,
    stale                                          AS `⚠️ 超過24h未更新`,
    all_faulted                                    AS `⚠️ 全程故障`
FROM ranked
ORDER BY `排名`, name_zh;
