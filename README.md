# JediSec Bootstrap

**Installer Framework Edition v2.1**

Modular, category-driven environment manager for **Termux / Linux / WSL2**.

Detects package manager, skips already-installed packages, logs everything, runs post-install health checks, supports non-interactive CLI flags, config overrides, self-update, and JSON summaries.

## Features

- **Cross-PM support**: Termux (`pkg`), Debian/Ubuntu/WSL (`apt`), Fedora (`dnf`), Arch (`pacman`)
- Category-based installs for system packages + Python packages
- Accurate installed detection (including Python import name mapping)
- Dry-run mode
- JSON summary output
- Interactive menu or pure CLI
- Config override via `~/.jedisec/packages.conf`
- Log rotation + run summaries
- Self-update (if the script lives in a git repo)

## Quick Start

```bash
# Clone
git clone https://github.com/jedisecX/jedisec-bootstrap.git
cd jedisec-bootstrap
chmod +x jedisec-bootstrap.sh

# Interactive
./jedisec-bootstrap.sh

# Full non-interactive
./jedisec-bootstrap.sh --full

# Dry run
./jedisec-bootstrap.sh --full --dry-run

# Specific categories
./jedisec-bootstrap.sh --sys=core --py=ai
./jedisec-bootstrap.sh --sys=all --py=all
```

## CLI Options

```
--full                  Full bootstrap (sys + py + dirs + aliases + health)
--sys=CATEGORY|all      System packages (core, dev, toolchain, data, media, network, osint)
--py=CATEGORY|all       Python packages (core, web, data, ai, security, db, osint)
--dirs                  Project directories + aliases
--health-check          Health check only
--update-self           git pull this script's repo
--dry-run               Preview only
--json                  Machine-readable summary
--help
```

## Config Override

Create `~/.jedisec/packages.conf` (plain bash):

```bash
SYS_CATEGORIES[osint]="tesseract-ocr exiftool custom-tool"
PY_CATEGORIES[ai]="openai ollama chromadb anthropic"
```

## Notes

- On Termux, upgrading core packages can kill the current session — just relaunch and re-run.
- `toolchain` category (clang/rust/golang) is memory-heavy; prefer running it alone on low-RAM devices.
- Designed so a fresh box can bootstrap itself before any fancy tools exist.

---

JediSec · https://jedi-sec.com
