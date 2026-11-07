-- 004：充電站 view，加上 Dashboard 用的行政區欄位
-- district：沒有行政區的站顯示為「未分類」（需求 3）
-- in_scope：新竹市的 3 個區和未分類 = 1；其他縣市（例如竹北市）= 0（需求 1、2）
SET NAMES utf8mb4;

CREATE OR REPLACE VIEW v_station AS
SELECT
    s.*,
    COALESCE(s.town, '未分類') AS district,
    (s.town IS NULL OR s.town IN ('東區', '北區', '香山區')) AS in_scope
FROM station s;
