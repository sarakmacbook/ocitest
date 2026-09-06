#!/usr/bin/env bash
#
# uninstall.sh - Remove OCI Sniper (the app) and/or the OCI resources it created.
#
# Two independent jobs; run either or both:
#   APP  - stop the running app (gunicorn/python), remove .venv/caches, opt-in
#          cleanup of cron entries, Docker container/image, and the repo dir.
#   OCI  - use the OCI CLI to terminate instances created by the app and delete
#          their boot volumes; optionally remove the app's bootstrap VCN.
#
# SAFETY: OCI cleanup only targets resources matching the app's naming patterns
# (see DEFAULT_NAME_PATTERN below), lists everything first, and requires a
# confirmation (or --yes). Nothing is destroyed in --dry-run.
#
# Usage:
#   ./uninstall.sh                      # interactive: choose APP and/or OCI
#   ./uninstall.sh --app-only           # just remove the local app
#   ./uninstall.sh --oci-only           # just clean up OCI resources
#   ./uninstall.sh --all                # both
#   ./uninstall.sh --oci-only --dry-run # show what would be deleted
#   ./uninstall.sh --oci-only --yes     # non-interactive (still lists targets)
#
# Common options:
#   --app-only | --oci-only | --all
#   --dry-run               print actions, change nothing
#   --yes                   skip interactive confirmations (not --dry-run)
#   --port PORT             app port (default 5000)
#   --purge-dir             also delete this repository directory (APP)
#   --cron                  remove crontab lines referencing this repo (APP)
#   --docker                remove matching Docker container/image (APP)
#   --oci-profile PROFILE   OCI CLI config profile (default DEFAULT)
#   --name-pattern REGEX    override instance/boot-volume name match (OCI)
#   --keep-boot-volumes     terminate instances but keep their boot volumes (OCI)
#   --vcn                   also delete app bootstrap VCN/subnet/IGW (OCI)
#   --force-vcn             delete VCN even if it holds unknown resources (OCI)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_NAME="$(basename "$SCRIPT_DIR")"
APP_PORT="${PORT:-5000}"
OCI_PROFILE="DEFAULT"
NAME_PATTERN='^(AlwaysFree-Bot|Resized-Instance|([0-9]{1,3}\.){3}[0-9]{1,3})$'
VCN_NAME="provisioner-vcn"
SUBNET_NAME="provisioner-subnet"
IGW_NAME="provisioner-igw"

MODE_APP=0 MODE_OCI=0
DRY_RUN=0 YES=0 PURGE_DIR=0 CRON=0 DOCKER=0 KEEP_BV=0 VCN=0 FORCE_VCN=0

# ---------------- helpers ----------------
c_reset=$'\033[0m'; c_bold=$'\033[1m'; c_green=$'\033[32m'; c_yellow=$'\033[33m'; c_red=$'\033[31m'; c_cyan=$'\033[36m'
log()   { printf '%s[*]%s %s\n'  "$c_cyan"   "$c_reset" "$*"; }
ok()    { printf '%s[+ ]%s %s\n' "$c_green"  "$c_reset" "$*"; }
warn()  { printf '%s[! ]%s %s\n' "$c_yellow" "$c_reset" "$*"; }
die()   { printf '%s[ERR]%s %s\n' "$c_red" "$c_reset" "$*" >&2; exit 1; }
say()   { printf '%s\n' "$*"; }

is_yes() { case "${1:-}" in y|Y|yes|YES|Yes) return 0;; *) return 1;; esac; }

confirm() {
    local prompt="$1"
    if [ "$YES" -eq 1 ]; then return 0; fi
    printf '%s' "$prompt [y/N] "
    local resp; read -r resp || true
    is_yes "$resp"
}

need() {
    command -v "$1" >/dev/null 2>&1 || die "'$1' not found. $2"
}

usage() { sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# ---------------- argument parsing ----------------
while [ $# -gt 0 ]; do
    case "$1" in
        --app-only) MODE_APP=1;;
        --oci-only) MODE_OCI=1;;
        --all)      MODE_APP=1; MODE_OCI=1;;
        --dry-run)  DRY_RUN=1;;
        --yes|-y)   YES=1;;
        --port)     shift; APP_PORT="${1:?--port needs a value}";;
        --purge-dir) PURGE_DIR=1;;
        --cron)     CRON=1;;
        --docker)   DOCKER=1;;
        --oci-profile) shift; OCI_PROFILE="${1:?--oci-profile needs a value}";;
        --name-pattern) shift; NAME_PATTERN="${1:?--name-pattern needs a value}";;
        --keep-boot-volumes) KEEP_BV=1;;
        --vcn)      VCN=1;;
        --force-vcn) VCN=1; FORCE_VCN=1;;
        -h|--help)  usage; exit 0;;
        *) die "Unknown option: $1  (run with --help)";;
    esac
    shift
done

if [ "$MODE_APP" -eq 0 ] && [ "$MODE_OCI" -eq 0 ]; then
    say ""
    say "OCI Sniper uninstaller — $REPO_NAME"
    say "Found here: $SCRIPT_DIR"
    say ""
    if confirm "1) Remove the app from this machine (stop process, .venv, caches)?"; then MODE_APP=1; fi
    if [ "$MODE_APP" -eq 1 ]; then
        if confirm "   Also remove Docker container/image?"; then DOCKER=1; fi
        if confirm "   Also remove crontab lines referencing this repo?"; then CRON=1; fi
        if confirm "   Also delete the repository directory itself?"; then PURGE_DIR=1; fi
    fi
    if command -v oci >/dev/null 2>&1 && confirm "2) Clean up OCI resources created by the app?"; then MODE_OCI=1; fi
fi

[ "$MODE_APP" -eq 0 ] && [ "$MODE_OCI" -eq 0 ] && { say "Nothing selected — nothing to do."; exit 0; }

[ "$DRY_RUN" -eq 1 ] && warn "DRY RUN — no changes will be made."
[ "$YES" -eq 1 ] && warn "Non-interactive mode: confirmations skipped."

# ================= APP removal =================
if [ "$MODE_APP" -eq 1 ]; then
    say ""
    say "${c_bold}== Removing app from this machine ==${c_reset}"

    # 1. stop the process listening on the app port
    pids=""
    if command -v ss >/dev/null 2>&1; then
        pids="$(ss -ltnp 2>/dev/null | awk -v port=":$APP_PORT" '$4 ~ port { match($0, /pid=[0-9]+/); if (RSTART) print substr($0, RSTART+4, RLENGTH-4) }' | sort -u || true)"
    fi
    if [ -z "$pids" ] && command -v lsof >/dev/null 2>&1; then
        pids="$(lsof -ti tcp:"$APP_PORT" 2>/dev/null || true)"
    fi
    # 2. also catch gunicorn/python running this app by path/pattern
    pids="$pids $(pgrep -f "gunicorn.*app:app" 2>/dev/null || true)"
    pids="$pids $(pgrep -f "$SCRIPT_DIR/app.py" 2>/dev/null || true)"
    pids="$(printf '%s\n' $pids | sed '/^$/d' | sort -u | tr '\n' ' ')"
    if [ -n "$pids" ]; then
        say "Stopping app process(es): $pids"
        if [ "$DRY_RUN" -eq 0 ]; then
            kill -TERM $pids 2>/dev/null || true
            sleep 2
            kill -KILL $pids 2>/dev/null || true
            ok "App processes stopped."
        fi
    else
        say "No running app process found on port $APP_PORT."
    fi

    # 3. docker cleanup (opt-in)
    if [ "$DOCKER" -eq 1 ]; then
        if command -v docker >/dev/null 2>&1; then
            containers="$(docker ps -a --format '{{.Names}} {{.Image}}' 2>/dev/null | grep -Ei 'oci-(sniper|provisioner)' || true)"
            if [ -n "$containers" ]; then
                say "Matching Docker containers:"
                echo "$containers"
                if confirm "Remove these containers?"; then
                    if [ "$DRY_RUN" -eq 0 ]; then
                        echo "$containers" | awk '{print $1}' | xargs -r docker rm -f
                        ok "Containers removed."
                    fi
                fi
            fi
            images="$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -Ei '^oci-(sniper|provisioner)(:|$)' || true)"
            if [ -n "$images" ]; then
                say "Matching Docker images:"
                echo "$images"
                if confirm "Remove Docker image(s)?"; then
                    if [ "$DRY_RUN" -eq 0 ]; then
                        echo "$images" | xargs -r docker rmi -f
                        ok "Images removed."
                    fi
                fi
            fi
        else
            warn "docker not found — skipping Docker cleanup."
        fi
    fi

    # 4. crontab cleanup (opt-in)
    if [ "$CRON" -eq 1 ]; then
        if crontab -l >/dev/null 2>&1; then
            hits="$(crontab -l 2>/dev/null | grep -F "$SCRIPT_DIR" || true)"
            if [ -n "$hits" ]; then
                say "Crontab entries referencing this repo:"
                echo "$hits"
                if confirm "Remove those crontab entries?"; then
                    [ "$DRY_RUN" -eq 0 ] && { crontab -l 2>/dev/null | grep -vF "$SCRIPT_DIR" | crontab - || true; ok "Crontab entries removed."; }
                fi
            fi
        else
            say "No crontab."
        fi
    fi

    # 5. venv / caches / compiled files (always, safe and reversible)
    say "Removing virtualenv and caches (.venv, __pycache__, *.pyc)..."
    if [ "$DRY_RUN" -eq 0 ]; then
        rm -rf "$SCRIPT_DIR/.venv" "$SCRIPT_DIR/venv" "$SCRIPT_DIR/__pycache__" "$SCRIPT_DIR/templates/__pycache__"
        find "$SCRIPT_DIR" -path "$SCRIPT_DIR/.git" -prune -o -name '__pycache__' -type d -print -exec rm -rf {} + 2>/dev/null || true
        find "$SCRIPT_DIR" -path "$SCRIPT_DIR/.git" -prune -o -name '*.pyc' -type f -delete 2>/dev/null || true
        ok "Virtualenv and Python caches removed."
    fi

    # 6. optional full directory purge
    if [ "$PURGE_DIR" -eq 1 ]; then
        warn "This will permanently delete the entire repository at: $SCRIPT_DIR (including .git)."
        if confirm "Delete the repository directory?"; then
            if [ "$DRY_RUN" -eq 0 ]; then
                cd / && rm -rf -- "$SCRIPT_DIR"
                ok "Repository directory removed."
                say "${c_bold}Done — the app is gone from this machine.${c_reset}"
                exit 0
            fi
        else
            say "Skipping directory purge."
        fi
    else
        ok "App removed (source files kept in $SCRIPT_DIR)."
    fi
fi

# ================= OCI cleanup =================
if [ "$MODE_OCI" -eq 1 ]; then
    say ""
    say "${c_bold}== Cleaning up OCI resources created by the app ==${c_reset}"
    need oci "Install the OCI CLI first:  pip install oci-cli  (or https://docs.oracle.com/en-us/iaas/Content/API/SDKDocs/cliinstall.htm). Then configure:  oci setup config"
    need jq "Install jq:  sudo apt-get install -y jq  (or brew install jq)"

    OCI=(oci --config-file "${HOME}/.oci/config" --profile "$OCI_PROFILE")
    [ -f "${HOME}/.oci/config" ] || die "No ~/.oci/config found. Run 'oci setup config' first (or pass --oci-profile with a custom config)."
    # fail fast on bad credentials/config
    "${OCI[@]}" iam region list >/dev/null 2>&1 || die "OCI CLI auth failed (profile '$OCI_PROFILE'). Check ~/.oci/config and run '${OCI[*]} iam region list'."
    TENANCY="$(python3 - "$OCI_PROFILE" <<'PY'
import configparser, os, sys
p = os.path.expanduser('~/.oci/config')
c = configparser.ConfigParser()
c.read(p)
sec = sys.argv[1] if c.has_section(sys.argv[1]) else 'DEFAULT'
print(c.get(sec, 'tenancy', fallback=''))
PY
)"
    # Last resort: ask.
    if [ -z "$TENANCY" ]; then
        read -r -p "Enter your tenancy OCID: " TENANCY || true
    fi
    [ -n "$TENANCY" ] || die "Could not determine the tenancy OCID — pass --oci-profile or set it in ~/.oci/config."

    say "Tenancy: $TENANCY"
    say "Name pattern: ${c_bold}${NAME_PATTERN}${c_reset}"
    warn "Only resources whose display name matches the pattern are targeted."

    # ---- collect instances ----
    instances_json="$("${OCI[@]}" compute instance list -c "$TENANCY" --all --output json 2>/dev/null | jq -c '.data[] | {id, name: ."display-name", state: ."lifecycle-state", ad: ."availability-domain", shape}' || true)"
    mapfile -t INSTANCES < <(printf '%s\n' "$instances_json" | jq -c --arg re "$NAME_PATTERN" 'select(.name | test($re))' 2>/dev/null || true)

    instances_count=${#INSTANCES[@]}
    say ""
    if [ "$instances_count" -gt 0 ]; then
        say "Matching instances ($instances_count):"
        for i in "${INSTANCES[@]}"; do
            say "  - $(jq -r '.name' <<<"$i")  [$(jq -r '.state' <<<"$i")]  $(jq -r '.shape' <<<"$i")"
        done
    else
        say "No instances match the name pattern."
    fi

    # ---- collect matching (detached) boot volumes across ADs ----
    bv_ids=()
    bv_label=()
    declare -A BV_MAP
    for ad in $("${OCI[@]}" iam availability-domain list -c "$TENANCY" --output json 2>/dev/null | jq -r '.data[].name'); do
        while IFS=$'\t' read -r id name state; do
            [ -n "$id" ] || continue
            BV_MAP["$id"]="$name"
            if [[ "$name" =~ ^($NAME_PATTERN)$ ]]; then
                bv_ids+=("$id")
                bv_label+=("$name")
            fi
        done < <("${OCI[@]}" bv boot-volume list -c "$TENANCY" --availability-domain "$ad" --all --output json 2>/dev/null | jq -r '.data[] | [.id, ."display-name", ."lifecycle-state"] | @tsv')
    done
    bv_count=${#bv_ids[@]}
    if [ "$bv_count" -gt 0 ]; then
        say "Matching boot volumes ($bv_count):"
        for n in "${bv_label[@]}"; do say "  - $n"; done
    else
        say "No boot volumes match the name pattern."
    fi

    # ---- VCN / subnet / IGW (opt-in) ----
    vcn_json=""
    if [ "$VCN" -eq 1 ]; then
        vcn_json="$("${OCI[@]}" network vcn list -c "$TENANCY" --output json 2>/dev/null | jq -c --arg n "$VCN_NAME" '.data[] | select(."display-name" == $n) | {id, name: ."display-name"}' | head -1 || true)"
        if [ -n "$vcn_json" ]; then
            VCN_ID="$(jq -r '.id' <<<"$vcn_json")"
            subnets="$("${OCI[@]}" network subnet list -c "$TENANCY" --vcn-id "$VCN_ID" --output json 2>/dev/null | jq -c '.data[] | {id, name: ."display-name"}' || true)"
            non_app_subnets="$(jq -c --arg n "$SUBNET_NAME" 'select(."display-name" != $n)' <<<"$subnets" 2>/dev/null || true)"
            say "App bootstrap VCN found: $(jq -r '.name' <<<"$vcn_json") ($VCN_ID)"
            if [ -n "$non_app_subnets" ] && [ "$FORCE_VCN" -ne 1 ]; then
                warn "VCN contains resources not named '$SUBNET_NAME' — refusing. Use --force-vcn to override."
                vcn_json=""
            fi
        else
            say "No '$VCN_NAME' VCN found (--vcn requested but nothing matched)."
        fi
    fi

    # ---- summary + confirmation ----
    total=$(( instances_count + bv_count ))
    [ "$VCN" -eq 1 ] && [ -n "$vcn_json" ] && total=$(( total + 1 ))
    if [ "$total" -eq 0 ]; then
        say ""
        say "No matching OCI resources to clean up."
        MODE_OCI=0
    else
        say ""
        if ! confirm "${c_bold}Delete $total OCI resource(s) listed above?${c_reset}"; then
            say "Aborted — nothing deleted."
            MODE_OCI=0
        fi
    fi
fi

# ---- execute OCI deletions ----
if [ "$MODE_OCI" -eq 1 ]; then
    [ "$DRY_RUN" -eq 1 ] && { say "(dry run — deletions NOT executed)"; }

    if [ "$instances_count" -gt 0 ]; then
        say ""
        say "Terminating instances..."
        for i in "${INSTANCES[@]}"; do
            id="$(jq -r '.id' <<<"$i")"
            name="$(jq -r '.name' <<<"$i")"
            if [ "$DRY_RUN" -eq 1 ]; then say "  would terminate $name"; continue; fi
            if [ "$KEEP_BV" -eq 1 ]; then
                "${OCI[@]}" compute instance terminate --instance-id "$id" --preserve-boot-volume true --force >/dev/null 2>&1 && ok "terminating $name (boot volume preserved)" || warn "failed to terminate $name"
            else
                "${OCI[@]}" compute instance terminate --instance-id "$id" --preserve-boot-volume false --force >/dev/null 2>&1 && ok "terminating $name (boot volume deleted with it)" || warn "failed to terminate $name"
            fi
        done
    fi

    if [ "$bv_count" -gt 0 ] && [ "$KEEP_BV" -eq 1 ]; then
        warn "--keep-boot-volumes set — skipping boot volume deletion."
    elif [ "$bv_count" -gt 0 ]; then
        say ""
        say "Deleting boot volumes..."
        for idx in "${!bv_ids[@]}"; do
            id="${bv_ids[$idx]}"; name="${bv_label[$idx]}"
            if [ "$DRY_RUN" -eq 1 ]; then say "  would delete $name"; continue; fi
            "${OCI[@]}" bv boot-volume delete --boot-volume-id "$id" --force >/dev/null 2>&1 && ok "deleting boot volume $name" || warn "failed to delete boot volume $name"
        done
    fi

    if [ "$VCN" -eq 1 ] && [ -n "${vcn_json:-}" ]; then
        VCN_ID="$(jq -r '.id' <<<"$vcn_json")"
        say ""
        say "Removing bootstrap VCN ($VCN_NAME)..."
        if [ "$DRY_RUN" -eq 1 ]; then
            say "  would delete subnet(s)/IGW/VCN $VCN_ID"
        else
            for sid in $("${OCI[@]}" network subnet list -c "$TENANCY" --vcn-id "$VCN_ID" --output json 2>/dev/null | jq -r '.data[] | .id'); do
                "${OCI[@]}" network subnet delete --subnet-id "$sid" --force >/dev/null 2>&1 && ok "subnet deleted" || warn "subnet delete failed (still in use?)"
            done
            for gid in $("${OCI[@]}" network internet-gateway list -c "$TENANCY" --vcn-id "$VCN_ID" --output json 2>/dev/null | jq -r '.data[] | .id'); do
                "${OCI[@]}" network internet-gateway delete --ig-id "$gid" --force >/dev/null 2>&1 && ok "internet gateway deleted" || warn "IGW delete failed"
            done
            "${OCI[@]}" network vcn delete --vcn-id "$VCN_ID" --force >/dev/null 2>&1 && ok "VCN deleted" || warn "VCN delete failed (resource still attached?)"
        fi
    fi

    say ""
    ok "OCI cleanup finished."
fi

say ""
say "${c_bold}Done.${c_reset} Use ${c_bold}--dry-run${c_reset} first if you want to preview any uninstall."
