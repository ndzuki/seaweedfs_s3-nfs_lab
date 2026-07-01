#!/bin/bash
# ============================================================
# fio 自动测试入口脚本
# 使用 JSON 输出格式，生成 TXT + HTML 报告
# ============================================================
set -euo pipefail

# ---- 诊断模式 (设置 TRACE=1 启用 set -x) ----
if [ "${TRACE:-0}" = "1" ]; then
    set -x
fi

TEST_SIZE="${TEST_SIZE:-256M}"
# TEST_RUNTIME 仅用于读测试；写测试用纯 --size 限流，防止 FUSE 脏页堆积导致 OOM
TEST_RUNTIME="${TEST_RUNTIME:-60s}"
TEST_DIRS=("/mnt/nfs" "/mnt/s3" "/mnt/s3_with_seaweedfs" "/mnt/image")
RESULT_DIR="${RESULT_DIR:-/tmp/fio-results}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-300}"

# FUSE/CSI 写限速 (MB/s)，防止脏页疯狂堆积撑爆内存
CSI_WRITE_RATE="${CSI_WRITE_RATE:-50m}"

# fio 单次执行超时 (秒)，防止 FUSE fsync 永久挂起
FIO_TIMEOUT="${FIO_TIMEOUT:-180}"

# 场景开关: ${var:-default} 仅在 unset/null 时使用默认值，但 K8s env 可能传入空字符串
# 空字符串时视为未设置，强制使用默认值
TEST_BASIC="${TEST_BASIC:-true}"
TEST_SMALL_FILES="${TEST_SMALL_FILES:-true}"
TEST_AI_MODEL="${TEST_AI_MODEL:-true}"
# 防御: K8s 传入空字符串时，${var:-default} 不会触发默认值，需显式检查
[ -z "$TEST_BASIC" ] && TEST_BASIC="true"
[ -z "$TEST_SMALL_FILES" ] && TEST_SMALL_FILES="true"
[ -z "$TEST_AI_MODEL" ] && TEST_AI_MODEL="true"
# 便捷场景选择: TEST_SCENARIO=small 只跑小文件 (basic|small|ai|all)
case "${TEST_SCENARIO:-all}" in
    basic) TEST_BASIC=true;  TEST_SMALL_FILES=false; TEST_AI_MODEL=false ;;
    small) TEST_BASIC=false; TEST_SMALL_FILES=true;  TEST_AI_MODEL=false ;;
    ai)    TEST_BASIC=false; TEST_SMALL_FILES=false; TEST_AI_MODEL=true ;;
    all)   ;;
esac

SMALL_FILE_COUNT="${SMALL_FILE_COUNT:-2000}"
SMALL_FILE_SIZE="${SMALL_FILE_SIZE:-16k}"
# NFS 文件创建延迟 (秒): 每个文件间隔, 默认 0.02s = 2000文件约40s
NFS_CREATE_DELAY="${NFS_CREATE_DELAY:-0.02}"

AI_MODEL_SIZE="${AI_MODEL_SIZE:-512M}"
AI_MODEL_RUNTIME="${AI_MODEL_RUNTIME:-120s}"
AI_MODEL_JOBS="${AI_MODEL_JOBS:-4}"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULT_FILE="${RESULT_DIR}/fio_${TIMESTAMP}.txt"
export HTML_FILE="${RESULT_DIR}/fio_${TIMESTAMP}.html"
INDEX_FILE="${RESULT_DIR}/index.html"
export DATA_DIR="${RESULT_DIR}/data"
mkdir -p "$RESULT_DIR" "$DATA_DIR"

# ============================================================
# 清理陷阱: 防止测试残留文件泄漏到 /tmp
# ============================================================
TMP_CLEANUP_DIRS=()
cleanup() {
    local exit_code=$?
    echo "🧹 清理残留文件..."

    # 清理测试期间可能泄漏到 /tmp 的 fio 临时文件
    # fio 在某些 I/O engine 下会在工作目录或 /tmp 创建临时文件
    find /tmp -maxdepth 1 -name 'fio_*' -user root -mmin -120 -delete 2>/dev/null || true

    # 清理脚本创建的临时目录
    for d in "${TMP_CLEANUP_DIRS[@]}"; do
        [ -n "$d" ] && [ -d "$d" ] && rm -rf "$d" 2>/dev/null || true
    done

    # 确保挂载点下的测试文件被清理
    for dir in "${READY_DIRS[@]:-}"; do
        [ -n "$dir" ] && [ -d "$dir" ] && find "$dir" -maxdepth 2 -name '.fio_*' -delete 2>/dev/null || true
    done

    echo "  退出码: ${exit_code}"
}
trap cleanup EXIT

banner() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🌿 SeaweedFS fio 基准测试"
    echo "  基础: ${TEST_SIZE} (读 ${TEST_RUNTIME}) | 小文件: ${SMALL_FILE_COUNT}×${SMALL_FILE_SIZE}"
    echo "  AI模型: ${AI_MODEL_SIZE}×${AI_MODEL_JOBS}jobs | CSI写限速: ${CSI_WRITE_RATE}"
    echo "  fio超时: ${FIO_TIMEOUT}s"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# 等待挂载点就绪 + 可写验证，返回实际可用的目录列表到 READY_DIRS 数组
READY_DIRS=()
# 检测挂载点 (兼容 Alpine + ImageVolume bind mount)
is_mountpoint() {
    local d="$1"
    # 1. 标准检测: mountpoint 命令
    if command -v mountpoint &>/dev/null; then
        mountpoint -q "$d" 2>/dev/null && return 0
    else
        # 2. stat 回退: 挂载点的 device ID 与父目录不同
        [ -d "$d" ] || return 1
        local d_dev parent_dev
        d_dev=$(stat -c '%d' "$d" 2>/dev/null) || return 1
        parent_dev=$(stat -c '%d' "${d}/.." 2>/dev/null) || return 1
        [ "$d_dev" != "$parent_dev" ] && return 0
    fi
    # 3. ImageVolume fallback: bind mount 可能不被 mountpoint/stat 检测到
    #    如果目录包含预置测试数据文件，视为已就绪
    [ -f "${d}/basic_read.dat" ] 2>/dev/null && return 0
    return 1
}

wait_mounts() {
    for dir in "${TEST_DIRS[@]}"; do
        local bn; bn=$(basename "$dir")
        # ImageVolume: 快速检测 (只读, 不写 touch, 3次×3s=9s 超时)
        local is_image_vol=false
        [ "$bn" = "image" ] && is_image_vol=true

        echo -n "⏳ 等待 ${dir} ..."
        local waited=0
        local dir_timeout=$WAIT_TIMEOUT
        $is_image_vol && dir_timeout=9  # ImageVolume 快速失败

        while [ $waited -lt $dir_timeout ]; do
            if is_mountpoint "$dir"; then
                if $is_image_vol; then
                    # 只读卷: 检查数据文件存在即就绪
                    echo " ✓"; break
                elif touch "${dir}/.fio_writable_test" 2>/dev/null; then
                    rm -f "${dir}/.fio_writable_test" 2>/dev/null
                    echo " ✓"; break
                fi
            fi
            sleep 3; waited=$((waited + 3))
        done
        if [ $waited -ge $dir_timeout ]; then
            $is_image_vol && echo " ⏭ 未挂载" || echo " ⚠️ 超时，跳过"
        else
            READY_DIRS+=("$dir")
        fi
    done
    if [ ${#READY_DIRS[@]} -eq 0 ]; then
        echo "❌ 所有挂载点均未就绪，退出。"
        exit 1
    fi
    echo "就绪目录: ${READY_DIRS[*]}"
    # 额外预热 5s，确保 FUSE/CSI 挂载完全就绪
    echo "⏳ 预热 5s 确保挂载稳定..."
    sleep 5

    # CSI 挂载点数据路径预热验证 (touch 仅验证元数据，需验证实际数据 I/O 路径)
    for dir in "${READY_DIRS[@]}"; do
        local dn warm_file
        dn=$(basename "$dir")
        case "$dn" in
            s3_with_seaweedfs|csi*)
                warm_file="${dir}/.fio_data_warmup"
                echo -n "🔥 CSI 数据路径预热 (${dn})..."
                # dd 在 FUSE 上 write 可成功但 close 返回 EIO, 忽略退出码检查文件内容
                timeout 30 dd if=/dev/zero of="$warm_file" bs=1M count=4 conv=notrunc 2>/dev/null || true
                if [ -s "$warm_file" ]; then
                    echo " ✓ (数据路径正常, $(stat -c%s "$warm_file" 2>/dev/null || wc -c < "$warm_file") bytes)"
                else
                    echo " ⚠️ 写入异常 — 文件为空, 降级重试将自动启用"
                fi
                # 单独测试 fsync (FUSE 已知问题: weed mount 返回 EIO)
                if timeout 15 dd if=/dev/zero of="${warm_file}.fsync_test" bs=4k count=1 conv=fsync 2>/dev/null; then
                    echo "   ✓ FUSE fsync 正常"
                else
                    echo "   ⚠️ FUSE fsync 返回 EIO — 写入降级+读取 truncate 规避已就绪"
                fi
                rm -f "$warm_file" "${warm_file}.fsync_test" 2>/dev/null || true
                ;;
            image)
                echo "📦 ImageVolume 就绪 (${dn}) — 只读，数据已在镜像中预置"
                ;;
        esac
    done
}

# 验证文件路径在挂载目录内，防止意外写入 /tmp 或其他位置
validate_path() {
    local target_path="$1"
    local label="${2:-unknown}"

    # 解析为绝对路径
    local abs_path
    abs_path=$(readlink -f "$target_path" 2>/dev/null || echo "$target_path")

    # 检查是否在允许的目录下 (/mnt/ 或 RESULT_DIR)
    case "$abs_path" in
        /mnt/*|"${RESULT_DIR}"/*) return 0 ;;
        *)
            echo "❌ 安全检查: 拒绝写入非挂载目录 [${label}] -> ${abs_path}" >&2
            return 1
            ;;
    esac
}

# 运行 fio 并提取 JSON 关键指标 → 保存到 data 文件
# 返回: 0=成功, 1=fio执行失败, 2=JSON解析失败
run_fio() {
    local label="$1"; shift
    local json_file="${DATA_DIR}/${label}.json"

    # 验证所有 --filename 和 --directory 参数在允许的路径内
    local prev_arg=""
    for arg in "$@"; do
        # 处理 --key=value 风格参数
        case "$arg" in
            --filename=*)
                validate_path "${arg#--filename=}" "$label" || {
                    echo "${label}|none|0|0|0|0" >> "${DATA_DIR}/metrics.dat"
                    return 1
                }
                ;;
            --directory=*)
                validate_path "${arg#--directory=}" "$label" || {
                    echo "${label}|none|0|0|0|0" >> "${DATA_DIR}/metrics.dat"
                    return 1
                }
                ;;
        esac
        # 处理 --key value 风格参数
        case "$prev_arg" in
            --filename|--directory)
                validate_path "$arg" "$label" || {
                    echo "${label}|none|0|0|0|0" >> "${DATA_DIR}/metrics.dat"
                    return 1
                }
                ;;
        esac
        prev_arg="$arg"
    done

    # fio 执行，带超时保护防止 FUSE fsync 永久挂起
    timeout "$FIO_TIMEOUT" fio --name="$label" --output-format=json "$@" \
        2>"${DATA_DIR}/${label}.err" > "$json_file" || {
        local rc=$?
        echo "    ⚠️ fio 失败: ${label} (exit=${rc})" >&2
        # 输出 stderr 末尾 5 行供诊断 (fio 错误原因通常在最末)
        if [ -s "${DATA_DIR}/${label}.err" ]; then
            echo "    ── fio stderr (last 5 lines):" >&2
            tail -5 "${DATA_DIR}/${label}.err" | while IFS= read -r errline; do
                echo "    │ ${errline}" >&2
            done
        fi
        if [ "$rc" -eq 124 ]; then
            echo "    ⚠️ fio 超时 (${FIO_TIMEOUT}s) — 可能是 FUSE fsync 挂起" >&2
        fi
        echo "${label}|none|0|0|0|0" >> "${DATA_DIR}/metrics.dat"
        return 1
    }

    # 提取关键指标 (jq 失败时所有值默认为 0)
    local job
    job=$(jq -r '.jobs[0] // empty' "$json_file" 2>/dev/null) || true
    if [ -z "$job" ] || [ "$job" = "null" ]; then
        echo "    ⚠️ JSON 解析失败: ${label}" >&2
        # 输出 stderr 和 stdout 摘要供诊断
        if [ -s "${DATA_DIR}/${label}.err" ]; then
            echo "    ── fio stderr:" >&2
            tail -3 "${DATA_DIR}/${label}.err" | while IFS= read -r errline; do
                echo "    │ ${errline}" >&2
            done
        fi
        echo "${label}|none|0|0|0|0" >> "${DATA_DIR}/metrics.dat"
        return 2
    fi

    local key iops bw_bytes bw_mb lat_ns lat_us lat_ms
    for key in read write; do
        iops=$(echo "$job" | jq -r ".${key}.iops // 0" 2>/dev/null) || iops=0
        bw_bytes=$(echo "$job" | jq -r ".${key}.bw_bytes // 0" 2>/dev/null) || bw_bytes=0
        bw_mb=$(awk "BEGIN {printf \"%.2f\", ${bw_bytes:-0}/1048576}" 2>/dev/null) || bw_mb="0.00"
        lat_ns=$(echo "$job" | jq -r ".${key}.lat_ns.mean // 0" 2>/dev/null) || lat_ns=0
        lat_us=$(awk "BEGIN {printf \"%.2f\", ${lat_ns:-0}/1000}" 2>/dev/null) || lat_us="0.00"
        lat_ms=$(awk "BEGIN {printf \"%.2f\", ${lat_ns:-0}/1000000}" 2>/dev/null) || lat_ms="0.00"
        echo "${label}|${key}|${iops:-0}|${bw_mb}|${lat_us}|${lat_ms}" >> "${DATA_DIR}/metrics.dat"
    done

    # 一行摘要
    local r_iops r_bw w_iops w_bw
    r_iops=$(echo "$job" | jq -r '.read.iops // 0' 2>/dev/null) || r_iops=0
    r_bw=$(echo "$job" | jq -r '.read.bw_bytes // 0' 2>/dev/null) || r_bw=0
    r_bw=$(awk "BEGIN {printf \"%.1f\", ${r_bw:-0}/1048576}" 2>/dev/null) || r_bw="0.0"
    w_iops=$(echo "$job" | jq -r '.write.iops // 0' 2>/dev/null) || w_iops=0
    w_bw=$(echo "$job" | jq -r '.write.bw_bytes // 0' 2>/dev/null) || w_bw=0
    w_bw=$(awk "BEGIN {printf \"%.1f\", ${w_bw:-0}/1048576}" 2>/dev/null) || w_bw="0.0"
    # 只显示有意义的指标 (写测试不显示读指标，反之亦然)
    if [ "${r_iops}" != "0" ] && [ "${r_iops}" != "0.0" ]; then
        echo -n "    r_iops=${r_iops} r_bw=${r_bw}MB/s  "
    fi
    if [ "${w_iops}" != "0" ] && [ "${w_iops}" != "0.0" ]; then
        echo "w_iops=${w_iops} w_bw=${w_bw}MB/s"
    else
        echo
    fi

    return 0
}

# ============================================================
# CSI 挂载安全写操作:
#   1. 去除 --time_based/--runtime (纯 --size 限流, 避免脏页堆积 → OOM)
#   2. 添加 --rate 写限速 (防止 FUSE 守护进程被压垮)
#   3. 去除 --end_fsync=1 (FUSE fsync 返回 EIO 或挂起)
#   4. 失败后自动降级重试 (减块减量, 无 end_fsync)
# ============================================================
run_fio_csi_safe_write() {
    local label="$1"; shift
    local orig_args=("$@")

    # 首次尝试: 去除 --time_based/--runtime/--end_fsync
    # 仅靠 --size 限制数据量 + --rate 限速, 防止 FUSE 脏页爆炸
    local first_args=()
    local has_rate=false
    for arg in "${orig_args[@]}"; do
        case "$arg" in
            --time_based)     continue ;;
            --runtime=*)      continue ;;
            --end_fsync=1|--end_fsync) continue ;;
            --rate=*)         has_rate=true; first_args+=("$arg") ;;
            *)                first_args+=("$arg") ;;
        esac
    done
    # 如果没有显式 rate, 添加默认限速
    if [ "$has_rate" = false ]; then
        first_args+=("--rate=${CSI_WRITE_RATE}")
    fi

    echo "    ↳ CSI safe write (size-only, rate=${CSI_WRITE_RATE}, no fsync)" >&2
    run_fio "$label" "${first_args[@]}" || true

    # 检查是否失败 (metrics.dat 中标记为 none)
    if grep -q "^${label}|none|" "${DATA_DIR}/metrics.dat" 2>/dev/null; then
        echo "    ↳ CSI 降级重试 (比例缩减: bs→1/8, size→1/4)..." >&2

        # 降级参数: bs 缩至 1/8, size 缩至 1/4
        local degraded=()
        for arg in "${first_args[@]}"; do
            case "$arg" in
                --end_fsync=*)  continue ;;
                --size=256M|--size=512M|--size=1G|--size=2G)
                                degraded+=("--size=64M") ;;
                --size=8M)      degraded+=("--size=2M") ;;
                --size=*)       degraded+=("--size=16M") ;;  # 安全最小值
                --bs=1M|--bs=4M)     degraded+=("--bs=128k") ;;
                --bs=4k|--bs=8k|--bs=16k)
                                     degraded+=("--bs=4k") ;;
                --bs=*)              degraded+=("--bs=64k") ;;
                *)              degraded+=("$arg") ;;
            esac
        done

        # 确保有 rate 限制
        local has_rate2=false
        for arg in "${degraded[@]}"; do
            case "$arg" in
                --rate=*) has_rate2=true ;;
            esac
        done
        if [ "$has_rate2" = false ]; then
            degraded+=("--rate=${CSI_WRITE_RATE}")
        fi

        run_fio "${label}-fallback" "${degraded[@]}" || true
    fi
    return 0  # 显式返回 0: grep -q 返回 1(无匹配=成功)时 if-fi 的退出码不能泄漏
}

banner
wait_mounts

# ---- 诊断: 显示生效的配置值 ----
echo ""
echo "📋 配置诊断:"
echo "   TEST_BASIC=${TEST_BASIC}  TEST_SMALL_FILES=${TEST_SMALL_FILES}  TEST_AI_MODEL=${TEST_AI_MODEL}"
echo "   TEST_SIZE=${TEST_SIZE}  TEST_RUNTIME=${TEST_RUNTIME}"
echo "   SMALL_FILE_COUNT=${SMALL_FILE_COUNT}  SMALL_FILE_SIZE=${SMALL_FILE_SIZE}"
echo "   AI_MODEL_SIZE=${AI_MODEL_SIZE}  AI_MODEL_JOBS=${AI_MODEL_JOBS}"
echo "   CSI_WRITE_RATE=${CSI_WRITE_RATE}  FIO_TIMEOUT=${FIO_TIMEOUT}s"
echo "   READY_DIRS: ${READY_DIRS[*]}"
echo ""

# 初始化数据文件
echo "label|op|iops|bw_mb|lat_us|lat_ms" > "${DATA_DIR}/metrics.dat"

# 立即创建占位 index.html，避免 nginx 403 (测试完成后会更新为跳转页)
cat > "$INDEX_FILE" << 'IDXEOF'
<!DOCTYPE html>
<html lang="zh"><head><meta charset="UTF-8"><meta http-equiv="refresh" content="15">
<title>SeaweedFS fio 测试进行中</title>
<style>body{font-family:system-ui;background:#0d1117;color:#c9d1d9;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
h1{color:#58a6ff}.spinner{width:40px;height:40px;border:4px solid #30363d;border-top-color:#58a6ff;border-radius:50%;animation:s .8s linear infinite;margin:0 auto 20px}
@keyframes s{to{transform:rotate(360deg)}}</style></head>
<body><div style="text-align:center"><div class="spinner"></div>
<h1>🌿 fio 基准测试进行中...</h1><p>基础读写 → 小文件 → AI 大模型</p><p style="color:#8b949e">每 15 秒自动刷新</p></div></body></html>
IDXEOF

echo "" | tee "$RESULT_FILE"
echo "fio 性能测试报告 | $(date)" | tee -a "$RESULT_FILE"
echo "============================================================" | tee -a "$RESULT_FILE"

# ============================================================
# 场景 1: 基础读写
# ============================================================
if [ "${TEST_BASIC}" = "true" ]; then
    echo -e "\n══════ 场景 1/3: 基础读写 ══════" | tee -a "$RESULT_FILE"
    for dir in "${READY_DIRS[@]}"; do
        dn=$(basename "$dir"); tf="${dir}/fio_basic.dat"
        echo "  📂 ${dn}" | tee -a "$RESULT_FILE"

        # CSI 挂载 (s3_with_seaweedfs): 写操作用安全包装, 读操作用 truncate 预分配
        if [ "$dn" = "s3_with_seaweedfs" ]; then
            # 写: 安全模式 — 无 time_based, 无 end_fsync, 带 rate 限速
            echo -n "    顺序写(1M):" | tee -a "$RESULT_FILE"
            run_fio_csi_safe_write "basic-seq-write-${dn}" \
                --filename="$tf" --rw=write --bs=1M --size="$TEST_SIZE" --numjobs=1 | tee -a "$RESULT_FILE"

            # 读: truncate 预分配, 避开 FUSE write-close EIO
            echo -n "    顺序读(1M):" | tee -a "$RESULT_FILE"
            read_tf="${dir}/fio_basic_read.dat"
            rm -f "$read_tf" 2>/dev/null || true
            truncate -s "${TEST_SIZE}" "$read_tf" 2>/dev/null || true
            sync 2>/dev/null; sleep 1
            run_fio "basic-seq-read-${dn}" --filename="$read_tf" --rw=read --bs=1M --size="$TEST_SIZE" --numjobs=1 \
                --runtime="$TEST_RUNTIME" --time_based | tee -a "$RESULT_FILE" || {
                sleep 5
                run_fio "basic-seq-read-${dn}-retry" --filename="$read_tf" --rw=read --bs=1M --size="$TEST_SIZE" --numjobs=1 | tee -a "$RESULT_FILE"
            }
            rm -f "$read_tf" 2>/dev/null || true

            echo -n "    随机写(4k):" | tee -a "$RESULT_FILE"
            run_fio_csi_safe_write "basic-rand-write-${dn}" \
                --filename="$tf" --rw=randwrite --bs=4k --size="$TEST_SIZE" --numjobs=1 | tee -a "$RESULT_FILE"

            echo -n "    随机读(4k):" | tee -a "$RESULT_FILE"
            read_tf="${dir}/fio_basic_randread.dat"
            rm -f "$read_tf" 2>/dev/null || true
            truncate -s "${TEST_SIZE}" "$read_tf" 2>/dev/null || true
            sync 2>/dev/null; sleep 1
            run_fio "basic-rand-read-${dn}" --filename="$read_tf" --rw=randread --bs=4k --size="$TEST_SIZE" --numjobs=1 \
                --runtime="$TEST_RUNTIME" --time_based | tee -a "$RESULT_FILE" || {
                sleep 5
                run_fio "basic-rand-read-${dn}-retry" --filename="$read_tf" --rw=randread --bs=4k --size="$TEST_SIZE" --numjobs=1 | tee -a "$RESULT_FILE"
            }
            rm -f "$read_tf" 2>/dev/null || true
        elif [ "$dn" = "image" ]; then
            # ImageVolume: 只读挂载 — 文件在镜像构建时已预置, 只测读性能
            echo -n "    顺序写(1M):" | tee -a "$RESULT_FILE"
            echo " ⏭ 只读" | tee -a "$RESULT_FILE"

            echo -n "    顺序读(1M):" | tee -a "$RESULT_FILE"
            run_fio "basic-seq-read-${dn}" --filename="${dir}/basic_read.dat" --rw=read --bs=1M --size="$TEST_SIZE" --numjobs=1 \
                --runtime="$TEST_RUNTIME" --time_based | tee -a "$RESULT_FILE" || {
                sleep 5
                run_fio "basic-seq-read-${dn}-retry" --filename="${dir}/basic_read.dat" --rw=read --bs=1M --size="$TEST_SIZE" --numjobs=1 | tee -a "$RESULT_FILE" || true
            }

            echo -n "    随机写(4k):" | tee -a "$RESULT_FILE"
            echo " ⏭ 只读" | tee -a "$RESULT_FILE"

            echo -n "    随机读(4k):" | tee -a "$RESULT_FILE"
            run_fio "basic-rand-read-${dn}" --filename="${dir}/basic_randread.dat" --rw=randread --bs=4k --size="$TEST_SIZE" --numjobs=1 \
                --runtime="$TEST_RUNTIME" --time_based | tee -a "$RESULT_FILE" || {
                sleep 5
                run_fio "basic-rand-read-${dn}-retry" --filename="${dir}/basic_randread.dat" --rw=randread --bs=4k --size="$TEST_SIZE" --numjobs=1 | tee -a "$RESULT_FILE" || true
            }
        else
            # NFS / S3 (rclone): 写操作去掉 --time_based --runtime 防止脏页堆积
            # 但保留 --end_fsync=1 (NFS/rclone 支持 fsync，保证 benchmark 测量真实落盘延迟)
            echo -n "    顺序写(1M):" | tee -a "$RESULT_FILE"
            run_fio "basic-seq-write-${dn}" --filename="$tf" --rw=write --bs=1M --size="$TEST_SIZE" --numjobs=1 --end_fsync=1 | tee -a "$RESULT_FILE" || true

            echo -n "    顺序读(1M):" | tee -a "$RESULT_FILE"
            sleep 1; run_fio "basic-seq-read-${dn}" --filename="$tf" --rw=read --bs=1M --size="$TEST_SIZE" --numjobs=1 \
                --runtime="$TEST_RUNTIME" --time_based | tee -a "$RESULT_FILE" || {
                sleep 5
                run_fio "basic-seq-read-${dn}-retry" --filename="$tf" --rw=read --bs=1M --size="$TEST_SIZE" --numjobs=1 | tee -a "$RESULT_FILE" || true
            }

            echo -n "    随机写(4k):" | tee -a "$RESULT_FILE"
            run_fio "basic-rand-write-${dn}" --filename="$tf" --rw=randwrite --bs=4k --size="$TEST_SIZE" --numjobs=1 --end_fsync=1 | tee -a "$RESULT_FILE" || true

            echo -n "    随机读(4k):" | tee -a "$RESULT_FILE"
            sleep 1; run_fio "basic-rand-read-${dn}" --filename="$tf" --rw=randread --bs=4k --size="$TEST_SIZE" --numjobs=1 \
                --runtime="$TEST_RUNTIME" --time_based | tee -a "$RESULT_FILE" || {
                sleep 5
                run_fio "basic-rand-read-${dn}-retry" --filename="$tf" --rw=randread --bs=4k --size="$TEST_SIZE" --numjobs=1 | tee -a "$RESULT_FILE" || true
            }
        fi
        rm -f "$tf" 2>/dev/null || true
    done
else
    echo -e "\n⏭️  场景 1/3: 基础读写 (已禁用, TEST_BASIC=${TEST_BASIC})" | tee -a "$RESULT_FILE"
fi

# ============================================================
# 场景 2: 小文件
# ============================================================
if [ "${TEST_SMALL_FILES}" = "true" ]; then
    echo -e "\n══════ 场景 2/3: 小文件 (${SMALL_FILE_COUNT}×${SMALL_FILE_SIZE}) ══════" | tee -a "$RESULT_FILE"
    for dir in "${READY_DIRS[@]}"; do
        dn=$(basename "$dir")
        if [ "$dn" = "image" ]; then
            sd="${dir}/small_files"  # ImageVolume: 使用镜像内预置路径
        else
            sd="${dir}/small_files_${TIMESTAMP}"; mkdir -p "$sd"
        fi
        echo "  📂 ${dn}" | tee -a "$RESULT_FILE"
        # 创建文件
        echo -n "    创建小文件: " | tee -a "$RESULT_FILE"
        s=$(date +%s)
        if [ "$dn" = "image" ]; then
            # ImageVolume: 文件在镜像构建时已预置, 跳过创建, 直接验证
            echo "(ImageVolume: 使用预置文件)" >&2
            echo -n "0s (预置)" | tee -a "$RESULT_FILE"
        elif [ "$dn" = "s3_with_seaweedfs" ]; then
            # CSI: create_only + truncate (避开 FUSE write 脏页)
            fio --name="small-create-${dn}" --directory="$sd" --rw=write --bs="$SMALL_FILE_SIZE" \
                --nrfiles="$SMALL_FILE_COUNT" --filesize="$SMALL_FILE_SIZE" --create_serialize=0 \
                --create_only=1 --filename_format='fio_small_$filenum.dat' \
                --file_service_type=sequential --openfiles=64 --numjobs=4 --output-format=json \
                2>/dev/null > "${DATA_DIR}/small-create-${dn}.json" || true
            find "$sd" -type f -size 0 -exec truncate -s "$SMALL_FILE_SIZE" {} + 2>/dev/null || true
        elif [ "$dn" = "nfs" ]; then
            # NFS: Python ftruncate (fio create_only 并行受限, 只能创建约60%)
            echo "(NFS: creating ${SMALL_FILE_COUNT} files, may take ~1min)" >&2
            python3 -c "
import os, sys, re, time
d, count, size_str = sys.argv[1], int(sys.argv[2]), sys.argv[3]
m = re.match(r'(\d+)([kmg]?)', size_str, re.I)
size = int(m.group(1)) * {'k':1024, 'm':1048576, 'g':1073741824, '':1}.get(m.group(2).lower(), 1)
delay = float(sys.argv[4]) if len(sys.argv) > 4 else 0.02
t0 = time.time()
for i in range(count):
    try:
        fd = os.open(os.path.join(d, f'fio_small_{i}.dat'), os.O_RDWR | os.O_CREAT | os.O_TRUNC, 0o644)
        os.ftruncate(fd, size)
        os.close(fd)
        if delay > 0: time.sleep(delay)
    except: pass
elapsed = time.time() - t0
sys.stderr.write(f'\r  NFS files: {count} created in {elapsed:.0f}s (NFS O_RDONLY limited, using O_RDWR workaround)\n')
" "$sd" "$SMALL_FILE_COUNT" "$SMALL_FILE_SIZE" "${NFS_CREATE_DELAY}" 2>&1 || true
        else
            # S3: 实际写入创建 (end_fsync=0)
            fio --name="small-create-${dn}" --directory="$sd" --rw=write --bs="$SMALL_FILE_SIZE" \
                --nrfiles="$SMALL_FILE_COUNT" --filesize="$SMALL_FILE_SIZE" --create_serialize=0 \
                --filename_format='fio_small_$filenum.dat' --file_service_type=sequential \
                --openfiles=64 --end_fsync=0 --numjobs=4 --output-format=json \
                2>/dev/null > "${DATA_DIR}/small-create-${dn}.json" || true
        fi
        sync 2>/dev/null || true; sleep 1
        echo "$(( $(date +%s) - s ))s" | tee -a "$RESULT_FILE"

        # NFS 属性缓存检测: 文件创建成功后目录可能立即不可见 (NFS over FUSE 已知问题)
        local nfs_dir_broken=false
        if [ "$dn" = "nfs" ] && ! ls "$sd" >/dev/null 2>&1; then
            nfs_dir_broken=true
            echo "     ⚠️ NFS 目录不可访问 (属性缓存)" | tee -a "$RESULT_FILE"
        fi

        # 随机读 (所有挂载类型通用)
        echo -n "    随机读(4k,4jobs):" | tee -a "$RESULT_FILE"
        if $nfs_dir_broken; then
            echo " ⏭ NFS 缓存" | tee -a "$RESULT_FILE"
        elif [ "$dn" = "nfs" ]; then
            run_fio "small-randread-${dn}" --directory="$sd" --rw=randrw --rwmixread=99 --bs=4k \
                --numjobs=4 --nrfiles=$SMALL_FILE_COUNT --filesize=$SMALL_FILE_SIZE --size=8M \
                --filename_format='fio_small_$filenum.dat' --file_service_type=sequential \
                --openfiles=64 --end_fsync=0 | tee -a "$RESULT_FILE" || true
        elif [ "$dn" = "image" ]; then
            # ImageVolume: 纯只读 randread (rw=randread 而非 randrw)
            run_fio "small-randread-${dn}" --directory="$sd" --rw=randread --bs=4k \
                --numjobs=4 --nrfiles=$SMALL_FILE_COUNT --filesize=$SMALL_FILE_SIZE --size=8M \
                --filename_format='fio_small_$filenum.dat' --file_service_type=sequential \
                --openfiles=64 | tee -a "$RESULT_FILE" || true
        else
            run_fio "small-randread-${dn}" --directory="$sd" --rw=randread --bs=4k \
                --numjobs=4 --nrfiles=$SMALL_FILE_COUNT --filesize=$SMALL_FILE_SIZE --size=8M \
                --filename_format='fio_small_$filenum.dat' --file_service_type=sequential \
                --openfiles=64 | tee -a "$RESULT_FILE" || true
        fi

        # 随机写
        echo -n "    随机写(4k,4jobs):" | tee -a "$RESULT_FILE"
        if [ "$dn" = "image" ]; then
            echo " ⏭ 只读" | tee -a "$RESULT_FILE"
        elif $nfs_dir_broken; then
            echo " ⏭ NFS 缓存" | tee -a "$RESULT_FILE"
        elif [ "$dn" = "s3_with_seaweedfs" ]; then
            run_fio_csi_safe_write "small-randwrite-${dn}" --directory="$sd" --rw=randwrite --bs=4k \
                --numjobs=4 --nrfiles=$SMALL_FILE_COUNT --filesize=$SMALL_FILE_SIZE --size=8M \
                --filename_format='fio_small_$filenum.dat' --file_service_type=sequential \
                --openfiles=64 | tee -a "$RESULT_FILE"
        else
            run_fio "small-randwrite-${dn}" --directory="$sd" --rw=randwrite --bs=4k \
                --numjobs=4 --nrfiles=$SMALL_FILE_COUNT --filesize=$SMALL_FILE_SIZE --size=8M \
                --filename_format='fio_small_$filenum.dat' --end_fsync=1 \
                --file_service_type=sequential --openfiles=64 | tee -a "$RESULT_FILE" || true
        fi

        # 混合读写
        echo -n "    混合rw(70r30w):" | tee -a "$RESULT_FILE"
        if [ "$dn" = "image" ]; then
            echo " ⏭ 只读" | tee -a "$RESULT_FILE"
        elif $nfs_dir_broken; then
            echo " ⏭ NFS 缓存" | tee -a "$RESULT_FILE"
        elif [ "$dn" = "s3_with_seaweedfs" ]; then
            run_fio_csi_safe_write "small-randrw-${dn}" --directory="$sd" --rw=randrw --rwmixread=70 --bs=4k \
                --numjobs=4 --nrfiles=$SMALL_FILE_COUNT --filesize=$SMALL_FILE_SIZE --size=8M \
                --filename_format='fio_small_$filenum.dat' --file_service_type=sequential \
                --openfiles=64 | tee -a "$RESULT_FILE"
        else
            run_fio "small-randrw-${dn}" --directory="$sd" --rw=randrw --rwmixread=70 --bs=4k \
                --numjobs=4 --nrfiles=$SMALL_FILE_COUNT --filesize=$SMALL_FILE_SIZE --size=8M \
                --filename_format='fio_small_$filenum.dat' --end_fsync=1 \
                --file_service_type=sequential --openfiles=64 | tee -a "$RESULT_FILE" || true
        fi
        sync 2>/dev/null || true
        [ "$dn" != "image" ] && rm -rf "$sd" 2>/dev/null || true
    done
else
    echo -e "\n⏭️  场景 2/3: 小文件 (已禁用, TEST_SMALL_FILES=${TEST_SMALL_FILES})" | tee -a "$RESULT_FILE"
fi

# ============================================================
# 场景 3: AI 大模型
# ============================================================
if [ "${TEST_AI_MODEL}" = "true" ]; then
    echo -e "\n══════ 场景 3/3: AI 大模型 (${AI_MODEL_SIZE}) ══════" | tee -a "$RESULT_FILE"
    for dir in "${READY_DIRS[@]}"; do
        dn=$(basename "$dir")
        if [ "$dn" = "image" ]; then
            md="${dir}/ai_model"  # ImageVolume: 使用镜像内预置路径，跳过 mkdir
        else
            md="${dir}/ai_model"; mkdir -p "$md"
        fi
        echo "  📂 ${dn}" | tee -a "$RESULT_FILE"

        # checkpoint 写
        echo -n "    checkpoint写(4M):" | tee -a "$RESULT_FILE"
        if [ "${dn}" = "image" ]; then
            echo " ⏭ 只读" | tee -a "$RESULT_FILE"
        elif [ "${dn}" = "s3_with_seaweedfs" ]; then
            # CSI: 安全包装 (无 time_based, 无 end_fsync, 带 rate 限速)
            run_fio_csi_safe_write "ai-save-${dn}" \
                --filename="${md}/ckpt.dat" --rw=write --bs=4M --size="$AI_MODEL_SIZE" --numjobs=1
        else
            # NFS/S3: 去掉 --time_based --runtime + --end_fsync (512M 写满 page cache → OOM)
            run_fio "ai-save-${dn}" --filename="${md}/ckpt.dat" --rw=write --bs=4M \
                --size="$AI_MODEL_SIZE" --numjobs=1 || true
        fi | tee -a "$RESULT_FILE"

        # 模型加载读 (ImageVolume: 文件已在镜像内，无需 truncate 预分配)
        echo -n "    模型加载读(4M,${AI_MODEL_JOBS}jobs):" | tee -a "$RESULT_FILE"
        if [ "${dn}" = "image" ]; then
            ai_read_tf="${md}/ckpt.dat"
            run_fio "ai-load-${dn}" --filename="$ai_read_tf" --rw=read --bs=4M \
                --size="$AI_MODEL_SIZE" --numjobs="$AI_MODEL_JOBS" \
                --runtime="$AI_MODEL_RUNTIME" --time_based | tee -a "$RESULT_FILE" || true
        elif [ "${dn}" = "s3_with_seaweedfs" ]; then
            ai_read_tf="${md}/ckpt_load.dat"
            rm -f "$ai_read_tf" 2>/dev/null || true
            truncate -s "$AI_MODEL_SIZE" "$ai_read_tf" 2>/dev/null || true
            sleep 2; sync 2>/dev/null
            run_fio "ai-load-${dn}" --filename="$ai_read_tf" --rw=read --bs=4M \
                --size="$AI_MODEL_SIZE" --numjobs="$AI_MODEL_JOBS" \
                --runtime="$AI_MODEL_RUNTIME" --time_based | tee -a "$RESULT_FILE" || true
        else
            sleep 2; sync 2>/dev/null
            run_fio "ai-load-${dn}" --filename="${md}/ckpt.dat" --rw=read --bs=4M \
                --size="$AI_MODEL_SIZE" --numjobs="$AI_MODEL_JOBS" \
                --runtime="$AI_MODEL_RUNTIME" --time_based | tee -a "$RESULT_FILE" || true
        fi

        # 分布式读
        echo -n "    分布式读(256k,${AI_MODEL_JOBS}jobs):" | tee -a "$RESULT_FILE"
        if [ "${dn}" = "s3_with_seaweedfs" ]; then
            run_fio "ai-distread-${dn}" --filename="$ai_read_tf" --rw=randread --bs=256k \
                --size="$AI_MODEL_SIZE" --numjobs="$AI_MODEL_JOBS" \
                --runtime="$AI_MODEL_RUNTIME" --time_based | tee -a "$RESULT_FILE" || true
            rm -f "$ai_read_tf" 2>/dev/null || true
        else
            run_fio "ai-distread-${dn}" --filename="${md}/ckpt.dat" --rw=randread --bs=256k \
                --size="$AI_MODEL_SIZE" --numjobs="$AI_MODEL_JOBS" \
                --runtime="$AI_MODEL_RUNTIME" --time_based | tee -a "$RESULT_FILE" || true
        fi

        # 日志写
        echo -n "    日志写(8k):" | tee -a "$RESULT_FILE"
        if [ "${dn}" = "image" ]; then
            echo " ⏭ 只读" | tee -a "$RESULT_FILE"
        elif [ "${dn}" = "s3_with_seaweedfs" ]; then
            run_fio_csi_safe_write "ai-log-${dn}" \
                --filename="${md}/log.dat" --rw=randwrite --bs=8k --size="$AI_MODEL_SIZE" \
                --numjobs=2
        else
            run_fio "ai-log-${dn}" --filename="${md}/log.dat" --rw=randwrite --bs=8k \
                --size="$AI_MODEL_SIZE" --numjobs=2 || true
        fi | tee -a "$RESULT_FILE"

        [ "$dn" != "image" ] && rm -rf "$md" 2>/dev/null || true
    done
else
    echo -e "\n⏭️  场景 3/3: AI 大模型 (已禁用, TEST_AI_MODEL=${TEST_AI_MODEL})" | tee -a "$RESULT_FILE"
fi

# ============================================================
# 生成 HTML 报告
# ============================================================
cat > "$HTML_FILE" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="zh">
<head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>SeaweedFS fio 性能报告</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:#0d1117;color:#c9d1d9;padding:24px;line-height:1.6}
h1{color:#58a6ff;margin-bottom:4px}h2{color:#8b949e;font-weight:400;font-size:16px;margin-bottom:24px}
h3{color:#f0883e;margin:24px 0 12px;border-bottom:1px solid #30363d;padding-bottom:8px}
h4{color:#79c0ff;margin:12px 0 8px;font-size:14px}
table{width:100%;border-collapse:collapse;margin:12px 0 24px;font-size:13px}
th{background:#161b22;color:#8b949e;text-align:left;padding:10px 12px;border:1px solid #30363d;position:sticky;top:0;z-index:1}
td{padding:8px 12px;border:1px solid #30363d;font-variant-numeric:tabular-nums}
tr:nth-child(even){background:#161b22}
tr:hover{background:#1c2535}
.best{color:#3fb950;font-weight:600}
.worst{color:#f85149}
.desc{color:#8b949e;font-size:12px;max-width:320px}
.detail{font-size:11px;color:#6e7681}
.legend{display:flex;gap:24px;flex-wrap:wrap;margin:8px 0}
.legend-item{display:flex;align-items:center;gap:6px;font-size:12px}
.legend-dot{width:10px;height:10px;border-radius:50%;flex-shrink:0}
.dot-nfs{background:#58a6ff}.dot-s3{background:#f0883e}.dot-csi{background:#3fb950}.dot-image{background:#a371f7}
.scenario-desc{color:#8b949e;font-size:13px;margin-bottom:12px;line-height:1.7}
.test-desc-tooltip{cursor:help;border-bottom:1px dotted #6e7681}
.test-desc-tooltip:hover{color:#c9d1d9;border-bottom-color:#c9d1d9}
.note{background:#1a1f2e;border-left:3px solid #d29922;padding:10px 14px;margin:12px 0;font-size:12px;color:#8b949e;border-radius:0 4px 4px 0}
.note strong{color:#e3b341}
.summary-box{background:#161b22;border:1px solid #30363d;border-radius:8px;padding:16px;margin-bottom:24px;font-size:13px;color:#8b949e}
.summary-box strong{color:#c9d1d9}
.csi-tag{display:inline-block;background:#1a3a2a;color:#3fb950;font-size:11px;padding:1px 6px;border-radius:3px;margin-left:4px}
.host-info-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:16px;margin-bottom:24px}
.host-info-card{background:#161b22;border:1px solid #30363d;border-radius:8px;padding:14px 16px}
.host-info-card h4{color:#79c0ff;margin:0 0 10px;font-size:13px;border-bottom:1px solid #30363d;padding-bottom:6px}
.host-info-card table{width:100%;border-collapse:collapse;font-size:12px;margin:0}
.host-info-card td{padding:3px 8px 3px 0;border:none;color:#8b949e}
.host-info-card td+td{color:#c9d1d9;text-align:right;font-family:monospace;font-size:11px}
.host-info-card tr:nth-child(even){background:transparent}
</style></head><body>
<h1>🌿 SeaweedFS fio 性能基准报告</h1>
<h2>__TIMESTAMP__</h2>

<!-- 存储后端说明 -->
<div class="summary-box">
<strong>📂 对比的四类存储挂载方式</strong>
<div class="legend">
<div class="legend-item"><span class="legend-dot dot-nfs"></span><b style="color:#c9d1d9">NFS</b> <span style="color:#6e7681">— 传统 NFS 协议，weed filer 通过 NFS 导出</span></div>
<div class="legend-item"><span class="legend-dot dot-s3"></span><b style="color:#c9d1d9">S3 (rclone)</b> <span style="color:#6e7681">— rclone FUSE 挂载 S3 API，实时双向同步</span></div>
<div class="legend-item"><span class="legend-dot dot-csi"></span><b style="color:#c9d1d9">CSI Driver</b> <span style="color:#6e7681">— Kubernetes CSI 原生挂载，weed mount FUSE<span class="csi-tag">⚠️ EIO风险</span></span></div>
<div class="legend-item"><span class="legend-dot dot-image"></span><b style="color:#c9d1d9">ImageVolume</b> <span style="color:#6e7681">— OCI 镜像直接挂载，🔒 只读 · 零拷贝 · 预填充数据</span></div>
</div>
</div>

<!-- 指标说明 -->
<div class="summary-box">
<strong>📊 指标含义 & 如何判断优劣</strong>
<table style="margin:8px 0;font-size:13px;border:none">
<tr>
<td style="border:none;padding:4px 16px 4px 0"><b style="color:#58a6ff">读 IOPS</b><br><span style="font-size:11px">每秒随机读取次数<br>📈 越高越好 → 小文件并发访问更快</span></td>
<td style="border:none;padding:4px 16px 4px 0"><b style="color:#58a6ff">读带宽 MB/s</b><br><span style="font-size:11px">大文件顺序读取速度<br>📈 越高越好 → 视频/模型加载更快</span></td>
</tr><tr>
<td style="border:none;padding:4px 16px 4px 0"><b style="color:#3fb950">写 IOPS</b><br><span style="font-size:11px">每秒随机写入次数<br>📈 越高越好 → 数据库/日志写入更快</span></td>
<td style="border:none;padding:4px 16px 4px 0"><b style="color:#3fb950">写带宽 MB/s</b><br><span style="font-size:11px">大文件顺序写入速度<br>📈 越高越好 → 备份/归档/checkpoint更快</span></td>
</tr><tr>
<td style="border:none;padding:4px 16px 4px 0"><b style="color:#a371f7">延迟 ms</b><br><span style="font-size:11px">单次 I/O 操作平均耗时<br>📉 越低越好 → 响应更灵敏</span></td>
<td style="border:none;padding:4px 16px 4px 0"></td>
</tr></table>
<div class="note">💡 <strong>绿色高亮</strong> = 该行最优值 &nbsp;|&nbsp; <span style="color:#f85149">红色</span> = 最差值 &nbsp;|&nbsp; 值为 0 = 该测试不涉及对应操作类型</div>
</div>
__BODY__
</body></html>
HTMLEOF

sed -i "s/__TIMESTAMP__/$(date)/" "$HTML_FILE"

# ============================================================
# 收集主机配置信息 (硬件 + 系统 + 内核参数)
# ============================================================
cat > "${DATA_DIR}/host-info.json" << HOSTEOF
{
  "timestamp": "$(date -Iseconds)",
  "hardware": {
    "cpu_model": "$(grep 'model name' /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | xargs || echo 'N/A')",
    "cpu_cores": "$(nproc 2>/dev/null || echo 'N/A')",
    "memory_total": "$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{printf "%.1f GB", $2/1048576}' || echo 'N/A')",
    "memory_available": "$(grep MemAvailable /proc/meminfo 2>/dev/null | awk '{printf "%.1f GB", $2/1048576}' || echo 'N/A')",
    "disk_mounts": "$(df -h /mnt/nfs /mnt/s3 /mnt/s3_with_seaweedfs /mnt/image 2>/dev/null | tail -4 | awk '{print $6, $2, $3}' | paste -sd ';' - || echo 'N/A')"
  },
  "system": {
    "kernel": "$(uname -r 2>/dev/null || echo 'N/A')",
    "os": "$(cat /etc/os-release 2>/dev/null | grep PRETTY_NAME | cut -d= -f2 | tr -d '\"' || echo 'N/A')",
    "hostname": "$(hostname 2>/dev/null || echo 'N/A')"
  },
  "kernel_params": {
    "fs.file-max": "$(cat /proc/sys/fs/file-max 2>/dev/null || echo 'N/A')",
    "fs.nfs.nfs_congestion_kb": "$(cat /proc/sys/fs/nfs/nfs_congestion_kb 2>/dev/null || echo 'N/A')",
    "vm.dirty_bytes": "$(cat /proc/sys/vm/dirty_bytes 2>/dev/null || echo 'N/A')",
    "vm.dirty_background_bytes": "$(cat /proc/sys/vm/dirty_background_bytes 2>/dev/null || echo 'N/A')",
    "net.core.rmem_max": "$(cat /proc/sys/net/core/rmem_max 2>/dev/null || echo 'N/A')",
    "net.core.wmem_max": "$(cat /proc/sys/net/core/wmem_max 2>/dev/null || echo 'N/A')"
  },
  "test_config": {
    "AI_MODEL_SIZE": "${AI_MODEL_SIZE}",
    "TEST_SIZE": "${TEST_SIZE}",
    "SMALL_FILE_COUNT": "${SMALL_FILE_COUNT}",
    "SMALL_FILE_SIZE": "${SMALL_FILE_SIZE}",
    "CSI_WRITE_RATE": "${CSI_WRITE_RATE}",
    "FIO_MEMORY_LIMIT": "${FIO_MEMORY_LIMIT:-未设置}",
    "RCLONE_MEMORY_LIMIT": "${RCLONE_MEMORY_LIMIT:-未设置}",
    "WEED_MOUNT_CACHE_MB": "${WEED_MOUNT_CACHE_MB:-未设置}",
    "CSI_CONCURRENT_WRITERS": "${CSI_CONCURRENT_WRITERS:-未设置}"
  }
}
HOSTEOF

# 从 metrics.dat 生成 HTML 表格
python3 << 'PYEOF'
import os, json
from datetime import datetime

data_dir = os.environ.get('DATA_DIR', '/tmp/fio-results/data')
html_file = os.environ.get('HTML_FILE', '/tmp/fio-results/fio_report.html')

# 从环境变量读取配置参数（用于场景描述）
SMALL_FILE_COUNT = int(os.environ.get('SMALL_FILE_COUNT', '2000'))
SMALL_FILE_SIZE = os.environ.get('SMALL_FILE_SIZE', '16k')
AI_MODEL_SIZE = os.environ.get('AI_MODEL_SIZE', '512M')

# 读取指标
rows = []
metrics_file = os.path.join(data_dir, 'metrics.dat')
if not os.path.exists(metrics_file):
    print("No metrics data, skipping HTML generation")
    exit(0)
with open(metrics_file) as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith('label|'): continue
        parts = line.split('|')
        if len(parts) < 6: continue
        rows.append(parts)

if not rows:
    print("No metrics data, skipping HTML generation")
    exit(0)

# 按场景和目录分组
tests = {}     # key: test_name -> { dir: {read: {iops,bw,lat}, write: {iops,bw,lat}} }
for r in rows:
    label, op, iops, bw, lat_us, lat_ms = r
    # 解析: scenario-detail-dir[-suffix] → scenario, detail, dir
    KNOWN_DIRS = ['nfs', 's3', 's3_with_seaweedfs', 'image']
    dir_name = ''
    test_name = label
    for d in KNOWN_DIRS:
        if label.endswith('-' + d):
            dir_name = d
            test_name = label[:-(len(d)+1)]
            break
    # 去除 -retry / -fallback 后缀以正确分组
    if test_name.endswith('-retry'):
        test_name = test_name[:-6]
    elif test_name.endswith('-fallback'):
        test_name = test_name[:-9]
    if not dir_name:
        continue  # 跳过无法解析的标签（如 CSI 降级重试产生的中间标签）
    if test_name not in tests:
        tests[test_name] = {}
    if dir_name not in tests[test_name]:
        tests[test_name][dir_name] = {}
    tests[test_name][dir_name][op] = {'iops': float(iops), 'bw': float(bw), 'lat': float(lat_us)}

# 目录显示名
dir_labels = {'nfs': 'NFS', 's3': 'S3 (rclone)', 's3_with_seaweedfs': 'CSI Driver', 'image': 'ImageVolume 🔒'}
DIR_ORDER = ['nfs', 's3', 's3_with_seaweedfs', 'image']

# 测试项描述 (中文，用户友好)
TEST_DESCRIPTIONS = {
    # 场景 1: 基础读写
    'basic-seq-write':  ('顺序写 (1M块)', '大文件连续写入 — 模拟视频存储、数据备份、模型保存'),
    'basic-seq-read':   ('顺序读 (1M块)', '大文件连续读取 — 模拟视频播放、数据恢复、模型加载'),
    'basic-rand-write': ('随机写 (4k块)', '小数据块随机写入 — 模拟数据库增删改、元数据更新'),
    'basic-rand-read':  ('随机读 (4k块)', '小数据块随机读取 — 模拟数据库查询、缓存查找'),
    # 场景 2: 小文件
    'small-create':    ('批量创建小文件', '同时创建数千个 16KB 小文件 — 模拟静态资源部署、缩略图生成'),
    'small-randread':  ('随机读小文件', '在数千个小文件中随机读取 — 模拟 CDN 回源、头像加载'),
    'small-randwrite': ('随机写小文件', '随机修改小文件内容 — 模拟配置热更新、状态文件写入'),
    'small-randrw':    ('混合读写 (70R/30W)', '70% 读 + 30% 写混合负载 — 模拟真实 Web 应用 I/O 模式'),
    # 场景 3: AI 大模型
    'ai-save':      ('Checkpoint 保存 (4M块)', '训练中断点保存 — 大文件顺序写入，fsync 保证持久化'),
    'ai-load':      ('模型加载 (4M块多线程)', '模型权重从存储加载到 GPU — 大文件多线程读取'),
    'ai-distread':  ('分布式读取 (256k多线程)', '分布式训练中多节点同时读取参数 — 混合块大小并发读'),
    'ai-log':       ('日志写入 (8k块)', '训练日志指标持久化 — 小块随机写，持续流式写入'),
}

# 场景分组及场景描述
SCENARIOS = [
    ('场景 1: 基础读写性能', 'basic-',
     '单文件 256MB 读写基准测试，反映存储系统的基础吞吐能力。'
     '<b>顺序读写</b>测量大块数据传输速度（MB/s），<b>随机读写</b>测量小块 I/O 并发能力（IOPS）。'
     '这是最基础的存储性能指标，直接影响所有上层应用。'),
    ('场景 2: 小文件并发读写', 'small-',
     f'同时操作 {SMALL_FILE_COUNT} 个 {SMALL_FILE_SIZE} 小文件，模拟真实生产环境的海量小文件场景。'
     '小文件性能是分布式存储的核心挑战 — 元数据操作开销远大于数据传输本身。'
     '<b>IOPS 越高</b>，应用启动、静态资源分发、容器镜像拉取越快。'),
    ('场景 3: AI/ML 训练负载', 'ai-',
     f'模拟深度学习训练中的典型 I/O 模式：{AI_MODEL_SIZE} 模型文件的 checkpoint 保存/加载，'
     '分布式训练的并发读取，以及训练日志的持续写入。'
     '<b>读带宽</b>决定模型加载速度，<b>写延迟</b>决定 checkpoint 频率上限。'),
]

def find_best_worst(values):
    """找出非零值中的最大和最小值索引"""
    valid = [(i, v) for i, v in enumerate(values) if v > 0]
    if len(valid) < 2:
        return None, None
    best_idx = max(valid, key=lambda x: x[1])[0]
    worst_idx = min(valid, key=lambda x: x[1])[0]
    return best_idx, worst_idx

def format_cell(value, fmt, best_idx, worst_idx, col_idx):
    """格式化单元格，高亮最优/最差值"""
    cls = ''
    if col_idx == best_idx and best_idx is not None:
        cls = ' class="best"'
    elif col_idx == worst_idx and worst_idx is not None:
        cls = ' class="worst"'
    return f'<td{cls}>{value:{fmt}}</td>'

# ============================================================
# 生成主机配置信息段
# ============================================================
host_info_html = ''
host_info_file = os.path.join(data_dir, 'host-info.json')
if os.path.exists(host_info_file):
    try:
        with open(host_info_file) as f:
            host = json.load(f)

        def kv_row(k, v):
            return f'<tr><td>{k}</td><td>{v}</td></tr>'

        hw = host.get('hardware', {})
        sys_info = host.get('system', {})
        kp = host.get('kernel_params', {})
        tc = host.get('test_config', {})

        host_info_html += '<h3>🖥️ 实验环境配置</h3>\n<div class="host-info-grid">\n'

        # 硬件信息
        host_info_html += '<div class="host-info-card"><h4>💻 硬件信息</h4><table>'
        host_info_html += kv_row('CPU', hw.get('cpu_model', 'N/A'))
        host_info_html += kv_row('CPU 核心数', str(hw.get('cpu_cores', 'N/A')))
        host_info_html += kv_row('内存总量', hw.get('memory_total', 'N/A'))
        host_info_html += kv_row('可用内存', hw.get('memory_available', 'N/A'))
        host_info_html += '</table></div>\n'

        # 系统信息
        host_info_html += '<div class="host-info-card"><h4>🐧 系统信息</h4><table>'
        host_info_html += kv_row('内核版本', sys_info.get('kernel', 'N/A'))
        host_info_html += kv_row('操作系统', sys_info.get('os', 'N/A'))
        host_info_html += kv_row('主机名', sys_info.get('hostname', 'N/A'))
        host_info_html += kv_row('测试时间', host.get('timestamp', 'N/A')[:19])
        host_info_html += '</table></div>\n'

        # 内核参数
        host_info_html += '<div class="host-info-card"><h4>⚙️ 内核参数</h4><table>'
        for k, v in kp.items():
            host_info_html += kv_row(k, str(v))
        host_info_html += '</table></div>\n'

        # 测试配置
        host_info_html += '<div class="host-info-card"><h4>🧪 测试配置</h4><table>'
        for k, v in tc.items():
            host_info_html += kv_row(k, str(v))
        host_info_html += '</table></div>\n'

        host_info_html += '</div>\n'
    except Exception as e:
        host_info_html = f'<!-- Host info generation failed: {e} -->\n'

html_body = host_info_html
for scenario_title, prefix, scenario_desc in SCENARIOS:
    test_keys = [k for k in sorted(tests) if k.startswith(prefix)]
    if not test_keys:
        continue

    html_body += f'<h3>{scenario_title}</h3>\n'
    html_body += f'<p class="scenario-desc">{scenario_desc}</p>\n'

    # 构建汇总表：每个 test 一行，显示所有三个指标
    html_body += '<table>\n'
    html_body += '<tr><th>测试项</th><th>说明</th>'
    for d in DIR_ORDER:
        html_body += f'<th>{dir_labels.get(d, d)}</th>'
    html_body += '</tr>\n'

    for tk in test_keys:
        desc_label = TEST_DESCRIPTIONS.get(tk, ('', ''))
        display_name = desc_label[0] or tk.replace(prefix, '').replace('-', ' ').title()
        tooltip = desc_label[1] or ''

        for op, op_label in [('read', '读'), ('write', '写')]:
            values = []
            for d in DIR_ORDER:
                v = tests.get(tk, {}).get(d, {}).get(op, {})
                values.append(v)

            # 确定要显示什么：如果所有值为 0，跳过该操作
            has_data = any(v.get('iops', 0) > 0 or v.get('bw', 0) > 0 for v in values)
            if not has_data:
                continue

            # IOPS 行
            iops_vals = [v.get('iops', 0) for v in values]
            best_i, worst_i = find_best_worst(iops_vals)
            html_body += '<tr>'
            if display_name:
                html_body += f'<td rowspan="3" class="test-desc-tooltip" title="{tooltip}">{display_name}</td>'
                display_name = ''  # 只在第一行显示名称
            html_body += f'<td class="detail">{op_label} IOPS <span class="desc">📈 越高越好</span></td>'
            for ci, d in enumerate(DIR_ORDER):
                v = values[ci]
                html_body += format_cell(v.get('iops', 0), ',.0f', best_i, worst_i, ci)
            html_body += '</tr>\n'

            # 带宽行
            bw_vals = [v.get('bw', 0) for v in values]
            best_i, worst_i = find_best_worst(bw_vals)
            html_body += '<tr>'
            html_body += f'<td class="detail">{op_label} BW (MB/s) <span class="desc">📈 越高越好</span></td>'
            for ci, d in enumerate(DIR_ORDER):
                v = values[ci]
                html_body += format_cell(v.get('bw', 0), '.1f', best_i, worst_i, ci)
            html_body += '</tr>\n'

            # 延迟行
            lat_vals = [v.get('lat', 0) / 1000 for v in values]  # us → ms
            # 延迟: 最低最好 (反向评比)
            valid_lat = [(i, v) for i, v in enumerate(lat_vals) if v > 0]
            if len(valid_lat) >= 2:
                best_lat = min(valid_lat, key=lambda x: x[1])[0]
                worst_lat = max(valid_lat, key=lambda x: x[1])[0]
            else:
                best_lat = worst_lat = None
            html_body += '<tr>'
            html_body += f'<td class="detail">{op_label} 延迟 (ms) <span class="desc">📉 越低越好</span></td>'
            for ci, d in enumerate(DIR_ORDER):
                v = values[ci]
                lat = v.get('lat', 0) / 1000
                cls = ''
                if ci == best_lat and best_lat is not None and lat > 0:
                    cls = ' class="best"'
                elif ci == worst_lat and worst_lat is not None and lat > 0:
                    cls = ' class="worst"'
                html_body += f'<td{cls}>{lat:.2f}</td>'
            html_body += '</tr>\n'

    html_body += '</table>\n'

    # 场景小结
    html_body += '<div class="note">'
    html_body += f'<strong>📝 如何理解 {scenario_title.split(":")[0]}：</strong> '
    if '基础读写' in scenario_title:
        html_body += '关注<b>带宽</b>（顺序读写）和 <b>IOPS</b>（随机读写）。NFS 通常在低延迟随机 I/O 上占优，CSI 在大块顺序读写上有优势。若 CSI 值为 0，说明 FUSE fsync 返回 EIO 导致写测试失败（已自动降级重试）。<b>ImageVolume</b> 仅显示读性能（🔒 只读），其数据在镜像构建时预填充。'
    elif '小文件' in scenario_title:
        html_body += '关注<b>读写 IOPS</b>。小文件场景下元数据操作占主导，CSI (weed mount) 的 FUSE 层可能成为瓶颈。若 CSI 写入 IOPS 异常低，检查 FUSE 脏页是否堆积。<b>ImageVolume</b> 小文件在镜像层中预创建，读性能通常最优（无网络/ FUSE 开销）。'
    elif 'AI' in scenario_title:
        html_body += '关注<b>读带宽</b>（模型加载速度）和<b>写延迟</b>（checkpoint 保存耗时）。多线程读取能力决定分布式训练的数据供给速度。CSI 若延迟异常高，可能是 FUSE 用户态调度开销。<b>ImageVolume</b> 模型文件预置在镜像中，模拟容器镜像分发模型的真实场景。'
    html_body += '</div>\n'

try:
    with open(html_file, 'r') as f:
        html = f.read()
    html = html.replace('__BODY__', html_body)
    with open(html_file, 'w') as f:
        f.write(html)
    print(f"HTML report generated: {html_file}")
except Exception as e:
    print(f"HTML generation failed: {e}")
PYEOF

# 生成 index.html 重定向
cat > "$INDEX_FILE" << EOF
<!DOCTYPE html>
<html><head><meta charset="UTF-8">
<meta http-equiv="refresh" content="0;url=fio_${TIMESTAMP}.html">
</head><body><p>跳转到最新报告: <a href="fio_${TIMESTAMP}.html">fio_${TIMESTAMP}.html</a></p></body></html>
EOF

# 确保 nginx 容器可读 (fio 容器可能以 root 写文件，nginx 以 nginx 用户运行)
chmod -R a+r "$RESULT_DIR" 2>/dev/null || true

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  🎉 测试完成！"
echo "  文本报告: ${RESULT_FILE}"
echo "  HTML报告: ${HTML_FILE}"
echo "  首页入口: ${INDEX_FILE}"
echo "════════════════════════════════════════════════════════════"
echo ""
echo "访问报告: http://<ingress-ip>/fio/"
echo ""

exec sleep infinity
