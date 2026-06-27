#!/system/bin/sh

LOG_TAG=mochen_path_hide
PERSIST_DIR="/data/adb/mochen_path_hide"
LEGACY_PERSIST_DIR="/data/adb/nohello"

log_i() {
	log -p i -t "$LOG_TAG" "$*" 2>/dev/null
}

# 卸载内核驱动
if grep -q '^pathmask ' /proc/modules 2>/dev/null; then
	if rmmod pathmask 2>/dev/null; then
		log_i "内核驱动在线卸载完成"
	else
		log_i "在线卸载失败，重启手机后内核自动清理驱动"
	fi
fi

# 清理本模块配置
if [ -d "$PERSIST_DIR" ]; then
	rm -rf "$PERSIST_DIR" 2>/dev/null && \
		log_i "已清空莫晨路径一键隐藏用户配置目录"
fi

# 清理旧版NoHello残留
if [ -d "$LEGACY_PERSIST_DIR" ]; then
	rm -rf "$LEGACY_PERSIST_DIR" 2>/dev/null && \
		log_i "清理旧版NoHello遗留配置文件"
fi
