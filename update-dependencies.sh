#!/usr/bin/env bash
#
# update-dependencies.sh
#
# Iterates over every git repository in the current directory and, for each one:
#   1. Switches to the repo's default branch
#   2. Pulls with fast-forward only
#   3. Creates (or resets) a branch named `update-dependencies`
#   4. Applies non-breaking `npm audit` fixes   (npm audit fix, WITHOUT --force)
#   5. Applies non-breaking `composer audit` fixes (composer update within constraints)
#   6. Commits with message "update dependencies" and pushes the branch to origin
#
# Advisories that can only be fixed by a BREAKING (major) upgrade are left in
# place and reported, in a high-visibility color, at the end of the run.
#
# Options:
#   --dry-run   Do everything EXCEPT commit and push. The `update-dependencies`
#               branch is left in place with the changes so you can inspect
#               `git diff` / `git status` yourself.
#   -h, --help  Show usage.
#
# Arguments:
#   [repo ...]  One or more folders to process. If none are given, every folder
#               in the current directory that is a git repo is processed.
#
# A failure in one repo is reported and skipped; it does not abort the whole run.

set -u

BRANCH="update-dependencies"
COMMIT_MSG="update dependencies"
DRY_RUN=false
REPOS=()   # explicit repo list from positional args; empty => scan current dir

# --- argument parsing --------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") [--dry-run] [-h|--help] [repo ...]

  --dry-run   Apply fixes and create the branch, but do NOT commit or push.
  -h, --help  Show this help.

  repo ...    Optional list of folders to process. When omitted, every folder
              in the current directory that is a git repository is processed.

Examples:
  $(basename "$0")                       # every git repo in the current dir
  $(basename "$0") my-app ../other-app   # only these two repos
  $(basename "$0") --dry-run my-app      # dry run against one repo
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=true ;;
        -h|--help) usage; exit 0 ;;
        --) shift; while [ $# -gt 0 ]; do REPOS+=("$1"); shift; done; break ;;
        -*) echo "Unknown option: $1" >&2; usage >&2; exit 64 ;;
        *) REPOS+=("$1") ;;
    esac
    shift
done

# --- colored logging helpers -------------------------------------------------
c_reset='\033[0m'; c_info='\033[1;34m'; c_ok='\033[1;32m'; c_warn='\033[1;33m'; c_err='\033[1;31m'
# High-visibility styling reserved for the breaking-change report.
c_break_hdr='\033[1;97;41m'   # bold white text on red background
c_break='\033[1;91m'          # bold bright red
info() { printf "${c_info}==>${c_reset} %s\n" "$*"; }
ok()   { printf "${c_ok}  ✓${c_reset} %s\n" "$*"; }
warn() { printf "${c_warn}  !${c_reset} %s\n" "$*"; }
err()  { printf "${c_err}  ✗${c_reset} %s\n" "$*"; }

# --- summary counters --------------------------------------------------------
processed=0; pushed=0; skipped=0; failed=0

# Collect breaking-change advisories across all repos here (subshells append to it).
BREAKING_FILE=$(mktemp)
cleanup() { rm -f "$BREAKING_FILE"; }
trap cleanup EXIT

# True when $1 is the root of a git repository.
#
# A plain clone has a `.git` DIRECTORY, but a submodule — and a linked worktree —
# has a `.git` FILE containing a `gitdir: …` pointer to the real git dir, so a
# `[ -d "$dir/.git" ]` test silently rejects them. Accept either, then confirm
# with git that the path really is a repository ROOT (`--show-toplevel` matching
# the directory itself), so a random subdirectory of an enclosing repo is not
# mistaken for a repo of its own.
is_git_repo_root() {
    local d="$1" top
    [ -e "$d/.git" ] || return 1
    top=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null) || return 1
    [ -n "$top" ] && [ "$(cd "$d" 2>/dev/null && pwd -P)" = "$(cd "$top" 2>/dev/null && pwd -P)" ]
}

# Determine the default branch for the current repo (via origin/HEAD, with fallbacks).
detect_default_branch() {
    local b
    b=$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')

    # The local origin/HEAD can be STALE — e.g. still pointing at origin/master
    # after the remote renamed its default to main. Trust it only if the branch
    # it names still exists; otherwise refresh the pointer from the remote.
    if [ -z "$b" ] || ! git show-ref --verify --quiet "refs/remotes/origin/$b"; then
        git remote set-head origin --auto >/dev/null 2>&1
        b=$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
    fi

    # Last-resort guess if the remote still didn't give us a usable default.
    if [ -z "$b" ] || ! git show-ref --verify --quiet "refs/remotes/origin/$b"; then
        b=""
        for cand in main master; do
            if git show-ref --verify --quiet "refs/remotes/origin/$cand"; then b="$cand"; break; fi
        done
    fi
    printf '%s' "$b"
}

# After applying non-breaking npm fixes, list advisories that still require a
# major (breaking) upgrade, or that have no fix at all. Appends to $BREAKING_FILE.
report_npm_breaking() {
    local repo="$1"
    command -v node >/dev/null 2>&1 || return 0
    local json
    json=$(mktemp)
    npm audit --json >"$json" 2>/dev/null
    REPO="$repo" ECOSYSTEM="npm" node -e '
        const fs = require("fs");
        let d;
        try { d = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch (e) { process.exit(0); }
        const repo = process.env.REPO, eco = process.env.ECOSYSTEM;
        const vulns = d.vulnerabilities || {};
        const lines = [];
        for (const name of Object.keys(vulns)) {
            const v = vulns[name];
            const fa = v.fixAvailable;
            if (fa === false) {
                lines.push(`${repo}\t${eco}\t${name} (${v.severity}) — no fix available`);
            } else if (fa && typeof fa === "object" && fa.isSemVerMajor) {
                lines.push(`${repo}\t${eco}\t${name} (${v.severity}) — needs ${fa.name}@${fa.version} (MAJOR / breaking)`);
            }
        }
        if (lines.length) fs.writeFileSync(1, lines.join("\n") + "\n");
    ' "$json" >>"$BREAKING_FILE" 2>/dev/null
    rm -f "$json"
}

# List composer advisories that remain after updating within version constraints.
# Anything still reported can only be resolved by a constraint change / major
# upgrade (i.e. a potentially breaking change). Appends to $BREAKING_FILE.
report_composer_breaking() {
    local repo="$1"
    command -v php >/dev/null 2>&1 || return 0
    local json
    json=$(mktemp)
    composer audit --no-interaction --format=json >"$json" 2>/dev/null
    REPO="$repo" php -r '
        $repo = getenv("REPO");
        $raw = @file_get_contents($argv[1]);
        $j = json_decode($raw, true);
        if (!is_array($j) || empty($j["advisories"])) exit(0);
        foreach ($j["advisories"] as $pkg => $advs) {
            foreach ($advs as $a) {
                $title = isset($a["title"]) ? $a["title"] : "security advisory";
                $sev   = isset($a["severity"]) ? $a["severity"] : "unknown";
                echo $repo . "\t" . "composer" . "\t" . $pkg . " (" . $sev . ") — " . $title . " (needs upgrade outside current constraints)\n";
            }
        }
    ' "$json" >>"$BREAKING_FILE" 2>/dev/null
    rm -f "$json"
}

# Run whichever breaking-change reporters apply to the repo in the CURRENT dir.
# Safe to call at any point — it only reads the current audit state, so it can
# remind the user what needs manual intervention even on re-runs that take an
# early-exit shortcut (e.g. a dirty tree left behind by a previous dry run).
report_outstanding_breaking() {
    local repo="$1"
    if [ -f package.json ] && command -v npm >/dev/null 2>&1; then
        report_npm_breaking "$repo"
    fi
    if [ -f composer.json ] && command -v composer >/dev/null 2>&1; then
        report_composer_breaking "$repo"
    fi
}

# Stage ONLY dependency-related changes for the commit. We deliberately avoid
# `git add -A` so that untracked files in the repo (which may include secrets
# such as auth tokens or license keys) are never committed or pushed. Tracked
# lockfile/manifest edits are captured by `git add -u`; a freshly-created
# lockfile that isn't tracked yet is added explicitly by name.
stage_dependency_changes() {
    git add -u || return 1
    local f
    for f in package.json package-lock.json npm-shrinkwrap.json yarn.lock pnpm-lock.yaml composer.json composer.lock; do
        [ -f "$f" ] && git add -- "$f"
    done
    return 0
}

process_repo() {
    local dir="$1"
    local name
    name=$(basename "$dir")
    info "Repo: $name"
    processed=$((processed + 1))

    # Run everything inside a subshell so `cd` stays local to this repo.
    (
        cd "$dir" || { err "cannot cd into $dir"; exit 1; }

        # Handle a dirty working tree. Show the branch name so the user can tell
        # whether these are leftovers from a previous --dry-run or unrelated work.
        # We only treat TRACKED modifications as "dirty":
        #   --ignore-submodules=untracked : a submodule with only untracked content
        #                                   inside it does not count as dirty.
        #   --untracked-files=no          : stray untracked files in the repo (build
        #                                   output, local keys, etc.) don't block us;
        #                                   the commit step never stages them anyway.
        if [ -n "$(git status --porcelain --ignore-submodules=untracked --untracked-files=no)" ]; then
            local cur_branch
            cur_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
            warn "working tree not clean on branch '$cur_branch'"

            if [ "$cur_branch" = "$BRANCH" ]; then
                # Uncommitted changes sitting on our own work branch are almost
                # certainly leftovers from a previous dry run.
                if [ "$DRY_RUN" = false ]; then
                    info "these look like changes from a previous dry run — committing and pushing them"
                    stage_dependency_changes || { err "git add failed"; exit 1; }
                    if git diff --cached --quiet; then
                        warn "no dependency changes staged (only untracked files present) — skipping"
                        exit 3
                    fi
                    git commit -m "$COMMIT_MSG" >/dev/null 2>&1 || { err "git commit failed"; exit 1; }
                    info "pushing $BRANCH to origin"
                    git push --set-upstream origin "$BRANCH" >/dev/null 2>&1 || { err "git push failed"; exit 1; }
                    ok "pushed $BRANCH (changes from a previous dry run)"
                    # Still remind the user what remains needing manual work.
                    report_outstanding_breaking "$name"
                    exit 0
                else
                    warn "changes look like a previous dry run; re-run WITHOUT --dry-run to commit and push them — skipping"
                    # Re-surface outstanding advisories even though we skip the repo.
                    report_outstanding_breaking "$name"
                    exit 2
                fi
            fi

            warn "unrelated changes present — commit, stash, or discard them first — skipping"
            exit 2
        fi

        if ! git remote get-url origin >/dev/null 2>&1; then
            warn "no 'origin' remote — skipping"
            exit 2
        fi

        info "fetching origin"
        git fetch --prune origin >/dev/null 2>&1 || { err "git fetch failed"; exit 1; }

        local default_branch
        default_branch=$(detect_default_branch)
        if [ -z "$default_branch" ]; then
            err "could not determine default branch"
            exit 1
        fi
        info "default branch: $default_branch"

        git checkout "$default_branch" >/dev/null 2>&1 || { err "checkout $default_branch failed"; exit 1; }
        info "pulling (fast-forward only)"
        git pull --ff-only origin "$default_branch" >/dev/null 2>&1 || { err "git pull --ff-only failed"; exit 1; }

        # Create/reset the work branch from the freshly pulled default branch.
        git branch -D "$BRANCH" >/dev/null 2>&1
        git checkout -b "$BRANCH" >/dev/null 2>&1 || { err "could not create branch $BRANCH"; exit 1; }

        # --- npm ------------------------------------------------------------
        if [ -f package.json ]; then
            if command -v npm >/dev/null 2>&1; then
                info "npm: installing then applying non-breaking audit fixes"
                # A lockfile + node_modules are needed for `npm audit fix` to work.
                npm install --no-audit --no-fund >/dev/null 2>&1 || warn "npm install had issues"
                # No --force  => only semver-compatible (non-breaking) updates.
                npm audit fix --no-fund >/dev/null 2>&1 || warn "npm audit fix reported issues"
                ok "npm audit fix complete"
                report_npm_breaking "$name"
            else
                warn "package.json present but npm not installed — skipping npm"
            fi
        fi

        # --- composer -------------------------------------------------------
        if [ -f composer.json ]; then
            if command -v composer >/dev/null 2>&1; then
                info "composer: updating within version constraints (non-breaking)"
                # Composer has no `audit fix`. `composer update` moves dependencies
                # to the newest versions allowed by composer.json's constraints,
                # which (with semver ^/~ constraints) excludes breaking upgrades.
                composer update --with-all-dependencies --no-interaction >/dev/null 2>&1 \
                    || warn "composer update reported issues"
                ok "composer update complete"
                report_composer_breaking "$name"
            else
                warn "composer.json present but composer not installed — skipping composer"
            fi
        fi

        # --- commit & push --------------------------------------------------
        # Stage only dependency changes (never untracked files), then decide
        # whether anything actually changed based on what got staged.
        stage_dependency_changes || { err "git add failed"; exit 1; }

        if git diff --cached --quiet; then
            warn "no dependency changes produced — nothing to commit"
            exit 3
        fi

        if [ "$DRY_RUN" = true ]; then
            warn "[dry-run] dependency changes staged on branch '$BRANCH' but NOT committed or pushed"
            info  "[dry-run] inspect with: (cd $name && git diff --cached)"
            exit 4
        fi

        git commit -m "$COMMIT_MSG" >/dev/null 2>&1 || { err "git commit failed"; exit 1; }
        info "pushing $BRANCH to origin"
        git push --set-upstream origin "$BRANCH" >/dev/null 2>&1 || { err "git push failed"; exit 1; }
        ok "pushed $BRANCH"
        exit 0
    )

    # Translate the subshell's exit code into summary counters.
    case $? in
        0) pushed=$((pushed + 1));   ok "$name: done" ;;
        2) skipped=$((skipped + 1)) ;;
        3) skipped=$((skipped + 1)) ;;
        4) skipped=$((skipped + 1)); ok "$name: dry-run complete (not pushed)" ;;
        *) failed=$((failed + 1));   err "$name: failed" ;;
    esac
    echo
}

# --- main --------------------------------------------------------------------
if [ "$DRY_RUN" = true ]; then
    info "DRY RUN — no commits or pushes will be made."
fi

# Build the list of candidate directories: explicit args, or a scan of $PWD.
candidates=()
if [ ${#REPOS[@]} -gt 0 ]; then
    info "Processing ${#REPOS[@]} folder(s) given on the command line…"
    candidates=("${REPOS[@]}")
else
    info "Scanning $(pwd) for git repositories…"
    shopt -s nullglob
    for entry in */; do
        candidates+=("${entry%/}")
    done
fi
echo

found_any=false
for dir in "${candidates[@]}"; do
    dir="${dir%/}"   # tolerate a trailing slash on supplied paths
    if [ ! -d "$dir" ]; then
        err "not a directory: $dir — skipping"
        failed=$((failed + 1))
        continue
    fi
    if ! is_git_repo_root "$dir"; then
        # An explicitly-named non-repo is worth flagging; a scanned one is just noise.
        if [ ${#REPOS[@]} -gt 0 ]; then
            warn "not a git repository: $dir — skipping"
            skipped=$((skipped + 1))
        fi
        continue
    fi
    found_any=true
    process_repo "$dir"
done

if [ "$found_any" = false ]; then
    if [ ${#REPOS[@]} -gt 0 ]; then
        warn "None of the supplied folders were git repositories."
    else
        warn "No git repositories found in the current directory."
    fi
fi

info "Summary: processed=$processed pushed=$pushed skipped=$skipped failed=$failed"

# --- breaking-change report (high visibility) --------------------------------
echo
if [ -s "$BREAKING_FILE" ]; then
    printf "${c_break_hdr} ⚠  ADVISORIES REQUIRING MANUAL INTERVENTION (breaking/major upgrade or no fix) ${c_reset}\n"
    echo
    # Group the tab-separated "repo <TAB> ecosystem <TAB> detail" lines by repo.
    current_repo=""
    while IFS=$'\t' read -r repo eco detail; do
        [ -z "$repo" ] && continue
        if [ "$repo" != "$current_repo" ]; then
            current_repo="$repo"
            printf "${c_break}▌ %s${c_reset}\n" "$repo"
        fi
        printf "${c_break}    [%s] %s${c_reset}\n" "$eco" "$detail"
    done < "$BREAKING_FILE"
    echo
    printf "${c_break}These were NOT changed — resolving them may require code changes.${c_reset}\n"
else
    ok "No breaking-change advisories left outstanding. 🎉"
fi
