-- 006：充電槍的事實欄位與異常標記（Dashboard ② ③ ⑤ ⑥ 頁共用，規則只寫在這裡）
-- 每支充電槍一列，從全部快照計算：
--   status_changes：相鄰兩批的狀態不同就算 1 次（中間缺批次也照樣比較前後兩批）
--   longest_run_samples：最長連續相同狀態的批次數（× 10 分鐘 ≈ 時間）；缺批次就斷開，和 build_events 相同
--   latest_update：最新一批的 TDX 狀態最後更新時間
-- 標記（只描述資料，不推測原因）：
--   全期間皆為閒置／全期間皆為佔用／期間內全程故障：資料涵蓋 ≥ 24 小時，且狀態變化 0 次
--   超過 24 小時未更新：全部資料的最新批次時間 − TDX 狀態最後更新時間 > 24 小時
SET NAMES utf8mb4;

CREATE OR REPLACE VIEW v_connector_flag AS
WITH flagged AS (
    SELECT
        station_id, charging_point_id, connector_id, batch_at, connector_status, last_update_time,
        LAG(connector_status) OVER w <> connector_status AS is_change,
        (LAG(batch_at) OVER w IS NULL
            OR LAG(connector_status) OVER w <> connector_status
            OR LAG(batch_at) OVER w <> batch_at - INTERVAL 10 MINUTE) AS is_new_run,
        ROW_NUMBER() OVER (PARTITION BY station_id, charging_point_id, connector_id
                           ORDER BY batch_at DESC) AS rn_desc,
        MAX(batch_at) OVER () AS latest_batch
    FROM connector_status_snapshot
    WINDOW w AS (PARTITION BY station_id, charging_point_id, connector_id ORDER BY batch_at)
),
numbered AS (
    SELECT
        flagged.*,
        SUM(is_new_run) OVER (PARTITION BY station_id, charging_point_id, connector_id
                              ORDER BY batch_at) AS run_no
    FROM flagged
),
runs AS (
    SELECT station_id, charging_point_id, connector_id, MAX(run_samples) AS longest_run_samples
    FROM (
        SELECT station_id, charging_point_id, connector_id, run_no, COUNT(*) AS run_samples
        FROM numbered
        GROUP BY station_id, charging_point_id, connector_id, run_no
    ) AS per_run
    GROUP BY station_id, charging_point_id, connector_id
),
per_connector AS (
    SELECT
        station_id, charging_point_id, connector_id,
        MIN(batch_at)                    AS first_batch,
        MAX(batch_at)                    AS last_batch,
        COUNT(*)                         AS samples,
        COALESCE(SUM(is_change), 0)      AS status_changes,
        MIN(connector_status)            AS min_status,
        MAX(CASE WHEN rn_desc = 1 THEN connector_status END) AS latest_status,
        MAX(CASE WHEN rn_desc = 1 THEN last_update_time END) AS latest_update,
        MAX(latest_batch)                AS latest_batch
    FROM numbered
    GROUP BY station_id, charging_point_id, connector_id
),
judged AS (
    SELECT
        p.*,
        r.longest_run_samples,
        TIMESTAMPDIFF(MINUTE, p.first_batch, p.last_batch) / 60 AS span_hours,
        TIMESTAMPDIFF(MINUTE, p.latest_update, p.latest_batch) / 60 AS hours_since_update,
        (TIMESTAMPDIFF(MINUTE, p.first_batch, p.last_batch) >= 24 * 60
            AND p.status_changes = 0) AS is_unchanged,
        (TIMESTAMPDIFF(MINUTE, p.latest_update, p.latest_batch) > 24 * 60) AS is_stale
    FROM per_connector p
    JOIN runs r USING (station_id, charging_point_id, connector_id)
)
SELECT
    station_id, charging_point_id, connector_id,
    first_batch, last_batch, samples, span_hours,
    status_changes, longest_run_samples,
    latest_status, latest_update, hours_since_update,
    is_unchanged,
    (is_unchanged AND min_status = 3) AS is_all_faulted,
    COALESCE(is_stale, 0) AS is_stale,
    NULLIF(CONCAT_WS('；',
        CASE WHEN is_unchanged THEN
            CASE min_status WHEN 1 THEN '全期間皆為閒置'
                            WHEN 2 THEN '全期間皆為佔用'
                            WHEN 3 THEN '期間內全程故障' END
        END,
        CASE WHEN is_stale THEN '超過 24 小時未更新' END
    ), '') AS flag_text
FROM judged;
