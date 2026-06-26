#!/bin/bash
set -euo pipefail

# ============================================================
# setup-seaweedfs-lab.sh — SeaweedFS 实验环境一键部署脚本
# ============================================================
# 功能:
#   1. 部署 kind 集群 (集成 kind-config.yaml)
#   2. 部署 SeaweedFS 服务 (master/volume/filer/s3/NFS)
#   3. 部署 seaweedfs-csi-driver 到 kind 集群
#   4. 部署 NFS/S3/rclone CRDs (环境变量动态配置)
#   5. 挂载 /mnt/nfs, /mnt/s3, /mnt/s3_with_seaweedfs 三目录
#   6. 容器启动时自动执行 fio 三目录对比测试并输出结果
#
# 环境变量 (均有默认值，按需覆盖):
#   SEAWEEDFS_FILER           - filer 地址        (默认: <本机IP>:8888)
#   SEAWEEDFS_MASTER          - master 地址       (默认: <本机IP>:9333)
#   SEAWEEDFS_S3_ENDPOINT     - S3 API 端点       (默认: http://<本机IP>:8333)
#   SEAWEEDFS_S3_ACCESS_KEY   - S3 Access Key     (默认: admin)
#   SEAWEEDFS_S3_SECRET_KEY   - S3 Secret Key     (默认: admin123)
#   NFS_SERVER                - NFS 服务器 IP      (默认: <本机IP>)
#   NFS_PATH                  - NFS 导出路径       (默认: /mnt/seaweedfs/data)
#   KIND_CLUSTER_NAME         - kind 集群名称      (默认: seaweedfs-lab)
#   CSI_DRIVER_VERSION        - CSI 驱动版本       (默认: v1.4.5)
#   S3_BUCKET                 - S3 存储桶名称      (默认: my-test-bucket)
#   FIO_SIZE                  - 基础测试文件大小   (默认: 256M)
#   FIO_RUNTIME               - 基础测试时长       (默认: 60s)
#   TEST_BASIC                - 启用基础读写测试   (默认: true)
#   TEST_SMALL_FILES          - 启用小文件场景     (默认: true)
#   TEST_AI_MODEL             - 启用 AI 大模型场景 (默认: true)
#   SMALL_FILE_COUNT          - 小文件数量         (默认: 2000)
#   SMALL_FILE_SIZE           - 单个小文件大小     (默认: 16k)
#   AI_MODEL_SIZE             - AI 场景测试文件大小(默认: 2G)
#   AI_MODEL_JOBS             - AI 场景并发线程数  (默认: 4)
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================
# 1. 配置与环境变量
# ============================================================

# 获取本机局域网 IP
LOCAL_IP="${LOCAL_IP:-$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7}' || hostname -I | awk '{print $1}')}"

# ---- SeaweedFS 组件地址 ----
export SEAWEEDFS_FILER="${SEAWEEDFS_FILER:-${LOCAL_IP}:8888}"
export SEAWEEDFS_MASTER="${SEAWEEDFS_MASTER:-${LOCAL_IP}:9333}"
export SEAWEEDFS_S3_ENDPOINT="${SEAWEEDFS_S3_ENDPOINT:-http://${LOCAL_IP}:8333}"
export SEAWEEDFS_S3_ACCESS_KEY="${SEAWEEDFS_S3_ACCESS_KEY:-admin}"
export SEAWEEDFS_S3_SECRET_KEY="${SEAWEEDFS_S3_SECRET_KEY:-admin123}"

# ---- NFS 配置 ----
export NFS_SERVER="${NFS_SERVER:-${LOCAL_IP}}"
export NFS_PATH="${NFS_PATH:-/mnt/seaweedfs/data}"
export WEED_MOUNT_CACHE_MB="${WEED_MOUNT_CACHE_MB:-256}"

# ---- Kind 集群 ----
export KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-seaweedfs-lab}"

# 检测真实用户 (sudo 场景下 HOME=/root，需要找到原始用户)
if [ -n "${SUDO_USER:-}" ]; then
	REAL_USER="$SUDO_USER"
	REAL_HOME="$(getent passwd "$SUDO_USER" 2>/dev/null | cut -d: -f6 || echo "/home/$SUDO_USER")"
elif [ "$EUID" -eq 0 ] && [ "$(logname 2>/dev/null || echo root)" != "root" ]; then
	REAL_USER="$(logname 2>/dev/null)"
	REAL_HOME="$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6 || echo "/home/$REAL_USER")"
else
	REAL_USER="${USER:-$(whoami)}"
	REAL_HOME="$HOME"
fi
export REAL_USER REAL_HOME
export KUBECONFIG_FILE="${KUBECONFIG_FILE:-${REAL_HOME}/.kube/config}"

# ---- CSI Driver ----
export CSI_DRIVER_VERSION="${CSI_DRIVER_VERSION:-v1.4.22}"
export CSI_DRIVER_IMAGE="${CSI_DRIVER_IMAGE:-chrislusf/seaweedfs-csi-driver:${CSI_DRIVER_VERSION}}"
export CSI_MOUNT_IMAGE="${CSI_MOUNT_IMAGE:-chrislusf/seaweedfs-mount:${CSI_DRIVER_VERSION}}"
export CSI_CACHE_CAPACITY_MB="${CSI_CACHE_CAPACITY_MB:-256}"
export CSI_PROVISIONER_IMAGE="${CSI_PROVISIONER_IMAGE:-registry.k8s.io/sig-storage/csi-provisioner:v3.5.0}"
export CSI_RESIZER_IMAGE="${CSI_RESIZER_IMAGE:-registry.k8s.io/sig-storage/csi-resizer:v1.8.0}"
export CSI_ATTACHER_IMAGE="${CSI_ATTACHER_IMAGE:-registry.k8s.io/sig-storage/csi-attacher:v4.3.0}"
export CSI_NODE_REGISTRAR_IMAGE="${CSI_NODE_REGISTRAR_IMAGE:-registry.k8s.io/sig-storage/csi-node-driver-registrar:v2.8.0}"
export CSI_LIVENESS_IMAGE="${CSI_LIVENESS_IMAGE:-registry.k8s.io/sig-storage/livenessprobe:v2.10.0}"
export NFS_PROVISIONER_IMAGE="${NFS_PROVISIONER_IMAGE:-registry.k8s.io/sig-storage/nfs-subdir-external-provisioner:v4.0.2}"
export RCLONE_IMAGE="${RCLONE_IMAGE:-rclone/rclone}"
export NGINX_IMAGE="${NGINX_IMAGE:-nginx:alpine}"
export INGRESS_NGINX_CHART_VERSION="${INGRESS_NGINX_CHART_VERSION:-4.13.2}"
# ingress-nginx 镜像 (tag 版本，与 Helm chart 引用一致)
export INGRESS_NGINX_CONTROLLER_IMAGE="${INGRESS_NGINX_CONTROLLER_IMAGE:-registry.k8s.io/ingress-nginx/controller:v1.13.2}"
export INGRESS_WEBHOOK_CERTGEN_IMAGE="${INGRESS_WEBHOOK_CERTGEN_IMAGE:-registry.k8s.io/ingress-nginx/kube-webhook-certgen:v1.6.2}"
export FIO_REPORT_HOST="${FIO_REPORT_HOST:-report.local.com}"

# ---- S3 存储桶 ----
export S3_BUCKET="${S3_BUCKET:-my-test-bucket}"

# ---- fio 测试镜像 ----
export FIO_IMAGE_TAG="${FIO_IMAGE_TAG:-local}"
export FIO_IMAGE="${FIO_IMAGE:-seaweedfs-fio-test:${FIO_IMAGE_TAG}}"

# ---- fio 测试参数 ----
export FIO_SIZE="${FIO_SIZE:-256M}"
export FIO_RUNTIME="${FIO_RUNTIME:-60s}"

# ---- fio 场景开关 ----
export TEST_BASIC="${TEST_BASIC:-true}"
export TEST_SMALL_FILES="${TEST_SMALL_FILES:-true}"
export TEST_AI_MODEL="${TEST_AI_MODEL:-true}"

# ---- 小文件场景参数 ----
export SMALL_FILE_COUNT="${SMALL_FILE_COUNT:-2000}"
export SMALL_FILE_SIZE="${SMALL_FILE_SIZE:-16k}"
export SMALL_FILE_RUNTIME="${SMALL_FILE_RUNTIME:-120s}"
export NFS_CACHE_WAIT="${NFS_CACHE_WAIT:-0}"

# ---- AI 大模型场景参数 ----
export AI_MODEL_SIZE="${AI_MODEL_SIZE:-512M}"
export AI_MODEL_RUNTIME="${AI_MODEL_RUNTIME:-120s}"
export AI_MODEL_JOBS="${AI_MODEL_JOBS:-4}"

# ---- 基础路径 ----
BASE_DIR="/mnt/seaweedfs"
DATA_DIR="${BASE_DIR}/data"
LOG_DIR="${BASE_DIR}/logs"
NFS_MOUNT="${BASE_DIR}/data"

# ---- 颜色输出 ----
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC}  $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
log_step() { echo -e "\n${CYAN}━━━ $* ━━━${NC}"; }
log_detail() { echo -e "${BLUE}  ➜${NC} $*"; }

# ============================================================
# 2. 工具函数
# ============================================================

# 检查命令是否存在
check_command() {
	local cmd="$1"
	local hint="${2:-}"
	if ! command -v "$cmd" &>/dev/null; then
		log_error "未找到命令 '$cmd'，请先安装。${hint}"
		return 1
	fi
}

# 检查必要工具
check_prerequisites() {
	local missing=()
	for cmd in kubectl kind helm; do
		if ! command -v "$cmd" &>/dev/null; then
			missing+=("$cmd")
		fi
	done
	if [[ ${#missing[@]} -gt 0 ]]; then
		log_error "缺少必要工具: ${missing[*]}"
		echo "  安装 kind:  https://kind.sigs.k8s.io/docs/user/quick-start/"
		echo "  安装 kubectl: https://kubernetes.io/docs/tasks/tools/"
		return 1
	fi
}

# envsubst 回退方案 (部分精简系统未安装 gettext)
safe_envsubst() {
	local input="$1"
	if command -v envsubst &>/dev/null; then
		envsubst <"$input"
	else
		# 手动替换 ${VAR} 占位符
		local content
		content=$(cat "$input")
		for var in SEAWEEDFS_FILER SEAWEEDFS_MASTER SEAWEEDFS_S3_ENDPOINT \
			SEAWEEDFS_S3_ACCESS_KEY SEAWEEDFS_S3_SECRET_KEY \
			NFS_SERVER NFS_PATH S3_BUCKET KIND_CLUSTER_NAME \
			FIO_IMAGE NGINX_IMAGE FIO_REPORT_HOST \
			TEST_BASIC TEST_SMALL_FILES TEST_AI_MODEL \
			SMALL_FILE_COUNT SMALL_FILE_SIZE SMALL_FILE_RUNTIME \
				NFS_CACHE_WAIT \
			AI_MODEL_SIZE AI_MODEL_RUNTIME AI_MODEL_JOBS \
			FIO_SIZE FIO_RUNTIME; do
			content="${content//\$\{${var}\}/$(eval echo "\$$var")}"
		done
		echo "$content"
	fi
}

# 等待 Pod 就绪
wait_for_pod() {
	local namespace="$1"
	local label="$2"
	local timeout="${3:-120}"
	log_info "等待 Pod 就绪 (ns=$namespace, label=$label, timeout=${timeout}s)..."
	kubectl wait --for=condition=Ready pod \
		-n "$namespace" \
		-l "$label" \
		--timeout="${timeout}s" 2>/dev/null || {
		log_warn "部分 Pod 未在 ${timeout}s 内就绪，继续执行..."
	}
}

# ============================================================
# 3. Kind 集群管理
# ============================================================

# 生成 kind 配置文件 (集成 kind-config.yaml 内容)
generate_kind_config() {
	local config_file="${SCRIPT_DIR}/.kind-config-generated.yaml"
	cat >"$config_file" <<KINDEOF
# kind 集群配置 — 由 setup-seaweedfs-lab.sh 生成
# 集群名称: ${KIND_CLUSTER_NAME}
apiVersion: kind.x-k8s.io/v1alpha4
kind: Cluster
name: ${KIND_CLUSTER_NAME}
nodes:
  - role: control-plane
    # 移除 control-plane taint，允许 Pod 调度到该节点
    # (实验环境仅有 2 节点，taint 会导致 anti-affinity 和单副本调度失败)
    kubeadmConfigPatches:
    - |
      kind: InitConfiguration
      nodeRegistration:
        taints: []
    # 端口映射：host → kind 容器内，localhost 即可访问 ingress
    extraPortMappings:
    - containerPort: 30080
      hostPort: 30080
      protocol: TCP
    - containerPort: 30443
      hostPort: 30443
      protocol: TCP
  - role: worker
KINDEOF
	echo "$config_file"
}
# 将 kind 集群 kubeconfig 合并到指定配置文件
# 从 kind get kubeconfig 提取最新端点/凭证，更新或创建条目
merge_kubeconfig() {
	local kubeconfig="${1:-${KUBECONFIG_FILE}}"
	local cluster_name="$2"
	local config_dir
	config_dir="$(dirname "$kubeconfig")"
	local ctx_name="kind-${cluster_name}"

	mkdir -p "$config_dir"
	if [ -n "${REAL_USER:-}" ] && [ "$EUID" -eq 0 ]; then
		chown "${REAL_USER}:" "$config_dir" 2>/dev/null || true
	fi

	# 备份
	if [ -f "$kubeconfig" ]; then
		cp "$kubeconfig" "${kubeconfig}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null || true
	fi

	# 导出 kind 集群当前 kubeconfig
	local kind_cfg="/tmp/kind-${cluster_name}.kubeconfig"
	kind get kubeconfig --name "$cluster_name" >"$kind_cfg" 2>/dev/null || {
		log_warn "无法获取 kind 集群 kubeconfig，跳过合并。"
		return 1
	}

	local server client_cert client_key ca_data
	server=$(grep 'server:' "$kind_cfg" | head -1 | awk '{print $2}')
	ca_data=$(grep 'certificate-authority-data:' "$kind_cfg" | head -1 | awk '{print $2}')
	client_cert=$(grep 'client-certificate-data:' "$kind_cfg" | head -1 | awk '{print $2}')
	client_key=$(grep 'client-key-data:' "$kind_cfg" | head -1 | awk '{print $2}')
	# 校验提取的字段非空，避免写入无效 kubeconfig
	if [ -z "$server" ] || [ -z "$ca_data" ] || [ -z "$client_cert" ] || [ -z "$client_key" ]; then
		log_warn "kind kubeconfig 解析失败，跳过合并。"
		rm -f "$kind_cfg"
		return 1
	fi

	# 如果条目已存在则更新，否则创建 (不删除避免中断 kubectl 后续操作)
	if KUBECONFIG="$kubeconfig" kubectl config get-clusters 2>/dev/null | grep -qx "$ctx_name"; then
		# 更新 server/凭证 (集群重建后端口会变)
		KUBECONFIG="$kubeconfig" kubectl config set-cluster "$ctx_name" \
			--server="$server" \
			--certificate-authority-data="$ca_data" \
			--embed-certs=true 2>/dev/null || true
		KUBECONFIG="$kubeconfig" kubectl config set-credentials "$ctx_name" \
			--client-certificate-data="$client_cert" \
			--client-key-data="$client_key" \
			--embed-certs=true 2>/dev/null || true
	else
		# 首次创建
		KUBECONFIG="$kubeconfig" kubectl config set-cluster "$ctx_name" \
			--server="$server" \
			--certificate-authority-data="$ca_data" \
			--embed-certs=true 2>/dev/null || true
		KUBECONFIG="$kubeconfig" kubectl config set-credentials "$ctx_name" \
			--client-certificate-data="$client_cert" \
			--client-key-data="$client_key" \
			--embed-certs=true 2>/dev/null || true
		KUBECONFIG="$kubeconfig" kubectl config set-context "$ctx_name" \
			--cluster="$ctx_name" \
			--user="$ctx_name" 2>/dev/null || true
	fi

	rm -f "$kind_cfg"

	# 修复权限与归属
	chmod 600 "$kubeconfig" 2>/dev/null || true
	if [ -n "${REAL_USER:-}" ] && [ "$EUID" -eq 0 ]; then
		chown "${REAL_USER}:" "$kubeconfig" 2>/dev/null || true
	fi
	# 确保当前上下文指向该集群
	KUBECONFIG="$kubeconfig" kubectl config use-context "$ctx_name" 2>/dev/null || true
	log_info "kubeconfig 已同步: ${kubeconfig} (context: ${ctx_name})"
}

create_kind_cluster() {
	log_step "创建 kind 集群: ${KIND_CLUSTER_NAME}"

	if kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER_NAME}$"; then
		log_warn "kind 集群 '${KIND_CLUSTER_NAME}' 已存在，跳过创建。"
		# 集群已存在，刷新 kubeconfig (端口可能已变)
		merge_kubeconfig "${KUBECONFIG_FILE}" "${KIND_CLUSTER_NAME}"
		KUBECONFIG="${KUBECONFIG_FILE}" kubectl config use-context "kind-${KIND_CLUSTER_NAME}" &>/dev/null || true
		return 0
	fi

	local config_file
	config_file=$(generate_kind_config)
	log_detail "使用配置文件: ${config_file}"

	# kind create cluster 会自动将 context/cluster/user 写入 ~/.kube/config
	kind create cluster --config "$config_file"

	# 预加载所有实验镜像到 kind 节点 (避免 Pod 启动时在线拉取)
	preload_images

	# 合并 kubeconfig 到用户配置 (kind 写入默认路径，需同步到 KUBECONFIG_FILE)
	merge_kubeconfig "${KUBECONFIG_FILE}" "${KIND_CLUSTER_NAME}"
	KUBECONFIG="${KUBECONFIG_FILE}" kubectl config use-context "kind-${KIND_CLUSTER_NAME}" 2>/dev/null || true

	# 修复权限 (sudo 场景)
	if [ -n "${REAL_USER:-}" ] && [ "$EUID" -eq 0 ]; then
		local kcfg="${KUBECONFIG_FILE}"
		chmod 600 "$kcfg" 2>/dev/null || true
		chown "${REAL_USER}:" "$kcfg" 2>/dev/null || true
		chown "${REAL_USER}:" "$(dirname "$kcfg")" 2>/dev/null || true
	fi

	log_info "kind 集群 '${KIND_CLUSTER_NAME}' 创建成功。"
	kubectl cluster-info --context "kind-${KIND_CLUSTER_NAME}" 2>/dev/null || true
}

# 删除 kind 集群
delete_kind_cluster() {
	log_step "删除 kind 集群: ${KIND_CLUSTER_NAME}"
	if kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER_NAME}$"; then
		kind delete cluster --name "${KIND_CLUSTER_NAME}"
		log_info "kind 集群 '${KIND_CLUSTER_NAME}' 已删除。"
	else
		log_warn "kind 集群 '${KIND_CLUSTER_NAME}' 不存在，跳过删除。"
	fi
	rm -f "${SCRIPT_DIR}/.kind-config-generated.yaml"
}

# ============================================================
# 4. SeaweedFS 原生服务部署 (宿主机)
# ============================================================

deploy_seaweedfs_services() {
	log_step "部署 SeaweedFS 原生服务 (master/volume/filer/s3/NFS)"

	# 检查 weed 二进制
	if ! command -v weed &>/dev/null; then
		log_error "未找到 'weed' 二进制，请先下载并放入 PATH。"
		echo "  wget https://github.com/seaweedfs/seaweedfs/releases/latest"
		return 1
	fi

	# 检查是否已运行
	if ps aux | grep "weed master" | grep -v grep &>/dev/null; then
		log_warn "SeaweedFS 服务已在运行中。如需重启请先执行 uninstall。"
		return 0
	fi

	# 1. 创建目录
	log_info "创建环境目录..."
	mkdir -p "${DATA_DIR}/master" "${DATA_DIR}/volume" "${DATA_DIR}/filer"
	mkdir -p "${LOG_DIR}" "${NFS_MOUNT}"
	chmod -R 777 "${BASE_DIR}"
	chmod 777 "${NFS_MOUNT}"

	# 2. 安装 NFS 依赖
	log_info "检查并安装 NFS 依赖..."
	if grep -qEi 'debian|ubuntu' /etc/os-release 2>/dev/null; then
		apt-get update -y && apt-get install -y nfs-kernel-server rpcbind 2>/dev/null || true
	elif grep -qEi 'centos|fedora|rhel|rocky|alma' /etc/os-release 2>/dev/null; then
		dnf install -y nfs-utils rpcbind 2>/dev/null || yum install -y nfs-utils rpcbind 2>/dev/null || true
	elif grep -qEi 'arch' /etc/os-release 2>/dev/null; then
		pacman -S --noconfirm nfs-utils 2>/dev/null || true
	fi
	modprobe nfs 2>/dev/null || true
	modprobe nfsd 2>/dev/null || true

	# 3. FUSE allow_other 权限
	log_info "配置 FUSE 权限..."
	if [ -f /etc/fuse.conf ]; then
		sed -i 's/#user_allow_other/user_allow_other/g' /etc/fuse.conf
		grep -q "^user_allow_other" /etc/fuse.conf || echo "user_allow_other" >>/etc/fuse.conf
	else
		echo "user_allow_other" >/etc/fuse.conf
	fi

	# 4. 启动 Master
	log_info "启动 Master (${SEAWEEDFS_MASTER})..."
	nohup weed master \
		-ip="${LOCAL_IP}" \
		-port=9333 \
		\t -port.grpc=19333 \
		-mdir="${DATA_DIR}/master" \
		-volumeSizeLimitMB=10240 \
		-volumePreallocate \
		>"${LOG_DIR}/master.log" 2>&1 &
	sleep 2

	# 5. 启动 Volume
	log_info "启动 Volume (${LOCAL_IP}:8080)..."
	nohup weed volume \
		-mserver="${SEAWEEDFS_MASTER}" \
		-ip="${LOCAL_IP}" \
		-port=8080 \
		\t -port.grpc=18080 \
		-dir="${DATA_DIR}/volume" \
		-images.fix.orientation=false \
		>"${LOG_DIR}/volume.log" 2>&1 &
	sleep 2

	# 6. 启动 Filer
	log_info "启动 Filer (${SEAWEEDFS_FILER})..."
	nohup weed filer \
		-master="${SEAWEEDFS_MASTER}" \
		-ip="${LOCAL_IP}" \
		-port=8888 \
		-port.grpc=18888 \
		>"${LOG_DIR}/filer.log" 2>&1 &
	sleep 2

	# 7. 启动 S3 API
	log_info "启动 S3 API (${SEAWEEDFS_S3_ENDPOINT})..."
	export AWS_ACCESS_KEY_ID="${SEAWEEDFS_S3_ACCESS_KEY}"
	export AWS_SECRET_ACCESS_KEY="${SEAWEEDFS_S3_SECRET_KEY}"
	nohup weed s3 \
		-filer="${SEAWEEDFS_FILER}" \
		-port=8333 \
		-allowEmptyFolder=true \
		>"${LOG_DIR}/s3.log" 2>&1 &
	sleep 2

	# 8. FUSE mount (Filer → 本地目录)
	log_info "FUSE 挂载 Filer → ${NFS_MOUNT}..."
	umount -l "${NFS_MOUNT}" 2>/dev/null || true
	# 确保挂载点可用 (最多重试 3 次, 等待时间递增)
	local mount_ok=0
	for attempt in 1 2 3; do
		umount -l "${NFS_MOUNT}" 2>/dev/null || true
		nohup weed mount \
			-filer="${SEAWEEDFS_FILER}" \
			-dir="${NFS_MOUNT}" \
			-cacheCapacityMB="${WEED_MOUNT_CACHE_MB:-256}" \
			>"${LOG_DIR}/mount.log" 2>&1 &
		local mount_pid=$!
		# 等待时间递增: 3s → 5s → 8s
		local wait_time=$(( attempt * 2 + 1 ))
		sleep "${wait_time}"
		if mountpoint -q "${NFS_MOUNT}" 2>/dev/null; then
			log_info "FUSE 挂载成功: ${NFS_MOUNT}"
			mount_ok=1; break
		fi
		# 检查进程是否存活
		if ! kill -0 "${mount_pid}" 2>/dev/null; then
			log_warn "weed mount 进程已退出 (尝试 ${attempt}/3), 日志:"
			tail -3 "${LOG_DIR}/mount.log" 2>/dev/null | while IFS= read -r l; do log_warn "  ${l}"; done
		else
			log_warn "挂载未就绪 (尝试 ${attempt}/3, 等待 ${wait_time}s)"
		fi
	done
	if [ "${mount_ok}" -eq 0 ]; then
		log_error "FUSE 挂载失败! 检查 filer 是否运行: ${SEAWEEDFS_FILER}"
		log_error "  日志: ${LOG_DIR}/mount.log"
	fi

	# 9. 配置 NFS 导出
	log_info "配置 NFS 导出..."
	sed -i '\#^/mnt/seaweedfs#d' /etc/exports 2>/dev/null || true
	# 每次重写而非追加，避免重复条目累积
	cat >>/etc/exports <<EOF
${NFS_MOUNT} 172.16.0.0/12(rw,sync,no_subtree_check,fsid=1,no_root_squash,insecure)
${NFS_MOUNT} 10.0.0.0/8(rw,sync,no_subtree_check,fsid=1,no_root_squash,insecure)
EOF

	# 10. 重启 NFS 服务
	log_info "重启 NFS 服务..."
	if command -v systemctl &>/dev/null; then
		systemctl enable rpcbind 2>/dev/null || true
		systemctl restart rpcbind 2>/dev/null || true
		systemctl enable nfs-server 2>/dev/null || systemctl enable nfs-kernel-server 2>/dev/null || true
		systemctl restart nfs-server 2>/dev/null || systemctl restart nfs-kernel-server 2>/dev/null || true
	else
		service rpcbind restart 2>/dev/null || true
		service nfs-kernel-server restart 2>/dev/null || service nfs-server restart 2>/dev/null || true
	fi
	exportfs -rav 2>/dev/null || true

	log_info "SeaweedFS 服务部署完成！"
	echo "  Filer Web : http://${SEAWEEDFS_FILER}"
	echo "  S3 API    : ${SEAWEEDFS_S3_ENDPOINT}"
	echo "  NFS 导出  : ${NFS_SERVER}:${NFS_MOUNT}"
}

# ============================================================
# 5. seaweedfs-csi-driver 部署
# ============================================================

deploy_csi_driver() {
	log_step "部署 seaweedfs-csi-driver 到 kind 集群"

	# 清理旧 CSI PVC finalizer (防止 Terminating 阻塞重建)
	kubectl get pvc seaweedfs-csi-pvc >/dev/null 2>&1 && {
		kubectl patch pvc seaweedfs-csi-pvc -p '"'"'{"metadata":{"finalizers":[]}}'"'"' --type=merge 2>/dev/null || true
		kubectl delete pvc seaweedfs-csi-pvc --force --grace-period=0 2>/dev/null || true
		sleep 2
	} || true

	local csi_yaml="${SCRIPT_DIR}/seaweedfs-csi-driver-master/deploy/kubernetes/seaweedfs-csi.yaml"

	if [ ! -f "$csi_yaml" ]; then
		log_error "CSI driver YAML 不存在: ${csi_yaml}"
		return 1
	fi

	# 从 YAML 中提取 filer 地址占位符并替换
	# seaweedfs-csi.yaml 中 SEAWEEDFS_FILER 的值为 "SEAWEEDFS_FILER:8888"
	# 需要替换为实际的 filer 地址
	local tmp_yaml="${SCRIPT_DIR}/.csi-driver-patched.yaml"

	log_info "替换 CSI driver 配置: filer=${SEAWEEDFS_FILER}, cache=${CSI_CACHE_CAPACITY_MB}MB, version=${CSI_DRIVER_VERSION}"
	sed -e "s|value: \"SEAWEEDFS_FILER:8888\"|value: \"${SEAWEEDFS_FILER}\"|g" \
		-e "s|SEAWEEDFS_FILER:8888|${SEAWEEDFS_FILER}|g" \
		-e "s|--cacheCapacityMB=[0-9]*|--cacheCapacityMB=${CSI_CACHE_CAPACITY_MB}|g" \
		-e "s|image: chrislusf/seaweedfs-csi-driver:.*|image: ${CSI_DRIVER_IMAGE}|g" \
		-e "s|image: chrislusf/seaweedfs-mount:.*|image: ${CSI_MOUNT_IMAGE}|g" \
		"$csi_yaml" >"$tmp_yaml"

	log_info "应用 CSI driver 资源..."
	kubectl apply -f "$tmp_yaml"

	log_info "等待 CSI driver 组件就绪..."
	wait_for_pod "default" "app=seaweedfs-controller" 120
	wait_for_pod "default" "app=seaweedfs-node" 120
	wait_for_pod "default" "app=seaweedfs-mount" 120

	rm -f "$tmp_yaml"

	log_info "CSI driver 部署完成。"
	kubectl get pods -l 'app in (seaweedfs-controller,seaweedfs-node,seaweedfs-mount)' 2>/dev/null || true
}

# ============================================================
# 6. 预加载镜像到 kind 集群 (构建 + 拉取 + 导入)
# ============================================================

preload_images() {
	log_step "预加载镜像到 kind 集群: ${KIND_CLUSTER_NAME}"

	# ---- 1. 构建 fio 测试镜像 ----
	local dockerfile="${SCRIPT_DIR}/docker/Dockerfile.fio"
	if [ ! -f "$dockerfile" ]; then
		log_error "Dockerfile 不存在: ${dockerfile}"
		return 1
	fi
	if docker image inspect "${FIO_IMAGE}" &>/dev/null; then
		log_detail "跳过构建: ${FIO_IMAGE} (已存在)"
	else
		log_info "构建: ${FIO_IMAGE} ..."
		docker build -t "${FIO_IMAGE}" -f "$dockerfile" "${SCRIPT_DIR}/docker"
	fi

	# ---- 2. 拉取 CSI / NFS / rclone 等外部镜像 ----
	local images=(
		"${CSI_DRIVER_IMAGE}"
		"${CSI_MOUNT_IMAGE}"
		"${CSI_PROVISIONER_IMAGE}"
		"${CSI_RESIZER_IMAGE}"
		"${CSI_ATTACHER_IMAGE}"
		"${CSI_NODE_REGISTRAR_IMAGE}"
		"${CSI_LIVENESS_IMAGE}"
		"${NFS_PROVISIONER_IMAGE}"
		"${RCLONE_IMAGE}"
		"${NGINX_IMAGE}"
		"${INGRESS_NGINX_CONTROLLER_IMAGE}"
		"${INGRESS_WEBHOOK_CERTGEN_IMAGE}"
	)

	for img in "${images[@]}"; do
		if docker image inspect "$img" &>/dev/null; then
			log_detail "跳过拉取: ${img} (已存在)"
		else
			log_info "拉取: ${img} ..."
			docker pull "$img" || log_warn "拉取失败: ${img} (将尝试在线拉取)"
		fi
	done

	# ---- 3. 批量导入 kind 节点 ----
	log_info "导入镜像到 kind 节点..."
	kind load docker-image "${FIO_IMAGE}" --name "${KIND_CLUSTER_NAME}"
	for img in "${images[@]}"; do
		if docker image inspect "$img" &>/dev/null; then
			log_detail "导入: ${img}"
			kind load docker-image "$img" --name "${KIND_CLUSTER_NAME}" || log_warn "导入失败: ${img}"
		fi
	done

	log_info "所有镜像预加载完成 (1 构建 + ${#images[@]} 导入)。"
}

# 兼容旧函数名
build_fio_image() {
	preload_images
}

# ============================================================
# 7. NFS / S3 / rclone CRDs 部署 (环境变量动态配置)
# ============================================================

deploy_nfs_s3_rclone() {
	log_step "部署 NFS/S3/rclone CRDs (环境变量动态配置)"
	local rendered="/tmp/nfs_s3_rclone_rendered.yaml"

	log_info "渲染模板 (NFS_SERVER=${NFS_SERVER}, NFS_PATH=${NFS_PATH})..."
	log_info "         (SEAWEEDFS_S3_ENDPOINT=${SEAWEEDFS_S3_ENDPOINT})..."

	# 创建带环境变量占位符的临时模板
	cat >"/tmp/nfs_s3_rclone_template.yaml" <<'TMPLEOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: nfs-client-provisioner
  namespace: kube-system
---
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: nfs-client-provisioner-runner
rules:
  - apiGroups: [""]
    resources: ["persistentvolumes"]
    verbs: ["get", "list", "watch", "create", "delete"]
  - apiGroups: [""]
    resources: ["persistentvolumeclaims"]
    verbs: ["get", "list", "watch", "update"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["storageclasses"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create", "update", "patch"]
  - apiGroups: [""]
    resources: ["nodes"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["endpoints"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
  - apiGroups: ["coordination.k8s.io"]
    resources: ["leases"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: run-nfs-client-provisioner
subjects:
  - kind: ServiceAccount
    name: nfs-client-provisioner
    namespace: kube-system
roleRef:
  kind: ClusterRole
  name: nfs-client-provisioner-runner
  apiGroup: rbac.authorization.k8s.io
---
kind: Role
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: leader-locking-nfs-client-provisioner
  namespace: kube-system
rules:
  - apiGroups: [""]
    resources: ["endpoints"]
    verbs: ["get", "list", "watch", "create", "update", "patch"]
  - apiGroups: ["coordination.k8s.io"]
    resources: ["leases"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
kind: RoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  name: leader-locking-nfs-client-provisioner
subjects:
  - kind: ServiceAccount
    name: nfs-client-provisioner
    namespace: kube-system
roleRef:
  kind: Role
  name: leader-locking-nfs-client-provisioner
  apiGroup: rbac.authorization.k8s.io
---
# NFS Provisioner Deployment
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nfs-client-provisioner
  namespace: kube-system
  labels:
    app: nfs-client-provisioner
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: nfs-client-provisioner
  template:
    metadata:
      labels:
        app: nfs-client-provisioner
    spec:
      serviceAccountName: nfs-client-provisioner
      containers:
        - name: nfs-client-provisioner
          image: registry.k8s.io/sig-storage/nfs-subdir-external-provisioner:v4.0.2
          volumeMounts:
            - name: nfs-client-root
              mountPath: /persistentvolumes
          env:
            - name: PROVISIONER_NAME
              value: seaweedfs/nfs-provisioner
            - name: NFS_SERVER
              value: "${NFS_SERVER}"
            - name: NFS_PATH
              value: "${NFS_PATH}"
      volumes:
        - name: nfs-client-root
          nfs:
            server: ${NFS_SERVER}
            path: ${NFS_PATH}
---
# NFS StorageClass
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: seaweedfs-nfs-storage
provisioner: seaweedfs/nfs-provisioner
reclaimPolicy: Delete
volumeBindingMode: Immediate
---
# NFS PVC
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: seaweedfs-nfs-pvc
spec:
  storageClassName: seaweedfs-nfs-storage
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 10Gi
---
# CSI PVC (seaweedfs-csi-driver)
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: seaweedfs-csi-pvc
spec:
  storageClassName: seaweedfs-storage
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 10Gi
---
# fio 测试 Deployment (三目录挂载: /mnt/nfs / /mnt/s3 / /mnt/s3_with_seaweedfs)
apiVersion: apps/v1
kind: Deployment
metadata:
  name: fio-storage-test
  labels:
    app: fio-storage
spec:
  replicas: 1
  selector:
    matchLabels:
      app: fio-storage
  template:
    metadata:
      labels:
        app: fio-storage
    spec:
      containers:
        # 主容器: fio 测试 (预装 fio 工具，挂载 nfs / s3 / s3_csi 三个目录)
        - name: fio-test
          image: ${FIO_IMAGE}
          imagePullPolicy: IfNotPresent
          volumeMounts:
            - name: nfs-volume
              mountPath: /mnt/nfs
            - name: s3-shared-volume
              mountPath: /mnt/s3
              subPath: s3
              mountPropagation: HostToContainer
            - name: s3-csi-volume
              mountPath: /mnt/s3_with_seaweedfs
              mountPropagation: HostToContainer
            - name: results-volume
              mountPath: /tmp/fio-results
          env:
            # 场景开关
            - name: TEST_BASIC
              value: "${TEST_BASIC}"
            - name: TEST_SMALL_FILES
              value: "${TEST_SMALL_FILES}"
            - name: TEST_AI_MODEL
              value: "${TEST_AI_MODEL}"
            # 基础测试参数
            - name: TEST_SIZE
              value: "${FIO_SIZE}"
            - name: TEST_RUNTIME
              value: "${FIO_RUNTIME}"
            # 小文件场景
            - name: SMALL_FILE_COUNT
              value: "${SMALL_FILE_COUNT}"
            - name: SMALL_FILE_SIZE
              value: "${SMALL_FILE_SIZE}"
            - name: SMALL_FILE_RUNTIME
              value: "${SMALL_FILE_RUNTIME}"
            - name: NFS_CACHE_WAIT
              value: "${NFS_CACHE_WAIT}"
            # AI 大模型场景
            - name: AI_MODEL_SIZE
              value: "${AI_MODEL_SIZE}"
            - name: AI_MODEL_RUNTIME
              value: "${AI_MODEL_RUNTIME}"
            - name: AI_MODEL_JOBS
              value: "${AI_MODEL_JOBS}"

        # Nginx: 静态文件服务，暴露 fio 测试结果 HTML
        - name: nginx
          image: ${NGINX_IMAGE}
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 80
          readinessProbe:
            tcpSocket:
              port: 80
            initialDelaySeconds: 3
            periodSeconds: 5
          volumeMounts:
            - name: results-volume
              mountPath: /usr/share/nginx/html

        # Sidecar: rclone S3 挂载 + 同步
        - name: s3-sidecar
          image: rclone/rclone
          imagePullPolicy: IfNotPresent
          securityContext:
            privileged: true
          lifecycle:
            preStop:
              exec:
                command: ["/bin/sh", "-c", "umount -f /data/s3 2>/dev/null; exit 0"]
          command: ["/bin/sh"]
          args:
            - -c
            - |
              sleep 3
              umount -l /data/s3 2>/dev/null || true

              # 创建 S3 存储桶
              rclone mkdir sw_s3:${S3_BUCKET} 2>/dev/null || true

              # 前台 FUSE 挂载 S3 → /data/s3
              rclone mount sw_s3:${S3_BUCKET} /data/s3 \
                --allow-other \
                --allow-non-empty \
                --vfs-cache-mode full \
                --no-modtime &

              sleep 2
              echo "[s3-sidecar] S3 挂载就绪，启动同步守护..."

              while true; do
                rclone sync sw_s3:${S3_BUCKET} /data/nfs \
                  --create-empty-src-dirs \
                  --modify-window 2s \
                  --update \
                  -v 2>&1 | tail -5
                sleep 5
              done
          env:
            - name: RCLONE_CONFIG_SW_S3_TYPE
              value: s3
            - name: RCLONE_CONFIG_SW_S3_PROVIDER
              value: Other
            - name: RCLONE_CONFIG_SW_S3_ENDPOINT
              value: "${SEAWEEDFS_S3_ENDPOINT}"
            - name: RCLONE_CONFIG_SW_S3_ENV_AUTH
              value: "true"
            - name: RCLONE_CONFIG_SW_S3_ACCESS_KEY_ID
              value: "${SEAWEEDFS_S3_ACCESS_KEY}"
            - name: RCLONE_CONFIG_SW_S3_SECRET_ACCESS_KEY
              value: "${SEAWEEDFS_S3_SECRET_KEY}"
          volumeMounts:
            - name: s3-shared-volume
              mountPath: /data
              mountPropagation: Bidirectional
            - name: nfs-volume
              mountPath: /data/nfs

      volumes:
        - name: nfs-volume
          persistentVolumeClaim:
            claimName: seaweedfs-nfs-pvc
        - name: s3-shared-volume
          emptyDir:
            medium: Memory
        - name: s3-csi-volume
          persistentVolumeClaim:
            claimName: seaweedfs-csi-pvc
        - name: results-volume
          emptyDir: {}
TMPLEOF

	# 使用 safe_envsubst 渲染模板
	safe_envsubst "/tmp/nfs_s3_rclone_template.yaml" >"$rendered"

	log_info "应用渲染后的资源..."
	kubectl apply -f "$rendered"

	# 创建 Service + Ingress (独立于模板，域名可配置)
	cat >"${SCRIPT_DIR}/.fio-report-ingress.yaml" <<EOF
apiVersion: v1
kind: Service
metadata:
  name: fio-report
  labels:
    app: fio-storage
spec:
  selector:
    app: fio-storage
  ports:
    - name: http
      port: 80
      targetPort: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: fio-report
spec:
  ingressClassName: nginx
  rules:
    - host: ${FIO_REPORT_HOST:-report.local.com}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: fio-report
                port:
                  number: 80
EOF
	kubectl apply -f "${SCRIPT_DIR}/.fio-report-ingress.yaml" 2>/dev/null || true

	# 清理临时文件
	rm -f "/tmp/nfs_s3_rclone_template.yaml" "/tmp/nfs_s3_rclone_rendered.yaml" "$rendered"

	log_info "等待 NFS provisioner 就绪..."
	wait_for_pod "kube-system" "app=nfs-client-provisioner" 60

	log_info "等待 fio 测试 Pod 就绪..."
	wait_for_pod "default" "app=fio-storage" 120

	# 等待容器内自动 fio 测试完成
	local pod_name
	pod_name=$(kubectl get pods -l app=fio-storage -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
	if [ -n "$pod_name" ]; then
		log_info "跟踪容器自动 fio 测试日志 (基础+小文件+AI模型 三场景)..."
		log_info "  (预计耗时 5-15 分钟，可 Ctrl+C 跳过，测试在后台继续)"
		kubectl logs -f "$pod_name" -c fio-test 2>/dev/null | while IFS= read -r line; do
			echo "  $line"
			[[ "$line" == *"测试完成"* ]] && break
		done || true
	fi


		# 诊断 kind 容器 → 宿主机 weed 服务连通性 (volume server 端口不可达会导致 CSI 测试失败)
		check_kind_host_connectivity

		log_info "NFS/S3/rclone CRDs 部署完成。"
		kubectl get pods -A 2>/dev/null | grep -E 'nfs-client-provisioner|fio-storage' || true

# 诊断 kind 容器内是否能连通宿主机 weed 服务的关键端口
# 若 volume server 端口不可达，CSI 挂载的 fio 数据写入会失败
check_kind_host_connectivity() {
	log_step "诊断 kind → 宿主机 weed 服务连通性"

	local filer_ip="${SEAWEEDFS_FILER%:*}"

	log_info "从 kind 容器内测试 TCP 连通性到 ${filer_ip}..."

	kubectl run connectivity-check --rm -i --restart=Never --image=busybox:1.36 \
		-- sh -c "
for port in 8888 18888 8080 18080 8333; do
    if timeout 3 nc -z ${filer_ip} \$port 2>/dev/null; then
        echo \"OK:\$port\"
    else
        echo \"FAIL:\$port\"
    fi
done
" 2>/dev/null || true

	local result
	result=$(kubectl logs connectivity-check 2>/dev/null || true)
	kubectl delete pod connectivity-check --force --grace-period=0 2>/dev/null || true

	if [ -n "$result" ]; then
		echo "$result" | while IFS= read -r line; do
			case "$line" in
				*OK:*)   log_info "  🟢 ${line#*OK:}" ;;
				*FAIL:*) log_warn "  🔴 ${line#*FAIL:} — 端口不可达!" ;;
			esac
		done

		if echo "$result" | grep -q "FAIL:8080\|FAIL:18080"; then
			echo ""
			log_warn "================================================"
			log_warn "  ⚠️  volume server 端口从 kind 不可达!"
			log_warn "  CSI 挂载 (s3_with_seaweedfs) 的 fio 数据写入将失败。"
			log_warn ""
			log_warn "  修复方案 (选择其一):"
			log_warn "  1. 放行防火墙:"
			log_warn "     iptables -I INPUT -p tcp --dport 8080 -j ACCEPT"
			log_warn "     iptables -I INPUT -p tcp --dport 18080 -j ACCEPT"
			log_warn "  2. 让 weed 监听所有接口:"
			log_warn "     将 volume 启动命令的 -ip 改为 0.0.0.0"
			log_warn "================================================"
			echo ""
		fi
	fi
}
}

# ============================================================
# 7. 部署 ingress-nginx 控制器
# ============================================================

deploy_ingress_nginx() {
	log_step "部署 ingress-nginx (Helm chart v${INGRESS_NGINX_CHART_VERSION})"

	local chart_dir="${SCRIPT_DIR}/ingress-nginx"
	if [ ! -f "${chart_dir}/Chart.yaml" ]; then
		log_error "Helm chart 不存在: ${chart_dir}"
		echo "  请将 ingress-nginx chart 放到 ${chart_dir}/"
		return 1
	fi

	if helm status ingress-nginx -n ingress-nginx &>/dev/null 2>&1; then
		log_warn "ingress-nginx 已部署，跳过。"
		return 0
	fi

	helm upgrade --install ingress-nginx "$chart_dir" \
		--namespace ingress-nginx \
		--create-namespace \
		--set controller.service.type=NodePort \
		--set controller.service.nodePorts.http=30080 \
		--set controller.service.nodePorts.https=30443 \
		--set controller.hostPort.enabled=false \
		--wait \
		--timeout 5m 2>&1 | tail -5

	log_info "ingress-nginx 部署完成。"
	kubectl get svc -n ingress-nginx 2>/dev/null || true
}

# 8. fio 性能测试
# ============================================================

# 查看 fio 自动测试结果 (容器启动时已自动执行三目录对比测试)
run_fio_benchmark() {
	log_step "fio 性能测试结果 (nfs / s3 / s3_with_seaweedfs 三目录对比)"

	local pod_name
	pod_name=$(kubectl get pods -l app=fio-storage -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
	if [ -z "$pod_name" ]; then
		log_error "未找到 fio-storage Pod，请先部署。"
		return 1
	fi

	# 检查容器是否已完成自动测试
	log_info "检查 fio-test 容器自动测试状态..."
	if kubectl logs "$pod_name" -c fio-test 2>/dev/null | grep -q "测试完成"; then
		log_info "✅ 自动测试已完成 (基础读写 + 小文件 + AI 大模型)，拉取结果..."
	else
		log_info "⏳ 自动测试仍在执行中，等待完成..."
		# 等待测试完成标记出现
		kubectl logs -f "$pod_name" -c fio-test 2>/dev/null | while IFS= read -r line; do
			echo "  $line"
			[[ "$line" == *"测试完成"* ]] && break
		done
	fi

	# 获取最新的结果文件
	local latest_result
	latest_result=$(kubectl exec "$pod_name" -c fio-test -- sh -c \
		"ls -t /tmp/fio-results/fio_*.txt 2>/dev/null | head -1" 2>/dev/null)

	if [ -n "$latest_result" ]; then
		log_info "拉取测试结果: ${latest_result}"
		local local_dir="${SCRIPT_DIR}/fio-results"
		mkdir -p "$local_dir"
		local local_file="${local_dir}/$(basename "$latest_result")"
		kubectl exec "$pod_name" -c fio-test -- cat "$latest_result" >"$local_file" 2>/dev/null
		log_info "结果已保存到: ${local_file}"
		echo ""
		cat "$local_file"
	else
		log_warn "未找到结果文件，直接输出容器日志..."
		echo ""
		kubectl logs "$pod_name" -c fio-test 2>/dev/null || echo "无法获取日志"
	fi

	echo ""
	log_info "💡 手动重新执行 fio 测试:"
	echo "   kubectl exec -it ${pod_name} -c fio-test -- /entrypoint-fio.sh"
	echo "   kubectl exec ${pod_name} -c fio-test -- fio --name=test --filename=/mnt/nfs/test.dat --rw=write --bs=1M --size=256M"
}

# ============================================================
# 8. 状态查看
# ============================================================

status_all() {
	echo ""
	echo "================================================================"
	echo "  📊 SeaweedFS 实验环境状态"
	echo "================================================================"

	echo -e "\n${CYAN}── 宿主机 SeaweedFS 进程${NC}"
	local components=("master" "volume" "filer" "s3" "mount")
	for comp in "${components[@]}"; do
		if ps aux | grep "weed ${comp}" | grep -v grep &>/dev/null; then
			echo -e "  🟢 weed ${comp}\t运行中"
		else
			echo -e "  🔴 weed ${comp}\t已停止"
		fi
	done

	echo -e "\n${CYAN}── kind 集群${NC}"
	if kind get clusters 2>/dev/null | grep -q "^${KIND_CLUSTER_NAME}$"; then
		echo -e "  🟢 ${KIND_CLUSTER_NAME}\t运行中"
		echo ""
		kubectl get nodes 2>/dev/null || true
	else
		echo -e "  🔴 ${KIND_CLUSTER_NAME}\t未创建"
	fi

	echo -e "\n${CYAN}── Kubernetes 核心资源${NC}"
	echo "  [CSI Driver]"
	kubectl get pods -l 'app in (seaweedfs-controller,seaweedfs-node,seaweedfs-mount)' 2>/dev/null || echo "  未部署"
	echo ""
	echo "  [Storage Classes]"
	kubectl get sc 2>/dev/null || echo "  无"
	echo ""
	echo "  [PVCs]"
	kubectl get pvc 2>/dev/null || echo "  无"
	echo ""
	echo "  [NFS Provisioner & fio Test Pod]"
	kubectl get pods -A 2>/dev/null | grep -E 'nfs-client-provisioner|fio-storage' || echo "  未部署"
	echo ""
	echo "  [ingress-nginx]"
	kubectl get pods -n ingress-nginx 2>/dev/null | grep controller || echo "  未部署"

	echo -e "
${CYAN}── 访问端点${NC}"
	echo "  Filer Web     : http://${SEAWEEDFS_FILER}"
	echo "  S3 API        : ${SEAWEEDFS_S3_ENDPOINT}"
	echo "  NFS 导出      : ${NFS_SERVER}:${NFS_MOUNT}"

	local ingress_ip ingress_port
	ingress_ip=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
	if [ -z "$ingress_ip" ]; then
		ingress_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
	fi
	ingress_port=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}' 2>/dev/null)
	if [ -n "$ingress_ip" ] && [ -n "$ingress_port" ]; then
		echo ""
		echo "  📊 fio 性能报告: http://${ingress_ip}:${ingress_port}/fio/"
	fi

	echo ""
	echo "  fio 测试挂载点 (kubectl exec 进入后可用):"
	echo "    /mnt/nfs                — NFS provisioner"
	echo "    /mnt/s3                 — rclone S3 FUSE"
	echo "    /mnt/s3_with_seaweedfs  — CSI driver"
}

# ============================================================
# 9. 清理卸载
# ============================================================

uninstall_all() {
	log_warn "=================================================="
	log_warn "  ⚠️  将卸载所有 SeaweedFS 实验环境组件！"
	log_warn "=================================================="
	read -rp "确认卸载? (y/N): " confirm
	if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
		log_info "操作已取消。"
		return 0
	fi

	# 1. 清理 Kubernetes 资源 (直接暴力清理，不做阻塞操作)
	log_step "清理 Kubernetes 资源..."
	if kubectl config current-context 2>/dev/null | grep -q "kind-${KIND_CLUSTER_NAME}"; then
		log_info "批量清理 finalizer + 强制删除..."

		# 先清 finalizer (后台并发，不阻塞)
		kubectl get pvc -A 2>/dev/null | awk '/seaweedfs/{print $1,$2}' | while read ns pvc; do
			timeout 5 kubectl patch pvc "$pvc" -n "$ns" -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null &
		done
		timeout 5 kubectl patch sc seaweedfs-nfs-storage -p '{"metadata":{"finalizers":[]}}' --type=merge 2>/dev/null &
		wait 2>/dev/null || true

		# 按顺序快速删除 (无 finalizer 阻挡，秒级完成)
		log_info "删除 Ingress/Service/Deployment..."
		kubectl delete ingress fio-report --force --grace-period=0 --timeout=5s 2>/dev/null || true
		kubectl delete svc fio-report --force --grace-period=0 --timeout=5s 2>/dev/null || true
		kubectl delete deployment fio-storage-test --force --grace-period=0 --timeout=5s 2>/dev/null || true
		kubectl delete deployment nfs-client-provisioner -n kube-system --force --grace-period=0 --timeout=5s 2>/dev/null || true

		log_info "删除 PVC/SC..."
		kubectl delete pvc --all --force --grace-period=0 --timeout=5s 2>/dev/null || true
		kubectl delete sc seaweedfs-nfs-storage --force --grace-period=0 --timeout=5s 2>/dev/null || true

		log_info "清理 CSI driver..."
		kubectl delete -f "${SCRIPT_DIR}/seaweedfs-csi-driver-master/deploy/kubernetes/seaweedfs-csi.yaml" --force --grace-period=0 --timeout=10s 2>/dev/null || true

		log_info "清理 ingress-nginx..."
		helm uninstall ingress-nginx -n ingress-nginx --timeout 15s 2>/dev/null || true
		kubectl delete namespace ingress-nginx --force --grace-period=0 --timeout=5s 2>/dev/null || true
	fi

	# 2. 删除 kind 集群
	delete_kind_cluster

	# 3. 停止 SeaweedFS 进程
	log_step "停止 SeaweedFS 进程..."
	pkill -9 -f "weed master" 2>/dev/null || true
	pkill -9 -f "weed volume" 2>/dev/null || true
	pkill -9 -f "weed filer" 2>/dev/null || true
	pkill -9 -f "weed s3" 2>/dev/null || true
	pkill -9 -f "weed mount" 2>/dev/null || true

	# 4. 解除挂载
	log_info "解除 FUSE 挂载..."
	umount -l "${NFS_MOUNT}" 2>/dev/null || true

	# 5. 清理 NFS 配置
	log_info "清理 NFS 配置..."
	sed -i '\#^/mnt/seaweedfs#d' /etc/exports 2>/dev/null || true
	exportfs -rav 2>/dev/null || true

	# 6. 清理数据
	read -rp "是否删除所有数据目录? (包括 ${BASE_DIR} 和 ${SCRIPT_DIR}/filerldb2) (y/N): " del_data
	if [[ "$del_data" == "y" || "$del_data" == "Y" ]]; then
		log_info "删除宿主机数据目录: ${BASE_DIR} ..."
		rm -rf "${BASE_DIR}"
		log_info "删除项目内 Filer 数据: ${SCRIPT_DIR}/filerldb2 ..."
		rm -rf "${SCRIPT_DIR}/filerldb2"
	else
		log_info "保留数据目录: ${BASE_DIR}"
		log_info "保留 Filer 数据: ${SCRIPT_DIR}/filerldb2"
	fi

	# 7. 清理生成文件
	rm -f "${SCRIPT_DIR}/.kind-config-generated.yaml"
	rm -f "${SCRIPT_DIR}/.csi-driver-patched.yaml"
	rm -f "/tmp/nfs_s3_rclone_template.yaml" "/tmp/nfs_s3_rclone_rendered.yaml"
	rm -f "${SCRIPT_DIR}/.nfs_s3_rclone_rendered.yaml"
	rm -f "${SCRIPT_DIR}/.ingress-nginx-deploy.yaml"

	log_info "卸载完成。"
}

# ============================================================
# 10. 一键部署
# ============================================================

deploy_all() {
	echo ""
	echo "╔══════════════════════════════════════════════════════════════╗"
	echo "║   🌿 SeaweedFS 实验环境一键部署                             ║"
	echo "║   集群: kind-${KIND_CLUSTER_NAME}                           ║"
	echo "║   本机: ${LOCAL_IP}                                         ║"
	echo "╚══════════════════════════════════════════════════════════════╝"
	echo ""

	check_prerequisites

	# 1. 创建 kind 集群 (含镜像预加载)
	create_kind_cluster

	# 2. 部署 SeaweedFS 原生服务
	deploy_seaweedfs_services

	# 3. 部署 CSI driver
	deploy_csi_driver

	# 4. 部署 ingress-nginx 控制器
	deploy_ingress_nginx

	# 5. 部署 NFS/S3/rclone CRDs (含 fio 测试 + nginx 报告)
	deploy_nfs_s3_rclone

	# 6. 显示最终状态
	status_all

	echo ""
	echo "╔══════════════════════════════════════════════════════════════╗"
	local report_url ingress_ip ingress_port
	ingress_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
	ingress_port=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}' 2>/dev/null)
	report_url="http://${FIO_REPORT_HOST}:${ingress_port:-30080}/"

	echo "║   🎉 实验环境部署完成！                                     ║"
	echo "║                                                            ║"
	echo "║   📊 fio 性能报告:                                         ║"
	echo "║   ${report_url}                 ║"
	echo "║                                                            ║"
	echo "║   请配置 /etc/hosts:                                        ║"
	echo "║   ${ingress_ip} ${FIO_REPORT_HOST}                              ║"
	echo "║                                                            ║"
	echo "║   • 查看状态: $0 status                                     ║"
	echo "║   • 卸载环境: $0 uninstall                                   ║"
	echo "╚══════════════════════════════════════════════════════════════╝"
}

# ============================================================
# 11. 主入口
# ============================================================

print_usage() {
	echo ""
	echo "🌿 setup-seaweedfs-lab.sh — SeaweedFS 实验环境管理脚本"
	echo ""
	echo "用法: $0 <命令>"
	echo ""
	echo "命令:"
	echo "  deploy      一键部署全部环境 (kind + SeaweedFS + CSI + Ingress + NFS/S3)"
	echo "  kind-up     仅创建 kind 集群"
	echo "  kind-down   仅删除 kind 集群"
	echo "  seaweedfs   仅部署 SeaweedFS 原生服务 (宿主机)"
	echo "  csi         仅部署 seaweedfs-csi-driver"
	echo "  crds        仅部署 NFS/S3/rclone CRDs"
	echo "  ingress     仅部署 ingress-nginx 控制器"
	echo "  status      查看环境状态"
	echo "  fio         查看 fio 自动测试结果"
	echo "  uninstall   卸载全部环境"
	echo ""
	echo "环境变量 (均有默认值):"
	echo "  NFS_SERVER=${NFS_SERVER}"
	echo "  NFS_PATH=${NFS_PATH}"
	echo "  SEAWEEDFS_FILER=${SEAWEEDFS_FILER}"
	echo "  SEAWEEDFS_S3_ENDPOINT=${SEAWEEDFS_S3_ENDPOINT}"
	echo "  KIND_CLUSTER_NAME=${KIND_CLUSTER_NAME}"
	echo "  FIO_IMAGE=${FIO_IMAGE}"
	echo "  CSI_CACHE_CAPACITY_MB=${CSI_CACHE_CAPACITY_MB}"
	echo "  FIO_SIZE=${FIO_SIZE}  FIO_RUNTIME=${FIO_RUNTIME}"
	echo "  SMALL_FILE_COUNT=${SMALL_FILE_COUNT}  SMALL_FILE_SIZE=${SMALL_FILE_SIZE}"
	echo "  AI_MODEL_SIZE=${AI_MODEL_SIZE}  AI_MODEL_JOBS=${AI_MODEL_JOBS}"
	echo ""
	echo "示例:"
	echo "  sudo $0 deploy"
	echo "  SEAWEEDFS_S3_ENDPOINT=http://192.168.1.100:8333 sudo -E $0 deploy"
	echo "  $0 fio"
	echo ""
}

case "${1:-}" in
deploy | all)
	if [ "$EUID" -ne 0 ]; then
		log_error "需要 root 权限，请使用 sudo 运行。"
		echo "  sudo $0 deploy"
		exit 1
	fi
	deploy_all
	;;
kind-up)
	check_prerequisites
	create_kind_cluster
	;;
kind-down)
	delete_kind_cluster
	;;
seaweedfs)
	if [ "$EUID" -ne 0 ]; then
		log_error "需要 root 权限。"
		exit 1
	fi
	deploy_seaweedfs_services
	;;
csi)
	check_prerequisites
	deploy_csi_driver
	;;
crds)
	check_prerequisites
	deploy_nfs_s3_rclone
	;;
ingress)
	check_prerequisites
	deploy_ingress_nginx
	;;
status)
	status_all
	;;
fio | bench | benchmark)
	run_fio_benchmark
	;;
uninstall | clean | cleanup)
	if [ "$EUID" -ne 0 ]; then
		log_error "需要 root 权限。"
		exit 1
	fi
	uninstall_all
	;;
-h | --help | help | "")
	print_usage
	;;
*)
	log_error "未知命令: $1"
	print_usage
	exit 1
	;;
esac
