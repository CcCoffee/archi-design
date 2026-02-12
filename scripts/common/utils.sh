#!/bin/bash

#######################################
# Redis Cluster 运维脚本 - 公共工具函数
# 用途: 提供通用的工具函数供其他脚本调用
# 作者: Redis Cluster 运维团队
# 版本: 1.0.0
#######################################

set -o pipefail

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志级别
LOG_DEBUG=0
LOG_INFO=1
LOG_WARN=2
LOG_ERROR=3
LOG_LEVEL=${LOG_INFO:-$LOG_INFO}

#######################################
# 打印带颜色的日志信息
# Arguments:
#   $1 - 日志级别 (DEBUG/INFO/WARN/ERROR)
#   $2 - 日志消息
# Outputs:
#   写入标准输出的日志消息
#######################################
log() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case $level in
        DEBUG)
            [[ $LOG_LEVEL -le $LOG_DEBUG ]] && echo -e "${BLUE}[DEBUG]${NC} ${timestamp} ${message}"
            ;;
        INFO)
            [[ $LOG_LEVEL -le $LOG_INFO ]] && echo -e "${GREEN}[INFO]${NC} ${timestamp} ${message}"
            ;;
        WARN)
            [[ $LOG_LEVEL -le $LOG_WARN ]] && echo -e "${YELLOW}[WARN]${NC} ${timestamp} ${message}"
            ;;
        ERROR)
            [[ $LOG_LEVEL -le $LOG_ERROR ]] && echo -e "${RED}[ERROR]${NC} ${timestamp} ${message}"
            ;;
    esac
}

#######################################
# 打印成功消息
# Arguments:
#   $1 - 消息内容
#######################################
success() {
    echo -e "${GREEN}✓ $1${NC}"
}

#######################################
# 打印错误消息并退出
# Arguments:
#   $1 - 错误消息
#   $2 - 退出码 (可选，默认为1)
#######################################
error_exit() {
    echo -e "${RED}✗ 错误: $1${NC}"
    exit ${2:-1}
}

#######################################
# 打印警告消息
# Arguments:
#   $1 - 警告消息
#######################################
warn() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

#######################################
# 打印信息消息
# Arguments:
#   $1 - 信息消息
#######################################
info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

#######################################
# 打印标题
# Arguments:
#   $1 - 标题内容
#######################################
print_title() {
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}  $1${NC}"
    echo -e "${GREEN}========================================${NC}"
    echo ""
}

#######################################
# 打印分隔线
#######################################
print_separator() {
    echo "----------------------------------------"
}

#######################################
# 检查命令是否存在
# Arguments:
#   $1 - 命令名称
# Returns:
#   0 - 存在
#   1 - 不存在
#######################################
check_command() {
    local cmd=$1
    if ! command -v "$cmd" &> /dev/null; then
        return 1
    fi
    return 0
}

#######################################
# 检查必要的依赖命令
# Arguments:
#   $@ - 命令列表
# Returns:
#   如果有缺失的命令则退出
#######################################
check_dependencies() {
    local missing=()
    
    for cmd in "$@"; do
        if ! check_command "$cmd"; then
            missing+=("$cmd")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        error_exit "缺少必要的命令: ${missing[*]}\n请安装后再运行此脚本"
    fi
}

#######################################
# 检查 Redis 是否安装
# Returns:
#   0 - 已安装
#   1 - 未安装
#######################################
check_redis_installed() {
    if check_command "redis-server" && check_command "redis-cli"; then
        return 0
    fi
    return 1
}

#######################################
# 获取 Redis 版本
# Outputs:
#   Redis 版本号
#######################################
get_redis_version() {
    redis-server --version 2>/dev/null | grep -oP 'v=\K[0-9.]+' | head -1
}

#######################################
# 检查端口是否被占用
# Arguments:
#   $1 - 端口号
# Returns:
#   0 - 已被占用
#   1 - 未被占用
#######################################
is_port_in_use() {
    local port=$1
    
    if check_command "lsof"; then
        lsof -i :$port &> /dev/null
        return $?
    elif check_command "netstat"; then
        netstat -an | grep -q ":$port "
        return $?
    elif check_command "ss"; then
        ss -tuln | grep -q ":$port "
        return $?
    fi
    
    return 1
}

#######################################
# 等待端口可用
# Arguments:
#   $1 - 端口号
#   $2 - 超时时间(秒)，默认30
# Returns:
#   0 - 端口可用
#   1 - 超时
#######################################
wait_for_port_available() {
    local port=$1
    local timeout=${2:-30}
    local count=0
    
    while is_port_in_use $port; do
        sleep 1
        ((count++))
        if [ $count -ge $timeout ]; then
            return 1
        fi
    done
    return 0
}

#######################################
# 等待 Redis 服务启动
# Arguments:
#   $1 - 主机地址
#   $2 - 端口号
#   $3 - 超时时间(秒)，默认30
# Returns:
#   0 - 服务已启动
#   1 - 超时
#######################################
wait_for_redis() {
    local host=$1
    local port=$2
    local timeout=${3:-30}
    local count=0
    
    while ! redis-cli -h $host -p $port ping &> /dev/null; do
        sleep 1
        ((count++))
        if [ $count -ge $timeout ]; then
            return 1
        fi
    done
    return 0
}

#######################################
# 执行 Redis 命令
# Arguments:
#   $1 - 主机地址
#   $2 - 端口号
#   $3 - Redis 命令
#   $4 - 密码 (可选)
# Outputs:
#   Redis 命令输出
#######################################
redis_exec() {
    local host=$1
    local port=$2
    local cmd=$3
    local password=$4
    
    if [ -n "$password" ]; then
        redis-cli -h $host -p $port -a "$password" --no-auth-warning $cmd 2>/dev/null
    else
        redis-cli -h $host -p $port $cmd 2>/dev/null
    fi
}

#######################################
# 获取 Redis 节点角色
# Arguments:
#   $1 - 主机地址
#   $2 - 端口号
# Outputs:
#   节点角色 (master/slave)
#######################################
get_redis_role() {
    local host=$1
    local port=$2
    
    local info=$(redis_exec $host $port "INFO replication")
    echo "$info" | grep "role:" | cut -d: -f2 | tr -d '\r'
}

#######################################
# 检查节点是否在集群中
# Arguments:
#   $1 - 主机地址
#   $2 - 端口号
# Returns:
#   0 - 在集群中
#   1 - 不在集群中
#######################################
is_node_in_cluster() {
    local host=$1
    local port=$2
    
    local info=$(redis_exec $host $port "CLUSTER INFO")
    if echo "$info" | grep -q "cluster_enabled:1"; then
        return 0
    fi
    return 1
}

#######################################
# 获取集群状态
# Arguments:
#   $1 - 主机地址
#   $2 - 端口号
# Outputs:
#   集群状态 (ok/fail)
#######################################
get_cluster_state() {
    local host=$1
    local port=$2
    
    local info=$(redis_exec $host $port "CLUSTER INFO")
    echo "$info" | grep "cluster_state:" | cut -d: -f2 | tr -d '\r'
}

#######################################
# 创建目录
# Arguments:
#   $1 - 目录路径
#######################################
ensure_dir() {
    local dir=$1
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir"
        log "INFO" "创建目录: $dir"
    fi
}

#######################################
# 备份文件
# Arguments:
#   $1 - 文件路径
# Outputs:
#   备份文件路径
#######################################
backup_file() {
    local file=$1
    if [ -f "$file" ]; then
        local backup="${file}.bak.$(date +%Y%m%d_%H%M%S)"
        cp "$file" "$backup"
        log "INFO" "备份文件: $backup"
        echo "$backup"
    fi
}

#######################################
# 生成随机密码
# Arguments:
#   $1 - 密码长度，默认16
# Outputs:
#   随机密码
#######################################
generate_password() {
    local length=${1:-16}
    openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c $length
}

#######################################
# 解析配置文件
# Arguments:
#   $1 - 配置文件路径
#   $2 - 配置项名称
# Outputs:
#   配置项值
#######################################
get_config_value() {
    local config_file=$1
    local key=$2
    
    if [ -f "$config_file" ]; then
        grep "^${key}=" "$config_file" | cut -d= -f2- | tr -d '"' | tr -d "'"
    fi
}

#######################################
# 设置配置文件值
# Arguments:
#   $1 - 配置文件路径
#   $2 - 配置项名称
#   $3 - 配置项值
#######################################
set_config_value() {
    local config_file=$1
    local key=$2
    local value=$3
    
    if [ -f "$config_file" ]; then
        if grep -q "^${key}=" "$config_file"; then
            sed -i.bak "s|^${key}=.*|${key}=${value}|" "$config_file"
        else
            echo "${key}=${value}" >> "$config_file"
        fi
    fi
}

#######################################
# 打印表格
# Arguments:
#   $@ - 表格数据 (格式: "列1|列2|列3" ...)
#######################################
print_table() {
    local data=("$@")
    local cols=0
    local widths=()
    
    # 计算列数和每列最大宽度
    for row in "${data[@]}"; do
        IFS='|' read -ra cells <<< "$row"
        local cell_count=${#cells[@]}
        if [ $cell_count -gt $cols ]; then
            cols=$cell_count
        fi
        for i in "${!cells[@]}"; do
            local len=${#cells[$i]}
            if [ -z "${widths[$i]}" ] || [ $len -gt ${widths[$i]} ]; then
                widths[$i]=$len
            fi
        done
    done
    
    # 打印分隔线
    local separator="+"
    for i in $(seq 0 $((cols-1))); do
        local w=${widths[$i]:-0}
        separator+=$(printf '%*s' $((w+2)) | tr ' ' '-')
        separator+="+"
    done
    echo "$separator"
    
    # 打印数据行
    for row in "${data[@]}"; do
        IFS='|' read -ra cells <<< "$row"
        local line="|"
        for i in $(seq 0 $((cols-1))); do
            local cell="${cells[$i]:-}"
            local w=${widths[$i]:-${#cell}}
            line+=" $(printf '%-*s' $w "$cell") |"
        done
        echo "$line"
        echo "$separator"
    done
}

#######################################
# 确认操作
# Arguments:
#   $1 - 提示消息
# Returns:
#   0 - 确认
#   1 - 取消
#######################################
confirm() {
    local message=$1
    read -p "$(echo -e ${YELLOW}? ${message} [y/N]: ${NC})" -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        return 0
    fi
    return 1
}

#######################################
# 显示进度条
# Arguments:
#   $1 - 当前进度
#   $2 - 总数
#   $3 - 描述信息
#######################################
show_progress() {
    local current=$1
    local total=$2
    local desc=$3
    local percent=$((current * 100 / total))
    local filled=$((percent / 2))
    local empty=$((50 - filled))
    
    printf "\r${desc}: ["
    printf '%*s' "$filled" | tr ' ' '='
    printf '%*s' "$empty" | tr ' ' ' '
    printf "] %3d%% (%d/%d)" $percent $current $total
    
    if [ $current -eq $total ]; then
        echo ""
    fi
}

#######################################
# 获取脚本所在目录
# Outputs:
#   脚本目录路径
#######################################
get_script_dir() {
    cd "$(dirname "${BASH_SOURCE[0]}")" && pwd
}

#######################################
# 获取项目根目录
# Outputs:
#   项目根目录路径
#######################################
get_project_root() {
    local script_dir=$(get_script_dir)
    dirname "$script_dir"
}
