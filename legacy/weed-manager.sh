#!/bin/bash

# 确保脚本以 root 权限运行
if [ "$EUID" -ne 0 ]; then
	echo "❌ 请使用 sudo 或 root 权限运行此脚本！"
	exit 1
fi

# 基础路径配置
BASE_DIR="/mnt/seaweedfs"
DATA_DIR="${BASE_DIR}/data"
LOG_DIR="${BASE_DIR}/logs"
NFS_MOUNT="${BASE_DIR}/data"

# 获取本机局域网 IP
LOCAL_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7}' || hostname -I | awk '{print $1}')

# 统一输出格式
log_info() { echo -e "\033[32m【INFO】$1\033[0m"; }
log_warn() { echo -e "\033[33m【WARN】$1\033[0m"; }
log_err() { echo -e "\033[31m【ERROR】$1\033[0m"; }

# 检查 weed 二进制是否存在
check_weed() {
	if ! command -v weed &>/dev/null; then
		log_err "未在系统环境变量中找到 'weed' 二进制文件！"
		echo "请先下载 weed 并移动到 /usr/local/bin/ 后再执行此脚本。"
		exit 1
	fi
}

# --- 安装部署函数 ---
install_all() {
	check_weed
	log_info "=================================================="
	log_info "🚀 开始原生 SeaweedFS 服务一键安装部署"
	log_info "📌 本机通信 IP: ${LOCAL_IP}"
	log_info "=================================================="

	# 1. 创建目录
	log_info "📁 1. 创建环境目录结构..."
	mkdir -p "${DATA_DIR}/master" "${DATA_DIR}/volume" "${DATA_DIR}/filer"
	mkdir -p "${LOG_DIR}" "${NFS_MOUNT}"
	chmod -R 777 "${BASE_DIR}"
	chmod 777 "${NFS_MOUNT}"

	# 2. 检查并安装原生 NFS 服务
	log_info "📦 2. 检查宿主机 NFS 依赖件..."
	if command -v apt-get &>/dev/null; then
		apt-get update -y && apt-get install -y nfs-kernel-server rpcbind
	elif command -v dnf &>/dev/null; then
		dnf install -y nfs-utils rpcbind
	elif command -v yum &>/dev/null; then
		yum install -y nfs-utils rpcbind
	fi
	modprobe nfs && modprobe nfsd

	# 3. 开启系统 FUSE allow_other 权限
	log_info "🔧 3. 优化系统 FUSE 权限策略..."
	if [ -f /etc/fuse.conf ]; then
		sed -i 's/#user_allow_other/user_allow_other/g' /etc/fuse.conf
		grep -q "^user_allow_other" /etc/fuse.conf || echo "user_allow_other" >>/etc/fuse.conf
	else
		echo "user_allow_other" >/etc/fuse.conf
	fi

	# 4. 启动 SeaweedFS 组件 (核心参数优化)
	log_info "🛰️ 4. 后台启动 Master 节点..."
	nohup weed master -ip="${LOCAL_IP}" -port=9333 -mdir="${DATA_DIR}/master" -volumeSizeLimitMB=10240 -volumePreallocate >"${LOG_DIR}/master.log" 2>&1 &
	sleep 1

	log_info "📦 5. 后台启动 Volume 节点..."
	# -images.fix.orientation=false 减少不必要的图片转码开销
	nohup weed volume -mserver="${LOCAL_IP}:9333" -ip="${LOCAL_IP}" -port=8080 -dir="${DATA_DIR}/volume" -images.fix.orientation=false >"${LOG_DIR}/volume.log" 2>&1 &
	sleep 1

	log_info "🗂️ 6. 后台启动 Filer 节点..."
	# 启用默认自建内存索引，不依赖外部数据库
	nohup weed filer -master="${LOCAL_IP}:9333" -ip="${LOCAL_IP}" -port=8888 >"${LOG_DIR}/filer.log" 2>&1 &
	sleep 1

	log_info "🌐 7. 后台启动 S3 API 节点..."
	# -allowEmptyFolder=true 允许空目录同步，完美适配 K8s 行为
	export AWS_ACCESS_KEY_ID="admin"
	export AWS_SECRET_ACCESS_KEY="admin123"
	nohup weed s3 -filer="${LOCAL_IP}:8888" -port=8333 -allowEmptyFolder=true >"${LOG_DIR}/s3.log" 2>&1 &
	sleep 2

	# 5. 将 Filer 挂载到宿主机本地供 NFS 使用
	log_info "🔗 8. 后台执行 weed mount 绑定本地 Filer..."
	umount -l "${NFS_MOUNT}" &>/dev/null
	# 核心优化：组件内关闭本地强缓存，解决多端元数据不同步问题
	nohup weed mount -filer="${LOCAL_IP}:8888" -dir="${NFS_MOUNT}" --allow_other -cacheCapacityMB=0 >"${LOG_DIR}/mount.log" 2>&1 &
	sleep 2

	# 6. 配置 NFS 导出网络权限
	log_info "🔒 9. 写入 NFS 跨容器特权规则..."
	sed -i '\#^/mnt/seaweedfs#d' /etc/exports
	echo "${NFS_MOUNT} 172.16.0.0/12(rw,sync,no_subtree_check,fsid=1,no_root_squash,insecure)" >>/etc/exports
	echo "${NFS_MOUNT} 10.10.32.0/20(rw,sync,no_subtree_check,fsid=1,no_root_squash,insecure)" >>/etc/exports

	# 7. 刷新服务
	log_info "🔄 10. 重启宿主机核心 NFS 内核网关..."
	if command -v systemctl &>/dev/null; then
		systemctl enable rpcbind && systemctl restart rpcbind
		systemctl enable nfs-kernel-server || systemctl enable nfs-server
		systemctl restart nfs-kernel-server || systemctl restart nfs-server
	else
		service rpcbind restart
		service nfs-kernel-server restart
	fi
	exportfs -rav

	log_info "=================================================="
	log_info "🎉 全套环境部署成功！"
	log_info "👉 Filer Web 界面: http://${LOCAL_IP}:8888"
	log_info "👉 S3 API 端点:    http://${LOCAL_IP}:8333"
	log_info "👉 NFS 导出路径:   ${NFS_MOUNT}"
	log_info "=================================================="
}

# --- 卸载清除函数 ---
uninstall_all() {
	log_warn "=================================================="
	log_warn "🚨 警告：准备卸载 SeaweedFS 并清空所有历史数据！"
	log_warn "=================================================="
	read -p "⚠️ 确认清除吗？(y/n): " confirm
	if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
		log_info "❌ 操作已取消。"
		exit 0
	fi

	log_info "🛑 1. 停止所有 weed 运行进程..."
	pkill -9 -f "weed master" || true
	pkill -9 -f "weed volume" || true
	pkill -9 -f "weed filer" || true
	pkill -9 -f "weed s3" || true
	pkill -9 -f "weed mount" || true

	log_info "🔗 2. 解除宿主机物理挂载点..."
	umount -l "${NFS_MOUNT}" &>/dev/null

	log_info "🔒 3. 清理 NFS 权限配置文件..."
	sed -i '\#^/mnt/seaweedfs#d' /etc/exports
	exportfs -rav &>/dev/null

	log_info "💥 4. 彻底删除历史存储文件、日志和元数据..."
	rm -rf "${BASE_DIR}"
	rm -rf "${NFS_MOUNT}"

	log_info "=================================================="
	log_info "🧹 所有相关进程、环境、配置文件、存储卷已完全净化！"
	log_info "=================================================="
}

# --- 状态查看函数 ---
status_all() {
	echo "=================================================="
	echo "📊 SeaweedFS 进程运行状态查看"
	echo "=================================================="
	local components=("master" "volume" "filer" "s3" "mount")
	for comp in "${components[@]}"; do
		if ps aux | grep "weed ${comp}" | grep -v grep &>/dev/null; then
			echo -e "🟢 weed ${comp} :\t\033[32m运行中 (Running)\033[0m"
		else
			echo -e "🔴 weed ${comp} :\t\033[31m已停止 (Stopped)\033[0m"
		fi
	done
	echo "--------------------------------------------------"
	echo "📌 当前物理挂载状态:"
	df -h | grep "weed" || echo "无物理挂载记录。"
}

#--- 启动rclone bisync ---
rclone_sync() {
	log_info "🔄 启动 Filer 物理磁盘同步守护进程..."
	# 将 Filer 虚拟路径下的 /buckets/my-test-bucket 实时同步到宿主机的物理目录 /opt/seaweedfs/sync_s3
	SYNC_DIR="/mnt/seaweedfs/sync_s3"
	mkdir -p "${SYNC_DIR}"
	chmod 777 "${SYNC_DIR}"

	export RCLONE_CONFIG_LOCAL_S3_TYPE="s3"
	export RCLONE_CONFIG_LOCAL_S3_PROVIDER="Other"
	export RCLONE_CONFIG_LOCAL_S3_ENDPOINT="http://127.0.0.1:8333"
	export RCLONE_CONFIG_LOCAL_SW_S3_ENV_AUTH="false"
	export RCLONE_CONFIG_LOCAL_SW_S3_ACCESS_KEY_ID="admin"
	export RCLONE_CONFIG_LOCAL_SW_S3_SECRET_ACCESS_KEY="admin123"

	# 3. 前台 resync 建立第一份清单
	log_warn "⏳ 建立初次握手快照 (执行 --resync)..."
	rclone bisync local_s3:my-test-bucket "${SYNC_DIR}" --resync --create-empty-src-dirs -v

	# 4. 完美切入后台实时同步
	log_info "🚀 初始对齐成功，开始切入后台实时同步模式..."
	nohup rclone bisync local_s3:my-test-bucket "${SYNC_DIR}" \
		--poll-interval 1s \
		--resilient \
		--create-empty-src-dirs \
		-v >"${LOG_DIR}/rclone_local_sync.log" 2>&1 &
}

# --- 引导主入口 ---
case "$1" in
install)
	install_all
	;;
uninstall)
	uninstall_all
	;;
status)
	status_all
	;;
sync)
	rclone_sync
	;;
*)
	echo "💡 使用说明: sudo $0 {install|uninstall|status|sync}"
	exit 1
	;;
esac
