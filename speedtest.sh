#!/bin/bash

# -------------------------------
# VPS 自动测速 + Telegram 推送脚本（区域简写 → 固定服务器 ID）
# -------------------------------

# 判断是否为 root
if [ "$(id -u)" -ne 0 ]; then
    SUDO="sudo"
else
    SUDO=""
fi

# === 设置区 ===
LOG_FILE="/var/log/auto_speedtest.log"
SERVER_ID=""              # 将由区域映射自动赋值
REGION_CODE=""            # 用户通过参数 -r 指定的区域简写
LOOP_MODE="no"            # yes/no 是否循环测速
INTERVAL=3600             # 循环间隔（秒）

# === Telegram 设置 ===
TG_BOT_TOKEN=""
TG_CHAT_ID=""

# === 检查命令是否存在 ===
check_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# === 安装 Speedtest CLI（多系统支持） ===
install_speedtest_cli() {
    if [ -f /etc/debian_version ]; then
        echo "✅ Debian 系统：安装 Speedtest CLI"
        curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | $SUDO bash
        $SUDO apt install -y speedtest
    elif [ -f /etc/redhat-release ]; then
        echo "✅ RedHat 系统：安装 Speedtest CLI"
        curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.rpm.sh | $SUDO bash
        $SUDO yum install -y speedtest
    elif [ -f /etc/arch-release ]; then
        echo "✅ Arch 系统：使用 AUR 安装 Speedtest CLI"
        if ! check_cmd yay; then
            echo "❌ 请先安装 yay（AUR 助手）"
            exit 1
        fi
        yay -S --noconfirm speedtest-cli
    else
        echo "❌ 当前系统不支持自动安装 Speedtest CLI"
        exit 1
    fi
}

# === 检查并安装依赖 ===
check_dependencies() {
    check_cmd jq || $SUDO apt install -y jq || $SUDO yum install -y jq || $SUDO pacman -Sy jq
    check_cmd speedtest || install_speedtest_cli
}

# === 获取 VPS 信息 ===
get_ipinfo() {
    INFO=$(curl -s ipinfo.io)
    PUBLIC_IP=$(echo "$INFO" | jq -r '.ip')
    CITY=$(echo "$INFO" | jq -r '.city')
    REGION=$(echo "$INFO" | jq -r '.region')
    COUNTRY=$(echo "$INFO" | jq -r '.country')
    ORG=$(echo "$INFO" | jq -r '.org')
}

# === Telegram 推送 ===
send_telegram() {
    local MESSAGE="$1"
    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d chat_id="${TG_CHAT_ID}" \
        -d parse_mode="Markdown" \
        -d text="$MESSAGE" > /dev/null
}

# === 区域简写 → Server ID 映射 ===
map_region_to_server_id() {
    case "$1" in
        jp) SERVER_ID="56935" ;;   # Tokyo - Contabo
        sg) SERVER_ID="4235" ;;   # Singapore - StarHub Ltd
        hk) SERVER_ID="28912" ;;   # Hong Kong - fdcservers.net
        kr) SERVER_ID="67564"  ;;   # Seoul - MOACK Data Center
        us) SERVER_ID="14236" ;;   # Los Angeles - Frontier
        tw) SERVER_ID="18607" ;;   # Tainan - Chunghwa Mobile
        *)
            echo "❌ 不支持的区域简写：$1"
            echo "✅ 支持：jp sg hk kr us tw"
            exit 1
            ;;
    esac
    echo "✅ 匹配到服务器 ID: $SERVER_ID"
}

# === 参数解析 ===
parse_args() {
    while getopts ":r:" opt; do
        case $opt in
            r)
                REGION_CODE="$OPTARG"
                echo "📍 用户指定区域简写为：$REGION_CODE"
                ;;
            \?)
                echo "❌ 无效参数: -$OPTARG" >&2
                exit 1
                ;;
        esac
    done
}

# === 执行测速 ===
run_test() {
    get_ipinfo
    TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$TIMESTAMP] 🚀 开始测速..."

    if [ -n "$SERVER_ID" ]; then
        RESULT=$(speedtest --accept-license --accept-gdpr --server-id="$SERVER_ID" -f json)
    else
        RESULT=$(speedtest --accept-license --accept-gdpr -f json)
    fi

    if [ $? -ne 0 ]; then
        MSG="[$TIMESTAMP] ❌ Speedtest 失败。"
        echo "$MSG" | tee -a "$LOG_FILE"
        send_telegram "$MSG"
        return
    fi

    DOWNLOAD=$(echo "$RESULT" | jq -r '.download.bandwidth / 125000')
    UPLOAD=$(echo "$RESULT" | jq -r '.upload.bandwidth / 125000')
    PING=$(echo "$RESULT" | jq -r '.ping.latency')
    ISP=$(echo "$RESULT" | jq -r '.isp')
    SERVER_NAME=$(echo "$RESULT" | jq -r '.server.name')
    LOCATION=$(echo "$RESULT" | jq -r '.server.location')

    MSG="*📡 VPS测速报告$COUNTRY *  
时间: $TIMESTAMP  
IP: \`$PUBLIC_IP\`  
地区: $CITY, $REGION, $COUNTRY  
ISP: $ORG  
测速服务器: $SERVER_NAME ($LOCATION)

🏓 延迟: *${PING} ms*  
⬇️ 下载: *${DOWNLOAD} Mbps*  
⬆️ 上传: *${UPLOAD} Mbps*"

    echo "$MSG" | tee -a "$LOG_FILE"
    send_telegram "$MSG"
    echo "------------------------------------------------" >> "$LOG_FILE"
}

# === 主程序 ===
main() {
    parse_args "$@"
    check_dependencies

    if [ -n "$REGION_CODE" ]; then
        map_region_to_server_id "$REGION_CODE"
    fi

    run_test

    if [ "$LOOP_MODE" = "yes" ]; then
        while true; do
            sleep "$INTERVAL"
            run_test
        done
    fi
}

main "$@"
