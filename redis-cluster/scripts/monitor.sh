#!/bin/bash

#######################################
# Redis Cluster 监控脚本
# 用途: 集群健康检查、性能监控、告警通知
# 使用: ./monitor.sh [命令] [选项]
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

# 监控阈值
MEMORY_WARNING_THRESHOLD=80
MEMORY_CRITICAL_THRESHOLD=90
CONNECTION_WARNING_THRESHOLD=80
CONNECTION_CRITICAL_THRESHOLD=90
LATENCY_WARNING_THRESHOLD=10
LATENCY_CRITICAL_THRESHOLD=50
REPLICATION_LAG_THRESHOLD=10

# Redis 客户端参数
REDIS_CLI_ARGS=""
[ -n "$CLUSTER_PASSWORD" ] && REDIS_CLI_ARGS="-a $CLUSTER_PASSWORD --no-auth-warning"

#######################################
# 显示帮助信息
#######################################
show_help() {
    cat << EOF
Redis Cluster 监控脚本

用法: $0 <命令> [选项]

命令:
    health          健康检查
    metrics         收集性能指标
    watch           实时监控
    alert           检查并发送告警
    report          生成监控报告
    top             实时显示 Top 命令
    slowlog         查看慢查询日志
    memory          内存使用分析
    connections     连接分析
    replication     复制状态检查
    help            显示帮助信息

选项:
    --env           环境类型 (local/production)
    --interval      监控间隔 (秒)
    --output        输出格式 (text/json)
    --threshold     自定义阈值

示例:
    $0 health
    $0 watch --interval 5
    $0 alert
    $0 report --output json

EOF
}

#######################################
# 执行 Redis CLI 命令
# Arguments:
#   $1 - 主机
#   $2 - 端口
#   $3 - 命令
# Outputs:
#   Redis CLI 输出
#######################################
redis_exec() {
    local host=$1
    local port=$2
    local cmd=$3
    
    redis-cli -h $host -p $port $REDIS_CLI_ARGS $cmd 2>/dev/null
}

#######################################
# 健康检查
#######################################
health_check() {
    print_title "Redis Cluster 健康检查"
    
    local issues=0
    local warnings=0
    
    # 1. 检查集群状态
    echo ""
    info "1. 集群状态检查"
    echo ""
    
    local first_node=${ALL_NODES[0]}
    local host=$(echo $first_node | cut -d: -f1)
    local port=$(echo $first_node | cut -d: -f2)
    
    local cluster_state=$(redis_exec $host $port "CLUSTER INFO" | grep "cluster_state:" | cut -d: -f2 | tr -d '\r')
    local cluster_slots_ok=$(redis_exec $host $port "CLUSTER INFO" | grep "cluster_slots_ok:" | cut -d: -f2 | tr -d '\r')
    local cluster_slots_assigned=$(redis_exec $host $port "CLUSTER INFO" | grep "cluster_slots_assigned:" | cut -d: -f2 | tr -d '\r')
    local cluster_known_nodes=$(redis_exec $host $port "CLUSTER INFO" | grep "cluster_known_nodes:" | cut -d: -f2 | tr -d '\r')
    
    if [ "$cluster_state" == "ok" ]; then
        success "集群状态: OK"
    else
        error "集群状态: FAIL"
        ((issues++))
    fi
    
    echo "  槽位状态: ${cluster_slots_ok}/${cluster_slots_assigned} 正常"
    echo "  已知节点: ${cluster_known_nodes}"
    
    # 2. 检查节点连接
    echo ""
    info "2. 节点连接检查"
    echo ""
    
    local table_data=("节点|地址|状态|响应时间")
    
    for node in "${ALL_NODES[@]}"; do
        local h=$(echo $node | cut -d: -f1)
        local p=$(echo $node | cut -d: -f2)
        
        local start_time=$(date +%s%N)
        local ping_result=$(redis_exec $h $p "PING" 2>/dev/null)
        local end_time=$(date +%s%N)
        
        local latency=$(( (end_time - start_time) / 1000000 ))
        
        if [ "$ping_result" == "PONG" ]; then
            local status="正常"
            table_data+=("${h}:${p}|${h}:${p}|${status}|${latency}ms")
        else
            local status="异常"
            table_data+=("${h}:${p}|${h}:${p}|${status}|N/A")
            ((issues++))
        fi
    done
    
    print_table "${table_data[@]}"
    
    # 3. 检查主从复制
    echo ""
    info "3. 主从复制检查"
    echo ""
    
    for node in "${ALL_NODES[@]}"; do
        local h=$(echo $node | cut -d: -f1)
        local p=$(echo $node | cut -d: -f2)
        
        local role=$(redis_exec $h $p "INFO replication" | grep "role:" | cut -d: -f2 | tr -d '\r')
        
        if [ "$role" == "slave" ]; then
            local master_link=$(redis_exec $h $p "INFO replication" | grep "master_link_status:" | cut -d: -f2 | tr -d '\r')
            local master_host=$(redis_exec $h $p "INFO replication" | grep "master_host:" | cut -d: -f2 | tr -d '\r')
            local master_port=$(redis_exec $h $p "INFO replication" | grep "master_port:" | cut -d: -f2 | tr -d '\r')
            
            if [ "$master_link" == "up" ]; then
                success "从节点 ${h}:${p} -> 主节点 ${master_host}:${master_port} 复制正常"
            else
                error "从节点 ${h}:${p} -> 主节点 ${master_host}:${master_port} 复制异常"
                ((issues++))
            fi
        fi
    done
    
    # 4. 检查内存使用
    echo ""
    info "4. 内存使用检查"
    echo ""
    
    local mem_table=("节点|已用内存|最大内存|使用率|状态")
    
    for node in "${ALL_NODES[@]}"; do
        local h=$(echo $node | cut -d: -f1)
        local p=$(echo $node | cut -d: -f2)
        
        local used_memory=$(redis_exec $h $p "INFO memory" | grep "used_memory:" | head -1 | cut -d: -f2 | tr -d '\r')
        local maxmemory=$(redis_exec $h $p "CONFIG GET maxmemory" | tail -1)
        
        if [ "$maxmemory" -gt 0 ]; then
            local usage=$(( used_memory * 100 / maxmemory ))
            local used_human=$(redis_exec $h $p "INFO memory" | grep "used_memory_human:" | cut -d: -f2 | tr -d '\r')
            local max_human="${maxmemory}"
            
            if [ $usage -ge $MEMORY_CRITICAL_THRESHOLD ]; then
                mem_table+=("${h}:${p}|${used_human}|${max_human}|${usage}%|严重")
                ((issues++))
            elif [ $usage -ge $MEMORY_WARNING_THRESHOLD ]; then
                mem_table+=("${h}:${p}|${used_human}|${max_human}|${usage}%|警告")
                ((warnings++))
            else
                mem_table+=("${h}:${p}|${used_human}|${max_human}|${usage}%|正常")
            fi
        else
            mem_table+=("${h}:${p}|N/A|无限制|N/A|正常")
        fi
    done
    
    print_table "${mem_table[@]}"
    
    # 5. 检查持久化
    echo ""
    info "5. 持久化状态检查"
    echo ""
    
    for node in "${ALL_NODES[@]}"; do
        local h=$(echo $node | cut -d: -f1)
        local p=$(echo $node | cut -d: -f2)
        
        echo "--- 节点: ${h}:${p} ---"
        
        # RDB 状态
        local rdb_last_save=$(redis_exec $h $p "LASTSAVE")
        local rdb_changes=$(redis_exec $h $p "INFO persistence" | grep "rdb_changes_since_last_save:" | cut -d: -f2 | tr -d '\r')
        local rdb_bgsave=$(redis_exec $h $p "INFO persistence" | grep "rdb_last_bgsave_status:" | cut -d: -f2 | tr -d '\r')
        
        echo "  RDB 最后保存: $(date -d @$rdb_last_save '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo $rdb_last_save)"
        echo "  RDB 变更次数: ${rdb_changes}"
        echo "  RDB 状态: ${rdb_bgsave}"
        
        # AOF 状态
        local aof_enabled=$(redis_exec $h $p "INFO persistence" | grep "aof_enabled:" | cut -d: -f2 | tr -d '\r')
        local aof_rewrite=$(redis_exec $h $p "INFO persistence" | grep "aof_last_rewrite_time_sec:" | cut -d: -f2 | tr -d '\r')
        
        echo "  AOF 启用: ${aof_enabled}"
        echo "  AOF 最后重写耗时: ${aof_rewrite}s"
        echo ""
    done
    
    # 总结
    echo ""
    print_separator
    echo ""
    
    if [ $issues -eq 0 ] && [ $warnings -eq 0 ]; then
        success "健康检查通过，所有指标正常"
    elif [ $issues -eq 0 ]; then
        warn "健康检查完成，发现 ${warnings} 个警告"
    else
        error "健康检查完成，发现 ${issues} 个问题，${warnings} 个警告"
    fi
}

#######################################
# 收集性能指标
#######################################
collect_metrics() {
    print_title "Redis Cluster 性能指标"
    
    local output_format=${OUTPUT_FORMAT:-text}
    local metrics_json="{"
    metrics_json+="\"timestamp\":\"$(date -Iseconds)\","
    metrics_json+="\"environment\":\"${ENV_TYPE}\","
    metrics_json+="\"nodes\":["
    
    local first_node=true
    
    for node in "${ALL_NODES[@]}"; do
        local h=$(echo $node | cut -d: -f1)
        local p=$(echo $node | cut -d: -f2)
        
        if [ "$first_node" = true ]; then
            first_node=false
        else
            metrics_json+=","
        fi
        
        metrics_json+="{"
        metrics_json+="\"host\":\"${h}\","
        metrics_json+="\"port\":${p},"
        
        # 基本信息
        local role=$(redis_exec $h $p "INFO replication" | grep "role:" | cut -d: -f2 | tr -d '\r')
        metrics_json+="\"role\":\"${role}\","
        
        # 连接数
        local connected_clients=$(redis_exec $h $p "INFO clients" | grep "connected_clients:" | cut -d: -f2 | tr -d '\r')
        local maxclients=$(redis_exec $h $p "CONFIG GET maxclients" | tail -1)
        metrics_json+="\"connected_clients\":${connected_clients},"
        metrics_json+="\"maxclients\":${maxclients},"
        
        # 内存
        local used_memory=$(redis_exec $h $p "INFO memory" | grep "used_memory:" | head -1 | cut -d: -f2 | tr -d '\r')
        local used_memory_rss=$(redis_exec $h $p "INFO memory" | grep "used_memory_rss:" | cut -d: -f2 | tr -d '\r')
        local maxmemory=$(redis_exec $h $p "CONFIG GET maxmemory" | tail -1)
        metrics_json+="\"used_memory\":${used_memory},"
        metrics_json+="\"used_memory_rss\":${used_memory_rss},"
        metrics_json+="\"maxmemory\":${maxmemory},"
        
        # 命令统计
        local total_commands=$(redis_exec $h $p "INFO stats" | grep "total_commands_processed:" | cut -d: -f2 | tr -d '\r')
        local instantaneous_ops=$(redis_exec $h $p "INFO stats" | grep "instantaneous_ops_per_sec:" | cut -d: -f2 | tr -d '\r')
        metrics_json+="\"total_commands_processed\":${total_commands},"
        metrics_json+="\"instantaneous_ops_per_sec\":${instantaneous_ops},"
        
        # 键数量
        local keys=$(redis_exec $h $p "DBSIZE" | cut -d: -f2 | tr -d '\r')
        metrics_json+="\"keys\":${keys},"
        
        # 网络
        local total_net_input=$(redis_exec $h $p "INFO stats" | grep "total_net_input_bytes:" | cut -d: -f2 | tr -d '\r')
        local total_net_output=$(redis_exec $h $p "INFO stats" | grep "total_net_output_bytes:" | cut -d: -f2 | tr -d '\r')
        metrics_json+="\"total_net_input_bytes\":${total_net_input},"
        metrics_json+="\"total_net_output_bytes\":${total_net_output}"
        
        metrics_json+="}"
    done
    
    metrics_json+="]}"
    
    if [ "$output_format" == "json" ]; then
        echo "$metrics_json"
    else
        # 文本格式输出
        echo ""
        
        for node in "${ALL_NODES[@]}"; do
            local h=$(echo $node | cut -d: -f1)
            local p=$(echo $node | cut -d: -f2)
            
            echo "=== 节点: ${h}:${p} ==="
            echo ""
            
            local role=$(redis_exec $h $p "INFO replication" | grep "role:" | cut -d: -f2 | tr -d '\r')
            echo "角色: ${role}"
            
            local connected_clients=$(redis_exec $h $p "INFO clients" | grep "connected_clients:" | cut -d: -f2 | tr -d '\r')
            echo "连接数: ${connected_clients}"
            
            local used_memory_human=$(redis_exec $h $p "INFO memory" | grep "used_memory_human:" | cut -d: -f2 | tr -d '\r')
            echo "内存使用: ${used_memory_human}"
            
            local instantaneous_ops=$(redis_exec $h $p "INFO stats" | grep "instantaneous_ops_per_sec:" | cut -d: -f2 | tr -d '\r')
            echo "每秒操作数: ${instantaneous_ops}"
            
            local keys=$(redis_exec $h $p "DBSIZE" | cut -d: -f2 | tr -d '\r')
            echo "键数量: ${keys}"
            
            echo ""
        done
    fi
}

#######################################
# 实时监控
#######################################
watch_metrics() {
    local interval=${INTERVAL:-5}
    
    print_title "Redis Cluster 实时监控 (刷新间隔: ${interval}s)"
    
    while true; do
        clear
        echo "========================================"
        echo "  Redis Cluster 实时监控"
        echo "  时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "========================================"
        echo ""
        
        # 集群状态
        local first_node=${ALL_NODES[0]}
        local host=$(echo $first_node | cut -d: -f1)
        local port=$(echo $first_node | cut -d: -f2)
        
        local cluster_state=$(redis_exec $host $port "CLUSTER INFO" | grep "cluster_state:" | cut -d: -f2 | tr -d '\r')
        
        if [ "$cluster_state" == "ok" ]; then
            echo -e "集群状态: ${GREEN}正常${NC}"
        else
            echo -e "集群状态: ${RED}异常${NC}"
        fi
        
        echo ""
        
        # 节点状态表
        printf "%-20s %-8s %-12s %-10s %-10s\n" "节点" "角色" "连接数" "OPS/s" "内存"
        echo "--------------------------------------------------------------------"
        
        for node in "${ALL_NODES[@]}"; do
            local h=$(echo $node | cut -d: -f1)
            local p=$(echo $node | cut -d: -f2)
            
            local role=$(redis_exec $h $p "INFO replication" | grep "role:" | cut -d: -f2 | tr -d '\r')
            local clients=$(redis_exec $h $p "INFO clients" | grep "connected_clients:" | cut -d: -f2 | tr -d '\r')
            local ops=$(redis_exec $h $p "INFO stats" | grep "instantaneous_ops_per_sec:" | cut -d: -f2 | tr -d '\r')
            local mem=$(redis_exec $h $p "INFO memory" | grep "used_memory_human:" | cut -d: -f2 | tr -d '\r')
            
            printf "%-20s %-8s %-12s %-10s %-10s\n" "${h}:${p}" "${role}" "${clients}" "${ops}" "${mem}"
        done
        
        echo ""
        echo "按 Ctrl+C 退出"
        
        sleep $interval
    done
}

#######################################
# 告警检查
#######################################
check_alerts() {
    print_title "检查告警条件"
    
    local alerts=()
    
    for node in "${ALL_NODES[@]}"; do
        local h=$(echo $node | cut -d: -f1)
        local p=$(echo $node | cut -d: -f2)
        
        # 检查连接
        if ! redis_exec $h $p "PING" &>/dev/null; then
            alerts+=("CRITICAL: 节点 ${h}:${p} 无法连接")
            continue
        fi
        
        # 检查内存
        local used_memory=$(redis_exec $h $p "INFO memory" | grep "used_memory:" | head -1 | cut -d: -f2 | tr -d '\r')
        local maxmemory=$(redis_exec $h $p "CONFIG GET maxmemory" | tail -1)
        
        if [ "$maxmemory" -gt 0 ]; then
            local usage=$(( used_memory * 100 / maxmemory ))
            
            if [ $usage -ge $MEMORY_CRITICAL_THRESHOLD ]; then
                alerts+=("CRITICAL: 节点 ${h}:${p} 内存使用率 ${usage}% 超过临界阈值")
            elif [ $usage -ge $MEMORY_WARNING_THRESHOLD ]; then
                alerts+=("WARNING: 节点 ${h}:${p} 内存使用率 ${usage}% 超过警告阈值")
            fi
        fi
        
        # 检查主从复制
        local role=$(redis_exec $h $p "INFO replication" | grep "role:" | cut -d: -f2 | tr -d '\r')
        
        if [ "$role" == "slave" ]; then
            local master_link=$(redis_exec $h $p "INFO replication" | grep "master_link_status:" | cut -d: -f2 | tr -d '\r')
            
            if [ "$master_link" != "up" ]; then
                alerts+=("CRITICAL: 从节点 ${h}:${p} 主从复制断开")
            fi
        fi
    done
    
    # 集群状态检查
    local first_node=${ALL_NODES[0]}
    local host=$(echo $first_node | cut -d: -f1)
    local port=$(echo $first_node | cut -d: -f2)
    
    local cluster_state=$(redis_exec $host $port "CLUSTER INFO" | grep "cluster_state:" | cut -d: -f2 | tr -d '\r')
    
    if [ "$cluster_state" != "ok" ]; then
        alerts+=("CRITICAL: 集群状态异常")
    fi
    
    # 输出告警
    if [ ${#alerts[@]} -eq 0 ]; then
        success "没有发现告警"
        return 0
    else
        error "发现 ${#alerts[@]} 个告警:"
        echo ""
        for alert in "${alerts[@]}"; do
            echo "  - $alert"
        done
        
        # 发送告警通知（如果配置了 webhook）
        if [ -n "$ALERT_WEBHOOK" ]; then
            send_alert_notification "${alerts[@]}"
        fi
        
        return 1
    fi
}

#######################################
# 发送告警通知
# Arguments:
#   $@ - 告警消息列表
#######################################
send_alert_notification() {
    local messages=("$@")
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    log "INFO" "发送告警通知..."
    
    # 钉钉/企业微信 webhook 格式
    local payload=$(cat << EOF
{
    "msgtype": "markdown",
    "markdown": {
        "title": "Redis Cluster 告警",
        "text": "### Redis Cluster 告警\n\n**环境**: ${ENV_TYPE}\n**时间**: ${timestamp}\n\n**告警详情**:\n$(printf '- %s\n' "${messages[@]}")"
    }
}
EOF
)
    
    curl -s -X POST "$ALERT_WEBHOOK" \
        -H "Content-Type: application/json" \
        -d "$payload" &>/dev/null
    
    log "INFO" "告警通知已发送"
}

#######################################
# 生成监控报告
#######################################
generate_report() {
    local output_format=${OUTPUT_FORMAT:-text}
    local report_file="/tmp/redis-cluster-report-$(date +%Y%m%d_%H%M%S).${output_format}"
    
    print_title "生成监控报告"
    
    if [ "$output_format" == "json" ]; then
        collect_metrics > "$report_file"
    else
        {
            echo "Redis Cluster 监控报告"
            echo "====================="
            echo ""
            echo "生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
            echo "环境: ${ENV_TYPE}"
            echo ""
            
            health_check
            echo ""
            collect_metrics
        } > "$report_file"
    fi
    
    success "报告已生成: $report_file"
    echo "$report_file"
}

#######################################
# 查看慢查询日志
#######################################
show_slowlog() {
    print_title "慢查询日志"
    
    local limit=${1:-10}
    
    for node in "${ALL_NODES[@]}"; do
        local h=$(echo $node | cut -d: -f1)
        local p=$(echo $node | cut -d: -f2)
        
        echo "=== 节点: ${h}:${p} ==="
        echo ""
        
        redis_exec $h $p "SLOWLOG GET $limit"
        echo ""
    done
}

#######################################
# 内存分析
#######################################
analyze_memory() {
    print_title "内存使用分析"
    
    for node in "${ALL_NODES[@]}"; do
        local h=$(echo $node | cut -d: -f1)
        local p=$(echo $node | cut -d: -f2)
        
        echo "=== 节点: ${h}:${p} ==="
        echo ""
        
        echo "内存统计:"
        redis_exec $h $p "MEMORY STATS"
        echo ""
        
        echo "内存使用详情:"
        redis_exec $h $p "INFO memory" | grep -E "(used_memory|memory_fragmentation|maxmemory)"
        echo ""
    done
}

#######################################
# 连接分析
#######################################
analyze_connections() {
    print_title "连接分析"
    
    for node in "${ALL_NODES[@]}"; do
        local h=$(echo $node | cut -d: -f1)
        local p=$(echo $node | cut -d: -f2)
        
        echo "=== 节点: ${h}:${p} ==="
        echo ""
        
        echo "客户端列表:"
        redis_exec $h $p "CLIENT LIST" | head -20
        echo ""
        
        echo "连接统计:"
        redis_exec $h $p "INFO clients"
        echo ""
    done
}

#######################################
# 复制状态检查
#######################################
check_replication() {
    print_title "复制状态检查"
    
    for node in "${ALL_NODES[@]}"; do
        local h=$(echo $node | cut -d: -f1)
        local p=$(echo $node | cut -d: -f2)
        
        echo "=== 节点: ${h}:${p} ==="
        echo ""
        
        redis_exec $h $p "INFO replication"
        echo ""
    done
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
            --interval)
                INTERVAL="$2"
                shift 2
                ;;
            --output)
                OUTPUT_FORMAT="$2"
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
    local command=${1:-health}
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
        health)
            health_check
            ;;
        metrics)
            collect_metrics
            ;;
        watch)
            watch_metrics
            ;;
        alert)
            check_alerts
            ;;
        report)
            generate_report
            ;;
        slowlog)
            show_slowlog "$@"
            ;;
        memory)
            analyze_memory
            ;;
        connections)
            analyze_connections
            ;;
        replication)
            check_replication
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
