-- 002：充電槍狀態事件
-- 把連續相同狀態的快照合併成一個「事件」，例如連續 3 批都是故障 → 1 次故障，持續 3 個樣本
-- 由 build_events 任務每天從快照建立；快照保留 6 個月，事件長期保存
SET NAMES utf8mb4;

CREATE TABLE IF NOT EXISTS connector_event (
    station_id        VARCHAR(64)       NOT NULL COMMENT '充電站代碼',
    charging_point_id VARCHAR(64)       NOT NULL COMMENT '充電樁代碼',
    connector_id      VARCHAR(64)       NOT NULL COMMENT '充電槍代碼',
    event_type        VARCHAR(16)       NOT NULL COMMENT 'occupied=佔用（狀態 2）, faulted=故障（狀態 3）',
    start_at          DATETIME          NOT NULL COMMENT '事件第一批的時間',
    end_at            DATETIME          NOT NULL COMMENT '事件最後一批的時間',
    samples           SMALLINT UNSIGNED NOT NULL COMMENT '持續的樣本數（× 10 分鐘 ≈ 持續時間）',
    built_at          DATETIME          NOT NULL COMMENT '這筆事件最後一次計算的時間',
    PRIMARY KEY (station_id, charging_point_id, connector_id, event_type, start_at),
    KEY idx_event_type_start (event_type, start_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='充電槍狀態事件（佔用、故障）';
