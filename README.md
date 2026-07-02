# 🌿 SeaweedFS 实验环境

一键部署 **kind 集群 + SeaweedFS 存储服务 + CSI Driver + ImageVolume + NFS/S3/rclone** 的本地实验环境，
并自动执行 **fio 基准测试**（基础读写 / 2000+ 小文件 / AI 大模型）对比 NFS、S3 FUSE、CSI、ImageVolume 四种挂载方式的性能。

## 目录结构

```
.
├── setup-seaweedfs-lab.sh          # 主入口脚本 (一键部署/测试/卸载)
├── docker/                          # 容器镜像
│   ├── Dockerfile.fio              # fio 测试容器镜像 (基于 Alpine)
│   ├── Dockerfile.testdata         # ImageVolume 测试数据镜像 (预置只读数据)
│   └── entrypoint-fio.sh           # 容器启动后自动执行 fio 四场景测试
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
| `FIO_IMAGE` | `seaweedfs-fio-test:local-<ts>` | fio 测试镜像名 (时间戳 tag 确保唯一) |
| `FIO_SIZE` | `256M` | 基础测试文件大小 |
| `FIO_RUNTIME` | `60s` | 基础测试时长 |
| `TEST_BASIC` | `true` | 启用基础读写测试 |
| `TEST_SMALL_FILES` | `true` | 启用小文件场景测试 |
| `TEST_AI_MODEL` | `true` | 启用 AI 大模型场景测试 |
| `TEST_SCENARIO` | `all` | 便捷场景选择: `basic`/`small`/`ai`/`all` |
| `SMALL_FILE_COUNT` | `2000` | 小文件数量 |
| `SMALL_FILE_SIZE` | `16k` | 单个小文件大小 |
| `AI_MODEL_SIZE` | `512M` | AI 场景测试文件大小 |
| `AI_MODEL_RUNTIME` | `120s` | AI 场景读测试时长 |
| `AI_MODEL_JOBS` | `4` | AI 场景并发线程数 |

### fio 安全与限流参数

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `CSI_WRITE_RATE` | `50m` | CSI 写限速 (MB/s)，防止 FUSE 脏页堆积 OOM |
| `FIO_TIMEOUT` | `180s` | fio 单次执行超时，防止 FUSE fsync 永久挂起 |
| `WAIT_TIMEOUT` | `300s` | 挂载点等待超时 |
| `NFS_CREATE_DELAY` | `0.02` | NFS 小文件创建间隔 (秒/文件) |

### fio Pod 资源限制

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `FIO_MEMORY_LIMIT` | `1536Mi` | fio 容器内存上限 (需 > AI_MODEL_SIZE) |
| `FIO_CPU_LIMIT` | `2` | fio 容器 CPU 上限 |
| `RCLONE_MEMORY_LIMIT` | `2560Mi` | rclone 容器内存上限 (含 2G VFS cache) |
| `RCLONE_CPU_LIMIT` | `2` | rclone 容器 CPU 上限 |

### 性能优化参数

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `WEED_MOUNT_CACHE_MB` | `1024` | weed mount 读缓存 (MB)，增大可缓存热数据 |
| `CSI_CONCURRENT_WRITERS` | `128` | CSI driver 并发写入线程数 |
| `NFS_PATH` | `/mnt/seaweedfs/nfs` | NFS 导出路径 |

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
│  │  │  │   seaweedfs    │  │                      │        │     │   │
│  │  │  │ /mnt/image 🔒   │  └──────────────────────┘        │     │   │
│  │  │  └──────────────┘                                   │     │   │
│  │  └────────────────────────────────────────────────────┘     │   │
│  └─────────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────┘
```

### 四种挂载路径对比

| 挂载路径 | 后端 | 存储类 | 读写 | 特点 |
|----------|------|--------|------|------|
| `/mnt/nfs` | NFS v4.2 provisioner → 宿主机 NFS | `seaweedfs-nfs-storage` | 读写 | 标准 NFS 协议，async + 1M rsize/wsize，内核态 |
| `/mnt/s3` | rclone S3 FUSE (sidecar 挂载) | — | 读写 | VFS full cache 2G，read-ahead 128M |
| `/mnt/s3_with_seaweedfs` | seaweedfs-csi-driver | `seaweedfs-storage` | 读写 | CSI 接口，concurrentWriters=128，hostPath 缓存 |
| `/mnt/image` | ImageVolume (OCI 镜像) | — | 🔒 只读 | 零拷贝，预填充数据，镜像构建时生成测试文件 |

### 性能差异分析

NFS 和 ImageVolume 通常最快，S3/CSI 因协议转换开销较慢。四种挂载底层存储路径（除 ImageVolume）都经过 SeaweedFS filer，性能差距来自接入层协议开销。

```
数据流对比 (fio → 数据):

ImageVolume (最快，只读):
  fio → [内核层] → 节点本地缓存(预拉取的镜像层) → 磁盘
  特点: 零网络, 零协议转换, 数据在镜像构建时预填充, 纯本地读取

NFS (读写高性能):
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

| 维度 | ImageVolume | NFS | CSI | S3 (rclone) |
|------|-------------|-----|-----|-------------|
| 接入协议 | 内核层 bind mount | NFS v4.2 内核态 | gRPC 用户态 | HTTP S3 API 用户态 |
| POSIX 兼容 | 🔒 只读 | 原生 | 通过 FUSE 适配 | 通过 rclone FUSE 模拟 |
| 网络开销 | 无 (节点本地) | 低 (TCP) | 中 (gRPC) | 高 (HTTP) |
| 元数据性能 | 最高 (本地 FS) | 高 (内核缓存) | 中 (gRPC 调用) | 低 (HTTP HEAD 翻译) |
| 大文件吞吐 | 最高 | 最高 | 中等 | 较低 |
| 协议转换次数 | 0 | 0 | 1 (FUSE→gRPC) | 2 (FUSE→HTTP→S3) |
| 适合场景 | 模型分发、静态资源 | 通用计算 / 高吞吐 | K8s 原生集成 | 跨平台 S3 兼容 |

**实测数据参考 (本实验环境):**

| 存储后端 | 顺序写 | 顺序读 | 随机写(4k) | 随机读(4k) | AI 模型加载读 | 小文件 IOPS |
|----------|--------|--------|------------|------------|---------------|-------------|
| ImageVolume | — 🔒 | ~3300 MB/s | — 🔒 | ~160k IOPS | ~3300 MB/s | ~18k IOPS |
| NFS | ~570 MB/s | ~650 MB/s | ~868 MB/s | ~160k IOPS | ~2500 MB/s | ~0 (NFS 缓存) |
| CSI | ~50 MB/s | ~500 MB/s | ~200 MB/s | ~90k IOPS | ~1900 MB/s | ~17k IOPS |
| S3 | ~1500 MB/s | ~1800 MB/s | ~150 MB/s | ~49k IOPS | ~900 MB/s | ~18k IOPS |

> **结论**: ImageVolume 在只读场景（模型分发、静态资源）提供零拷贝最优解，适合 AI 推理、静态网站、配置文件分发。NFS 适合高吞吐读写和通用场景。CSI 适合 K8s 原生集成（PVC），S3 适合跨平台兼容但性能有折损。选择取决于业务对读写模式、性能和接口标准的需求。

## ImageVolume 只读测试

通过 Kubernetes ImageVolume 特性，将预置测试数据的 OCI 镜像直接挂载为只读卷，模拟容器镜像分发模型权重或静态资源的场景。

### 构建测试数据镜像

```bash
sudo docker build -t seaweedfs-test-data:local -f docker/Dockerfile.testdata docker/
sudo kind load docker-image seaweedfs-test-data:local --name seaweedfs-lab
```

### 预置数据

| 路径 | 大小 | 用途 |
|------|------|------|
| `/basic_read.dat` | 256M | 基础顺序/随机读 |
| `/basic_randread.dat` | 256M | 基础随机读 |
| `/small_files/fio_small_*.dat` | 2000×16k | 小文件随机读 |
| `/ai_model/ckpt.dat` | 512M | AI 模型加载/分布式读 |

### ImageVolume 测试行为

ImageVolume 为只读挂载，fio 测试自动：

| 操作 | 行为 |
|------|------|
| 写测试 (顺序/随机/checkpoint/log) | ⏭ 跳过 |
| 读测试 (顺序/随机/模型加载/分布式) | ✅ 使用预置文件 |
| 挂载检测 | 9s 快速超时 (不阻塞其他测试) |

### kind 集群启用 ImageVolume

```yaml
# kind-config.yaml 中添加
featureGates:
  ImageVolume: true
```

## 性能优化配置

### NFS v4.2 优化

| 层级 | 配置 | 效果 |
|------|------|------|
| 宿主机 export | `async,no_wdelay` | 异步写入，不等待刷盘 |
| K8s mount | `nfsvers=4.2,rsize=1M,wsize=1M` | 大块 I/O，减少网络往返 |
| K8s mount | `noatime,nodiratime,nocto` | 消除元数据开销 |
| Sysctl | `vm.dirty_bytes=2G` | AI 大文件写入不阻塞 |
| Sysctl | `fs.nfs.nfs_congestion_kb=128M` | NFS 拥塞窗口 |

### rclone S3 优化

| 参数 | 值 | 说明 |
|------|-----|------|
| `--vfs-cache-mode` | `full` | 全缓存模式 |
| `--vfs-cache-max-size` | `2048M` | 磁盘缓存上限 |
| `--vfs-read-ahead` | `128M` | 预读缓冲区 |
| `--buffer-size` | `32M` | 传输缓冲区 |
| `--cache-dir` | `/data/rclone-cache` | 缓存目录 (emptyDir) |

### CSI (s3_with_seaweedfs) 优化

| 层级 | 配置 | 默认值 |
|------|------|--------|
| DaemonSet | `--concurrentWriters=128` | 128 |
| DaemonSet | `--cacheDir=/var/cache/seaweedfs` | hostPath 持久化 |
| StorageClass | `mountOptions: [noatime]` | — |
| 宿主机 | `fs.file-max=2097152` | 海量文件句柄 |
| 宿主机 | `net.core.rmem_max=16MB` | 大块读缓冲 |
| 宿主机 | `net.core.wmem_max=16MB` | 大块写缓冲 |

### 内存安全保护

| 机制 | 说明 |
|------|------|
| CSI 写限速 `--rate=50m` | 防止 FUSE 脏页堆积 OOM |
| fio 超时 `timeout 180s` | 防止 FUSE fsync 永久挂起 |
| run_fio `\|\| true` 保护 | fio 失败不触发 `set -e` 脚本退出 |
| `run_fio_csi_safe_write` | 自动降级重试，无 fsync |
| cleanup trap | EXIT 时清理 /tmp 残留 volume 文件 |

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
| `setup-seaweedfs-lab.sh` | 主入口脚本，集成 kind 集群创建、SeaweedFS 部署、CSI Driver 部署、ImageVolume、fio 测试 |
| `docker/Dockerfile.fio` | fio 测试容器，基于 Alpine 3.20，预装 fio/bash/curl/util-linux |
| `docker/Dockerfile.testdata` | ImageVolume 测试数据镜像，预置 256M/512M 文件和 2000 小文件 |
| `docker/entrypoint-fio.sh` | 容器入口脚本，自动等待挂载点 → 执行四场景测试 → 生成 HTML 报告 |
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

### fio Pod OOMKilled

大文件写入（512M AI checkpoint）会导致 page cache 撑爆容器内存。

```bash
# 确认 OOM
kubectl describe pod -l app=fio-storage | grep OOM

# 解决方案 (选其一):
# 1. 增大 fio 容器内存限制
FIO_MEMORY_LIMIT=2Gi sudo -E ./setup-seaweedfs-lab.sh crds

# 2. 调小 AI 测试文件
AI_MODEL_SIZE=256M sudo -E ./setup-seaweedfs-lab.sh crds

# 3. 禁用 AI 场景
TEST_AI_MODEL=false sudo -E ./setup-seaweedfs-lab.sh crds
```

### CSI Driver (seaweedfs-node) 启动失败

CSI 驱动参数不兼容会导致进程退出并打印 help 文本。

```bash
# 查看日志确认
kubectl logs -l app=seaweedfs-node -c csi-seaweedfs-plugin | head -20

# 常见原因: CSI driver 不支持 --cacheCapacityMB 或 --chunkSizeLimitMB
# 这是 weed mount 的参数，不是 CSI driver 的参数
# 修复: 确保 seaweedfs-csi.yaml 中 args 仅包含 CSI driver 支持的参数
```

### fio 脚本卡在等待挂载点

`mountpoint` 命令在 Alpine 中属于 `util-linux` 包，不在 `coreutils` 中。镜像已包含 `util-linux`。同时脚本有 `stat` 设备 ID 和文件存在性双重回退检测。

```bash
# 检查挂载点是否真的就绪
kubectl exec -l app=fio-storage -c fio-test -- sh -c "
  mountpoint -q /mnt/nfs && echo 'nfs: mounted' || echo 'nfs: NOT mounted'
  ls /mnt/image/basic_read.dat 2>/dev/null && echo 'image: ready' || echo 'image: NOT ready'
"

# ImageVolume 9s 快速超时，不阻塞其他测试
```

### NFS AI 大文件写入卡住

NFS async 模式下脏页达到 `vm.dirty_bytes` 硬上限时会阻塞写入。

```bash
# 增大脏页上限 (临时)
sudo sysctl -w vm.dirty_bytes=2147483648
sudo sysctl -w vm.dirty_background_bytes=1073741824

# 或通过 setup 脚本重部署 NFS 配置
sudo ./setup-seaweedfs-lab.sh seaweedfs
```

### 重建 fio 镜像后 Pod 仍使用旧镜像

K8s `imagePullPolicy: IfNotPresent` + 相同 tag → 永远不复用新镜像。

```bash
# 始终使用唯一 tag 构建
TAG="local-$(date +%s)"
sudo docker build -t seaweedfs-fio-test:$TAG -f docker/Dockerfile.fio docker/
sudo kind load docker-image seaweedfs-fio-test:$TAG --name seaweedfs-lab
sudo kubectl set image deployment/fio-storage-test fio-test=seaweedfs-fio-test:$TAG
```

### weed mount 启动失败

`-chunkSizeLimitMB` 和 `-readAheadSize` 不是 weed mount 的有效参数（当前版本）。

```bash
# 查看 weed mount 日志确认
tail -20 /mnt/seaweedfs/logs/mount.log

# 有效参数: -filer, -dir, -cacheCapacityMB
# 确保未传递不支持的参数
```
