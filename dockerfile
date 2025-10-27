FROM python:3.13-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

# deps do SO + bash + dos2unix (bash é necessário pro wait-for-it clássico)
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    libpq-dev \
    bash \
    dos2unix \
 && rm -rf /var/lib/apt/lists/*

# dependências Python
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# código do projeto (seu repo na raiz do host será montado em /app no runtime)
COPY . .

# normaliza todos os .sh do projeto e cria uma cópia "blindada" do wait-for-it
RUN find /app -type f -name "*.sh" -print0 | xargs -0 dos2unix || true \
 && find /app -type f -name "*.sh" -print0 | xargs -0 chmod +x || true \
 && cp /app/scripts/wait-for-it.sh /wait-for-it.sh \
 && dos2unix /wait-for-it.sh && chmod +x /wait-for-it.sh

EXPOSE 8000

# keep it simple
CMD ["python", "-m", "uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000"]
