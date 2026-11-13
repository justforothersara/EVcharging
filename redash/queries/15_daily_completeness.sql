-- 頁面：⑤ 資料品質
-- 問題：資料有沒有收齊？沒收到的批次是什麼原因？
-- 圖表：長條圖（X 軸：日期標籤，含「實際/應有」批數；Y 軸：完整度）＋ 表格
-- 更新：每小時
--
-- 應有批數：從第一批到現在，每 10 分鐘 1 批（第一天和今天只算已經過去的時間）
--   最新一批要等 5 分鐘後才算進應有批數，避免把正在收集的批次算成缺漏
-- 每一批依 fetch_runs 分成三種：
--   成功（實際批數）：有紀錄、沒有錯誤（包含重試後成功）
--   失敗：有紀錄、有錯誤 → 收集任務有執行，但連 TDX 失敗
--   無紀錄：fetch_runs 沒有這一批 → 收集任務沒有執行（系統停止）
-- 錯誤類型：錯誤訊息開頭的例外名稱，例如 ConnectTimeout、SSLError
-- 筆數異常批數：成功的批次中，筆數和最常見的筆數不同的批數

WITH digits AS (
    SELECT 0 AS d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
    UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9
),
bounds AS (
    SELECT
        MIN(batch_at) AS first_batch,
        FROM_UNIXTIME(FLOOR(UNIX_TIMESTAMP(NOW() - INTERVAL 5 MINUTE) / 600) * 600) AS last_slot
    FROM fetch_runs
),
slots AS (
    -- 0～99999 個 10 分鐘的時段，最多約 694 天
    SELECT b.first_batch + INTERVAL (a.d + 10 * c.d + 100 * e.d + 1000 * f.d + 10000 * g.d) * 10 MINUTE AS batch_at
    FROM bounds b
    CROSS JOIN digits a CROSS JOIN digits c CROSS JOIN digits e CROSS JOIN digits f CROSS JOIN digits g
    WHERE b.first_batch + INTERVAL (a.d + 10 * c.d + 100 * e.d + 1000 * f.d + 10000 * g.d) * 10 MINUTE <= b.last_slot
),
usual AS (
    SELECT record_count
    FROM fetch_runs
    WHERE error IS NULL
    GROUP BY record_count
    ORDER BY COUNT(*) DESC
    LIMIT 1
),
judged AS (
    SELECT
        DATE(s.batch_at) AS day,
        r.run_id IS NOT NULL AND r.error IS NULL                AS is_ok,
        r.run_id IS NOT NULL AND r.error IS NOT NULL            AS is_failed,
        r.run_id IS NULL                                        AS is_missing,
        CASE WHEN r.error IS NOT NULL THEN SUBSTRING_INDEX(r.error, '(', 1) END AS error_type,
        r.error IS NULL AND r.record_count <> u.record_count    AS is_odd_count
    FROM slots s
    LEFT JOIN fetch_runs r ON r.batch_at = s.batch_at
    CROSS JOIN usual u
)
SELECT
    CONCAT(DATE_FORMAT(day, '%m/%d'), '（', SUM(is_ok), '/', COUNT(*), '）') AS `日期（實際/應有）`,
    day                                                      AS `日期`,
    COUNT(*)                                                 AS `應有批數`,
    SUM(is_ok)                                               AS `實際批數`,
    ROUND(100 * SUM(is_ok) / COUNT(*), 1)                    AS `完整度(%)`,
    SUM(is_failed)                                           AS `失敗批數`,
    SUM(is_missing)                                          AS `無紀錄批數`,
    COALESCE(GROUP_CONCAT(DISTINCT error_type ORDER BY error_type SEPARATOR '、'), '') AS `錯誤類型`,
    SUM(COALESCE(is_odd_count, 0))                           AS `筆數異常批數`
FROM judged
GROUP BY day
ORDER BY day;
