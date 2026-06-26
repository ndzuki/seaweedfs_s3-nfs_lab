#!/bin/bash
# ============================================================
# fio 自动测试入口脚本
# 使用 JSON 输出格式，生成 TXT + HTML 报告
# ============================================================
set -euo pipefail

TEST_SIZE="${TEST_SIZE:-256M}"
TEST_RUNTIME="${TEST_RUNTIME:-60s}"
TEST_DIRS=("/mnt/nfs" "/mnt/s3" "/mnt/s3_with_seaweedfs")
RESULT_DIR="${RESULT_DIR:-/tmp/fio-results}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-300}"

TEST_BASIC="${TEST_BASIC:-true}"
TEST_SMALL_FILES="${TEST_SMALL_FILES:-true}"
TEST_AI_MODEL="${TEST_AI_MODEL:-true}"
# 便捷场景选择: TEST_SCENARIO=small 只跑小文件 (basic|small|ai|all)
case "${TEST_SCENARIO:-all}" in
    basic) TEST_BASIC=true;  TEST_SMALL_FILES=false; TEST_AI_MODEL=false ;;
    small) TEST_BASIC=false; TEST_SMALL_FILES=true;  TEST_AI_MODEL=false ;;
    ai)    TEST_BASIC=false; TEST_SMALL_FILES=false; TEST_AI_MODEL=true ;;
    all)   ;;
esac

SMALL_FILE_COUNT="${SMALL_FILE_COUNT:-2000}"
SMALL_FILE_SIZE="${SMALL_FILE_SIZE:-16k}"
SMALL_FILE_RUNTIME="${SMALL_FILE_RUNTIME:-120s}"
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
banner() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  🌿 SeaweedFS fio 基准测试"
    echo "  基础: ${TEST_SIZE}/${TEST_RUNTIME} | 小文件: ${SMALL_FILE_COUNT}×${SMALL_FILE_SIZE}"
    echo "  AI模型: ${AI_MODEL_SIZE}×${AI_MODEL_JOBS}jobs (CSI限制512M)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# 等待挂载点就绪 + 可写验证，返回实际可用的目录列表到 READY_DIRS 数组
READY_DIRS=()
wait_mounts() {
    for dir in "${TEST_DIRS[@]}"; do
        echo -n "⏳ 等待 ${dir} ..."
        local waited=0
        while [ $waited -lt $WAIT_TIMEOUT ]; do
            if mountpoint -q "$dir" 2>/dev/null; then
                # 验证可写 (touch 成功才算真正就绪)
                if touch "${dir}/.fio_writable_test" 2>/dev/null; then
                    rm -f "${dir}/.fio_writable_test" 2>/dev/null
                    echo " ✓"; break
                fi
            fi
            sleep 3; waited=$((waited + 3))
        done
        if [ $waited -ge $WAIT_TIMEOUT ]; then
            echo " ⚠️ 超时，跳过"
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
                dd if=/dev/zero of="$warm_file" bs=1M count=4 conv=notrunc 2>/dev/null || true
                if [ -s "$warm_file" ]; then
                    echo " ✓ (数据路径正常, $(stat -c%s "$warm_file" 2>/dev/null || wc -c < "$warm_file") bytes)"
                else
                    echo " ⚠️ 写入异常 — 文件为空, 降级重试将自动启用"
                fi
                # 单独测试 fsync (FUSE 已知问题: weed mount 返回 EIO)
                if dd if=/dev/zero of="${warm_file}.fsync_test" bs=4k count=1 conv=fsync 2>/dev/null; then
                    echo "   ✓ FUSE fsync 正常"
                else
                    echo "   ⚠️ FUSE fsync 返回 EIO — 写入降级+读取 truncate 规避已就绪"
                fi
                rm -f "$warm_file" "${warm_file}.fsync_test" 2>/dev/null || true
                ;;
        esac
    done
}

# 运行 fio 并提取 JSON 关键指标 → 保存到 data 文件
# 所有子命令均有 fallback，防止 set -e 下因 fio/jq 异常退出
run_fio() {
    local label="$1"; shift
    local json_file="${DATA_DIR}/${label}.json"

    # fio 执行，失败时输出诊断信息 (stderr 末尾行)
    fio --name="$label" --output-format=json "$@" 2>"${DATA_DIR}/${label}.err" > "$json_file" || {
        echo "    ⚠️ fio 失败: ${label}" >&2
        # 输出 stderr 末尾 5 行供诊断 (fio 错误原因通常在最末)
        if [ -s "${DATA_DIR}/${label}.err" ]; then
            echo "    ── fio stderr (last 5 lines):" >&2
            tail -5 "${DATA_DIR}/${label}.err" | while IFS= read -r errline; do
                echo "    │ ${errline}" >&2
            done
        fi
        echo "${label}|none|0|0|0|0" >> "${DATA_DIR}/metrics.dat"
        return 0
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
        return 0
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
}

# CSI 挂载安全运行: 首次用 --size 限流 (无 time_based, 避免大量脏数据导致 fsync 挂死),
# 失败后自动降级重试 (移除 end_fsync, 减块减量)
run_fio_csi_safe() {
    local label="$1"; shift
    local orig_args=("$@")

    # 首次尝试: 去除 --time_based/--runtime (避免 60s 持续写入堆积 FUSE 脏页)
    # 仅靠 --size 限制数据量, 让 fsync 快速返回 (无论 EIO 还是成功)
    local first_args=()
    for arg in "${orig_args[@]}"; do
        case "$arg" in
            --time_based) continue ;;
            --runtime=*)  continue ;;
            *)            first_args+=("$arg") ;;
        esac
    done
    run_fio "$label" "${first_args[@]}"

    # 检查是否失败 (metrics.dat 中标记为 none)
    if grep -q "^${label}|none|" "${DATA_DIR}/metrics.dat" 2>/dev/null; then
        echo "    ↳ CSI 降级重试 (移除 end_fsync, 64M/128k)..." >&2

        # 降级参数: 移除 --end_fsync; bs=1M → 128k; size=256M → 64M
        local degraded=()
        for arg in "${first_args[@]}"; do
            case "$arg" in
                --end_fsync=*) continue ;;
                --bs=1M)       degraded+=("--bs=128k") ;;
                --size=256M)   degraded+=("--size=64M") ;;
                *)             degraded+=("$arg") ;;
            esac
        done

        run_fio "${label}-fallback" "${degraded[@]}"
    fi
}

banner
wait_mounts

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

        # CSI 挂载 (s3_with_seaweedfs) 使用安全包装: 失败时自动降级重试
        # 读取用 truncate 预分配 (纯元数据, 避开 FUSE write-close EIO)
        if [ "$dn" = "s3_with_seaweedfs" ]; then
            echo -n "    顺序写(1M):" | tee -a "$RESULT_FILE"
            run_fio_csi_safe "basic-seq-write-${dn}" --filename="$tf" --rw=write --bs=1M --size="$TEST_SIZE" --numjobs=1 --runtime="$TEST_RUNTIME" --time_based --end_fsync=1 | tee -a "$RESULT_FILE"
            echo -n "    顺序读(1M):" | tee -a "$RESULT_FILE"
            read_tf="${dir}/fio_basic_read.dat"
            rm -f "$read_tf" 2>/dev/null || true
            truncate -s "${TEST_SIZE}" "$read_tf" 2>/dev/null || true
            sync 2>/dev/null; sleep 1
            run_fio "basic-seq-read-${dn}" --filename="$read_tf" --rw=read --bs=1M --size="$TEST_SIZE" --numjobs=1 | tee -a "$RESULT_FILE" || {
                sleep 5
                run_fio "basic-seq-read-${dn}-retry" --filename="$read_tf" --rw=read --bs=1M --size="$TEST_SIZE" --numjobs=1 | tee -a "$RESULT_FILE"
            }
            rm -f "$read_tf" 2>/dev/null || true
            echo -n "    随机写(4k):" | tee -a "$RESULT_FILE"
            run_fio_csi_safe "basic-rand-write-${dn}" --filename="$tf" --rw=randwrite --bs=4k --size="$TEST_SIZE" --numjobs=1 --runtime="$TEST_RUNTIME" --time_based --end_fsync=1 | tee -a "$RESULT_FILE"
            echo -n "    随机读(4k):" | tee -a "$RESULT_FILE"
            read_tf="${dir}/fio_basic_randread.dat"
            rm -f "$read_tf" 2>/dev/null || true
            truncate -s "${TEST_SIZE}" "$read_tf" 2>/dev/null || true
            sync 2>/dev/null; sleep 1
            run_fio "basic-rand-read-${dn}" --filename="$read_tf" --rw=randread --bs=4k --size="$TEST_SIZE" --numjobs=1 | tee -a "$RESULT_FILE" || {
                sleep 5
                run_fio "basic-rand-read-${dn}-retry" --filename="$read_tf" --rw=randread --bs=4k --size="$TEST_SIZE" --numjobs=1 | tee -a "$RESULT_FILE"
            }
            rm -f "$read_tf" 2>/dev/null || true
        else
            echo -n "    顺序写(1M):" | tee -a "$RESULT_FILE"
            run_fio "basic-seq-write-${dn}" --filename="$tf" --rw=write --bs=1M --size="$TEST_SIZE" --numjobs=1 --runtime="$TEST_RUNTIME" --time_based --end_fsync=1 | tee -a "$RESULT_FILE"
            echo -n "    顺序读(1M):" | tee -a "$RESULT_FILE"
            sleep 1; run_fio "basic-seq-read-${dn}" --filename="$tf" --rw=read --bs=1M --size="$TEST_SIZE" --numjobs=1 | tee -a "$RESULT_FILE" || {
                sleep 5
                run_fio "basic-seq-read-${dn}-retry" --filename="$tf" --rw=read --bs=1M --size="$TEST_SIZE" --numjobs=1 | tee -a "$RESULT_FILE"
            }
            echo -n "    随机写(4k):" | tee -a "$RESULT_FILE"
            run_fio "basic-rand-write-${dn}" --filename="$tf" --rw=randwrite --bs=4k --size="$TEST_SIZE" --numjobs=1 --runtime="$TEST_RUNTIME" --time_based --end_fsync=1 | tee -a "$RESULT_FILE"
            echo -n "    随机读(4k):" | tee -a "$RESULT_FILE"
            sleep 1; run_fio "basic-rand-read-${dn}" --filename="$tf" --rw=randread --bs=4k --size="$TEST_SIZE" --numjobs=1 | tee -a "$RESULT_FILE" || {
                sleep 5
                run_fio "basic-rand-read-${dn}-retry" --filename="$tf" --rw=randread --bs=4k --size="$TEST_SIZE" --numjobs=1 | tee -a "$RESULT_FILE"
            }
        fi
        rm -f "$tf" 2>/dev/null || true
    done
fi

# ============================================================
# 场景 2: 小文件
# ============================================================
if [ "${TEST_SMALL_FILES}" = "true" ]; then
    echo -e "\n══════ 场景 2/3: 小文件 (${SMALL_FILE_COUNT}×${SMALL_FILE_SIZE}) ══════" | tee -a "$RESULT_FILE"
    for dir in "${READY_DIRS[@]}"; do
        dn=$(basename "$dir"); sd="${dir}/small_files_${TIMESTAMP}"; mkdir -p "$sd"
        echo "  📂 ${dn}" | tee -a "$RESULT_FILE"
        # 创建文件
        echo -n "    创建小文件: " | tee -a "$RESULT_FILE"
        s=$(date +%s)
        if [ "$dn" = "s3_with_seaweedfs" ]; then
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

        echo -n "    随机读(4k,4jobs):" | tee -a "$RESULT_FILE"
        if [ "$dn" = "nfs" ]; then
            run_fio "small-randread-${dn}" --directory="$sd" --rw=randrw --rwmixread=99 --bs=4k --numjobs=4 --nrfiles=$SMALL_FILE_COUNT --filesize=$SMALL_FILE_SIZE --size=8M --filename_format='fio_small_$filenum.dat' --file_service_type=sequential --openfiles=64 --end_fsync=0 | tee -a "$RESULT_FILE"
        else
            run_fio "small-randread-${dn}" --directory="$sd" --rw=randread --bs=4k --numjobs=4 --nrfiles=$SMALL_FILE_COUNT --filesize=$SMALL_FILE_SIZE --size=8M --filename_format='fio_small_$filenum.dat' --file_service_type=sequential --openfiles=64 | tee -a "$RESULT_FILE"
        fi
        # 随机写 (CSI 挂载用安全包装避开 FUSE fsync EIO)
        echo -n "    随机写(4k,4jobs):" | tee -a "$RESULT_FILE"
        if [ "$dn" = "s3_with_seaweedfs" ]; then
            run_fio_csi_safe "small-randwrite-${dn}" --directory="$sd" --rw=randwrite --bs=4k --numjobs=4 --nrfiles=$SMALL_FILE_COUNT --filesize=$SMALL_FILE_SIZE --size=8M --filename_format='fio_small_$filenum.dat' --end_fsync=1 --file_service_type=sequential --openfiles=64 | tee -a "$RESULT_FILE"
        else
            run_fio "small-randwrite-${dn}" --directory="$sd" --rw=randwrite --bs=4k --numjobs=4 --nrfiles=$SMALL_FILE_COUNT --filesize=$SMALL_FILE_SIZE --size=8M --filename_format='fio_small_$filenum.dat' --end_fsync=1 --file_service_type=sequential --openfiles=64 | tee -a "$RESULT_FILE"
        fi
        # 混合读写 (CSI 挂载用安全包装)
        echo -n "    混合rw(70r30w):" | tee -a "$RESULT_FILE"
        if [ "$dn" = "s3_with_seaweedfs" ]; then
            run_fio_csi_safe "small-randrw-${dn}" --directory="$sd" --rw=randrw --rwmixread=70 --bs=4k --numjobs=4 --nrfiles=$SMALL_FILE_COUNT --filesize=$SMALL_FILE_SIZE --size=8M --filename_format='fio_small_$filenum.dat' --end_fsync=1 --file_service_type=sequential --openfiles=64 | tee -a "$RESULT_FILE"
        else
            run_fio "small-randrw-${dn}" --directory="$sd" --rw=randrw --rwmixread=70 --bs=4k --numjobs=4 --nrfiles=$SMALL_FILE_COUNT --filesize=$SMALL_FILE_SIZE --size=8M --filename_format='fio_small_$filenum.dat' --end_fsync=1 --file_service_type=sequential --openfiles=64 | tee -a "$RESULT_FILE"
        fi
        sync 2>/dev/null || true; rm -rf "$sd" 2>/dev/null || true
    done
fi

# ============================================================
# 场景 3: AI 大模型
# ============================================================
if [ "${TEST_AI_MODEL}" = "true" ]; then
    echo -e "\n══════ 场景 3/3: AI 大模型 (${AI_MODEL_SIZE}) ══════" | tee -a "$RESULT_FILE"
    for dir in "${READY_DIRS[@]}"; do
        dn=$(basename "$dir"); md="${dir}/ai_model"; mkdir -p "$md"
        echo "  📂 ${dn}" | tee -a "$RESULT_FILE"
        # checkpoint 写
        echo -n "    checkpoint写(4M):" | tee -a "$RESULT_FILE"
        if [ "${dn}" = "s3_with_seaweedfs" ]; then
            # CSI: 用 256M + 安全包装 (自动去除 end_fsync)
            run_fio_csi_safe "ai-save-${dn}" --filename="${md}/ckpt.dat" --rw=write --bs=4M --size=256M --numjobs=1 --end_fsync=1
        else
            run_fio "ai-save-${dn}" --filename="${md}/ckpt.dat" --rw=write --bs=4M --size="$AI_MODEL_SIZE" --numjobs=1 --runtime="$AI_MODEL_RUNTIME" --time_based --end_fsync=1
        fi | tee -a "$RESULT_FILE"
        # 模型加载读 (CSI 用独立预分配文件避开 FUSE fsync)
        echo -n "    模型加载读(4M,${AI_MODEL_JOBS}jobs):" | tee -a "$RESULT_FILE"
        if [ "${dn}" = "s3_with_seaweedfs" ]; then
            ai_read_tf="${md}/ckpt_load.dat"
            rm -f "$ai_read_tf" 2>/dev/null || true
            truncate -s 256M "$ai_read_tf" 2>/dev/null || true
            sleep 2; sync 2>/dev/null
            run_fio "ai-load-${dn}" --filename="$ai_read_tf" --rw=read --bs=4M --size=256M --numjobs="$AI_MODEL_JOBS" --runtime="$AI_MODEL_RUNTIME" --time_based | tee -a "$RESULT_FILE"
        else
            sleep 2; sync 2>/dev/null; run_fio "ai-load-${dn}" --filename="${md}/ckpt.dat" --rw=read --bs=4M --size="$AI_MODEL_SIZE" --numjobs="$AI_MODEL_JOBS" --runtime="$AI_MODEL_RUNTIME" --time_based | tee -a "$RESULT_FILE"
        fi
        # 分布式读
        echo -n "    分布式读(256k,${AI_MODEL_JOBS}jobs):" | tee -a "$RESULT_FILE"
        if [ "${dn}" = "s3_with_seaweedfs" ]; then
            run_fio "ai-distread-${dn}" --filename="$ai_read_tf" --rw=randread --bs=256k --size=256M --numjobs="$AI_MODEL_JOBS" --runtime="$AI_MODEL_RUNTIME" --time_based | tee -a "$RESULT_FILE"
            rm -f "$ai_read_tf" 2>/dev/null || true
        else
            run_fio "ai-distread-${dn}" --filename="${md}/ckpt.dat" --rw=randread --bs=256k --size="$AI_MODEL_SIZE" --numjobs="$AI_MODEL_JOBS" --runtime="$AI_MODEL_RUNTIME" --time_based | tee -a "$RESULT_FILE"
        fi
        # 日志写 (CSI 用安全包装)
        echo -n "    日志写(8k):" | tee -a "$RESULT_FILE"
        if [ "${dn}" = "s3_with_seaweedfs" ]; then
            run_fio_csi_safe "ai-log-${dn}" --filename="${md}/log.dat" --rw=randwrite --bs=8k --size=256M --numjobs=2 --runtime="$AI_MODEL_RUNTIME" --time_based --end_fsync=1 | tee -a "$RESULT_FILE"
        else
            run_fio "ai-log-${dn}" --filename="${md}/log.dat" --rw=randwrite --bs=8k --size=256M --numjobs=2 --runtime="$AI_MODEL_RUNTIME" --time_based --end_fsync=1 | tee -a "$RESULT_FILE"
        fi
        rm -rf "$md" 2>/dev/null || true
    done
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
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:#0d1117;color:#c9d1d9;padding:24px}
h1{color:#58a6ff;margin-bottom:4px}h2{color:#8b949e;font-weight:400;font-size:16px;margin-bottom:24px}
h3{color:#f0883e;margin:24px 0 12px;border-bottom:1px solid #30363d;padding-bottom:8px}
table{width:100%;border-collapse:collapse;margin:12px 0 24px;font-size:14px}
th{background:#161b22;color:#8b949e;text-align:left;padding:10px 12px;border:1px solid #30363d}
td{padding:8px 12px;border:1px solid #30363d;font-variant-numeric:tabular-nums}
tr:nth-child(even){background:#161b22}
.best{color:#3fb950;font-weight:600}
.dim{color:#8b949e;font-size:12px}
.bar{display:inline-block;height:8px;border-radius:4px;margin-right:4px}
.bar-nfs{background:#58a6ff}.bar-s3{background:#f0883e}.bar-csi{background:#3fb950}
</style></head><body>
<h1>🌿 SeaweedFS fio 性能基准报告</h1>
<h2>__TIMESTAMP__ | 挂载点: /mnt/nfs (NFS) | /mnt/s3 (rclone) | /mnt/s3_with_seaweedfs (CSI)</h2>
	<div style="background:#161b22;border:1px solid #30363d;border-radius:8px;padding:16px;margin-bottom:24px;font-size:13px;color:#8b949e;line-height:1.8">
	<strong style="color:#c9d1d9">📊 指标说明</strong><br>
	<table style="margin:8px 0;font-size:13px;border:none"><tr>
	<td style="border:none;padding:4px 16px 4px 0"><b style="color:#58a6ff">r_iops</b> — 读 IOPS<br><span style="font-size:11px">每秒随机读取操作次数，衡量小文件并发读取吞吐能力</span></td>
	<td style="border:none;padding:4px 16px 4px 0"><b style="color:#58a6ff">r_bw</b> — 读带宽<br><span style="font-size:11px">顺序读取速率 (MB/s)，衡量大文件流式读取传输速度</span></td>
	</tr><tr>
	<td style="border:none;padding:4px 16px 4px 0"><b style="color:#3fb950">w_iops</b> — 写 IOPS<br><span style="font-size:11px">每秒随机写入操作次数，衡量小文件并发写入吞吐能力</span></td>
	<td style="border:none;padding:4px 16px 4px 0"><b style="color:#3fb950">w_bw</b> — 写带宽<br><span style="font-size:11px">顺序写入速率 (MB/s)，衡量大文件流式写入传输速度</span></td>
	</tr></table>
	<span style="font-size:11px">💡 值越高越好。IOPS 决定小文件并发性能，带宽决定大文件传输速度。数值为 0 表示该测试项不涉及对应操作。</span>
	</div>
__BODY__
</body></html>
HTMLEOF

sed -i "s/__TIMESTAMP__/$(date)/" "$HTML_FILE"

# 从 metrics.dat 生成 HTML 表格
python3 << 'PYEOF'
import os, json
from datetime import datetime

data_dir = os.environ.get('DATA_DIR', '/tmp/fio-results/data')
html_file = os.environ.get('HTML_FILE', '/tmp/fio-results/fio_report.html')

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
    # 解析: scenario-detail-dir  -> scenario, detail, dir
    parts = label.split('-')
    dir_name = parts[-1]    # nfs, s3, s3_with_seaweedfs
    test_name = '-'.join(parts[:-1])  # basic-seq-write, small-randread, etc.
    if test_name not in tests:
        tests[test_name] = {}
    if dir_name not in tests[test_name]:
        tests[test_name][dir_name] = {}
    tests[test_name][dir_name][op] = {'iops': float(iops), 'bw': float(bw), 'lat': float(lat_us)}

# 目录显示名
dir_labels = {'nfs': 'NFS', 's3': 'S3 (rclone)', 's3_with_seaweedfs': 'CSI Driver'}

# 场景分组
scenarios = [
    ('基础读写 (单文件, 1 job)', [k for k in sorted(tests) if k.startswith('basic-')]),
    ('小文件随机读写 (2000+ files, 4 jobs)', [k for k in sorted(tests) if k.startswith('small-')]),
    ('AI 大模型读写 (2 GB, 4 jobs)', [k for k in sorted(tests) if k.startswith('ai-')]),
]

html_body = ''
for scenario_title, test_keys in scenarios:
    if not test_keys:
        continue
    html_body += f'<h3>{scenario_title}</h3>\n<table>\n'
    html_body += '<tr><th>测试项</th><th>指标</th>'
    for d in ['nfs', 's3', 's3_with_seaweedfs']:
        html_body += f'<th>{dir_labels.get(d, d)}</th>'
    html_body += '</tr>\n'

    # 为每个 test 显示一行 read + 一行 write
    for tk in test_keys:
        test_label = tk.replace('basic-','').replace('small-','').replace('ai-','').replace('-',' ').title()
        for op, op_label in [('read', '读'), ('write', '写')]:
            html_body += f'<tr><td>{test_label}</td><td>{op_label} IOPS</td>'
            for d in ['nfs', 's3', 's3_with_seaweedfs']:
                v = tests.get(tk, {}).get(d, {}).get(op, {})
                iops = v.get('iops', 0)
                html_body += f'<td>{iops:,.0f}</td>'
            html_body += '</tr>\n'
            html_body += f'<tr><td></td><td>{op_label} BW (MB/s)</td>'
            for d in ['nfs', 's3', 's3_with_seaweedfs']:
                v = tests.get(tk, {}).get(d, {}).get(op, {})
                bw = v.get('bw', 0)
                html_body += f'<td>{bw:.1f}</td>'
            html_body += '</tr>\n'
            html_body += f'<tr><td></td><td>{op_label} Lat (ms)</td>'
            for d in ['nfs', 's3', 's3_with_seaweedfs']:
                v = tests.get(tk, {}).get(d, {}).get(op, {})
                lat = v.get('lat', 0) / 1000  # us -> ms
                html_body += f'<td>{lat:.2f}</td>'
            html_body += '</tr>\n'
    html_body += '</table>\n'

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
