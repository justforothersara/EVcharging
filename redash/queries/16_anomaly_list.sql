-- 頁面：⑤ 資料品質
-- 問題：哪些站、哪些槍的資料有異常？
-- 圖表：表格（站層級的異常排最前面，再依標記、充電站排序）
-- 更新：每小時（v_connector_flag 每次約需 30 秒）
--
-- 充電槍的標記來自 v_connector_flag（規則見 db/migrations/006_connector_flag.sql）：
--   全期間皆為閒置／全期間皆為佔用／期間內全程故障：資料涵蓋 ≥ 24 小時，且狀態變化 0 次
--   超過 24 小時未更新：全部資料的最新批次時間 − TDX 狀態最後更新時間 > 24 小時
--   一支槍可能同時有多個標記，以「；」分隔
-- ② ③ ④ 的 ⚠️ 欄位只顯示計數，完整明細在這裡
-- 站層級：納入範圍的站，但從來沒有任何充電槍資料
-- 只描述資料，不推測原因；有標記的槍在其他頁照常計算，不排除

SELECT
    '充電站'                                     AS `層級`,
    v.name_zh                                    AS `充電站`,
    v.district                                   AS `行政區`,
    ''                                           AS `充電樁`,
    ''                                           AS `充電槍`,
    '沒有任何充電槍資料'                          AS `異常標記`,
    NULL                                         AS `樣本數`,
    NULL                                         AS `資料涵蓋(小時)`,
    NULL                                         AS `狀態變化次數`,
    NULL                                         AS `最長連續相同狀態(小時)`,
    ''                                           AS `最新狀態`,
    NULL                                         AS `TDX 最後更新`,
    NULL                                         AS `距今未更新(小時)`
FROM v_station v
WHERE v.in_scope = 1
  AND NOT EXISTS (SELECT 1 FROM connector_hourly_usage c WHERE c.station_id = v.station_id)
UNION ALL
SELECT
    '充電槍',
    v.name_zh,
    v.district,
    f.charging_point_id,
    f.connector_id,
    f.flag_text,
    f.samples,
    ROUND(f.span_hours, 1),
    f.status_changes,
    ROUND(f.longest_run_samples / 6, 1),
    CASE f.latest_status WHEN 1 THEN '閒置' WHEN 2 THEN '佔用' WHEN 3 THEN '故障' ELSE '不明' END,
    f.latest_update,
    ROUND(f.hours_since_update, 1)
FROM v_connector_flag f
JOIN v_station v ON v.station_id = f.station_id
WHERE v.in_scope = 1
  AND COALESCE(f.flag_text, '') <> ''
ORDER BY FIELD(`層級`, '充電站', '充電槍'), `異常標記`, `充電站`, `充電樁`, `充電槍`;
