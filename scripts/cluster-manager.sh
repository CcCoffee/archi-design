#!/bin/bash

#######################################
# Redis Cluster 集群管理脚本
# 用途: 集群管理操作（故障转移、扩缩容、槽位迁移等）
# 使用: ./cluster-manager.sh [命令] [选项]
#######################################

set -e

# 获取脚本目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 加载公共函数
source "${SCRIPT_DIR}/common/utils.sh"

# 默认环境
ENV_TYPE="${ENV_TYPE:-local}"

# 加载对应环境配置
case $ENV_TYPE in
    local)
        source "${SCRIPT_DIR}/env/local.env"
        ;;
    production)
        source "${SCRIPT_DIR}/env/production.env"
        ;;
esac

# Redis 客户端参数
REDIS_CLI_ARGS=""
[ -n "$CLUSTER_PASSWORD" ] && REDIS_CLI_ARGS="-a $CLUSTER_PASSWORD --no-auth-warning"

#######################################
# 显示帮助信息
#######################################
show_help() {
    cat << EOF
Redis Cluster 集群管理脚本

用法: $0 <命令> [选项]

命令:
    status          查看集群状态
    nodes           查看节点列表
    slots           查看槽位分布
    info            查看集群信息
    meet            添加节点到集群
    forget          从集群移除节点
    replicate       设置主从复制关系
    failover        执行故障转移
    reshard         重新分配槽位
    rebalance       平衡槽位分布
    add-node        添加新节点
    del-node        删除节点
    check           检查集群健康状态
    fix             修复集群问题
    backup          备份集群数据
    restore         恢复集群数据
    help            显示帮助信息

选项:
    --env           环境类型 (local/production)
    --node          节点地址 (ip:port)
    --master        主节点地址
    --slave         从节点地址
    --slots         槽位数量
    --from          源节点 ID
    --to            目标节点 ID

示例:
    $0 status
    $0 failover --node 127.0.0.1:7003
    $0 reshard --from <node-id> --to <node-id> --slots 1000
    $0 add-node --new 127.0.0.1:7006 --master 127.0.0.1:7000

EOF
}

#######################################
# 获取第一个可用节点
# Outputs:
#   节点地址 (ip:port)
#######################################
get_first_node() {
    echo "${ALL_NODES[0]}"
}

#######################################
# 执行 Redis CLI 命令
# Arguments:
#   $@ - Redis CLI 参数
# Outputs:
#   Redis CLI 输出
#######################################
redis_cli() {
    redis-cli $REDIS_CLI_ARGS "$@"
}

#######################################
# 执行集群命令
# Arguments:
#   $@ - 集群命令参数
# Outputs:
#   集群命令输出
#######################################
cluster_exec() {
    local node=$(get_first_node)
    local host=$(echo $node | cut -d: -f1)
    local port=$(echo $node | cut -d: -f2)
    
    redis-cli -h $host -p $port $REDIS_CLI_ARGS "$@"
}

#######################################
# 查看集群状态
#######################################
show_status() {
    print_title "Redis Cluster 状态"
    
    local node=$(get_first_node)
    local host=$(echo $node | cut -d: -f1)
    local port=$(echo $node | cut -d: -f2)
    
    echo ""
    info "集群信息:"
    echo ""
    cluster_exec CLUSTER INFO
    echo ""
    
    info "节点概览:"
    echo ""
    
    # 解析节点信息
    local nodes_output=$(cluster_exec CLUSTER NODES)
    
    local table_data=("节点ID|地址|角色|状态|槽位|主节点ID")
    
    while IFS= read -r line; do
        local node_id=$(echo $line | awk '{print $1}')
        local addr=$(echo $line | awk '{print $2}')
        local flags=$(echo $line | awk '{print $3}')
        local master_id=$(echo $line | awk '{print $4}')
        local link_state=$(echo $line | awk '{print $8}')
        local slots=$(echo $line | awk '{for(i=9;i<=NF;i++) printf "%s ", $i}')
        
        # 判断角色
        local role="slave"
        if echo "$flags" | grep -q "master"; then
            role="master"
        fi
        
        # 判断状态
        local status="offline"
        if echo "$link_state" | grep -q "connected"; then
            status="online"
        fi
        
        # 处理主节点ID
        if [ "$master_id" == "-" ]; then
            master_id="-"
        fi
        
        table_data+=("${node_id:0:8}|$addr|$role|$status|${slots:-"-"}|$master_id")
    done <<< "$nodes_output"
    
    print_table "${table_data[@]}"
}

#######################################
# 查看节点列表
#######################################
show_nodes() {
    print_title "Redis Cluster 节点列表"
    
    cluster_exec CLUSTER NODES
}

#######################################
# 查看槽位分布
#######################################
show_slots() {
    print_title "Redis Cluster 槽位分布"
    
    local node=$(get_first_node)
    
    redis-cli --cluster info $node $REDIS_CLI_ARGS 2>/dev/null || {
        warn "无法获取槽位信息，请确保集群已创建"
    }
}

#######################################
# 查看集群信息
#######################################
show_info() {
    print_title "Redis Cluster 详细信息"
    
    local node=$(get_first_node)
    local host=$(echo $node | cut -d: -f1)
    local port=$(echo $node | cut -d: -f2)
    
    echo ""
    info "集群状态:"
    cluster_exec CLUSTER INFO
    echo ""
    
    info "节点统计:"
    echo ""
    
    for node in "${ALL_NODES[@]}"; do
        local h=$(echo $node | cut -d: -f1)
        local p=$(echo $node | cut -d: -f2)
        
        echo "--- 节点: ${h}:${p} ---"
        redis-cli -h $h -p $p $REDIS_CLI_ARGS INFO stats | grep -E "(total_connections|total_commands|instantaneous)"
        echo ""
    done
}

#######################################
# 添加节点到集群
# Arguments:
#   $1 - 新节点地址
#   $2 - 已有节点地址
#######################################
meet_node() {
    local new_node=$1
    local existing_node=$2
    
    if [ -z "$new_node" ] || [ -z "$existing_node" ]; then
        error_exit "用法: $0 meet --new <ip:port> --existing <ip:port>"
    fi
    
    print_title "添加节点到集群"
    
    local new_host=$(echo $new_node | cut -d: -f1)
    local new_port=$(echo $new_node | cut -d: -f2)
    local exist_host=$(echo $existing_node | cut -d: -f1)
    local exist_port=$(echo $existing_node | cut -d: -f2)
    
    log "INFO" "添加节点: ${new_node}"
    
    redis-cli -h $exist_host -p $exist_port $REDIS_CLI_ARGS CLUSTER MEET $new_host $new_port
    
    if [ $? -eq 0 ]; then
        success "节点添加成功"
    else
        error_exit "节点添加失败"
    fi
}

#######################################
# 从集群移除节点
# Arguments:
#   $1 - 节点 ID
#######################################
forget_node() {
    local node_id=$1
    
    if [ -z "$node_id" ]; then
        error_exit "用法: $0 forget --node-id <node-id>"
    fi
    
    print_title "从集群移除节点"
    
    log "INFO" "移除节点: ${node_id}"
    
    cluster_exec CLUSTER FORGET $node_id
    
    if [ $? -eq 0 ]; then
        success "节点移除成功"
    else
        error_exit "节点移除失败"
    fi
}

#######################################
# 设置主从复制关系
# Arguments:
#   $1 - 主节点 ID
#######################################
set_replicate() {
    local master_id=$1
    
    if [ -z "$master_id" ]; then
        error_exit "用法: $0 replicate --master-id <master-node-id> --slave <ip:port>"
    fi
    
    local slave_node=${SLAVE_NODE:-}
    
    if [ -z "$slave_node" ]; then
        error_exit "请指定从节点: --slave <ip:port>"
    fi
    
    local slave_host=$(echo $slave_node | cut -d: -f1)
    local slave_port=$(echo $slave_node | cut -d: -f2)
    
    print_title "设置主从复制"
    
    log "INFO" "设置 ${slave_node} 复制 ${master_id}"
    
    redis-cli -h $slave_host -p $slave_port $REDIS_CLI_ARGS CLUSTER REPLICATE $master_id
    
    if [ $? -eq 0 ]; then
        success "主从复制设置成功"
    else
        error_exit "主从复制设置失败"
    fi
}

#######################################
# 执行故障转移
# Arguments:
#   $1 - 从节点地址
#######################################
do_failover() {
    local slave_node=$1
    
    if [ -z "$slave_node" ]; then
        error_exit "用法: $0 failover --node <slave-ip:port>"
    fi
    
    local host=$(echo $slave_node | cut -d: -f1)
    local port=$(echo $slave_node | cut -d: -f2)
    
    print_title "执行故障转移"
    
    log "INFO" "在节点 ${slave_node} 上执行故障转移..."
    
    # 检查节点角色
    local role=$(redis-cli -h $host -p $port $REDIS_CLI_ARGS INFO replication | grep "role:" | cut -d: -f2 | tr -d '\r')
    
    if [ "$role" != "slave" ]; then
        error_exit "节点 ${slave_node} 不是从节点，无法执行故障转移"
    fi
    
    # 执行故障转移
    redis-cli -h $host -p $port $REDIS_CLI_ARGS CLUSTER FAILOVER
    
    if [ $? -eq 0 ]; then
        success "故障转移成功"
        sleep 2
        show_status
    else
        error_exit "故障转移失败"
    fi
}

#######################################
# 重新分配槽位
# Arguments:
#   $1 - 源节点 ID
#   $2 - 目标节点 ID
#   $3 - 槽位数量
#######################################
do_reshard() {
    local from_node=$1
    local to_node=$2
    local slots=$3
    
    if [ -z "$from_node" ] || [ -z "$to_node" ] || [ -z "$slots" ]; then
        error_exit "用法: $0 reshard --from <node-id> --to <node-id> --slots <count>"
    fi
    
    print_title "重新分配槽位"
    
    local node=$(get_first_node)
    
    log "INFO" "从 ${from_node} 迁移 ${slots} 个槽位到 ${to_node}"
    
    # 使用 redis-cli --cluster reshard
    # 注意：这是一个交互式命令，需要特殊处理
    redis-cli --cluster reshard $node $REDIS_CLI_ARGS \
        --cluster-from $from_node \
        --cluster-to $to_node \
        --cluster-slots $slots \
        --cluster-yes
    
    if [ $? -eq 0 ]; then
        success "槽位迁移成功"
        show_slots
    else
        error_exit "槽位迁移失败"
    fi
}

#######################################
# 平衡槽位分布
#######################################
do_rebalance() {
    print_title "平衡槽位分布"
    
    local node=$(get_first_node)
    
    log "INFO" "平衡集群槽位分布..."
    
    redis-cli --cluster rebalance $node $REDIS_CLI_ARGS --cluster-use-empty-masters
    
    if [ $? -eq 0 ]; then
        success "槽位平衡完成"
        show_slots
    else
        error_exit "槽位平衡失败"
    fi
}

#######################################
# 添加新节点
# Arguments:
#   $1 - 新节点地址
#   $2 - 集群中已有节点地址
#   $3 - 角色 (master/slave)
#   $4 - 主节点地址 (如果是 slave)
#######################################
add_node() {
    local new_node=$1
    local existing_node=$2
    local role=${3:-master}
    local master_node=$4
    
    if [ -z "$new_node" ] || [ -z "$existing_node" ]; then
        error_exit "用法: $0 add-node --new <ip:port> --existing <ip:port> [--role master|slave] [--master <ip:port>]"
    fi
    
    print_title "添加新节点到集群"
    
    log "INFO" "新节点: ${new_node}"
    log "INFO" "角色: ${role}"
    
    if [ "$role" == "slave" ]; then
        if [ -z "$master_node" ]; then
            error_exit "添加从节点时需要指定主节点: --master <ip:port>"
        fi
        
        redis-cli --cluster add-node $new_node $existing_node \
            --cluster-slave \
            --cluster-master-id $(get_node_id $master_node) \
            $REDIS_CLI_ARGS
    else
        redis-cli --cluster add-node $new_node $existing_node $REDIS_CLI_ARGS
    fi
    
    if [ $? -eq 0 ]; then
        success "节点添加成功"
        show_status
    else
        error_exit "节点添加失败"
    fi
}

#######################################
# 删除节点
# Arguments:
#   $1 - 节点地址
#######################################
del_node() {
    local node=$1
    
    if [ -z "$node" ]; then
        error_exit "用法: $0 del-node --node <ip:port>"
    fi
    
    print_title "从集群删除节点"
    
    local node_id=$(get_node_id $node)
    
    if [ -z "$node_id" ]; then
        error_exit "无法获取节点 ID: $node"
    fi
    
    log "INFO" "删除节点: ${node} (ID: ${node_id})"
    
    if ! confirm "确定要删除节点 ${node} 吗?"; then
        info "操作已取消"
        exit 0
    fi
    
    # 先清空槽位（如果是主节点）
    local role=$(get_redis_role $(echo $node | cut -d: -f1) $(echo $node | cut -d: -f2))
    
    if [ "$role" == "master" ]; then
        warn "节点是主节点，需要先迁移槽位"
        info "请使用 reshard 命令迁移槽位后再删除"
        exit 1
    fi
    
    redis-cli --cluster del-node $node $node_id $REDIS_CLI_ARGS
    
    if [ $? -eq 0 ]; then
        success "节点删除成功"
        show_status
    else
        error_exit "节点删除失败"
    fi
}

#######################################
# 获取节点 ID
# Arguments:
#   $1 - 节点地址
# Outputs:
#   节点 ID
#######################################
get_node_id() {
    local node=$1
    local host=$(echo $node | cut -d: -f1)
    local port=$(echo $node | cut -d: -f2)
    
    redis-cli -h $host -p $port $REDIS_CLI_ARGS CLUSTER MYID 2>/dev/null
}

#######################################
# 检查集群健康状态
#######################################
check_cluster() {
    print_title "检查集群健康状态"
    
    local node=$(get_first_node)
    
    log "INFO" "检查集群状态..."
    
    redis-cli --cluster check $node $REDIS_CLI_ARGS
    
    echo ""
    info "详细检查:"
    echo ""
    
    # 检查每个节点
    for node in "${ALL_NODES[@]}"; do
        local host=$(echo $node | cut -d: -f1)
        local port=$(echo $node | cut -d: -f2)
        
        echo "--- 节点: ${host}:${port} ---"
        
        # 检查连接
        if redis-cli -h $host -p $port $REDIS_CLI_ARGS ping &>/dev/null; then
            success "连接正常"
        else
            error "连接失败"
            continue
        fi
        
        # 检查复制状态
        local repl_info=$(redis-cli -h $host -p $port $REDIS_CLI_ARGS INFO replication)
        local role=$(echo "$repl_info" | grep "role:" | cut -d: -f2 | tr -d '\r')
        
        if [ "$role" == "slave" ]; then
            local master_link=$(echo "$repl_info" | grep "master_link_status:" | cut -d: -f2 | tr -d '\r')
            if [ "$master_link" == "up" ]; then
                success "主从复制正常"
            else
                error "主从复制异常"
            fi
        fi
        
        # 检查持久化
        local aof_enabled=$(redis-cli -h $host -p $port $REDIS_CLI_ARGS CONFIG GET appendonly | tail -1)
        local rdb_last_save=$(redis-cli -h $host -p $port $REDIS_CLI_ARGS LASTSAVE)
        
        echo "AOF: $aof_enabled"
        echo "RDB Last Save: $(date -d @$rdb_last_save '+%Y-%m-%d %H:%M:%S')"
        echo ""
    done
}

#######################################
# 修复集群问题
#######################################
fix_cluster() {
    print_title "修复集群问题"
    
    local node=$(get_first_node)
    
    warn "此操作可能修改集群数据，请确保已备份"
    
    if ! confirm "是否继续修复?"; then
        info "操作已取消"
        exit 0
    fi
    
    redis-cli --cluster fix $node $REDIS_CLI_ARGS
    
    if [ $? -eq 0 ]; then
        success "集群修复完成"
        check_cluster
    else
        error_exit "集群修复失败"
    fi
}

#######################################
# 备份集群数据
#######################################
backup_cluster() {
    print_title "备份集群数据"
    
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_dir="${BACKUP_DIR:-./backups}/${timestamp}"
    
    ensure_dir "$backup_dir"
    
    for node in "${ALL_NODES[@]}"; do
        local host=$(echo $node | cut -d: -f1)
        local port=$(echo $node | cut -d: -f2)
        
        log "INFO" "备份节点: ${host}:${port}"
        
        # 触发 RDB 快照
        redis-cli -h $host -p $port $REDIS_CLI_ARGS BGSAVE
        
        # 等待快照完成
        sleep 2
        
        # 创建节点备份目录
        local node_backup="${backup_dir}/${host}_${port}"
        ensure_dir "$node_backup"
        
        # 获取 RDB 文件路径
        local rdb_file=$(redis-cli -h $host -p $port $REDIS_CLI_ARGS CONFIG GET dir | tail -1)
        local rdb_name=$(redis-cli -h $host -p $port $REDIS_CLI_ARGS CONFIG GET dbfilename | tail -1)
        
        # 复制备份文件（如果是远程节点，需要其他方式）
        if [ "$host" == "127.0.0.1" ] || [ "$host" == "localhost" ]; then
            cp "${rdb_file}/${rdb_name}" "${node_backup}/dump.rdb" 2>/dev/null || warn "无法复制 RDB 文件"
        else
            warn "远程节点备份需要配置 SSH 或其他传输方式"
        fi
        
        # 保存节点信息
        redis-cli -h $host -p $port $REDIS_CLI_ARGS CLUSTER NODES > "${node_backup}/nodes.conf"
        redis-cli -h $host -p $port $REDIS_CLI_ARGS INFO > "${node_backup}/info.txt"
    done
    
    # 压缩备份
    local parent_dir=$(dirname "$backup_dir")
    cd "$parent_dir"
    tar czf "${timestamp}.tar.gz" "$timestamp"
    rm -rf "$timestamp"
    
    success "备份完成: ${parent_dir}/${timestamp}.tar.gz"
}

#######################################
# 解析命令行参数
#######################################
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --env)
                ENV_TYPE="$2"
                shift 2
                ;;
            --node)
                NODE_ADDR="$2"
                shift 2
                ;;
            --new)
                NEW_NODE="$2"
                shift 2
                ;;
            --existing)
                EXISTING_NODE="$2"
                shift 2
                ;;
            --master)
                MASTER_NODE="$2"
                shift 2
                ;;
            --slave)
                SLAVE_NODE="$2"
                shift 2
                ;;
            --master-id)
                MASTER_ID="$2"
                shift 2
                ;;
            --node-id)
                NODE_ID="$2"
                shift 2
                ;;
            --from)
                FROM_NODE="$2"
                shift 2
                ;;
            --to)
                TO_NODE="$2"
                shift 2
                ;;
            --slots)
                SLOTS_COUNT="$2"
                shift 2
                ;;
            --role)
                NODE_ROLE="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done
}

#######################################
# 主函数
#######################################
main() {
    local command=${1:-help}
    shift || true
    
    parse_args "$@"
    
    # 重新加载环境配置
    case $ENV_TYPE in
        local)
            source "${SCRIPT_DIR}/env/local.env"
            ;;
        production)
            source "${SCRIPT_DIR}/env/production.env"
            ;;
    esac
    
    # 更新 Redis CLI 参数
    REDIS_CLI_ARGS=""
    [ -n "$CLUSTER_PASSWORD" ] && REDIS_CLI_ARGS="-a $CLUSTER_PASSWORD --no-auth-warning"
    
    case $command in
        status)
            show_status
            ;;
        nodes)
            show_nodes
            ;;
        slots)
            show_slots
            ;;
        info)
            show_info
            ;;
        meet)
            meet_node "$NEW_NODE" "$EXISTING_NODE"
            ;;
        forget)
            forget_node "$NODE_ID"
            ;;
        replicate)
            set_replicate "$MASTER_ID"
            ;;
        failover)
            do_failover "$NODE_ADDR"
            ;;
        reshard)
            do_reshard "$FROM_NODE" "$TO_NODE" "$SLOTS_COUNT"
            ;;
        rebalance)
            do_rebalance
            ;;
        add-node)
            add_node "$NEW_NODE" "$EXISTING_NODE" "$NODE_ROLE" "$MASTER_NODE"
            ;;
        del-node)
            del_node "$NODE_ADDR"
            ;;
        check)
            check_cluster
            ;;
        fix)
            fix_cluster
            ;;
        backup)
            backup_cluster
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
