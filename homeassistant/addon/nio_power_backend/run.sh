#!/bin/sh
set -e

export PATH=/usr/lib/postgresql/15/bin:$PATH
PGDATA=/data/postgres

opt() {
    jq -r ".$1 // empty" /data/options.json
}

# 选项留空时生成一次随机值并保存在 /data（随 HA 备份），之后重启保持不变。
generated_secret() {
    file="/data/generated/$1"
    if [ ! -s "$file" ]; then
        mkdir -p /data/generated
        head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' > "$file"
        chmod 600 "$file"
    fi
    cat "$file"
}

opt_or_generated() {
    value=$(opt "$1")
    if [ -n "$value" ]; then printf '%s' "$value"; else generated_secret "$1"; fi
}

echo "[INFO] 启动 NIO Power 后端..."

# ---------- PostgreSQL ----------
if [ ! -s "$PGDATA/PG_VERSION" ]; then
    echo "[INFO] 初始化 PostgreSQL 数据目录..."
    mkdir -p "$PGDATA" /data/control
    chown -R postgres:postgres "$PGDATA"
    su postgres -s /bin/sh -c "initdb -D $PGDATA --auth-local=trust --auth-host=trust -U postgres" >/dev/null
fi
chown -R postgres:postgres "$PGDATA"

if ! su postgres -s /bin/sh -c "pg_ctl -D $PGDATA status" >/dev/null 2>&1; then
    echo "[INFO] 启动 PostgreSQL..."
    su postgres -s /bin/sh -c "pg_ctl -D $PGDATA -l $PGDATA/server.log -o '-p 5432 -c listen_addresses=127.0.0.1 -c unix_socket_directories=/tmp' start"
fi

PGPASS=$(opt_or_generated postgres_password)
case "$PGPASS" in
    *"'"*|*'"'*|*\\*) echo "[ERROR] postgres_password 不能包含引号或反斜杠"; exit 1 ;;
esac
PSQL="psql -h 127.0.0.1 -p 5432 -U postgres"
su postgres -s /bin/sh -c "$PSQL -tAc \"SELECT 1 FROM pg_roles WHERE rolname='nio'\" | grep -q 1 || $PSQL -c \"CREATE USER nio WITH PASSWORD '$PGPASS'\""
su postgres -s /bin/sh -c "$PSQL -tAc \"SELECT 1 FROM pg_database WHERE datname='nio_swap_history'\" | grep -q 1 || createdb -h 127.0.0.1 -p 5432 -U postgres -O nio nio_swap_history"

# ---------- 后端环境 ----------
export BIND_ADDR=0.0.0.0:8080
export DATABASE_URL="postgres://nio:$PGPASS@127.0.0.1:5432/nio_swap_history"
# 前端代理与 HA 集成共用这个 Key；留空时自动生成，可在 /data/generated/api_key 查看。
export API_KEY="$(opt_or_generated api_key)"
export NIO_BEARER_TOKEN="$(opt bearer_token)"
export NIO_VEHICLE_ID="$(opt vehicle_id)"
export NIO_DEVICE_ID="$(opt device_id)"
export NIO_ACCOUNT_ID="$(opt account_id)"
# 请求签名按 iOS App 进行
export NIO_APP_ID=10002
export NIO_APP_VERSION="$(opt app_version)"
export NIO_REGION="$(opt region)"
export NIO_LANGUAGE="$(opt language)"
export NIO_SWAP_MODEL_TYPE="$(opt swap_model_type)"
export NIO_SWAP_MODEL_TYPE_YEAR="$(opt swap_model_type_year)"
export NIO_SWAP_TARGET_BATTERY_CAP_LEVEL="$(opt target_battery_cap_level)"
export STATION_URL_TEMPLATE="https://app.nio.com/nio/app/bff/map/resources/v1/swap/{station_id}?region={region}&vehicle_id={vehicle_id}&device_id={device_id}&lang=zh_cn&app_ver={app_version}&app_id={app_id}"
export STATION_TEMPLATE_HEADERS_JSON="{}"
export RUST_LOG=nio_swap_history_backend=info,actix_web=info

# ---------- 车控（可选）----------
CK=$(opt control_api_key)
if [ -n "$CK" ]; then
    mkdir -p /data/control
    opt control_tls_cert > /data/control/tls-certificate.pem
    opt control_tls_key  > /data/control/tls-private-key.pem
    opt control_ca       > /data/control/server-ca.pem
    chmod 600 /data/control/tls-certificate.pem /data/control/tls-private-key.pem
    printf "NIO_VEHICLE_ID=%s\nPIN=%s\n" "$(opt vehicle_id)" "$(opt pin)" > /data/control/pin.env
    chmod 600 /data/control/pin.env
    export NIO_CONTROL_API_KEY="$CK"
    export NIO_CONTROL_TLS_CERT_PATH=/data/control/tls-certificate.pem
    export NIO_CONTROL_TLS_KEY_PATH=/data/control/tls-private-key.pem
    export NIO_CONTROL_CA_PATH=/data/control/server-ca.pem
    export NIO_CONTROL_PIN_FILE=/data/control/pin.env
    echo "[INFO] 车控已启用（PIN 文件就绪）"
else
    echo "[WARNING] 未配置车控 Key，车控功能关闭"
fi

# ---------- 迁移 + 启动 ----------
echo "[INFO] 执行数据库迁移..."
nio-swap-history-backend migrate-db || echo "[WARNING] 迁移失败（可能已是最新）"

echo "[INFO] 启动 Web 前端代理（Ingress :8099）..."
python3 /proxy.py &

echo "[INFO] 启动后端服务..."
exec nio-swap-history-backend
