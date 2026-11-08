-- 頁面：① 經營總覽
-- 問題：每天的可用率、使用率、滿站率怎麼變化
-- 圖表：折線圖（X 軸：日期；Y 軸：三個比率）
-- 更新：每小時
--
-- 定義同 01_kpi_overview.sql
-- 「批次數」是當天實際收到的批次數，完整的一天是 144 批（每 10 分鐘 1 批）。
-- 第一天、今天、停機的日子批次數會比較少，照實列出，不補值也不排除

WITH conn AS (
    SELECT
        DATE(c.hour_start)  AS day,
        SUM(c.samples)      AS samples,
        SUM(c.occupied_cnt) AS occupied,
        SUM(c.faulted_cnt)  AS faulted
    FROM connector_hourly_usage c
    JOIN v_station v ON v.station_id = c.station_id
    WHERE v.in_scope = 1
    GROUP BY day
),
st AS (
    SELECT
        DATE(h.hour_start) AS day,
        SUM(h.full_cnt)    AS full_cnt,
        SUM(h.samples)     AS samples
    FROM station_hourly_usage h
    JOIN v_station v ON v.station_id = h.station_id
    WHERE v.in_scope = 1
    GROUP BY day
),
-- 每小時的批次數 = 該小時所有站裡最大的樣本數
batches AS (
    SELECT DATE(hour_start) AS day, SUM(n) AS batches
    FROM (
        SELECT hour_start, MAX(samples) AS n
        FROM station_hourly_usage
        GROUP BY hour_start
    ) AS per_hour
    GROUP BY day
)
SELECT
    conn.day                                                               AS `日期`,
    ROUND(100 * (conn.samples - conn.faulted) / conn.samples, 1)           AS `可用率(%)`,
    ROUND(100 * conn.occupied / NULLIF(conn.samples - conn.faulted, 0), 1) AS `使用率(%)`,
    ROUND(100 * st.full_cnt / st.samples, 1)                               AS `滿站率(%)`,
    batches.batches                                                        AS `批次數`
FROM conn
JOIN st      ON st.day = conn.day
JOIN batches ON batches.day = conn.day
ORDER BY conn.day;
