-- 頁面：① 經營總覽
-- 問題：東區、北區、香山區、未分類，各區的站數、槍數、可用率、使用率、滿站率
-- 圖表：長條圖（X 軸：行政區；Y 軸：三個比率），旁邊放表格
-- 更新：每小時
--
-- 定義同 01_kpi_overview.sql
-- 「未分類」是 TDX 沒有提供行政區的站，照常納入計算

WITH conn AS (
    SELECT
        v.district,
        COUNT(DISTINCT c.station_id)                                      AS stations,
        COUNT(DISTINCT c.station_id, c.charging_point_id, c.connector_id) AS connectors,
        SUM(c.samples)      AS samples,
        SUM(c.occupied_cnt) AS occupied,
        SUM(c.faulted_cnt)  AS faulted
    FROM connector_hourly_usage c
    JOIN v_station v ON v.station_id = c.station_id
    WHERE v.in_scope = 1
    GROUP BY v.district
),
st AS (
    SELECT
        v.district,
        SUM(h.full_cnt) AS full_cnt,
        SUM(h.samples)  AS samples
    FROM station_hourly_usage h
    JOIN v_station v ON v.station_id = h.station_id
    WHERE v.in_scope = 1
    GROUP BY v.district
)
SELECT
    conn.district                                                          AS `行政區`,
    conn.stations                                                          AS `充電站數`,
    conn.connectors                                                        AS `充電槍數`,
    ROUND(100 * (conn.samples - conn.faulted) / conn.samples, 1)           AS `可用率(%)`,
    ROUND(100 * conn.occupied / NULLIF(conn.samples - conn.faulted, 0), 1) AS `使用率(%)`,
    ROUND(100 * st.full_cnt / st.samples, 1)                               AS `滿站率(%)`
FROM conn
JOIN st ON st.district = conn.district
ORDER BY FIELD(conn.district, '東區', '北區', '香山區', '未分類');
