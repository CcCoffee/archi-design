#!/bin/bash

#######################################
# Redis Cluster 生产环境部署脚本
# 用途: 在生产服务器上部署 Redis Cluster 节点
# 使用: ./deploy-production.sh [命令] [选项]
# 注意: 此脚本需要在每台服务器上单独执行
#######################################

set -e

# 获取脚本目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# 加载公共函数
source "${SCRIPT_DIR}/common/utils.sh"

# 加载环境配置
source "${SCRIPT_DIR}/env/production.env"

# 当前服务器配置 (部署时需要设置)
export CURRENT_SERVER_IP=""
export CURRENT_SERVER_ROLE=""  # master 或 slave
export CURRENT_SERVER_DC=""     # DC-A 或 DC-B
export CURRENT_NODE_PORT=6379

#######################################
# 显示帮助信息
#######################################
show_help() {
    cat << EOF
Redis Cluster 生产环境部署脚本

用法: $0 <命令> [选项]

命令:
    init        初始化服务器环境
    install     安装 Redis
    config      生成配置文件
    start       启动 Redis 服务
    stop        停止 Redis 服务
    restart     重启 Redis 服务
    status      查看服务状态
    join        加入集群
    backup      备份数据
    restore     恢复数据
    upgrade     升级 Redis 版本
    help        显示帮助信息

选项:
    --ip        当前服务器 IP 地址
    --role      节点角色 (master/slave)
    --dc        数据中心 (DC-A/DC-B)
    --port      Redis 端口 (默认: 6379)
    --password  集群密码

示例:
    $0 init --ip 10.1.1.1 --role master --dc DC-A
    $0 install
    $0 config --password your_password
    $0 start
    $0 join --master 10.1.1.1:6379

EOF
}

#######################################
# 解析命令行参数
#######################################
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --ip)
                CURRENT_SERVER_IP="$2"
                shift 2
                ;;
            --role)
                CURRENT_SERVER_ROLE="$2"
                shift 2
                ;;
            --dc)
                CURRENT_SERVER_DC="$2"
                shift 2
                ;;
            --port)
                CURRENT_NODE_PORT="$2"
                shift 2
                ;;
            --password)
                CLUSTER_PASSWORD="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done
}

#######################################
# 初始化服务器环境
#######################################
init_server() {
    print_title "初始化服务器环境"
    
    # 检查是否以 root 运行
    if [ "$EUID" -ne 0 ]; then
        warn "建议使用 root 用户运行此脚本"
    fi
    
    log "INFO" "服务器 IP: ${CURRENT_SERVER_IP:-未设置}"
    log "INFO" "节点角色: ${CURRENT_SERVER_ROLE:-未设置}"
    log "INFO" "数据中心: ${CURRENT_SERVER_DC:-未设置}"
    
    # 创建用户和组
    if ! id redis &>/dev/null; then
        log "INFO" "创建 redis 用户和组..."
        groupadd -r redis 2>/dev/null || true
        useradd -r -g redis -s /sbin/nologin redis 2>/dev/null || true
    fi
    
    # 创建目录
    log "INFO" "创建目录结构..."
    ensure_dir "$REDIS_BASE_DIR"
    ensure_dir "$REDIS_DATA_DIR"
    ensure_dir "$REDIS_LOG_DIR"
    ensure_dir "$REDIS_CONF_DIR"
    ensure_dir "$REDIS_PID_DIR"
    ensure_dir "${BACKUP_DIR:-/opt/redis-cluster/backups}"
    
    # 设置权限
    chown -R redis:redis "$REDIS_BASE_DIR"
    chmod 750 "$REDIS_BASE_DIR"
    
    # 配置系统参数
    log "INFO" "配置系统参数..."
    
    # 关闭 THP (Transparent Huge Pages)
    if [ -f /sys/kernel/mm/transparent_hugepage/enabled ]; then
        echo never > /sys/kernel/mm/transparent_hugepage/enabled
        echo never > /sys/kernel/mm/transparent_hugepage/defrag
    fi
    
    # 配置 sysctl
    cat >> /etc/sysctl.conf << EOF

# Redis 优化参数
vm.overcommit_memory = 1
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_sack = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.tcp_max_tw_buckets = 720000
net.core.wmem_max = 16777216
net.core.rmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
EOF
    
    sysctl -p &>/dev/null || true
    
    # 配置文件描述符限制
    cat > /etc/security/limits.d/redis.conf << EOF
redis soft nofile 65535
redis hard nofile 65535
redis soft nproc 65535
redis hard nproc 65535
EOF
    
    # 创建 systemd 服务文件
    create_systemd_service
    
    success "服务器环境初始化完成"
}

#######################################
# 创建 systemd 服务文件
#######################################
create_systemd_service() {
    local service_file="/etc/systemd/system/redis-cluster.service"
    
    log "INFO" "创建 systemd 服务文件..."
    
    cat > "$service_file" << EOF
[Unit]
Description=Redis Cluster Node
After=network.target

[Service]
Type=forking
ExecStart=/usr/local/bin/redis-server ${REDIS_CONF_DIR}/redis.conf
ExecStop=/usr/local/bin/redis-cli -p ${CURRENT_NODE_PORT} shutdown
Restart=always
RestartSec=5
User=redis
Group=redis
LimitNOFILE=65535
LimitNPROC=65535

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable redis-cluster
}

#######################################
# 安装 Redis
#######################################
install_redis() {
    print_title "安装 Redis"
    
    local redis_version="${1:-7.0.11}"
    local install_dir="/usr/local"
    local src_dir="/tmp/redis-src"
    
    # 检查是否已安装
    if check_command "redis-server"; then
        local current_version=$(get_redis_version)
        warn "Redis 已安装 (版本: $current_version)"
        if ! confirm "是否重新安装?"; then
            return 0
        fi
    fi
    
    # 安装依赖
    log "INFO" "安装编译依赖..."
    if check_command "yum"; then
        yum install -y gcc make tcl wget
    elif check_command "apt-get"; then
        apt-get update
        apt-get install -y gcc make tcl wget
    fi
    
    # 下载源码
    log "INFO" "下载 Redis ${redis_version}..."
    rm -rf "$src_dir"
    mkdir -p "$src_dir"
    cd "$src_dir"
    
    wget "https://download.redis.io/releases/redis-${redis_version}.tar.gz"
    tar xzf "redis-${redis_version}.tar.gz"
    cd "redis-${redis_version}"
    
    # 编译安装
    log "INFO" "编译 Redis..."
    make -j$(nproc)
    make test
    
    log "INFO" "安装 Redis..."
    make install PREFIX="$install_dir"
    
    # 创建软链接
    ln -sf "${install_dir}/bin/redis-server" /usr/local/bin/redis-server
    ln -sf "${install_dir}/bin/redis-cli" /usr/local/bin/redis-cli
    ln -sf "${install_dir}/bin/redis-benchmark" /usr/local/bin/redis-benchmark
    ln -sf "${install_dir}/bin/redis-check-aof" /usr/local/bin/redis-check-aof
    ln -sf "${install_dir}/bin/redis-check-rdb" /usr/local/bin/redis-check-rdb
    
    # 清理
    cd /
    rm -rf "$src_dir"
    
    # 验证安装
    local installed_version=$(get_redis_version)
    success "Redis ${installed_version} 安装完成"
}

#######################################
# 生成生产环境配置文件
#######################################
generate_production_config() {
    print_title "生成 Redis 配置文件"
    
    if [ -z "$CURRENT_SERVER_IP" ]; then
        error_exit "请指定服务器 IP: --ip <IP地址>"
    fi
    
    local config_file="${REDIS_CONF_DIR}/redis.conf"
    local cluster_config_file="${REDIS_CONF_DIR}/nodes.conf"
    
    log "INFO" "生成配置文件: $config_file"
    
    # 备份现有配置
    [ -f "$config_file" ] && backup_file "$config_file"
    
    cat > "$config_file" << EOF
# Redis Cluster 生产环境配置
# 服务器: ${CURRENT_SERVER_IP}
# 角色: ${CURRENT_SERVER_ROLE:-未指定}
# 数据中心: ${CURRENT_SERVER_DC:-未指定}
# 生成时间: $(date)

# ==================== 网络配置 ====================
bind 0.0.0.0
port ${CURRENT_NODE_PORT}
protected-mode yes
tcp-backlog 511
timeout ${REDIS_TIMEOUT}
tcp-keepalive ${REDIS_TCP_KEEPALIVE}

# ==================== 通用配置 ====================
daemonize yes
supervised systemd
pidfile ${REDIS_PID_DIR}/redis-${CURRENT_NODE_PORT}.pid
loglevel ${REDIS_LOGLEVEL}
logfile ${REDIS_LOG_DIR}/redis-${CURRENT_NODE_PORT}.log
databases 16

# ==================== 内存配置 ====================
maxmemory ${REDIS_MAXMEMORY}
maxmemory-policy ${REDIS_MAXMEMORY_POLICY}
maxmemory-samples 5

# ==================== 持久化配置 - RDB ====================
save 900 1
save 300 10
save 60 10000
stop-writes-on-bgsave-error yes
rdbcompression yes
rdbchecksum yes
dbfilename dump-${CURRENT_NODE_PORT}.rdb
dir ${REDIS_DATA_DIR}

# ==================== 持久化配置 - AOF ====================
appendonly ${APPENDONLY}
appendfilename "appendonly-${CURRENT_NODE_PORT}.aof"
appendfsync ${APPENDFSYNC}
no-appendfsync-on-rewrite no
auto-aof-rewrite-percentage ${AUTO_AOF_REWRITE_PERCENTAGE}
auto-aof-rewrite-min-size ${AUTO_AOF_REWRITE_MIN_SIZE}
aof-load-truncated yes
aof-use-rdb-preamble yes

# ==================== 集群配置 ====================
cluster-enabled yes
cluster-config-file ${cluster_config_file}
cluster-node-timeout ${CLUSTER_NODE_TIMEOUT}
cluster-slave-validity-factor ${CLUSTER_SLAVE_VALIDITY_FACTOR}
cluster-migration-barrier ${CLUSTER_MIGRATION_BARRIER}
cluster-require-full-coverage ${CLUSTER_REQUIRE_FULL_COVERAGE}
cluster-announce-ip ${CURRENT_SERVER_IP}
cluster-announce-port ${CURRENT_NODE_PORT}
cluster-announce-bus-port $((CURRENT_NODE_PORT + 10000))

# ==================== 复制配置 ====================
replica-serve-stale-data ${REPLICA_SERVE_STALE_DATA}
replica-read-only ${REPLICA_READ_ONLY}
repl-diskless-sync no
repl-diskless-sync-delay 5
repl-disable-tcp-nodelay no
repl-backlog-size 64mb
repl-backlog-ttl 3600
replica-priority ${REPLICA_PRIORITY}

# ==================== 安全配置 ====================
EOF

    # 添加密码配置
    if [ -n "$CLUSTER_PASSWORD" ]; then
        cat >> "$config_file" << EOF
requirepass ${CLUSTER_PASSWORD}
masterauth ${CLUSTER_PASSWORD}
EOF
    fi

    cat >> "$config_file" << EOF

# ==================== 慢查询日志 ====================
slowlog-log-slower-than 10000
slowlog-max-len 128

# ==================== 客户端配置 ====================
maxclients 10000

# ==================== 事件通知 ====================
notify-keyspace-events ""

# ==================== 高级配置 ====================
hz 10
dynamic-hz yes
aof-rewrite-incremental-fsync yes
rdb-save-incremental-fsync yes
EOF

    # 设置权限
    chown redis:redis "$config_file"
    chmod 640 "$config_file"
    
    success "配置文件生成完成"
}

#######################################
# 启动 Redis 服务
#######################################
start_redis() {
    print_title "启动 Redis 服务"
    
    local config_file="${REDIS_CONF_DIR}/redis.conf"
    
    if [ ! -f "$config_file" ]; then
        error_exit "配置文件不存在，请先运行: $0 config"
    fi
    
    # 检查服务状态
    if systemctl is-active --quiet redis-cluster; then
        warn "Redis 服务已在运行"
        return 0
    fi
    
    log "INFO" "启动 Redis 服务..."
    systemctl start redis-cluster
    
    sleep 2
    
    if systemctl is-active --quiet redis-cluster; then
        success "Redis 服务启动成功"
        show_status
    else
        error_exit "Redis 服务启动失败"
    fi
}

#######################################
# 停止 Redis 服务
#######################################
stop_redis() {
    print_title "停止 Redis 服务"
    
    if ! systemctl is-active --quiet redis-cluster; then
        warn "Redis 服务未运行"
        return 0
    fi
    
    log "INFO" "停止 Redis 服务..."
    systemctl stop redis-cluster
    
    success "Redis 服务已停止"
}

#######################################
# 显示服务状态
#######################################
show_status() {
    print_title "Redis 服务状态"
    
    echo ""
    info "服务状态:"
    systemctl status redis-cluster --no-pager || true
    
    echo ""
    info "Redis 信息:"
    
    if [ -n "$CLUSTER_PASSWORD" ]; then
        redis-cli -p $CURRENT_NODE_PORT -a "$CLUSTER_PASSWORD" --no-auth-warning INFO server | head -20
    else
        redis-cli -p $CURRENT_NODE_PORT INFO server | head -20
    fi
    
    echo ""
    info "集群状态:"
    
    if [ -n "$CLUSTER_PASSWORD" ]; then
        redis-cli -p $CURRENT_NODE_PORT -a "$CLUSTER_PASSWORD" --no-auth-warning CLUSTER INFO
    else
        redis-cli -p $CURRENT_NODE_PORT CLUSTER INFO
    fi
}

#######################################
# 加入集群
# Arguments:
#   $1 - 主节点地址 (格式: ip:port)
#######################################
join_cluster() {
    local master_addr=$1
    
    if [ -z "$master_addr" ]; then
        error_exit "请指定要加入的主节点: --master <ip:port>"
    fi
    
    print_title "加入 Redis Cluster"
    
    local master_ip=$(echo $master_addr | cut -d: -f1)
    local master_port=$(echo $master_addr | cut -d: -f2)
    
    log "INFO" "当前节点: ${CURRENT_SERVER_IP}:${CURRENT_NODE_PORT}"
    log "INFO" "目标主节点: ${master_addr}"
    
    # 加入集群作为从节点
    if [ -n "$CLUSTER_PASSWORD" ]; then
        redis-cli --cluster add-node \
            ${CURRENT_SERVER_IP}:${CURRENT_NODE_PORT} \
            ${master_addr} \
            --cluster-slave \
            -a "$CLUSTER_PASSWORD" --no-auth-warning
    else
        redis-cli --cluster add-node \
            ${CURRENT_SERVER_IP}:${CURRENT_NODE_PORT} \
            ${master_addr} \
            --cluster-slave
    fi
    
    if [ $? -eq 0 ]; then
        success "成功加入集群"
    else
        error_exit "加入集群失败"
    fi
}

#######################################
# 备份数据
#######################################
backup_data() {
    print_title "备份 Redis 数据"
    
    local backup_dir="${BACKUP_DIR:-/opt/redis-cluster/backups}"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_path="${backup_dir}/${timestamp}"
    
    ensure_dir "$backup_path"
    
    log "INFO" "触发 RDB 快照..."
    
    if [ -n "$CLUSTER_PASSWORD" ]; then
        redis-cli -p $CURRENT_NODE_PORT -a "$CLUSTER_PASSWORD" --no-auth-warning BGSAVE
    else
        redis-cli -p $CURRENT_NODE_PORT BGSAVE
    fi
    
    # 等待备份完成
    local count=0
    while [ $count -lt 60 ]; do
        local bgsave_status
        if [ -n "$CLUSTER_PASSWORD" ]; then
            bgsave_status=$(redis-cli -p $CURRENT_NODE_PORT -a "$CLUSTER_PASSWORD" --no-auth-warning LASTSAVE)
        else
            bgsave_status=$(redis-cli -p $CURRENT_NODE_PORT LASTSAVE)
        fi
        
        sleep 1
        ((count++))
    done
    
    # 复制备份文件
    log "INFO" "复制备份文件..."
    cp "${REDIS_DATA_DIR}/dump-${CURRENT_NODE_PORT}.rdb" "${backup_path}/dump.rdb"
    cp "${REDIS_DATA_DIR}/appendonly-${CURRENT_NODE_PORT}.aof" "${backup_path}/appendonly.aof" 2>/dev/null || true
    cp "${REDIS_CONF_DIR}/redis.conf" "${backup_path}/redis.conf"
    
    # 压缩备份
    cd "$backup_dir"
    tar czf "${timestamp}.tar.gz" "$timestamp"
    rm -rf "$timestamp"
    
    # 清理旧备份
    find "$backup_dir" -name "*.tar.gz" -mtime +${BACKUP_RETENTION_DAYS:-7} -delete
    
    success "备份完成: ${backup_dir}/${timestamp}.tar.gz"
}

#######################################
# 主函数
#######################################
main() {
    local command=${1:-help}
    shift || true
    
    parse_args "$@"
    
    case $command in
        init)
            init_server
            ;;
        install)
            install_redis "$@"
            ;;
        config)
            generate_production_config
            ;;
        start)
            start_redis
            ;;
        stop)
            stop_redis
            ;;
        restart)
            stop_redis
            sleep 2
            start_redis
            ;;
        status)
            show_status
            ;;
        join)
            join_cluster "$@"
            ;;
        backup)
            backup_data
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            error_exit "未知命令: $command\n运行 '$0 help' 查看帮助"
            ;;
    esac
}

main "$@"
