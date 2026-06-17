#!/bin/bash
#
# compile-latex.sh — Compile any LaTeX project (zip/folder) locally using Docker
#
# Usage:
#   ./compile-latex.sh [IMAGE_TAG]
#   ./compile-latex.sh texlive/texlive:2025     # pin a specific year tag
#   ./compile-latex.sh --help                    # show help

set -eo pipefail

# ============================================================
# HELP
# ============================================================
for arg in "$@"; do
    if [ "$arg" = "--help" ] || [ "$arg" = "-h" ]; then
        echo ""
        echo "compile-latex.sh — Compile LaTeX projects locally using Docker"
        echo ""
        echo "USAGE"
        echo "  ./compile-latex.sh [IMAGE_TAG]"
        echo ""
        echo "  IMAGE_TAG  Docker image to use (default: texlive/texlive:latest)"
        echo ""
        echo "WHAT IT DOES"
        echo "  1. Accepts a .zip (Overleaf export) or a local folder"
        echo "  2. Detects the LaTeX engine (pdflatex/xelatex/lualatex)"
        echo "  3. Detects bibliography tool (bibtex/biber)"
        echo "  4. Compiles with latexmk inside a texlive Docker container"
        echo "  5. Handles fonts (mounts host fonts, re-asserts after lmodern)"
        echo "  6. Disables babel active shorthands that break XeLaTeX/LuaLaTeX"
        echo ""
        echo "REQUIREMENTS"
        echo "  - Docker"
        echo "  - unzip, sed, grep, find"
        echo ""
        echo "EXAMPLES"
        echo "  ./compile-latex.sh"
        echo "  ./compile-latex.sh texlive/texlive:2025"
        echo ""
        exit 0
    fi
done

# ============================================================
# CONFIG
# ============================================================
DOCKER_IMAGE="${1:-texlive/texlive:latest}"
SUDO_DOCKER=false
EXTRACT_DIR=""

# ============================================================
# TRAP — guarantee no leftover temp dirs
# ============================================================
cleanup() {
    if [ -n "$EXTRACT_DIR" ] && [ -d "$EXTRACT_DIR" ]; then
        rm -rf "$EXTRACT_DIR" 2>/dev/null || true
    fi
}
# INT (Ctrl+C) must exit immediately, not fall through
trap 'cleanup; exit 130' INT
trap cleanup EXIT TERM

# ============================================================
# COLORS & HELPERS
# ============================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { printf "${CYAN}[INFO]${NC}  %s\n" "$*"; }
ok()    { printf "${GREEN}[OK]${NC}    %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
err()   { printf "${RED}[ERR]${NC}   %s\n" "$*"; }
header(){ printf "\n${BOLD}${BLUE}=== %s ===${NC}\n" "$*"; }

# Run docker — with sudo prefix if user isn't in the docker group
docker_cmd() {
    if [ "$SUDO_DOCKER" = true ]; then
        sudo docker "$@"
    else
        docker "$@"
    fi
}

# Check internet connectivity by pinging a reliable host
check_net() {
    # Use curl with a short timeout; fallback to ping if curl missing
    if command -v curl &>/dev/null; then
        curl -s --max-time 5 https://registry-1.docker.io > /dev/null 2>&1
    elif command -v wget &>/dev/null; then
        wget -q --timeout=5 https://registry-1.docker.io > /dev/null 2>&1
    elif command -v ping &>/dev/null; then
        ping -c 1 -W 5 8.8.8.8 > /dev/null 2>&1
    else
        return 0  # can't check, assume yes
    fi
}

# Portable realpath
resolve_path() {
    local p="$1"
    if command -v realpath &>/dev/null; then
        realpath "$p"
    elif command -v readlink &>/dev/null; then
        readlink -f "$p" 2>/dev/null || printf '%s\n' "$p"
    else
        printf '%s\n' "$p"
    fi
}

# Detect distro package manager
detect_pkg_manager() {
    if   command -v apt-get &>/dev/null; then echo "apt"
    elif command -v dnf     &>/dev/null; then echo "dnf"
    elif command -v yum     &>/dev/null; then echo "yum"
    elif command -v pacman  &>/dev/null; then echo "pacman"
    elif command -v zypper  &>/dev/null; then echo "zypper"
    else echo "unknown"
    fi
}

pkg_install_cmd() {
    case "$(detect_pkg_manager)" in
        apt)    echo "sudo apt-get install -y"    ;;
        dnf)    echo "sudo dnf install -y"        ;;
        yum)    echo "sudo yum install -y"        ;;
        pacman) echo "sudo pacman -S --noconfirm" ;;
        zypper) echo "sudo zypper install -y"     ;;
        *)      echo ""                           ;;
    esac
}

docker_pkg_name() {
    case "$(detect_pkg_manager)" in
        apt)    echo "docker.io" ;;
        pacman) echo "docker"    ;;
        zypper) echo "docker"    ;;
        *)      echo ""          ;;
    esac
}

docker_install_hint() {
    case "$(detect_pkg_manager)" in
        apt)    echo "sudo apt-get install -y docker.io"           ;;
        dnf)    echo "See: https://docs.docker.com/engine/install/fedora/" ;;
        yum)    echo "See: https://docs.docker.com/engine/install/centos/" ;;
        pacman) echo "sudo pacman -S --noconfirm docker"           ;;
        zypper) echo "sudo zypper install -y docker"               ;;
        *)      echo "See: https://docs.docker.com/engine/install/" ;;
    esac
}

# Start docker daemon with systemd or sysvinit fallback
start_docker_daemon() {
    if command -v systemctl &>/dev/null; then
        sudo systemctl start docker
    elif command -v service &>/dev/null; then
        sudo service docker start
    else
        err "Cannot start Docker daemon — neither systemctl nor service found."
        return 1
    fi
}

# Enable Docker to start on boot (best-effort)
enable_docker_autostart() {
    if command -v systemctl &>/dev/null; then
        sudo systemctl enable docker 2>/dev/null || true
    fi
}

# Detect system command to open files (xdg-open on Linux, open on macOS)
detect_open_cmd() {
    if command -v xdg-open &>/dev/null; then
        echo "xdg-open"
    elif command -v open &>/dev/null; then
        echo "open"
    else
        echo ""
    fi
}

# ============================================================
# 1. DEPENDENCY CHECK
# ============================================================
header "DEPENDENCY CHECK"

# Basic CLI tools
MISSING=()
for cmd in unzip sed grep find mktemp; do
    command -v "$cmd" &>/dev/null || MISSING+=("$cmd")
done

# File-open command (xdg-open on Linux, open on macOS)
OPEN_CMD="$(detect_open_cmd)"
if [ -n "$OPEN_CMD" ]; then
    HAS_OPEN_CMD=true
else
    HAS_OPEN_CMD=false
fi

if [ ${#MISSING[@]} -gt 0 ]; then
    err "Missing tools: ${MISSING[*]}"
    INSTALL_CMD="$(pkg_install_cmd)"
    if [ -n "$INSTALL_CMD" ]; then
        info "Install with: $INSTALL_CMD ${MISSING[*]}"
    else
        info "Install ${MISSING[*]} using your distro's package manager."
    fi
    exit 1
fi

# Docker binary
if ! command -v docker &>/dev/null; then
    warn "Docker is not installed."
    if ! check_net; then
        err "No internet connection. Cannot install Docker."
        exit 1
    fi
    DOCKER_HINT="$(docker_install_hint)"
    read -r -p "? Install Docker? [Y/n] (will run: $DOCKER_HINT) " ans
    if [[ ! "$ans" =~ ^[Nn] ]]; then
        DOCKER_PKG="$(docker_pkg_name)"
        if [ -n "$DOCKER_PKG" ]; then
            INSTALL_CMD="$(pkg_install_cmd)"
            $INSTALL_CMD $DOCKER_PKG
            enable_docker_autostart
            start_docker_daemon
            ok "Docker installed."
        else
            err "Auto-install not supported on this distro."
            info "$DOCKER_HINT"
            exit 1
        fi
    else
        err "Docker is required. Aborting."
        exit 1
    fi
fi

# Docker daemon reachable? If not, diagnose group & daemon
if docker info &>/dev/null; then
    ok "Docker daemon reachable."
elif groups | grep -q docker; then
    warn "Docker daemon not running."
    read -r -p "? Start Docker daemon? [Y/n] " ans
    if [[ ! "$ans" =~ ^[Nn] ]]; then
        start_docker_daemon
        sleep 2
        docker info &>/dev/null || {
            err "Failed to start Docker daemon."
            exit 1
        }
        ok "Docker daemon started."
    else
        err "Docker daemon required. Aborting."
        exit 1
    fi
else
    warn "User not in docker group."
    read -r -p "? Add to docker group (sudo required)? [Y/n] " ans
    if [[ ! "$ans" =~ ^[Nn] ]]; then
        sudo usermod -aG docker "$USER"
        SUDO_DOCKER=true
        warn "Using 'sudo docker' for this session. Re-login to use docker directly."

        # Start daemon if needed
        docker_cmd info &>/dev/null || {
            start_docker_daemon 2>/dev/null || true
            sleep 2
        }
        docker_cmd info &>/dev/null || {
            err "Cannot reach Docker daemon."
            exit 1
        }
        ok "Docker daemon reachable via sudo."
    else
        err "Docker group membership required. Aborting."
        exit 1
    fi
fi

# Docker image — keep cached, auto-update when a newer version exists
if docker_cmd images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -q "^${DOCKER_IMAGE}$"; then
    ok "Docker image cached."
    if check_net; then
        docker_cmd pull "$DOCKER_IMAGE" > /dev/null 2>&1
        docker_cmd image prune -f > /dev/null 2>&1 || true
    else
        info "Offline — using cached image."
    fi
else
    header "PULL DOCKER IMAGE (~2GB — one-time download)"
    if ! check_net; then
        err "No internet connection. Cannot pull Docker image."
        exit 1
    fi
    echo ""
    read -r -p "? Pull ${DOCKER_IMAGE}? [Y/n] " ans
    if [[ ! "$ans" =~ ^[Nn] ]]; then
        info "Pulling..."
        docker_cmd pull "$DOCKER_IMAGE"
        ok "Image pulled."
    else
        err "Image required. Aborting."
        exit 1
    fi
fi

# ============================================================
# 2. STEP-BY-STEP INPUT
# ============================================================
header "INPUT SETUP"

# Input zip or folder
INPUT=""
while [ -z "$INPUT" ]; do
    read -r -p "? Path to .zip or folder: " INPUT
    INPUT="${INPUT/#\~/$HOME}"
    [ -z "$INPUT" ] && continue
    if [ ! -f "$INPUT" ] && [ ! -d "$INPUT" ]; then
        err "File or folder not found: $INPUT"
        INPUT=""
    elif [ -f "$INPUT" ] && [[ "$INPUT" != *.zip ]]; then
        err "Not a .zip file."
        INPUT=""
    fi
done
ok "Input: $INPUT"

# Output directory (default: same directory as the input)
DEFAULT_OUTDIR="$(dirname "$(resolve_path "$INPUT")")"
read -r -p "? Output directory [enter to use ${DEFAULT_OUTDIR}]: " OUTDIR
OUTDIR="${OUTDIR/#\~/$HOME}"
OUTDIR="${OUTDIR:-$DEFAULT_OUTDIR}"
mkdir -p "$OUTDIR"
OUTDIR="$(resolve_path "$OUTDIR")"
ok "Output: $OUTDIR"

# Output PDF name (default: input basename with .pdf)
INPUT_BASENAME="$(basename "$INPUT")"
INPUT_BASENAME="${INPUT_BASENAME%.zip}"
DEFAULT_PDF_NAME="${INPUT_BASENAME}.pdf"
read -r -p "? Output PDF filename [${DEFAULT_PDF_NAME}]: " PDF_NAME
PDF_NAME="${PDF_NAME:-$DEFAULT_PDF_NAME}"
ok "PDF name: $PDF_NAME"

# Font mounting — host fonts are mounted into the container automatically
# if the directory exists. Font-specific fallbacks are handled after
# project detection (see "Font patching" in section 3).

# ============================================================
# 3. DETECT PROJECT STRUCTURE
# ============================================================
header "PROJECT DETECTION"

EXTRACT_DIR="$(mktemp -d /tmp/overleaf-compile-XXXXXX)"
if [ -f "$INPUT" ]; then
    unzip -o "$INPUT" -d "$EXTRACT_DIR" > /dev/null
    ok "Extracted zip to temp dir."
else
    # Copy contents so cleanup works the same way
    cp -a "$INPUT"/. "$EXTRACT_DIR/"
    ok "Copied folder to temp dir."
fi

# Fix Windows CRLF line endings — Overleaf exports from Windows can have \r\n
# which causes LaTeX errors in Linux containers.
find "$EXTRACT_DIR" \( -name '*.tex' -o -name '*.cls' -o -name '*.sty' -o -name '*.bst' \) \
    -exec sed -i 's/\r$//' {} + 2>/dev/null || true
ok "Normalized line endings (CRLF → LF)."

# Locate root .tex (the one with \documentclass)
ROOT_TEX=""
while IFS= read -r -d '' f; do
    if grep -q '\\documentclass' "$f" 2>/dev/null; then
        ROOT_TEX="$f"
        break
    fi
done < <(find "$EXTRACT_DIR" -name '*.tex' -print0 2>/dev/null)

if [ -z "$ROOT_TEX" ]; then
    err "No .tex file with \\documentclass found."
    exit 1
fi

# Compute relative path inside archive
ROOT_REL="${ROOT_TEX#$EXTRACT_DIR}"
ROOT_REL="${ROOT_REL#/}"
ROOT_DIR="$(dirname "$ROOT_REL")"
ROOT_FILE="$(basename "$ROOT_TEX")"

ok "Root file:  $ROOT_REL"

# Detect LaTeX engine
ENGINE="pdflatex"
if grep -q '\\usepackage.*fontspec' "$ROOT_TEX" 2>/dev/null; then
    if grep -q '\\usepackage.*luatex\|\\usepackage.*luacode\|\directlua' "$ROOT_TEX" 2>/dev/null; then
        ENGINE="lualatex"
    else
        ENGINE="xelatex"
    fi
fi
ok "Engine:  $ENGINE"

# Detect bibliography tool
BIBTOOL="bibtex"
if grep -q '\\usepackage.*biblatex' "$ROOT_TEX" 2>/dev/null; then
    BIBTOOL="biber"
fi
ok "Bibliography:  $BIBTOOL"

# Detect makeindex / nomenclature
NEEDS_MAKEINDEX=false
grep -q '\\makeindex' "$ROOT_TEX" 2>/dev/null && NEEDS_MAKEINDEX=true
grep -q '\\printnomenclature\|\\printglossary' "$ROOT_TEX" 2>/dev/null && NEEDS_MAKEINDEX=true
$NEEDS_MAKEINDEX && ok "Makeindex/nomencl: yes"

# ── Font availability check ────────────────────────────
# Scan for fontspec font commands and check if each
# referenced font is available. Unavailable fonts are
# substituted with safe DejaVu defaults.

FONT_SUBSTITUTED=""  # tracks main serif font for lmodern fix

if command -v fc-list &>/dev/null && [ "$ENGINE" != "pdflatex" ]; then
    FONT_PATCH_CMDS=()
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        cmd="${line%%\{*}"
        name="${line#*\{}"
        name="${name%\}}"
        # Check if font is available on the host
        if ! fc-list "$name" &>/dev/null 2>/dev/null; then
            case "$cmd" in
                *setmonofont*) fallback="DejaVu Sans Mono" ;;
                *setsansfont*) fallback="DejaVu Sans" ;;
                *)             fallback="DejaVu Serif" ;;
            esac
            FONT_PATCH_CMDS+=("$cmd|$name|$fallback")
        fi
    done < <(grep -oE '\\set(main|roman|sans|mono)font\{[^}]+\}' "$ROOT_TEX" 2>/dev/null || true)

    if [ ${#FONT_PATCH_CMDS[@]} -gt 0 ]; then
        echo ""
        warn "Fonts in your document are not available on this system:"
        for entry in "${FONT_PATCH_CMDS[@]}"; do
            IFS='|' read -r cmd original fallback <<< "$entry"
            echo "    • ${original} (used by ${cmd})"
        done
        echo ""
        read -r -p "? Substitute with DejaVu fonts (recommended)? [Y/n] " ans
        if [[ ! "$ans" =~ ^[Nn] ]]; then
            for entry in "${FONT_PATCH_CMDS[@]}"; do
                IFS='|' read -r cmd original fallback <<< "$entry"
                sed -i "s/${cmd}{${original}}/${cmd}{${fallback}}/" "$ROOT_TEX"
                ok "Substituted '$original' → '$fallback'"
                if [ -z "$FONT_SUBSTITUTED" ] && \
                    { [[ "$cmd" == *"setmainfont"* ]] || [[ "$cmd" == *"setromanfont"* ]]; }; then
                    FONT_SUBSTITUTED="$fallback"
                fi
            done
        fi
    fi
fi

# ── Compatibility patches for XeLaTeX/LuaLaTeX ──────────
if [ "$ENGINE" != "pdflatex" ]; then
    # Babel makes " an active shorthand in many languages (French, German,
    # Vietnamese, Catalan, etc.), breaking literal ASCII quotes in the source.
    # Disable " shorthand globally so quotes pass through to the output unchanged.
    if grep -q '^[^%]*\\usepackage\[.*\]{babel}' "$ROOT_TEX" 2>/dev/null; then
        sed -i '/^[^%]*\\usepackage\[.*\]{babel}/a \\\shorthandoff{"}' "$ROOT_TEX"
        ok 'Disabled babel " shorthand (avoids conflicts with literal quotes).'
    fi

    # \usepackage{lmodern} overrides \setmainfont.
    # Re-assert the substituted (or original) main font after lmodern.
    FONT_TO_ASSERT="${FONT_SUBSTITUTED:-Times New Roman}"
    if grep -q '^[^%]*\\usepackage{lmodern}' "$ROOT_TEX" 2>/dev/null; then
        sed -i "/^[^%]*\\usepackage{lmodern}/a \\\\\\setmainfont{$FONT_TO_ASSERT}" "$ROOT_TEX"
        ok "Re-asserted '$FONT_TO_ASSERT' after lmodern override."
    fi
fi

# Build latexmk flag for the chosen engine
LATEXMK_OPTS="-interaction=nonstopmode -f -pdf"
case "$ENGINE" in
    xelatex)  LATEXMK_OPTS="$LATEXMK_OPTS -xelatex" ;;
    lualatex) LATEXMK_OPTS="$LATEXMK_OPTS -lualatex" ;;
esac

# ============================================================
# 4. CONFIRM & COMPILE
# ============================================================
header "CONFIRMATION"

echo ""
echo "  Input:           ${BOLD}$INPUT${NC}"
echo "  Output dir:     ${BOLD}$OUTDIR${NC}"
echo "  Root file:      ${BOLD}$ROOT_REL${NC}"
echo "  Engine:         ${BOLD}$ENGINE${NC}"
echo "  Bibliography:   ${BOLD}$BIBTOOL${NC}"
echo "  Makeindex:      ${BOLD}$NEEDS_MAKEINDEX${NC}"
echo ""

read -r -p "? Start compilation? [Y/n] " ans
if [[ "$ans" =~ ^[Nn] ]]; then
    info "Aborted."
    exit 0
fi

# ── Compile ────────────────────────────────────────────────
header "COMPILING"
echo ""

# Write a small compile script to avoid quoting nightmares
COMPILE_SH="$EXTRACT_DIR/.compile.sh"
LOG_FILE="/data/.logs/compile.log"
cat > "$COMPILE_SH" <<- 'COMPILE_SCRIPT'
	#!/bin/bash
	set -eo pipefail
	ROOT_DIR="$1"
	ROOT_FILE="$2"
	LATEXMK_OPTS="$3"
	LOG_FILE="$4"
	mkdir -p "$(dirname "$LOG_FILE")"
	# Refresh font cache so mounted host fonts are findable
	fc-cache -f 2>/dev/null || true
	cd "/data/$ROOT_DIR"
	echo "  → latexmk $LATEXMK_OPTS $ROOT_FILE"
	latexmk $LATEXMK_OPTS "$ROOT_FILE" 2>&1 | tee "$LOG_FILE"
	RC=${PIPESTATUS[0]}
	if [ $RC -eq 0 ] && [ -f "${ROOT_FILE%.tex}.pdf" ]; then
	    echo ""
	    echo "  Done."
	else
	    echo ""
	    echo "  FAILED (exit $RC)"
	    exit 1
	fi
COMPILE_SCRIPT
chmod +x "$COMPILE_SH"

# Mount host fonts so "Times New Roman" is available in the container
FONT_MOUNT=""
[ -d /usr/share/fonts ] && FONT_MOUNT="-v /usr/share/fonts:/usr/share/fonts:ro"

set +e
docker_cmd run --rm \
    $FONT_MOUNT \
    -v "$EXTRACT_DIR:/data" \
    "$DOCKER_IMAGE" \
    "/data/.compile.sh" \
    "$ROOT_DIR" \
    "$ROOT_FILE" \
    "$LATEXMK_OPTS" \
    "$LOG_FILE"
DOCKER_EXIT=$?
set -eo pipefail

if [ $DOCKER_EXIT -ne 0 ]; then
    err "Compilation failed."
    cp "$EXTRACT_DIR/.logs/compile.log" "$OUTDIR/${PDF_NAME%.pdf}-error.log" 2>/dev/null || true
    info "Error log saved to: ${OUTDIR}/${PDF_NAME%.pdf}-error.log"
    exit 1
fi

ok "Compilation succeeded."

# ── Copy PDF ────────────────────────────────────────────────
TEX_PDF="${ROOT_FILE%.tex}.pdf"
TEX_PDF_SRC="$EXTRACT_DIR/$ROOT_DIR/$TEX_PDF"
if [ "$ROOT_DIR" = "." ]; then
    TEX_PDF_SRC="$EXTRACT_DIR/$TEX_PDF"
fi

cp "$TEX_PDF_SRC" "$OUTDIR/$PDF_NAME"
ok "PDF: ${OUTDIR}/${PDF_NAME}"

# ── Open? ───────────────────────────────────────────────────
echo "Next:"
echo "  [1] Open PDF (default = [Enter])"
echo "  [2] Open PDF folder"
echo "  [3] Exit"
read -r -p "? " ans
ans="${ans:-1}"
case "$ans" in
    1)
        if [ "$HAS_OPEN_CMD" = true ]; then
            $OPEN_CMD "$OUTDIR/$PDF_NAME" &>/dev/null || \
                info "File at: $OUTDIR/$PDF_NAME"
        else
            info "File at: $OUTDIR/$PDF_NAME"
        fi
        ;;
    2)
        if [ "$HAS_OPEN_CMD" = true ]; then
            $OPEN_CMD "$OUTDIR" &>/dev/null || \
                info "Folder: $OUTDIR"
        else
            info "Folder: $OUTDIR"
        fi
        ;;
esac

echo ""
ok "All done."
