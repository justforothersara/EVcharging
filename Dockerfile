# 新竹市充電站數據分析平台：beat 和 4 個 worker 共用這個映像檔
FROM python:3.12-slim

# 從 uv 官方映像檔複製 uv 執行檔，版本和你本機的一致（0.9.18）
COPY --from=ghcr.io/astral-sh/uv:0.9.18 /uv /bin/uv

WORKDIR /app

ENV PYTHONUNBUFFERED=1 \
    UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    TZ=Asia/Taipei

# 1. 先複製套件清單並安裝套件
#    只要套件沒變，這一層就能重複使用，重新建置時會快很多
COPY pyproject.toml uv.lock ./
RUN uv sync --frozen --no-dev --no-install-project

# 2. 再複製程式碼
COPY src ./src

ENV PATH="/app/.venv/bin:$PATH" \
    PYTHONPATH=/app/src

# 3. 建立一般使用者執行程式，不使用 root
RUN useradd --create-home appuser \
    && mkdir -p /data/archive \
    && chown appuser /data/archive
USER appuser

# 預設啟動 worker；docker-compose.yml 會依服務指定不同的啟動指令
CMD ["celery", "-A", "crawler.celery_app", "worker", "--loglevel=INFO"]
