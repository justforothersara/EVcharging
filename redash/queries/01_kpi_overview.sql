-- 頁面：① 經營總覽
-- 問題：全部期間的可用率、使用率、滿站率，以及納入計算的站數、槍數
-- 圖表：數字卡片（每個欄位一張）
-- 更新：每小時
--
-- 定義：
--   可用率 = 非故障樣本 ÷ 全部樣本（設備妥善率）
--   使用率 = 佔用樣本 ÷ 非故障樣本
--   滿站率 = 滿站批次 ÷ 全部批次（滿站 = 沒有閒置槍、且至少 1 支佔用）
-- 範圍：只計算 in_scope = 1 的站（不含竹北市 3 站；未分類的站照常計算）
-- 缺漏的批次不在資料表裡，所以不會算進分母

WITH conn AS (
    SELECT
        COUNT(DISTINCT c.station_id)                                      AS stations,
        COUNT(DISTINCT c.station_id, c.charging_point_id, c.connector_id) AS connectors,
        SUM(c.samples)      AS samples,
        SUM(c.occupied_cnt) AS occupied,
        SUM(c.faulted_cnt)  AS faulted,
        MIN(c.hour_start)   AS first_hour,
        MAX(c.hour_start)   AS last_hour
    FROM connector_hourly_usage c
    JOIN v_station v ON v.station_id = c.station_id
    WHERE v.in_scope = 1
),
st AS (
    SELECT
        SUM(h.full_cnt) AS full_cnt,
        SUM(h.samples)  AS samples
    FROM station_hourly_usage h
    JOIN v_station v ON v.station_id = h.station_id
    WHERE v.in_scope = 1
)
SELECT
    conn.stations                                                          AS `充電站數`,
    conn.connectors                                                        AS `充電槍數`,
    ROUND(100 * (conn.samples - conn.faulted) / conn.samples, 1)           AS `可用率(%)`,
    ROUND(100 * conn.occupied / NULLIF(conn.samples - conn.faulted, 0), 1) AS `使用率(%)`,
    ROUND(100 * st.full_cnt / st.samples, 1)                               AS `滿站率(%)`,
    conn.first_hour                                                        AS `資料起始`,
    conn.last_hour + INTERVAL 1 HOUR                                       AS `資料截止`
FROM conn
CROSS JOIN st;
