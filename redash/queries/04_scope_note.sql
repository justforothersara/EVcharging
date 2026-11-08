-- 頁面：① 經營總覽
-- 問題：哪些站不納入計算、哪些站是未分類
-- 圖表：表格
-- 更新：每天（站點資料每天 22:00 同步）
--
-- 縣市歸屬有誤：TDX 新竹市資料裡，行政區是新竹市以外的站 → 不納入計算
-- 未分類：TDX 沒有提供行政區的站 → 照常納入計算
-- 充電槍數取自全部期間的每小時彙總；沒有任何彙總資料的站顯示 0

SELECT
    CASE WHEN v.in_scope = 0 THEN '縣市歸屬有誤（不納入計算）'
         ELSE '未分類（納入計算）' END                       AS `類別`,
    CASE WHEN v.in_scope = 0 THEN CONCAT('行政區為「', v.town, '」，不屬於新竹市')
         ELSE 'TDX 未提供行政區' END                         AS `判斷依據`,
    v.name_zh                                                AS `充電站`,
    v.address                                                AS `地址`,
    COUNT(DISTINCT c.charging_point_id, c.connector_id)      AS `充電槍數`
FROM v_station v
LEFT JOIN connector_hourly_usage c ON c.station_id = v.station_id
WHERE v.in_scope = 0 OR v.town IS NULL
GROUP BY v.station_id, v.in_scope, v.town, v.name_zh, v.address
ORDER BY v.in_scope, v.name_zh;
