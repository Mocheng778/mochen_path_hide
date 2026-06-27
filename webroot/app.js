const MODULE_ID = "mochen_path_hide";
const LEGACY_MODULE_ID = "nohello-demo";
const MODULE_NAME = "pathmask";
const LEGACY_MODULE_NAME = "nohello";
const MODDIR = `/data/adb/modules/${MODULE_ID}`;
const LEGACY_MODDIR = `/data/adb/modules/${LEGACY_MODULE_ID}`;
const CONFIGDIR = "/data/adb/mochen_path_hide";
const LEGACY_CONFIGDIR = "/data/adb/nohello";
const LOG_PAGE_LINES = 80;

const DEFAULT_TARGET_PATHS = [
	"/dev/cpuset/scene-daemon",
	"/dev/scene",
	"/system_ext/app/SoterService",
];

const DEFAULT_DENY_PACKAGES = [
	"com.chunqiunativecheck",
	"com.eltavine.duckdetector",
	"luna.safe.luna",
];

const DEFAULT_WAIT_SECONDS = 60;
const BOOT_POLL_INTERVAL_MS = 5000;
const BOOT_WAITING_STATES = new Set(["init", "waiting-targets", "waiting-packages"]);

const files = {
	targets: `${CONFIGDIR}/target_path.conf`,
	hideDirents: `${CONFIGDIR}/hide_dirents.conf`,
	scope: `${CONFIGDIR}/scope_mode.conf`,
	denyPackages: `${CONFIGDIR}/deny_packages.conf`,
	denyUids: `${CONFIGDIR}/deny_uids.conf`,
	waitSeconds: `${CONFIGDIR}/wait_seconds.conf`,
	bootState: `${CONFIGDIR}/boot_state`,
	failCount: `${CONFIGDIR}/load_fail_count`,
	failReason: `${CONFIGDIR}/load_fail_reason`,
	service: `${MODDIR}/service.sh`,
	ko: `${MODDIR}/ko/`,
};

let apps = [];
let selectedPackages = new Set();
let busy = false;
let lastSnapshot = {};
let logPages = { status: [], config: [], kernel: [], script: [] };
let activeLog = "status";
let activeLogPage = 
