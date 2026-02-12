#!/bin/bash

#######################################
# Redis Cluster 本地开发环境管理脚本
# 用途: 在 MacBook 上使用多端口模拟 Redis Cluster
# 使用: ./local-cluster.sh [start|stop|restart|status|create|reset|logs]
#######################################

set -e

# 获取脚本目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# 加载公共函数
source "${SCRIPT_DIR}/common/utils.sh"

# 加载环境配置
source "${SCRIPT_DIR}/env/local.env"

#######################################
# 显示帮助信息
#######################################
show_help() {
    cat << EOF
Redis Cluster 本地开发环境管理脚本

用法: $0 <命令> [选项]

命令:
    start       启动所有 Redis 节点
    stop        停止所有 Redis 节点
    restart     重启所有 Redis 节点
    status      查看集群状态
    create      创建集群（首次启动后执行）
    reset       重置集群（删除所有数据并重新创建）
    logs        查看日志
    clean       清理所有数据和配置
    test        运行测试脚本
    help        显示帮助信息

选项:
    -n, --node  指定节点端口（仅对部分命令有效）
    -f, --force 强制执行（不提示确认）

示例:
    $0 start                # 启动所有节点
    $0 stop                 # 停止所有节点
    $0 create               # 创建集群
    $0 reset                # 重置集群
    $0 logs -n 7000         # 查看 7000 端口节点日志
    $0 test                 # 运行测试

EOF
}

#######################################
# 创建必要的目录
#######################################
create_directories() {
    log "INFO" "创建必要的目录..."
    ensure_dir "$REDIS_BASE_DIR"
    ensure_dir "$REDIS_DATA_DIR"
    ensure_dir "$REDIS_LOG_DIR"
    ensure_dir "$REDIS_CONF_DIR"
    ensure_dir "$REDIS_PID_DIR"
    
    # 为每个节点创建数据目录
    for node in "${ALL_NODES[@]}"; do
        local port=$(echo $node | cut -d: -f2)
        ensure_dir "${REDIS_DATA_DIR}/${port}"
        ensure_dir "${REDIS_CONF_DIR}/${port}"
    done
}

#######################################
# 生成 Redis 配置文件
# Arguments:
#   $1 - 端口号
#######################################
generate_redis_config() {
    local port=$1
    local config_file="${REDIS_CONF_DIR}/${port}/redis.conf"
    
    log "INFO" "生成配置文件: $config_file"
    
    cat > "$config_file" << EOF
# Redis Cluster 节点配置
# 节点端口: ${port}
# 生成时间: $(date)

# 网络配置
bind 127.0.0.1
port ${port}
protected-mode no
tcp-backlog 511
timeout ${REDIS_TIMEOUT}
tcp-keepalive ${REDIS_TCP_KEEPALIVE}

# 通用配置
daemonize yes
supervised no
pidfile ${REDIS_PID_DIR}/redis-${port}.pid
loglevel ${REDIS_LOGLEVEL}
logfile ${REDIS_LOG_DIR}/redis-${port}.log
databases 16

# 持久化配置 - RDB
save 900 1
save 300 10
save 60 10000
stop-writes-on-bgsave-error yes
rdbcompression yes
rdbchecksum yes
dbfilename dump-${port}.rdb
dir ${REDIS_DATA_DIR}/${port}

# 持久化配置 - AOF
appendonly ${APPENDONLY}
appendfilename "appendonly-${port}.aof"
appendfsync ${APPENDFSYNC}
no-appendfsync-on-rewrite no
auto-aof-rewrite-percentage ${AUTO_AOF_REWRITE_PERCENTAGE}
auto-aof-rewrite-min-size ${AUTO_AOF_REWRITE_MIN_SIZE}
aof-load-truncated yes
aof-use-rdb-preamble yes

# 内存配置
maxmemory ${REDIS_MAXMEMORY}
maxmemory-policy ${REDIS_MAXMEMORY_POLICY}

# 集群配置
cluster-enabled yes
cluster-config-file ${REDIS_CONF_DIR}/${port}/${CLUSTER_CONFIG_FILE}
cluster-node-timeout ${CLUSTER_NODE_TIMEOUT}
cluster-slave-validity-factor ${CLUSTER_SLAVE_VALIDITY_FACTOR}
cluster-migration-barrier ${CLUSTER_MIGRATION_BARRIER}
cluster-require-full-coverage ${CLUSTER_REQUIRE_FULL_COVERAGE}

# 复制配置
replica-serve-stale-data ${REPLICA_SERVE_STALE_DATA}
replica-read-only ${REPLICA_READ_ONLY}
repl-diskless-sync no
repl-diskless-sync-delay 5
repl-disable-tcp-nodelay no
repl-backlog-size 1mb
repl-backlog-ttl 3600
replica-priority ${REPLICA_PRIORITY}

# 慢查询日志
slowlog-log-slower-than 10000
slowlog-max-len 128

# 客户端配置
maxclients 10000

# 安全配置
# requirepass ${CLUSTER_PASSWORD}
# masterauth ${CLUSTER_PASSWORD}
EOF

    if [ -n "$CLUSTER_PASSWORD" ]; then
        sed -i.bak "s/# requirepass.*/requirepass ${CLUSTER_PASSWORD}/" "$config_file"
        sed -i.bak "s/# masterauth.*/masterauth ${CLUSTER_PASSWORD}/" "$config_file"
    fi
}

#######################################
# 生成所有配置文件
#######################################
generate_all_configs() {
    log "INFO" "生成所有节点配置文件..."
    
    for node in "${ALL_NODES[@]}"; do
        local port=$(echo $node | cut -d: -f2)
        generate_redis_config $port
    done
    
    success "配置文件生成完成"
}

#######################################
# 启动单个节点
# Arguments:
#   $1 - 端口号
#######################################
start_node() {
    local port=$1
    local config_file="${REDIS_CONF_DIR}/${port}/redis.conf"
    local pid_file="${REDIS_PID_DIR}/redis-${port}.pid"
    
    if [ -f "$pid_file" ]; then
        local pid=$(cat "$pid_file")
        if kill -0 $pid 2>/dev/null; then
            warn "节点 ${port} 已在运行 (PID: $pid)"
            return 0
        fi
    fi
    
    log "INFO" "启动节点: ${port}"
    redis-server "$config_file"
    
    if wait_for_redis "127.0.0.1" $port 10; then
        success "节点 ${port} 启动成功"
    else
        error_exit "节点 ${port} 启动失败"
    fi
}

#######################################
# 启动所有节点
#######################################
start_all_nodes() {
    print_title "启动 Redis Cluster 节点"
    
    create_directories
    generate_all_configs
    
    for node in "${ALL_NODES[@]}"; do
        local port=$(echo $node | cut -d: -f2)
        start_node $port
    done
    
    echo ""
    info "所有节点已启动，请运行 '$0 create' 创建集群"
}

#######################################
# 停止单个节点
# Arguments:
#   $1 - 端口号
#######################################
stop_node() {
    local port=$1
    local pid_file="${REDIS_PID_DIR}/redis-${port}.pid"
    
    if [ ! -f "$pid_file" ]; then
        warn "节点 ${port} 未运行"
        return 0
    fi
    
    local pid=$(cat "$pid_file")
    
    log "INFO" "停止节点: ${port} (PID: $pid)"
    
    redis-cli -p $port SHUTDOWN NOSAVE 2>/dev/null || kill $pid 2>/dev/null
    
    local count=0
    while kill -0 $pid 2>/dev/null && [ $count -lt 10 ]; do
        sleep 1
        ((count++))
    done
    
    if kill -0 $pid 2>/dev/null; then
        kill -9 $pid 2>/dev/null
    fi
    
    rm -f "$pid_file"
    success "节点 ${port} 已停止"
}

#######################################
# 停止所有节点
#######################################
stop_all_nodes() {
    print_title "停止 Redis Cluster 节点"
    
    for node in "${ALL_NODES[@]}"; do
        local port=$(echo $node | cut -d: -f2)
        stop_node $port
    done
}

#######################################
# 创建集群
#######################################
create_cluster() {
    print_title "创建 Redis Cluster"
    
    # 检查所有节点是否在运行
    for node in "${ALL_NODES[@]}"; do
        local host=$(echo $node | cut -d: -f1)
        local port=$(echo $node | cut -d: -f2)
        
        if ! redis-cli -h $host -p $port ping &>/dev/null; then
            error_exit "节点 ${host}:${port} 未运行，请先启动所有节点"
        fi
    done
    
    # 构建集群创建命令
    local cluster_nodes=""
    for node in "${ALL_NODES[@]}"; do
        cluster_nodes+=" $node"
    done
    
    log "INFO" "创建集群 (3主3从)..."
    
    # 使用 redis-cli --cluster create 创建集群
    # --cluster-replicas 1 表示每个主节点有1个从节点
    if [ -n "$CLUSTER_PASSWORD" ]; then
        redis-cli --cluster create $cluster_nodes \
            --cluster-replicas 1 \
            --cluster-yes \
            -a "$CLUSTER_PASSWORD" --no-auth-warning
    else
        redis-cli --cluster create $cluster_nodes \
            --cluster-replicas 1 \
            --cluster-yes
    fi
    
    if [ $? -eq 0 ]; then
        success "集群创建成功"
        show_cluster_status
    else
        error_exit "集群创建失败"
    fi
}

#######################################
# 显示集群状态
#######################################
show_cluster_status() {
    print_title "Redis Cluster 状态"
    
    # 使用第一个节点查询集群状态
    local first_node=${DC_A_NODES[0]}
    local host=$(echo $first_node | cut -d: -f1)
    local port=$(echo $first_node | cut -d: -f2)
    
    echo ""
    info "集群信息:"
    echo ""
    redis-cli -h $host -p $port CLUSTER INFO
    echo ""
    
    info "节点列表:"
    echo ""
    redis-cli -h $host -p $port CLUSTER NODES
    echo ""
    
    info "槽位分布:"
    echo ""
    redis-cli --cluster info $host:$port 2>/dev/null || true
    echo ""
    
    info "节点状态:"
    echo ""
    
    local table_data=("节点|端口|角色|状态|连接数|内存使用")
    
    for node in "${ALL_NODES[@]}"; do
        local host=$(echo $node | cut -d: -f1)
        local port=$(echo $node | cut -d: -f2)
        
        local role=$(get_redis_role $host $port)
        local connected_clients=$(redis_exec $host $port "INFO clients" | grep connected_clients | cut -d: -f2 | tr -d '\r')
        local used_memory=$(redis_exec $host $port "INFO memory" | grep used_memory_human | cut -d: -f2 | tr -d '\r')
        
        if redis_exec $host $port ping &>/dev/null; then
            local status="运行中"
        else
            local status="已停止"
        fi
        
        table_data+=("$host|$port|$role|$status|$connected_clients|$used_memory")
    done
    
    print_table "${table_data[@]}"
}

#######################################
# 重置集群
#######################################
reset_cluster() {
    print_title "重置 Redis Cluster"
    
    if [ "$1" != "-f" ] && [ "$1" != "--force" ]; then
        if ! confirm "这将删除所有数据并重新创建集群，是否继续?"; then
            info "操作已取消"
            exit 0
        fi
    fi
    
    # 停止所有节点
    stop_all_nodes
    
    # 删除所有数据
    log "INFO" "删除所有数据..."
    rm -rf "${REDIS_DATA_DIR:?}"/*
    rm -rf "${REDIS_CONF_DIR:?}"/*
    rm -rf "${REDIS_LOG_DIR:?}"/*
    rm -rf "${REDIS_PID_DIR:?}"/*
    
    success "数据已清理"
    
    # 重新启动并创建集群
    start_all_nodes
    sleep 2
    create_cluster
}

#######################################
# 查看日志
# Arguments:
#   $1 - 端口号 (可选)
#######################################
view_logs() {
    local port=$1
    
    if [ -n "$port" ]; then
        local log_file="${REDIS_LOG_DIR}/redis-${port}.log"
        if [ -f "$log_file" ]; then
            tail -f "$log_file"
        else
            error_exit "日志文件不存在: $log_file"
        fi
    else
        # 显示所有日志文件
        info "可用的日志文件:"
        for node in "${ALL_NODES[@]}"; do
            local p=$(echo $node | cut -d: -f2)
            echo "  - ${REDIS_LOG_DIR}/redis-${p}.log"
        done
        echo ""
        info "使用 '$0 logs -n <端口>' 查看特定节点日志"
    fi
}

#######################################
# 清理环境
#######################################
clean_environment() {
    print_title "清理 Redis Cluster 环境"
    
    if [ "$1" != "-f" ] && [ "$1" != "--force" ]; then
        if ! confirm "这将删除所有数据、配置和日志，是否继续?"; then
            info "操作已取消"
            exit 0
        fi
    fi
    
    # 停止所有节点
    for node in "${ALL_NODES[@]}"; do
        local port=$(echo $node | cut -d: -f2)
        stop_node $port 2>/dev/null || true
    done
    
    # 删除所有文件
    log "INFO" "删除所有文件..."
    rm -rf "$REDIS_BASE_DIR"
    
    success "环境已清理完成"
}

#######################################
# 运行测试
#######################################
run_tests() {
    print_title "运行 Redis Cluster 测试"
    
    local test_script="${SCRIPT_DIR}/test-cluster.sh"
    
    if [ -f "$test_script" ]; then
        bash "$test_script"
    else
        warn "测试脚本不存在: $test_script"
        info "正在创建基础测试..."
        
        # 基础连接测试
        info "1. 测试节点连接..."
        for node in "${ALL_NODES[@]}"; do
            local host=$(echo $node | cut -d: -f1)
            local port=$(echo $node | cut -d: -f2)
            
            if redis-cli -h $host -p $port ping &>/dev/null; then
                success "节点 ${host}:${port} 连接正常"
            else
                error "节点 ${host}:${port} 连接失败"
            fi
        done
        
        echo ""
        info "2. 测试集群写入..."
        
        # 写入测试数据
        local test_key="test:cluster:$(date +%s)"
        local test_value="hello-redis-cluster"
        
        if redis-cli -c -p 7000 SET "$test_key" "$test_value" &>/dev/null; then
            success "写入测试成功"
            
            # 读取测试
            local read_value=$(redis-cli -c -p 7003 GET "$test_key" 2>/dev/null)
            if [ "$read_value" == "$test_value" ]; then
                success "读取测试成功"
            else
                error "读取测试失败"
            fi
            
            # 清理测试数据
            redis-cli -c -p 7000 DEL "$test_key" &>/dev/null
        else
            error "写入测试失败"
        fi
        
        echo ""
        info "3. 测试主从复制..."
        
        # 检查主从复制状态
        for mapping in "${REPLICA_MAPPING[@]}"; do
            local slave_port=$(echo $mapping | cut -d: -f1)
            local master_port=$(echo $mapping | cut -d: -f2)
            
            local master_link=$(redis_exec "127.0.0.1" $slave_port "INFO replication" | grep master_link_status | cut -d: -f2 | tr -d '\r')
            
            if [ "$master_link" == "up" ]; then
                success "主从复制正常: ${slave_port} -> ${master_port}"
            else
                error "主从复制异常: ${slave_port} -> ${master_port}"
            fi
        done
    fi
}

#######################################
# 主函数
#######################################
main() {
    local command=${1:-help}
    local option=${2:-}
    
    # 检查 Redis 是否安装
    if ! check_redis_installed; then
        error_exit "Redis 未安装，请先安装 Redis\nmacOS: brew install redis"
    fi
    
    case $command in
        start)
            start_all_nodes
            ;;
        stop)
            stop_all_nodes
            ;;
        restart)
            stop_all_nodes
            sleep 2
            start_all_nodes
            ;;
        status)
            show_cluster_status
            ;;
        create)
            create_cluster
            ;;
        reset)
            reset_cluster "$option"
            ;;
        logs)
            view_logs "$option"
            ;;
        clean)
            clean_environment "$option"
            ;;
        test)
            run_tests
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
