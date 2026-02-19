#!/bin/sh
set -e

CONFIG_FILE="${APP_HOME}/config.yaml"

# 1. إعداد ملف الإعدادات الأساسي
if [ -n "${USERNAME}" ] && [ -n "${PASSWORD}" ]; then
  echo "--- Basic auth enabled: Creating config.yaml with provided credentials. ---"
  cat <<EOT > ${CONFIG_FILE}
dataRoot: ./data
listen: true
listenAddress:
  ipv4: 0.0.0.0
  ipv6: '[::]'
protocol:
    ipv4: true
    ipv6: false
dnsPreferIPv6: false
autorunHostname: "auto"
port: 8000
autorunPortOverride: -1
ssl:
  enabled: false
  certPath: "./certs/cert.pem"
  keyPath: "./certs/privkey.pem"
whitelistMode: false
enableForwardedWhitelist: false
whitelist:
  - ::1
  - 127.0.0.1
whitelistDockerHosts: true
basicAuthMode: true
basicAuthUser:
  username: "${USERNAME}"
  password: "${PASSWORD}"
enableCorsProxy: false
requestProxy:
  enabled: false
  url: "socks5://username:password@example.com:1080"
  bypass:
    - localhost
    - 127.0.0.1
enableUserAccounts: false
enableDiscreetLogin: false
autheliaAuth: false
perUserBasicAuth: false
sessionTimeout: -1
disableCsrfProtection: false
securityOverride: false
logging:
  enableAccessLog: true
  minLogLevel: 0
rateLimiting:
  preferRealIpHeader: false
autorun: false
avoidLocalhost: false
backups:
  common:
    numberOfBackups: 50
  chat:
    enabled: true
    checkIntegrity: true
    maxTotalBackups: -1
    throttleInterval: 10000
thumbnails:
  enabled: true
  format: "jpg"
  quality: 95
  dimensions: { 'bg': [160, 90], 'avatar': [96, 144] }
performance:
  lazyLoadCharacters: false
  memoryCacheCapacity: '100mb'
  useDiskCache: true
allowKeysExposure: true
skipContentCheck: false
whitelistImportDomains:
  - localhost
  - cdn.discordapp.com
  - files.catbox.moe
  - raw.githubusercontent.com
requestOverrides: []
extensions:
  enabled: true
  autoUpdate: false
  models:
    autoDownload: true
    classification: Cohee/distilbert-base-uncased-go-emotions-onnx
    captioning: Xenova/vit-gpt2-image-captioning
    embedding: Cohee/jina-embeddings-v2-base-en
    speechToText: Xenova/whisper-small
    textToSpeech: Xenova/speecht5_tts
enableDownloadableTokenizers: true
promptPlaceholder: "[Start a new chat]"
openai:
  randomizeUserId: false
  captionSystemPrompt: ""
deepl:
  formality: default
mistral:
  enabledPrefix: false
ollama:
  keepAlive: -1
  batchSize: -1
claude:
  enableSystemPromptCache: false
  cachingAtDepth: -1
enableServerPlugins: true
enableServerPluginsAutoUpdate: false
EOT
elif [ -n "${CONFIG_YAML}" ]; then
  echo "--- Found CONFIG_YAML, creating config.yaml from environment variable. ---"
  printf '%s\n' "${CONFIG_YAML}" > ${CONFIG_FILE}
else
    echo "--- No user/pass or CONFIG_YAML provided. App will use its default settings. ---"
fi

# 2. تحديث SillyTavern لأحدث نسخة (Staging) عند التشغيل
echo '--- Updating SillyTavern Core (Staging Branch) ---'
if [ -d ".git" ]; then
  git reset --hard HEAD && git pull origin staging || echo 'WARN: Update failed.'
fi

# 3. إعداد هوية Git (ضرورية لعملية المزامنة)
git config --global user.name "SillyTavern Sync"
git config --global user.email "sillytavern-sync@example.com"
git config --global --add safe.directory "${APP_HOME}/data"

# 4. النظام الجديد: استعادة البيانات تلقائياً من الـ Backup
if [ -n "${REPO_URL}" ] && [ -n "${GITHUB_TOKEN}" ]; then
  echo "--- [RESTORE] Checking backup repository... ---"
  AUTH_REPO=$(echo "${REPO_URL}" | sed "s/https:\/\//https:\/\/x-access-token:${GITHUB_TOKEN}@/")
  
  # إذا لم يجد مجلد المحادثات، يقوم بالسحب فوراً
  if [ ! -d "${APP_HOME}/data/default-user/chats" ] || [ -z "$(ls -A ${APP_HOME}/data/default-user/chats 2>/dev/null)" ]; then
    echo "--- [RESTORE] Chats not found locally. Cloning from GitHub... ---"
    mkdir -p ${APP_HOME}/temp_restore
    if git clone --depth 1 "${AUTH_REPO}" ${APP_HOME}/temp_restore; then
      cp -rf ${APP_HOME}/temp_restore/* ${APP_HOME}/data/ 2>/dev/null || true
      rm -rf ${APP_HOME}/temp_restore
      chown -R node:node ${APP_HOME}/data
      echo "--- [RESTORE] Data successfully restored! ---"
    fi
  else
    echo "--- [RESTORE] Existing data detected, skipping restore to prevent overwrite. ---"
  fi
fi

# 5. تثبيت الإضافات (Plugins) وإعداد الخزن السحابي
if [ -n "$PLUGINS" ]; then
  echo "*** Installing Plugins: $PLUGINS ***"
  mkdir -p ./plugins && chown node:node ./plugins
  IFS=','
  for plugin_url in $PLUGINS; do
    plugin_url=$(echo "$plugin_url" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [ -z "$plugin_url" ]; then continue; fi
    plugin_name_git=$(basename "$plugin_url")
    plugin_name=${plugin_name_git%.git}
    plugin_dir="./plugins/$plugin_name"
    
    echo "--- Installing $plugin_name ---"
    rm -rf "$plugin_dir"
    git clone --depth 1 "$plugin_url" "$plugin_dir"
    
    # إعداد إضافة الخزن السحابي تلقائياً
    if [ "$plugin_name" = "cloud-saves" ]; then
      AUTOSAVE_TARGET_TAG_VALUE=${AUTOSAVE_TARGET_TAG:-"MySave"} # تم تثبيته على MySave لحل مشكلة الـ refspec
      cat <<EOT > "$plugin_dir/config.json"
{
  "repo_url": "${REPO_URL}",
  "branch": "main",
  "username": "cloud-saves",
  "github_token": "${GITHUB_TOKEN}",
  "is_authorized": true,
  "autoSaveEnabled": true,
  "autoSaveInterval": ${AUTOSAVE_INTERVAL:-10},
  "autoSaveTargetTag": "${AUTOSAVE_TARGET_TAG_VALUE}"
}
EOT
      chown node:node "$plugin_dir/config.json"
    fi
  done
  unset IFS
  chown -R node:node ./plugins
fi

# 6. تشغيل السيرفر
echo "*** Starting SillyTavern Server... ***"
node ${APP_HOME}/server.js &
SERVER_PID=$!

# 7. فحص الجاهزية (Health Check)
RETRY_COUNT=0
while ! curl -sf http://localhost:8000/ > /dev/null; do
    RETRY_COUNT=$((RETRY_COUNT+1))
    [ ${RETRY_COUNT} -ge 12 ] && exit 1
    echo "Waiting for server (Attempt $RETRY_COUNT)..."
    sleep 5
done

echo "SillyTavern is LIVE!"

# 8. تثبيت الإضافات (Extensions) في الخلفية بعد التشغيل
(
  sleep 40
  if [ -n "$EXTENSIONS" ]; then
    EXTENSIONS_DIR="./data/default-user/extensions"
    mkdir -p "$EXTENSIONS_DIR"
    IFS=','
    for ext in $EXTENSIONS; do
      ext=$(echo "$ext" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
      ext_name=$(basename "$ext" .git)
      echo "--- Installing Extension: $ext_name ---"
      rm -rf "$EXTENSIONS_DIR/$ext_name"
      git clone --depth 1 "$ext" "$EXTENSIONS_DIR/$ext_name"
    done
    unset IFS
    chown -R node:node "$EXTENSIONS_DIR"
  fi
) &

wait ${SERVER_PID}
