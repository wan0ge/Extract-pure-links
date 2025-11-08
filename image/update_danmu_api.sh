#!/bin/ash
# Openwrt 兼容脚本 - 增强详细中文日志输出 (支持钉钉错误通知)
# 手动启动: /bin/ash /root/danmu_api_web/update_danmu_api.sh
# 清理回车符: tr -d '\r' < /root/danmu_api_web/update_danmu_api.sh > temp_script.sh && mv temp_script.sh /root/danmu_api_web/update_danmu_api.sh

# 获取脚本自身的绝对路径
SCRIPT_DIR=$(dirname "$0")

# --- 配置区 ---
PROJECT_DIR="/root/danmu_api"     # 您的项目根目录
SERVICE_NAME="danmu_api"          # init.d 中注册的服务名称
LOG_FILE="$SCRIPT_DIR/update_log.txt"  # 日志输出文件（脚本位置）
#LOG_FILE="/tmp/danmu_update.log"  # 日志输出文件（特定位置）
STASH_MESSAGE="部署定制化自动暂存" # 暂存信息

# --- 钉钉通知配置 ---
DINGTALK_PROXY_URL=""  # 钉钉代理服务地址
ENABLE_DINGTALK_NOTIFY=0  # 1=启用钉钉通知, 0=禁用
NOTIFY_TIMEOUT=5  # 通知发送超时时间（秒）

# --- 代理配置区 ---
# 允许配置多个代理服务器，格式为 "类型:地址:端口"，例如: "http:192.168.8.234:28235"
# 注意：此为 ASH/BusyBox 兼容的字符串列表，项目之间用逗号 (,) 分隔。
PROXY_LIST="http:192.168.8.234:28235,socks5:192.168.8.231:2080"    # 您可以添加更多代理...
PROXY_TIMEOUT=3                   # 代理连接测试超时时间（秒）

# --- 核心变量 ---
PRE_PULL_HEAD=""
MAX_LOG_LINES=1000 # 日志文件最大允许行数
NEED_RESTART=0 # 默认：不需要重启服务
CODE_WAS_UPDATED=0 # 标记远程代码是否更新
PACKAGE_JSON_CHANGED=0 # 标记 package.json 是否变动
USE_PROXY=0 # 标记是否使用代理

# --- 钉钉通知函数 ---
send_dingtalk_notification() {
    # 参数: $1 = 标题, $2 = 消息内容
    local title="$1"
    local message="$2"
    
    # 检查是否启用通知
    if [ "$ENABLE_DINGTALK_NOTIFY" -ne 1 ]; then
        return 0
    fi
    
    # 检查 curl 是否可用
    if ! command -v curl >/dev/null 2>&1; then
        echo "警告: curl 命令不可用，无法发送钉钉通知。" >> $LOG_FILE
        return 1
    fi
    
    # 对消息内容进行 JSON 转义处理
    # 1. 转义反斜杠 \ -> \\
    # 2. 转义双引号 " -> \"
    # 3. 将真实换行符转换为 \n（适用于实际包含换行的内容）
    # 4. 将字面 \n 转换为真实换行符，再转为 JSON 的 \n
    local escaped_message=$(echo "$message" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
    local escaped_title=$(echo "$title" | sed 's/\\/\\\\/g' | sed 's/"/\\"/g')
    
    # 构建 JSON 数据
    local json_data="{\"title\":\"${escaped_title}\",\"message\":\"${escaped_message}\"}"
    
    echo "正在发送钉钉通知: ${title}" >> $LOG_FILE
    echo "调试 - JSON 数据: $json_data" >> $LOG_FILE
    
    # 发送 POST 请求
    local response=$(curl -s -X POST "$DINGTALK_PROXY_URL" \
        -H "Content-Type: application/json" \
        -d "$json_data" \
        -m "$NOTIFY_TIMEOUT" 2>&1)
    
    local curl_status=$?
    
    if [ $curl_status -eq 0 ]; then
        echo "钉钉通知已发送。响应: $response" >> $LOG_FILE
        return 0
    else
        echo "钉钉通知发送失败 (curl 状态码: $curl_status)。" >> $LOG_FILE
        return 1
    fi
}

# --- 日志清理函数 ---
clean_log_file() {
    # 检查日志文件是否存在
    if [ -f "$LOG_FILE" ]; then
        # 使用 'wc -l' 快速获取行数
        CURRENT_LINES=$(wc -l < "$LOG_FILE")
        
        # 检查是否超过限制
        if [ "$CURRENT_LINES" -gt "$MAX_LOG_LINES" ]; then
            
            echo "警告：日志文件 '$LOG_FILE' 已超过 $MAX_LOG_LINES 行 (当前 $CURRENT_LINES 行)。"
            echo "正在进行截断，保留最新的 $MAX_LOG_LINES 行..."
            
            # 使用 tail -n 截取最后 N 行到临时文件，然后覆盖原文件
            tail -n "$MAX_LOG_LINES" "$LOG_FILE" > "$LOG_FILE.tmp" 2>&1
            # 检查 tail 是否成功
            if [ $? -eq 0 ]; then
                mv "$LOG_FILE.tmp" "$LOG_FILE" 2>&1
                echo "日志文件清理完成。"
            else
                echo "错误：tail 截断失败。可能是因为文件过大或 BusyBox 限制。跳过清理。"
                rm -f "$LOG_FILE.tmp"
            fi
        fi
    fi
}
# -----------------

# 启动时清理日志文件（检查行数并截断）
# 注意：此清理函数中的 echo 语句会直接输出到 STDOUT (控制台/crontab输出)，不会写入 $LOG_FILE
clean_log_file

# 检查日志文件是否已存在且非空
if [ -s "$LOG_FILE" ]; then
    # 如果文件存在且不为空 (-s 检查)，则添加三个换行符作为分隔
    echo -e "\n\n\n" >> $LOG_FILE # 写入三个换行符
fi
echo "--- $(date) ---" >> $LOG_FILE
echo "========================================================" >> $LOG_FILE
echo "开始自动更新服务：$SERVICE_NAME ..." >> $LOG_FILE
echo "当前目录：$PROJECT_DIR" >> $LOG_FILE

# 1. 切换到项目根目录
echo "【步骤 1: 准备工作】" >> $LOG_FILE
echo "切换到 Git 仓库目录：$PROJECT_DIR" >> $LOG_FILE
cd $PROJECT_DIR >> $LOG_FILE 2>&1 || {
    ERROR_MSG="错误: 无法切换到项目目录 $PROJECT_DIR"
    echo "$ERROR_MSG" >> $LOG_FILE
    send_dingtalk_notification "自动更新失败" "${ERROR_MSG}

服务: $SERVICE_NAME
时间: $(date '+%Y-%m-%d %H:%M:%S')
来自: update_danmu_api"
    exit 1
}
PRE_PULL_HEAD=$(git rev-parse HEAD)


# 1.5. 检测并配置代理 (循环测试多个代理)
echo "--------------------------------------------------------" >> $LOG_FILE
echo "【步骤 1.5: 检测网络代理可用性】" >> $LOG_FILE

# 初始化变量
SUCCESSFUL_PROXY_TYPE=""
SUCCESSFUL_PROXY_HOST=""
SUCCESSFUL_PROXY_PORT=""
TEST_SUCCESS=0

# 保存原始 IFS
OLD_IFS=$IFS

# 将 IFS 临时设置为逗号，用于解析代理列表字符串
IFS=','

# 循环遍历代理列表 (现在以逗号为分隔符)
for PROXY_ENTRY in $PROXY_LIST; do
    
    # 恢复 IFS，以确保后续命令和变量截取不会出错
    IFS=$OLD_IFS

    if [ -z "$PROXY_ENTRY" ]; then
        IFS=',' # 确保循环继续前 IFS 仍然是逗号
        continue
    fi

    # 解析代理配置: 类型:地址:端口
    PROXY_TYPE=$(echo "$PROXY_ENTRY" | cut -d: -f1)
    PROXY_HOST=$(echo "$PROXY_ENTRY" | cut -d: -f2)
    PROXY_PORT=$(echo "$PROXY_ENTRY" | cut -d: -f3)

    # 恢复 IFS，以便进行日志输出和 curl 测试
    # (此行实际上在循环顶部已执行，但为了确保安全，我们再次设置，
    # 或者如上所示，在解析完成后立即恢复)

    # 检查解析结果是否有效
    if [ -z "$PROXY_TYPE" ] || [ -z "$PROXY_HOST" ] || [ -z "$PROXY_PORT" ]; then
        echo "警告: 代理配置格式错误或不完整: '$PROXY_ENTRY'。" >> $LOG_FILE
        IFS=',' # 确保循环继续前 IFS 仍然是逗号
        continue
    fi

    echo "--------------------------------------------------------" >> $LOG_FILE
    echo "正在测试代理: ${PROXY_TYPE}://${PROXY_HOST}:${PROXY_PORT}" >> $LOG_FILE
    
    # 使用 curl 尝试通过代理访问 GitHub
    TEST_URL="https://github.com"
    PROXY_URL="${PROXY_HOST}:${PROXY_PORT}"

    echo "正在通过代理 ${PROXY_URL} 测试访问 ${TEST_URL} (设置超时: ${PROXY_TIMEOUT}秒)..." >> $LOG_FILE

    # curl 命令，并提取 HTTP 状态码
    HTTP_CODE=$(curl --proxy "${PROXY_TYPE}://${PROXY_URL}" "$TEST_URL" \
        -m "$PROXY_TIMEOUT" -o /dev/null -s -w "%{http_code}" 2>&1)
    CURL_STATUS=$?

    echo "Curl 状态码: ${CURL_STATUS}, HTTP 响应码: ${HTTP_CODE}" >> $LOG_FILE

    # 检查 curl 退出状态码（0）和 HTTP 状态码（2xx/3xx）
    if [ "$CURL_STATUS" -eq 0 ] && [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -le 399 ]; then
        echo "✓ 代理功能测试成功。将使用此代理。" >> $LOG_FILE
        SUCCESSFUL_PROXY_TYPE="$PROXY_TYPE"
        SUCCESSFUL_PROXY_HOST="$PROXY_HOST"
        SUCCESSFUL_PROXY_PORT="$PROXY_PORT"
        TEST_SUCCESS=1
        
        # 恢复原始 IFS 后再跳出循环
        IFS=$OLD_IFS
        break
    else
        echo "✗ 代理测试失败。" >> $LOG_FILE
        IFS=',' # 确保循环继续前 IFS 仍然是逗号
        # 继续测试下一个代理
    fi
done

# 在所有循环/跳出后，确保 IFS 被恢复，防止循环外代码受影响
IFS=$OLD_IFS

# 根据测试结果进行最终配置
echo "--------------------------------------------------------" >> $LOG_FILE
if [ "$TEST_SUCCESS" -eq 1 ]; then
    USE_PROXY=1
    
    # 设置 Git 代理
    PROXY_URL_TO_SET="${SUCCESSFUL_PROXY_TYPE}://${SUCCESSFUL_PROXY_HOST}:${SUCCESSFUL_PROXY_PORT}"
    git config --global http.proxy "$PROXY_URL_TO_SET"
    git config --global https.proxy "$PROXY_URL_TO_SET"
    echo "已成功设置 Git 使用代理: $PROXY_URL_TO_SET" >> $LOG_FILE

else
    echo "✗ 所有代理均测试失败或列表为空，将直接连接远程仓库（不使用代理）。" >> $LOG_FILE
    USE_PROXY=0
    
    # 清除可能存在的代理配置
    git config --global --unset http.proxy 2>/dev/null
    git config --global --unset https.proxy 2>/dev/null
    echo "已清除 Git 代理配置。" >> $LOG_FILE
fi


# 2. 检查并保存本地修改 (Stash)
echo "--------------------------------------------------------" >> $LOG_FILE
echo "【步骤 2: 检查并暂存本地修改】" >> $LOG_FILE
MODIFIED_FILES=$(git status --porcelain | grep -E '^[M A D R C U]' | sed 's/^...//')
STASHED_COUNT=0

if [ -n "$MODIFIED_FILES" ]; then
    echo "警告: 检测到以下本地修改，将进行暂存以避免冲突：" >> $LOG_FILE
    echo "$MODIFIED_FILES" | sed 's/^/    - /' >> $LOG_FILE
    
    git stash push -u -m "$STASH_MESSAGE" >> $LOG_FILE 2>&1
    
    if [ $? -ne 0 ]; then
        ERROR_MSG="错误: Git 暂存失败。更新已中止。"
        echo "$ERROR_MSG" >> $LOG_FILE
        send_dingtalk_notification "Git 暂存失败" "${ERROR_MSG}

服务: $SERVICE_NAME
时间: $(date '+%Y-%m-%d %H:%M:%S')
来自: update_danmu_api"
        exit 1
    fi
    echo "本地修改已成功暂存。" >> $LOG_FILE
    STASHED_COUNT=1
else
    echo "未检测到本地修改。工作区干净。" >> $LOG_FILE
fi


# 3. 拉取最新代码
echo "--------------------------------------------------------" >> $LOG_FILE
echo "【步骤 3: 拉取最新代码】" >> $LOG_FILE
if [ "$USE_PROXY" -eq 1 ]; then
    echo "正在通过代理从 Git 远程仓库拉取 (分支: main)... (设置超时: 10秒)" >> $LOG_FILE
else
    echo "正在直连从 Git 远程仓库拉取 (分支: main)... (设置超时: 10秒)" >> $LOG_FILE
fi

# 优化：使用 'timeout' 命令 (GNU coreutils 版本语法，不使用 -t)
# 直接指定 10 秒超时。如果 'git pull' 在10秒内未完成（包括连接、协商、下载），
# 'timeout' 会终止它，并返回状态码 124。
PULL_OUTPUT=$(timeout 10 git pull --ff-only origin main 2>&1)
PULL_STATUS=$?

echo "$PULL_OUTPUT" >> $LOG_FILE

if [ $PULL_STATUS -ne 0 ]; then
    echo "========================================================" >> $LOG_FILE
    
    # 优化：检查是否是超时导致的错误
    if [ $PULL_STATUS -eq 124 ]; then
        ERROR_MSG="❌ 严重错误: Git 拉取超时 (超过10秒)。
可能原因：网络连接缓慢、远程仓库服务器无响应。"
        echo "$ERROR_MSG" >> $LOG_FILE
        send_dingtalk_notification "Git 拉取超时" "${ERROR_MSG}

服务: $SERVICE_NAME
时间: $(date '+%Y-%m-%d %H:%M:%S')
来自: update_danmu_api"
    else
        ERROR_MSG="❌ 严重错误: Git 拉取失败或发生冲突 (非超时错误，状态码: $PULL_STATUS)。"
        echo "$ERROR_MSG" >> $LOG_FILE
        echo "详细输出: $PULL_OUTPUT" >> $LOG_FILE
        send_dingtalk_notification "Git 拉取失败" "${ERROR_MSG}
详情: $PULL_OUTPUT

服务: $SERVICE_NAME
时间: $(date '+%Y-%m-%d %H:%M:%S')
来自: update_danmu_api"
    fi
    
    echo "服务重启已中止。错误详情已记录在日志中。" >> $LOG_FILE
    
    if [ "$STASHED_COUNT" -eq 1 ]; then
        echo "尝试还原已暂存的修改..." >> $LOG_FILE
        git stash pop >> $LOG_FILE 2>&1
        echo "已还原本地修改。" >> $LOG_FILE
    fi
    
    # 清理代理配置
    if [ "$USE_PROXY" -eq 1 ]; then
        git config --global --unset http.proxy 2>/dev/null
        git config --global --unset https.proxy 2>/dev/null
        echo "已清除 Git 代理配置。" >> $LOG_FILE
    fi
    
    echo "========================================================" >> $LOG_FILE
    exit 1
fi

# 4. 检查更新文件列表
CURRENT_PULL_HEAD=$(git rev-parse HEAD)
if [ "$PRE_PULL_HEAD" != "$CURRENT_PULL_HEAD" ]; then
    echo "检测到代码更新。更新文件列表如下：" >> $LOG_FILE
    git diff --name-only "$PRE_PULL_HEAD" "$CURRENT_PULL_HEAD" | sed 's/^/    + /' >> $LOG_FILE
    
    # 关键标记：只有远程代码更新，才设置此标记
    CODE_WAS_UPDATED=1
    NEED_RESTART=1
    
    # 检查 package.json 是否在更新文件中
    if git diff --name-only "$PRE_PULL_HEAD" "$CURRENT_PULL_HEAD" | grep -q "package.json"; then
        PACKAGE_JSON_CHANGED=1
        echo "检测到 package.json 文件变动。" >> $LOG_FILE
    fi
else
    echo "代码已是最新版本 (Already up to date)。" >> $LOG_FILE
fi


# 4.5. 清理代理配置
echo "--------------------------------------------------------" >> $LOG_FILE
echo "【步骤 4.5: 清理代理配置】" >> $LOG_FILE
if [ "$USE_PROXY" -eq 1 ]; then
    git config --global --unset http.proxy 2>/dev/null
    git config --global --unset https.proxy 2>/dev/null
    echo "Git 操作完成，已清除代理配置。" >> $LOG_FILE
else
    echo "未使用代理，无需清理。" >> $LOG_FILE
fi


# 5. 重新应用本地修改 (Stash Pop)
echo "--------------------------------------------------------" >> $LOG_FILE
echo "【步骤 5: 还原本地定制化修改】" >> $LOG_FILE
if [ "$STASHED_COUNT" -eq 1 ]; then
    echo "应用已暂存的本地修改..." >> $LOG_FILE
    STASH_POP_OUTPUT=$(git stash pop 2>&1)
    POP_STATUS=$?
    
    if [ $POP_STATUS -ne 0 ]; then
        CONFLICT_FILES=$(git status --porcelain | grep -E '^UU' | sed 's/^UU //')
        
        echo "$STASH_POP_OUTPUT" >> $LOG_FILE
        echo "==========================================================" >> $LOG_FILE
        ERROR_MSG="🚨 警告: 暂存应用发生合并冲突！"
        echo "$ERROR_MSG" >> $LOG_FILE
        echo "冲突文件：" >> $LOG_FILE
        echo "$CONFLICT_FILES" | sed 's/^/    ! /' >> $LOG_FILE
        
        CONFLICT_LIST=$(echo "$CONFLICT_FILES" | tr '\n' ',' | sed 's/,$//')
        send_dingtalk_notification "Git 合并冲突" "🚨 警告: 暂存应用发生合并冲突！

冲突文件: $CONFLICT_LIST
请手动解决冲突并重启服务。

服务: $SERVICE_NAME
时间: $(date '+%Y-%m-%d %H:%M:%S')
来自: update_danmu_api"
        
        echo "请通过 FinalShell 连接，手动解决冲突 (git status/git diff)，然后手动重启服务。" >> $LOG_FILE
        echo "当前服务仍运行在旧代码上，更新已中止。" >> $LOG_FILE
        echo "==========================================================" >> $LOG_FILE
        exit 1
    fi
    echo "已成功还原并应用暂存的修改。" >> $LOG_FILE
    
    # 本地定制化修改被还原，如果代码没有更新，则不需要设置 NEED_RESTART=1
    if [ "$CODE_WAS_UPDATED" -eq 1 ]; then
        # 远程代码有更新，那么还原定制化后，需要重启
        NEED_RESTART=1
    else
        # 远程代码没有更新，那么还原定制化文件只是恢复了原来的状态，无需重启。
        echo "（注：远程代码无更新，跳过对 NEED_RESTART 的设置。）" >> $LOG_FILE
    fi
else
    echo "没有需要应用的暂存修改。" >> $LOG_FILE
fi


# 6. 安装依赖
echo "--------------------------------------------------------" >> $LOG_FILE
echo "【步骤 6: 检查并安装依赖】" >> $LOG_FILE

# 只有在 package.json 变动时才需要运行 npm install
if [ "$PACKAGE_JSON_CHANGED" -eq 1 ]; then
    echo "检测到 package.json 变动，正在执行 npm install --production..." >> $LOG_FILE
    
    NPM_OUTPUT=$(npm install --production 2>&1)
    NPM_STATUS=$?
    echo "$NPM_OUTPUT" >> $LOG_FILE

    if [ $NPM_STATUS -ne 0 ]; then
        ERROR_MSG="错误: npm 依赖安装失败。服务重启已中止。"
        echo "$ERROR_MSG" >> $LOG_FILE
        send_dingtalk_notification "NPM 安装失败" "${ERROR_MSG}

详情: $NPM_OUTPUT

服务: $SERVICE_NAME
时间: $(date '+%Y-%m-%d %H:%M:%S')
来自: update_danmu_api"
        echo "请检查日志中的 npm 详情，手动解决问题。" >> $LOG_FILE
        exit 1
    fi
    echo "依赖检查与安装已完成。" >> $LOG_FILE
    
    # 依赖更新后必须重启服务
    NEED_RESTART=1
elif [ "$CODE_WAS_UPDATED" -eq 1 ]; then
    echo "代码已更新但 package.json 未变动，跳过 npm install。" >> $LOG_FILE
else
    echo "未检测到远程代码更新，跳过 npm install。" >> $LOG_FILE
fi


# 7. 重启服务 (根据 NEED_RESTART 标志位决定)
echo "--------------------------------------------------------" >> $LOG_FILE
echo "【步骤 7: 重启服务】" >> $LOG_FILE
if [ "$NEED_RESTART" -eq 1 ]; then
    echo "检测到代码、配置或依赖发生变动，通过 init.d 重启服务..." >> $LOG_FILE
    /etc/init.d/$SERVICE_NAME restart >> $LOG_FILE 2>&1
    
    if [ $? -eq 0 ]; then
        echo "服务重启指令已发送。" >> $LOG_FILE
        
        # **优化：添加服务更新成功通知**
        send_dingtalk_notification "服务更新成功" "🎉 服务 **$SERVICE_NAME** 已成功更新并重启。

**更新详情:**
* 代码状态: $([ "$CODE_WAS_UPDATED" -eq 1 ] && echo '已更新' || echo '未更新')
* 依赖状态: $([ "$PACKAGE_JSON_CHANGED" -eq 1 ] && echo '已更新/安装' || echo '未变动')

时间: $(date '+%Y-%m-%d %H:%M:%S')
来自: update_danmu_api"
        
    else
        ERROR_MSG="警告: 服务重启命令执行异常"
        echo "$ERROR_MSG" >> $LOG_FILE
        send_dingtalk_notification "服务重启异常" "${ERROR_MSG}

服务: $SERVICE_NAME
时间: $(date '+%Y-%m-%d %H:%M:%S')
来自: update_danmu_api"
    fi
else
    echo "未检测到远程代码、依赖或配置变动，跳过服务重启。" >> $LOG_FILE
    fi

echo "========================================================" >> $LOG_FILE
echo "自动更新流程已成功完成。" >> $LOG_FILE
echo "========================================================" >> $LOG_FILE