#!/usr/bin/env bash
# forge-kit — one-line installer for the forge JB module family (opencode)
#
#   curl -fsSL <repo>/install.sh | bash                  # install / refresh (idempotent)
#   curl -fsSL <repo>/install.sh | bash -s -- --update   # hot-update modules only
#   curl -fsSL <repo>/install.sh | bash -s -- --uninstall
#
# Windows (PowerShell — native installer, same layout & flags):
#   irm <repo>/install.ps1 | iex                         # install / refresh
#   & ([scriptblock]::Create((irm <repo>/install.ps1))) -Update
#   & ([scriptblock]::Create((irm <repo>/install.ps1))) -List
#   ...or double-click install.cmd (forwards flags, bypasses exec policy)
#
# Local: ./install.sh --from ./modules
#
# Layout:
#   FORGE_HOME (~/.config/opencode/forge)   managed truth: modules/, registry
#   ~/.config/opencode/agent/<name>.md      symlink -> FORGE_HOME/modules/<name>.md
#   ~/.config/opencode/opencode.json        model entries merged (Law-1 pinned)
#
# Both the terminal CLI and the desktop app read ~/.config/opencode — one
# install serves both. Hot-update replaces module files under FORGE_HOME;
# symlinks stay, every NEW opencode session picks up the new spec instantly.

set -euo pipefail

FORGE_HOME="${FORGE_HOME:-$HOME/.config/opencode/forge}"
AGENT_DIR="$HOME/.config/opencode/agent"
CONFIG="$HOME/.config/opencode/opencode.json"
# Resolve HERE only when running from a real script file; `curl | bash` pipes
# have no file, and dirname-of-"bash" would silently resolve to $PWD.
SELF="${BASH_SOURCE[0]:-$0}"
if [ -f "$SELF" ]; then HERE="$(cd "$(dirname "$SELF")" && pwd)"; else HERE=""; fi
# Repo to self-clone from when invoked via `curl | bash` (no local modules/).
# Override with FORGE_REPO env var. Replace <you> after pushing to GitHub.
FORGE_REPO="${FORGE_REPO:-https://github.com/RickSanchez88E/forge-kit.git}"

# module -> (model id | pinned upstream) registry; keep in sync with modules/
DEEPSEEK_MODEL="deepseek/deepseek-v4.1-flash-1017"
DEEPSEEK_PIN="deepinfra/fp8"
QWEN_MODEL="qwen/qwen3.8-max-0902"
QWEN_PIN="alibaba"
MIMO_MODEL="xiaomi/mimo-v2.6-pro"
MIMO_PIN="deepinfra/fp8"

# ---------------------------------------------------------------- helpers ---
say()  { printf '\033[1;32m[forge]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[forge]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[forge]\033[0m %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"; }

# Git Bash / MSYS / Cygwin: bash path is best-effort (symlink + python3 quirks).
# Native Windows installer lives in install.ps1 / install.cmd — point there.
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    warn "Git Bash/MSYS detected - this bash path is best-effort on Windows."
    warn "native installer (PowerShell): irm <repo>/install.ps1 | iex   (or run install.cmd)"
    ;;
esac

backup() { # backup file once per second-granularity
  local f="$1" ts
  ts="$(date +%Y%m%d-%H%M%S)"
  [ -f "$f" ] && cp -p "$f" "$f.bak-$ts" && say "backed up: $(basename "$f") -> $(basename "$f").bak-$ts"
}

# Adopt a module file into FORGE_HOME and symlink it into agent/.
# Existing real files at the symlink target are absorbed (kept as truth),
# foreign symlinks are replaced. Never destroys data.
adopt_module() {
  local name="$1" src="$2"
  local truth="$FORGE_HOME/modules/$name.md"
  local link="$AGENT_DIR/$name.md"

  mkdir -p "$FORGE_HOME/modules" "$AGENT_DIR"

  if [ -f "$src" ]; then
    cp -p "$src" "$truth"
  elif [ -f "$link" ] && [ ! -L "$link" ]; then
    : # no source given but an existing real agent file exists — adopt it below
  else
    warn "no source for $name — skipped"
    return 0
  fi

  # adopt existing real file as truth if we didn't just write one
  if [ ! -f "$truth" ] && [ -f "$link" ] && [ ! -L "$link" ]; then
    mv "$link" "$truth"
  fi
  [ -f "$truth" ] || { warn "no truth for $name — skipped"; return 0; }

  if [ -L "$link" ]; then
    [ "$(readlink "$link")" = "$truth" ] || { rm "$link"; ln -s "$truth" "$link"; }
  elif [ -e "$link" ]; then
    # real file already there — it was copied to truth above (or adopted); replace with symlink
    cmp -s "$link" "$truth" || backup "$link"
    rm -f "$link"; ln -s "$truth" "$link"
  else
    ln -s "$truth" "$link"
  fi
  say "module $name -> $truth (symlinked into agent/)"
}

# ----------------------------------------------------------- config merge ---
merge_models() {
  need python3
  if [ ! -f "$CONFIG" ]; then
    # fresh machine: opencode never ran — create a minimal skeleton so install
    # completes; opencode merges its defaults over this on first run.
    mkdir -p "$(dirname "$CONFIG")"
    printf '{\n  "provider": {\n    "openrouter": {\n      "models": {}\n    }\n  }\n}\n' > "$CONFIG"
    say "created skeleton opencode.json (run opencode once to finish its setup)"
  fi
  python3 - "$CONFIG" "$DEEPSEEK_MODEL" "$DEEPSEEK_PIN" "$QWEN_MODEL" "$QWEN_PIN" "$MIMO_MODEL" "$MIMO_PIN" <<'PY'
import json, sys, os, shutil, datetime

cfg_path, *pairs = sys.argv[1:]
entries = {}
for i in range(0, len(pairs), 2):
    model, pin = pairs[i], pairs[i+1]
    entries[model] = {
        "name": f"{model} (forge pinned {pin})",
        "options": {
            "provider": {"only": [pin], "allow_fallbacks": False},
            "reasoning": {"enabled": True},
        },
    }

with open(cfg_path, encoding="utf-8") as f:
    cfg = json.load(f)

prov = cfg.setdefault("provider", {}).setdefault("openrouter", {})
models = prov.setdefault("models", {})

changed = []
for mid, entry in entries.items():
    if models.get(mid) != entry:
        models[mid] = entry
        changed.append(mid)

if changed:
    ts = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    shutil.copy2(cfg_path, f"{cfg_path}.bak-{ts}")
    print(f"backed up: opencode.json -> opencode.json.bak-{ts}")
    with open(cfg_path, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)
        f.write("\n")

print("merged:" + ",".join(changed) if changed else "merged:none(already current)")
PY
}

# ------------------------------------------------------------------ cmds ---
do_uninstall() {
  for name in deepseek-forge qwen-forge mimo-forge; do
    link="$AGENT_DIR/$name.md"
    if [ -L "$link" ]; then
      rm "$link"
      say "removed symlink $name"
    elif [ -e "$link" ]; then
      warn "$name is a real file (not ours) — left untouched"
    fi
  done
  if [ "${1:-}" = "--purge" ]; then
    rm -rf "$FORGE_HOME" && say "purged $FORGE_HOME"
  else
    say "kept $FORGE_HOME (use --uninstall --purge to remove module truth)"
  fi
  say "model entries left in opencode.json — remove manually if desired"
}

do_list() {
  say "FORGE_HOME: $FORGE_HOME"
  for name in deepseek-forge qwen-forge mimo-forge; do
    link="$AGENT_DIR/$name.md"
    if [ -L "$link" ]; then
      echo "  $name: symlink -> $(readlink "$link") $([ -f "$link" ] && echo '[OK]' || echo '[BROKEN]')"
    elif [ -e "$link" ]; then
      echo "  $name: REAL FILE (not symlink-managed)"
    else
      echo "  $name: not installed"
    fi
  done
}

do_install() {
  local src="${1:-}"
  # source resolution: explicit --from > bundled modules/ next to script > self-clone
  if [ -z "$src" ]; then
    if [ -n "$HERE" ] && [ -d "$HERE/modules" ]; then
      src="$HERE/modules"
    else
      need git
      local tmp; tmp="$(mktemp -d)/forge-kit"
      git clone --depth 1 "$FORGE_REPO" "$tmp" >/dev/null 2>&1 || die "self-clone failed: $FORGE_REPO (set FORGE_REPO or use --from)"
      src="$tmp/modules"
      say "self-cloned from $FORGE_REPO"
    fi
  fi
  # remote source (git URL) support: shallow clone to a temp dir
  if [ "${src#http://}" != "$src" ] || [ "${src#https://}" != "$src" ] || [ "${src#git@}" != "$src" ]; then
    need git
    local tmp; tmp="$(mktemp -d)/forge-src"; rm -rf "${tmp%%/forge-src}"
    git clone --depth 1 "$src" "$tmp" >/dev/null 2>&1 || die "git clone failed: $src"
    src="$tmp"
  fi
  [ -d "$src" ] || die "module source not found: $src"

  adopt_module deepseek-forge "$src/deepseek-forge.md"
  adopt_module qwen-forge     "$src/qwen-forge.md"
  adopt_module mimo-forge     "$src/mimo-forge.md"

  merge_models

  echo
  say "install complete. usage:"
  echo "    in opencode (TUI or app):  @deepseek-forge <task>   (spawn FOREGROUND only)"
  echo "    hot-update:                install.sh --update  (or --from <src>)"
  echo "    status:                    install.sh --list"
}

do_update() {
  # replace module truth under FORGE_HOME; symlinks untouched; new sessions pick it up
  local src="${1:-${HERE:+$HERE/modules}}"
  [ -n "$src" ] || die "no module source — run from a repo checkout or pass --from <src>"
  if [ ! -d "$FORGE_HOME/modules" ]; then die "not installed — run install first"; fi
  for name in deepseek-forge qwen-forge mimo-forge; do
    [ -f "$src/$name.md" ] && cp -p "$src/$name.md" "$FORGE_HOME/modules/$name.md" && say "updated $name"
  done
  say "symlinks untouched — new opencode sessions load the new specs"
}

# ------------------------------------------------------------------ main ----
ACTION="install"; SRC=""   # empty SRC lets do_install self-resolve (local modules/ or self-clone)
while [ $# -gt 0 ]; do
  case "$1" in
    --install)   ACTION="install" ;;
    --update)    ACTION="update" ;;
    --uninstall) ACTION="uninstall" ;;
    --purge)     ACTION="uninstall-purge" ;;
    --list)      ACTION="list" ;;
    --from)      shift; SRC="${1:?--from needs a value}" ;;
    -h|--help)   sed -n '2,21p' "$0"; exit 0 ;;
    *) die "unknown flag: $1" ;;
  esac
  shift
done

case "$ACTION" in
  install)          do_install "$SRC" ;;
  update)           do_update "$SRC" ;;
  uninstall)        do_uninstall ;;
  uninstall-purge)  do_uninstall --purge ;;
  list)             do_list ;;
esac
