#!/usr/bin/env bash
# Embody — Cloud Agent install script.
#
# Bootstraps the development experience that can run without Unreal Engine:
#   * Node dependencies for the two Electron example apps and their bundled
#     SignallingWebServers.
#   * A Python virtual environment for the Animation Offset Studio AI server
#     (FastAPI + PyTorch Motion Diffusion Transformer), using the CPU PyTorch
#     build since Cloud Agent VMs have no GPU.
#
# The script is idempotent: it can be re-run against a cached or partial state.
# It never starts long-running services (see terminals in environment.json).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AOS_DIR="$ROOT_DIR/Example Apps/Embody-Animation-Offset-Studio"
CCS_DIR="$ROOT_DIR/Example Apps/Embody-Content-Creator-Studio"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

# ── 1. Node dependencies ──────────────────────────────────────────────────
# Mirrors each app's setup.sh. SignallingWebServer deps are runtime-only.
install_node() {
    local dir="$1"; local mode="$2"; local label="$3"
    if [ ! -f "$dir/package.json" ]; then
        echo "  Skipping $label — no package.json at $dir"
        return 0
    fi
    log "Installing Node deps: $label"
    ( cd "$dir" && npm install $mode --no-audit --no-fund )
}

install_node "$AOS_DIR/signalling" "--omit=dev" "Animation Offset Studio — SignallingWebServer"
install_node "$AOS_DIR"            ""            "Animation Offset Studio — Electron app"
install_node "$CCS_DIR/signalling" "--omit=dev" "Content Creator Studio — SignallingWebServer"
install_node "$CCS_DIR"            ""            "Content Creator Studio — Electron app"

# ── 2. Python animation server ────────────────────────────────────────────
log "Setting up Python animation server (Animation Offset Studio)"

# The default base image ships Python 3.12 without the venv/ensurepip module.
# Install it once so `python3 -m venv` works. Safe to re-run.
if ! python3 -c "import ensurepip" >/dev/null 2>&1; then
    echo "  Installing python3-venv system package"
    sudo apt-get update -qq
    sudo apt-get install -y -qq python3-venv python3.12-venv >/dev/null
fi

VENV_DIR="$AOS_DIR/server_env"
PY_BIN="$VENV_DIR/bin/python"

# Recreate the venv unless it already has a working pip (guards against a
# partially created venv left behind by an interrupted run).
if ! "$PY_BIN" -m pip --version >/dev/null 2>&1; then
    echo "  Creating virtual environment at $VENV_DIR"
    rm -rf "$VENV_DIR"
    python3 -m venv "$VENV_DIR"
fi

"$PY_BIN" -m pip install --upgrade pip --quiet

# Cloud Agent VMs have no NVIDIA GPU. Install the CPU PyTorch build FIRST so the
# transitive `torch` dependency of sentence-transformers is already satisfied
# and pip does not pull the multi-GB default CUDA wheel and CUDA runtime libs.
if ! "$PY_BIN" -c "import torch" 2>/dev/null; then
    echo "  Installing PyTorch (CPU build)"
    "$PY_BIN" -m pip install --quiet torch --index-url https://download.pytorch.org/whl/cpu
fi

echo "  Installing FastAPI / Uvicorn / NumPy / sentence-transformers"
"$PY_BIN" -m pip install --quiet \
    "fastapi>=0.104.0" "uvicorn[standard]>=0.24.0" "numpy>=1.24.0" "sentence-transformers>=2.2.0"

"$PY_BIN" - <<'PYCHECK'
import torch
print(f"  PyTorch {torch.__version__}  |  CUDA available: {torch.cuda.is_available()}")
PYCHECK

# Warm the sentence-transformers text encoder so the server starts instantly and
# works even if the model host is unreachable at runtime. Non-fatal: the server
# falls back to a hash encoder if this cannot complete.
log "Warming text encoder (all-mpnet-base-v2)"
"$PY_BIN" - <<'PYWARM' || echo "  Warm-up skipped (server will fall back to hash encoder)."
from sentence_transformers import SentenceTransformer
SentenceTransformer("all-mpnet-base-v2")
print("  Text encoder cached.")
PYWARM

log "Install complete."
