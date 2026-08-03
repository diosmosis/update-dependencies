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
# Advisories that have already been IGNORED on GitHub — dismissed by hand in the
# repo's Security tab, or auto-dismissed by GitHub itself — are filtered out of
# that report, so it only shows work that still needs a decision. The count of
# hidden advisories is always printed, so the filtering is never silent. This
# needs the `gh` CLI, authenticated; without it nothing is filtered.
#
# Options:
#   --dry-run   Do everything EXCEPT commit and push. The `update-dependencies`
#               branch is left in place with the changes so you can inspect
#               `git diff` / `git status` yourself.
#   --no-github-ignores
#               Do not consult GitHub — report every outstanding advisory,
#               including ones already dismissed there.
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
USE_GH_FILTER=true   # consult GitHub for advisories already dismissed there
REPOS=()   # explicit repo list from positional args; empty => scan current dir

# Per-repo cache flag for the GitHub alert fetch. process_repo runs its body in a
# subshell, so setting this inside that subshell scopes it to the current repo and
# the next repo starts from `false` again — no explicit reset needed.
ALERTS_FETCHED=false

# --- argument parsing --------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") [--dry-run] [--no-github-ignores] [-h|--help] [repo ...]

  --dry-run   Apply fixes and create the branch, but do NOT commit or push.
  --no-github-ignores
              Report every outstanding advisory, including ones already
              dismissed (or auto-dismissed) on GitHub. By default those are
              hidden from the final report and only counted.
  -h, --help  Show this help.

  repo ...    Optional list of folders to process. When omitted, every folder
              in the current directory that is a git repository is processed.

Examples:
  $(basename "$0")                       # every git repo in the current dir
  $(basename "$0") my-app ../other-app   # only these two repos
  $(basename "$0") --dry-run my-app      # dry run against one repo
  $(basename "$0") --no-github-ignores   # show dismissed advisories too
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=true ;;
        --no-github-ignores) USE_GH_FILTER=false ;;
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
c_dim='\033[2;37m'            # dim grey, for the "hidden advisories" footnote
info() { printf "${c_info}==>${c_reset} %s\n" "$*"; }
ok()   { printf "${c_ok}  ✓${c_reset} %s\n" "$*"; }
warn() { printf "${c_warn}  !${c_reset} %s\n" "$*"; }
err()  { printf "${c_err}  ✗${c_reset} %s\n" "$*"; }

# --- summary counters --------------------------------------------------------
processed=0; pushed=0; skipped=0; failed=0

# Collect breaking-change advisories across all repos here (subshells append to it).
BREAKING_FILE=$(mktemp)
# Advisories suppressed because they are already ignored on GitHub. Only its line
# count is shown, but keeping the lines makes the filtering auditable.
IGNORED_FILE=$(mktemp)
# Scratch space for the current repo's GitHub alerts (rewritten per repo).
ALERTS_FILE=$(mktemp)
cleanup() { rm -f "$BREAKING_FILE" "$IGNORED_FILE" "$ALERTS_FILE"; }
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

# Fetch the advisories this repo has already IGNORED on GitHub: alerts a human
# dismissed in the Security tab, plus the ones GitHub auto-dismissed on its own
# (typically low-impact dev dependencies). Both are states we should not keep
# nagging about, and they are distinct `state` values in the API, so both are
# requested explicitly.
#
# Writes TSV "ecosystem <TAB> package <TAB> ghsa <TAB> cve" to $ALERTS_FILE, once
# per repo. EVERY failure path leaves that file EMPTY, which makes the reporters
# fall back to showing everything — filtering on incomplete data would silently
# hide real advisories, which is far worse than showing a few known ones.
fetch_dismissed_alerts() {
    [ "$ALERTS_FETCHED" = true ] && return 0
    ALERTS_FETCHED=true
    : >"$ALERTS_FILE"

    [ "$USE_GH_FILTER" = true ] || return 1
    command -v gh >/dev/null 2>&1 || return 1

    # Only GitHub remotes have Dependabot alerts to read.
    case "$(git remote get-url origin 2>/dev/null)" in
        *github.com[:/]*) ;;
        *) return 1 ;;
    esac

    # gh expands {owner}/{repo} from the origin remote, so a directory whose name
    # differs from the repo name — or differs only in case — still resolves.
    # --jq is built into gh, so this needs no jq binary and keeps the multi-MB
    # advisory descriptions out of the pipe.
    if ! gh api "repos/{owner}/{repo}/dependabot/alerts?state=dismissed,auto_dismissed&per_page=100" \
            --paginate \
            --jq '.[] | [.dependency.package.ecosystem, .dependency.package.name, .security_advisory.ghsa_id, (.security_advisory.cve_id // "")] | @tsv' \
            >"$ALERTS_FILE" 2>/dev/null; then
        # gh writes the REST error body to STDOUT on failure (e.g. HTTP 403 when
        # Dependabot is disabled for the repo), and a half-finished run leaves a
        # partial page. Either would masquerade as a valid ignore list, so throw
        # the whole thing away rather than trust part of it.
        : >"$ALERTS_FILE"
        warn "could not read GitHub security alerts — reporting all advisories"
        return 1
    fi
    return 0
}

# After applying non-breaking npm fixes, list advisories that still require a
# major (breaking) upgrade, or that have no fix at all. Appends to $BREAKING_FILE.
report_npm_breaking() {
    local repo="$1"
    command -v node >/dev/null 2>&1 || return 0
    fetch_dismissed_alerts
    local json
    json=$(mktemp)
    npm audit --json >"$json" 2>/dev/null
    REPO="$repo" ECOSYSTEM="npm" ALERTS_FILE="$ALERTS_FILE" IGNORED_FILE="$IGNORED_FILE" node -e '
        const fs = require("fs");
        let d;
        try { d = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch (e) { process.exit(0); }
        const repo = process.env.REPO, eco = process.env.ECOSYSTEM;

        // GHSA ids already dismissed / auto-dismissed on GitHub for this repo.
        const ignored = new Set();
        try {
            for (const line of fs.readFileSync(process.env.ALERTS_FILE, "utf8").split("\n")) {
                const f = line.split("\t");
                // Anything that is not a well-formed 4-field row is junk (e.g. a
                // REST error body gh printed to stdout) and must never be able to
                // suppress an advisory.
                if (f.length !== 4) continue;
                if (f[0] === "npm" && f[2]) ignored.add(f[2]);
            }
        } catch (e) { /* no alert data => nothing is ignored */ }

        const vulns = d.vulnerabilities || {};

        // An entry lists its causes in `via`: advisory OBJECTS (this package is
        // itself the subject of the advisory) or STRINGS naming another vulnerable
        // package it depends on. Most entries are string-only — they are flagged
        // purely transitively and carry no GHSA of their own — so we walk the graph
        // to the advisory objects at its roots.
        //
        // Iterative, with a visited set per starting node. `via` can contain cycles,
        // and caching a result computed under a cycle guard would return a
        // too-small root set and silently over-suppress.
        function rootAdvisories(start) {
            const out = new Set();
            const seen = new Set([start]);
            const stack = [start];
            while (stack.length) {
                const node = vulns[stack.pop()];
                if (!node) continue;
                for (const x of (node.via || [])) {
                    if (typeof x === "string") {
                        if (!seen.has(x)) { seen.add(x); stack.push(x); }
                    } else if (x) {
                        const m = x.url && /GHSA-[0-9a-z-]+/.exec(x.url);
                        // No GHSA means nothing to match against GitHub. Record it
                        // as an unmatchable root so this entry can never be
                        // suppressed on the strength of its siblings.
                        out.add(m ? m[0] : "npm-source:" + x.source);
                    }
                }
            }
            return out;
        }

        const lines = [], hidden = [];
        for (const name of Object.keys(vulns)) {
            const v = vulns[name];
            const fa = v.fixAvailable;
            let detail;
            if (fa === false) {
                detail = `${name} (${v.severity}) — no fix available`;
            } else if (fa && typeof fa === "object" && fa.isSemVerMajor) {
                detail = `${name} (${v.severity}) — needs ${fa.name}@${fa.version} (MAJOR / breaking)`;
            } else {
                continue;
            }
            // Suppress only when EVERY root advisory is ignored on GitHub: one
            // still-open root means this package genuinely needs attention. An
            // empty root set is unresolvable, so fail open and report it.
            const roots = rootAdvisories(name);
            const row = `${repo}\t${eco}\t${detail}`;
            if (roots.size > 0 && [...roots].every(g => ignored.has(g))) {
                hidden.push(row);
            } else {
                lines.push(row);
            }
        }
        if (lines.length) fs.writeFileSync(1, lines.join("\n") + "\n");
        if (hidden.length) fs.appendFileSync(process.env.IGNORED_FILE, hidden.join("\n") + "\n");
    ' "$json" >>"$BREAKING_FILE" 2>/dev/null
    rm -f "$json"
}

# List composer advisories that remain after updating within version constraints.
# Anything still reported can only be resolved by a constraint change / major
# upgrade (i.e. a potentially breaking change). Appends to $BREAKING_FILE.
report_composer_breaking() {
    local repo="$1"
    command -v php >/dev/null 2>&1 || return 0
    fetch_dismissed_alerts
    local json
    json=$(mktemp)
    composer audit --no-interaction --format=json >"$json" 2>/dev/null
    REPO="$repo" ALERTS_FILE="$ALERTS_FILE" IGNORED_FILE="$IGNORED_FILE" php -r '
        $repo = getenv("REPO");
        $raw = @file_get_contents($argv[1]);
        $j = json_decode($raw, true);
        if (!is_array($j) || empty($j["advisories"])) exit(0);

        // Advisory ids already dismissed / auto-dismissed on GitHub, composer only.
        $ignoredGhsa = [];
        $ignoredCve  = [];
        $alerts = @file_get_contents(getenv("ALERTS_FILE"));
        if ($alerts !== false) {
            foreach (explode("\n", $alerts) as $line) {
                $f = explode("\t", $line);
                // Skip anything that is not a well-formed 4-field row, so a stray
                // error body can never suppress an advisory.
                if (count($f) !== 4 || $f[0] !== "composer") continue;
                if ($f[2] !== "") $ignoredGhsa[$f[2]] = true;
                if ($f[3] !== "") $ignoredCve[$f[3]]  = true;
            }
        }

        $keep = [];
        $hidden = [];
        foreach ($j["advisories"] as $pkg => $advs) {
            foreach ($advs as $a) {
                $title = isset($a["title"]) ? $a["title"] : "security advisory";
                $sev   = isset($a["severity"]) ? $a["severity"] : "unknown";

                // Composer records the GitHub advisory id under sources[]; prefer
                // it, and fall back to the CVE when this advisory has no GHSA.
                $ghsa = "";
                if (!empty($a["sources"]) && is_array($a["sources"])) {
                    foreach ($a["sources"] as $s) {
                        if (isset($s["name"], $s["remoteId"]) && $s["name"] === "GitHub") $ghsa = $s["remoteId"];
                    }
                }
                $cve = isset($a["cve"]) ? $a["cve"] : "";
                $isIgnored = ($ghsa !== "" && isset($ignoredGhsa[$ghsa]))
                          || ($ghsa === "" && $cve !== "" && isset($ignoredCve[$cve]));

                $line = $repo . "\t" . "composer" . "\t" . $pkg . " (" . $sev . ") — " . $title . " (needs upgrade outside current constraints)\n";
                if ($isIgnored) { $hidden[] = $line; } else { $keep[] = $line; }
            }
        }
        echo implode("", $keep);
        if ($hidden) @file_put_contents(getenv("IGNORED_FILE"), implode("", $hidden), FILE_APPEND);
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

# Report how many advisories the GitHub filter removed. Printed in both the
# "found something" and "all clear" cases on purpose: without it, "nothing is
# wrong" and "everything was filtered out" would look identical.
ignored_note() {
    [ -s "$IGNORED_FILE" ] || return 0
    local n
    n=$(wc -l <"$IGNORED_FILE" | tr -d ' ')
    printf "${c_dim}  (%s advisor%s hidden — already dismissed on GitHub; --no-github-ignores to show)${c_reset}\n" \
        "$n" "$([ "$n" = 1 ] && echo "y" || echo "ies")"
}

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
    ignored_note
else
    ok "No breaking-change advisories left outstanding. 🎉"
    ignored_note
fi
