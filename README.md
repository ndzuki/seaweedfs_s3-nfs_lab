# 🌿 SeaweedFS 实验环境

一键部署 **kind 集群 + SeaweedFS 存储服务 + CSI Driver + NFS/S3/rclone** 的本地实验环境，
并自动执行 **fio 基准测试**（基础读写 / 2000+ 小文件 / AI 大模型）对比 NFS、S3 FUSE、CSI 三种挂载方式的性能。

## 目录结构

```
.
├── setup-seaweedfs-lab.sh          # 主入口脚本 (一键部署/测试/卸载)
├── docker/                          # 容器镜像
│   ├── Dockerfile.fio              # fio 测试容器镜像
│   └── entrypoint-fio.sh           # 容器启动后自动执行 fio 测试
├── seaweedfs-csi-driver-master/     # SeaweedFS CSI Driver (第三方)
│   └── deploy/kubernetes/
│       └── seaweedfs-csi.yaml      # CSI Driver K8s 部署清单
├── legacy/                          # 旧版脚本 (保留参考)
│   ├── weed-manager.sh             # 原始 weed 管理脚本
│   └── nfs_s3_rclone_crds.yaml     # 原始 CRDs 模板
└── filerldb2/                       # SeaweedFS Filer 数据目录 (运行时生成)
```

## 前置依赖

| 工具 | 版本要求 | 安装方式 |
|------|---------|---------|
| [kind](https://kind.sigs.k8s.io/) | ≥ v0.20 | `go install sigs.k8s.io/kind@latest` |
| [kubectl](https://kubernetes.io/docs/tasks/tools/) | ≥ v1.28 | 包管理器或官方二进制 |
| [weed](https://github.com/seaweedfs/seaweedfs) | ≥ v3.60 | 从 [Releases](https://github.com/seaweedfs/seaweedfs/releases) 下载 |
| Docker | ≥ 24 | `docker-ce` 或 `docker.io` |
| NFS 工具 | — | `nfs-kernel-server` / `nfs-utils` (脚本会自动安装) |

## 快速开始

### 一键部署

```bash
# 使用默认配置部署全部环境 (需要 root 权限，因为要挂载 FUSE/NFS)
sudo ./setup-seaweedfs-lab.sh deploy
```

### 查看状态

```bash
./setup-seaweedfs-lab.sh status
```

### 查看 fio 测试结果

```bash
# 容器启动后自动执行三场景 fio 测试，此命令拉取结果
./setup-seaweedfs-lab.sh fio
```

### 卸载

```bash
sudo ./setup-seaweedfs-lab.sh uninstall
```

## 命令参考

| 命令 | 说明 | 权限 |
|------|------|------|
| `deploy` | 一键部署全部环境 | root |
| `kind-up` | 仅创建 kind 集群 | 普通 |
| `kind-down` | 仅删除 kind 集群 | 普通 |
| `seaweedfs` | 仅部署 SeaweedFS 原生服务 | root |
| `csi` | 仅部署 seaweedfs-csi-driver | 普通 |
| `crds` | 仅部署 NFS/S3/rclone CRDs + fio Pod | 普通 |
| `status` | 查看环境状态 | 普通 |
| `fio` | 查看 fio 测试结果 | 普通 |
| `uninstall` | 卸载全部环境 | root |

## 环境变量

所有变量均有合理默认值，按需覆盖即可跨环境复现。

### 连接地址

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `NFS_SERVER` | `<本机IP>` | NFS 服务器地址 |
| `NFS_PATH` | `/mnt/seaweedfs/data` | NFS 导出路径 |
| `SEAWEEDFS_FILER` | `<本机IP>:8888` | SeaweedFS Filer 地址 |
| `SEAWEEDFS_MASTER` | `<本机IP>:9333` | SeaweedFS Master 地址 |
| `SEAWEEDFS_S3_ENDPOINT` | `http://<本机IP>:8333` | S3 API 端点 |
| `SEAWEEDFS_S3_ACCESS_KEY` | `admin` | S3 Access Key |
| `SEAWEEDFS_S3_SECRET_KEY` | `admin123` | S3 Secret Key |
| `KIND_CLUSTER_NAME` | `seaweedfs-lab` | kind 集群名称 |
| `S3_BUCKET` | `my-test-bucket` | S3 存储桶名称 |

### fio 测试参数

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `FIO_IMAGE` | `seaweedfs-fio-test:local` | fio 测试镜像名 |
| `FIO_SIZE` | `256M` | 基础测试文件大小 |
| `FIO_RUNTIME` | `60s` | 基础测试时长 |
| `TEST_BASIC` | `true` | 启用基础读写测试 |
| `TEST_SMALL_FILES` | `true` | 启用小文件场景测试 |
| `TEST_AI_MODEL` | `true` | 启用 AI 大模型场景测试 |
| `SMALL_FILE_COUNT` | `2000` | 小文件数量 |
| `SMALL_FILE_SIZE` | `16k` | 单个小文件大小 |
| `AI_MODEL_SIZE` | `2G` | AI 场景测试文件大小 |
| `AI_MODEL_JOBS` | `4` | AI 场景并发线程数 |

### 使用示例

```bash
# 自定义 S3 端点部署
SEAWEEDFS_S3_ENDPOINT=http://192.168.1.100:8333 sudo -E ./setup-seaweedfs-lab.sh deploy

# 仅测试 AI 大模型场景
TEST_BASIC=false TEST_SMALL_FILES=false sudo -E ./setup-seaweedfs-lab.sh deploy

# 5000 个小文件测试
SMALL_FILE_COUNT=5000 SMALL_FILE_SIZE=64k sudo -E ./setup-seaweedfs-lab.sh deploy

# 不同集群名称部署多套环境
KIND_CLUSTER_NAME=seaweedfs-exp2 sudo -E ./setup-seaweedfs-lab.sh deploy
```

## 架构概览

```
┌──────────────────────────────────────────────────────────────────┐
│                         宿主机 (Host)                              │
│  ┌─────────────────────────────────────────────────────────┐     │
│  │              SeaweedFS 原生服务                           │     │
│  │  Master(:9333)  Volume(:8080)  Filer(:8888)  S3(:8333)  │     │
│  │                    │ FUSE mount                           │     │
│  │              /mnt/seaweedfs/data ──→ NFS 导出              │     │
│  └─────────────────────────────────────────────────────────┘     │
│                              │                                    │
│  ┌───────────────────────────┼────────────────────────────────┐   │
│  │              kind 集群 (seaweedfs-lab)                      │   │
│  │                           │                                 │   │
│  │  ┌────────────────────────┼──────────────────────────┐     │   │
│  │  │  CSI Driver                                         │     │   │
│  │  │  controller + node (DaemonSet) + mount (DaemonSet)  │     │   │
│  │  │  StorageClass: seaweedfs-storage                     │     │   │
│  │  └────────────────────────┼──────────────────────────┘     │   │
│  │                           │                                 │   │
│  │  ┌────────────────────────┼──────────────────────────┐     │   │
│  │  │  NFS Provisioner                                    │     │   │
│  │  │  StorageClass: seaweedfs-nfs-storage                │     │   │
│  │  └────────────────────────┼──────────────────────────┘     │   │
│  │                           │                                 │   │
│  │  ┌────────────────────────────────────────────────────┐     │   │
│  │  │  fio-storage-test Pod                               │     │   │
│  │  │                                                     │     │   │
│  │  │  ┌──────────────┐  ┌──────────────────────┐        │     │   │
│  │  │  │  fio-test     │  │  s3-sidecar (rclone) │        │     │   │
│  │  │  │               │  │                      │        │     │   │
│  │  │  │ /mnt/nfs      │  │ /data/s3 ← S3 FUSE   │        │     │   │
│  │  │  │ /mnt/s3       │  │ /data/nfs → NFS PVC  │        │     │   │
│  │  │  │ /mnt/s3_with_ │  │   sync loop          │        │     │   │
│  │  │  │   seaweedfs   │  └──────────────────────┘        │     │   │
│  │  │  └──────────────┘                                   │     │   │
│  │  └────────────────────────────────────────────────────┘     │   │
│  └─────────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────┘
```

### 三种挂载路径对比

| 挂载路径 | 后端 | 存储类 | 特点 |
|----------|------|--------|------|
| `/mnt/nfs` | NFS provisioner → 宿主机 NFS | `seaweedfs-nfs-storage` | 标准 NFS 协议，成熟稳定 |
| `/mnt/s3` | rclone S3 FUSE (sidecar 挂载) | — (emptyDir) | S3 协议，通过 FUSE 模拟 POSIX |
| `/mnt/s3_with_seaweedfs` | seaweedfs-csi-driver | `seaweedfs-storage` | CSI 接口，K8s 原生集成 |

### 性能差异分析

NFS 始终比 S3/CSI 快，这是协议架构决定的正常现象。三者底层存储路径完全相同（都是 SeaweedFS filer），性能差距完全来自接入层协议开销。

```
数据流对比 (fio → SeaweedFS 磁盘):

NFS (最快):
  fio → [内核 NFS 客户端] → TCP → NFS 服务(内核态) → FUSE mount → filer → 磁盘
  特点: 内核态端到端, 原生 POSIX 语义, 页缓存加速, 无协议翻译

CSI (中速):
  fio → FUSE(内核) → CSI mount daemon(用户态) → gRPC → filer → 磁盘
  特点: gRPC 二进制协议比 HTTP 高效, 但内核↔用户态切换有开销

S3 rclone (最慢):
  fio → FUSE(内核) → rclone(用户态) → HTTP S3 API → S3 gateway → filer → 磁盘
  特点: 每次 POSIX 操作需翻译成 S3 API 调用(HEAD/GET/PUT/DELETE),
        HTTP 协议头开销大, 用户态到用户态再到内核态
```

| 维度 | NFS | CSI | S3 (rclone) |
|------|-----|-----|-------------|
| 接入协议 | NFS v3/v4 内核态 | gRPC 用户态 | HTTP S3 API 用户态 |
| POSIX 兼容 | 原生 | 通过 FUSE 适配 | 通过 rclone FUSE 模拟 |
| 元数据性能 | 高 (内核缓存) | 中 (gRPC 调用) | 低 (HTTP HEAD 翻译) |
| 大文件吞吐 | 最高 | 中等 | 较低 |
| 协议转换次数 | 0 | 1 (FUSE→gRPC) | 2 (FUSE→HTTP→S3) |
| 适合场景 | 通用计算 / 高吞吐 | K8s 原生集成 | 跨平台 S3 兼容 |

**实测数据参考 (256M 顺序写, 本实验环境):**

| 存储后端 | 顺序写 | 顺序读 | 随机写(4k) | 随机读(4k) |
|----------|--------|--------|------------|------------|
| NFS | ~1700 MB/s | ~4000 MB/s | ~900 MB/s | ~8000 IOPS |
| CSI | ~2000 MB/s | ~500 MB/s | ~200 MB/s | ~8000 IOPS |
| S3 | ~1500 MB/s | ~1800 MB/s | ~150 MB/s | ~35000 IOPS |

> **结论**: NFS 适合高吞吐和通用场景，CSI 适合 K8s 原生集成（PVC），S3 适合跨平台兼容但性能有折损。选择取决于业务对性能和接口标准的需求。

## fio 测试场景

容器启动后自动对三个挂载目录依次执行以下三个场景的基准测试：

### 场景 1: 基础读写

| 测试项 | 参数 |
|--------|------|
| 顺序写 | `rw=write`, `bs=1M` |
| 顺序读 | `rw=read`, `bs=1M` |
| 随机写 | `rw=randwrite`, `bs=4k` |
| 随机读 | `rw=randread`, `bs=4k` |

### 场景 2: 2000+ 小文件随机读写

模拟容器镜像层、源代码仓库等大量小文件场景。

| 测试项 | 参数 |
|--------|------|
| 文件创建 | `nrfiles=2000`, `filesize=16k` |
| 随机读 | `rw=randread`, `bs=4k`, `numjobs=4`, `openfiles=512` |
| 随机写 | `rw=randwrite`, `bs=4k`, `numjobs=4`, `openfiles=512` |
| 混合读写 | `rw=randrw`, `rwmixread=70`, `numjobs=4` |

### 场景 3: AI 大模型文件读写

模拟模型权重加载、checkpoint 保存、分布式训练数据读取。

| 测试项 | 参数 | 对应场景 |
|--------|------|----------|
| 顺序写 | `bs=4M`, `size=2G` | Checkpoint 保存 |
| 顺序读 | `bs=4M`, `size=2G`, `numjobs=4` | 模型权重加载 |
| 随机读 | `bs=256k`, `numjobs=4` | 分布式训练数据读取 |
| 随机写 | `bs=8k`, `size=256M` | 训练日志写入 |

### 手动执行 fio 测试

```bash
# 进入容器手动测试
kubectl exec -it $(kubectl get pods -l app=fio-storage -o name) -c fio-test -- bash

# 重新运行全部场景
/entrypoint-fio.sh

# 自定义单次测试
fio --name=test --filename=/mnt/nfs/test.dat --rw=write --bs=1M --size=256M
```

## 文件说明

| 文件 | 说明 |
|------|------|
| `setup-seaweedfs-lab.sh` | 主入口脚本，集成 kind 集群创建、SeaweedFS 部署、CSI Driver 部署、fio 测试 |
| `docker/Dockerfile.fio` | fio 测试容器，基于 Alpine 3.20，预装 fio/bash/curl |
| `docker/entrypoint-fio.sh` | 容器入口脚本，自动等待挂载点 → 执行三场景测试 → 输出结果 |
| `legacy/weed-manager.sh` | 旧版脚本，仅管理宿主机上的 weed 进程 |
| `legacy/nfs_s3_rclone_crds.yaml` | 旧版 CRDs 模板，已内嵌到新脚本中 |
| `seaweedfs-csi-driver-master/` | SeaweedFS CSI Driver 源码及 K8s 部署清单 |

## 常见问题

### NFS 挂载失败

```bash
# 确认 NFS 服务运行
systemctl status nfs-server
# 确认导出
showmount -e localhost
# 手动测试挂载
mount -t nfs ${NFS_SERVER}:${NFS_PATH} /mnt/test
```

### CSI Driver Pod 未就绪

```bash
# 查看日志
kubectl logs -l app=seaweedfs-controller
kubectl logs -l app=seaweedfs-node
# 确认 filer 地址可达
kubectl exec -it $(kubectl get pods -l app=seaweedfs-controller -o name) -- wget -qO- http://${SEAWEEDFS_FILER}/
```

### 小文件场景 NFS 随机读失败

NFS 小文件场景（场景 2）中，`small-randread` 和 `small-randrw` 可能失败，报错 `No such file or directory` 或 `is not a directory`。这是 NFS close-to-open 缓存一致性导致的问题：

- 并行创建 2000 个文件后，NFS 客户端目录缓存可能不包含全部新文件
- 后续 `open(O_RDONLY)` 调用返回 `ENOENT`（文件不存在）
- `small-randwrite` 使用 `O_RDWR`，可在文件缺失时自动创建，因此不受影响
- S3 (rclone) 和 CSI (seaweedfs-csi-driver) 无此问题

**已知状态：**

| 小文件测试 | NFS | S3 | CSI |
|-----------|-----|-----|------|
| 文件创建 | ✅ | ✅ | ✅ |
| 随机读 | ❌ (NFS 缓存) | ✅ | ✅ |
| 随机写 | ✅ | ✅ | ✅ |
| 混合读写 | ❌ (NFS 缓存) | ✅ | ✅ |

**根因**: NFS 服务端（宿主机 SeaweedFS FUSE → NFS export）对新创建文件的 `open(O_RDONLY)` 返回 `ENOENT`，而 `open(O_RDWR)` 可正常访问（或自动创建）。这是 NFS over FUSE 的属性缓存同步问题。

**已尝试方案**: fio write、fio create_only、Python ftruncate（2000/2000 创建成功，44s）、NFS_CREATE_DELAY 逐文件限速、sync+ls 刷新、稳定等待（导致目录失效）。均无法使 O_RDONLY 读取全部文件。

**当前状态**:
- `small-randwrite`: ✅（O_RDWR 打开）
- `small-randrand`: ❌（O_RDONLY 打开失败）
- `small-randrw`: ❌（70% 读取部分用 O_RDONLY 失败）
- S3 和 CSI 全部通过。

**参数**:
- `NFS_CREATE_DELAY=0.02`（秒/文件）：创建间隔，默认 0.02s → 2000 文件约 44s

### fio 测试未自动执行

容器启动后需要等待挂载点就绪（最长 300s）。如果超时：

```bash
# 检查挂载点状态
kubectl exec $(kubectl get pods -l app=fio-storage -o name) -c fio-test -- df -h | grep /mnt

# 手动触发测试
kubectl exec $(kubectl get pods -l app=fio-storage -o name) -c fio-test -- /entrypoint-fio.sh
```

### 切换 kind 集群上下文

```bash
kubectl config use-context kind-seaweedfs-lab
```
