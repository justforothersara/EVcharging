-- 頁面：④ 維運監控
-- 問題：故障平均多久修好（MTTR）？平均多久壞一次（MTBF）？
-- 圖表：數字卡片（第 1 列「全部」的 MTTR、MTBF、尚未修復）＋ 表格（各站）
-- 更新：每小時（connector_event 每天 00:15 更新）
--
-- 只計算連續故障（持續 ≥ 20 分鐘）；單一樣本故障不算（設計 2 = A）
-- 故障持續時間 = end_at − start_at + 10 分鐘
-- 每次連續故障的結果，看結束後 30 分鐘內的下一批：
--   已修復：下一批是閒置或佔用
--   尚未修復：事件建立時，這次故障還持續到最後一批
--   結束時間未知：下一批前中斷超過 30 分鐘，或下一批狀態不明
-- MTTR = 已修復的連續故障，平均持續時數（尚未修復、結束時間未知的不算）
-- MTBF = 正常運作時數 ÷ 連續故障次數（以「每支槍」計：全部槍的非故障時數加總）
--   正常運作時數只算到事件建立時的最後一批，和事件的期間一致
-- 沒有連續故障的站不列出；「全部」那一列包含所有站
-- 全部時間都是故障的站沒有正常運作時數，MTBF 顯示空白

WITH build AS (
    SELECT MAX(s.batch_at) AS last_batch
    FROM connector_status_snapshot s
    WHERE s.batch_at <= (SELECT MAX(built_at) FROM connector_event)
),
sustained AS (
    SELECT
        e.station_id,
        TIMESTAMPDIFF(MINUTE, e.start_at, e.end_at) + 10 AS minutes,
        e.end_at,
        (SELECT s.connector_status
         FROM connector_status_snapshot s
         WHERE s.station_id = e.station_id
           AND s.charging_point_id = e.charging_point_id
           AND s.connector_id = e.connector_id
           AND s.batch_at >  e.end_at
           AND s.batch_at <= e.end_at + INTERVAL 30 MINUTE
         ORDER BY s.batch_at
         LIMIT 1) AS next_status
    FROM connector_event e
    JOIN v_station v ON v.station_id = e.station_id
    WHERE v.in_scope = 1
      AND e.event_type = 'faulted'
      AND TIMESTAMPDIFF(MINUTE, e.start_at, e.end_at) + 10 >= 20
),
judged AS (
    SELECT
        x.station_id,
        x.minutes,
        CASE WHEN x.next_status IN (1, 2)   THEN 'repaired'
             WHEN x.end_at >= b.last_batch  THEN 'ongoing'
             ELSE 'unknown' END AS outcome
    FROM sustained x
    CROSS JOIN build b
),
up_time AS (
    SELECT c.station_id, SUM(c.samples - c.faulted_cnt) / 6 AS up_hours
    FROM connector_hourly_usage c
    JOIN v_station v ON v.station_id = c.station_id
    CROSS JOIN build b
    WHERE v.in_scope = 1
      AND c.hour_start < DATE_FORMAT(b.last_batch, '%Y-%m-%d %H:00:00')
    GROUP BY c.station_id
),
per_station AS (
    SELECT
        station_id,
        COUNT(*)                                          AS faults,
        SUM(outcome = 'repaired')                         AS repaired,
        AVG(CASE WHEN outcome = 'repaired' THEN minutes END) / 60 AS mttr_hours,
        SUM(outcome = 'ongoing')                          AS ongoing,
        SUM(outcome = 'unknown')                          AS unknown
    FROM judged
    GROUP BY station_id
),
result AS (
    SELECT
        0                                                         AS sort_group,
        '全部'                                                    AS scope_name,
        ''                                                        AS district,
        COUNT(*)                                                  AS faults,
        SUM(outcome = 'repaired')                                 AS repaired,
        AVG(CASE WHEN outcome = 'repaired' THEN minutes END) / 60 AS mttr_hours,
        (SELECT SUM(up_hours) FROM up_time) / NULLIF(COUNT(*), 0) AS mtbf_hours,
        SUM(outcome = 'ongoing')                                  AS ongoing,
        SUM(outcome = 'unknown')                                  AS unknown
    FROM judged
    UNION ALL
    SELECT
        1,
        v.name_zh,
        v.district,
        p.faults,
        p.repaired,
        p.mttr_hours,
        NULLIF(u.up_hours, 0) / p.faults,
        p.ongoing,
        p.unknown
    FROM per_station p
    JOIN v_station v ON v.station_id = p.station_id
    LEFT JOIN up_time u ON u.station_id = p.station_id
)
SELECT
    scope_name               AS `範圍`,
    district                 AS `行政區`,
    faults                   AS `連續故障次數`,
    repaired                 AS `已修復次數`,
    ROUND(mttr_hours, 1)     AS `MTTR(小時)`,
    ROUND(mtbf_hours, 1)     AS `MTBF(小時)`,
    ongoing                  AS `尚未修復`,
    unknown                  AS `結束時間未知`
FROM result
ORDER BY sort_group, faults DESC, scope_name;
