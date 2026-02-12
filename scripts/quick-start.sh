#!/bin/bash

#######################################
# Redis Cluster 快速启动脚本
# 用途: 一键启动本地开发环境并创建集群
# 使用: ./quick-start.sh
#######################################

set -e

# 获取脚本目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 加载公共函数
source "${SCRIPT_DIR}/common/utils.sh"

print_title "Redis Cluster 快速启动"

# 检查 Redis 是否安装
if ! check_redis_installed; then
    error "Redis 未安装"
    echo ""
    info "请先安装 Redis:"
    echo "  macOS: brew install redis"
    echo "  Ubuntu: sudo apt-get install redis-server"
    echo "  CentOS: sudo yum install redis"
    exit 1
fi

info "Redis 版本: $(get_redis_version)"
echo ""

# 检查端口是否被占用
info "检查端口..."
ports_in_use=()

for port in 7000 7001 7002 7003 7004 7005; do
    if is_port_in_use $port; then
        ports_in_use+=($port)
    fi
done

if [ ${#ports_in_use[@]} -gt 0 ]; then
    warn "以下端口已被占用: ${ports_in_use[*]}"
    echo ""
    
    if confirm "是否停止现有 Redis 进程并继续?"; then
        for port in "${ports_in_use[@]}"; do
            log "INFO" "停止端口 ${port} 上的 Redis..."
            redis-cli -p $port SHUTDOWN NOSAVE 2>/dev/null || true
            sleep 1
        done
    else
        exit 1
    fi
fi

# 启动集群
info "启动 Redis Cluster..."
bash "${SCRIPT_DIR}/local-cluster.sh" start

echo ""
sleep 2

# 创建集群
info "创建集群..."
bash "${SCRIPT_DIR}/local-cluster.sh" create

echo ""
sleep 1

# 运行测试
info "运行测试..."
bash "${SCRIPT_DIR}/test-cluster.sh" all

echo ""
print_title "快速启动完成"

echo ""
info "集群信息:"
echo "  主节点: 127.0.0.1:7000, 127.0.0.1:7001, 127.0.0.1:7002"
echo "  从节点: 127.0.0.1:7003, 127.0.0.1:7004, 127.0.0.1:7005"
echo ""
info "常用命令:"
echo "  查看状态: ./redis-cluster.sh status"
echo "  实时监控: ./redis-cluster.sh watch"
echo "  健康检查: ./redis-cluster.sh health"
echo "  停止集群: ./redis-cluster.sh stop"
echo ""
info "连接集群:"
echo "  redis-cli -c -p 7000"
echo ""
