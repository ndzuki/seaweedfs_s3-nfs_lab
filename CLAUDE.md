# SeaweedFS Lab — Claude 上下文

## 环境
- Docker 需 `sudo`
- kind 集群: `seaweedfs-lab`, kubeconfig 在 `~/.kube/config`, context: `kind-seaweedfs-lab`
- kubectl/kind 也需要 `sudo` (docker group 未添加当前用户)
- SSH push: `git push upstream main` (remote: `git@github.com:ndzuki/seaweedfs_s3-nfs_lab.git`)

## 构建 & 部署
- fio 镜像: `docker/Dockerfile.fio` + `docker/entrypoint-fio.sh`, 构建 `docker build -t seaweedfs-fio-test:$TAG -f docker/Dockerfile.fio docker/`
- testdata 镜像: `docker/Dockerfile.testdata` (ImageVolume 只读测试数据)
- **务必使用唯一 tag**: `seaweedfs-fio-test:local-$(date +%Y%m%d%H%M%S)`, 否则 K8s `IfNotPresent` 复用旧镜像
- kind 加载: `sudo kind load docker-image seaweedfs-fio-test:$TAG --name seaweedfs-lab`
- 更新部署: `sudo kubectl set image deployment/fio-storage-test fio-test=seaweedfs-fio-test:$TAG`
- 重部署 CSI: `sudo ./setup-seaweedfs-lab.sh csi`
- 重部署 CRDs (含 fio Pod): `sudo ./setup-seaweedfs-lab.sh crds`

## entrypoint-fio.sh 关键约定
- `set -euo pipefail` — 所有 `run_fio ... | tee` 管线后面必须加 `|| true`, 否则 fio 失败杀脚本
- `local` 只能在函数内使用 — 循环体在最外层时不能有 `local`
- CSI 写操作用 `run_fio_csi_safe_write()` 包装 (去 `--time_based`/`--end_fsync`, 加 `--rate` 限速)
- `is_mountpoint()` 三级回退: `mountpoint -q` → `stat %d` → `[ -f basic_read.dat ]`
- NFS 小文件目录创建后可能立即可见性丢失 (NFS over FUSE 属性缓存), 用 `nfs_dir_broken` flag 跳过后续测试
- `grep -q` 在函数末尾会泄漏退出码 → 函数末尾加 `return 0`

## CSI Driver 参数陷阱
- CSI driver (`seaweedfs-csi.yaml` args) 支持的参数 ≠ `weed mount` 的参数
- ✅ 有效: `--cacheDir`, `--concurrentWriters` (默认 128)
- ❌ 无效: `--cacheCapacityMB`, `--chunkSizeLimitMB`, `--readAheadSize` (这些是 `weed mount` 专有)

## 宿主机 NFS/weed
- weed mount 仅支持 `-filer`, `-dir`, `-cacheCapacityMB`
- NFS async export + `vm.dirty_bytes` 需 > AI_MODEL_SIZE (512M → 至少 2G), 否则写入阻塞
- weed volume 需 `(cd DATA_DIR/volume && nohup ...)` 保护, 防止 CWD 降级写 /tmp

## K8s YAML 陷阱
- Pod `volumes[].nfs` 不支持 `mountOptions` — 只能放 `StorageClass` 或 `PV`
- ImageVolume 需 `pullPolicy: IfNotPresent`, tag 避免 `:latest` (K8s 会尝试 pull)
- `kubectl run --rm -i` 的输出用 `$()` 直接捕获, 不要用 `kubectl logs`

## 测试挂载点
- `/mnt/nfs` — NFS v4.2 provisioner
- `/mnt/s3` — rclone S3 FUSE (VFS full cache)
- `/mnt/s3_with_seaweedfs` — CSI driver (weed mount)
- `/mnt/image` — ImageVolume (OCI 镜像, 🔒 只读)
