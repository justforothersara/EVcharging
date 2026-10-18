-- 新竹市充電站數據分析平台：資料表定義
-- MySQL 容器第一次啟動時會自動執行這個檔案（只執行一次）

SET NAMES utf8mb4;
SET time_zone = '+08:00';

-- 1. 充電站（維度表，每天 22:00 同步）
CREATE TABLE IF NOT EXISTS station (
    station_id      VARCHAR(64)  NOT NULL COMMENT '充電站代碼',
    operator_id     VARCHAR(16)  NULL     COMMENT '營運業者代碼',
    name_zh         VARCHAR(255) NULL     COMMENT '中文名稱',
    town            VARCHAR(32)  NULL     COMMENT '行政區',
    address         VARCHAR(255) NULL     COMMENT '完整地址',
    position_lat    DECIMAL(9,6) NULL     COMMENT '緯度',
    position_lon    DECIMAL(9,6) NULL     COMMENT '經度',
    operation_type  TINYINT      NULL     COMMENT '營運種類：1 BOT、2 公營、3 民營',
    spaces          SMALLINT     NULL     COMMENT '充電車位數',
    charging_points SMALLINT     NULL     COMMENT '充電樁數',
    service_time    TEXT         NULL     COMMENT '服務時間',
    charging_rate   TEXT         NULL     COMMENT '充電費率',
    parking_rate    TEXT         NULL     COMMENT '停車費率',
    synced_at       DATETIME     NOT NULL COMMENT '最後同步時間',
    PRIMARY KEY (station_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='充電站';

-- 2. 充電樁（維度表，每天 22:00 同步）
CREATE TABLE IF NOT EXISTS charging_point (
    station_id        VARCHAR(64) NOT NULL COMMENT '所屬充電站',
    charging_point_id VARCHAR(64) NOT NULL COMMENT '充電樁代碼',
    operator_id       VARCHAR(16) NULL     COMMENT '營運業者代碼',
    floor             VARCHAR(64) NULL     COMMENT '樓層',
    connectors        JSON        NULL     COMMENT '槍型與數量，例如 [{"Type":5,"Quantity":2}]',
    payment           JSON        NULL     COMMENT '付款方式',
    synced_at         DATETIME    NOT NULL COMMENT '最後同步時間',
    PRIMARY KEY (station_id, charging_point_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='充電樁';

-- 3. 抓取紀錄（每 10 分鐘 1 筆）
CREATE TABLE IF NOT EXISTS fetch_runs (
    run_id          BIGINT       NOT NULL AUTO_INCREMENT COMMENT '抓取編號',
    batch_at        DATETIME     NOT NULL COMMENT '批次時間（取整到 10 分鐘）',
    fetched_at      DATETIME     NOT NULL COMMENT '實際抓取時間',
    worker          VARCHAR(128) NULL     COMMENT '執行的 worker',
    attempts        TINYINT      NOT NULL DEFAULT 1 COMMENT '第幾次嘗試',
    http_status     SMALLINT     NULL     COMMENT 'HTTP 狀態碼',
    record_count    INT          NOT NULL DEFAULT 0 COMMENT '資料筆數',
    response_bytes  INT          NULL     COMMENT '回應大小',
    src_update_time DATETIME     NULL     COMMENT 'TDX 資料更新時間',
    error           TEXT         NULL     COMMENT '錯誤訊息，成功時為 NULL',
    PRIMARY KEY (run_id),
    UNIQUE KEY uk_fetch_runs_batch (batch_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='抓取紀錄';

-- 4. 充電槍狀態快照（每 10 分鐘 +499 筆，保留 6 個月）
CREATE TABLE IF NOT EXISTS connector_status_snapshot (
    batch_at          DATETIME         NOT NULL COMMENT '批次時間',
    station_id        VARCHAR(64)      NOT NULL COMMENT '充電站代碼',
    charging_point_id VARCHAR(64)      NOT NULL COMMENT '充電樁代碼',
    connector_id      VARCHAR(64)      NOT NULL COMMENT '充電槍代碼',
    connector_type    TINYINT UNSIGNED NULL     COMMENT '槍型：1 CCS1、2 CCS2、3 CHAdeMO、4 Tesla TPC、5 J1772、6 Type2、254 Others、255 Unknown',
    connector_status  TINYINT          NULL     COMMENT '狀態：1 閒置、2 佔用/充電中、3 異常故障',
    charged_kwh       DECIMAL(10,3)    NULL     COMMENT '已充電度數',
    charged_percent   DECIMAL(5,2)     NULL     COMMENT '已充電百分比',
    last_update_time  DATETIME         NULL     COMMENT '狀態最後更新時間',
    PRIMARY KEY (batch_at, station_id, charging_point_id, connector_id),
    KEY idx_snapshot_connector (station_id, charging_point_id, connector_id, batch_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='充電槍狀態快照';

-- 5. 每小時彙總（每小時 +499 筆，長期保存）
CREATE TABLE IF NOT EXISTS connector_hourly_usage (
    hour_start        DATETIME         NOT NULL COMMENT '小時起點，例如 14:00 代表 14:00～14:59',
    station_id        VARCHAR(64)      NOT NULL COMMENT '充電站代碼',
    charging_point_id VARCHAR(64)      NOT NULL COMMENT '充電樁代碼',
    connector_id      VARCHAR(64)      NOT NULL COMMENT '充電槍代碼',
    connector_type    TINYINT UNSIGNED NULL     COMMENT '槍型',
    samples           TINYINT UNSIGNED NOT NULL COMMENT '快照次數，正常為 6',
    available_cnt     TINYINT UNSIGNED NOT NULL COMMENT '閒置次數（狀態 1）',
    occupied_cnt      TINYINT UNSIGNED NOT NULL COMMENT '佔用次數（狀態 2）',
    faulted_cnt       TINYINT UNSIGNED NOT NULL COMMENT '故障次數（狀態 3）',
    PRIMARY KEY (hour_start, station_id, charging_point_id, connector_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='每小時彙總';
