FROM python:3.13-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_ROOT_USER_ACTION=ignore

WORKDIR /app

# SO deps + bash + dos2unix
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    libpq-dev \
    bash \
    dos2unix \
 && rm -rf /var/lib/apt/lists/*

# Python deps
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# App code
COPY . .

# Normaliza .sh e garante /wait-for-it.sh sem falhar se não existir em scripts/
RUN set -eux; \
    find /app -type f -name '*.sh' -exec dos2unix {} + || true; \
    find /app -type f -name '*.sh' -exec chmod +x {} + || true; \
    if [ -f /app/scripts/wait-for-it.sh ]; then \
      cp /app/scripts/wait-for-it.sh /wait-for-it.sh; \
    else \
      printf '%s\n' \
        '#!/usr/bin/env bash' \
        'set -euo pipefail' \
        'host="${1:-db}"' \
        'port="${2:-5432}"' \
        'echo "[wait] Aguardando ${host}:${port}..."' \
        'until (</dev/tcp/$host/$port) >/dev/null 2>&1; do sleep 0.5; done' \
        'echo "[wait] OK"' \
      > /wait-for-it.sh; \
    fi; \
    dos2unix /wait-for-it.sh; \
    chmod +x /wait-for-it.sh

EXPOSE 8000

CMD ["python", "-m", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
