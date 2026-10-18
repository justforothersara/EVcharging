"""
Celery 主設定：連線位址、4 個佇列的路由、Beat 排程

beat 和 4 個 worker 都會載入這個檔案，啟動指令例如：
    celery -A crawler.celery_app beat
    celery -A crawler.celery_app worker -Q collect
"""

import os

from celery import Celery
from celery.schedules import crontab

# 1. 連線設定

# RabbitMQ 的位址由 docker-compose.yml 透過環境變數傳入，
# 格式：amqp://帳號:密碼@rabbitmq:5672//
broker_url = os.environ["CELERY_BROKER_URL"]

app = Celery("crawler", broker=broker_url, include=["crawler.tasks"])

# 2. 基本設定

app.conf.update(
    timezone="Asia/Taipei",
    # 只用 RabbitMQ 傳遞任務，不需要保存任務的回傳值
    task_ignore_result=True,
    # 任務做完才回覆 RabbitMQ；worker 中途掛掉的話，任務會回到佇列
    task_acks_late=True,
    task_reject_on_worker_lost=True,
    # 每個 worker 一次只預先領取 1 個任務
    worker_prefetch_multiplier=1,
    # 啟動時如果 RabbitMQ 還沒準備好，持續重試連線
    broker_connection_retry_on_startup=True,
)

# 3. 佇列路由：每個任務要送到哪個佇列

app.conf.task_routes = {
    "crawler.tasks.collect_live_status": {"queue": "collect"},
    "crawler.tasks.sync_stations": {"queue": "sync"},
    "crawler.tasks.aggregate_hourly": {"queue": "aggregate"},
    "crawler.tasks.purge_old_snapshots": {"queue": "aggregate"},
    "crawler.tasks.archive_raw": {"queue": "archive"},
}

# 4. Beat 排程（archive_raw 不在這裡，它由其他任務完成後送出）

app.conf.beat_schedule = {
    "collect-live-status": {
        "task": "crawler.tasks.collect_live_status",
        "schedule": crontab(minute="*/10"),
        # 9 分鐘內沒有被執行就丟棄，因為下一批馬上就來了
        "options": {"expires": 9 * 60},
    },
    "aggregate-hourly": {
        "task": "crawler.tasks.aggregate_hourly",
        "schedule": crontab(minute=5),
    },
    "sync-stations": {
        "task": "crawler.tasks.sync_stations",
        "schedule": crontab(hour=22, minute=0),
    },
    "purge-old-snapshots": {
        "task": "crawler.tasks.purge_old_snapshots",
        "schedule": crontab(hour=4, minute=0),
    },
}
