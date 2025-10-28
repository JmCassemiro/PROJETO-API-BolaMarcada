pipeline {
  agent any

  options {
    timestamps()
    buildDiscarder(logRotator(numToKeepStr: '20'))
    timeout(time: 45, unit: 'MINUTES')
  }

  parameters {
    booleanParam(name: 'PUBLISH_GHCR', defaultValue: false, description: 'Fazer push da imagem para GHCR (opcional)')
  }

  environment {
    DOCKER_BUILDKIT = '1'
    IMAGE_NAME = 'ci-api'
    IMAGE_TAG  = ''                 // setado no Checkout (fallback no build)
    SMTP_HOST  = 'smtp.mailtrap.io'
    SMTP_PORT  = '2525'
    REPO_SLUG  = 'C14-2025/API-BolaMarcada'  // dono/repositorio no GitHub

    // ===== Credentials (um por variável) =====
    POSTGRES_SERVER = credentials('postgres-server')         // Secret text: db
    POSTGRES_DB     = credentials('postgres-dbname')         // Secret text: bolamarcadadb
    SECRET_KEY      = credentials('app-secret-key')          // Secret text
    ACCESS_TOKEN_EXPIRE_MINUTES = credentials('access-token-expire') // Secret text
    DB = credentials('pg-db') // Username+Password -> cria DB_USR e DB_PSW
  }

  stages {
    stage('Checkout') {
      steps {
        checkout scm
        script {
          if (isUnix()) {
            env.GIT_SHORT = sh(script: 'git rev-parse --short=8 HEAD || echo local', returnStdout: true).trim()
          } else {
            env.GIT_SHORT = powershell(script: '''
$ErrorActionPreference = "Stop"
$git = git rev-parse --short=8 HEAD 2>$null
if ([string]::IsNullOrWhiteSpace($git)) { $git = 'local' }
$git
''', returnStdout: true).trim()
          }
          env.IMAGE_TAG = "${env.BUILD_NUMBER}-${env.GIT_SHORT}"
          echo "[ci] IMAGE_TAG=${env.IMAGE_TAG ?: 'null'}"
        }
      }
    }

    stage('Compose override (CI)') {
      steps {
        script {
          if (isUnix()) {
            sh '''
cat > docker-compose.ci.yml <<'YAML'
services:
  db:
    ports: []     # garante que NADA será publicado
  api:
    env_file: []
    environment:
      SECRET_KEY: ${SECRET_KEY}
      ACCESS_TOKEN_EXPIRE_MINUTES: ${ACCESS_TOKEN_EXPIRE_MINUTES}
      POSTGRES_SERVER: ${POSTGRES_SERVER}
      POSTGRES_HOST: ${POSTGRES_SERVER}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
YAML
'''
          } else {
            powershell '''
$override = @'
services:
  db:
    ports: []
  api:
    env_file: []
    environment:
      SECRET_KEY: ${SECRET_KEY}
      ACCESS_TOKEN_EXPIRE_MINUTES: ${ACCESS_TOKEN_EXPIRE_MINUTES}
      POSTGRES_SERVER: ${POSTGRES_SERVER}
      POSTGRES_HOST: ${POSTGRES_SERVER}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
'@
[System.IO.File]::WriteAllText((Join-Path $Env:WORKSPACE "docker-compose.ci.yml"), $override)
'''
          }
        }
      }
    }

    stage('Testes (pytest)') {
      steps {
        script {
          if (isUnix()) {
            sh '''
set -e
mkdir -p reports artifacts
export COMPOSE_PROJECT_NAME="fastapi-ci-${BUILD_NUMBER}"

# Mapear DB_USR/DB_PSW para nomes esperados pelo compose/app
export POSTGRES_USER="$DB_USR"
export POSTGRES_PASSWORD="$DB_PSW"

compose_cmd="docker compose"
if ! docker compose version >/dev/null 2>&1; then
  if command -v docker-compose >/dev/null 2>&1; then compose_cmd="docker-compose"; fi
fi
echo "Usando: $compose_cmd"

# Alguns projetos definem env_file: .env no compose base. Cria .env vazio p/ evitar erro no CI.
[ -f .env ] || printf "# ci placeholder\n" > .env

dc="docker-compose.yml"
ci="docker-compose.ci.yml"

# Dump do merge para debug (checar se 'ports:' sumiu do db)
$compose_cmd -f "$dc" -f "$ci" config | sed -n '1,200p'

cleanup() { $compose_cmd -f "$dc" -f "$ci" down -v || true; }
trap cleanup EXIT

$compose_cmd -f "$dc" -f "$ci" up -d db

# Espera DB dentro da rede do compose (sem depender de wait-for-it.sh)
# Executa no container da API (tem bash instalado) e só roda os testes quando db:5432 responder
$compose_cmd -f "$dc" -f "$ci" run --rm api bash -lc 'until (</dev/tcp/db/5432) >/dev/null 2>&1; do echo "[ci] aguardando db:5432..."; sleep 0.5; done; tr -d "\\r" < scripts/run_tests.sh > /tmp/run_tests.sh && chmod +x /tmp/run_tests.sh && /tmp/run_tests.sh'
'''
          } else {
            powershell '''
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path "reports"   | Out-Null
New-Item -ItemType Directory -Force -Path "artifacts" | Out-Null
$Env:COMPOSE_PROJECT_NAME = "fastapi-ci-$Env:BUILD_NUMBER"

# Mapeia DB_USR/DB_PSW -> nomes esperados
$Env:POSTGRES_USER     = $Env:DB_USR
$Env:POSTGRES_PASSWORD = $Env:DB_PSW

# Alguns projetos definem env_file: .env no compose base. Cria .env vazio p/ evitar erro no CI.
if (!(Test-Path ".env")) { New-Item -ItemType File -Path ".env" | Out-Null }

$dc  = Join-Path $Env:WORKSPACE 'docker-compose.yml'
$ci  = Join-Path $Env:WORKSPACE 'docker-compose.ci.yml'

# Dump do merge para garantir que 'db' não publica portas
$cfg = & docker compose -f $dc -f $ci config
$cfg | Out-Host

# Sobe somente o db
$upArgs = @('compose','-f', $dc, '-f', $ci, 'up','-d','db')
& docker @upArgs

try {
  # Espera db:5432 de dentro da rede e executa testes
  $cmdStr = @"
until (</dev/tcp/db/5432) >/dev/null 2>&1; do echo '[ci] aguardando db:5432...'; sleep 0.5; done; tr -d '\r' < scripts/run_tests.sh > /tmp/run_tests.sh && chmod +x /tmp/run_tests.sh && /tmp/run_tests.sh
"@
  $runArgs = @('compose','-f', $dc, '-f', $ci, 'run','--rm','api','bash','-lc', $cmdStr)
  & docker @runArgs
}
finally {
  try {
    $downArgs = @('compose','-f', $dc, '-f', $ci, 'down','-v')
    & docker @downArgs
  } catch {
    Write-Warning "Falha ao derrubar serviços: $($_.Exception.Message)"
  }
}
'''
          }
        }
      }
      post {
        always {
          junit allowEmptyResults: true, testResults: 'reports/junit.xml'
          archiveArtifacts artifacts: 'reports/**', allowEmptyArchive: true
        }
      }
    }

    stage('Paralelo: Empacotamento + Notificação') {
      parallel {
        stage('Empacotamento (Docker)') {
          steps {
            script {
              if (isUnix()) {
                sh '''
set -e
mkdir -p artifacts

# Garante .dockerignore para não mandar GB de contexto
touch .dockerignore
for p in artifacts/ reports/ .git/ .venv/ venv/ node_modules/ __pycache__/ *.tar *.zip *.log; do
  grep -qxF "$p" .dockerignore || echo "$p" >> .dockerignore
done

# Se o Dockerfile referir scripts/wait-for-it.sh, garante um stub presente
mkdir -p scripts
if [ ! -f scripts/wait-for-it.sh ]; then
  cat > scripts/wait-for-it.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
host="${1:-db}"
port="${2:-5432}"
echo "[wait] Aguardando ${host}:${port}..."
until (</dev/tcp/$host/$port) >/dev/null 2>&1; do sleep 0.5; done
echo "[wait] OK"
SH
fi

if [ -z "${IMAGE_TAG}" ]; then export IMAGE_TAG="${BUILD_NUMBER}-local"; fi
docker build -t ${IMAGE_NAME}:${IMAGE_TAG} -f Dockerfile .
docker image ls ${IMAGE_NAME}:${IMAGE_TAG}
docker save -o artifacts/${IMAGE_NAME}_${IMAGE_TAG}.tar ${IMAGE_NAME}:${IMAGE_TAG}
'''
              } else {
                powershell '''
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path "artifacts" | Out-Null

# .dockerignore defensivo (evita contexto gigante)
$dockerIgnore = ".dockerignore"
if (!(Test-Path $dockerIgnore)) { New-Item -ItemType File -Path $dockerIgnore | Out-Null }
$patterns = @(
  'artifacts/','reports/','.git/','.venv/','venv/','node_modules/','__pycache__/','*.tar','*.zip','*.log'
)
foreach ($p in $patterns) {
  if (-not (Select-String -Path $dockerIgnore -Pattern "^\Q$p\E$" -SimpleMatch -Quiet)) {
    Add-Content $dockerIgnore $p
  }
}

# Cria scripts/wait-for-it.sh se não existir (para Dockerfile que copia esse arquivo)
if (!(Test-Path 'scripts')) { New-Item -ItemType Directory -Path 'scripts' | Out-Null }
if (!(Test-Path 'scripts/wait-for-it.sh')) {
  $wfi = @"
#!/usr/bin/env bash
set -euo pipefail
host="\${1:-db}"
port="\${2:-5432}"
echo "[wait] Aguardando \${host}:\${port}..."
until (</dev/tcp/\$host/\$port) >/dev/null 2>&1; do sleep 0.5; done
echo "[wait] OK"
"@
  [IO.File]::WriteAllText('scripts/wait-for-it.sh', $wfi, (New-Object System.Text.UTF8Encoding($false)))
}

if ([string]::IsNullOrWhiteSpace($Env:IMAGE_TAG)) { $Env:IMAGE_TAG = "$(($Env:BUILD_NUMBER))-local" }
$tag = "$(($Env:IMAGE_NAME)):$(($Env:IMAGE_TAG))"
$archive = "artifacts/$(($Env:IMAGE_NAME))_$(($Env:IMAGE_TAG)).tar"
docker build -t "$tag" -f Dockerfile .
docker image ls "$tag"
docker save -o "$archive" "$tag"
'''
              }
            }
            archiveArtifacts artifacts: 'artifacts/*.tar', onlyIfSuccessful: true
          }
        }

        stage('Notificação (paralela)') {
          steps {
            withCredentials([
              usernamePassword(credentialsId: 'mailtrap-smtp', usernameVariable: 'SMTP_USER', passwordVariable: 'SMTP_PASS'),
              string(credentialsId: 'EMAIL_TO', variable: 'EMAIL_TO')
            ]) {
              script {
                if (isUnix()) {
                  sh '''
set -e
STATUS="IN_PROGRESS"
REPO="$(git config --get remote.origin.url || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD || echo unknown)"
RUNID="${BUILD_URL:-${JOB_NAME}#${BUILD_NUMBER}}"

# Não derruba o job se Mailtrap rate-limit
set +e
docker run --rm -v "$PWD:/app" -w /app \
  -e SMTP_HOST="${SMTP_HOST}" -e SMTP_PORT="${SMTP_PORT}" \
  -e SMTP_USER="$SMTP_USER" -e SMTP_PASS="$SMTP_PASS" -e EMAIL_TO="$EMAIL_TO" \
  python:3.13-slim python scripts/notify.py \
    --status "$STATUS" --run-id "$RUNID" --repo "$REPO" --branch "$BRANCH"
RET=$?
set -e
[ $RET -eq 0 ] || echo "[warn] Notificação falhou (ignorado)."
'''
                } else {
                  powershell '''
$ErrorActionPreference = "Stop"
$STATUS = "IN_PROGRESS"
$REPO = git config --get remote.origin.url 2>$null; if ([string]::IsNullOrWhiteSpace($REPO)) { $REPO = 'unknown' }
$BRANCH = git rev-parse --abbrev-ref HEAD 2>$null; if ([string]::IsNullOrWhiteSpace($BRANCH)) { $BRANCH = 'unknown' }
$RUNID = if ($Env:BUILD_URL) { $Env:BUILD_URL } else { "${JOB_NAME}#${BUILD_NUMBER}" }

$volume = "$(($Env:WORKSPACE)):/app"
$args = @(
  'run','--rm','-v', $volume,'-w','/app',
  '-e', "SMTP_HOST=$(($Env:SMTP_HOST))",
  '-e', "SMTP_PORT=$(($Env:SMTP_PORT))",
  '-e', "SMTP_USER=$(($Env:SMTP_USER))",
  '-e', "SMTP_PASS=$(($Env:SMTP_PASS))",
  '-e', "EMAIL_TO=$(($Env:EMAIL_TO))",
  'python:3.13-slim',
  'python','scripts/notify.py',
  '--status', $STATUS,
  '--run-id', $RUNID,
  '--repo', $REPO,
  '--branch', $BRANCH
)
try {
  & docker @args
} catch {
  Write-Warning "Falha ao enviar email (ignorado): $($_.Exception.Message)"
}
'''
                }
              }
            }
          }
        }
      }
    }

    // ===== Publicar artefatos no GitHub (Release sem depender do GHCR) =====
    stage('Publicar artefatos no GitHub') {
      steps {
        script { env.CI_STATUS = env.CI_STATUS ?: (currentBuild.currentResult ?: 'IN_PROGRESS') }

        withCredentials([usernamePassword(credentialsId: 'github-pat', usernameVariable: 'GH_USER', passwordVariable: 'GH_PAT')]) {
          script {
            if (isUnix()) {
              // LINUX: deixa como estava (robusto). Windows já está validado abaixo.
              sh '''
set -euo pipefail
TAG="build-${BUILD_NUMBER}-${GIT_SHORT}"

# build-info.txt
{
  echo "status=${CI_STATUS}"
  echo "image=${IMAGE_NAME}:${IMAGE_TAG}"
  echo "repo=${REPO_SLUG}"
  echo "commit=${GIT_SHORT}"
  echo "run=${BUILD_URL:-${JOB_NAME}#${BUILD_NUMBER}}"
} > build-info.txt

AUTH="Authorization: Bearer ${GH_PAT}"
UA="User-Agent: jenkins-ci"
AC="Accept: application/vnd.github+json"

API_BASE="https://api.github.com/repos/${REPO_SLUG}/releases"

set +e
curl -sfSL -H "$AUTH" -H "$AC" -H "$UA" -X POST -d "{\"tag_name\":\"${TAG}\",\"name\":\"Build ${BUILD_NUMBER} (${GIT_SHORT})\",\"body\":\"Artefatos do Jenkins. Imagem Docker (.tar) anexada.\",\"draft\":false,\"prerelease\":false}" "$API_BASE" >/dev/null
set -e

curl -sfSL -H "$AUTH" -H "$AC" -H "$UA" "$API_BASE/tags/${TAG}" > release.json

REL_ID=$(python3 - <<'PY'
import json; print(json.load(open("release.json","r",encoding="utf-8")).get("id",""))
PY
)
UPLOAD_BASE=$(python3 - <<'PY'
import json
j=json.load(open("release.json","r",encoding="utf-8"))
u=(j.get("upload_url") or "").split("{")[0].strip()
if not u:
  a=(j.get("assets_url") or "").strip()
  if a.startswith("https://api.github.com"):
    u=a.replace("https://api.github.com","https://uploads.github.com")
print(u)
PY
)

[ -n "$REL_ID" ] && [ -n "$UPLOAD_BASE" ] || { echo "Falha ao obter upload_url"; cat release.json; exit 1; }
case "$UPLOAD_BASE" in https://uploads.github.com/*) ;; *) echo "upload_base inválido: $UPLOAD_BASE"; exit 1;; esac
echo "Upload base: $UPLOAD_BASE"

urlencode() { python3 - "$1" <<'PY'
import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))
PY
}

upload_one() {
  f="$1"; [ -e "$f" ] || { echo "WARN: ausente: $f"; return 0; }
  name="$(basename "$f")"; enc="$(urlencode "$name")"
  curl -sfSL -X POST -H "$AUTH" -H "Content-Type: application/octet-stream" -H "$UA" \
    --data-binary @"$f" "${UPLOAD_BASE}?name=${enc}" >/dev/null
  echo "Enviado: $name"
}
upload_one reports/junit.xml
upload_one build-info.txt
for f in artifacts/*.tar; do upload_one "$f"; done
'''
            } else {
              // ===== WINDOWS: robusto com validação + URL-encode + remoção de duplicados =====
              powershell '''
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Web

$TAG   = "build-$($Env:BUILD_NUMBER)-$($Env:GIT_SHORT)"
$api   = "https://api.github.com/repos/$($Env:REPO_SLUG)/releases"

# build-info.txt
$lines = @(
  "status=$($Env:CI_STATUS)",
  "image=$($Env:IMAGE_NAME):$($Env:IMAGE_TAG)",
  "repo=$($Env:REPO_SLUG)",
  "commit=$($Env:GIT_SHORT)",
  "run=$($Env:BUILD_URL)"
)
[IO.File]::WriteAllLines((Join-Path $Env:WORKSPACE 'build-info.txt'), $lines)

$Headers = @{
  Authorization = "Bearer $($Env:GH_PAT)"
  Accept        = "application/vnd.github+json"
  "User-Agent"  = "jenkins-ci"
}

# 1) Tenta criar a release (idempotente)
$body = @{
  tag_name   = $TAG
  name       = "Build $($Env:BUILD_NUMBER) ($($Env:GIT_SHORT))"
  body       = "Artefatos do Jenkins. Imagem Docker (.tar) anexada."
  draft      = $false
  prerelease = $false
} | ConvertTo-Json

try {
  Invoke-RestMethod -Method Post -Uri $api -Headers $Headers -ContentType 'application/json' -Body $body | Out-Null
} catch {
  if ($_.Exception.Response -and ($_.Exception.Response.StatusCode.Value__ -in  @([int]422,[int]409))) {
    Write-Host "Release já existia; prosseguindo."
  } else { throw }
}

# 2) Busca sempre por TAG
$res = Invoke-RestMethod -Method Get -Uri "$api/tags/$TAG" -Headers $Headers
if (-not $res) { throw "Falha ao recuperar release por tag." }

# 3) upload_base
$uploadBase = $null
if ($res.upload_url) {
  $uploadBase = $res.upload_url.ToString().Split('{')[0].Trim()
} elseif ($res.assets_url) {
  $uploadBase = $res.assets_url.ToString().Replace('https://api.github.com','https://uploads.github.com').Trim()
}
if ([string]::IsNullOrWhiteSpace($uploadBase)) { throw "GitHub release sem upload_url/assets_url" }
$uriObj = $null
if (-not [Uri]::TryCreate($uploadBase, [UriKind]::Absolute, [ref]$uriObj)) { throw "uploadBase inválido: '$uploadBase'" }
Write-Host ("Upload base: " + $uploadBase)

# 4) Monta lista de arquivos
$files = New-Object System.Collections.ArrayList
foreach ($p in @('reports/junit.xml','build-info.txt')) {
  $full = Join-Path $Env:WORKSPACE $p
  if (Test-Path $full) { [void]$files.Add($full) }
}
$tarFiles = Get-ChildItem -Path (Join-Path $Env:WORKSPACE 'artifacts') -Filter *.tar -ErrorAction SilentlyContinue
if ($tarFiles) { foreach ($t in $tarFiles) { [void]$files.Add($t.FullName) } }

# 5) Id da release e assets
$relId = $res.id
$assetsUrl = "https://api.github.com/repos/$($Env:REPO_SLUG)/releases/$relId/assets"

# 6) Upload (remove duplicado se existir)
foreach ($f in $files) {
  $name = [IO.Path]::GetFileName($f)
  $encoded = [System.Web.HttpUtility]::UrlEncode($name)

  try {
    $assets = Invoke-RestMethod -Method Get -Uri $assetsUrl -Headers $Headers
    $match = $assets | Where-Object { $_.name -eq $name }
    if ($match) {
      Write-Host "Removendo asset existente '$name' (id=$($match.id))..."
      Invoke-RestMethod -Method Delete -Uri ("https://api.github.com/repos/$($Env:REPO_SLUG)/releases/assets/{0}" -f $match.id) -Headers $Headers | Out-Null
    }
  } catch {
    Write-Warning "Falha ao listar/remover asset antigo: $($_.Exception.Message)"
  }

  $uri = "$uploadBase?name=$encoded"
  Invoke-RestMethod -Method Post -Uri $uri -Headers @{ Authorization = $Headers.Authorization; "Content-Type" = "application/octet-stream"; "User-Agent" = "jenkins-ci" } -InFile $f | Out-Null
  Write-Host "Enviado: $name"
}
'''
            }
          }
        }

        // 2) Push da imagem para GHCR (Opcional)
        script {
          if (params.PUBLISH_GHCR) {
            withCredentials([usernamePassword(credentialsId: 'ghcr-cred', usernameVariable: 'GHCR_USER', passwordVariable: 'GHCR_TOKEN')]) {
              if (isUnix()) {
                sh '''
set -e
OWNER="${REPO_SLUG%%/*}"
echo "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USER" --password-stdin
TARGET="ghcr.io/${OWNER}/ci-api:${IMAGE_TAG}"
docker tag ${IMAGE_NAME}:${IMAGE_TAG} "$TARGET"
docker push "$TARGET"
'''
              } else {
                powershell '''
$ErrorActionPreference = "Stop"
$OWNER  = $Env:REPO_SLUG.Split('/')[0]
$TARGET = "ghcr.io/$OWNER/ci-api:$($Env:IMAGE_TAG)"
$Env:GHCR_TOKEN | docker login ghcr.io -u $Env:GHCR_USER --password-stdin | Out-Null
docker tag "$(($Env:IMAGE_NAME)):$(($Env:IMAGE_TAG))" $TARGET
docker push $TARGET
'''
              }
            }
          } else {
            echo 'PUBLISH_GHCR=false — ignorando push para GHCR.'
          }
        }
      }
    }
  }

  post {
    always {
      script { env.CI_STATUS = currentBuild.currentResult ?: 'UNKNOWN' }

      withCredentials([
        usernamePassword(credentialsId: 'mailtrap-smtp', usernameVariable: 'SMTP_USER', passwordVariable: 'SMTP_PASS'),
        string(credentialsId: 'EMAIL_TO', variable: 'EMAIL_TO')
      ]) {
        script {
          if (isUnix()) {
            sh '''
set -e
STATUS="${CI_STATUS}"
REPO="$(git config --get remote.origin.url || echo unknown)"
BRANCH="$(git rev-parse --abbrev-ref HEAD || echo unknown)"
RUNID="${BUILD_URL:-${JOB_NAME}#${BUILD_NUMBER}}"

set +e
docker run --rm -v "$PWD:/app" -w /app \
  -e SMTP_HOST="${SMTP_HOST}" -e SMTP_PORT="${SMTP_PORT}" \
  -e SMTP_USER="$SMTP_USER" -e SMTP_PASS="$SMTP_PASS" -e EMAIL_TO="$EMAIL_TO" \
  python:3.13-slim python scripts/notify.py \
    --status "$STATUS" --run-id "$RUNID" --repo "$REPO" --branch "$BRANCH"
RET=$?
set -e
[ $RET -eq 0 ] || echo "[warn] Notificação pós-build falhou (ignorado)."
'''
          } else {
            powershell '''
$ErrorActionPreference = "Stop"
$STATUS = if ($Env:CI_STATUS) { $Env:CI_STATUS } else { "UNKNOWN" }
$REPO = git config --get remote.origin.url 2>$null; if ([string]::IsNullOrWhiteSpace($REPO)) { $REPO = 'unknown' }
$BRANCH = git rev-parse --abbrev-ref HEAD 2>$null; if ([string]::IsNullOrWhiteSpace($BRANCH)) { $BRANCH = 'unknown' }
$RUNID = if ($Env:BUILD_URL) { $Env:BUILD_URL } else { "${JOB_NAME}#${BUILD_NUMBER}" }

$volume = "$(($Env:WORKSPACE)):/app"
$args = @(
  'run','--rm','-v', $volume,'-w','/app',
  '-e', "SMTP_HOST=$(($Env:SMTP_HOST))",
  '-e', "SMTP_PORT=$(($Env:SMTP_PORT))",
  '-e', "SMTP_USER=$(($Env:SMTP_USER))",
  '-e', "SMTP_PASS=$(($Env:SMTP_PASS))",
  '-e', "EMAIL_TO=$(($Env:EMAIL_TO))",
  'python:3.13-slim',
  'python','scripts/notify.py',
  '--status', $STATUS,
  '--run-id', $RUNID,
  '--repo', $REPO,
  '--branch', $BRANCH
)
try {
  & docker @args
} catch {
  Write-Warning "Falha ao enviar email (ignorado): $($_.Exception.Message)"
}
'''
          }
        }
      }

      script {
        if (isUnix()) {
          sh 'docker system prune -f || true'
        } else {
          powershell '''
$ErrorActionPreference = "SilentlyContinue"
try { docker system prune -f | Out-Null } catch { Write-Warning "Falha ao limpar docker: $($_.Exception.Message)" }
'''
        }
      }
    }
  }
}
