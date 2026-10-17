import os

import requests
from dotenv import load_dotenv

# 1. 載入環境變數
load_dotenv()

client_id = os.getenv("TDX_CLIENT_ID")
client_secret = os.getenv("TDX_CLIENT_SECRET")

if not client_id or not client_secret:
    raise ValueError(
        "找不到 TDX_CLIENT_ID 或 TDX_CLIENT_SECRET，"
        "請檢查專案根目錄的 .env"
    )

# 2. 取得 Access Token
token_url = (
    "https://tdx.transportdata.tw/auth/realms/"
    "TDXConnect/protocol/openid-connect/token"
)

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
access_token = token_response.json()["access_token"]

print("Access Token 取得成功！")

# 3. 呼叫指定縣市的充電樁基本資料 API

city = "Hsinchu"

api_url = (
    "https://tdx.transportdata.tw/api/basic"
    f"/v1/EV/ChargingPoint/City/{city}"
)

response = requests.get(
    api_url,
    headers={
        "Authorization": f"Bearer {access_token}",
    },
    params={
        "$top": 1000,
        "$format": "JSON",
    },
    timeout=30,
)

response.raise_for_status()
data = response.json()

print(f"API 回應成功，HTTP 狀態碼：{response.status_code}")
print("回傳資料型態：", type(data).__name__)

# TDX 回應可能是包裝物件，先檢查實際結構
if isinstance(data, dict):
    print("回傳欄位：", list(data.keys()))
    print("完整回應：")
    print(data)
elif isinstance(data, list):
    print(f"取得資料筆數：{len(data)}")
    for index, station in enumerate(data, start=1):
        print(f"\n第 {index} 筆資料：")
        print(station)
else:
    print(data)


# 4. 整理新竹市充電樁資料

charging_points = data.get("ChargingPoints", [])

print(f"查詢縣市：新竹市 ({city})")
print(f"充電樁資料筆數：{len(charging_points)}")

station_ids = {
    point.get("StationID")
    for point in charging_points
    if point.get("StationID")
}

print(f"不同充電站數量：{len(station_ids)}")

print("\n新竹市充電樁資料表")
print("=" * 100)

headers = [
    "序號",
    "StationID",
    "ChargingPointID",
    "OperatorID",
    "Connectors",
    "Floor",
]

rows = []

for index, point in enumerate(charging_points, start=1):
    connectors = point.get("Connectors", [])

    connector_summary = ", ".join(
        f"Type {item.get('Type')} × {item.get('Quantity')}"
        for item in connectors
    )

    rows.append([
        str(index),
        str(point.get("StationID", "")),
        str(point.get("ChargingPointID", "")),
        str(point.get("OperatorID", "")),
        connector_summary,
        str(point.get("Floor", "")),
    ])

# 計算各欄位所需的顯示寬度
widths = [
    max(len(headers[i]), *(len(row[i]) for row in rows))
    for i in range(len(headers))
]

def print_row(row):
    print(" | ".join(
        value.ljust(widths[i])
        for i, value in enumerate(row)
    ))

print_row(headers)
print("-+-".join("-" * width for width in widths))

for row in rows:
    print_row(row)

# 5. 資料品質檢查

from collections import Counter

    # 1. 檢查重複的 ChargingPointID
charging_point_ids = [
    item.get("ChargingPointID")
    for item in charging_points
    if item.get("ChargingPointID")
]

id_counts = Counter(charging_point_ids)

duplicate_ids = {
    point_id: count
    for point_id, count in id_counts.items()
    if count > 1
}

    # 2. 檢查缺少 StationID 的資料
missing_station_id = [
    item for item in charging_points
    if not item.get("StationID")
]

    # 3. 檢查缺少 ChargingPointID 的資料
missing_charging_point_id = [
    item for item in charging_points
    if not item.get("ChargingPointID")
]

    # 4. 統計每個充電站的資料筆數
station_counts = Counter(
    item.get("StationID")
    for item in charging_points
    if item.get("StationID")
)

# 輸出檢查結果
print("\n===== 資料品質檢查 =====")
print(f"總資料筆數：{len(charging_points)}")
print(f"不同充電站數量：{len(station_counts)}")
print(f"不同 ChargingPointID 數量：{len(id_counts)}")
print(f"重複 ChargingPointID 數量：{len(duplicate_ids)}")
print(f"缺少 StationID 的資料：{len(missing_station_id)}")
print(f"缺少 ChargingPointID 的資料：{len(missing_charging_point_id)}")

print("\n===== 充電點紀錄最多的前 10 個充電站 =====")

for station_id, count in station_counts.most_common(10):
    print(f"{station_id}: {count} 筆")

# 6. 取得新竹市充電槍即時狀態

live_status_url = (
    "https://tdx.transportdata.tw/api/basic/v1/"
    "EV/ConnectorLiveStatus/City/Hsinchu"
)

live_params = {
    "$format": "JSON",
    "$top": 1000,
}

live_headers = {
    "Authorization": f"Bearer {access_token}",
}

live_response = requests.get(
    live_status_url,
    headers=live_headers,
    params=live_params,
    timeout=30,
)

print("\n===== 充電槍即時狀態 API =====")
print(f"HTTP 狀態碼：{live_response.status_code}")

live_response.raise_for_status()

live_data = live_response.json()

# 先檢查資料結構，不急著假設欄位名稱
print(f"回傳資料型別：{type(live_data).__name__}")

# 統一取出 live_statuses，不論 API 回傳 dict 或 list
if isinstance(live_data, dict):
    print(f"最外層欄位：{list(live_data.keys())}")
    live_statuses = live_data.get("LiveStatuses", [])
elif isinstance(live_data, list):
    live_statuses = live_data
else:
    live_statuses = []

print(f"充電槍即時狀態筆數：{len(live_statuses)}")

if live_statuses:
    print("\n第一筆即時狀態資料：")
    print(live_statuses[0])

    # 統計各種充電槍狀態的筆數
    status_counts = Counter(
        item.get("ConnectorStatus")
        for item in live_statuses
    )

    print("\n===== 充電槍狀態分布 =====")

    for status, count in sorted(
        status_counts.items(),
        key=lambda item: str(item[0])
    ):
        print(f"狀態 {status}: {count} 支")
else:
    print("\n目前沒有取得即時狀態資料，請檢查實際回傳結構。")

# 7. 充電槍即時狀態資料品質檢查

# 1. 檢查重複的充電槍（ConnectorID 可能只在同一支充電樁內唯一，
#    因此用 StationID + ChargingPointID + ConnectorID 組合鍵判斷）
connector_keys = [
    (
        item.get("StationID"),
        item.get("ChargingPointID"),
        item.get("ConnectorID"),
    )
    for item in live_statuses
    if item.get("ConnectorID")
]

connector_key_counts = Counter(connector_keys)

duplicate_connector_keys = {
    key: count
    for key, count in connector_key_counts.items()
    if count > 1
}

# 2. 檢查缺少 StationID 的資料
missing_live_station_id = [
    item for item in live_statuses
    if not item.get("StationID")
]

# 3. 檢查缺少 ChargingPointID 的資料
missing_live_charging_point_id = [
    item for item in live_statuses
    if not item.get("ChargingPointID")
]

# 4. 檢查缺少 ConnectorID 的資料
missing_connector_id = [
    item for item in live_statuses
    if not item.get("ConnectorID")
]

# 5. 統計每個充電站的即時狀態筆數
live_station_counts = Counter(
    item.get("StationID")
    for item in live_statuses
    if item.get("StationID")
)

# 輸出檢查結果
print("\n===== 充電槍即時狀態資料品質檢查 =====")
print(f"總資料筆數：{len(live_statuses)}")
print(f"不同充電站數量：{len(live_station_counts)}")
print(f"不同充電槍數量（組合鍵）：{len(connector_key_counts)}")
print(f"重複充電槍數量（組合鍵）：{len(duplicate_connector_keys)}")
print(f"缺少 StationID 的資料：{len(missing_live_station_id)}")
print(f"缺少 ChargingPointID 的資料：{len(missing_live_charging_point_id)}")
print(f"缺少 ConnectorID 的資料：{len(missing_connector_id)}")

if duplicate_connector_keys:
    print("\n===== 重複的充電槍（StationID, ChargingPointID, ConnectorID）=====")
    for key, count in duplicate_connector_keys.items():
        print(f"{key}: {count} 筆")

print("\n===== 即時狀態紀錄最多的前 10 個充電站 =====")

for station_id, count in live_station_counts.most_common(10):
    print(f"{station_id}: {count} 筆")
# 8. 充電樁與充電槍資料交叉比對

# 1. 建立充電樁資料的組合鍵，並加總每支充電樁應有的充電槍數量
expected_connector_counts = {}

for point in charging_points:
    key = (point.get("StationID"), point.get("ChargingPointID"))

    total_quantity = 0
    for item in point.get("Connectors", []):
        try:
            total_quantity += int(item.get("Quantity") or 0)
        except (TypeError, ValueError):
            pass

    expected_connector_counts[key] = (
        expected_connector_counts.get(key, 0) + total_quantity
    )

# 2. 統計即時狀態資料中，每支充電樁實際回報的充電槍數量
actual_connector_counts = Counter(
    (item.get("StationID"), item.get("ChargingPointID"))
    for item in live_statuses
)

# 3. 比對兩邊的充電樁組合鍵
point_keys = set(expected_connector_counts)
live_point_keys = set(actual_connector_counts)

only_in_points = point_keys - live_point_keys
only_in_live = live_point_keys - point_keys
matched_keys = point_keys & live_point_keys

# 4. 比對兩邊都有的充電樁，充電槍數量是否一致
quantity_mismatches = {
    key: (expected_connector_counts[key], actual_connector_counts[key])
    for key in matched_keys
    if expected_connector_counts[key] != actual_connector_counts[key]
}

# 輸出比對結果
print("\n===== 充電樁與充電槍資料交叉比對 =====")
print(f"充電樁資料中的充電樁數量：{len(point_keys)}")
print(f"即時狀態資料中的充電樁數量：{len(live_point_keys)}")
print(f"兩邊都有的充電樁數量：{len(matched_keys)}")
print(f"只在充電樁資料出現的數量：{len(only_in_points)}")
print(f"只在即時狀態資料出現的數量：{len(only_in_live)}")
print(f"充電槍數量不一致的充電樁數量：{len(quantity_mismatches)}")

if only_in_points:
    print("\n===== 只在充電樁資料出現（前 10 筆）=====")
    for key in sorted(only_in_points, key=str)[:10]:
        print(f"{key}")

if only_in_live:
    print("\n===== 只在即時狀態資料出現（前 10 筆）=====")
    for key in sorted(only_in_live, key=str)[:10]:
        print(f"{key}")

if quantity_mismatches:
    print("\n===== 充電槍數量不一致（前 10 筆）=====")
    for key, (expected, actual) in sorted(
        quantity_mismatches.items(),
        key=lambda item: str(item[0])
    )[:10]:
        print(f"{key}: 充電樁資料 {expected} 把，即時狀態 {actual} 把")
