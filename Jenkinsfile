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

cleanup() { $compose_cmd -f docker-compose.yml -f docker-compose.ci.yml down -v || true; }
trap cleanup EXIT

$compose_cmd -f docker-compose.yml -f docker-compose.ci.yml up -d db

# Normaliza CRLF sem sed -i (evita erro de rename no FS montado)
$compose_cmd -f docker-compose.yml -f docker-compose.ci.yml run --rm api bash -lc 'tr -d "\r" < scripts/run_tests.sh > /tmp/run_tests.sh && chmod +x /tmp/run_tests.sh && /tmp/run_tests.sh'
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

$upArgs = @('compose','-f', $dc, '-f', $ci, 'up','-d','db')
& docker @upArgs

try {
  $cmdStr = "tr -d '\r' < scripts/run_tests.sh > /tmp/run_tests.sh && chmod +x /tmp/run_tests.sh && /tmp/run_tests.sh"
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

    // ====== Paralelo exigido (Empacotamento + Notificação) ======
    stage('Paralelo: Empacotamento + Notificação') {
      parallel {
        stage('Empacotamento (Docker)') {
          steps {
            script {
              if (isUnix()) {
                sh '''
set -e
mkdir -p artifacts
if [ -z "${IMAGE_TAG}" ]; then export IMAGE_TAG="${BUILD_NUMBER}-local"; fi
docker build -t ${IMAGE_NAME}:${IMAGE_TAG} -f Dockerfile .
docker image ls ${IMAGE_NAME}:${IMAGE_TAG}
docker save -o artifacts/${IMAGE_NAME}_${IMAGE_TAG}.tar ${IMAGE_NAME}:${IMAGE_TAG}
'''
              } else {
                powershell '''
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path "artifacts" | Out-Null
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

docker run --rm -v "$PWD:/app" -w /app \
  -e SMTP_HOST="${SMTP_HOST}" -e SMTP_PORT="${SMTP_PORT}" \
  -e SMTP_USER="$SMTP_USER" -e SMTP_PASS="$SMTP_PASS" -e EMAIL_TO="$EMAIL_TO" \
  python:3.13-slim python scripts/notify.py \
    --status "$STATUS" --run-id "$RUNID" --repo "$REPO" --branch "$BRANCH"
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
& docker @args
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

        // 1) Release com junit.xml + build-info.txt (+ artifacts/*.tar se existir)
        withCredentials([usernamePassword(credentialsId: 'github-pat', usernameVariable: 'GH_USER', passwordVariable: 'GH_PAT')]) {
          script {
            if (isUnix()) {
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

API="https://api.github.com/repos/${REPO_SLUG}/releases"
AUTH="Authorization: Bearer ${GH_PAT}"
UA="User-Agent: jenkins-ci"

# Cria a release (se já existir, pega pela tag)
CREATE_PAYLOAD=$(cat <<JSON
{"tag_name":"${TAG}","name":"Build ${BUILD_NUMBER} (${GIT_SHORT})",
 "body":"Artefatos do Jenkins. Imagem Docker (.tar) anexada.",
 "draft":false,"prerelease":false}
JSON
)

set +e
RES=$(curl -sfSL -H "$AUTH" -H "Accept: application/vnd.github+json" -H "$UA" \
  -X POST -d "$CREATE_PAYLOAD" "$API")
RC=$?
set -e

if [ $RC -ne 0 ] || [ "$(printf '%s' "$RES" | tr -d '\\n' | grep -c '"upload_url"')" -eq 0 ]; then
  RES=$(curl -sfSL -H "$AUTH" -H "Accept: application/vnd.github+json" -H "$UA" \
    "$API/tags/${TAG}")
fi

# <<< FIX: usar ERE no sed (evita \(\))
UPLOAD_BASE=$(printf '%s' "$RES" | sed -E -n 's/.*"upload_url"[[:space:]]*:[[:space:]]*"([^"]*)".*/\\1/p' | sed 's/{.*}//')
if [ -z "$UPLOAD_BASE" ]; then
  echo "Falha ao obter upload_url da release:"
  echo "$RES"
  exit 1
fi

upload() {
  local f="$1"
  [ -e "$f" ] || { echo "WARN: arquivo ausente: $f"; return 0; }
  local name; name=$(basename "$f")
  curl -sfSL -H "$AUTH" -H "$UA" -H "Content-Type: application/octet-stream" \
    --data-binary @"$f" "${UPLOAD_BASE}?name=${name}" >/dev/null
  echo "Enviado: $name"
}

upload reports/junit.xml
upload build-info.txt
for f in artifacts/*.tar; do upload "$f"; done
'''
            } else {
              // Windows: API REST nativa (sem gh CLI/containers)
              powershell '''
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.Web

$TAG   = "build-$($Env:BUILD_NUMBER)-$($Env:GIT_SHORT)"
$api   = "https://api.github.com/repos/$($Env:REPO_SLUG)/releases"

# build-info.txt
$lines = @(
  "status=$($Env:CI_STATUS))",
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

# cria ou obtém release
$body = @{
  tag_name   = $TAG
  name       = "Build $($Env:BUILD_NUMBER) ($($Env:GIT_SHORT))"
  body       = "Artefatos do Jenkins. Imagem Docker (.tar) anexada."
  draft      = $false
  prerelease = $false
} | ConvertTo-Json

try {
  $res = Invoke-RestMethod -Method Post -Uri $api -Headers $Headers -ContentType 'application/json' -Body $body
} catch {
  if ($_.Exception.Response.StatusCode.Value__ -eq 422) {
    $res = Invoke-RestMethod -Method Get -Uri "$api/tags/$TAG" -Headers $Headers
  } else { throw }
}

# upload_url
$uploadBase = $null
if ($res.upload_url) {
  $uploadBase = $res.upload_url.Split('{')[0]
} elseif ($res.assets_url) {
  $uploadBase = $res.assets_url.Replace('https://api.github.com','https://uploads.github.com')
} else { throw "GitHub release response sem upload_url/assets_url" }

# lista de arquivos para enviar
$files = New-Object System.Collections.ArrayList
foreach ($p in @('reports/junit.xml','build-info.txt')) {
  $full = Join-Path $Env:WORKSPACE $p
  if (Test-Path $full) { [void]$files.Add($full) }
}
$tarFiles = Get-ChildItem -Path (Join-Path $Env:WORKSPACE 'artifacts') -Filter *.tar -ErrorAction SilentlyContinue
if ($tarFiles) { foreach ($t in $tarFiles) { [void]$files.Add($t.FullName) } }

foreach ($f in $files) {
  $name = [IO.Path]::GetFileName($f)
  $encoded = [System.Web.HttpUtility]::UrlEncode($name)
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
      // status final disponível para shells
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

docker run --rm -v "$PWD:/app" -w /app \
  -e SMTP_HOST="${SMTP_HOST}" -e SMTP_PORT="${SMTP_PORT}" \
  -e SMTP_USER="$SMTP_USER" -e SMTP_PASS="$SMTP_PASS" -e EMAIL_TO="$EMAIL_TO" \
  python:3.13-slim python scripts/notify.py \
    --status "$STATUS" --run-id "$RUNID" --repo "$REPO" --branch "$BRANCH"
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
& docker @args
'''
          }
        }
      }

      // limpeza do docker
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
