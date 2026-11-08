-- 頁面：③ 站點配置評估
-- 問題：哪些站不夠用，應該擴充？
-- 圖表：散佈圖（X 軸：使用率；Y 軸：滿站率；依「分類」上色）＋ 表格（依滿站率排序）
-- 更新：每小時（v_connector_flag 每次約需 20 秒）
--
-- 門檻：擴站候選 = 滿站率 ≥ 20%（平均每天約 4.8 小時沒有空槍）← 要調整門檻，只改 params 這一行
-- 滿站率 = 滿站批次 ÷ 全部批次（滿站 = 沒有閒置槍、且至少 1 支佔用），定義同 01_kpi_overview.sql
-- 每天無空槍時數 = 滿站率 × 24 小時
-- 列出全部站（散佈圖需要），表格依滿站率由高到低排序，門檻上下的站都看得到
-- 有異常的站照常分類，不排除；⚠️ 欄位定義同 06_station_ranking.sql

WITH params AS (
    SELECT 20 AS full_threshold_pct
),
usage_by_station AS (
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
        100 * u.occupied / NULLIF(u.samples - u.faulted, 0) AS usage_pct,
        100 * fs.full_cnt / fs.samples                      AS full_pct,
        f.unchanged, f.unchanged_states, f.stale, f.all_faulted
    FROM usage_by_station u
    JOIN v_station v        ON v.station_id = u.station_id
    JOIN full_by_station fs ON fs.station_id = u.station_id
    JOIN flag_by_station f  ON f.station_id = u.station_id
)
SELECT
    j.name_zh                                       AS `充電站`,
    j.district                                      AS `行政區`,
    j.connectors                                    AS `充電槍數`,
    ROUND(j.usage_pct, 1)                           AS `使用率(%)`,
    ROUND(j.full_pct, 1)                            AS `滿站率(%)`,
    ROUND(j.full_pct / 100 * 24, 1)                 AS `每天無空槍時數`,
    CASE WHEN j.full_pct >= p.full_threshold_pct
         THEN CONCAT('擴站候選（滿站率 ≥ ', p.full_threshold_pct, '%）')
         ELSE '其他' END                            AS `分類`,
    CASE WHEN j.unchanged > 0 THEN CONCAT(j.unchanged, '（', j.unchanged_states, '）')
         ELSE '0' END                               AS `⚠️ 狀態未變化`,
    j.stale                                         AS `⚠️ 超過24h未更新`,
    j.all_faulted                                   AS `⚠️ 全程故障`
FROM judged j
CROSS JOIN params p
ORDER BY j.full_pct DESC, j.usage_pct DESC, j.name_zh;
