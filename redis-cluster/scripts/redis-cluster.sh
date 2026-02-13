#!/bin/bash

#######################################
# Redis Cluster 运维脚本 - 主入口
# 用途: 提供统一的命令行入口
# 使用: ./redis-cluster.sh <命令> [选项]
#######################################

set -e

# 获取脚本目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 加载公共函数
source "${SCRIPT_DIR}/common/utils.sh"

# 默认环境
ENV_TYPE="${ENV_TYPE:-local}"

#######################################
# 显示帮助信息
#######################################
show_help() {
    cat << EOF
Redis Cluster 运维脚本

用法: $0 <命令> [选项]

命令:
    环境管理:
        local           切换到本地开发环境
        production      切换到生产环境
        
    本地开发环境:
        start           启动本地集群
        stop            停止本地集群
        restart         重启本地集群
        status          查看集群状态
        create          创建集群
        reset           重置集群
        logs            查看日志
        test            运行测试
        
    生产环境部署:
        deploy          部署生产环境节点
        init            初始化服务器
        install         安装 Redis
        config          生成配置
        
    集群管理:
        nodes           查看节点列表
        slots           查看槽位分布
        failover        执行故障转移
        reshard         重新分配槽位
        rebalance       平衡槽位分布
        add-node        添加节点
        del-node        删除节点
        check           检查集群健康
        fix             修复集群问题
        
    监控运维:
        health          健康检查
        watch           实时监控
        alert           检查告警
        report          生成报告
        slowlog         慢查询日志
        memory          内存分析
        backup          备份数据
        
    其他:
        help            显示帮助信息
        version         显示版本信息

选项:
    --env           环境类型 (local/production)
    --node          节点地址 (ip:port)
    --master        主节点地址
    --slave         从节点地址
    --slots         槽位数量
    --interval      监控间隔 (秒)
    --output        输出格式 (text/json)
    -f, --force     强制执行
    -h, --help      显示帮助

示例:
    # 本地开发
    $0 start                    # 启动本地集群
    $0 create                   # 创建集群
    $0 status                   # 查看状态
    $0 test                     # 运行测试
    
    # 生产环境
    $0 --env production deploy --ip 10.1.1.1 --role master --dc DC-A
    
    # 集群管理
    $0 failover --node 10.2.1.1:6379
    $0 reshard --from <node-id> --to <node-id> --slots 1000
    
    # 监控
    $0 health
    $0 watch --interval 5

EOF
}

#######################################
# 显示版本信息
#######################################
show_version() {
    echo "Redis Cluster 运维脚本 v1.0.0"
    echo ""
    echo "环境: ${ENV_TYPE}"
    
    if check_redis_installed; then
        echo "Redis 版本: $(get_redis_version)"
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
                export ENV_TYPE
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
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
    
    case $command in
        # 环境切换
        local)
            export ENV_TYPE=local
            info "已切换到本地开发环境"
            ;;
        production)
            export ENV_TYPE=production
            info "已切换到生产环境"
            ;;
            
        # 本地开发环境
        start|stop|restart|status|create|reset|logs|test|clean)
            bash "${SCRIPT_DIR}/local-cluster.sh" $command "$@"
            ;;
            
        # 生产环境部署
        deploy|init|install|config)
            bash "${SCRIPT_DIR}/deploy-production.sh" $command "$@"
            ;;
            
        # 集群管理
        nodes|slots|info|meet|forget|replicate|failover|reshard|rebalance|add-node|del-node|check|fix|backup)
            bash "${SCRIPT_DIR}/cluster-manager.sh" --env $ENV_TYPE $command "$@"
            ;;
            
        # 监控运维
        health|metrics|watch|alert|report|slowlog|memory|connections|replication)
            bash "${SCRIPT_DIR}/monitor.sh" --env $ENV_TYPE $command "$@"
            ;;
            
        # 其他
        help|--help|-h)
            show_help
            ;;
        version|--version|-v)
            show_version
            ;;
        *)
            error_exit "未知命令: $command\n运行 '$0 help' 查看帮助"
            ;;
    esac
}

main "$@"
