-- 頁面：④ 維運監控
-- 問題：現在哪些槍壞了？壞多久了？
-- 圖表：數字卡片（目前故障槍數，用 Count rows）＋ 表格（依已連續故障時間排序）
-- 更新：每 10 分鐘（v_connector_flag 每次約需 20 秒）
--
-- 目前故障 = 最新一批的狀態是故障（狀態 3）
-- 直接查快照，不用 connector_event（事件表每天 00:15 才更新一次）
-- 故障開始：往回找這次連續故障的第一批
--   判斷規則同 build_events：狀態改變、或和上一批間隔超過 30 分鐘（漏掉 3 批以上），就是另一段
-- 異常標記來自 v_connector_flag（規則見 db/migrations/006_connector_flag.sql）

WITH latest AS (
    SELECT MAX(batch_at) AS batch_at FROM connector_status_snapshot
),
faulted_now AS (
    SELECT s.station_id, s.charging_point_id, s.connector_id, s.last_update_time
    FROM connector_status_snapshot s
    JOIN latest l    ON l.batch_at = s.batch_at
    JOIN v_station v ON v.station_id = s.station_id
    WHERE v.in_scope = 1
      AND s.connector_status = 3
),
history AS (
    SELECT
        s.station_id, s.charging_point_id, s.connector_id, s.batch_at,
        (LAG(s.batch_at) OVER w IS NULL
         OR NOT (LAG(s.connector_status) OVER w <=> s.connector_status)
         OR LAG(s.batch_at) OVER w < s.batch_at - INTERVAL 30 MINUTE) AS is_new
    FROM connector_status_snapshot s
    JOIN faulted_now f
      ON f.station_id = s.station_id
     AND f.charging_point_id = s.charging_point_id
     AND f.connector_id = s.connector_id
    WINDOW w AS (PARTITION BY s.station_id, s.charging_point_id, s.connector_id ORDER BY s.batch_at)
),
fault_start AS (
    SELECT station_id, charging_point_id, connector_id, MAX(batch_at) AS start_at
    FROM history
    WHERE is_new
    GROUP BY station_id, charging_point_id, connector_id
)
SELECT
    v.name_zh                                                        AS `充電站`,
    v.district                                                       AS `行政區`,
    f.charging_point_id                                              AS `充電樁`,
    f.connector_id                                                   AS `充電槍`,
    fs.start_at                                                      AS `故障開始`,
    ROUND((TIMESTAMPDIFF(MINUTE, fs.start_at, l.batch_at) + 10) / 60, 1) AS `已連續故障(小時)`,
    f.last_update_time                                               AS `TDX 最後更新`,
    COALESCE(NULLIF(cf.flag_text, ''), '')                           AS `⚠️ 異常標記`
FROM faulted_now f
CROSS JOIN latest l
JOIN v_station v    ON v.station_id = f.station_id
JOIN fault_start fs
  ON fs.station_id = f.station_id
 AND fs.charging_point_id = f.charging_point_id
 AND fs.connector_id = f.connector_id
LEFT JOIN v_connector_flag cf
  ON cf.station_id = f.station_id
 AND cf.charging_point_id = f.charging_point_id
 AND cf.connector_id = f.connector_id
ORDER BY fs.start_at, v.name_zh, f.charging_point_id, f.connector_id;
