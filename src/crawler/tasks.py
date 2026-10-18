"""
5 個 Celery 任務

佇列 collect  ：collect_live_status  每 10 分鐘抓即時狀態
佇列 sync     ：sync_stations        每天 22:00 同步充電站、充電樁
佇列 aggregate：aggregate_hourly     每小時第 5 分鐘彙總上一個小時
               purge_old_snapshots  每天 04:00 刪除 6 個月前的快照
佇列 archive  ：archive_raw          由前兩個任務送出，封存原始資料
"""

import gzip
import json
import os
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

import pymysql
import requests
from celery.utils.log import get_task_logger

from crawler.celery_app import app

logger = get_task_logger(__name__)

# 1. 基本設定

city = "Hsinchu"
taipei = ZoneInfo("Asia/Taipei")

token_url = (
    "https://tdx.transportdata.tw/auth/realms/"
    "TDXConnect/protocol/openid-connect/token"
)
api_base_url = "https://tdx.transportdata.tw/api/basic/v1/EV"

# 封存位置：local 存在本機資料夾；gcs 在階段 4 實作
archive_target = os.getenv("ARCHIVE_TARGET", "local")
archive_dir = Path(os.getenv("ARCHIVE_DIR", "/data/archive"))

# 2. 共用工具


def now_taipei():
    """取得現在的台灣時間（不含時區資訊）。

    MySQL 的 DATETIME 不含時區，一律存台灣時間。
    """
    return datetime.now(taipei).replace(tzinfo=None)


def floor_to_10_minutes(moment):
    """把時間取整到 10 分鐘，例如 14:17:32 → 14:10:00，讓每一批的時間對齊。"""
    return moment.replace(
        minute=moment.minute - moment.minute % 10, second=0, microsecond=0
    )


def parse_time(value):
    """把 TDX 的時間字串轉成台灣時間。

    例如 "2026-10-17T14:18:37+08:00"；空值或格式錯誤時回傳 None。
    """
    if not value:
        return None
    try:
        return datetime.fromisoformat(value).astimezone(taipei).replace(tzinfo=None)
    except ValueError:
        return None


def tdx_get(path):
    """取得 TDX Token 後呼叫指定的 API，回傳 response。

    每次呼叫都重新取得 Token（每天只有約 150 次，負擔很小）。
    """
    token_response = requests.post(
        token_url,
        data={
            "grant_type": "client_credentials",
            "client_id": os.environ["TDX_CLIENT_ID"],
            "client_secret": os.environ["TDX_CLIENT_SECRET"],
        },
        timeout=30,
    )
    token_response.raise_for_status()
    access_token = token_response.json()["access_token"]

    response = requests.get(
        f"{api_base_url}/{path}",
        headers={"Authorization": f"Bearer {access_token}"},
        params={"$format": "JSON", "$top": 1000},
        timeout=30,
    )
    response.raise_for_status()
    return response


def connect_db():
    """建立 MySQL 連線，連線資訊全部來自環境變數。"""
    return pymysql.connect(
        host=os.environ["MYSQL_HOST"],
        port=int(os.getenv("MYSQL_PORT", "3306")),
        user=os.environ["MYSQL_USER"],
        password=os.environ["MYSQL_PASSWORD"],
        database=os.environ["MYSQL_DATABASE"],
        charset="utf8mb4",
        init_command="SET time_zone = '+08:00'",
    )


# 3. 任務 1：收集即時狀態（佇列 collect）


@app.task(bind=True, max_retries=3)
def collect_live_status(self, batch_at=None):
    """任務 1（佇列 collect，每 10 分鐘）：抓新竹市充電槍即時狀態。

    寫入 fetch_runs 和快照，再交給 archive 佇列封存原始資料。
    """
    # 第一次執行時決定批次時間；重試時沿用同一個批次時間
    if batch_at is None:
        batch_at = floor_to_10_minutes(now_taipei()).isoformat()

    fetched_at = now_taipei()

    try:
        response = tdx_get(f"ConnectorLiveStatus/City/{city}")
        data = response.json()
    except requests.RequestException as error:
        # 30 秒、60 秒、120 秒後重試
        if self.request.retries < self.max_retries:
            raise self.retry(
                exc=error,
                countdown=30 * 2 ** self.request.retries,
                args=[batch_at],
            )
        # 重試 3 次都失敗：記錄下來
        save_failed_run(self, batch_at, fetched_at, error)
        raise

    live_statuses = data.get("LiveStatuses", []) if isinstance(data, dict) else data

    # 筆數剛好等於 $top 時，資料可能被截斷
    if len(live_statuses) >= 1000:
        logger.warning("%s 筆數達 1000 筆，資料可能被截斷", batch_at)

    rows = [
        (
            batch_at,
            item.get("StationID") or "",
            item.get("ChargingPointID") or "",
            item.get("ConnectorID") or "",
            item.get("ConnectorType"),
            item.get("ConnectorStatus"),
            item.get("ChargedKWH"),
            item.get("ChargedPercent"),
            parse_time(item.get("LastUpdateTime")),
        )
        for item in live_statuses
    ]

    # fetch_runs 和快照在同一個交易裡寫入，要嘛全部成功，要嘛全部取消
    with connect_db() as conn, conn.cursor() as cursor:
        cursor.execute(
            "INSERT INTO fetch_runs "
            "(batch_at, fetched_at, worker, attempts, http_status, "
            "record_count, response_bytes, src_update_time, error) "
            "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, NULL) AS new "
            "ON DUPLICATE KEY UPDATE "
            "fetched_at = new.fetched_at, worker = new.worker, "
            "attempts = new.attempts, http_status = new.http_status, "
            "record_count = new.record_count, "
            "response_bytes = new.response_bytes, "
            "src_update_time = new.src_update_time, error = NULL",
            (
                batch_at,
                fetched_at,
                self.request.hostname,
                self.request.retries + 1,
                response.status_code,
                len(rows),
                len(response.content),
                parse_time(data.get("UpdateTime") if isinstance(data, dict) else None),
            ),
        )
        # INSERT IGNORE：同一批次、同一支槍已經存在的話就跳過
        cursor.executemany(
            "INSERT IGNORE INTO connector_status_snapshot "
            "(batch_at, station_id, charging_point_id, connector_id, "
            "connector_type, connector_status, charged_kwh, "
            "charged_percent, last_update_time) "
            "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)",
            rows,
        )
        conn.commit()

    logger.info("%s 抓取成功：%d 筆", batch_at, len(rows))

    # 交給 archive 佇列封存原始資料
    archive_raw.delay("live_status", batch_at, response.text)


def save_failed_run(task, batch_at, fetched_at, error):
    """重試 3 次都失敗時，在 fetch_runs 寫入一筆失敗紀錄。"""
    response = getattr(error, "response", None)
    with connect_db() as conn, conn.cursor() as cursor:
        # INSERT IGNORE：如果這個批次已經成功過，就不覆蓋
        cursor.execute(
            "INSERT IGNORE INTO fetch_runs "
            "(batch_at, fetched_at, worker, attempts, http_status, "
            "record_count, error) "
            "VALUES (%s, %s, %s, %s, %s, 0, %s)",
            (
                batch_at,
                fetched_at,
                task.request.hostname,
                task.request.retries + 1,
                response.status_code if response is not None else None,
                repr(error),
            ),
        )
        conn.commit()
    logger.error("%s 抓取失敗：%r", batch_at, error)


# 4. 任務 2：同步充電站、充電樁（佇列 sync）


@app.task(
    autoretry_for=(requests.RequestException,),
    max_retries=3,
    retry_backoff=30,
    retry_jitter=False,
)
def sync_stations():
    """任務 2（佇列 sync，每天 22:00）：同步新竹市充電站、充電樁基本資料。

    有就更新、沒有就新增，再交給 archive 佇列封存原始資料。
    """
    synced_at = now_taipei()

    station_response = tdx_get(f"Station/City/{city}")
    point_response = tdx_get(f"ChargingPoint/City/{city}")

    stations = station_response.json().get("Stations", [])
    points = point_response.json().get("ChargingPoints", [])

    station_rows = []
    for item in stations:
        # 位置資訊有三種：完整地址 Address、只有路名 CityRoad、地標文字 Place
        location = item.get("Location") or {}
        address = location.get("Address") or location.get("CityRoad") or {}
        place = (location.get("Place") or {}).get("POI")
        full_address = "".join(
            str(address.get(key) or "")
            for key in ("City", "Town", "Road", "Lane", "Alley", "No")
        )
        station_rows.append((
            item.get("StationID"),
            item.get("OperatorID"),
            (item.get("StationName") or {}).get("Zh_tw"),
            address.get("Town"),
            full_address or place,
            item.get("PositionLat"),
            item.get("PositionLon"),
            item.get("OperationType"),
            item.get("Spaces"),
            item.get("ChargingPoints"),
            item.get("ServiceTime"),
            item.get("ChargingRate"),
            item.get("ParkingRate"),
            synced_at,
        ))

    point_rows = [
        (
            item.get("StationID"),
            item.get("ChargingPointID"),
            item.get("OperatorID"),
            item.get("Floor"),
            json.dumps(item.get("Connectors"), ensure_ascii=False),
            json.dumps(item.get("Payment"), ensure_ascii=False),
            synced_at,
        )
        for item in points
        if item.get("StationID") and item.get("ChargingPointID")
    ]

    # 有就更新、沒有就新增
    with connect_db() as conn, conn.cursor() as cursor:
        cursor.executemany(
            "INSERT INTO station "
            "(station_id, operator_id, name_zh, town, address, "
            "position_lat, position_lon, operation_type, spaces, "
            "charging_points, service_time, charging_rate, parking_rate, "
            "synced_at) "
            "VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s) "
            "AS new ON DUPLICATE KEY UPDATE "
            "operator_id = new.operator_id, name_zh = new.name_zh, "
            "town = new.town, address = new.address, "
            "position_lat = new.position_lat, "
            "position_lon = new.position_lon, "
            "operation_type = new.operation_type, spaces = new.spaces, "
            "charging_points = new.charging_points, "
            "service_time = new.service_time, "
            "charging_rate = new.charging_rate, "
            "parking_rate = new.parking_rate, synced_at = new.synced_at",
            [row for row in station_rows if row[0]],
        )
        cursor.executemany(
            "INSERT INTO charging_point "
            "(station_id, charging_point_id, operator_id, floor, "
            "connectors, payment, synced_at) "
            "VALUES (%s, %s, %s, %s, %s, %s, %s) "
            "AS new ON DUPLICATE KEY UPDATE "
            "operator_id = new.operator_id, floor = new.floor, "
            "connectors = new.connectors, payment = new.payment, "
            "synced_at = new.synced_at",
            point_rows,
        )
        conn.commit()

    logger.info("同步完成：充電站 %d 筆、充電樁 %d 筆", len(station_rows), len(point_rows))

    batch_at = synced_at.replace(second=0, microsecond=0).isoformat()
    archive_raw.delay("station", batch_at, station_response.text)
    archive_raw.delay("charging_point", batch_at, point_response.text)


# 5. 任務 3：每小時彙總（佇列 aggregate）


@app.task
def aggregate_hourly(hour_start=None):
    """任務 3（佇列 aggregate，每小時第 5 分鐘）：把快照彙總到 connector_hourly_usage。

    沒有指定 hour_start 時，彙總上一個小時；也可以手動指定某個小時重算。
    """
    if hour_start is None:
        current_hour = now_taipei().replace(minute=0, second=0, microsecond=0)
        hour_start = (current_hour - timedelta(hours=1)).isoformat()

    with connect_db() as conn, conn.cursor() as cursor:
        # 先刪掉這個小時的舊結果，再重新計算，重算幾次結果都一樣
        cursor.execute(
            "DELETE FROM connector_hourly_usage WHERE hour_start = %s",
            (hour_start,),
        )
        cursor.execute(
            "INSERT INTO connector_hourly_usage "
            "(hour_start, station_id, charging_point_id, connector_id, "
            "connector_type, samples, available_cnt, occupied_cnt, faulted_cnt) "
            "SELECT %s, station_id, charging_point_id, connector_id, "
            "MAX(connector_type), COUNT(*), "
            "SUM(connector_status = 1), SUM(connector_status = 2), "
            "SUM(connector_status = 3) "
            "FROM connector_status_snapshot "
            "WHERE batch_at >= %s AND batch_at < %s + INTERVAL 1 HOUR "
            "GROUP BY station_id, charging_point_id, connector_id",
            (hour_start, hour_start, hour_start),
        )
        inserted = cursor.rowcount
        conn.commit()

    logger.info("%s 彙總完成：%d 支充電槍", hour_start, inserted)


# 6. 任務 4：清理 6 個月前的快照（佇列 aggregate）


@app.task
def purge_old_snapshots():
    """任務 4（佇列 aggregate，每天 04:00）：刪除 6 個月前的快照。"""
    with connect_db() as conn, conn.cursor() as cursor:
        cursor.execute(
            "DELETE FROM connector_status_snapshot "
            "WHERE batch_at < NOW() - INTERVAL 6 MONTH"
        )
        deleted = cursor.rowcount
        conn.commit()

    logger.info("清理完成：刪除 %d 筆快照", deleted)


# 7. 任務 5：封存原始資料（佇列 archive）


@app.task
def archive_raw(kind, batch_at, raw_text):
    """任務 5（佇列 archive）：把原始 API 回應 gzip 壓縮後存檔。"""
    if archive_target != "local":
        raise NotImplementedError("GCS 封存在階段 4 實作")

    # 例如 /data/archive/live_status/2026/10/18/1410.json.gz
    batch_time = datetime.fromisoformat(batch_at)
    path = (
        archive_dir / kind / batch_time.strftime("%Y/%m/%d")
        / f"{batch_time:%H%M}.json.gz"
    )
    path.parent.mkdir(parents=True, exist_ok=True)

    with gzip.open(path, "wt", encoding="utf-8") as file:
        file.write(raw_text)

    logger.info("封存完成：%s（%d bytes）", path, path.stat().st_size)
