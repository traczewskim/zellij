#!/usr/bin/env bash
# Install the x1 workspace onto this machine.
# Idempotent. Backs up every file it touches as <file>.bak-<date>.
set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAMP="$(date +%Y%m%d)"

backup() { [ -e "$1" ] && [ ! -e "$1.bak-$STAMP" ] && cp "$1" "$1.bak-$STAMP" && echo "  backed up $1"; true; }
append_once() {   # append_once <file> <marker> <fragment-file>
    grep -qF "$2" "$1" 2>/dev/null && { echo "  already present in $1"; return; }
    backup "$1"; cat "$3" >> "$1"; echo "  appended to $1"
}

echo "==> scripts"
mkdir -p "$HOME/.local/bin"
install -m 755 "$SRC/bin/ccs"       "$HOME/.local/bin/ccs"
install -m 755 "$SRC/bin/ccs-state" "$HOME/.local/bin/ccs-state"
echo "  ~/.local/bin/ccs, ~/.local/bin/ccs-state"

echo "==> layout"
mkdir -p "$HOME/.config/zellij/layouts"
sed "s|__HOME__|$HOME|g" "$SRC/layouts/x1.kdl" > "$HOME/.config/zellij/layouts/x1.kdl"
chmod 644 "$HOME/.config/zellij/layouts/x1.kdl"
echo "  ~/.config/zellij/layouts/x1.kdl (__HOME__ -> $HOME)"

echo "==> plugins"
"$SRC/plugins/fetch-plugins.sh" >/dev/null && echo "  fetched into ~/.config/zellij/plugins/"

echo "==> plugin permissions"
mkdir -p "$HOME/.cache/zellij"
sed "s|__HOME__|$HOME|g" "$SRC/zellij/permissions.kdl" > "$HOME/.cache/zellij/permissions.kdl"
chmod 644 "$HOME/.cache/zellij/permissions.kdl"
echo "  ~/.cache/zellij/permissions.kdl"

echo "==> zellij config"
touch "$HOME/.config/zellij/config.kdl"
append_once "$HOME/.config/zellij/config.kdl" "serialization_interval 60" "$SRC/zellij/config.kdl.fragment"

echo "==> shell alias"
append_once "$HOME/.bashrc" "alias zj=" "$SRC/shell/bashrc.fragment"

echo "==> claude hooks"
python3 - "$SRC/claude/settings.hooks.json" <<'PY'
import json, sys, os, shutil, datetime, collections
frag = json.loads(open(sys.argv[1]).read().replace("__HOME__", os.path.expanduser("~")))["hooks"]
p = os.path.expanduser("~/.claude/settings.json")
os.makedirs(os.path.dirname(p), exist_ok=True)
if os.path.exists(p):
    shutil.copy(p, p + ".bak-" + datetime.date.today().strftime("%Y%m%d"))
    s = json.load(open(p), object_pairs_hook=collections.OrderedDict)
else:
    s = collections.OrderedDict()
s.setdefault("hooks", collections.OrderedDict()).update(frag)
json.dump(s, open(p, "w"), indent=2); open(p, "a").write("\n")
print("  merged", ", ".join(frag), "into ~/.claude/settings.json")
PY

echo
echo "Done. Open a new shell and run: zj"
echo "Already-running Claude panes keep the old behaviour until relaunched."
