#!/bin/sh
set -e

CONFIG_FILE="${APP_HOME}/config.yaml"

# Priority 1: Use USERNAME/PASSWORD if both are provided
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
  enablePrefix: false
ollama:
  keepAlive: -1
  batchSize: -1
claude:
  enableSystemPromptCache: false
  cachingAtDepth: -1
enableServerPlugins: true
enableServerPluginsAutoUpdate: false
EOT

# Priority 2: Use CONFIG_YAML if provided (and username/password are not)
elif [ -n "${CONFIG_YAML}" ]; then
  echo "--- Found CONFIG_YAML, creating config.yaml from environment variable. ---"
  printf '%s\n' "${CONFIG_YAML}" > ${CONFIG_FILE}

# Priority 3: No config provided, let the app use its defaults
else
    echo "--- No user/pass or CONFIG_YAML provided. App will use its default settings. ---"
fi

# --- BEGIN: Update SillyTavern Core at Runtime ---
echo '--- Attempting to update SillyTavern Core from GitHub (staging branch) ---'
if [ -d ".git" ] && [ "$(git rev-parse --abbrev-ref HEAD)" = "staging" ]; then
  echo 'Existing staging branch found. Resetting and pulling latest changes...'
  git reset --hard HEAD && \
  git pull origin staging || echo 'WARN: git pull failed, continuing with code from build time.'
  echo '--- SillyTavern Core update check finished. ---'
else
  echo 'WARN: .git directory not found or not on staging branch. Skipping runtime update. Code from build time will be used.'
fi
# --- END: Update SillyTavern Core at Runtime ---

# --- BEGIN: Configure Git default identity at Runtime ---
echo '--- Configuring Git default user identity at runtime ---'
git config --global user.name "SillyTavern Sync" && \
git config --global user.email "sillytavern-sync@example.com" && \
git config --global --add safe.directory "${APP_HOME}/data"
echo '--- Git identity configured for runtime user. ---'
# --- END: Configure Git default identity at Runtime ---

# --- BEGIN: Auto-Restore Data from Backup ---
if [ -n "${REPO_URL}" ] && [ -n "${GITHUB_TOKEN}" ]; then
  echo "--- Checking for existing backup data in $REPO_URL ---"
  AUTH_REPO=$(echo "${REPO_URL}" | sed "s/https:\/\//https:\/\/x-access-token:${GITHUB_TOKEN}@/")
  
  # التأكد من أن مجلد البيانات لا يحتوي على محادثات سابقة قبل السحب
  if [ ! -d "${APP_HOME}/data/default-user/chats" ] || [ -z "$(ls -A ${APP_HOME}/data/default-user/chats 2>/dev/null)" ]; then
    echo "Data directory is empty or fresh. Restoring from backup repository..."
    mkdir -p ${APP_HOME}/temp_restore
    if git clone --depth 1 "${AUTH_REPO}" ${APP_HOME}/temp_restore; then
      cp -rn ${APP_HOME}/temp_restore/* ${APP_HOME}/data/ 2>/dev/null || true
      rm -rf ${APP_HOME}/temp_restore
      echo "--- Restore from backup finished successfully. ---"
    else
      echo "WARN: Failed to clone backup. Moving on with fresh data."
      rm -rf ${APP_HOME}/temp_restore
    fi
  else
    echo "Existing data detected in /data, skipping auto-restore to prevent overwrite."
  fi
fi
# --- END: Auto-Restore Data from Backup ---

# --- BEGIN: Dynamically Install Plugins at Runtime ---
echo '--- Checking for PLUGINS environment variable ---'
if [ -n "$PLUGINS" ]; then
  echo "*** Installing Plugins specified in PLUGINS environment variable: $PLUGINS ***"
  mkdir -p ./plugins && chown node:node ./plugins
  IFS=','
  for plugin_url in $PLUGINS; do
    plugin_url=$(echo "$plugin_url" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [ -z "$plugin_url" ]; then continue; fi
    plugin_name_git=$(basename "$plugin_url")
    plugin_name=${plugin_name_git%.git}
    plugin_dir="./plugins/$plugin_name"
    echo "--- Installing plugin: $plugin_name from $plugin_url into $plugin_dir ---"
    rm -rf "$plugin_dir"
    git clone --depth 1 "$plugin_url" "$plugin_dir"
    if [ -f "$plugin_dir/package.json" ]; then
      echo "--- Installing dependencies for $plugin_name ---"
      (cd "$plugin_dir" && npm install --no-audit --no-fund --loglevel=error --no-progress --omit=dev --force && npm cache clean --force) || echo "WARN: Failed to install dependencies for $plugin_name"
    else
       echo "--- No package.json found for $plugin_name, skipping dependency install. ---"
    fi || echo "WARN: Failed to clone $plugin_name from $plugin_url, skipping..."
    
    if [ "$plugin_name" = "cloud-saves" ]; then
      echo "--- Detected cloud-saves plugin, configuring... ---"
      REPO_URL_VALUE=${REPO_URL:-"https://github.com/fuwei99/sillytravern"}
      GITHUB_TOKEN_VALUE=${GITHUB_TOKEN:-""}
      AUTOSAVE_INTERVAL_VALUE=${AUTOSAVE_INTERVAL:-10}
      AUTOSAVE_TARGET_TAG_VALUE=${AUTOSAVE_TARGET_TAG:-"MySave"}
      
      AUTOSAVE_ENABLED="true"
      
      CONFIG_JSON_FILE="$plugin_dir/config.json"
      cat <<EOT > ${CONFIG_JSON_FILE}
{
  "repo_url": "${REPO_URL_VALUE}",
  "branch": "main",
  "username": "cloud-saves",
  "github_token": "${GITHUB_TOKEN_VALUE}",
  "display_name": "",
  "is_authorized": true,
  "last_save": null,
  "current_save": null,
  "has_temp_stash": false,
  "autoSaveEnabled": ${AUTOSAVE_ENABLED},
  "autoSaveInterval": ${AUTOSAVE_INTERVAL_VALUE},
  "autoSaveTargetTag": "${AUTOSAVE_TARGET_TAG_VALUE}"
}
EOT
      chown node:node ${CONFIG_JSON_FILE}
      echo "--- cloud-saves plugin configuration file created. ---"
    fi
  done
  unset IFS
  echo "--- Setting permissions for plugins directory ---"
  chown -R node:node ./plugins
  echo "*** Plugin installation finished. ***"
else
  echo 'PLUGINS environment variable is empty, skipping.'
fi
# --- END: Dynamically Install Plugins at Runtime ---

echo "*** Starting SillyTavern... ***"
node ${APP_HOME}/server.js &
SERVER_PID=$!

echo "SillyTavern server started with PID ${SERVER_PID}."

HEALTH_CHECK_URL="http://localhost:8000/"
CURL_COMMAND="curl -sf"
if [ -n "${USERNAME}" ] && [ -n "${PASSWORD}" ]; then
    CURL_COMMAND="curl -sf -u \"${USERNAME}:${PASSWORD}\""
fi

RETRY_COUNT=0
MAX_RETRIES=12 
while ! eval "${CURL_COMMAND} ${HEALTH_CHECK_URL}" > /dev/null; do
    RETRY_COUNT=$((RETRY_COUNT+1))
    if [ ${RETRY_COUNT} -ge ${MAX_RETRIES} ]; then
        echo "SillyTavern failed to start. Exiting."
        kill ${SERVER_PID}
        exit 1
    fi
    echo "SillyTavern is still starting, waiting 5 seconds..."
    sleep 5
done

echo "SillyTavern started successfully!"

# --- BEGIN: Install Extensions after SillyTavern startup ---
install_extensions() {
    echo "--- Waiting 40 seconds before installing extensions... ---"
    sleep 40
    if [ -n "$EXTENSIONS" ]; then
        echo "*** Installing Extensions... ***"
        if [ "$INSTALL_FOR_ALL_USERS" = "true" ]; then
            EXTENSIONS_DIR="./public/scripts/extensions/third-party"
        else
            EXTENSIONS_DIR="./data/default-user/extensions"
        fi
        mkdir -p "$EXTENSIONS_DIR" && chown node:node "$EXTENSIONS_DIR"
        IFS=','
        for extension_url in $EXTENSIONS; do
            extension_url=$(echo "$extension_url" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            if [ -z "$extension_url" ]; then continue; fi
            extension_name_git=$(basename "$extension_url")
            extension_name=${extension_name_git%.git}
            extension_dir="$EXTENSIONS_DIR/$extension_name"
            echo "--- Installing extension: $extension_name ---"
            rm -rf "$extension_dir"
            git clone --depth 1 "$extension_url" "$extension_dir"
            if [ -f "$extension_dir/package.json" ]; then
                (cd "$extension_dir" && npm install --no-audit --no-fund --loglevel=error --no-progress --omit=dev --force && npm cache clean --force)
            fi
        done
        unset IFS
        chown -R node:node "$EXTENSIONS_DIR"
        echo "*** Extensions installation finished. ***"
    fi
}
install_extensions &
# --- END: Install Extensions after SillyTavern startup ---

while kill -0 ${SERVER_PID} 2>/dev/null; do
    eval "${CURL_COMMAND} ${HEALTH_CHECK_URL}" > /dev/null || echo "Keep-alive failed."
    sleep 1800
done &

wait ${SERVER_PID}
