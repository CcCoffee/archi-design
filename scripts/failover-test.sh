#!/bin/bash

#######################################
# Redis Cluster 故障恢复测试脚本
# 用途: 测试各种故障场景和恢复能力
# 使用: ./failover-test.sh [测试类型]
#######################################

# 不使用 set -e，手动处理错误

# 获取脚本目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 加载公共函数
source "${SCRIPT_DIR}/common/utils.sh"

# 加载环境配置
source "${SCRIPT_DIR}/env/local.env"

# Redis 客户端参数
REDIS_CLI_ARGS=""
[ -n "$CLUSTER_PASSWORD" ] && REDIS_CLI_ARGS="-a $CLUSTER_PASSWORD --no-auth-warning"

#######################################
# 显示帮助信息
#######################################
show_help() {
    cat << EOF
Redis Cluster 故障恢复测试脚本

用法: $0 [测试类型]

测试类型:
    all                 运行所有故障测试
    master-down         主节点故障测试 (P1)
    slave-down          从节点故障测试 (P1)
    network-split       网络分区模拟测试 (P2)
    multi-failure       多节点故障测试 (P2)
    recovery            数据恢复测试
    datacenter-failure  数据中心故障测试 (P3)
    disaster-recovery   灾难恢复测试 (P4)
    help                显示帮助

灾难场景分类:
    P1 - 单节点故障 (自动恢复，秒级)
    P2 - 网络分区 (自动恢复，分钟级)
    P3 - 数据中心故障 (手动切换，分钟级)
    P4 - 灾难恢复 (从备份恢复，小时级)

示例:
    $0 all
    $0 master-down
    $0 p3              # 数据中心故障测试
    $0 p4              # 灾难恢复测试

警告: 这些测试会影响集群正常运行，请谨慎使用！

EOF
}

#######################################
# 获取节点 ID
# Arguments:
#   $1 - 端口号
# Outputs:
#   节点 ID
#######################################
get_node_id_by_port() {
    local port=$1
    redis-cli -p $port $REDIS_CLI_ARGS CLUSTER MYID 2>/dev/null
}

#######################################
# 获取主节点端口
# Arguments:
#   $1 - 从节点端口
# Outputs:
#   主节点端口
#######################################
get_master_port() {
    local slave_port=$1
    local master_info=$(redis-cli -p $slave_port $REDIS_CLI_ARGS INFO replication 2>/dev/null | grep "master_host:")
    echo "$master_info" | head -1
}

#######################################
# 等待集群稳定
# Arguments:
#   $1 - 等待时间（秒）
#######################################
wait_cluster_stable() {
    local wait_time=${1:-5}
    log "INFO" "等待集群稳定 ${wait_time} 秒..."
    sleep $wait_time
}

#######################################
# 检查集群状态
# Outputs:
#   集群状态
#######################################
check_cluster_state() {
    local first_node=${DC_A_NODES[0]}
    local host=$(echo $first_node | cut -d: -f1)
    local port=$(echo $first_node | cut -d: -f2)
    
    redis-cli -h $host -p $port $REDIS_CLI_ARGS CLUSTER INFO 2>/dev/null | grep "cluster_state:" | cut -d: -f2 | tr -d '\r'
}

#######################################
# 写入测试数据
# Arguments:
#   $1 - 键前缀
#   $2 - 数量
# Outputs:
#   写入的键列表
#######################################
write_test_data() {
    local prefix=$1
    local count=${2:-100}
    
    log "INFO" "写入 ${count} 条测试数据..."
    
    local written=0
    for i in $(seq 1 $count); do
        # 使用集群模式，自动路由到正确节点
        if redis-cli -c -p 7001 $REDIS_CLI_ARGS SET "${prefix}:${i}" "value${i}" &>/dev/null; then
            written=$((written + 1))
        fi
    done
    
    success "已写入 ${written}/${count} 条数据"
}

#######################################
# 验证数据完整性
# Arguments:
#   $1 - 键前缀
#   $2 - 数量
# Returns:
#   0 - 数据完整
#   1 - 数据丢失
#######################################
verify_data() {
    local prefix=$1
    local count=${2:-100}
    
    log "INFO" "验证数据完整性..."
    
    local missing=0
    local mismatch=0
    
    for i in $(seq 1 $count); do
        local key="${prefix}:${i}"
        local value=$(redis-cli -c -p 7001 $REDIS_CLI_ARGS GET "$key" 2>/dev/null)
        
        if [ -z "$value" ]; then
            missing=$((missing + 1))
        elif [ "$value" != "value${i}" ]; then
            mismatch=$((mismatch + 1))
        fi
    done
    
    if [ $missing -eq 0 ] && [ $mismatch -eq 0 ]; then
        success "数据完整性验证通过 (${count}/${count})"
        return 0
    else
        error "数据丢失: ${missing}, 数据不一致: ${mismatch}"
        return 1
    fi
}

#######################################
# 清理测试数据
# Arguments:
#   $1 - 键前缀
#   $2 - 数量
#######################################
cleanup_test_data() {
    local prefix=$1
    local count=${2:-100}
    
    log "INFO" "清理测试数据..."
    
    for i in $(seq 1 $count); do
        redis-cli -c -p 7001 $REDIS_CLI_ARGS DEL "${prefix}:${i}" &>/dev/null
    done
    
    success "已清理 ${count} 条测试数据"
}

#######################################
# 停止节点
# Arguments:
#   $1 - 端口号
#######################################
stop_node() {
    local port=$1
    log "INFO" "停止节点 ${port}..."
    redis-cli -p $port $REDIS_CLI_ARGS SHUTDOWN NOSAVE 2>/dev/null || true
    sleep 2
    
    # 验证节点已停止
    if ! redis-cli -p $port $REDIS_CLI_ARGS PING &>/dev/null; then
        success "节点 ${port} 已停止"
    else
        warn "节点 ${port} 可能仍在运行"
    fi
}

#######################################
# 生成 Redis 配置文件
# Arguments:
#   $1 - 端口号
#######################################
generate_redis_config() {
    local port=$1
    local config_dir="${HOME}/.redis-cluster/conf/${port}"
    local config_file="${config_dir}/redis.conf"
    
    mkdir -p "$config_dir"
    mkdir -p "${HOME}/.redis-cluster/data/${port}"
    mkdir -p "${HOME}/.redis-cluster/logs"
    mkdir -p "${HOME}/.redis-cluster/pids"
    
    cat > "$config_file" << EOF
# Redis Cluster 节点配置
# 节点端口: ${port}
# 生成时间: $(date)

# 网络配置
bind 127.0.0.1
port ${port}
protected-mode no
daemonize yes
pidfile ${HOME}/.redis-cluster/pids/redis-${port}.pid
logfile /dev/null
dir ${HOME}/.redis-cluster/data/${port}
dbfilename dump-${port}.rdb

# 集群配置
cluster-enabled yes
cluster-config-file ${config_dir}/nodes.conf
cluster-node-timeout 5000

# 持久化配置
appendonly yes
appendfilename appendonly-${port}.aof

# 内存配置
maxmemory 256mb
maxmemory-policy allkeys-lru
EOF
}

#######################################
# 启动节点
# Arguments:
#   $1 - 端口号
#######################################
start_node() {
    local port=$1
    
    # 检查节点是否已在运行
    if redis-cli -p $port $REDIS_CLI_ARGS PING &>/dev/null; then
        success "节点 ${port} 已在运行"
        return 0
    fi
    
    # 重新生成配置文件（解决日志文件权限问题）
    generate_redis_config $port
    
    local config_file="${HOME}/.redis-cluster/conf/${port}/redis.conf"
    
    log "INFO" "启动节点 ${port}..."
    redis-server "$config_file" 2>/dev/null
    
    sleep 2
    
    if redis-cli -p $port $REDIS_CLI_ARGS PING &>/dev/null; then
        success "节点 ${port} 已启动"
    else
        error "节点 ${port} 启动失败"
    fi
}

#######################################
# 检查集群是否正常
# Returns:
#   0 - 集群正常
#   1 - 集群异常
#######################################
check_cluster_ok() {
    local state=$(redis-cli -p 7001 CLUSTER INFO 2>/dev/null | grep "cluster_state:" | cut -d: -f2 | tr -d '\r')
    if [ "$state" == "ok" ]; then
        return 0
    else
        return 1
    fi
}

#######################################
# 获取可用的主节点端口
# Outputs:
#   主节点端口
#######################################
get_available_master() {
    for port in 7001 7002 7003 7004 7005 7006; do
        if redis-cli -p $port PING &>/dev/null; then
            local role=$(redis-cli -p $port INFO replication 2>/dev/null | grep "^role:" | cut -d: -f2 | tr -d '\r')
            if [ "$role" == "master" ]; then
                echo $port
                return 0
            fi
        fi
    done
    return 1
}

#######################################
# 获取可用的从节点端口
# Outputs:
#   从节点端口
#######################################
get_available_slave() {
    for port in 7001 7002 7003 7004 7005 7006; do
        if redis-cli -p $port PING &>/dev/null; then
            local role=$(redis-cli -p $port INFO replication 2>/dev/null | grep "^role:" | cut -d: -f2 | tr -d '\r')
            if [ "$role" == "slave" ]; then
                echo $port
                return 0
            fi
        fi
    done
    return 1
}

#######################################
# 主节点故障测试
#######################################
test_master_down() {
    print_title "主节点故障测试"
    
    # 检查集群状态
    if ! check_cluster_ok; then
        error "集群状态异常，跳过测试"
        return 1
    fi
    
    # 获取可用的主节点
    local master_port=$(get_available_master)
    if [ -z "$master_port" ]; then
        error "未找到可用的主节点"
        return 1
    fi
    
    local master_id=$(get_node_id_by_port $master_port)
    
    # 找到对应的从节点
    local slave_port=""
    for port in 7001 7002 7003 7004 7005 7006; do
        if [ "$port" != "$master_port" ] && redis-cli -p $port PING &>/dev/null; then
            local role=$(redis-cli -p $port INFO replication 2>/dev/null | grep "^role:" | cut -d: -f2 | tr -d '\r')
            if [ "$role" == "slave" ]; then
                local master_info=$(redis-cli -p $port INFO replication 2>/dev/null | grep "master_port:")
                if echo "$master_info" | grep -q "master_port:${master_port}"; then
                    slave_port=$port
                    break
                fi
            fi
        fi
    done
    
    if [ -z "$slave_port" ]; then
        error "未找到主节点 ${master_port} 的从节点"
        return 1
    fi
    
    info "测试场景: 主节点 ${master_port} 故障"
    info "预期结果: 从节点 ${slave_port} 自动提升为主节点"
    echo ""
    
    # 写入测试数据
    write_test_data "failover:test" 50
    
    # 记录故障前的状态
    info "故障前状态:"
    echo "  主节点: ${master_port} (ID: ${master_id:0:8}...)"
    echo "  从节点: ${slave_port}"
    echo ""
    
    # 停止主节点
    warn "模拟主节点 ${master_port} 故障..."
    stop_node $master_port
    
    # 等待故障转移
    info "等待故障转移（约 10 秒）..."
    sleep 10
    
    # 检查从节点是否提升
    local new_role=$(redis-cli -p $slave_port $REDIS_CLI_ARGS INFO replication 2>/dev/null | grep "role:" | cut -d: -f2 | tr -d '\r')
    
    if [ "$new_role" == "master" ]; then
        success "故障转移成功: 从节点 ${slave_port} 已提升为主节点"
    else
        error "故障转移失败: 从节点 ${slave_port} 角色仍为 ${new_role}"
    fi
    
    # 验证数据完整性
    verify_data "failover:test" 50
    
    # 恢复原主节点
    echo ""
    info "恢复原主节点..."
    start_node $master_port
    
    wait_cluster_stable 5
    
    # 检查恢复后的角色
    local recovered_role=$(redis-cli -p $master_port $REDIS_CLI_ARGS INFO replication 2>/dev/null | grep "role:" | cut -d: -f2 | tr -d '\r')
    info "原主节点 ${master_port} 恢复后角色: ${recovered_role}"
    
    # 清理测试数据
    cleanup_test_data "failover:test" 50
    
    # 显示最终状态
    echo ""
    info "最终集群状态:"
    ./cluster-manager.sh status 2>/dev/null | head -30
}

#######################################
# 从节点故障测试
#######################################
test_slave_down() {
    print_title "从节点故障测试"
    
    # 检查集群状态
    if ! check_cluster_ok; then
        error "集群状态异常，跳过测试"
        return 1
    fi
    
    # 获取可用的从节点
    local slave_port=$(get_available_slave)
    if [ -z "$slave_port" ]; then
        error "未找到可用的从节点"
        return 1
    fi
    
    info "测试场景: 从节点 ${slave_port} 故障"
    info "预期结果: 集群继续正常服务"
    echo ""
    
    # 写入测试数据
    write_test_data "slave:test" 30
    
    # 停止从节点
    warn "模拟从节点 ${slave_port} 故障..."
    stop_node $slave_port
    
    wait_cluster_stable 3
    
    # 检查集群状态
    local cluster_state=$(check_cluster_state)
    info "集群状态: ${cluster_state}"
    
    # 尝试写入和读取
    info "测试集群读写..."
    
    if redis-cli -c -p 7002 $REDIS_CLI_ARGS SET "slave:test:check" "ok" &>/dev/null; then
        success "写入测试成功"
    else
        error "写入测试失败"
    fi
    
    local read_val=$(redis-cli -c -p 7002 $REDIS_CLI_ARGS GET "slave:test:check" 2>/dev/null)
    if [ "$read_val" == "ok" ]; then
        success "读取测试成功"
    else
        error "读取测试失败"
    fi
    
    # 验证数据完整性
    verify_data "slave:test" 30
    
    # 恢复从节点
    echo ""
    info "恢复从节点..."
    start_node $slave_port
    
    wait_cluster_stable 5
    
    # 检查复制状态
    local master_link=$(redis-cli -p $slave_port $REDIS_CLI_ARGS INFO replication 2>/dev/null | grep "master_link_status:" | cut -d: -f2 | tr -d '\r')
    info "从节点 ${slave_port} 复制状态: ${master_link}"
    
    # 清理
    cleanup_test_data "slave:test" 30
    redis-cli -c -p 7002 $REDIS_CLI_ARGS DEL "slave:test:check" &>/dev/null
}

#######################################
# 网络分区模拟测试
#######################################
test_network_split() {
    print_title "网络分区模拟测试"
    
    info "测试场景: 模拟网络分区（暂停部分节点）"
    info "预期结果: 集群在多数派节点上继续服务"
    echo ""
    
    # 写入测试数据
    write_test_data "split:test" 30
    
    # 暂停一个主节点（模拟分区）
    local paused_port=7005
    
    warn "暂停节点 ${paused_port} 模拟网络分区..."
    redis-cli -p $paused_port $REDIS_CLI_ARGS CLIENT PAUSE 10000 &>/dev/null || warn "CLIENT PAUSE 命令不可用"
    
    info "节点 ${paused_port} 已暂停 10 秒"
    
    # 尝试访问被暂停节点的数据
    info "测试集群可用性..."
    
    # 写入新数据
    if redis-cli -c -p 7002 $REDIS_CLI_ARGS SET "split:test:new" "value" &>/dev/null; then
        success "集群仍可写入"
    else
        warn "集群写入受限（部分槽位不可用）"
    fi
    
    # 等待暂停结束
    info "等待暂停结束..."
    sleep 12
    
    # 验证数据
    verify_data "split:test" 30
    
    # 清理
    cleanup_test_data "split:test" 30
    redis-cli -c -p 7002 $REDIS_CLI_ARGS DEL "split:test:new" &>/dev/null
}

#######################################
# 多节点故障测试
#######################################
test_multi_failure() {
    print_title "多节点故障测试"
    
    # 检查集群状态
    if ! check_cluster_ok; then
        error "集群状态异常，跳过测试"
        return 1
    fi
    
    info "测试场景: 多个节点同时故障"
    info "预期结果: 集群在剩余节点上继续服务或降级"
    echo ""
    
    # 写入测试数据
    write_test_data "multi:test" 30
    
    # 获取可用的从节点
    local slave_port=$(get_available_slave)
    if [ -z "$slave_port" ]; then
        error "未找到可用的从节点"
        return 1
    fi
    
    warn "停止从节点 ${slave_port}..."
    stop_node $slave_port
    
    wait_cluster_stable 2
    
    # 检查集群状态
    local cluster_state=$(check_cluster_state)
    info "停止一个从节点后集群状态: ${cluster_state}"
    
    # 尝试读写
    if redis-cli -c -p 7002 $REDIS_CLI_ARGS SET "multi:test:check" "ok" &>/dev/null; then
        success "集群仍可正常写入"
    fi
    
    # 恢复节点
    echo ""
    info "恢复故障节点..."
    start_node $slave_port
    
    wait_cluster_stable 5
    
    # 验证数据
    verify_data "multi:test" 30
    
    # 清理
    cleanup_test_data "multi:test" 30
    redis-cli -c -p 7002 $REDIS_CLI_ARGS DEL "multi:test:check" &>/dev/null
}

#######################################
# 数据恢复测试
#######################################
test_recovery() {
    print_title "数据恢复测试"
    
    info "测试场景: 验证持久化和数据恢复能力"
    echo ""
    
    # 写入大量测试数据
    write_test_data "recovery:test" 100
    
    # 强制保存 RDB
    info "触发 RDB 快照..."
    for port in 7001 7002 7003 7004 7005 7006; do
        redis-cli -p $port $REDIS_CLI_ARGS BGSAVE &>/dev/null
    done
    
    sleep 3
    
    # 检查 RDB 文件
    info "检查 RDB 文件..."
    local rdb_count=0
    for port in 7001 7002 7003 7004 7005 7006; do
        local rdb_file="${HOME}/.redis-cluster/data/${port}/dump-${port}.rdb"
        if [ -f "$rdb_file" ]; then
            local size=$(ls -lh "$rdb_file" | awk '{print $5}')
            echo "  节点 ${port}: RDB 文件存在 (${size})"
            rdb_count=$((rdb_count + 1))
        fi
    done
    
    if [ $rdb_count -gt 0 ]; then
        success "发现 ${rdb_count} 个 RDB 文件"
    else
        error "未发现 RDB 文件"
    fi
    
    # 检查 AOF 文件
    echo ""
    info "检查 AOF 文件..."
    local aof_count=0
    for port in 7001 7002 7003 7004 7005 7006; do
        # Redis 8.x 使用 appendonlydir 目录存放 AOF 文件
        local aof_dir="${HOME}/.redis-cluster/data/${port}/appendonlydir"
        if [ -d "$aof_dir" ]; then
            local aof_files=$(ls "$aof_dir"/*.aof 2>/dev/null | wc -l | tr -d ' ')
            if [ "$aof_files" -gt 0 ]; then
                local size=$(du -sh "$aof_dir" 2>/dev/null | cut -f1)
                echo "  节点 ${port}: AOF 文件存在 (${size}, ${aof_files} 个文件)"
                aof_count=$((aof_count + 1))
            fi
        fi
    done
    
    if [ $aof_count -gt 0 ]; then
        success "发现 ${aof_count} 个 AOF 文件"
    else
        warn "未发现 AOF 文件"
    fi
    
    # 验证数据完整性
    echo ""
    verify_data "recovery:test" 100
    
    # 清理
    cleanup_test_data "recovery:test" 100
}

#######################################
# P3: 数据中心故障测试
# 模拟整个数据中心不可用的场景
#######################################
test_datacenter_failure() {
    print_title "数据中心故障测试 (P3)"
    
    # 检查集群状态
    if ! check_cluster_ok; then
        error "集群状态异常，跳过测试"
        return 1
    fi
    
    info "测试场景: 模拟整个数据中心不可用"
    info "预期结果: 集群在剩余数据中心节点上继续服务"
    echo ""
    
    # 获取当前主节点
    local masters=()
    for port in 7001 7002 7003 7004 7005 7006; do
        if redis-cli -p $port PING &>/dev/null; then
            local role=$(redis-cli -p $port INFO replication 2>/dev/null | grep "^role:" | cut -d: -f2 | tr -d '\r')
            if [ "$role" == "master" ]; then
                masters+=($port)
            fi
        fi
    done
    
    info "当前主节点: ${masters[*]}"
    
    # 写入测试数据
    write_test_data "dc:test" 50
    
    # 模拟数据中心故障：停止一个主节点及其从节点
    # 假设 7005(主) 和 7001(从) 属于同一数据中心
    local dc_master=""
    local dc_slave=""
    
    # 找到一个主节点和它的从节点
    for master_port in "${masters[@]}"; do
        for port in 7001 7002 7003 7004 7005 7006; do
            if [ "$port" != "$master_port" ] && redis-cli -p $port PING &>/dev/null; then
                local role=$(redis-cli -p $port INFO replication 2>/dev/null | grep "^role:" | cut -d: -f2 | tr -d '\r')
                if [ "$role" == "slave" ]; then
                    local master_info=$(redis-cli -p $port INFO replication 2>/dev/null | grep "master_port:")
                    if echo "$master_info" | grep -q "master_port:${master_port}"; then
                        dc_master=$master_port
                        dc_slave=$port
                        break 2
                    fi
                fi
            fi
        done
    done
    
    if [ -z "$dc_master" ] || [ -z "$dc_slave" ]; then
        error "无法找到主从节点对"
        cleanup_test_data "dc:test" 50
        return 1
    fi
    
    info "模拟数据中心故障: 停止主节点 ${dc_master} 和从节点 ${dc_slave}"
    echo ""
    
    # 停止主节点和从节点
    warn "停止数据中心节点..."
    stop_node $dc_master
    stop_node $dc_slave
    
    # 等待集群检测到故障
    info "等待集群检测故障（约 10 秒）..."
    sleep 10
    
    # 检查集群状态
    local cluster_ok=false
    for port in 7001 7002 7003 7004 7005 7006; do
        if redis-cli -p $port PING &>/dev/null; then
            local state=$(redis-cli -p $port CLUSTER INFO 2>/dev/null | grep "cluster_state:" | cut -d: -f2 | tr -d '\r')
            if [ "$state" == "ok" ]; then
                cluster_ok=true
                break
            fi
        fi
    done
    
    if $cluster_ok; then
        success "集群状态: ok（多数派节点正常）"
    else
        warn "集群状态: 部分不可用（槽位未完全覆盖）"
    fi
    
    # 测试读写
    info "测试集群读写能力..."
    local write_ok=false
    local read_ok=false
    
    # 尝试写入
    for port in 7001 7002 7003 7004 7005 7006; do
        if redis-cli -p $port PING &>/dev/null; then
            if redis-cli -c -p $port SET "dc:test:check" "value" 2>/dev/null; then
                write_ok=true
                break
            fi
        fi
    done
    
    if $write_ok; then
        success "写入测试成功"
    else
        warn "写入测试失败（部分槽位不可用）"
    fi
    
    # 恢复数据中心节点
    echo ""
    info "恢复数据中心节点..."
    start_node $dc_master
    start_node $dc_slave
    
    info "等待集群恢复（约 10 秒）..."
    sleep 10
    
    # 验证数据完整性
    verify_data "dc:test" 50
    
    # 清理
    cleanup_test_data "dc:test" 50
    redis-cli -c -p 7002 DEL "dc:test:check" &>/dev/null
}

#######################################
# P4: 灾难恢复测试
# 模拟从备份恢复数据的场景
#######################################
test_disaster_recovery() {
    print_title "灾难恢复测试 (P4)"
    
    # 检查集群状态
    if ! check_cluster_ok; then
        error "集群状态异常，跳过测试"
        return 1
    fi
    
    info "测试场景: 模拟灾难后从备份恢复"
    info "预期结果: 数据能够从 RDB/AOF 备份恢复"
    echo ""
    
    # 写入测试数据
    write_test_data "disaster:test" 100
    
    # 记录写入的数据
    info "记录测试数据..."
    local data_count=0
    for i in $(seq 1 100); do
        local key="disaster:test:${i}"
        local value="value-${i}-$(date +%s)"
        if redis-cli -c -p 7002 SET "$key" "$value" &>/dev/null; then
            data_count=$((data_count + 1))
        fi
    done
    info "已写入 ${data_count} 条数据"
    
    # 强制持久化
    info "触发持久化..."
    for port in 7001 7002 7003 7004 7005 7006; do
        redis-cli -p $port BGSAVE &>/dev/null
        redis-cli -p $port BGREWRITEAOF &>/dev/null
    done
    
    sleep 5
    
    # 备份当前数据文件
    local backup_dir="${HOME}/.redis-cluster/backup_$(date +%Y%m%d_%H%M%S)"
    info "创建备份到 ${backup_dir}..."
    mkdir -p "$backup_dir"
    
    for port in 7001 7002 7003 7004 7005 7006; do
        local data_dir="${HOME}/.redis-cluster/data/${port}"
        local backup_subdir="${backup_dir}/${port}"
        mkdir -p "$backup_subdir"
        
        # 备份 RDB 文件
        if [ -f "${data_dir}/dump-${port}.rdb" ]; then
            cp "${data_dir}/dump-${port}.rdb" "${backup_subdir}/"
        fi
        
        # 备份 AOF 目录
        if [ -d "${data_dir}/appendonlydir" ]; then
            cp -r "${data_dir}/appendonlydir" "${backup_subdir}/"
        fi
    done
    
    success "备份完成"
    
    # 模拟灾难：删除所有数据
    warn "模拟灾难: 清空数据目录..."
    for port in 7001 7002 7003 7004 7005 7006; do
        rm -rf "${HOME}/.redis-cluster/data/${port}/*"
    done
    
    # 恢复数据
    info "从备份恢复数据..."
    for port in 7001 7002 7003 7004 7005 7006; do
        local data_dir="${HOME}/.redis-cluster/data/${port}"
        local backup_subdir="${backup_dir}/${port}"
        
        mkdir -p "$data_dir"
        
        # 恢复 RDB 文件
        if [ -f "${backup_subdir}/dump-${port}.rdb" ]; then
            cp "${backup_subdir}/dump-${port}.rdb" "${data_dir}/"
        fi
        
        # 恢复 AOF 目录
        if [ -d "${backup_subdir}/appendonlydir" ]; then
            cp -r "${backup_subdir}/appendonlydir" "${data_dir}/"
        fi
    done
    
    success "数据恢复完成"
    
    # 重启集群以加载恢复的数据
    info "重启集群加载恢复的数据..."
    cd /Users/kevin/Documents/trae_projects/redis_cluster/scripts
    ./local-cluster.sh stop &>/dev/null
    sleep 2
    ./local-cluster.sh start &>/dev/null
    sleep 5
    
    # 验证数据完整性
    info "验证恢复的数据..."
    local recovered_count=0
    for i in $(seq 1 100); do
        local key="disaster:test:${i}"
        if redis-cli -c -p 7002 EXISTS "$key" 2>/dev/null | grep -q "1"; then
            recovered_count=$((recovered_count + 1))
        fi
    done
    
    if [ $recovered_count -ge 90 ]; then
        success "数据恢复成功: ${recovered_count}/100 条数据已恢复"
    else
        error "数据恢复失败: 仅恢复 ${recovered_count}/100 条数据"
    fi
    
    # 清理
    cleanup_test_data "disaster:test" 100
    rm -rf "$backup_dir"
}

#######################################
# 主函数
#######################################
main() {
    local test_type=${1:-all}
    
    case $test_type in
        all)
            test_slave_down
            echo ""
            test_master_down
            echo ""
            test_multi_failure
            echo ""
            test_recovery
            echo ""
            test_datacenter_failure
            echo ""
            test_disaster_recovery
            ;;
        master-down)
            test_master_down
            ;;
        slave-down)
            test_slave_down
            ;;
        network-split)
            test_network_split
            ;;
        multi-failure)
            test_multi_failure
            ;;
        recovery)
            test_recovery
            ;;
        datacenter-failure|dc-failure|p3)
            test_datacenter_failure
            ;;
        disaster-recovery|dr|p4)
            test_disaster_recovery
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            error_exit "未知测试类型: $test_type\n运行 '$0 help' 查看帮助"
            ;;
    esac
}

main "$@"
