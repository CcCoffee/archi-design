#!/bin/bash

#######################################
# Redis Cluster 测试脚本
# 用途: 测试集群功能（连接、读写、故障转移等）
# 使用: ./test-cluster.sh [测试类型]
#######################################

set -e

# 获取脚本目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 加载公共函数
source "${SCRIPT_DIR}/common/utils.sh"

# 加载环境配置
ENV_TYPE="${ENV_TYPE:-local}"
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

# 测试结果统计
TESTS_PASSED=0
TESTS_FAILED=0

#######################################
# 显示帮助信息
#######################################
show_help() {
    cat << EOF
Redis Cluster 测试脚本

用法: $0 [测试类型]

测试类型:
    all         运行所有测试
    connect     连接测试
    readwrite   读写测试
    cluster     集群功能测试
    failover    故障转移测试
    replication 复制测试
    performance 性能测试
    help        显示帮助

选项:
    --env       环境类型 (local/production)
    --nodes     节点数量
    --keys      测试键数量
    --size      数据大小

示例:
    $0 all
    $0 connect
    $0 performance --keys 10000

EOF
}

#######################################
# 记录测试结果
# Arguments:
#   $1 - 测试名称
#   $2 - 结果 (pass/fail)
#   $3 - 消息
#######################################
test_result() {
    local name=$1
    local result=$2
    local message=$3
    
    if [ "$result" == "pass" ]; then
        success "[PASS] ${name}: ${message}"
        TESTS_PASSED=$((TESTS_PASSED + 1))
    else
        error "[FAIL] ${name}: ${message}"
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

#######################################
# 连接测试
#######################################
test_connectivity() {
    print_title "连接测试"
    
    for node in "${ALL_NODES[@]}"; do
        local host=$(echo $node | cut -d: -f1)
        local port=$(echo $node | cut -d: -f2)
        
        local result=$(redis-cli -h $host -p $port $REDIS_CLI_ARGS PING 2>/dev/null)
        
        if [ "$result" == "PONG" ]; then
            test_result "连接测试" "pass" "节点 ${host}:${port} 连接正常"
        else
            test_result "连接测试" "fail" "节点 ${host}:${port} 连接失败"
        fi
    done
}

#######################################
# 读写测试
#######################################
test_readwrite() {
    print_title "读写测试"
    
    local test_keys=${TEST_KEYS:-100}
    local test_size=${TEST_SIZE:-1024}
    local first_node=${ALL_NODES[0]}
    local host=$(echo $first_node | cut -d: -f1)
    local port=$(echo $first_node | cut -d: -f2)
    
    # 生成测试数据
    local test_data=$(head -c $test_size /dev/urandom | base64)
    
    info "写入 ${test_keys} 个键..."
    
    local write_success=0
    local write_fail=0
    
    for i in $(seq 1 $test_keys); do
        local key="test:rw:${i}"
        
        if redis-cli -c -h $host -p $port $REDIS_CLI_ARGS SET "$key" "$test_data" &>/dev/null; then
            ((write_success++))
        else
            ((write_fail++))
        fi
    done
    
    if [ $write_fail -eq 0 ]; then
        test_result "写入测试" "pass" "成功写入 ${write_success} 个键"
    else
        test_result "写入测试" "fail" "写入 ${write_success} 成功, ${write_fail} 失败"
    fi
    
    info "读取 ${test_keys} 个键..."
    
    local read_success=0
    local read_fail=0
    
    for i in $(seq 1 $test_keys); do
        local key="test:rw:${i}"
        
        local value=$(redis-cli -c -h $host -p $port $REDIS_CLI_ARGS GET "$key" 2>/dev/null)
        
        if [ -n "$value" ]; then
            ((read_success++))
        else
            ((read_fail++))
        fi
    done
    
    if [ $read_fail -eq 0 ]; then
        test_result "读取测试" "pass" "成功读取 ${read_success} 个键"
    else
        test_result "读取测试" "fail" "读取 ${read_success} 成功, ${read_fail} 失败"
    fi
    
    # 清理测试数据
    info "清理测试数据..."
    for i in $(seq 1 $test_keys); do
        redis-cli -c -h $host -p $port $REDIS_CLI_ARGS DEL "test:rw:${i}" &>/dev/null
    done
}

#######################################
# 集群功能测试
#######################################
test_cluster() {
    print_title "集群功能测试"
    
    local first_node=${ALL_NODES[0]}
    local host=$(echo $first_node | cut -d: -f1)
    local port=$(echo $first_node | cut -d: -f2)
    
    # 测试集群状态
    local cluster_state=$(redis-cli -h $host -p $port $REDIS_CLI_ARGS CLUSTER INFO 2>/dev/null | grep "cluster_state:" | cut -d: -f2 | tr -d '\r')
    
    if [ "$cluster_state" == "ok" ]; then
        test_result "集群状态" "pass" "集群状态正常"
    else
        test_result "集群状态" "fail" "集群状态异常: ${cluster_state}"
    fi
    
    # 测试槽位覆盖
    local slots_ok=$(redis-cli -h $host -p $port $REDIS_CLI_ARGS CLUSTER INFO 2>/dev/null | grep "cluster_slots_ok:" | cut -d: -f2 | tr -d '\r')
    local slots_assigned=$(redis-cli -h $host -p $port $REDIS_CLI_ARGS CLUSTER INFO 2>/dev/null | grep "cluster_slots_assigned:" | cut -d: -f2 | tr -d '\r')
    
    if [ "$slots_ok" == "$slots_assigned" ] && [ "$slots_ok" == "16384" ]; then
        test_result "槽位覆盖" "pass" "所有槽位已覆盖 (${slots_ok}/16384)"
    else
        test_result "槽位覆盖" "fail" "槽位覆盖不完整 (${slots_ok}/${slots_assigned})"
    fi
    
    # 测试节点数量
    local known_nodes=$(redis-cli -h $host -p $port $REDIS_CLI_ARGS CLUSTER INFO 2>/dev/null | grep "cluster_known_nodes:" | cut -d: -f2 | tr -d '\r')
    
    if [ "$known_nodes" == "${#ALL_NODES[@]}" ]; then
        test_result "节点数量" "pass" "节点数量正确 (${known_nodes})"
    else
        test_result "节点数量" "fail" "节点数量不匹配 (期望 ${#ALL_NODES[@]}, 实际 ${known_nodes})"
    fi
    
    # 测试跨节点访问
    info "测试跨节点访问..."
    
    local cross_node_success=true
    
    # 在不同槽位写入数据
    for i in {1..10}; do
        local key="test:cluster:cross:${i}"
        
        if ! redis-cli -c -h $host -p $port $REDIS_CLI_ARGS SET "$key" "value${i}" &>/dev/null; then
            cross_node_success=false
            break
        fi
    done
    
    if $cross_node_success; then
        test_result "跨节点访问" "pass" "跨节点访问正常"
    else
        test_result "跨节点访问" "fail" "跨节点访问失败"
    fi
    
    # 清理
    for i in {1..10}; do
        redis-cli -c -h $host -p $port $REDIS_CLI_ARGS DEL "test:cluster:cross:${i}" &>/dev/null
    done
}

#######################################
# 复制测试
#######################################
test_replication() {
    print_title "复制测试"
    
    local replication_ok=true
    
    for node in "${ALL_NODES[@]}"; do
        local host=$(echo $node | cut -d: -f1)
        local port=$(echo $node | cut -d: -f2)
        
        local role=$(redis-cli -h $host -p $port $REDIS_CLI_ARGS INFO replication 2>/dev/null | grep "role:" | cut -d: -f2 | tr -d '\r')
        
        if [ "$role" == "slave" ]; then
            local master_link=$(redis-cli -h $host -p $port $REDIS_CLI_ARGS INFO replication 2>/dev/null | grep "master_link_status:" | cut -d: -f2 | tr -d '\r')
            
            if [ "$master_link" == "up" ]; then
                test_result "复制状态" "pass" "从节点 ${host}:${port} 复制正常"
            else
                test_result "复制状态" "fail" "从节点 ${host}:${port} 复制断开"
                replication_ok=false
            fi
        fi
    done
    
    # 测试数据一致性
    info "测试数据一致性..."
    
    local first_master=${DC_A_NODES[0]}
    local master_host=$(echo $first_master | cut -d: -f1)
    local master_port=$(echo $first_master | cut -d: -f2)
    
    # 使用 hash tag 确保数据在同一槽位
    local test_key="test:replication:{test}:$(date +%s)"
    local test_value="replication-test-value"
    
    redis-cli -c -h $master_host -p $master_port $REDIS_CLI_ARGS SET "$test_key" "$test_value" &>/dev/null
    
    sleep 1
    
    # 使用集群客户端读取（会自动路由到正确的节点）
    local read_value=$(redis-cli -c -h $master_host -p $master_port $REDIS_CLI_ARGS GET "$test_key" 2>/dev/null)
    
    if [ "$read_value" == "$test_value" ]; then
        test_result "数据一致性" "pass" "数据读写一致"
    else
        test_result "数据一致性" "fail" "数据读写不一致"
    fi
    
    # 清理
    redis-cli -c -h $master_host -p $master_port $REDIS_CLI_ARGS DEL "$test_key" &>/dev/null
}

#######################################
# 故障转移测试
#######################################
test_failover() {
    print_title "故障转移测试"
    
    warn "故障转移测试需要手动操作"
    info "请使用以下命令测试故障转移:"
    echo ""
    echo "  1. 模拟主节点故障:"
    echo "     redis-cli -p <master-port> DEBUG SEGFAULT"
    echo ""
    echo "  2. 或使用集群管理脚本:"
    echo "     ./cluster-manager.sh failover --node <slave-ip:port>"
    echo ""
    echo "  3. 观察从节点是否成功提升为主节点"
    echo ""
}

#######################################
# 性能测试
#######################################
test_performance() {
    print_title "性能测试"
    
    local first_node=${ALL_NODES[0]}
    local host=$(echo $first_node | cut -d: -f1)
    local port=$(echo $first_node | cut -d: -f2)
    
    local test_keys=${TEST_KEYS:-10000}
    local test_size=${TEST_SIZE:-256}
    
    info "运行 redis-benchmark..."
    info "键数量: ${test_keys}, 数据大小: ${test_size} bytes"
    echo ""
    
    # SET 性能
    echo "--- SET 性能 ---"
    redis-benchmark -h $host -p $port $REDIS_CLI_ARGS -t set -n $test_keys -d $test_size -q
    
    echo ""
    
    # GET 性能
    echo "--- GET 性能 ---"
    redis-benchmark -h $host -p $port $REDIS_CLI_ARGS -t get -n $test_keys -d $test_size -q
    
    echo ""
    
    # 混合读写性能
    echo "--- 混合读写性能 ---"
    redis-benchmark -h $host -p $port $REDIS_CLI_ARGS -t set,get -n $test_keys -d $test_size -q
    
    echo ""
    
    # MSET 性能
    echo "--- MSET 性能 ---"
    redis-benchmark -h $host -p $port $REDIS_CLI_ARGS -t mset -n $test_keys -d $test_size -q
}

#######################################
# 显示测试总结
#######################################
show_summary() {
    print_title "测试总结"
    
    local total=$((TESTS_PASSED + TESTS_FAILED))
    
    echo ""
    echo "测试总数: ${total}"
    echo -e "通过: ${GREEN}${TESTS_PASSED}${NC}"
    echo -e "失败: ${RED}${TESTS_FAILED}${NC}"
    echo ""
    
    if [ $TESTS_FAILED -eq 0 ]; then
        success "所有测试通过!"
        return 0
    else
        error "存在测试失败!"
        return 1
    fi
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
            --keys)
                TEST_KEYS="$2"
                shift 2
                ;;
            --size)
                TEST_SIZE="$2"
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
    local test_type=${1:-all}
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
    
    case $test_type in
        all)
            test_connectivity
            test_readwrite
            test_cluster
            test_replication
            show_summary
            ;;
        connect)
            test_connectivity
            show_summary
            ;;
        readwrite)
            test_readwrite
            show_summary
            ;;
        cluster)
            test_cluster
            show_summary
            ;;
        replication)
            test_replication
            show_summary
            ;;
        failover)
            test_failover
            ;;
        performance)
            test_performance
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
