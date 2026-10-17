"""
＃9 定時抓取充電槍即時狀態並存入 SQLite

呼叫 TDX ConnectorLiveStatus API（新竹市），預設每 10 分鐘抓一次，
共 144 次（24 小時），抓取紀錄與充電槍狀態分別存入 data/ev_live_status.db：
- fetch_runs：每次抓取的紀錄（時間、HTTP 狀態、筆數、錯誤訊息）
- connector_live_status：每次抓取中每支充電槍的狀態與原始 JSON
- .gitignore 排除 data/，資料庫不進版控
用法：
    uv run python src/collect_live_status.py
    uv run python src/collect_live_status.py --interval 10 --runs 2  # 快速測試
"""

import argparse
import json
import os
import sqlite3
import time
from datetime import datetime
from pathlib import Path

import requests
from dotenv import load_dotenv

# 1. 基本設定

city = "Hsinchu"

token_url = (
    "https://tdx.transportdata.tw/auth/realms/"
    "TDXConnect/protocol/openid-connect/token"
)

live_status_url = (
    "https://tdx.transportdata.tw/api/basic/v1/"
    f"EV/ConnectorLiveStatus/City/{city}"
)

# 資料庫放在專案根目錄的 data/ 底下
db_path = Path(__file__).resolve().parent.parent / "data" / "ev_live_status.db"

# 預設每 10 分鐘抓一次，抓一天（24 小時 × 6 次 = 144 次）
parser = argparse.ArgumentParser(description="定時抓取充電槍即時狀態並存入 SQLite")
parser.add_argument("--interval", type=int, default=600, help="每次抓取間隔秒數")
parser.add_argument("--runs", type=int, default=144, help="總共抓取次數")
args = parser.parse_args()

# 2. 載入環境變數

load_dotenv()

client_id = os.getenv("TDX_CLIENT_ID")
client_secret = os.getenv("TDX_CLIENT_SECRET")

if not client_id or not client_secret:
    raise ValueError(
        "找不到 TDX_CLIENT_ID 或 TDX_CLIENT_SECRET，"
        "請檢查專案根目錄的 .env"
    )

# 3. 建立資料庫與資料表

db_path.parent.mkdir(parents=True, exist_ok=True)
conn = sqlite3.connect(db_path)

conn.executescript("""
CREATE TABLE IF NOT EXISTS fetch_runs (
    run_id        INTEGER PRIMARY KEY AUTOINCREMENT,
    fetched_at    TEXT NOT NULL,
    http_status   INTEGER,
    record_count  INTEGER,
    response_bytes INTEGER,
    error         TEXT
);

CREATE TABLE IF NOT EXISTS connector_live_status (
    run_id           INTEGER NOT NULL REFERENCES fetch_runs(run_id),
    fetched_at       TEXT NOT NULL,
    station_id       TEXT,
    charging_point_id TEXT,
    connector_id     TEXT,
    connector_status TEXT,
    raw_json         TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_live_status_connector
    ON connector_live_status (station_id, charging_point_id, connector_id);
""")
conn.commit()

# 4. 定義單次抓取流程


def get_access_token():
    # 每次抓取都重新取得 Token，避免跑一整天時 Token 過期
    token_response = requests.post(
        token_url,
        data={
            "grant_type": "client_credentials",
            "client_id": client_id,
            "client_secret": client_secret,
        },
        timeout=30,
    )
    token_response.raise_for_status()
    return token_response.json()["access_token"]


def fetch_once():
    fetched_at = datetime.now().isoformat(timespec="seconds")
    http_status = None
    response_bytes = None

    try:
        access_token = get_access_token()

        live_response = requests.get(
            live_status_url,
            headers={
                "Authorization": f"Bearer {access_token}",
            },
            params={
                "$format": "JSON",
                "$top": 1000,
            },
            timeout=30,
        )

        http_status = live_response.status_code
        response_bytes = len(live_response.content)
        live_response.raise_for_status()

        live_data = live_response.json()

        # 統一取出 live_statuses，不論 API 回傳 dict 或 list
        if isinstance(live_data, dict):
            live_statuses = live_data.get("LiveStatuses", [])
        elif isinstance(live_data, list):
            live_statuses = live_data
        else:
            live_statuses = []

    except Exception as error:
        # 單次失敗只記錄下來，不中斷整天的抓取
        conn.execute(
            "INSERT INTO fetch_runs "
            "(fetched_at, http_status, record_count, response_bytes, error) "
            "VALUES (?, ?, ?, ?, ?)",
            (fetched_at, http_status, 0, response_bytes, repr(error)),
        )
        conn.commit()
        print(f"[{fetched_at}] 抓取失敗：{error!r}")
        return

    cursor = conn.execute(
        "INSERT INTO fetch_runs "
        "(fetched_at, http_status, record_count, response_bytes, error) "
        "VALUES (?, ?, ?, ?, NULL)",
        (fetched_at, http_status, len(live_statuses), response_bytes),
    )
    run_id = cursor.lastrowid

    conn.executemany(
        "INSERT INTO connector_live_status "
        "(run_id, fetched_at, station_id, charging_point_id, "
        "connector_id, connector_status, raw_json) "
        "VALUES (?, ?, ?, ?, ?, ?, ?)",
        [
            (
                run_id,
                fetched_at,
                item.get("StationID"),
                item.get("ChargingPointID"),
                item.get("ConnectorID"),
                str(item.get("ConnectorStatus")),
                json.dumps(item, ensure_ascii=False),
            )
            for item in live_statuses
        ],
    )
    conn.commit()

    print(
        f"[{fetched_at}] 第 {run_id} 次抓取成功："
        f"{len(live_statuses)} 筆，{response_bytes:,} bytes"
    )

    # 筆數剛好等於 $top 時，資料可能被截斷
    if len(live_statuses) == 1000:
        print("  ⚠ 筆數剛好 1000 筆，資料可能被 $top 截斷")


# 5. 依固定間隔重複抓取

print(f"開始抓取：每 {args.interval} 秒一次，共 {args.runs} 次")
print(f"資料庫位置：{db_path}")

start_time = time.monotonic()

for run_index in range(args.runs):
    fetch_once()

    if run_index == args.runs - 1:
        break

    # 以開始時間計算下一次抓取時間，避免每次執行耗時累積造成時間漂移
    next_time = start_time + (run_index + 1) * args.interval
    time.sleep(max(0, next_time - time.monotonic()))

# 6. 輸出資料量統計

run_count, success_count, total_records, total_bytes = conn.execute(
    "SELECT COUNT(*), COUNT(*) - COUNT(error), "
    "COALESCE(SUM(record_count), 0), COALESCE(SUM(response_bytes), 0) "
    "FROM fetch_runs"
).fetchone()

conn.close()

print("\n===== 抓取結果統計（資料庫累計）=====")
print(f"抓取次數：{run_count}")
print(f"成功次數：{success_count}")
print(f"累計資料筆數：{total_records:,}")
print(f"累計 API 回應大小：{total_bytes / 1024 / 1024:.2f} MB")
print(f"資料庫檔案大小：{db_path.stat().st_size / 1024 / 1024:.2f} MB")
