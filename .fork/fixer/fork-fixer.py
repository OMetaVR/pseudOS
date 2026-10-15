#!/usr/bin/env python3
"""Local fixer for upstream-sync failures (see FORK.md).

Run every few minutes by a systemd user timer (install.sh). When the sync
workflow opens a "needs-ai-fix" issue, this notifies the desktop, starts Claude
Code headless (Opus 5.5, medium effort) in a private clone to fix the merge or
build on sync/upstream, then re-runs the sync workflow, which builds the fix
and only then updates main.

Only issues opened by github-actions and carrying the sync marker are acted on,
so nobody else can start Claude on this machine by filing an issue.
"""

import fcntl
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

REPO = os.environ.get("LC_FORK_REPO", "OMetaVR/LiveContainer")
UPSTREAM_URL = "https://github.com/LiveContainer/LiveContainer.git"
MODEL = os.environ.get("LC_FORK_MODEL", "claude-opus-5-5")
EFFORT = os.environ.get("LC_FORK_EFFORT", "medium")
CLAUDE = os.environ.get("LC_FORK_CLAUDE", str(Path.home() / ".local/bin/claude-selected"))
MAX_ATTEMPTS = 3        # per upstream commit, across conflict and build issues
CLAUDE_TIMEOUT = 90 * 60

HERE = Path(__file__).resolve().parent
STATE_DIR = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "lc-fork-fixer"
CLONE = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "lc-fork-fixer/LiveContainer"
STATE = STATE_DIR / "state.json"
MARKER = re.compile(r"<!-- fork-sync kind=(\w+) upstream=([0-9a-f]{40}) main=([0-9a-f]{40}) run=(\S+) -->")
ALLOWED_TOOLS = [
    "Read", "Edit", "Write", "Glob", "Grep",
    "Bash(git:*)", "Bash(gh issue:*)", "Bash(gh run view:*)", "Bash(gh run list:*)",
    "Bash(ls:*)", "Bash(cat:*)", "Bash(grep:*)", "Bash(plutil:*)", "Bash(python3 -I -c:*)",
]


def log(msg):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), msg, flush=True)


def run(*cmd, cwd=None, check=True):
    p = subprocess.run(cmd, cwd=cwd, text=True, capture_output=True)
    if check and p.returncode:
        raise RuntimeError(f"{' '.join(cmd)} failed:\n{p.stderr.strip()}")
    return p.stdout.strip()


def succeeds(*cmd, cwd=None):
    return subprocess.run(cmd, cwd=cwd, capture_output=True).returncode == 0


def notify(summary, body, urgency="normal"):
    try:
        subprocess.run(["notify-send", "-a", "LiveContainer fork", "-u", urgency, "-i", "github", summary, body],
                       timeout=10)
    except Exception as e:
        log(f"notify-send failed: {e}")


def gh_issue(number, *args):
    run("gh", "issue", *args, str(number), "-R", REPO, check=False)


def load_state():
    try:
        return json.loads(STATE.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {"attempts": {}}


def save_state(state):
    STATE.write_text(json.dumps(state, indent=2))


def prepare_clone():
    if not (CLONE / ".git").exists():
        CLONE.parent.mkdir(parents=True, exist_ok=True)
        run("git", "clone", "-q", f"https://github.com/{REPO}.git", str(CLONE))
        run("git", "remote", "add", "upstream", UPSTREAM_URL, cwd=CLONE)
    run("git", "config", "rerere.enabled", "true", cwd=CLONE)
    run("git", "merge", "--abort", cwd=CLONE, check=False)
    run("git", "fetch", "-q", "--prune", "origin", cwd=CLONE)
    run("git", "fetch", "-q", "upstream", "main", cwd=CLONE)
    has_sync = run("git", "ls-remote", "--heads", "origin", "sync/upstream", cwd=CLONE) != ""
    start = "origin/sync/upstream" if has_sync else "origin/main"
    run("git", "checkout", "-q", "-B", "sync/upstream", start, cwd=CLONE)
    run("git", "reset", "-q", "--hard", start, cwd=CLONE)
    run("git", "clean", "-qfdx", cwd=CLONE)
    return run("git", "rev-parse", "HEAD", cwd=CLONE)


def build_prompt(issue, kind, upstream, run_url):
    template = (HERE / "prompt.md").read_text()
    return (template.replace("{{REPO}}", REPO).replace("{{ISSUE}}", str(issue["number"]))
            .replace("{{TITLE}}", issue["title"]).replace("{{KIND}}", kind)
            .replace("{{UPSTREAM}}", upstream).replace("{{RUN_URL}}", run_url)
            .replace("{{BODY}}", issue["body"]))


def handle(issue, state):
    m = MARKER.search(issue["body"])
    kind, upstream, _main, run_url = m.groups()
    short = upstream[:7]
    attempts = state["attempts"].get(upstream, 0)
    if attempts >= MAX_ATTEMPTS:
        log(f"#{issue['number']}: {attempts} attempts used for {short}, handing to a human")
        gh_issue(issue["number"], "edit", "--remove-label", "needs-ai-fix", "--add-label", "needs-human")
        gh_issue(issue["number"], "comment", "--body",
                 f"The local fixer has tried {attempts} times for upstream `{short}` and is giving up. Needs a human.")
        notify("LiveContainer sync needs you", f"Claude couldn't fix upstream {short} after {attempts} tries "
               f"(issue #{issue['number']}).", "critical")
        return

    state["attempts"][upstream] = attempts + 1
    save_state(state)
    gh_issue(issue["number"], "edit", "--add-label", "ai-fixing")
    notify("LiveContainer upstream sync failed",
           f"{issue['title']}\nStarting Claude ({MODEL}, {EFFORT} effort) to fix it… (attempt {attempts + 1})")

    before = prepare_clone()
    logs = STATE_DIR / "logs"
    logs.mkdir(parents=True, exist_ok=True)
    log_file = logs / f"issue-{issue['number']}-attempt-{attempts + 1}.log"
    cmd = [CLAUDE, "-p", build_prompt(issue, kind, upstream, run_url),
           "--model", MODEL, "--effort", EFFORT,
           "--permission-mode", "acceptEdits", "--allowedTools", *ALLOWED_TOOLS]
    log(f"#{issue['number']}: running Claude in {CLONE}, log {log_file}")
    with open(log_file, "w") as out:
        try:
            code = subprocess.run(cmd, cwd=CLONE, stdout=out, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                  timeout=CLAUDE_TIMEOUT).returncode
        except subprocess.TimeoutExpired:
            code = "timeout"
    log(f"#{issue['number']}: Claude exited with {code}")
    gh_issue(issue["number"], "edit", "--remove-label", "ai-fixing")

    run("git", "fetch", "-q", "origin", cwd=CLONE)
    after = run("git", "rev-parse", "origin/sync/upstream", cwd=CLONE, check=False)
    fixed = bool(after) and after != before and succeeds(
        "git", "merge-base", "--is-ancestor", upstream, "origin/sync/upstream", cwd=CLONE)
    labels = run("gh", "issue", "view", str(issue["number"]), "-R", REPO, "--json", "labels",
                 "-q", "[.labels[].name] | join(\",\")", check=False).split(",")

    if "needs-human" in labels:
        notify("LiveContainer sync needs you", f"Claude couldn't resolve {issue['title']} (#{issue['number']}). "
               f"Log: {log_file}", "critical")
    elif fixed:
        run("gh", "workflow", "run", "sync-upstream.yml", "-R", REPO, check=False)
        notify("LiveContainer fix pushed", f"Claude pushed a fix for upstream {short} to sync/upstream. "
               "The sync workflow is building it; main updates if the build passes.")
    else:
        notify("LiveContainer fix attempt failed", f"Claude finished without pushing a fix for {short} "
               f"(exit {code}). It will retry on the next check. Log: {log_file}", "critical")


def main():
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    lock = open(STATE_DIR / "lock", "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        log("another fixer run is active")
        return
    if not shutil.which("gh"):
        sys.exit("gh not found on PATH")

    issues = json.loads(run("gh", "issue", "list", "-R", REPO, "--state", "open", "--label", "needs-ai-fix",
                            "--json", "number,title,body,author,labels"))
    state = load_state()
    for issue in sorted(issues, key=lambda i: i["number"], reverse=True):  # newest first
        labels = {l["name"] for l in issue["labels"]}
        author = issue["author"]
        if not (author.get("is_bot") or author.get("login") in ("app/github-actions", "github-actions")):
            log(f"#{issue['number']}: not opened by github-actions ({author.get('login')}), ignoring")
            continue
        if not MARKER.search(issue["body"]) or labels & {"ai-fixing", "needs-human"}:
            continue
        handle(issue, state)
        break  # one fix per run; older issues close once the sync succeeds


if __name__ == "__main__":
    main()
