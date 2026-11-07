-- 003：充電站每小時彙總
-- 計算每站每小時有幾批「全站滿了」或「全站停擺」，用來算滿站率和擴站評估
-- 由 aggregate_hourly 任務每小時計算（和 connector_hourly_usage 一起）
SET NAMES utf8mb4;

CREATE TABLE IF NOT EXISTS station_hourly_usage (
    hour_start  DATETIME          NOT NULL COMMENT '小時的開始時間，例如 14:00 代表 14:00～14:59',
    station_id  VARCHAR(64)       NOT NULL COMMENT '充電站代碼',
    connectors  SMALLINT UNSIGNED NOT NULL COMMENT '這一站的充電槍數量',
    samples     TINYINT UNSIGNED  NOT NULL COMMENT '這個小時的批次數（正常是 6）',
    full_cnt    TINYINT UNSIGNED  NOT NULL COMMENT '全站滿了的批次數：沒有可使用的槍，且至少 1 支佔用',
    down_cnt    TINYINT UNSIGNED  NOT NULL COMMENT '全站停擺的批次數：所有的槍都故障',
    PRIMARY KEY (hour_start, station_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='充電站每小時彙總（滿站、停擺）';
