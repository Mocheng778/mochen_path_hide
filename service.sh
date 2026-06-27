#!/system/bin/sh

MODDIR=${0%/*}
MODULE_ID=mochen_path_hide
LEGACY_MODULE_ID=nohello-demo
LOG_TAG=mochen_path_hide
PERSIST_DIR="/data/adb/mochen_path_hide"
LEGACY_PERSIST_DIR="/data/adb/nohello"
LOAD_FAIL_COUNT_PATH="$PERSIST_DIR/load_fail_count"
LOAD_FAIL_REASON_PATH="$PERSIST_DIR/load_fail_reason"
LOAD_FAIL_LIMIT=3

# 自动获取内核主版本
get_kernel_ver() {
    uname -r | grep -oE '^[0-9]+\.[0-9]+' | head -n1
}
KERNEL_VER=$(get_kernel_ver)
KO_DIR="${MODDIR}/ko"

# 内核版本匹配驱动文件
case "${KERNEL_VER}" in
    5.4)  KO_NAME="pathmask-5.4.ko" ;;
    5.10) KO_NAME="pathmask-5.10.ko" ;;
    5.15) KO_NAME="pathmask-5.15.ko" ;;
    6.1)  KO_NAME="pathmask-6.1.ko" ;;
    6.6)  KO_NAME="pathmask-6.6.ko" ;;
    *)
        KO_NAME="pathmask-7.x.ko"
        log_i "未精准匹配内核${KERNEL_VER}，使用7.x兼容驱动尝试加载"
    ;;
esac

KO_PATH="$KO_DIR/$KO_NAME"

MOD_CONFIG_PATH="$MODDIR/target_path.conf"
MOD_HIDE_DIRENTS_CONFIG="$MODDIR/hide_dirents.conf"
MOD_SCOPE_MODE_CONFIG="$MODDIR/scope_mode.conf"
MOD_DENY_UIDS_CONFIG="$MODDIR/deny_uids.conf"
MOD_DENY_PACKAGES_CONFIG="$MODDIR/deny_packages.conf"
MOD_WAIT_SECONDS_CONFIG="$MODDIR/wait_seconds.conf"

CONFIG_PATH="$PERSIST_DIR/target_path.conf"
HIDE_DIRENTS_CONFIG="$PERSIST_DIR/hide_dirents.conf"
SCOPE_MODE_CONFIG="$PERSIST_DIR/scope_mode.conf"
DENY_UIDS_CONFIG="$PERSIST_DIR/deny_uids.conf"
DENY_PACKAGES_CONFIG="$PERSIST_DIR/deny_packages.conf"
WAIT_SECONDS_CONFIG="$PERSIST_DIR/wait_seconds.conf"
LEGACY_TARGET_WAIT_SECONDS_CONFIG="$PERSIST_DIR/target_wait_seconds.conf"
LEGACY_PACKAGE_WAIT_SECONDS_CONFIG="$PERSIST_DIR/package_wait_seconds.conf"
BOOT_STATE_PATH="$PERSIST_DIR/boot_state"

TARGET_PATHS=""
HIDE_DIRENTS=1
SCOPE_MODE=deny
DENY_UIDS=""
WAIT_SECONDS=60
UNRESOLVED_PACKAGES=0

read_load_failure_count() {
	COUNT=0
	if [ -f "$LOAD_FAIL_COUNT_PATH" ]; then
		COUNT="$(head -n 1 "$LOAD_FAIL_COUNT_PATH" 2>/dev/null | tr -d '\r ' || true)"
	fi

	case "$COUNT" in
		''|*[!0-9]*)
			COUNT=0
			;;
	esac

	printf '%s\n' "$COUNT"
}

reset_load_failure_guard() {
	rm -f "$LOAD_FAIL_COUNT_PATH" "$LOAD_FAIL_REASON_PATH" 2>/dev/null || true
}

record_load_failure() {
	REASON="$1"
	COUNT="$(read_load_failure_count)"
	COUNT=$((COUNT + 1))
	mkdir -p "$PERSIST_DIR" 2>/dev/null || true
	printf '%s\n' "$COUNT" > "$LOAD_FAIL_COUNT_PATH" 2>/dev/null || true
	printf '%s\n' "$REASON" > "$LOAD_FAIL_REASON_PATH" 2>/dev/null || true
	log_e "加载失败 $COUNT/$LOAD_FAIL_LIMIT: $REASON"
}

should_skip_after_load_failures() {
	[ "${PATHMASK_IGNORE_FAIL_GUARD:-0}" = "1" ] && return 1

	COUNT="$(read_load_failure_count)"
	if [ "$COUNT" -ge "$LOAD_FAIL_LIMIT" ]; then
		if [ -f "$LOAD_FAIL_REASON_PATH" ]; then
			REASON="$(head -n 1 "$LOAD_FAIL_REASON_PATH" 2>/dev/null || true)"
		else
			REASON=""
		fi
		log_e "已触发连续失败保护，不再加载；原因=$REASON"
		log_e "WebUI保存热重载或手动删除失败计数文件即可重试"
		return 0
	fi

	return 1
}

log_i() {
	log -p i -t "$LOG_TAG" "$*"
}

log_e() {
	log -p e -t "$LOG_TAG" "$*"
}

write_boot_state() {
	STATE="$1"
	DETAIL="$2"
	DEADLINE="$3"

	[ -d "$PERSIST_DIR" ] || mkdir -p "$PERSIST_DIR" 2>/dev/null || return 0

	{
		printf 'state=%s\n' "$STATE"
		printf 'updated=%s\n' "$(date +%s 2>/dev/null || echo 0)"
		[ -n "$DEADLINE" ] && printf 'deadline=%s\n' "$DEADLINE"
		[ -n "$DETAIL" ] && printf 'detail=%s\n' "$DETAIL"
	} > "$BOOT_STATE_PATH" 2>/dev/null || true
}

clear_boot_state() {
	rm -f "$BOOT_STATE_PATH" 2>/dev/null || true
}

migrate_legacy_wait_seconds() {
	[ -f "$WAIT_SECONDS_CONFIG" ] && {
		rm -f "$LEGACY_TARGET_WAIT_SECONDS_CONFIG" \
			"$LEGACY_PACKAGE_WAIT_SECONDS_CONFIG" 2>/dev/null || true
		return
	}

	OLD_TARGET=""
	OLD_PACKAGE=""
	[ -f "$LEGACY_TARGET_WAIT_SECONDS_CONFIG" ] && \
		OLD_TARGET="$(head -n 1 "$LEGACY_TARGET_WAIT_SECONDS_CONFIG" 2>/dev/null | tr -d '\r ')"
	[ -f "$LEGACY_PACKAGE_WAIT_SECONDS_CONFIG" ] && \
		OLD_PACKAGE="$(head -n 1 "$LEGACY_PACKAGE_WAIT_SECONDS_CONFIG" 2>/dev/null | tr -d '\r ')"

	case "$OLD_TARGET" in ''|*[!0-9]*) OLD_TARGET=0 ;; esac
	case "$OLD_PACKAGE" in ''|*[!0-9]*) OLD_PACKAGE=0 ;; esac

	if [ "$OLD_TARGET" -gt 0 ] || [ "$OLD_PACKAGE" -gt 0 ]; then
		MAX_WAIT="$OLD_TARGET"
		[ "$OLD_PACKAGE" -gt "$MAX_WAIT" ] && MAX_WAIT="$OLD_PACKAGE"
		printf '%s\n' "$MAX_WAIT" > "$WAIT_SECONDS_CONFIG" 2>/dev/null || true
		log_i "合并旧等待配置 target=$OLD_TARGET package=$OLD_PACKAGE 最终=$MAX_WAIT"
	fi

	rm -f "$LEGACY_TARGET_WAIT_SECONDS_CONFIG" \
		"$LEGACY_PACKAGE_WAIT_SECONDS_CONFIG" 2>/dev/null || true
}

seed_config_file() {
	DEST="$1"
	SRC="$2"
	DEFAULT_VALUE="$3"

	if [ -f "$DEST" ]; then
		return
	fi

	if [ -f "$SRC" ]; then
		cp "$SRC" "$DEST" 2>/dev/null && return
	fi

	printf '%s\n' "$DEFAULT_VALUE" > "$DEST"
}

migrate_legacy_config() {
	[ -d "$PERSIST_DIR" ] && return
	[ -d "$LEGACY_PERSIST_DIR" ] || return

	if mkdir -p "$PERSIST_DIR" 2>/dev/null; then
		for NAME in target_path.conf hide_dirents.conf scope_mode.conf deny_uids.conf deny_packages.conf wait_seconds.conf target_wait_seconds.conf package_wait_seconds.conf; do
			if [ -f "$LEGACY_PERSIST_DIR/$NAME" ]; then
				cp "$LEGACY_PERSIST_DIR/$NAME" "$PERSIST_DIR/$NAME" 2>/dev/null || true
			fi
		done
		log_i "已迁移旧版NoHello配置"
	fi
}

init_persistent_config() {
	migrate_legacy_config

	if ! mkdir -p "$PERSIST_DIR" 2>/dev/null; then
		log_i "无法创建持久化目录，使用模块内置配置"
		CONFIG_PATH="$MOD_CONFIG_PATH"
		HIDE_DIRENTS_CONFIG="$MOD_HIDE_DIRENTS_CONFIG"
		SCOPE_MODE_CONFIG="$MOD_SCOPE_MODE_CONFIG"
		DENY_UIDS_CONFIG="$MOD_DENY_UIDS_CONFIG"
		DENY_PACKAGES_CONFIG="$MOD_DENY_PACKAGES_CONFIG"
		WAIT_SECONDS_CONFIG="$MOD_WAIT_SECONDS_CONFIG"
		return
	fi

	chmod 0700 "$PERSIST_DIR" 2>/dev/null || true
	migrate_legacy_wait_seconds
	seed_config_file "$CONFIG_PATH" "$MOD_CONFIG_PATH" ""
	seed_config_file "$HIDE_DIRENTS_CONFIG" "$MOD_HIDE_DIRENTS_CONFIG" "1"
	seed_config_file "$SCOPE_MODE_CONFIG" "$MOD_SCOPE_MODE_CONFIG" "deny"
	seed_config_file "$DENY_UIDS_CONFIG" "$MOD_DENY_UIDS_CONFIG" ""
	seed_config_file "$DENY_PACKAGES_CONFIG" "$MOD_DENY_PACKAGES_CONFIG" ""
	seed_config_file "$WAIT_SECONDS_CONFIG" "$MOD_WAIT_SECONDS_CONFIG" "60"
}

add_target_path() {
	CANDIDATE_PATH="$1"

	if [ -z "$CANDIDATE_PATH" ]; then
		return
	fi

	if [ -z "$TARGET_PATHS" ]; then
		TARGET_PATHS="$CANDIDATE_PATH"
	else
		TARGET_PATHS="$TARGET_PATHS,$CANDIDATE_PATH"
	fi
}

add_deny_uid() {
	CANDIDATE_UID="$1"

	case "$CANDIDATE_UID" in
		''|*[!0-9]*)
			return
			;;
	esac

	case ",$DENY_UIDS," in
		*,"$CANDIDATE_UID",*)
			return
			;;
	esac

	if [ -z "$DENY_UIDS" ]; then
		DENY_UIDS="$CANDIDATE_UID"
	else
		DENY_UIDS="$DENY_UIDS,$CANDIDATE_UID"
	fi
}

package_to_uid_from_packages_list() {
	PACKAGE_NAME="$1"
	PACKAGES_LIST="/data/system/packages.list"

	[ -f "$PACKAGES_LIST" ] || return

	while IFS= read -r PACKAGE_LINE || [ -n "$PACKAGE_LINE" ]; do
		set -- $PACKAGE_LINE
		[ "$1" = "$PACKAGE_NAME" ] || continue

		case "$2" in
			''|*[!0-9]*)
				return
				;;
			*)
				printf '%s\n' "$2"
				return
				;;
		esac
	done < "$PACKAGES_LIST"
}

package_to_uid_from_data_dir() {
	PACKAGE_NAME="$1"

	for DATA_DIR in "/data/user/0/$PACKAGE_NAME" "/data/data/$PACKAGE_NAME"; do
		[ -d "$DATA_DIR" ] || continue

		DATA_UID="$(stat -c '%u' "$DATA_DIR" 2>/dev/null || true)"
		case "$DATA_UID" in
			''|*[!0-9]*)
				;;
			*)
				printf '%s\n' "$DATA_UID"
				return
				;;
		esac

		DATA_LINE="$(ls -ldn "$DATA_DIR" 2>/dev/null || true)"
		set -- $DATA_LINE
		case "$3" in
			''|*[!0-9]*)
				;;
			*)
				printf '%s\n' "$3"
				return
				;;
		esac
	done
}

package_to_uid_from_pm() {
	PACKAGE_NAME="$1"
	PACKAGE_LINES="$(
		cmd package list packages --user 0 -U "$PACKAGE_NAME" 2>/dev/null || true
		pm list packages --user 0 -U "$PACKAGE_NAME" 2>/dev/null || true
		cmd package list packages -U "$PACKAGE_NAME" 2>/dev/null || true
		pm list packages -U "$PACKAGE_NAME" 2>/dev/null || true
	)"

	printf '%s\n' "$PACKAGE_LINES" |
	while IFS= read -r PACKAGE_LINE; do
		case "$PACKAGE_LINE" in
			package:*" uid:"*)
				;;
			*)
				continue
				;;
		esac

		LINE_PKG="${PACKAGE_LINE#package:}"
		LINE_PKG="${LINE_PKG%% uid:*}"
		LINE_UID="${PACKAGE_LINE##* uid:}"
		LINE_UID="${LINE_UID%% *}"

		if [ "$LINE_PKG" = "$PACKAGE_NAME" ] &&
		   [ "$LINE_UID" != "$PACKAGE_LINE" ]; then
			printf '%s\n' "$LINE_UID"
			break
		fi
	done
}

package_to_uid() {
	RESOLVED_PACKAGE_UID="$(package_to_uid_from_packages_list "$1" | head -n 1)"
	if [ -n "$RESOLVED_PACKAGE_UID" ]; then
		printf '%s\n' "$RESOLVED_PACKAGE_UID"
		return
	fi

	RESOLVED_PACKAGE_UID="$(package_to_uid_from_pm "$1" | head -n 1)"
	if [ -n "$RESOLVED_PACKAGE_UID" ]; then
		printf '%s\n' "$RESOLVED_PACKAGE_UID"
		return
	fi

	package_to_uid_from_data_dir "$1" | head -n 1
}

read_deny_uid_config() {
	[ -f "$DENY_UIDS_CONFIG" ] || return

	while IFS= read -r CONFIG_LINE || [ -n "$CONFIG_LINE" ]; do
		CONFIG_LINE="$(printf '%s' "$CONFIG_LINE" | tr -d '\r')"
		case "$CONFIG_LINE" in
			''|\#*)
				continue
				;;
		esac
		OLD_IFS="$IFS"
		IFS=","
		for UID_ITEM in $CONFIG_LINE; do
			IFS="$OLD_IFS"
			UID_ITEM="$(printf '%s' "$UID_ITEM" | tr -d ' ')"
			add_deny_uid "$UID_ITEM"
			IFS=","
		done
		IFS="$OLD_IFS"
	done < "$DENY_UIDS_CONFIG"
}

read_deny_package_config() {
	QUIET="$1"
	UNRESOLVED_PACKAGES=0
	[ -f "$DENY_PACKAGES_CONFIG" ] || return

	while IFS= read -r CONFIG_LINE || [ -n "$CONFIG_LINE" ]; do
		CONFIG_LINE="$(printf '%s' "$CONFIG_LINE" | tr -d '\r ')"
		case "$CONFIG_LINE" in
			''|\#*)
				continue
				;;
		esac
		PACKAGE_UID="$(package_to_uid "$CONFIG_LINE" | head -n 1)"
		if [ -n "$PACKAGE_UID" ]; then
			add_deny_uid "$PACKAGE_UID"
			[ "$QUIET" = "1" ] || log_i "解析应用 $CONFIG_LINE UID=$PACKAGE_UID"
		else
			UNRESOLVED_PACKAGES=$((UNRESOLVED_PACKAGES + 1))
			[ "$QUIET" = "1" ] || log_i "无法解析包名UID: $CONFIG_LINE"
		fi
	done < "$DENY_PACKAGES_CONFIG"
}

any_target_exists() {
	OLD_IFS="$IFS"
	IFS=","
	for TARGET_ITEM in $TARGET_PATHS; do
		IFS="$OLD_IFS"
		if [ -e "$TARGET_ITEM" ]; then
			return 0
		fi
		IFS=","
	done
	IFS="$OLD_IFS"
	return 1
}

all_targets_exist() {
	OLD_IFS="$IFS"
	IFS=","
	for TARGET_ITEM in $TARGET_PATHS; do
		IFS="$OLD_IFS"
		if [ ! -e "$TARGET_ITEM" ]; then
			return 1
		fi
		IFS=","
	done
	IFS="$OLD_IFS"
	return 0
}

log_missing_targets() {
	OLD_IFS="$IFS"
	IFS=","
	for TARGET_ITEM in $TARGET_PATHS; do
		IFS="$OLD_IFS"
		if [ ! -e "$TARGET_ITEM" ]; then
			log_i "路径不存在，内核将跳过: $TARGET_ITEM"
		fi
		IFS=","
	done
	IFS="$OLD_IFS"
}

wait_for_targets() {
	END="$1"

	write_boot_state "waiting-targets" "$TARGET_PATHS" "$END"

	while :; do
		if all_targets_exist; then
			return 0
		fi
		NOW="$(date +%s 2>/dev/null || echo 0)"
		[ "$NOW" -ge "$END" ] && break
		sleep 1
	done

	log_missing_targets
	any_target_exists
}

wait_for_deny_packages() {
	END="$1"

	write_boot_state "waiting-packages" "" "$END"

	while :; do
		DENY_UIDS=""
		read_deny_uid_config
		read_deny_package_config 1
		if [ "$UNRESOLVED_PACKAGES" -eq 0 ]; then
			read_deny_package_config 0
			return 0
		fi
		NOW="$(date +%s 2>/dev/null || echo 0)"
		[ "$NOW" -ge "$END" ] && break
		sleep 1
	done

	DENY_UIDS=""
	read_deny_uid_config
	read_deny_package_config 0
}

init_persistent_config
write_boot_state "init" "" ""

if [ -n "${PATHMASK_LOAD_FAIL_LIMIT:-}" ]; then
	LOAD_FAIL_LIMIT="$PATHMASK_LOAD_FAIL_LIMIT"
fi

case "$LOAD_FAIL_LIMIT" in
	''|*[!0-9]*|0)
		LOAD_FAIL_LIMIT=3
		;;
esac

if [ "${PATHMASK_RESET_FAIL_GUARD:-0}" = "1" ]; then
	reset_load_failure_guard
	log_i "已重置加载失败保护"
fi

if should_skip_after_load_failures; then
	write_boot_state "skipped-fail-guard" "连续加载失败已暂停" ""
	exit 0
fi

if [ -f "$CONFIG_PATH" ]; then
	while IFS= read -r CONFIG_LINE || [ -n "$CONFIG_LINE" ]; do
		CONFIG_LINE="$(printf '%s' "$CONFIG_LINE" | tr -d '\r')"
		case "$CONFIG_LINE" in
			''|\#*)
				continue
				;;
		esac
		add_target_path "$CONFIG_LINE"
	done < "$CONFIG_PATH"
fi

if [ -f "$HIDE_DIRENTS_CONFIG" ]; then
	HIDE_DIRENTS="$(head -n 1 "$HIDE_DIRENTS_CONFIG" | tr -d '\r')"
fi

if [ -f "$SCOPE_MODE_CONFIG" ]; then
	SCOPE_MODE="$(head -n 1 "$SCOPE_MODE_CONFIG" | tr -d '\r ')"
fi

if [ -f "$WAIT_SECONDS_CONFIG" ]; then
	WAIT_SECONDS="$(head -n 1 "$WAIT_SECONDS_CONFIG" | tr -d '\r ')"
fi

if [ -n "${PATHMASK_WAIT_SECONDS:-}" ]; then
	WAIT_SECONDS="$PATHMASK_WAIT_SECONDS"
fi

case "$WAIT_SECONDS" in
	''|*[!0-9]*)
		WAIT_SECONDS=60
		;;
esac

case "$SCOPE_MODE" in
	deny|global)
		;;
	*)
		log_i "不支持的模式$SCOPE_MODE，自动切换为global全局模式"
		SCOPE_MODE=global
		;;
esac

case "$HIDE_DIRENTS" in
	0|false|False|no|No)
		HIDE_DIRENTS=0
		;;
	*)
		HIDE_DIRENTS=1
		;;
esac

if [ -z "$TARGET_PATHS" ]; then
	log_e "隐藏路径列表为空，终止加载"
	write_boot_state "skipped-empty-targets" "无配置隐藏路径" ""
	exit 1
fi

if [ ! -f "$KO_PATH" ]; then
	log_e "对应内核驱动不存在：$KO_PATH"
	record_load_failure "驱动文件缺失：$KO_PATH"
	write_boot_state "failed-missing-ko" "$KO_PATH" ""
	exit 1
fi

sleep 10

WAIT_DEADLINE=$(( $(date +%s 2>/dev/null || echo 0) + WAIT_SECONDS ))

if ! wait_for_targets "$WAIT_DEADLINE"; then
	log_i "无有效隐藏路径，跳过驱动加载"
	write_boot_state "skipped-targets-missing" "$TARGET_PATHS" ""
	exit 0
fi

if [ "$SCOPE_MODE" = "deny" ]; then
	wait_for_deny_packages "$WAIT_DEADLINE"
	if [ -z "$DENY_UIDS" ]; then
		log_i "黑名单模式无可用UID，跳过加载"
		write_boot_state "skipped-no-uids" "无解析成功的UID" ""
		exit 0
	fi
else
	read_deny_uid_config
	read_deny_package_config 0
fi

if grep -q '^pathmask ' /proc/modules 2>/dev/null; then
	reset_load_failure_guard
	log_i "莫晨路径隐藏驱动已处于加载状态"
	write_boot_state "already-loaded" "" ""
	exit 0
fi

if grep -q '^nohello ' /proc/modules 2>/dev/null; then
	log_i "检测到旧版NoHello驱动，请卸载旧模块后重试"
	write_boot_state "skipped-legacy-loaded" "旧内核模块冲突" ""
	exit 0
fi

if insmod "$KO_PATH" target_paths="$TARGET_PATHS" hide_dirents="$HIDE_DIRENTS" scope_mode="$SCOPE_MODE" deny_uids="$DENY_UIDS"; then
	reset_load_failure_guard
	log_i "内核${KERNEL_VER}驱动加载成功，参数：$TARGET_PATHS 模式:$SCOPE_MODE UID:$DENY_UIDS"
	write_boot_state "loaded" "$TARGET_PATHS" ""
else
	log_e "内核${KERNEL_VER} insmod加载失败，抓取内核报错日志"
	dmesg | grep -i pathmask | tail -n10 | while read -r line; do log_e "dmesg日志: $line"; done
	record_load_failure "insmod加载失败: $KO_PATH"
	write_boot_state "failed-insmod" "$KO_PATH" ""
	exit 1
fi
