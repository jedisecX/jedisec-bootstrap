#!/data/data/com.termux/files/usr/bin/bash
#
# JediSec Bootstrap - Installer Framework Edition v2.1
#
# Modular, category-driven environment manager for Termux / Linux / WSL2.
# Detects package manager + already-installed packages, logs every action,
# runs post-install health checks, supports non-interactive CLI flags,
# config overrides, self-update, and JSON summaries.
#
# v2.1 changes:
#   - Cross-PM package name resolution (Termux / apt / dnf / pacman)
#   - Accurate Python import-name mapping for installed checks
#   - CLI --sys=all / --py=all now run the full update + install paths
#   - Minor robustness + logging polish
#

set -uo pipefail

# ------------------------------------------------------------------
# Colors / UI
# ------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# ------------------------------------------------------------------
# Paths / Logging / State
# ------------------------------------------------------------------
JEDISEC_HOME="${HOME}/.jedisec"
LOG_DIR="${JEDISEC_HOME}/logs"
STATE_DIR="${JEDISEC_HOME}/state"
LOG_FILE="${LOG_DIR}/bootstrap_$(date +%Y%m%d_%H%M%S).log"
SUMMARY_FILE="${STATE_DIR}/last_run_summary.txt"
JSON_SUMMARY_FILE="${STATE_DIR}/last_run_summary.json"
CONFIG_FILE="${JEDISEC_HOME}/packages.conf"
LOG_RETENTION_DAYS=14

PROJECT_DIRS=("$HOME/Projects/JediSec" "$HOME/Projects/Scripts" "$HOME/Projects/AI" "$HOME/Projects/OSINT" "$HOME/.config")

mkdir -p "$LOG_DIR" "$STATE_DIR"

# Run counters / flags
declare -i COUNT_INSTALLED=0
declare -i COUNT_SKIPPED=0
declare -i COUNT_FAILED=0
FAILED_ITEMS=()
DRY_RUN=false
JSON_OUTPUT=false
INTERRUPTED=false

# ------------------------------------------------------------------
# Categorized System Packages
# ------------------------------------------------------------------
declare -A SYS_CATEGORIES=(
    [core]="bash git curl wget nano vim tmux openssh rsync tree jq zip unzip tar xz 7zip"
    [dev]="make pkg-config python python-pip nodejs php"
    [toolchain]="clang cmake ninja rust golang"
    [data]="sqlite openssl libffi libxml2 libxslt libjpeg-turbo libpng freetype zlib"
    [media]="ffmpeg imagemagick poppler"
    [network]="dnsutils inetutils net-tools nmap whois"
    [osint]="tesseract-ocr exiftool binwalk yt-dlp"
)
SYS_CATEGORY_ORDER=(core dev toolchain data media network osint)

# ------------------------------------------------------------------
# Categorized Python Packages
# ------------------------------------------------------------------
declare -A PY_CATEGORIES=(
    [core]="requests httpx aiohttp python-dotenv pyyaml orjson click typer rich tqdm"
    [web]="beautifulsoup4 lxml feedparser fastapi uvicorn flask websockets"
    [data]="numpy pandas matplotlib pillow pymupdf pdfplumber"
    [ai]="openai ollama chromadb"
    [security]="cryptography pycryptodome paramiko dnspython python-whois tldextract"
    [db]="sqlalchemy aiosqlite"
    [osint]="gallery-dl yt-dlp exifread python-magic shodan"
)
PY_CATEGORY_ORDER=(core web data ai security db osint)

# ------------------------------------------------------------------
# Config override (optional)
#
# ~/.jedisec/packages.conf is a plain bash file, sourced if present.
# Not YAML on purpose: yq/python-yaml can't be assumed to exist yet on
# a fresh box, and this script has to run before it installs anything.
# Override individual categories like:
#
#   SYS_CATEGORIES[osint]="tesseract-ocr exiftool custom-tool"
#   PY_CATEGORIES[ai]="openai ollama chromadb anthropic"
#
# ------------------------------------------------------------------
load_config_override() {
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
        log INFO "Loaded config override: ${CONFIG_FILE}"
    fi
}

# ------------------------------------------------------------------
# Core UI helpers
# ------------------------------------------------------------------
header() {
    $JSON_OUTPUT && return 0
    clear 2>/dev/null || true
    echo -e "${BLUE}=========================================${NC}"
    echo -e "${GREEN}${BOLD}     JediSec Bootstrap${NC}"
    echo -e "${CYAN}     Installer Framework Edition v2.1${NC}"
    echo -e "${BLUE}=========================================${NC}"
    echo -e "${NC}Platform: ${PKG_MANAGER:-unknown}   Log: ${LOG_FILE}"
    $DRY_RUN && echo -e "${YELLOW}DRY RUN — no changes will be made${NC}"
    echo
}

pause() {
    $JSON_OUTPUT && return 0
    echo
    read -n 1 -s -r -p "Press any key to continue..."
    echo
}

# log <level> <message>   levels: INFO, OK, WARN, ERROR
log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    local color icon
    case "$level" in
        OK)    color="$GREEN";  icon="[✓]" ;;
        WARN)  color="$YELLOW"; icon="[!]" ;;
        ERROR) color="$RED";    icon="[✗]" ;;
        *)     color="$NC";     icon="[i]" ;;
    esac
    if ! $JSON_OUTPUT; then
        echo -e "${color}${icon} ${msg}${NC}"
    fi
    echo "${ts} [${level}] ${msg}" >> "$LOG_FILE"
}

error() { log ERROR "$1"; }

section() {
    if ! $JSON_OUTPUT; then
        echo
        echo -e "${MAGENTA}${BOLD}--- $1 ---${NC}"
    fi
    log INFO "=== $1 ==="
}

# ------------------------------------------------------------------
# Log rotation
# ------------------------------------------------------------------
rotate_logs() {
    local removed
    removed=$(find "$LOG_DIR" -name "bootstrap_*.log" -mtime "+${LOG_RETENTION_DAYS}" -print -delete 2>/dev/null | wc -l)
    if [ "${removed:-0}" -gt 0 ]; then
        log INFO "Log rotation: removed ${removed} log(s) older than ${LOG_RETENTION_DAYS}d"
    fi
}

# ------------------------------------------------------------------
# Environment / package-manager detection
#
# One script, three targets: Termux (pkg/apt-based), Debian/WSL2 (apt),
# Fedora-family (dnf), Arch-family (pacman). Everything else falls back
# to "unknown" and the script degrades gracefully (health-check and
# directory/alias setup still work; package install steps are skipped).
# ------------------------------------------------------------------
detect_environment() {
    if [ -n "${PREFIX:-}" ] && [[ "$PREFIX" == *"com.termux"* ]] && command -v pkg >/dev/null 2>&1; then
        PKG_MANAGER="termux"
    elif command -v apt-get >/dev/null 2>&1; then
        PKG_MANAGER="apt"
    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
    elif command -v pacman >/dev/null 2>&1; then
        PKG_MANAGER="pacman"
    else
        PKG_MANAGER="unknown"
    fi

    if grep -qi microsoft /proc/version 2>/dev/null; then
        IS_WSL=true
    else
        IS_WSL=false
    fi

    export PKG_MANAGER IS_WSL
}

# ------------------------------------------------------------------
# Cross-PM package name resolution
# ------------------------------------------------------------------
# Maps the canonical names used in SYS_CATEGORIES to the real package
# name expected by the detected package manager.
resolve_pkg() {
    local p="$1"
    case "$PKG_MANAGER" in
        apt)
            case "$p" in
                7zip)            echo "p7zip-full" ;;
                python)          echo "python3" ;;
                python-pip)      echo "python3-pip" ;;
                nodejs)          echo "nodejs" ;;
                sqlite)          echo "sqlite3" ;;
                libjpeg-turbo)   echo "libjpeg-turbo8" ;;
                libpng)          echo "libpng-dev" ;;
                freetype)        echo "libfreetype6" ;;
                zlib)            echo "zlib1g" ;;
                libffi)          echo "libffi-dev" ;;
                libxml2)         echo "libxml2-dev" ;;
                libxslt)         echo "libxslt1-dev" ;;
                openssl)         echo "libssl-dev" ;;
                dnsutils)        echo "dnsutils" ;;
                inetutils)       echo "inetutils-ping" ;;
                net-tools)       echo "net-tools" ;;
                tesseract-ocr)   echo "tesseract-ocr" ;;
                yt-dlp)          echo "yt-dlp" ;;
                poppler)         echo "poppler-utils" ;;
                *)               echo "$p" ;;
            esac
            ;;
        dnf)
            case "$p" in
                7zip)            echo "p7zip" ;;
                python)          echo "python3" ;;
                python-pip)      echo "python3-pip" ;;
                tesseract-ocr)   echo "tesseract" ;;
                libjpeg-turbo)   echo "libjpeg-turbo" ;;
                poppler)         echo "poppler-utils" ;;
                *)               echo "$p" ;;
            esac
            ;;
        pacman)
            case "$p" in
                7zip)            echo "p7zip" ;;
                python-pip)      echo "python-pip" ;;
                tesseract-ocr)   echo "tesseract" ;;
                libjpeg-turbo)   echo "libjpeg-turbo" ;;
                poppler)         echo "poppler" ;;
                *)               echo "$p" ;;
            esac
            ;;
        *)  # termux + unknown — keep original names
            echo "$p"
            ;;
    esac
}

# ------------------------------------------------------------------
# Detection helpers (installed check + install command per PM)
# ------------------------------------------------------------------
sys_pkg_installed() {
    local p="$1"
    local real
    real=$(resolve_pkg "$p")
    case "$PKG_MANAGER" in
        termux|apt) dpkg -s "$real" >/dev/null 2>&1 || dpkg -s "$p" >/dev/null 2>&1 ;;
        dnf)        rpm -q "$real" >/dev/null 2>&1 || rpm -q "$p" >/dev/null 2>&1 ;;
        pacman)     pacman -Qi "$real" >/dev/null 2>&1 || pacman -Qi "$p" >/dev/null 2>&1 ;;
        *)          return 1 ;;
    esac
}

pm_update_cmd() {
    case "$PKG_MANAGER" in
        termux) echo "pkg update -y && pkg upgrade -y" ;;
        apt)    echo "sudo apt-get update -y && sudo apt-get upgrade -y" ;;
        dnf)    echo "sudo dnf upgrade -y" ;;
        pacman) echo "sudo pacman -Syu --noconfirm" ;;
        *)      echo "" ;;
    esac
}

pm_install_cmd() {
    # Prints the install command prefix; caller appends package names
    case "$PKG_MANAGER" in
        termux) echo "pkg install -y" ;;
        apt)    echo "sudo apt-get install -y" ;;
        dnf)    echo "sudo dnf install -y" ;;
        pacman) echo "sudo pacman -S --noconfirm" ;;
        *)      echo "" ;;
    esac
}

py_pkg_installed() {
    local pkg="$1"
    local import_name
    case "$pkg" in
        python-dotenv)  import_name="dotenv" ;;
        pyyaml)         import_name="yaml" ;;
        beautifulsoup4) import_name="bs4" ;;
        pillow)         import_name="PIL" ;;
        pymupdf)        import_name="fitz" ;;
        python-whois)   import_name="whois" ;;
        python-magic)   import_name="magic" ;;
        gallery-dl)     import_name="gallery_dl" ;;
        *)              import_name="${pkg//-/_}" ;;
    esac
    python -c "import importlib.util,sys; sys.exit(0 if importlib.util.find_spec('${import_name}') else 1)" 2>/dev/null \
        || pip show "$pkg" >/dev/null 2>&1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# ------------------------------------------------------------------
# Installers (category-aware, detection + dry-run aware)
# ------------------------------------------------------------------
install_sys_category() {
    local cat="$1"
    local pkgs=(${SYS_CATEGORIES[$cat]:-})
    local to_install=()
    local real_pkgs=()

    if [ "${#pkgs[@]}" -eq 0 ]; then
        log WARN "No packages defined for sys category '${cat}'"
        return 0
    fi

    section "System packages: ${cat}"

    if [ "$PKG_MANAGER" = "unknown" ]; then
        log WARN "No supported package manager detected; skipping '${cat}'"
        return 0
    fi

    for p in "${pkgs[@]}"; do
        if sys_pkg_installed "$p"; then
            log INFO "  ${p} already installed, skipping"
            ((COUNT_SKIPPED++))
        else
            to_install+=("$p")
            real_pkgs+=("$(resolve_pkg "$p")")
        fi
    done

    if [ "${#to_install[@]}" -eq 0 ]; then
        log OK "All '${cat}' packages already present."
        return 0
    fi

    if $DRY_RUN; then
        log INFO "[DRY RUN] Would install (${cat}): ${to_install[*]}  (resolved: ${real_pkgs[*]})"
        COUNT_INSTALLED=$((COUNT_INSTALLED + ${#to_install[@]}))
        return 0
    fi

    local install_prefix
    install_prefix=$(pm_install_cmd)
    log INFO "Installing: ${to_install[*]}  →  ${real_pkgs[*]}"
    if eval "$install_prefix ${real_pkgs[*]@Q}" 2>&1 | tee -a "$LOG_FILE"; then
        log OK "'${cat}' packages installed successfully."
        COUNT_INSTALLED=$((COUNT_INSTALLED + ${#to_install[@]}))
    else
        log WARN "Batch install for '${cat}' failed, retrying individually..."
        local i
        for i in "${!to_install[@]}"; do
            local orig="${to_install[$i]}"
            local real="${real_pkgs[$i]}"
            if eval "$install_prefix ${real@Q}" 2>&1 | tee -a "$LOG_FILE"; then
                log OK "  ${orig} (${real}) installed"
                ((COUNT_INSTALLED++))
            else
                log ERROR "  ${orig} (${real}) failed to install"
                FAILED_ITEMS+=("sys:${orig}")
                ((COUNT_FAILED++))
            fi
        done
    fi
}

install_py_category() {
    local cat="$1"
    local pkgs=(${PY_CATEGORIES[$cat]:-})
    local to_install=()

    if [ "${#pkgs[@]}" -eq 0 ]; then
        log WARN "No packages defined for py category '${cat}'"
        return 0
    fi

    section "Python packages: ${cat}"

    for p in "${pkgs[@]}"; do
        if py_pkg_installed "$p"; then
            log INFO "  ${p} already installed, skipping"
            ((COUNT_SKIPPED++))
        else
            to_install+=("$p")
        fi
    done

    if [ "${#to_install[@]}" -eq 0 ]; then
        log OK "All '${cat}' Python packages already present."
        return 0
    fi

    if $DRY_RUN; then
        log INFO "[DRY RUN] Would pip install (${cat}): ${to_install[*]}"
        COUNT_INSTALLED=$((COUNT_INSTALLED + ${#to_install[@]}))
        return 0
    fi

    log INFO "Installing: ${to_install[*]}"
    if pip install --break-system-packages "${to_install[@]}" >>"$LOG_FILE" 2>&1 \
        || pip install "${to_install[@]}" >>"$LOG_FILE" 2>&1; then
        log OK "'${cat}' Python packages installed successfully."
        COUNT_INSTALLED=$((COUNT_INSTALLED + ${#to_install[@]}))
    else
        log WARN "Batch pip install for '${cat}' failed, retrying individually..."
        for p in "${to_install[@]}"; do
            if pip install --break-system-packages "$p" >>"$LOG_FILE" 2>&1 \
                || pip install "$p" >>"$LOG_FILE" 2>&1; then
                log OK "  ${p} installed"
                ((COUNT_INSTALLED++))
            else
                log ERROR "  ${p} failed to install"
                FAILED_ITEMS+=("py:${p}")
                ((COUNT_FAILED++))
            fi
        done
    fi
}

install_all_sys_pkgs() {
    if [ "$PKG_MANAGER" = "unknown" ]; then
        log WARN "No supported package manager detected; skipping system packages"
        return 0
    fi

    local update_cmd
    update_cmd=$(pm_update_cmd)
    if $DRY_RUN; then
        log INFO "[DRY RUN] Would run: ${update_cmd}"
    else
        log INFO "Updating repositories (${PKG_MANAGER})..."
        if [ "$PKG_MANAGER" = "termux" ]; then
            log WARN "Upgrading core packages (bash/libc/termux-tools) can kill this session — that's Termux, not this script. If it happens, just relaunch Termux and re-run; already-updated packages will be skipped."
        fi
        eval "$update_cmd" 2>&1 | tee -a "$LOG_FILE" || log WARN "Repo update/upgrade reported issues, continuing"
    fi

    for cat in "${SYS_CATEGORY_ORDER[@]}"; do
        install_sys_category "$cat"
    done

    if [ "$PKG_MANAGER" = "termux" ] && ! $DRY_RUN; then
        log INFO "Setting up storage access..."
        termux-setup-storage 2>>"$LOG_FILE" || log WARN "termux-setup-storage skipped/failed (non-fatal)"
    fi
}

install_all_py_pkgs() {
    if $DRY_RUN; then
        log INFO "[DRY RUN] Would upgrade pip toolchain"
    else
        log INFO "Upgrading pip toolchain..."
        (python -m pip install --upgrade pip setuptools wheel build cython --break-system-packages \
            || python -m pip install --upgrade pip setuptools wheel build cython) >>"$LOG_FILE" 2>&1
    fi

    for cat in "${PY_CATEGORY_ORDER[@]}"; do
        install_py_category "$cat"
    done
}

setup_dirs() {
    section "Project directories"
    if $DRY_RUN; then
        log INFO "[DRY RUN] Would create: ${PROJECT_DIRS[*]}"
        return 0
    fi
    mkdir -p "${PROJECT_DIRS[@]}"
    log OK "Directories ready: ${PROJECT_DIRS[*]}"
}

setup_aliases() {
    section "Shell aliases"
    if grep -q "# JediSec Settings" "$HOME/.bashrc" 2>/dev/null; then
        log INFO "Aliases already present, skipping."
        return
    fi
    if $DRY_RUN; then
        log INFO "[DRY RUN] Would append JediSec alias block to ~/.bashrc"
        return 0
    fi
    cat >> "$HOME/.bashrc" <<'EOF'

# JediSec Settings
export EDITOR=nano
export PAGER=less
export PATH=$HOME/.local/bin:$PATH
alias ll="ls -lah"
alias gs="git status"
alias py="python"
alias pipup="python -m pip install --upgrade pip"
alias update="pkg update && pkg upgrade -y 2>/dev/null || sudo apt-get update && sudo apt-get upgrade -y"
EOF
    log OK "Aliases added to ~/.bashrc"
}

# ------------------------------------------------------------------
# Self-update (git pull on the script's own repo, if it's in one)
# ------------------------------------------------------------------
self_update() {
    section "Self-update"
    local script_path script_dir
    script_path=$(readlink -f "$0" 2>/dev/null || echo "$0")
    script_dir=$(dirname "$script_path")

    if ! command_exists git; then
        log WARN "git not available, cannot self-update"
        return 1
    fi

    if ! git -C "$script_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        log WARN "Script is not inside a git repo (${script_dir}), skipping self-update"
        return 1
    fi

    if $DRY_RUN; then
        log INFO "[DRY RUN] Would run: git -C ${script_dir} pull"
        return 0
    fi

    log INFO "Pulling latest changes in ${script_dir}..."
    if git -C "$script_dir" pull >>"$LOG_FILE" 2>&1; then
        log OK "Self-update complete. Re-run the script to use the latest version."
    else
        log ERROR "git pull failed, see log for details"
        return 1
    fi
}

# ------------------------------------------------------------------
# Health checks
# ------------------------------------------------------------------
health_check() {
    section "Health Check"
    local pass=0 fail=0

    check() {
        local desc="$1"; shift
        if "$@" >/dev/null 2>&1; then
            log OK "  ${desc}"
            ((pass++))
        else
            log ERROR "  ${desc}"
            ((fail++))
        fi
    }

    check "git available"       command_exists git
    check "python available"    command_exists python
    check "pip available"       command_exists pip
    check "node available"      command_exists node
    check "php available"       command_exists php
    check "sqlite3 available"   command_exists sqlite3
    check "curl available"      command_exists curl
    check "nmap available"      command_exists nmap

    check "python: requests importable"     python -c "import requests"
    check "python: pandas importable"       python -c "import pandas"
    check "python: cryptography importable" python -c "import cryptography"
    check "python: fastapi importable"      python -c "import fastapi"

    local free_kb
    free_kb=$(df "$HOME" 2>/dev/null | awk 'NR==2 {print $4}')
    if [ -n "${free_kb:-}" ] && [ "$free_kb" -lt 512000 ]; then
        log WARN "  Low disk space: $((free_kb / 1024))MB free"
    else
        log OK "  Disk space OK ($((${free_kb:-0} / 1024))MB free)"
        ((pass++))
    fi

    if curl -s --max-time 5 -o /dev/null https://pypi.org; then
        log OK "  Network reachable (pypi.org)"
        ((pass++))
    else
        log WARN "  Network check failed (offline, or pypi.org blocked)"
    fi

    local missing_dirs=0
    for d in "${PROJECT_DIRS[@]}"; do
        [ -d "$d" ] || ((missing_dirs++))
    done
    if [ "$missing_dirs" -eq 0 ]; then
        log OK "  All project directories present"
        ((pass++))
    else
        log WARN "  ${missing_dirs} project directories missing"
    fi

    HEALTH_PASS=$pass
    HEALTH_FAIL=$fail

    if ! $JSON_OUTPUT; then
        echo
        echo -e "${BOLD}Health check: ${GREEN}${pass} passed${NC}, ${RED}${fail} failed${NC}"
    fi
    log INFO "Health check complete: ${pass} passed, ${fail} failed"
}

# ------------------------------------------------------------------
# Summary reports (text + JSON)
# ------------------------------------------------------------------
print_summary() {
    section "Run Summary"
    {
        echo "JediSec Bootstrap run: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "Platform: ${PKG_MANAGER:-unknown} (WSL: ${IS_WSL:-false})"
        echo "Dry run: ${DRY_RUN}"
        echo "Installed: ${COUNT_INSTALLED}"
        echo "Skipped (already present): ${COUNT_SKIPPED}"
        echo "Failed: ${COUNT_FAILED}"
        if [ "${#FAILED_ITEMS[@]}" -gt 0 ]; then
            echo "Failed items:"
            printf '  - %s\n' "${FAILED_ITEMS[@]}"
        fi
        echo "Full log: ${LOG_FILE}"
    } > "$SUMMARY_FILE"

    if ! $JSON_OUTPUT; then
        while IFS= read -r line; do
            echo -e "${CYAN}${line}${NC}"
        done < "$SUMMARY_FILE"
    fi

    write_json_summary
}

write_json_summary() {
    local failed_json="[]"
    if [ "${#FAILED_ITEMS[@]}" -gt 0 ]; then
        failed_json=$(printf '"%s",' "${FAILED_ITEMS[@]}")
        failed_json="[${failed_json%,}]"
    fi

    cat > "$JSON_SUMMARY_FILE" <<JSON
{
  "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "platform": "${PKG_MANAGER:-unknown}",
  "is_wsl": ${IS_WSL:-false},
  "dry_run": ${DRY_RUN},
  "interrupted": ${INTERRUPTED},
  "installed": ${COUNT_INSTALLED},
  "skipped": ${COUNT_SKIPPED},
  "failed": ${COUNT_FAILED},
  "failed_items": ${failed_json},
  "health_pass": ${HEALTH_PASS:-null},
  "health_fail": ${HEALTH_FAIL:-null},
  "log_file": "${LOG_FILE}"
}
JSON

    if $JSON_OUTPUT; then
        cat "$JSON_SUMMARY_FILE"
    fi
}

# ------------------------------------------------------------------
# Signal handling — don't leave the user guessing what landed
# ------------------------------------------------------------------
handle_interrupt() {
    INTERRUPTED=true
    echo
    log WARN "Interrupted by signal — writing partial summary"
    print_summary
    exit 130
}
trap handle_interrupt SIGINT SIGTERM

# ------------------------------------------------------------------
# Bootstrap workflows
# ------------------------------------------------------------------
full_bootstrap() {
    header
    echo -e "${YELLOW}Starting FULL bootstrap...${NC}\n"
    log INFO "Full bootstrap started"

    install_all_sys_pkgs
    install_all_py_pkgs
    setup_dirs
    setup_aliases
    health_check
    print_summary

    if ! $JSON_OUTPUT; then
        echo
        echo -e "${GREEN}${BOLD}Bootstrap completed.${NC}"
        echo "Workspace: $HOME/Projects/JediSec"
        echo -e "${YELLOW}Please restart your shell now.${NC}"
    fi
    pause
}

# ------------------------------------------------------------------
# Category picker submenu
# ------------------------------------------------------------------
category_menu() {
    local kind="$1"
    local -a order
    if [ "$kind" = "sys" ]; then
        order=("${SYS_CATEGORY_ORDER[@]}")
    else
        order=("${PY_CATEGORY_ORDER[@]}")
    fi

    while true; do
        header
        echo -e "${BOLD}Select a category (${kind}):${NC}\n"
        local i=1
        for cat in "${order[@]}"; do
            echo "  ${i}) ${cat}"
            ((i++))
        done
        echo "  a) All categories"
        echo "  b) Back"
        echo
        read -p "Choose: " sel

        if [ "$sel" = "b" ]; then
            return
        elif [ "$sel" = "a" ]; then
            if [ "$kind" = "sys" ]; then
                install_all_sys_pkgs
            else
                install_all_py_pkgs
            fi
            print_summary; pause; return
        elif [[ "$sel" =~ ^[0-9]+$ ]] && [ "$sel" -ge 1 ] && [ "$sel" -le "${#order[@]}" ]; then
            local chosen="${order[$((sel-1))]}"
            if [ "$kind" = "sys" ]; then
                install_sys_category "$chosen"
            else
                install_py_category "$chosen"
            fi
            print_summary; pause
        else
            echo -e "${RED}Invalid choice.${NC}"; sleep 1
        fi
    done
}

# ------------------------------------------------------------------
# CLI usage
# ------------------------------------------------------------------
print_usage() {
    cat <<EOF
JediSec Bootstrap - Installer Framework Edition v2.1

Usage: $0 [options]

  --full                  Run the full bootstrap (sys + py + dirs + aliases + health check)
  --sys=CATEGORY|all      Install one system-package category, or all (${SYS_CATEGORY_ORDER[*]})
                          Note: 'toolchain' (clang/rust/golang/cmake/ninja) is memory-heavy —
                          on low-RAM devices, run it by itself rather than as part of --full.
  --py=CATEGORY|all       Install one Python-package category, or all (${PY_CATEGORY_ORDER[*]})
  --dirs                  Create project directories + shell aliases
  --health-check          Run health check only
  --update-self           Git-pull this script's own repo, if it's in one
  --dry-run               Show what would happen without changing anything
  --json                  Emit a JSON summary to stdout instead of interactive UI
  --help                  Show this message

No flags: launches the interactive menu.
EOF
}

# ------------------------------------------------------------------
# Entry point
# ------------------------------------------------------------------
detect_environment
load_config_override
rotate_logs

if [ "$#" -gt 0 ]; then
    # Non-interactive CLI mode
    RAN_SOMETHING=false
    for arg in "$@"; do
        case "$arg" in
            --dry-run) DRY_RUN=true ;;
            --json)    JSON_OUTPUT=true ;;
        esac
    done

    for arg in "$@"; do
        case "$arg" in
            --help)          print_usage; exit 0 ;;
            --full)          full_bootstrap; RAN_SOMETHING=true ;;
            --sys=*)
                val="${arg#--sys=}"
                if [ "$val" = "all" ]; then
                    install_all_sys_pkgs
                else
                    install_sys_category "$val"
                fi
                RAN_SOMETHING=true ;;
            --py=*)
                val="${arg#--py=}"
                if [ "$val" = "all" ]; then
                    install_all_py_pkgs
                else
                    install_py_category "$val"
                fi
                RAN_SOMETHING=true ;;
            --dirs)          setup_dirs; setup_aliases; RAN_SOMETHING=true ;;
            --health-check)  health_check; RAN_SOMETHING=true ;;
            --update-self)   self_update; RAN_SOMETHING=true ;;
            --dry-run|--json) : ;; # already handled above
            *)
                echo -e "${RED}Unknown option: ${arg}${NC}"
                print_usage
                exit 1 ;;
        esac
    done

    if $RAN_SOMETHING; then
        print_summary
    fi
    exit 0
fi

# ------------------------------------------------------------------
# Interactive Main Menu
# ------------------------------------------------------------------
while true; do
    header
    echo "1) Full Bootstrap (Recommended)"
    echo "2) System Packages (by category)"
    echo "3) Python Packages (by category)"
    echo "4) Directories + Aliases"
    echo "5) Health Check Only"
    echo "6) View Last Run Summary"
    echo "7) Self-Update (git pull this script)"
    echo "8) Toggle Dry Run (currently: $($DRY_RUN && echo ON || echo OFF))"
    echo "9) Exit"
    echo
    read -p "Choose [1-9]: " choice

    case $choice in
        1) full_bootstrap ;;
        2) category_menu sys ;;
        3) category_menu py ;;
        4) setup_dirs; setup_aliases; print_summary; pause ;;
        5) health_check; pause ;;
        6)
            header
            if [ -f "$SUMMARY_FILE" ]; then cat "$SUMMARY_FILE"; else echo -e "${YELLOW}No run summary yet.${NC}"; fi
            pause ;;
        7) self_update; pause ;;
        8) $DRY_RUN && DRY_RUN=false || DRY_RUN=true ;;
        9) echo -e "${GREEN}Goodbye!${NC}"; exit 0 ;;
        *) echo -e "${RED}Invalid choice.${NC}"; sleep 1 ;;
    esac
done
