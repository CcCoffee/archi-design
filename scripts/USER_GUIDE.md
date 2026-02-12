# Redis Cluster 运维脚本用户指南

## 目录

1. [快速开始](#1-快速开始)
2. [脚本概览](#2-脚本概览)
3. [本地开发环境](#3-本地开发环境)
4. [生产环境部署](#4-生产环境部署)
5. [集群管理](#5-集群管理)
6. [监控运维](#6-监控运维)
7. [测试验证](#7-测试验证)
8. [常见问题](#8-常见问题)

---

## 1. 快速开始

### 1.1 前置条件

- **操作系统**: macOS / Linux
- **Redis**: 6.0+ 版本
- **依赖工具**: bash, redis-cli, redis-server

### 1.2 安装 Redis

```bash
# macOS
brew install redis

# Ubuntu/Debian
sudo apt-get install redis-server

# CentOS/RHEL
sudo yum install redis
```

### 1.3 一键启动本地集群

```bash
cd /path/to/redis_cluster/scripts
./quick-start.sh
```

这个脚本会自动：
1. 检查 Redis 是否安装
2. 检查端口是否可用
3. 启动 6 个 Redis 节点（3主3从）
4. 创建集群并分配槽位
5. 运行测试验证

### 1.4 连接集群

```bash
# 使用集群模式连接
redis-cli -c -p 7001

# 测试写入
127.0.0.1:7001> SET hello world
OK

# 测试读取（自动路由）
127.0.0.1:7001> GET hello
"world"
```

---

## 2. 脚本概览

```
scripts/
├── redis-cluster.sh      # 主入口脚本（推荐使用）
├── quick-start.sh        # 快速启动脚本
├── local-cluster.sh      # 本地集群管理
├── deploy-production.sh  # 生产环境部署
├── cluster-manager.sh    # 集群管理操作
├── monitor.sh            # 监控和健康检查
├── test-cluster.sh       # 集群测试
├── common/
│   └── utils.sh          # 公共工具函数
├── env/
│   ├── local.env         # 本地环境配置
│   └── production.env    # 生产环境配置
└── templates/
    └── redis.conf.template  # Redis 配置模板
```

### 2.1 主入口脚本 (redis-cluster.sh)

这是推荐的统一入口，可以调用所有功能：

```bash
# 查看帮助
./redis-cluster.sh help

# 查看版本
./redis-cluster.sh version
```

---

## 3. 本地开发环境

### 3.1 环境配置

配置文件: `scripts/env/local.env`

```bash
# 节点配置
DC_A_NODES=("127.0.0.1:7001" "127.0.0.1:7002" "127.0.0.1:7003")  # 主节点
DC_B_NODES=("127.0.0.1:7004" "127.0.0.1:7005" "127.0.0.1:7006")  # 从节点

# 内存配置
REDIS_MAXMEMORY="256mb"

# 集群参数
CLUSTER_NODE_TIMEOUT="5000"
```

### 3.2 常用命令

```bash
# 启动集群
./local-cluster.sh start

# 停止集群
./local-cluster.sh stop

# 重启集群
./local-cluster.sh restart

# 查看状态
./local-cluster.sh status

# 创建集群（首次启动后执行）
./local-cluster.sh create

# 重置集群（删除所有数据）
./local-cluster.sh reset

# 强制重置（不提示确认）
./local-cluster.sh reset -f

# 查看日志
./local-cluster.sh logs           # 列出所有日志文件
./local-cluster.sh logs -n 7001   # 查看指定节点日志

# 清理环境
./local-cluster.sh clean
```

### 3.3 目录结构

本地环境会在 `~/.redis-cluster/` 下创建以下目录：

```
~/.redis-cluster/
├── data/           # 数据文件
│   ├── 7001/
│   ├── 7002/
│   └── ...
├── logs/           # 日志文件
│   ├── redis-7001.log
│   └── ...
├── conf/           # 配置文件
│   ├── 7001/
│   │   ├── redis.conf
│   │   └── nodes.conf
│   └── ...
└── pids/           # PID 文件
```

---

## 4. 生产环境部署

### 4.1 环境配置

配置文件: `scripts/env/production.env`

```bash
# 数据中心 A（主）
DC_A_NODES=("10.1.1.1:6379" "10.1.1.2:6379" "10.1.1.3:6379")

# 数据中心 B（备）
DC_B_NODES=("10.2.1.1:6379" "10.2.1.2:6379" "10.2.1.3:6379")

# 集群密码
CLUSTER_PASSWORD="your_strong_password"

# 内存配置
REDIS_MAXMEMORY="4gb"
```

### 4.2 部署步骤

在**每台服务器**上执行：

```bash
# 1. 初始化服务器环境
./deploy-production.sh init --ip <服务器IP> --role <master|slave> --dc <DC-A|DC-B>

# 2. 安装 Redis
./deploy-production.sh install

# 3. 生成配置文件
./deploy-production.sh config --password <集群密码>

# 4. 启动服务
./deploy-production.sh start

# 5. 查看状态
./deploy-production.sh status
```

### 4.3 创建集群

在任意一台服务器上执行：

```bash
# 使用 redis-cli 创建集群
redis-cli --cluster create \
    10.1.1.1:6379 10.1.1.2:6379 10.1.1.3:6379 \
    10.2.1.1:6379 10.2.1.2:6379 10.2.1.3:6379 \
    --cluster-replicas 1 \
    -a <密码>
```

### 4.4 加入已有集群

```bash
# 新节点加入集群
./deploy-production.sh join --master <主节点IP:端口>
```

### 4.5 数据备份

```bash
# 备份当前节点数据
./deploy-production.sh backup
```

---

## 5. 集群管理

### 5.1 查看集群信息

```bash
# 查看集群状态
./cluster-manager.sh status

# 查看节点列表
./cluster-manager.sh nodes

# 查看槽位分布
./cluster-manager.sh slots

# 查看详细信息
./cluster-manager.sh info
```

### 5.2 故障转移

当主节点故障时，手动将从节点提升为主节点：

```bash
# 在从节点上执行故障转移
./cluster-manager.sh failover --node <从节点IP:端口>

# 示例
./cluster-manager.sh failover --node 127.0.0.1:7004
```

### 5.3 槽位迁移

将槽位从一个节点迁移到另一个节点：

```bash
# 迁移槽位
./cluster-manager.sh reshard \
    --from <源节点ID> \
    --to <目标节点ID> \
    --slots <槽位数量>

# 示例：迁移 1000 个槽位
./cluster-manager.sh reshard \
    --from 7d11028279ff115c8db4ea47df62036455a7a866 \
    --to fadc7d7c254727ebe4547975cbc4f264fa76502e \
    --slots 1000
```

### 5.4 平衡槽位

自动平衡集群槽位分布：

```bash
./cluster-manager.sh rebalance
```

### 5.5 添加节点

```bash
# 添加主节点
./cluster-manager.sh add-node \
    --new <新节点IP:端口> \
    --existing <已有节点IP:端口>

# 添加从节点
./cluster-manager.sh add-node \
    --new <新节点IP:端口> \
    --existing <已有节点IP:端口> \
    --role slave \
    --master <主节点IP:端口>
```

### 5.6 删除节点

```bash
# 删除节点（需要先迁移槽位）
./cluster-manager.sh del-node --node <节点IP:端口>
```

### 5.7 集群检查与修复

```bash
# 检查集群健康状态
./cluster-manager.sh check

# 修复集群问题
./cluster-manager.sh fix
```

---

## 6. 监控运维

### 6.1 健康检查

```bash
# 完整健康检查
./monitor.sh health
```

输出包括：
- 集群状态检查
- 节点连接检查
- 主从复制检查
- 内存使用检查
- 持久化状态检查

### 6.2 实时监控

```bash
# 实时监控（默认 5 秒刷新）
./monitor.sh watch

# 自定义刷新间隔
./monitor.sh watch --interval 3
```

### 6.3 性能指标

```bash
# 收集性能指标
./monitor.sh metrics

# JSON 格式输出
./monitor.sh metrics --output json
```

### 6.4 告警检查

```bash
# 检查告警条件
./monitor.sh alert
```

可在 `production.env` 中配置告警阈值：

```bash
MEMORY_WARNING_THRESHOLD=80
MEMORY_CRITICAL_THRESHOLD=90
LATENCY_WARNING_THRESHOLD=10
```

### 6.5 慢查询日志

```bash
# 查看慢查询日志
./monitor.sh slowlog

# 指定显示条数
./monitor.sh slowlog 20
```

### 6.6 内存分析

```bash
# 内存使用分析
./monitor.sh memory
```

### 6.7 连接分析

```bash
# 连接分析
./monitor.sh connections
```

### 6.8 生成报告

```bash
# 生成监控报告
./monitor.sh report

# JSON 格式
./monitor.sh report --output json
```

---

## 7. 测试验证

### 7.1 运行所有测试

```bash
./test-cluster.sh all
```

### 7.2 单独测试

```bash
# 连接测试
./test-cluster.sh connect

# 读写测试
./test-cluster.sh readwrite

# 集群功能测试
./test-cluster.sh cluster

# 复制测试
./test-cluster.sh replication

# 性能测试
./test-cluster.sh performance
```

### 7.3 自定义测试参数

```bash
# 指定测试键数量和数据大小
./test-cluster.sh readwrite --keys 1000 --size 2048
```

---

## 8. 常见问题

### 8.1 端口被占用

**问题**: 启动时提示端口被占用

**解决方案**:
```bash
# 查找占用进程
lsof -i :7001

# 停止占用进程
kill -9 <PID>

# 或使用脚本停止
redis-cli -p 7001 SHUTDOWN NOSAVE
```

### 8.2 集群状态异常

**问题**: `cluster_state:fail`

**解决方案**:
```bash
# 检查集群
./cluster-manager.sh check

# 尝试修复
./cluster-manager.sh fix
```

### 8.3 主从复制断开

**问题**: `master_link_status:down`

**解决方案**:
```bash
# 检查网络连接
ping <主节点IP>

# 检查主节点状态
redis-cli -h <主节点IP> -p <端口> PING

# 检查认证配置
redis-cli -h <从节点IP> -p <端口> CONFIG GET masterauth
```

### 8.4 内存不足

**问题**: 写入失败，提示 OOM

**解决方案**:
```bash
# 检查内存使用
./monitor.sh memory

# 调整内存限制
redis-cli -p 7001 CONFIG SET maxmemory 512mb

# 或修改配置文件
# 编辑 env/local.env 中的 REDIS_MAXMEMORY
```

### 8.5 槽位未覆盖

**问题**: 部分槽位没有节点负责

**解决方案**:
```bash
# 检查槽位分布
./cluster-manager.sh slots

# 手动分配槽位
redis-cli --cluster fix <节点IP:端口>
```

### 8.6 数据迁移卡住

**问题**: 槽位迁移过程中卡住

**解决方案**:
```bash
# 检查迁移状态
redis-cli -p 7001 CLUSTER SETSLOT <slot> IMPORTING <source_node_id>

# 取消迁移
redis-cli -p 7001 CLUSTER SETSLOT <slot> STABLE
```

---

## 附录 A: 命令速查表

| 命令 | 说明 |
|------|------|
| `./quick-start.sh` | 一键启动本地集群 |
| `./local-cluster.sh start` | 启动本地集群 |
| `./local-cluster.sh stop` | 停止本地集群 |
| `./local-cluster.sh status` | 查看集群状态 |
| `./local-cluster.sh reset` | 重置集群 |
| `./cluster-manager.sh failover --node <ip:port>` | 故障转移 |
| `./cluster-manager.sh reshard --from <id> --to <id> --slots <n>` | 迁移槽位 |
| `./cluster-manager.sh check` | 检查集群 |
| `./monitor.sh health` | 健康检查 |
| `./monitor.sh watch` | 实时监控 |
| `./test-cluster.sh all` | 运行所有测试 |

## 附录 B: Redis Cluster 常用命令

```bash
# 连接集群
redis-cli -c -p 7001

# 查看集群信息
CLUSTER INFO

# 查看节点
CLUSTER NODES

# 查看键所在槽位
CLUSTER KEYSLOT <key>

# 查看槽位所属节点
CLUSTER SLOTS

# 手动故障转移
CLUSTER FAILOVER

# 查看从节点信息
INFO replication
```

## 附录 C: 配置参数说明

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `REDIS_MAXMEMORY` | 256mb (本地) / 4gb (生产) | 最大内存 |
| `CLUSTER_NODE_TIMEOUT` | 5000 | 节点超时时间(ms) |
| `CLUSTER_REQUIRE_FULL_COVERAGE` | no (本地) / yes (生产) | 是否要求完整槽位覆盖 |
| `APPENDONLY` | yes | 启用 AOF 持久化 |
| `MAXMEMORY_POLICY` | allkeys-lru | 内存淘汰策略 |

---

**文档版本**: 1.0.0  
**最后更新**: 2026-02-12
