#!/bin/bash
#
# install-claude-skill.sh - Install the /lispeval Claude Code skill.
#
# Copies skills/lispeval/SKILL.md into ~/.claude/skills/lispeval/
# and registers the /lispeval trigger in ~/.claude/CLAUDE.md so new
# Claude Code sessions auto-invoke the skill.
#
# Idempotent: safe to re-run after every update of the source SKILL.md.
#
# Usage:
#   ./install-claude-skill.sh
#   ./install-claude-skill.sh --uninstall   # remove skill + registration
#
# After install, any Claude Code session can run /lispeval to load
# the instructions for driving this eval-server via nc.
#
# The skill expects $EVAL_SERVER_JKF_DIR to point at this directory so
# Claude can resolve paths to es.cl and CLAUDE-EVAL-SERVER-GUIDE.md.
# The installer reminds you to set it at the end.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
SOURCE_SKILL="${SCRIPT_DIR}/skills/lispeval/SKILL.md"

CLAUDE_DIR="${HOME}/.claude"
TARGET_DIR="${CLAUDE_DIR}/skills/lispeval"
TARGET_SKILL="${TARGET_DIR}/SKILL.md"
CLAUDE_MD="${CLAUDE_DIR}/CLAUDE.md"

REG_MARKER="# lispeval"
REG_BLOCK=$(cat <<'EOF'

# lispeval
- **lispeval** (`~/.claude/skills/lispeval/SKILL.md`) - drive jkf's TCP-based Common Lisp eval-server (load/compile/test Lisp code in a running image via nc). Includes hot-reload discipline and load-file footguns. Trigger: `/lispeval`
When the user types `/lispeval`, invoke the Skill tool with `skill: "lispeval"` before doing anything else.
EOF
)

uninstall() {
    if [ -f "${TARGET_SKILL}" ]; then
        rm "${TARGET_SKILL}"
        rmdir "${TARGET_DIR}" 2>/dev/null || true
        echo ">> Removed ${TARGET_SKILL}"
    else
        echo ">> No skill file at ${TARGET_SKILL} (nothing to remove)"
    fi

    if [ -f "${CLAUDE_MD}" ] && grep -qx "${REG_MARKER}" "${CLAUDE_MD}"; then
        # Strip the lispeval registration block (4 lines starting at the marker).
        awk -v marker="${REG_MARKER}" '
            $0 == marker && !skipped {
                # skip the marker line + the next 2 lines (bullet + instruction)
                getline; getline; skipped = 1
                # If the line after the block is blank, skip it too for tidiness
                getline next_line
                if (next_line != "") print next_line
                next
            }
            { print }
        ' "${CLAUDE_MD}" > "${CLAUDE_MD}.tmp" && mv "${CLAUDE_MD}.tmp" "${CLAUDE_MD}"
        echo ">> Removed registration from ${CLAUDE_MD}"
    else
        echo ">> No registration found in ${CLAUDE_MD} (nothing to remove)"
    fi

    echo ""
    echo "Uninstalled. Existing Claude Code sessions may still cache the skill until restart."
}

install() {
    if [ ! -f "${SOURCE_SKILL}" ]; then
        echo "ERROR: ${SOURCE_SKILL} not found." >&2
        echo "       Run this script from the eval-server-jkf checkout root." >&2
        exit 1
    fi

    mkdir -p "${TARGET_DIR}"

    if [ -f "${TARGET_SKILL}" ] && cmp -s "${SOURCE_SKILL}" "${TARGET_SKILL}"; then
        echo ">> ${TARGET_SKILL} already up to date."
    else
        cp "${SOURCE_SKILL}" "${TARGET_SKILL}"
        echo ">> Installed ${TARGET_SKILL}"
    fi

    mkdir -p "${CLAUDE_DIR}"
    touch "${CLAUDE_MD}"

    if grep -qx "${REG_MARKER}" "${CLAUDE_MD}"; then
        echo ">> Registration already present in ${CLAUDE_MD}."
    else
        # Ensure the file ends with a newline before appending.
        if [ -s "${CLAUDE_MD}" ] && [ "$(tail -c 1 "${CLAUDE_MD}")" != "" ]; then
            printf '\n' >> "${CLAUDE_MD}"
        fi
        printf '%s\n' "${REG_BLOCK}" >> "${CLAUDE_MD}"
        echo ">> Registered /lispeval trigger in ${CLAUDE_MD}"
    fi

    echo ""
    echo "Done. Start a new Claude Code session and type /lispeval to load the skill."
    echo ""
    echo "Reminder: set this env var so the skill can resolve paths in this checkout:"
    echo "    export EVAL_SERVER_JKF_DIR=\"${SCRIPT_DIR}\""
    echo ""
    echo "Add it to ~/.bashrc (or equivalent) for persistence."
}

case "${1:-install}" in
    --uninstall|uninstall) uninstall ;;
    --install|install|"") install ;;
    -h|--help)
        sed -n '2,20p' "$0"
        ;;
    *)
        echo "Unknown argument: $1" >&2
        echo "Usage: $0 [--install|--uninstall]" >&2
        exit 2
        ;;
esac
