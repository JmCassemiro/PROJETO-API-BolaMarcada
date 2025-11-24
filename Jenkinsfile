pipeline {
    agent any

  options {
    timestamps()
    buildDiscarder(logRotator(numToKeepStr: '20'))
    disableConcurrentBuilds()
  }

  parameters {
    booleanParam(
      name: 'ENABLE_GH_RELEASE',
      defaultValue: true,
      description: 'Publicar image-<commit>.tar como asset em um Release do GitHub (opcional)'
    )
  }

  environment {
    // DB para testes
    PGUSER = 'postgres'
    PGPASS = 'postgres'
    PGDB   = 'bolamarcadadb'
    PGHOST = 'ci-db'
    PGPORT = '5432'

    // Relatórios/artefatos
    JUNIT_XML    = 'report-junit.xml'
    COVERAGE_XML = 'coverage.xml'
  }

  stages {
    stage('Checkout & Vars') {
      steps {
        checkout scm
        script {
          // commit curto
          env.COMMIT = bat(script: 'git rev-parse --short=8 HEAD', returnStdout: true).trim().readLines().last().trim()

          // branch robusto (evita HEAD em detached)
          def guess = env.BRANCH_NAME ?: env.GIT_BRANCH
          if (!guess || guess.trim() == 'HEAD') {
            def nameRev = bat(script: 'git name-rev --name-only HEAD', returnStdout: true).trim()
            guess = nameRev ?: 'unknown'
          }
          guess = guess.replaceFirst(/^origin\\//, '').replaceFirst(/^remotes\\/origin\\//, '')
          env.BRANCH = guess

          env.IMAGE     = "app:${env.COMMIT}"
          env.IMAGE_TAR = "image-${env.COMMIT}.tar"

          // TAG único por build (evita colar em release antiga)
          env.CI_TAG = "ci-${env.BUILD_NUMBER}-${env.COMMIT}"

          echo "BRANCH=${env.BRANCH}  CI_TAG=${env.CI_TAG}  COMMIT=${env.COMMIT}"
        }
      }
    }

    stage('Build image') {
      steps {
        bat '''
          @echo on
          docker version
          docker build --pull -t %IMAGE% -t app:latest .
        '''
      }
    }

    stage('CI (parallel)') {
      failFast false
      parallel {

        stage('Testes') {
          steps {
            script {
              catchError(buildResult: 'FAILURE', stageResult: 'FAILURE') {
                withCredentials([
                  string(credentialsId: 'app-secret-key',       variable: 'SECRET_KEY'),
                  string(credentialsId: 'access-token-expire', variable: 'ACCESS_TOKEN_EXPIRE_MINUTES')
                ]) {
                  bat """
                    @echo on
                    rem -- rede dedicada
                    docker network create ci_net 2>nul || echo net exists

                    rem -- sobe Postgres
                    docker rm -f ci-db 2>nul
                    docker run -d --name ci-db --network ci_net ^
                      -e POSTGRES_USER=%PGUSER% -e POSTGRES_PASSWORD=%PGPASS% -e POSTGRES_DB=%PGDB% ^
                      -p %PGPORT%:5432 postgres:17-alpine

                    rem -- espera Postgres
                    docker run --rm --network ci_net postgres:17-alpine sh -lc "until pg_isready -h %PGHOST% -p 5432 -U %PGUSER% -d %PGDB%; do sleep 1; done"

                    rem -- roda pytest dentro da SUA imagem
                    docker run --rm --network ci_net ^
                      -e POSTGRES_SERVER=%PGHOST% -e POSTGRES_HOST=%PGHOST% ^
                      -e POSTGRES_USER=%PGUSER% -e POSTGRES_PASSWORD=%PGPASS% -e POSTGRES_DB=%PGDB% ^
                      -e DATABASE_URL=postgresql+psycopg2://%PGUSER%:%PGPASS%@%PGHOST%:5432/%PGDB% ^
                      -e SECRET_KEY=%SECRET_KEY% ^
                      -e ACCESS_TOKEN_EXPIRE_MINUTES=%ACCESS_TOKEN_EXPIRE_MINUTES% ^
                      -e PYTHONPATH=/workspace ^
                      -v "%cd%":/workspace -w /workspace %IMAGE% ^
                      sh -lc "python -m pip install --disable-pip-version-check -U pip && python -m pip install pytest pytest-cov && pytest -vv tests --junit-xml=/workspace/%JUNIT_XML% --cov=/workspace --cov-report=xml:/workspace/%COVERAGE_XML%"

                    set RC=%errorlevel%
                    if %RC%==0 (
                      echo SUCCESS>status_tests.txt
                    ) else (
                      echo FAILURE>status_tests.txt
                      exit /b %RC%
                    )
                  """
                }
              }
            }
          }
          post {
            always {
              junit allowEmptyResults: true, testResults: "${JUNIT_XML}"
              archiveArtifacts allowEmptyArchive: true, artifacts: "${JUNIT_XML}, ${COVERAGE_XML}"
              bat '''
                @echo off
                rem -- cleanup tolerante a erros
                docker rm -f ci-db 1>nul 2>nul || ver > nul
                docker network rm ci_net 1>nul 2>nul || ver > nul
              '''
              script {
                if (!fileExists('status_tests.txt')) {
                  writeFile file: 'status_tests.txt', text: 'FAILURE'
                }
              }
            }
          }
        }

        stage('Empacotamento') {
          steps {
            script {
              catchError(buildResult: 'FAILURE', stageResult: 'FAILURE') {
                bat """
                  @echo on
                  docker save %IMAGE% -o %IMAGE_TAR%
                  set RC=%errorlevel%
                  if %RC%==0 (echo SUCCESS>status_package.txt) else (echo FAILURE>status_package.txt & exit /b %RC%)
                """
              }
            }
        }

        stage('Setup Python Environment') {
            steps {
              echo "🐍 Criando ambiente virtual..."
              sh '''
              if [ -d "$VENV_DIR" ]; then
                  rm -rf $VENV_DIR
              fi

              $PYTHON -m venv $VENV_DIR
              . $VENV_DIR/bin/activate
              python -m pip install --upgrade pip
              '''
            }
        }

        stage('Install Dependencies') {
            steps {
                echo "📚 Instalando dependências..."
                sh '''
                . $VENV_DIR/bin/activate
                ls -l
                cat requirements.txt
                pip cache purge
                pip install --upgrade pip
                pip install psycopg2-binary==2.9.10 --no-cache-dir
                pip install --no-cache-dir -r requirements.txt
                '''
            }
        }

        stage('Run Tests') {
            steps {
                echo "🧪 Executando testes unitários com pytest..."
                withCredentials([
                    usernamePassword(credentialsId: 'pg-db', usernameVariable: 'POSTGRES_USER', passwordVariable: 'POSTGRES_PASSWORD'),
                    string(credentialsId: 'postgres-server', variable: 'POSTGRES_SERVER'),
                    string(credentialsId: 'postgres-dbname', variable: 'POSTGRES_DB'),
                    string(credentialsId: 'app-secret-key', variable: 'SECRET_KEY')
                ]) {
                    sh '''
                    . $VENV_DIR/bin/activate
                    mkdir -p reports
                    pytest tests/ --maxfail=1 --disable-warnings \
                        --junitxml=reports/report.xml \
                        --html=reports/report.html
                    '''
                }
            }
        }

      } // parallel
    }

    stage('Upload GitHub Release (opcional)') {
      when {
        allOf {
          expression { params.ENABLE_GH_RELEASE as boolean }
          // Libera para feat/CI/Docker, feat/CICD/Jenkins, main, master, release/* e test/*
          expression { return env.BRANCH ==~ /(feat\/CI\/Docker|feat\/CICD\/Jenkins|main|master|release\/.+|test\/.+)/ }
        }

        stage('Archive Artifacts') {
            steps {
                echo "📦 Armazenando artefatos do build e relatórios..."
                archiveArtifacts artifacts: 'dist/*.whl, dist/*.tar.gz, tests/**/report*.xml, reports/**/*.html', fingerprint: true
            }
        }

        stage('Create GitHub Release') {
            steps {
                withCredentials([string(credentialsId: 'GITHUB_TOKEN', variable: 'GH_TOKEN')]) {
                    sh """
                    # Cria release usando a API do GitHub via curl
                    curl -X POST -H "Authorization: token \$GH_TOKEN" \
                        -H "Content-Type: application/json" \
                        -d \"{
                            \\\"tag_name\\\": \\\"v\$BUILD_NUMBER\\\",
                            \\\"name\\\": \\\"v\$BUILD_NUMBER\\\",
                            \\\"body\\\": \\\"Build automatizado via Jenkins\\\"
                        }\" \
                        https://api.github.com/repos/C14-2025/API-BolaMarcada/releases
                    """
                }
            }
        }

        stage('Notification'){

            steps {
                echo '📩 Enviando notificação por e-mail...'
                withCredentials([
                    string(credentialsId: 'EMAIL_DESTINO', variable: 'EMAIL_DESTINO'),
                    usernamePassword(credentialsId: 'mailtrap-smtp', usernameVariable: 'USERNAME', passwordVariable: 'PASSWORD')
                ]) {
                    sh '''
                        cd scripts
                        chmod 775 shell.sh
                        ./shell.sh
                    '''
                }
            }
        }

        
    }
  }
}
