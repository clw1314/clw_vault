#!/usr/bin/env bash
# ============================================================
# 本地文件同步管理器
# Version: v2.0.1
#
# 功能:
#   1. 手动同步管理
#      - 临时手动同步
#      - 固定手动同步任务
#   2. 自动同步管理
#      - 支持多个独立定时同步计划
#      - 支持增量同步和镜像同步
#      - 支持立即执行
#   3. 兼容旧版 v1.x 单任务配置
#      - 自动读取旧版 OnCalendar
#      - 旧配置和服务文件自动备份
#      - 迁移后保留为 legacy_sync 计划
#   4. 日志
#      - 日志保存到 /var/log/sync-manager/
#      - 同时输出到 systemd journal
#   5. Telegram 通知
#      - 配置时强制发送测试消息
#      - 测试成功后才保存配置
# ============================================================

set -Eeuo pipefail

VERSION="v2.0.1"

BASE_SERVICE_NAME="local-rsync-sync"
MANAGER_DIR="/etc/sync-manager"
JOBS_DIR="${MANAGER_DIR}/jobs"
MANUAL_DIR="${MANAGER_DIR}/manual"
MANUAL_TASKS_FILE="${MANAGER_DIR}/manual-tasks.conf"

TELEGRAM_CONF="${MANAGER_DIR}/telegram.conf"
LOG_DIR="/var/log/sync-manager"

WORKER="/usr/local/sbin/sync-manager-worker"

LOCK_DIR="/run/lock"

# 旧版 v1.x 文件
LEGACY_CONFIG="/etc/local-rsync-sync.conf"
LEGACY_SERVICE_FILE="/etc/systemd/system/local-rsync-sync.service"
LEGACY_TIMER_FILE="/etc/systemd/system/local-rsync-sync.timer"
LEGACY_WORKER="/usr/local/sbin/local-rsync-sync-worker"

shopt -s nullglob

# ------------------------------------------------------------
# 权限检查
# ------------------------------------------------------------

if [[ "${EUID}" -ne 0 ]]; then
    echo "本脚本需要 root 权限运行，正在请求 sudo 权限..."
    exec sudo bash "$0" "$@"
fi

mkdir -p "${JOBS_DIR}" "${MANUAL_DIR}" "${LOG_DIR}"
touch "${MANUAL_TASKS_FILE}"

chmod 700 "${MANAGER_DIR}" "${JOBS_DIR}" "${MANUAL_DIR}" "${LOG_DIR}" 2>/dev/null || true
chmod 600 "${MANUAL_TASKS_FILE}" 2>/dev/null || true

# ------------------------------------------------------------
# 基础函数
# ------------------------------------------------------------

pause() {
    echo
    read -r -p "按 Enter 返回菜单..."
}

print_line() {
    echo "============================================================"
}

need_command() {
    command -v "$1" >/dev/null 2>&1
}

install_package() {
    local package_name="$1"

    if need_command apt-get; then
        apt-get update
        apt-get install -y "${package_name}"
    elif need_command dnf; then
        dnf install -y "${package_name}"
    elif need_command yum; then
        yum install -y "${package_name}"
    elif need_command pacman; then
        pacman -Sy --noconfirm "${package_name}"
    else
        echo "错误: 无法识别系统包管理器，请手动安装: ${package_name}" >&2
        return 1
    fi
}

need_rsync() {
    if need_command rsync; then
        return 0
    fi

    echo "未检测到 rsync，正在自动安装..."
    install_package rsync
}

need_lsof() {
    if need_command lsof; then
        return 0
    fi

    echo "未检测到 lsof，正在自动安装..."
    install_package lsof
}

need_curl() {
    if need_command curl; then
        return 0
    fi

    echo "未检测到 curl，正在自动安装..."
    install_package curl
}

valid_task_name() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]
}

# ------------------------------------------------------------
# 选择菜单
#
# 重要:
#   这些函数会通过 $(...) 获取返回值。
#   菜单说明必须输出到 stderr，否则会被命令替换吞掉。
# ------------------------------------------------------------

choose_directory_mode() {
    local answer

    {
        echo
        echo "同步目录方式:"
        echo
        echo "  1) 仅同步目录内的内容"
        echo "     示例: 源 /data/photos -> 目标 /backup"
        echo "     结果: /backup/ 内直接出现 photos 目录中的文件"
        echo
        echo "  2) 同步整个目录（保留源目录名）"
        echo "     示例: 源 /data/photos -> 目标 /backup"
        echo "     结果: /backup/photos/"
        echo
    } >&2

    read -r -p "请选择 [1/2，默认 1]: " answer
    answer="${answer:-1}"

    if [[ "${answer}" == "2" ]]; then
        printf '%s\n' "1"
    else
        printf '%s\n' "0"
    fi
}

choose_sync_mode() {
    local answer

    {
        echo
        echo "同步模式:"
        echo
        echo "  1) 增量同步"
        echo "     不删除目标目录中的额外文件"
        echo
        echo "  2) 镜像同步"
        echo "     删除目标目录中源目录不存在的文件"
        echo
    } >&2

    read -r -p "请选择 [1/2，默认 1]: " answer
    answer="${answer:-1}"

    if [[ "${answer}" == "2" ]]; then
        printf '%s\n' "1"
    else
        printf '%s\n' "0"
    fi
}

choose_running_policy() {
    local answer

    {
        echo
        echo "如果检测到源目录正在被程序、服务或进程使用:"
        echo
        echo "  1) 安全取消同步（推荐）"
        echo "     检测到占用后直接取消，避免产生不一致备份"
        echo
        echo "  2) 忽略占用并继续同步"
        echo "     适合普通文档、图片等"
        echo "     数据库或运行中的程序不推荐使用"
        echo
        echo "  3) 停止指定 systemd 服务后同步"
        echo "     同步完成后自动恢复原本正在运行的服务"
        echo
    } >&2

    read -r -p "请选择 [1/2/3，默认 1]: " answer
    answer="${answer:-1}"

    case "${answer}" in
        2)
            printf '%s\n' "ignore"
            ;;
        3)
            printf '%s\n' "stop"
            ;;
        *)
            printf '%s\n' "abort"
            ;;
    esac
}

# ------------------------------------------------------------
# 路径校验
# ------------------------------------------------------------

validate_paths() {
    local src="$1"
    local dst="$2"
    local include_dir="${3:-0}"

    if [[ -z "${src}" || -z "${dst}" ]]; then
        echo "错误: 源路径和目标路径不能为空。"
        return 1
    fi

    if [[ ! -d "${src}" ]]; then
        echo "错误: 源目录不存在: ${src}"
        return 1
    fi

    if [[ "${src}" == "/" || "${dst}" == "/" ]]; then
        echo "错误: 禁止直接同步根目录 /。"
        return 1
    fi

    local src_real
    local dst_real
    local actual_target

    if ! src_real="$(realpath -e "${src}")"; then
        echo "错误: 无法解析源目录: ${src}"
        return 1
    fi

    if ! dst_real="$(realpath -m "${dst}")"; then
        echo "错误: 无法解析目标目录: ${dst}"
        return 1
    fi

    if [[ "${include_dir}" == "1" ]]; then
        actual_target="${dst_real}/$(basename "${src_real}")"
    else
        actual_target="${dst_real}"
    fi

    if [[ "${src_real}" == "${actual_target}" ]]; then
        echo "错误: 源目录和实际目标目录不能相同。"
        return 1
    fi

    case "${actual_target}/" in
        "${src_real}/"*)
            echo "错误: 实际目标目录不能位于源目录内部。"
            return 1
            ;;
    esac

    case "${src_real}/" in
        "${actual_target}/"*)
            echo "错误: 源目录不能位于实际目标目录内部。"
            return 1
            ;;
    esac

    return 0
}

show_sync_layout() {
    local src="$1"
    local dst="$2"
    local include_dir="$3"

    local src_real
    local dst_real

    src_real="$(realpath -e "${src}")"
    dst_real="$(realpath -m "${dst}")"

    echo "源目录: ${src_real}"
    echo "目标目录: ${dst_real}"

    if [[ "${include_dir}" == "1" ]]; then
        echo "目录方式: 同步整个目录（保留源目录名）"
        echo "实际结果: ${dst_real}/$(basename "${src_real}")/"
    else
        echo "目录方式: 仅同步目录内的内容"
        echo "实际结果: ${dst_real}/"
    fi
}

# ------------------------------------------------------------
# 配置文件写入
# ------------------------------------------------------------

write_sync_config() {
    local config_file="$1"
    local source_dir="$2"
    local destination_dir="$3"
    local include_dir="$4"
    local sync_delete="$5"
    local running_policy="$6"
    local stop_services="$7"
    local mountpoint="$8"
    local schedule="${9:-}"

    {
        printf 'SOURCE=%q\n' "${source_dir}"
        printf 'DESTINATION=%q\n' "${destination_dir}"
        printf 'SYNC_INCLUDE_DIR=%q\n' "${include_dir}"
        printf 'SYNC_DELETE=%q\n' "${sync_delete}"
        printf 'RUNNING_POLICY=%q\n' "${running_policy}"
        printf 'STOP_SERVICES=%q\n' "${stop_services}"
        printf 'REQUIRE_MOUNTPOINT=%q\n' "${mountpoint}"

        if [[ -n "${schedule}" ]]; then
            printf 'SCHEDULE=%q\n' "${schedule}"
        fi
    } > "${config_file}"

    chmod 600 "${config_file}"
}

# ------------------------------------------------------------
# Worker
# ------------------------------------------------------------

install_worker() {
    cat > "${WORKER}" <<'WORKER_EOF'
#!/usr/bin/env bash

set -Eeuo pipefail

MANAGER_DIR="/etc/sync-manager"
TELEGRAM_CONF="${MANAGER_DIR}/telegram.conf"
LOG_DIR="/var/log/sync-manager"
LOCK_DIR="/run/lock"

TASK_NAME="${1:?缺少任务名称}"
CONFIG="${2:?缺少配置文件}"
RUN_MODE="${3:-auto}"

START_TIME="$(date '+%F %T')"
LOG_FILE="${LOG_DIR}/${TASK_NAME}_$(date '+%Y%m%d_%H%M%S').log"
LOCK_FILE="${LOCK_DIR}/sync-manager-${TASK_NAME}.lock"

STOPPED_SERVICES=()
REPORT_SENT=0

mkdir -p "${LOG_DIR}" "${LOCK_DIR}"
touch "${LOG_FILE}"
chmod 600 "${LOG_FILE}" 2>/dev/null || true

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "${LOG_FILE}"
}

send_telegram() {
    local message="$1"

    [[ -f "${TELEGRAM_CONF}" ]] || return 0

    # shellcheck disable=SC1090
    source "${TELEGRAM_CONF}"

    [[ -n "${TG_BOT_TOKEN:-}" ]] || return 0
    [[ -n "${TG_CHAT_ID:-}" ]] || return 0
    command -v curl >/dev/null 2>&1 || return 0

    curl -sS -X POST \
        "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TG_CHAT_ID}" \
        --data-urlencode "text=${message}" \
        >/dev/null 2>&1 || true
}

send_report() {
    local status="$1"
    local summary="$2"

    [[ "${REPORT_SENT}" -eq 1 ]] && return 0
    REPORT_SENT=1

    local end_time
    local message

    end_time="$(date '+%F %T')"

    # Telegram 单条消息不能无限长，限制摘要长度
    summary="${summary:0:2500}"

    message=$(
        cat <<EOF
本地文件同步报告

任务名称: ${TASK_NAME}
状态: ${status}
开始时间: ${START_TIME}
结束时间: ${end_time}

${summary}
EOF
    )

    send_telegram "${message}"
}

restore_stopped_services() {
    local service

    for service in "${STOPPED_SERVICES[@]}"; do
        log "正在恢复服务: ${service}"

        if systemctl start "${service}"; then
            log "服务已恢复: ${service}"
        else
            log "警告: 服务恢复失败，请手动检查: ${service}"
        fi
    done
}

trap restore_stopped_services EXIT

fail_sync() {
    local reason="$1"

    log "错误: ${reason}"
    send_report "失败" "${reason}"
    exit 1
}

if [[ ! -f "${CONFIG}" ]]; then
    fail_sync "找不到配置文件: ${CONFIG}"
fi

# shellcheck disable=SC1090
if ! source "${CONFIG}"; then
    fail_sync "配置文件读取失败: ${CONFIG}"
fi

exec 9>"${LOCK_FILE}"

if ! flock -n 9; then
    log "已有相同同步任务正在运行，本次跳过。"
    exit 0
fi

if [[ -z "${SOURCE:-}" || -z "${DESTINATION:-}" ]]; then
    fail_sync "SOURCE 或 DESTINATION 未配置。"
fi

if [[ ! -d "${SOURCE}" ]]; then
    fail_sync "源目录不存在: ${SOURCE}"
fi

log "============================================================"
log "同步任务开始"
log "任务名称: ${TASK_NAME}"
log "源目录: ${SOURCE}"
log "目标目录: ${DESTINATION}"

if [[ -n "${REQUIRE_MOUNTPOINT:-}" ]]; then
    if ! mountpoint -q "${REQUIRE_MOUNTPOINT}"; then
        fail_sync "备份挂载点未挂载: ${REQUIRE_MOUNTPOINT}，已停止同步以避免误写系统盘。"
    fi

    log "挂载点检查通过: ${REQUIRE_MOUNTPOINT}"
fi

if ! SRC_REAL="$(realpath -e "${SOURCE}")"; then
    fail_sync "无法解析源目录: ${SOURCE}"
fi

if ! DST_REAL="$(realpath -m "${DESTINATION}")"; then
    fail_sync "无法解析目标目录: ${DESTINATION}"
fi

SYNC_INCLUDE_DIR="${SYNC_INCLUDE_DIR:-0}"
SYNC_DELETE="${SYNC_DELETE:-0}"
RUNNING_POLICY="${RUNNING_POLICY:-abort}"
STOP_SERVICES="${STOP_SERVICES:-}"

if [[ "${SYNC_INCLUDE_DIR}" == "1" ]]; then
    ACTUAL_TARGET="${DST_REAL}/$(basename "${SRC_REAL}")"
    RSYNC_SRC="${SRC_REAL}"
    log "目录方式: 同步整个目录（保留源目录名）"
else
    ACTUAL_TARGET="${DST_REAL}"
    RSYNC_SRC="${SRC_REAL}/"
    log "目录方式: 仅同步目录内的内容"
fi

RSYNC_DST="${DST_REAL}/"

if [[ "${SRC_REAL}" == "${ACTUAL_TARGET}" ]]; then
    fail_sync "源目录和实际目标目录相同。"
fi

case "${ACTUAL_TARGET}/" in
    "${SRC_REAL}/"*)
        fail_sync "实际目标目录位于源目录内部，拒绝执行。"
        ;;
esac

case "${SRC_REAL}/" in
    "${ACTUAL_TARGET}/"*)
        fail_sync "源目录位于实际目标目录内部，拒绝执行。"
        ;;
esac

mkdir -p "${DST_REAL}"

get_source_users() {
    local source_dir="$1"

    if ! command -v lsof >/dev/null 2>&1; then
        fail_sync "未安装 lsof，无法检测源目录是否被使用。"
    fi

    {
        lsof -nP -t +D "${source_dir}" 2>/dev/null || true
    } | sort -u
}

show_source_users() {
    local pids="$1"
    local pid_list

    [[ -z "${pids}" ]] && return 0

    pid_list="$(echo "${pids}" | paste -sd, -)"

    log "以下进程正在使用源目录:"
    ps -o pid,user,stat,etime,cmd -p "${pid_list}" 2>/dev/null \
        | tee -a "${LOG_FILE}" || true
}

handle_running_processes() {
    local pids
    local service

    if [[ "${RUNNING_POLICY}" == "ignore" ]]; then
        log "进程占用策略: ignore，跳过占用检查。"
        return 0
    fi

    pids="$(get_source_users "${SRC_REAL}")"

    if [[ -z "${pids}" ]]; then
        log "未检测到源目录被进程使用。"
        return 0
    fi

    log "警告: 检测到源目录正在被进程使用。"
    show_source_users "${pids}"

    case "${RUNNING_POLICY}" in
        abort)
            fail_sync "源目录被进程占用，按照 abort 策略取消同步。"
            ;;

        stop)
            if [[ -z "${STOP_SERVICES}" ]]; then
                fail_sync "策略为 stop，但没有配置 STOP_SERVICES。"
            fi

            for service in ${STOP_SERVICES}; do
                if systemctl is-active --quiet "${service}"; then
                    log "正在停止服务: ${service}"

                    if systemctl stop "${service}"; then
                        STOPPED_SERVICES+=("${service}")
                    else
                        fail_sync "停止服务失败: ${service}"
                    fi
                else
                    log "服务当前未运行，跳过: ${service}"
                fi
            done

            sleep 1

            pids="$(get_source_users "${SRC_REAL}")"

            if [[ -n "${pids}" ]]; then
                show_source_users "${pids}"
                fail_sync "停止指定服务后，源目录仍被其他进程使用。"
            fi

            log "指定服务已停止，源目录已无进程占用。"
            ;;

        *)
            fail_sync "未知 RUNNING_POLICY: ${RUNNING_POLICY}"
            ;;
    esac
}

handle_running_processes

OPTS=(
    -aHAX
    --numeric-ids
    --human-readable
    --partial
    --partial-dir=.rsync-partial
)

if [[ "${RUN_MODE}" == "manual" ]]; then
    OPTS+=(--info=progress2)
else
    OPTS+=(--info=stats2)
fi

if [[ "${SYNC_DELETE}" == "1" ]]; then
    OPTS+=(--delete-delay)
    log "同步模式: 镜像同步，将删除目标中源目录不存在的文件。"
else
    log "同步模式: 增量同步，不删除目标目录中的额外文件。"
fi

log "开始执行 rsync..."
log "源: ${RSYNC_SRC}"
log "目标: ${RSYNC_DST}"

set +e
rsync "${OPTS[@]}" -- "${RSYNC_SRC}" "${RSYNC_DST}" 2>&1 \
    | tee -a "${LOG_FILE}"
RSYNC_EXIT="${PIPESTATUS[0]}"
set -e

if [[ "${RSYNC_EXIT}" -eq 0 ]]; then
    log "同步成功。"
    SUMMARY="$(tail -n 25 "${LOG_FILE}" 2>/dev/null || true)"
    send_report "成功" "${SUMMARY}"
else
    log "同步失败，rsync 退出代码: ${RSYNC_EXIT}"
    SUMMARY="$(tail -n 25 "${LOG_FILE}" 2>/dev/null || true)"
    send_report "失败，rsync 退出代码: ${RSYNC_EXIT}" "${SUMMARY}"
fi

log "同步任务结束。"
log "日志文件: ${LOG_FILE}"
log "============================================================"

exit "${RSYNC_EXIT}"
WORKER_EOF

    chmod 755 "${WORKER}"
}

# ------------------------------------------------------------
# 执行同步任务
# ------------------------------------------------------------

run_sync_task() {
    local task_name="$1"
    local config_file="$2"
    local run_mode="${3:-manual}"
    local exit_code

    install_worker

    echo
    echo "开始同步任务: ${task_name}"
    echo "开始时间: $(date '+%F %T')"
    echo

    set +e
    "${WORKER}" "${task_name}" "${config_file}" "${run_mode}"
    exit_code=$?
    set -e

    echo

    if [[ "${exit_code}" -eq 0 ]]; then
        echo "同步完成。"
    else
        echo "同步失败，退出代码: ${exit_code}"
    fi

    echo "日志目录: ${LOG_DIR}"
    return "${exit_code}"
}

# ------------------------------------------------------------
# 临时手动同步
# ------------------------------------------------------------

temporary_manual_sync() {
    clear
    print_line
    echo "                  临时手动同步"
    print_line
    echo

    need_rsync || {
        pause
        return
    }

    local src
    local dst
    local include_dir
    local delete_mode
    local policy
    local stop_services=""
    local mountpoint=""
    local config_file
    local answer

    read -r -e -p "请输入源目录: " src
    read -r -e -p "请输入目标目录: " dst

    include_dir="$(choose_directory_mode)"

    if ! validate_paths "${src}" "${dst}" "${include_dir}"; then
        pause
        return
    fi

    delete_mode="$(choose_sync_mode)"
    policy="$(choose_running_policy)"

    if [[ "${policy}" != "ignore" ]]; then
        need_lsof || {
            pause
            return
        }
    fi

    if [[ "${policy}" == "stop" ]]; then
        echo
        echo "请输入需要停止的 systemd 服务，多个服务用空格分隔。"
        read -r -p "服务名称: " stop_services

        if [[ -z "${stop_services}" ]]; then
            echo "错误: 未填写服务名称。"
            pause
            return
        fi
    fi

    src="$(realpath -e "${src}")"
    dst="$(realpath -m "${dst}")"

    config_file="$(mktemp "${MANAGER_DIR}/temporary.XXXXXX.conf")"

    write_sync_config \
        "${config_file}" \
        "${src}" \
        "${dst}" \
        "${include_dir}" \
        "${delete_mode}" \
        "${policy}" \
        "${stop_services}" \
        "${mountpoint}"

    echo
    print_line
    show_sync_layout "${src}" "${dst}" "${include_dir}"

    if [[ "${delete_mode}" == "1" ]]; then
        echo "同步模式: 镜像同步"
    else
        echo "同步模式: 增量同步"
    fi

    echo "进程占用策略: ${policy}"
    print_line

    read -r -p "确认开始同步? [Y/n]: " answer
    answer="${answer:-Y}"

    if [[ ! "${answer}" =~ ^[Yy]$ ]]; then
        rm -f "${config_file}"
        echo "已取消。"
        pause
        return
    fi

    set +e
    run_sync_task "temporary_manual" "${config_file}" "manual"
    set -e

    rm -f "${config_file}"
    pause
}

# ------------------------------------------------------------
# 固定手动同步任务
# ------------------------------------------------------------

list_manual_tasks() {
    local configs=()
    local config
    local index=1

    configs=("${MANUAL_DIR}"/*.conf)

    if [[ "${#configs[@]}" -eq 0 ]]; then
        echo "当前没有固定手动同步任务。"
        return 1
    fi

    echo "固定手动同步任务:"
    echo

    for config in "${configs[@]}"; do
        (
            # shellcheck disable=SC1090
            source "${config}"

            printf '%2d) %-20s %s -> %s\n' \
                "${index}" \
                "$(basename "${config}" .conf)" \
                "${SOURCE:-未知}" \
                "${DESTINATION:-未知}"
        )

        ((index++))
    done

    return 0
}

add_manual_task() {
    clear
    print_line
    echo "                添加固定手动任务"
    print_line
    echo

    need_rsync || {
        pause
        return
    }

    local task_name
    local src
    local dst
    local include_dir
    local delete_mode
    local policy
    local stop_services=""
    local mountpoint=""
    local config_file

    read -r -p "任务名称（英文、数字、下划线或短横线）: " task_name

    if ! valid_task_name "${task_name}"; then
        echo "错误: 任务名称格式不正确。"
        pause
        return
    fi

    config_file="${MANUAL_DIR}/${task_name}.conf"

    if [[ -f "${config_file}" ]]; then
        echo "错误: 该固定任务已经存在。"
        pause
        return
    fi

    read -r -e -p "源目录: " src
    read -r -e -p "目标目录: " dst

    include_dir="$(choose_directory_mode)"

    if ! validate_paths "${src}" "${dst}" "${include_dir}"; then
        pause
        return
    fi

    delete_mode="$(choose_sync_mode)"
    policy="$(choose_running_policy)"

    if [[ "${policy}" != "ignore" ]]; then
        need_lsof || {
            pause
            return
        }
    fi

    if [[ "${policy}" == "stop" ]]; then
        read -r -p "需要停止的 systemd 服务（空格分隔）: " stop_services

        if [[ -z "${stop_services}" ]]; then
            echo "错误: 未填写服务名称。"
            pause
            return
        fi
    fi

    src="$(realpath -e "${src}")"
    dst="$(realpath -m "${dst}")"

    write_sync_config \
        "${config_file}" \
        "${src}" \
        "${dst}" \
        "${include_dir}" \
        "${delete_mode}" \
        "${policy}" \
        "${stop_services}" \
        "${mountpoint}"

    echo "固定手动同步任务已保存: ${task_name}"
    pause
}

run_fixed_manual_task() {
    clear
    print_line
    echo "                执行固定手动同步"
    print_line
    echo

    local configs=()
    local config
    local index=1
    local choice
    local selected_config
    local task_name

    configs=("${MANUAL_DIR}"/*.conf)

    if [[ "${#configs[@]}" -eq 0 ]]; then
        echo "当前没有固定手动同步任务，请先创建。"
        pause
        return
    fi

    for config in "${configs[@]}"; do
        (
            # shellcheck disable=SC1090
            source "${config}"

            printf '%2d) %-20s %s -> %s\n' \
                "${index}" \
                "$(basename "${config}" .conf)" \
                "${SOURCE:-未知}" \
                "${DESTINATION:-未知}"
        )

        ((index++))
    done

    echo
    echo " 0) 返回"

    read -r -p "请选择要执行的任务: " choice

    if [[ "${choice}" == "0" ]]; then
        return
    fi

    if ! [[ "${choice}" =~ ^[0-9]+$ ]]; then
        echo "无效选择。"
        pause
        return
    fi

    if (( choice < 1 || choice > ${#configs[@]} )); then
        echo "无效选择。"
        pause
        return
    fi

    selected_config="${configs[$((choice - 1))]}"
    task_name="$(basename "${selected_config}" .conf)"

    set +e
    run_sync_task "fixed_${task_name}" "${selected_config}" "manual"
    set -e

    pause
}

delete_manual_task() {
    clear
    print_line
    echo "                删除固定手动任务"
    print_line
    echo

    local configs=()
    local config
    local names=()
    local index=1
    local choice
    local selected_name
    local answer

    configs=("${MANUAL_DIR}"/*.conf)

    if [[ "${#configs[@]}" -eq 0 ]]; then
        echo "当前没有固定手动同步任务。"
        pause
        return
    fi

    for config in "${configs[@]}"; do
        selected_name="$(basename "${config}" .conf)"
        names+=("${selected_name}")
        printf '%2d) %s\n' "${index}" "${selected_name}"
        ((index++))
    done

    echo
    echo " 0) 返回"

    read -r -p "请选择要删除的任务: " choice

    if [[ "${choice}" == "0" ]]; then
        return
    fi

    if ! [[ "${choice}" =~ ^[0-9]+$ ]] ||
        (( choice < 1 || choice > ${#configs[@]} )); then
        echo "无效选择。"
        pause
        return
    fi

    selected_name="${names[$((choice - 1))]}"

    read -r -p "确认删除任务 ${selected_name}? [y/N]: " answer

    if [[ ! "${answer}" =~ ^[Yy]$ ]]; then
        echo "已取消。"
        pause
        return
    fi

    rm -f "${MANUAL_DIR}/${selected_name}.conf"
    echo "任务已删除: ${selected_name}"
    pause
}

manual_sync_menu() {
    while true; do
        clear
        print_line
        echo "                  手动同步管理"
        echo "                    ${VERSION}"
        print_line
        echo "1. 临时手动同步"
        echo "2. 执行固定手动同步"
        echo "3. 添加固定手动同步任务"
        echo "4. 删除固定手动同步任务"
        echo "0. 返回主菜单"
        echo

        read -r -p "请选择: " choice

        case "${choice}" in
            1)
                temporary_manual_sync
                ;;
            2)
                run_fixed_manual_task
                ;;
            3)
                add_manual_task
                ;;
            4)
                delete_manual_task
                ;;
            0)
                return
                ;;
            *)
                echo "无效选择。"
                sleep 1
                ;;
        esac
    done
}

# ------------------------------------------------------------
# 自动同步计划
# ------------------------------------------------------------

install_auto_units() {
    local job_name="$1"
    local schedule="$2"

    local config_file="${JOBS_DIR}/${job_name}.conf"
    local service_file="/etc/systemd/system/${BASE_SERVICE_NAME}@${job_name}.service"
    local timer_file="/etc/systemd/system/${BASE_SERVICE_NAME}@${job_name}.timer"

    cat > "${service_file}" <<EOF
[Unit]
Description=Local rsync synchronization job: ${job_name}
After=local-fs.target network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${WORKER} ${job_name} ${config_file} auto
TimeoutStartSec=infinity
StandardOutput=journal
StandardError=journal
EOF

    cat > "${timer_file}" <<EOF
[Unit]
Description=Local rsync synchronization timer: ${job_name}

[Timer]
OnCalendar=${schedule}
Persistent=true
RandomizedDelaySec=2m
Unit=${BASE_SERVICE_NAME}@${job_name}.service

[Install]
WantedBy=timers.target
EOF
}

get_job_names() {
    local config
    local name

    for config in "${JOBS_DIR}"/*.conf; do
        name="$(basename "${config}" .conf)"
        printf '%s\n' "${name}"
    done
}

list_auto_jobs() {
    clear
    print_line
    echo "                  当前自动同步计划"
    print_line
    echo

    local configs=()
    local config
    local job_name
    local schedule
    local enabled
    local active

    configs=("${JOBS_DIR}"/*.conf)

    if [[ "${#configs[@]}" -eq 0 ]]; then
        echo "当前没有自动同步计划。"
        pause
        return
    fi

    for config in "${configs[@]}"; do
        job_name="$(basename "${config}" .conf)"
        schedule="$(
            awk -F= '/^SCHEDULE=/{sub(/^SCHEDULE=/, ""); print; exit}' \
                "${config}" 2>/dev/null || true
        )"

        (
            # shellcheck disable=SC1090
            source "${config}"

            echo "任务名称: ${job_name}"
            echo "源目录: ${SOURCE:-未知}"
            echo "目标目录: ${DESTINATION:-未知}"
            echo "定时规则: ${SCHEDULE:-${schedule:-未知}}"

            if [[ "${SYNC_DELETE:-0}" == "1" ]]; then
                echo "同步模式: 镜像同步"
            else
                echo "同步模式: 增量同步"
            fi

            echo "进程占用策略: ${RUNNING_POLICY:-abort}"

            if systemctl is-enabled --quiet \
                "${BASE_SERVICE_NAME}@${job_name}.timer" 2>/dev/null; then
                enabled="已启用"
            else
                enabled="未启用"
            fi

            if systemctl is-active --quiet \
                "${BASE_SERVICE_NAME}@${job_name}.timer" 2>/dev/null; then
                active="运行中"
            else
                active="未运行"
            fi

            echo "定时器状态: ${enabled}，${active}"
            echo "------------------------------------------------------------"
        )
    done

    echo
    echo "systemd 执行时间表:"
    systemctl list-timers --all --no-pager 2>/dev/null \
        | grep "${BASE_SERVICE_NAME}@" || echo "暂无已加载的同步定时器。"

    pause
}

create_auto_job() {
    clear
    print_line
    echo "                  创建新定时计划"
    print_line
    echo

    need_rsync || {
        pause
        return
    }

    local job_name
    local src
    local dst
    local include_dir
    local delete_mode
    local policy
    local stop_services=""
    local schedule
    local mountpoint=""
    local answer
    local config_file

    read -r -p "计划任务名称（英文/数字/下划线/短横线，如 sync_web）: " job_name

    if ! valid_task_name "${job_name}"; then
        echo "错误: 任务名称只能包含英文、数字、下划线和短横线。"
        pause
        return
    fi

    config_file="${JOBS_DIR}/${job_name}.conf"

    if [[ -f "${config_file}" ]]; then
        echo "错误: 该计划名称已经存在。"
        pause
        return
    fi

    read -r -e -p "源目录: " src
    read -r -e -p "目标目录: " dst

    # 这里会正常显示 1 和 2 的具体含义
    include_dir="$(choose_directory_mode)"

    if ! validate_paths "${src}" "${dst}" "${include_dir}"; then
        pause
        return
    fi

    # 这里也会正常显示增量同步和镜像同步的具体含义
    delete_mode="$(choose_sync_mode)"

    policy="$(choose_running_policy)"

    if [[ "${policy}" != "ignore" ]]; then
        need_lsof || {
            pause
            return
        }
    fi

    if [[ "${policy}" == "stop" ]]; then
        echo
        echo "请输入同步前需要停止的 systemd 服务。"
        echo "多个服务用空格分隔，例如:"
        echo "myapp.service nginx.service"
        read -r -p "服务名称: " stop_services

        if [[ -z "${stop_services}" ]]; then
            echo "错误: 未填写服务名称。"
            pause
            return
        fi
    fi

    echo
    echo "定时规则示例:"
    echo
    echo "  每天凌晨 02:00       *-*-* 02:00:00"
    echo "  每天凌晨 03:30       *-*-* 03:30:00"
    echo "  每周日凌晨 03:00     Sun *-*-* 03:00:00"
    echo "  工作日晚上 23:30     Mon..Fri *-*-* 23:30:00"
    echo

    read -r -p "请输入 systemd OnCalendar 规则 [默认每天 02:00]: " schedule
    schedule="${schedule:-*-*-* 02:00:00}"

    if [[ "${schedule}" == *$'\n'* || "${schedule}" == *$'\r'* ]]; then
        echo "错误: 定时规则不能包含换行。"
        pause
        return
    fi

    if ! systemd-analyze calendar "${schedule}" >/dev/null 2>&1; then
        echo "错误: 无效的 systemd OnCalendar 规则: ${schedule}"
        pause
        return
    fi

    echo
    echo "如果目标目录位于移动硬盘、NAS 或其他挂载盘中，建议填写挂载点。"
    echo "例如目标目录为 /mnt/backup/data，则填写 /mnt/backup。"
    echo "不需要检查时直接按 Enter。"
    echo

    read -r -e -p "备份盘挂载点 [可留空]: " mountpoint

    if [[ -n "${mountpoint}" ]]; then
        if [[ ! -d "${mountpoint}" ]]; then
            echo "错误: 挂载点目录不存在: ${mountpoint}"
            pause
            return
        fi

        mountpoint="$(realpath -e "${mountpoint}")"
    fi

    src="$(realpath -e "${src}")"
    dst="$(realpath -m "${dst}")"

    echo
    print_line
    echo "配置确认:"
    print_line
    echo "计划名称: ${job_name}"
    show_sync_layout "${src}" "${dst}" "${include_dir}"
    echo "定时规则: ${schedule}"

    if [[ "${delete_mode}" == "1" ]]; then
        echo "同步模式: 镜像同步（会删除目标多余文件）"
    else
        echo "同步模式: 增量同步（不会删除目标额外文件）"
    fi

    echo "进程占用策略: ${policy}"

    if [[ "${policy}" == "stop" ]]; then
        echo "需要停止的服务: ${stop_services}"
    fi

    echo "挂载点检查: ${mountpoint:-未启用}"
    print_line
    echo

    read -r -p "确认创建并启用此自动同步计划? [Y/n]: " answer
    answer="${answer:-Y}"

    if [[ ! "${answer}" =~ ^[Yy]$ ]]; then
        echo "已取消。"
        pause
        return
    fi

    write_sync_config \
        "${config_file}" \
        "${src}" \
        "${dst}" \
        "${include_dir}" \
        "${delete_mode}" \
        "${policy}" \
        "${stop_services}" \
        "${mountpoint}" \
        "${schedule}"

    install_worker
    install_auto_units "${job_name}" "${schedule}"

    systemctl daemon-reload

    if systemctl enable --now \
        "${BASE_SERVICE_NAME}@${job_name}.timer"; then
        echo
        echo "自动同步计划创建并启用成功: ${job_name}"
    else
        echo "错误: 定时器启用失败。"
        echo "配置文件仍保留: ${config_file}"
    fi

    pause
}

run_auto_job_now() {
    clear
    print_line
    echo "                  立即执行自动同步"
    print_line
    echo

    local configs=()
    local config
    local names=()
    local index=1
    local choice
    local selected_name
    local selected_config

    configs=("${JOBS_DIR}"/*.conf)

    if [[ "${#configs[@]}" -eq 0 ]]; then
        echo "当前没有自动同步计划。"
        pause
        return
    fi

    for config in "${configs[@]}"; do
        selected_name="$(basename "${config}" .conf)"
        names+=("${selected_name}")
        printf '%2d) %s\n' "${index}" "${selected_name}"
        ((index++))
    done

    echo
    echo " 0) 返回"

    read -r -p "请选择要立即执行的计划: " choice

    if [[ "${choice}" == "0" ]]; then
        return
    fi

    if ! [[ "${choice}" =~ ^[0-9]+$ ]] ||
        (( choice < 1 || choice > ${#configs[@]} )); then
        echo "无效选择。"
        pause
        return
    fi

    selected_config="${configs[$((choice - 1))]}"
    selected_name="${names[$((choice - 1))]}"

    set +e
    systemctl start "${BASE_SERVICE_NAME}@${selected_name}.service"
    local exit_code=$?
    set -e

    if [[ "${exit_code}" -eq 0 ]]; then
        echo "自动同步执行完成。"
    else
        echo "自动同步执行失败，请查看日志。"
    fi

    pause
}

disable_auto_job() {
    clear
    print_line
    echo "                  启用或停用自动计划"
    print_line
    echo

    local names=()
    local name
    local index=1
    local choice
    local action

    while IFS= read -r name; do
        [[ -n "${name}" ]] || continue
        names+=("${name}")
        printf '%2d) %s\n' "${index}" "${name}"
        ((index++))
    done < <(get_job_names)

    if [[ "${#names[@]}" -eq 0 ]]; then
        echo "当前没有自动同步计划。"
        pause
        return
    fi

    echo
    echo " 0) 返回"

    read -r -p "请选择计划: " choice

    if [[ "${choice}" == "0" ]]; then
        return
    fi

    if ! [[ "${choice}" =~ ^[0-9]+$ ]] ||
        (( choice < 1 || choice > ${#names[@]} )); then
        echo "无效选择。"
        pause
        return
    fi

    name="${names[$((choice - 1))]}"

    echo
    echo "1) 启用计划"
    echo "2) 停用计划"
    read -r -p "请选择 [1/2]: " action

    case "${action}" in
        1)
            systemctl enable --now \
                "${BASE_SERVICE_NAME}@${name}.timer"
            echo "计划已启用: ${name}"
            ;;
        2)
            systemctl disable --now \
                "${BASE_SERVICE_NAME}@${name}.timer"
            echo "计划已停用: ${name}"
            ;;
        *)
            echo "无效选择。"
            ;;
    esac

    pause
}

delete_auto_job() {
    clear
    print_line
    echo "                  删除自动同步计划"
    print_line
    echo

    local configs=()
    local config
    local names=()
    local index=1
    local choice
    local selected_name
    local answer

    configs=("${JOBS_DIR}"/*.conf)

    if [[ "${#configs[@]}" -eq 0 ]]; then
        echo "当前没有自动同步计划。"
        pause
        return
    fi

    for config in "${configs[@]}"; do
        selected_name="$(basename "${config}" .conf)"
        names+=("${selected_name}")
        printf '%2d) %s\n' "${index}" "${selected_name}"
        ((index++))
    done

    echo
    echo " 0) 返回"

    read -r -p "请选择要删除的计划: " choice

    if [[ "${choice}" == "0" ]]; then
        return
    fi

    if ! [[ "${choice}" =~ ^[0-9]+$ ]] ||
        (( choice < 1 || choice > ${#configs[@]} )); then
        echo "无效选择。"
        pause
        return
    fi

    selected_name="${names[$((choice - 1))]}"

    echo
    echo "警告: 删除后将停用该计划并删除其配置。"
    read -r -p "确认删除 ${selected_name}? [y/N]: " answer

    if [[ ! "${answer}" =~ ^[Yy]$ ]]; then
        echo "已取消。"
        pause
        return
    fi

    systemctl disable --now \
        "${BASE_SERVICE_NAME}@${selected_name}.timer" \
        2>/dev/null || true

    rm -f \
        "/etc/systemd/system/${BASE_SERVICE_NAME}@${selected_name}.timer" \
        "/etc/systemd/system/${BASE_SERVICE_NAME}@${selected_name}.service" \
        "${JOBS_DIR}/${selected_name}.conf"

    systemctl daemon-reload

    echo "自动同步计划已删除: ${selected_name}"
    pause
}

view_job_logs() {
    clear
    print_line
    echo "                  查看同步日志"
    print_line
    echo

    local logs=()
    local log
    local index=1
    local choice

    logs=("${LOG_DIR}"/*.log)

    if [[ "${#logs[@]}" -eq 0 ]]; then
        echo "当前没有同步日志。"
        pause
        return
    fi

    for log in "${logs[@]}"; do
        printf '%2d) %s\n' "${index}" "$(basename "${log}")"
        ((index++))
    done

    echo
    echo " 0) 返回"

    read -r -p "请选择要查看的日志: " choice

    if [[ "${choice}" == "0" ]]; then
        return
    fi

    if ! [[ "${choice}" =~ ^[0-9]+$ ]] ||
        (( choice < 1 || choice > ${#logs[@]} )); then
        echo "无效选择。"
        pause
        return
    fi

    if need_command less; then
        less "${logs[$((choice - 1))]}"
    else
        cat "${logs[$((choice - 1))]}"
        pause
    fi
}

auto_sync_menu() {
    while true; do
        clear
        print_line
        echo "                  自动同步管理"
        echo "                    ${VERSION}"
        print_line
        echo "1. 查看所有定时同步计划"
        echo "2. 创建新的定时同步计划"
        echo "3. 立即执行一次同步"
        echo "4. 启用或停用同步计划"
        echo "5. 删除同步计划"
        echo "6. 查看同步日志"
        echo "0. 返回主菜单"
        echo

        read -r -p "请选择: " choice

        case "${choice}" in
            1)
                list_auto_jobs
                ;;
            2)
                create_auto_job
                ;;
            3)
                run_auto_job_now
                ;;
            4)
                disable_auto_job
                ;;
            5)
                delete_auto_job
                ;;
            6)
                view_job_logs
                ;;
            0)
                return
                ;;
            *)
                echo "无效选择。"
                sleep 1
                ;;
        esac
    done
}

# ------------------------------------------------------------
# Telegram 配置
# ------------------------------------------------------------

configure_telegram() {
    clear
    print_line
    echo "                  Telegram 通知配置"
    print_line
    echo

    need_curl || {
        pause
        return
    }

    local token
    local chat_id
    local response

    read -r -p "请输入 Telegram Bot Token: " token
    read -r -p "请输入 Telegram Chat ID: " chat_id

    if [[ -z "${token}" || -z "${chat_id}" ]]; then
        echo "错误: Bot Token 和 Chat ID 都不能为空。"
        pause
        return
    fi

    echo
    echo "正在发送 Telegram 测试消息，请稍候..."

    set +e
    response="$(
        curl -sS --connect-timeout 10 --max-time 30 \
            -X POST \
            "https://api.telegram.org/bot${token}/sendMessage" \
            --data-urlencode "chat_id=${chat_id}" \
            --data-urlencode "text=本地文件同步管理器 Telegram 测试消息：配置成功。" \
            2>/dev/null
    )"
    local curl_exit=$?
    set -e

    if [[ "${curl_exit}" -ne 0 ]]; then
        echo "Telegram 测试失败: 无法连接 Telegram API。"
        pause
        return
    fi

    if grep -Eq '"ok"[[:space:]]*:[[:space:]]*true' <<< "${response}"; then
        {
            printf 'TG_BOT_TOKEN=%q\n' "${token}"
            printf 'TG_CHAT_ID=%q\n' "${chat_id}"
        } > "${TELEGRAM_CONF}"

        chmod 600 "${TELEGRAM_CONF}"

        echo "Telegram 测试成功，配置已保存。"
    else
        echo "Telegram 测试失败，配置不会保存。"
        echo
        echo "Telegram 返回内容:"
        echo "${response}"
    fi

    pause
}

# ------------------------------------------------------------
# 旧版迁移
# ------------------------------------------------------------

legacy_timer_schedule() {
    if [[ ! -f "${LEGACY_TIMER_FILE}" ]]; then
        return 1
    fi

    awk -F= '
        /^OnCalendar=/ {
            sub(/^OnCalendar=/, "", $0)
            print
            exit
        }
    ' "${LEGACY_TIMER_FILE}"
}

wait_legacy_service_finish() {
    local count=0

    while systemctl is-active --quiet "${BASE_SERVICE_NAME}.service" 2>/dev/null; do
        echo "旧版同步服务仍在运行，等待本次同步完成..."
        sleep 2
        ((count++))

        if (( count >= 150 )); then
            echo "警告: 等待旧版同步服务超过 5 分钟。"
            return 1
        fi
    done

    return 0
}

migrate_legacy_plan() {
    clear
    print_line
    echo "                  迁移旧版同步计划"
    print_line
    echo

    if [[ ! -f "${LEGACY_CONFIG}" ]]; then
        echo "未检测到旧版配置: ${LEGACY_CONFIG}"
        pause
        return
    fi

    local backup_dir
    local timestamp
    local old_schedule
    local new_name
    local config_file
    local src
    local dst
    local include_dir
    local delete_mode
    local policy
    local stop_services
    local mountpoint
    local answer

    timestamp="$(date '+%Y%m%d_%H%M%S')"
    backup_dir="${MANAGER_DIR}/legacy-backup-${timestamp}"
    mkdir -p "${backup_dir}"

    echo "检测到旧版同步计划:"
    echo "配置文件: ${LEGACY_CONFIG}"

    if [[ -f "${LEGACY_TIMER_FILE}" ]]; then
        old_schedule="$(legacy_timer_schedule || true)"
    else
        old_schedule=""
    fi

    if [[ -z "${old_schedule}" ]]; then
        old_schedule="*-*-* 02:00:00"
        echo "旧版定时规则未找到，将使用默认规则: ${old_schedule}"
    else
        echo "旧版定时规则: ${old_schedule}"
    fi

    # shellcheck disable=SC1090
    if ! source "${LEGACY_CONFIG}"; then
        echo "错误: 无法读取旧版配置。"
        pause
        return
    fi

    src="${SOURCE:-}"
    dst="${DESTINATION:-}"
    include_dir="${SYNC_INCLUDE_DIR:-0}"
    delete_mode="${SYNC_DELETE:-0}"
    policy="${RUNNING_POLICY:-abort}"
    stop_services="${STOP_SERVICES:-}"
    mountpoint="${REQUIRE_MOUNTPOINT:-}"

    if [[ -z "${src}" || -z "${dst}" ]]; then
        echo "错误: 旧版配置缺少 SOURCE 或 DESTINATION。"
        pause
        return
    fi

    if ! validate_paths "${src}" "${dst}" "${include_dir}"; then
        echo "错误: 旧版路径校验失败，未执行迁移。"
        pause
        return
    fi

    new_name="legacy_sync"

    if [[ -f "${JOBS_DIR}/${new_name}.conf" ]]; then
        new_name="legacy_sync_${timestamp}"
    fi

    echo
    echo "旧版计划将迁移为新计划: ${new_name}"
    echo "旧版原始文件会备份到: ${backup_dir}"
    echo "旧版定时器会停用，迁移后的新计划会继续运行。"
    echo
    echo "这不会删除旧版文件。"
    read -r -p "确认开始迁移? [Y/n]: " answer
    answer="${answer:-Y}"

    if [[ ! "${answer}" =~ ^[Yy]$ ]]; then
        echo "已取消迁移。"
        pause
        return
    fi

    # 先备份旧版文件
    cp -a "${LEGACY_CONFIG}" "${backup_dir}/" 2>/dev/null || true
    cp -a "${LEGACY_SERVICE_FILE}" "${backup_dir}/" 2>/dev/null || true
    cp -a "${LEGACY_TIMER_FILE}" "${backup_dir}/" 2>/dev/null || true
    cp -a "${LEGACY_WORKER}" "${backup_dir}/" 2>/dev/null || true

    # 停止旧版定时器，但不强制杀死正在运行的同步服务
    systemctl disable --now "${BASE_SERVICE_NAME}.timer" 2>/dev/null || true

    if ! wait_legacy_service_finish; then
        echo "旧版同步服务仍未结束，为避免两个计划同时运行，本次迁移停止。"
        echo "旧版定时器保持停用状态，请检查:"
        echo "  systemctl status ${BASE_SERVICE_NAME}.service"
        pause
        return
    fi

    src="$(realpath -e "${src}")"
    dst="$(realpath -m "${dst}")"

    config_file="${JOBS_DIR}/${new_name}.conf"

    write_sync_config \
        "${config_file}" \
        "${src}" \
        "${dst}" \
        "${include_dir}" \
        "${delete_mode}" \
        "${policy}" \
        "${stop_services}" \
        "${mountpoint}" \
        "${old_schedule}"

    install_worker
    install_auto_units "${new_name}" "${old_schedule}"

    systemctl daemon-reload

    if ! systemctl enable --now \
        "${BASE_SERVICE_NAME}@${new_name}.timer"; then
        echo "错误: 新版计划启用失败。"
        echo "旧版文件备份位置: ${backup_dir}"
        echo "新版配置文件: ${config_file}"
        pause
        return
    fi

    # 保留旧配置的迁移副本，避免重复迁移
    mv "${LEGACY_CONFIG}" \
        "${backup_dir}/local-rsync-sync.conf.migrated"

    echo
    echo "旧版同步计划迁移成功。"
    echo "新版计划名称: ${new_name}"
    echo "新版定时规则: ${old_schedule}"
    echo "备份目录: ${backup_dir}"
    echo
    echo "旧版同步计划已由新版计划继续运行。"
    pause
}

# ------------------------------------------------------------
# 兼容此前 v2.0 的固定任务文件
# ------------------------------------------------------------

import_old_manual_tasks() {
    local config_count
    local line
    local old_name
    local old_src
    local old_dst
    local old_inc
    local old_del
    local target_file

    config_count=("${MANUAL_DIR}"/*.conf)

    if [[ "${#config_count[@]}" -gt 0 ]]; then
        return 0
    fi

    [[ -s "${MANUAL_TASKS_FILE}" ]] || return 0

    while IFS='|' read -r old_name old_src old_dst old_inc old_del; do
        [[ -n "${old_name}" ]] || continue
        [[ -n "${old_src}" ]] || continue
        [[ -n "${old_dst}" ]] || continue

        if ! valid_task_name "${old_name}"; then
            continue
        fi

        target_file="${MANUAL_DIR}/${old_name}.conf"

        [[ -f "${target_file}" ]] && continue

        write_sync_config \
            "${target_file}" \
            "${old_src}" \
            "${old_dst}" \
            "${old_inc:-0}" \
            "${old_del:-0}" \
            "ignore" \
            "" \
            ""
    done < "${MANUAL_TASKS_FILE}"
}

# ------------------------------------------------------------
# 主菜单
# ------------------------------------------------------------

main_menu() {
    while true; do
        clear
        print_line
        echo "              本地文件同步管理器"
        echo "                    ${VERSION}"
        print_line
        echo "1. 手动同步管理"
        echo "2. 自动同步管理"
        echo "3. 配置 Telegram 通知"
        echo "4. 迁移旧版同步计划"
        echo "0. 退出"
        echo

        read -r -p "请选择: " choice

        case "${choice}" in
            1)
                manual_sync_menu
                ;;
            2)
                auto_sync_menu
                ;;
            3)
                configure_telegram
                ;;
            4)
                migrate_legacy_plan
                ;;
            0)
                echo "已退出。"
                exit 0
                ;;
            *)
                echo "无效选择，请重新输入。"
                sleep 1
                ;;
        esac
    done
}

# ------------------------------------------------------------
# 启动
# ------------------------------------------------------------

import_old_manual_tasks
main_menu
