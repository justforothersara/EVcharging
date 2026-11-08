-- 頁面：② 使用率分析
-- 問題：一天中幾點最忙？平日和週末有沒有不同？
-- 圖表：折線圖（X 軸：時；Y 軸：平日使用率、週末使用率）
-- 更新：每小時
--
-- 使用率 = 佔用樣本 ÷ 非故障樣本（定義同 01_kpi_overview.sql）
-- 週末 = 星期六、日；國定假日不另外處理
-- 「天數」是該時段實際有資料的天數，週末的天數較少，照實列出

SELECT
    HOUR(c.hour_start) AS `時`,
    ROUND(100 * SUM(CASE WHEN DAYOFWEEK(c.hour_start) NOT IN (1, 7) THEN c.occupied_cnt END)
              / NULLIF(SUM(CASE WHEN DAYOFWEEK(c.hour_start) NOT IN (1, 7)
                                THEN c.samples - c.faulted_cnt END), 0), 1) AS `平日使用率(%)`,
    ROUND(100 * SUM(CASE WHEN DAYOFWEEK(c.hour_start) IN (1, 7) THEN c.occupied_cnt END)
              / NULLIF(SUM(CASE WHEN DAYOFWEEK(c.hour_start) IN (1, 7)
                                THEN c.samples - c.faulted_cnt END), 0), 1) AS `週末使用率(%)`,
    COUNT(DISTINCT CASE WHEN DAYOFWEEK(c.hour_start) NOT IN (1, 7) THEN DATE(c.hour_start) END) AS `平日天數`,
    COUNT(DISTINCT CASE WHEN DAYOFWEEK(c.hour_start) IN (1, 7) THEN DATE(c.hour_start) END)     AS `週末天數`
FROM connector_hourly_usage c
JOIN v_station v ON v.station_id = c.station_id
WHERE v.in_scope = 1
GROUP BY HOUR(c.hour_start)
ORDER BY `時`;
