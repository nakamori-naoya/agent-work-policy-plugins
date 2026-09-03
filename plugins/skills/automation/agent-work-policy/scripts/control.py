#!/usr/bin/env python3
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time


ACTIONS = ("commit", "push", "pull_request", "merge")
GATES = {action: f"before_{action}" for action in ACTIONS}


def emit(payload, code=0):
    print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
    raise SystemExit(code)


def command(args, cwd=None, shell=False):
    try:
        return subprocess.run(
            args,
            cwd=cwd,
            shell=shell,
            executable="/bin/bash" if shell else None,
            text=True,
            capture_output=True,
        )
    except FileNotFoundError as exc:
        emit({"error": "必要なcommandが無い", "command": str(exc.filename)}, 2)


def require_success(proc, operation, code=3):
    if proc.returncode:
        emit(
            {
                "status": "failed",
                "operation": operation,
                "exit_code": proc.returncode,
                "stdout": proc.stdout[-4000:].strip(),
                "stderr": proc.stderr[-4000:].strip(),
            },
            code,
        )
    return proc.stdout.strip()


def load_config(path):
    proc = command(["yq", "-o=json", "-I=0", ".", path])
    if proc.returncode:
        emit({"error": "解決済み設定を読めない", "detail": proc.stderr.strip()}, 2)
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        emit({"error": "解決済み設定がJSONへ変換できない", "detail": str(exc)}, 2)


def repo_root(repo):
    proc = command(["git", "-C", repo, "rev-parse", "--show-toplevel"])
    if proc.returncode:
        emit({"error": "git repositoryではない", "repo": repo}, 2)
    return str(Path(proc.stdout.strip()).resolve())


def bound_repo_root(cfg, repo):
    root = repo_root(repo)
    configured = str(Path(cfg.get("repo_root", "")).resolve())
    if configured != root:
        emit({
            "error": "設定と対象repositoryが一致しない",
            "configured_repo_root": configured,
            "repo_root": root,
        }, 2)
    return root


def git(root, *args):
    return command(["git", "-C", root, *args])


def current_branch(root):
    proc = git(root, "branch", "--show-current")
    branch = require_success(proc, "current-branch", 2)
    if not branch:
        emit({"error": "detached HEADでは公開操作できない", "repo": root}, 2)
    return branch


def dirty_changes(root):
    proc = git(root, "status", "--porcelain")
    require_success(proc, "git-status", 2)
    return [line for line in proc.stdout.splitlines() if line]


def worktree_entries(root):
    proc = git(root, "worktree", "list", "--porcelain")
    require_success(proc, "list-worktrees", 2)
    entries = []
    current = {}
    for line in proc.stdout.splitlines() + [""]:
        if not line:
            if current:
                entries.append(current)
                current = {}
            continue
        key, _, value = line.partition(" ")
        current[key] = value
    return entries


def remove_merged_worktree(root, branch):
    target = str(Path(root).resolve())
    entries = worktree_entries(root)
    match = next((item for item in entries if str(Path(item.get("worktree", "")).resolve()) == target), None)
    if match is None:
        return {"deleted": False, "reason": "unregistered_worktree", "worktree": target}
    expected_ref = f"refs/heads/{branch}"
    if match.get("branch") != expected_ref:
        return {
            "deleted": False,
            "reason": "worktree_branch_mismatch",
            "worktree": target,
            "branch": match.get("branch"),
            "expected_branch": expected_ref,
        }
    primary = str(Path(entries[0]["worktree"]).resolve()) if entries else ""
    if not primary or primary == target:
        return {"deleted": False, "reason": "primary_worktree", "worktree": target}
    changes = dirty_changes(target)
    if changes:
        return {"deleted": False, "reason": "dirty_worktree", "worktree": target, "changes": changes}
    proc = git(primary, "worktree", "remove", target)
    if proc.returncode:
        return {
            "deleted": False,
            "reason": "git_worktree_remove_failed",
            "worktree": target,
            "stderr": proc.stderr[-4000:].strip(),
        }
    if Path(target).exists():
        return {"deleted": False, "reason": "worktree_still_exists", "worktree": target}
    return {"deleted": True, "worktree": target}


def validate_branch(cfg, root, branch, require_absent=False):
    check = command(["git", "check-ref-format", "--branch", branch])
    if check.returncode:
        emit({"error": "branch名が不正", "branch": branch}, 2)
    prefix = cfg["workspace"]["branch_prefix"]
    base = cfg["workspace"]["base_branch"]
    if not branch.startswith(prefix):
        emit({"error": "branch_prefix外のbranch", "branch": branch, "required_prefix": prefix}, 2)
    if branch in {base, "main", "master"}:
        emit({"error": "保護branchは作業branchにできない", "branch": branch}, 2)
    if require_absent:
        local = git(root, "show-ref", "--verify", "--quiet", f"refs/heads/{branch}")
        remote_name = cfg["git"]["remote"]
        remote = git(root, "show-ref", "--verify", "--quiet", f"refs/remotes/{remote_name}/{branch}")
        if local.returncode == 0 or remote.returncode == 0:
            emit({"status": "branch_exists", "branch": branch}, 3)


def permission(cfg, action):
    if action not in ACTIONS:
        emit({"error": "未知のaction", "action": action}, 2)
    if not cfg["permissions"][action]:
        emit({"status": "forbidden", "action": action, "allowed": False}, 3)


def gate(cfg, action, approved, context=None):
    key = GATES[action]
    required = cfg["gates"][key]
    if required and not approved:
        payload = {
            "status": "waiting_for_human",
            "action": action,
            "gate": key,
            "required": True,
        }
        if context:
            payload["context"] = context
        emit(payload, 3)


def base_exists(cfg, root):
    base = cfg["workspace"]["base_branch"]
    proc = git(root, "show-ref", "--verify", "--quiet", f"refs/heads/{base}")
    if proc.returncode:
        emit({"error": "local base branchが無い", "base_branch": base}, 2)


def workspace_plan(cfg, repo, branch):
    root = bound_repo_root(cfg, repo)
    validate_branch(cfg, root, branch, require_absent=True)
    base_exists(cfg, root)
    use_worktree = cfg["workspace"]["use_worktree"]
    dirty = dirty_changes(root)
    if cfg["workspace"]["require_clean_start"] and dirty:
        emit(
            {
                "status": "dirty_start",
                "mode": "worktree" if use_worktree else "branch",
                "changes": dirty,
            },
            3,
        )
    return {
        "status": "ready",
        "mode": "worktree" if use_worktree else "branch",
        "repo_root": root,
        "base_branch": cfg["workspace"]["base_branch"],
        "branch": branch,
        "remote": cfg["git"]["remote"],
        "worktree_root": cfg["workspace"]["worktree_root"],
        "source_dirty": bool(dirty),
    }


def start_workspace(cfg, repo, branch):
    plan = workspace_plan(cfg, repo, branch)
    root = plan["repo_root"]
    base = plan["base_branch"]
    if plan["mode"] == "branch":
        proc = git(root, "switch", "-c", branch, base)
        require_success(proc, "create-branch")
        plan["status"] = "created"
        plan["worktree"] = root
        return plan

    configured_root = cfg["workspace"]["worktree_root"]
    temporary = not configured_root
    if temporary:
        worktree = tempfile.mkdtemp(prefix="agent-work-")
    else:
        parent = Path(configured_root)
        parent.mkdir(parents=True, exist_ok=True)
        name = re.sub(r"[^A-Za-z0-9._-]+", "-", branch).strip("-")
        worktree = str(parent / name)
        if Path(worktree).exists():
            emit({"status": "worktree_exists", "worktree": worktree}, 3)
    proc = git(root, "worktree", "add", "-b", branch, worktree, base)
    if proc.returncode:
        if temporary:
            try:
                Path(worktree).rmdir()
            except OSError:
                pass
        require_success(proc, "create-worktree")
    plan["status"] = "created"
    plan["worktree"] = str(Path(worktree).resolve())
    return plan


def safe_paths(root, paths_file):
    try:
        raw = Path(paths_file).read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        emit({"error": "paths fileを読めない", "detail": str(exc)}, 2)
    paths = [line.strip() for line in raw if line.strip()]
    if not paths:
        emit({"error": "commit対象pathが空"}, 2)
    root_path = Path(root).resolve()
    for item in paths:
        candidate = Path(item)
        if candidate.is_absolute() or ".." in candidate.parts or item == ".git" or item.startswith(".git/"):
            emit({"error": "repository外または.gitはcommit対象にできない", "path": item}, 2)
        resolved = (root_path / candidate).resolve()
        try:
            resolved.relative_to(root_path)
        except ValueError:
            emit({"error": "repository外はcommit対象にできない", "path": item}, 2)
    return paths


def run_verification(cfg, root):
    results = []
    for item in cfg["verification"]["commands"]:
        proc = command(item, cwd=root, shell=True)
        result = {"command": item, "exit_code": proc.returncode}
        results.append(result)
        if proc.returncode:
            result["stdout"] = proc.stdout[-4000:].strip()
            result["stderr"] = proc.stderr[-4000:].strip()
            emit({"status": "verification_failed", "results": results}, 3)
    return results


def safe_current_branch(cfg, root):
    branch = current_branch(root)
    validate_branch(cfg, root, branch)
    return branch


def gh_json(args, root, operation):
    if not shutil.which("gh"):
        emit({"error": "ghが無い", "operation": operation}, 2)
    proc = command(["gh", *args], cwd=root)
    output = require_success(proc, operation)
    try:
        return json.loads(output)
    except json.JSONDecodeError as exc:
        emit({"error": "ghのJSONを読めない", "operation": operation, "detail": str(exc)}, 2)


def pull_request_state(cfg, root, pr_number, branch=None):
    view = gh_json(
        [
            "pr", "view", str(pr_number), "--json",
            "number,state,mergedAt,isDraft,mergeable,mergeStateStatus,headRefName,headRefOid,headRepositoryOwner,headRepository,baseRefName,baseRefOid,statusCheckRollup,reviews,url",
        ],
        root,
        "pull-request-state",
    )
    return {
        "view": view,
        "pr_number_matches": view.get("number") == pr_number,
        "head_branch_matches": branch is None or view.get("headRefName") == branch,
        "base_branch_matches": view.get("baseRefName") == cfg["workspace"]["base_branch"],
    }


def repository_name(root):
    data = gh_json(["repo", "view", "--json", "nameWithOwner"], root, "repository-name")
    return data["nameWithOwner"]


def repository_info(cfg, root):
    data = gh_json(["repo", "view", "--json", "id,nameWithOwner,sshUrl,url"], root, "repository-identity")
    remote_url = require_success(git(root, "remote", "get-url", cfg["git"]["remote"]), "remote-url", 2)
    candidates = {data.get("sshUrl"), data.get("url"), f"{data.get('url')}.git"}
    if remote_url not in candidates:
        match = re.search(r"github\.com[:/]([^/]+)/([^/]+?)(?:\.git)?$", remote_url)
        remote_name = f"{match.group(1)}/{match.group(2)}" if match else None
        if not remote_name or remote_name.lower() != str(data.get("nameWithOwner", "")).lower():
            emit({
                "error": "GitHub対象とgit remoteが一致しない",
                "github_repository": data.get("nameWithOwner"),
                "remote": cfg["git"]["remote"],
                "remote_url": remote_url,
            }, 2)
    return data


ZERO_OID = "0000000000000000000000000000000000000000"


def atomic_update_refs(root, repository_id, updates, operation):
    rendered = ",".join(
        "{"
        f"name:{json.dumps(item['name'])},"
        f"beforeOid:{json.dumps(item['before'])},"
        f"afterOid:{json.dumps(item['after'])},"
        "force:false"
        "}"
        for item in updates
    )
    query = (
        "mutation { updateRefs(input:{"
        f"repositoryId:{json.dumps(repository_id)},"
        f"refUpdates:[{rendered}]"
        "}) { clientMutationId } }"
    )
    proc = command(["gh", "api", "graphql", "-f", f"query={query}"], cwd=root)
    if proc.returncode:
        return {
            "ok": False,
            "operation": operation,
            "exit_code": proc.returncode,
            "stdout": proc.stdout[-4000:].strip(),
            "stderr": proc.stderr[-4000:].strip(),
        }
    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        return {"ok": False, "operation": operation, "detail": str(exc)}
    if not ((data.get("data") or {}).get("updateRefs")):
        return {"ok": False, "operation": operation, "result": data}
    return {"ok": True}


def approval_count(reviews):
    latest = {}
    for review in reviews or []:
        author = (review.get("author") or {}).get("login")
        if not author:
            continue
        submitted = review.get("submittedAt") or ""
        previous = latest.get(author)
        if previous is None or submitted >= (previous.get("submittedAt") or ""):
            latest[author] = review
    return sum(1 for review in latest.values() if review.get("state") == "APPROVED")


def required_check_names(root, repo_name, base):
    data = gh_json(
        ["api", f"repos/{repo_name}/branches/{base}/protection/required_status_checks"],
        root,
        "required-status-checks",
    )
    return {
        item
        for item in [
            *(data.get("contexts") or []),
            *((check or {}).get("context") for check in (data.get("checks") or [])),
        ]
        if item
    }


def checks_passed(checks, required_names):
    if not required_names:
        return False
    successful = set()
    for item in checks or []:
        conclusion = str(item.get("conclusion") or item.get("state") or "").upper()
        if conclusion == "SUCCESS":
            name = item.get("name") or item.get("context")
            if name:
                successful.add(name)
    return required_names <= successful


def unresolved_threads(root, repo_name, pr_number):
    owner, name = repo_name.split("/", 1)
    query = """
query($owner:String!,$name:String!,$number:Int!){
  repository(owner:$owner,name:$name){
    pullRequest(number:$number){
      reviewThreads(first:100){nodes{isResolved} pageInfo{hasNextPage}}
    }
  }
}
"""
    data = gh_json(
        [
            "api", "graphql", "-f", f"query={query}", "-F", f"owner={owner}",
            "-F", f"name={name}", "-F", f"number={pr_number}",
        ],
        root,
        "review-threads",
    )
    threads = data["data"]["repository"]["pullRequest"]["reviewThreads"]
    if threads["pageInfo"]["hasNextPage"]:
        emit({"error": "review threadが100件を超え、readinessを確定できない"}, 2)
    return sum(1 for item in threads["nodes"] if not item["isResolved"])


def merge_readiness(cfg, root, pr_number):
    info = repository_info(cfg, root)
    state = pull_request_state(cfg, root, pr_number)
    view = state["view"]
    expected_repo = info["nameWithOwner"]
    expected_owner = expected_repo.split("/", 1)[0]
    head_repository = view.get("headRepository") or {}
    head_owner = view.get("headRepositoryOwner") or {}
    reasons = []
    approvals = approval_count(view.get("reviews"))
    required = cfg["merge"]["readiness"]
    if view.get("isDraft"):
        reasons.append("draft")
    if view.get("state") != "OPEN":
        reasons.append(f"state:{view.get('state')}")
    if view.get("mergeable") != "MERGEABLE":
        reasons.append(f"mergeable:{view.get('mergeable')}")
    if view.get("mergeStateStatus") != "CLEAN":
        reasons.append(f"merge_state:{view.get('mergeStateStatus')}")
    if not state["base_branch_matches"]:
        reasons.append("base_branch_mismatch")
    if (
        head_repository.get("nameWithOwner") != expected_repo
        or head_owner.get("login") != expected_owner
    ):
        reasons.append("cross_repository")
    if approvals < required["min_approvals"]:
        reasons.append("approvals")
    required_names = required_check_names(root, expected_repo, view.get("baseRefName")) if required["require_checks_passed"] else set()
    passed = checks_passed(view.get("statusCheckRollup"), required_names) if required["require_checks_passed"] else True
    if required["require_checks_passed"] and not passed:
        reasons.append("checks")
    unresolved = None
    if required["require_no_unresolved_threads"]:
        unresolved = unresolved_threads(root, repository_name(root), pr_number)
        if unresolved:
            reasons.append("unresolved_threads")
    return {
        "status": "ready" if not reasons else "not_ready",
        "pr": pr_number,
        "url": view.get("url"),
        "head_branch": view.get("headRefName"),
        "head_sha": view.get("headRefOid"),
        "base_branch": view.get("baseRefName"),
        "base_sha": view.get("baseRefOid"),
        "approvals": approvals,
        "required_approvals": required["min_approvals"],
        "checks_passed": passed,
        "required_checks": sorted(required_names),
        "unresolved_threads": unresolved,
        "reasons": reasons,
    }


def do_commit(cfg, args):
    root = bound_repo_root(cfg, args.repo)
    permission(cfg, "commit")
    branch = safe_current_branch(cfg, root)
    paths = safe_paths(root, args.paths_file)
    changes = git(root, "status", "--porcelain", "--", *paths)
    require_success(changes, "inspect-commit-paths", 2)
    if not changes.stdout.strip():
        emit({"status": "no_changes", "action": "commit", "paths": paths}, 3)
    verification = run_verification(cfg, root)
    gate(cfg, "commit", args.approved, {"branch": branch, "paths": paths, "verification": verification})
    require_success(git(root, "add", "--", *paths), "stage")
    if git(root, "diff", "--cached", "--quiet").returncode == 0:
        emit({"status": "no_staged_changes", "action": "commit"}, 3)
    require_success(git(root, "commit", "-m", args.message), "commit")
    sha = require_success(git(root, "rev-parse", "HEAD"), "commit-sha", 2)
    emit({"status": "committed", "action": "commit", "branch": branch, "sha": sha, "paths": paths})


def do_push(cfg, args):
    root = bound_repo_root(cfg, args.repo)
    permission(cfg, "push")
    branch = safe_current_branch(cfg, root)
    sha = require_success(git(root, "rev-parse", "HEAD"), "head-sha", 2)
    gate(cfg, "push", args.approved, {"branch": branch, "sha": sha, "remote": cfg["git"]["remote"]})
    require_success(git(root, "push", "-u", cfg["git"]["remote"], branch), "push")
    emit({"status": "pushed", "action": "push", "branch": branch, "sha": sha, "remote": cfg["git"]["remote"]})


def do_pull_request(cfg, args):
    root = bound_repo_root(cfg, args.repo)
    permission(cfg, "pull_request")
    branch = safe_current_branch(cfg, root)
    gate(cfg, "pull_request", args.approved, {"branch": branch, "base": cfg["workspace"]["base_branch"], "title": args.title})
    repository_info(cfg, root)
    cmd = [
        "pr", "create", "--base", cfg["workspace"]["base_branch"], "--head", branch,
        "--title", args.title, "--body-file", args.body_file,
    ]
    if cfg["pull_request"]["draft"]:
        cmd.append("--draft")
    if not shutil.which("gh"):
        emit({"error": "ghが無い", "operation": "pull-request"}, 2)
    proc = command(["gh", *cmd], cwd=root)
    url = require_success(proc, "pull-request")
    emit({"status": "created", "action": "pull_request", "branch": branch, "url": url})


def do_ready_for_review(cfg, args):
    root = bound_repo_root(cfg, args.repo)
    permission(cfg, "pull_request")
    repository_info(cfg, root)
    branch = safe_current_branch(cfg, root)
    state = pull_request_state(cfg, root, args.pr, branch)
    view = state["view"]
    result = {
        "action": "pull_request",
        "pr": args.pr,
        "url": view.get("url"),
        "head_branch": view.get("headRefName"),
        "base_branch": view.get("baseRefName"),
    }
    if not state["pr_number_matches"]:
        emit({"status": "failed", **result, "reason": "pr_number_mismatch"}, 3)
    if not state["head_branch_matches"]:
        emit({"status": "failed", **result, "reason": "head_branch_mismatch", "expected_head_branch": branch}, 3)
    expected_base = cfg["workspace"]["base_branch"]
    if not state["base_branch_matches"]:
        emit({"status": "failed", **result, "reason": "base_branch_mismatch", "expected_base_branch": expected_base}, 3)
    if not view.get("isDraft"):
        emit({"status": "ready", **result, "changed": False})
    proc = command(["gh", "pr", "ready", str(args.pr)], cwd=root)
    require_success(proc, "ready-for-review")
    emit({"status": "ready", **result, "changed": True})


def fast_forward_merge(cfg, root, ready, branch):
    remote = cfg["git"]["remote"]
    base = ready["base_branch"]
    head_sha = ready["head_sha"]
    base_sha = ready["base_sha"]
    local_head = require_success(git(root, "rev-parse", "HEAD"), "head-sha", 2)
    if branch != ready["head_branch"] or local_head != head_sha:
        emit({
            "status": "merge_failed",
            "action": "merge",
            "reason": "local_head_mismatch",
            "branch": branch,
            "local_head_sha": local_head,
            "pr_head_branch": ready["head_branch"],
            "pr_head_sha": head_sha,
        }, 3)
    refs = {
        f"refs/heads/{ready['head_branch']}": None,
        f"refs/heads/{base}": None,
    }
    probe = git(root, "ls-remote", "--heads", remote, *refs)
    if probe.returncode:
        emit({
            "status": "merge_failed",
            "action": "merge",
            "reason": "remote_ref_lookup_failed",
            "stderr": probe.stderr[-4000:].strip(),
        }, 3)
    for line in probe.stdout.splitlines():
        sha, _, ref = line.partition("\t")
        if ref in refs:
            refs[ref] = sha
    remote_head = refs[f"refs/heads/{ready['head_branch']}"]
    remote_base = refs[f"refs/heads/{base}"]
    if remote_head != head_sha:
        emit({
            "status": "merge_failed",
            "action": "merge",
            "reason": "remote_head_mismatch",
            "remote_head_sha": remote_head,
            "pr_head_sha": head_sha,
        }, 3)
    if remote_base != base_sha:
        emit({
            "status": "merge_failed",
            "action": "merge",
            "reason": "remote_base_mismatch",
            "remote_base_sha": remote_base,
            "pr_base_sha": base_sha,
        }, 3)
    ancestor = git(root, "merge-base", "--is-ancestor", base_sha, head_sha)
    if ancestor.returncode == 1:
        emit({
            "status": "merge_failed",
            "action": "merge",
            "reason": "non_fast_forward",
            "base_sha": base_sha,
            "head_sha": head_sha,
        }, 3)
    if ancestor.returncode:
        emit({
            "status": "merge_failed",
            "action": "merge",
            "reason": "ancestry_check_failed",
            "stderr": ancestor.stderr[-4000:].strip(),
        }, 3)
    latest = merge_readiness(cfg, root, ready["pr"])
    if (
        latest["status"] != "ready"
        or latest["head_sha"] != head_sha
        or latest["base_sha"] != base_sha
        or latest["head_branch"] != ready["head_branch"]
    ):
        emit({
            "status": "merge_failed",
            "action": "merge",
            "reason": "readiness_changed",
            "latest": latest,
        }, 3)
    info = repository_info(cfg, root)
    updated = atomic_update_refs(
        root,
        info["id"],
        [
            {"name": f"refs/heads/{base}", "before": base_sha, "after": head_sha},
            {"name": f"refs/heads/{ready['head_branch']}", "before": head_sha, "after": ZERO_OID},
        ],
        "fast-forward-update-refs",
    )
    if not updated["ok"]:
        emit({
            "status": "merge_failed",
            "action": "merge",
            "reason": "atomic_ref_update_failed",
            "detail": updated,
        }, 3)
    remote_after = git(root, "ls-remote", "--heads", remote, f"refs/heads/{base}")
    if remote_after.returncode:
        emit({
            "status": "merge_failed",
            "action": "merge",
            "reason": "remote_verification_failed",
            "stderr": remote_after.stderr[-4000:].strip(),
        }, 3)
    updated_sha = next((line.partition("\t")[0] for line in remote_after.stdout.splitlines()), None)
    reflected = {}
    reflected_ok = False
    for attempt in range(5):
        reflected = pull_request_state(cfg, root, ready["pr"])["view"]
        reflected_ok = (
            updated_sha == head_sha
            and reflected.get("state") == "MERGED"
            and bool(reflected.get("mergedAt"))
            and reflected.get("headRefOid") == head_sha
            and reflected.get("baseRefOid") == base_sha
        )
        if reflected_ok:
            break
        if attempt < 4:
            time.sleep(1)
    if not reflected_ok:
        emit({
            "status": "merge_partial",
            "action": "merge",
            "reason": "pull_request_not_reflected",
            "base_updated": True,
            "merge_sha": head_sha,
            "remote_base_sha": updated_sha,
            "pr_state": reflected.get("state"),
            "pr_merged_at": reflected.get("mergedAt"),
            "pr_head_sha": reflected.get("headRefOid"),
            "pr_base_sha": reflected.get("baseRefOid"),
        }, 4)
    return head_sha


def cleanup_remote_branch(cfg, root, head_branch, head_sha):
    validate_branch(cfg, root, head_branch)
    remote = cfg["git"]["remote"]
    remote_ref = f"refs/heads/{head_branch}"
    probe = git(root, "ls-remote", "--exit-code", "--heads", remote, remote_ref)
    if probe.returncode == 2:
        return {"ok": True, "branch_deleted": True, "reason": "already_absent"}
    if probe.returncode:
        return {"ok": False, "operation": "delete_branch", "stderr": probe.stderr[-4000:].strip()}
    remote_head = next((line.partition("\t")[0] for line in probe.stdout.splitlines()), None)
    if remote_head != head_sha:
        return {
            "ok": False,
            "operation": "delete_branch",
            "reason": "remote_head_mismatch",
            "remote_head_sha": remote_head,
            "pr_head_sha": head_sha,
        }
    info = repository_info(cfg, root)
    deleted = atomic_update_refs(
        root,
        info["id"],
        [{"name": remote_ref, "before": head_sha, "after": ZERO_OID}],
        "delete-branch",
    )
    if deleted["ok"]:
        return {"ok": True, "branch_deleted": True, "reason": "deleted"}
    after = git(root, "ls-remote", "--exit-code", "--heads", remote, remote_ref)
    if after.returncode == 2:
        return {"ok": True, "branch_deleted": True, "reason": "already_absent"}
    return {"ok": False, "operation": "delete_branch", "detail": deleted}


def cleanup_after_merge(cfg, root, head_branch, head_sha):
    failures = []
    branch_deleted = False
    branch_cleanup = {"ok": True, "branch_deleted": False, "reason": "disabled"}
    if cfg["merge"]["delete_branch"]:
        branch_cleanup = cleanup_remote_branch(cfg, root, head_branch, head_sha)
        branch_deleted = branch_cleanup.get("branch_deleted", False)
        if not branch_cleanup["ok"]:
            failures.append(branch_cleanup)
    worktree_cleanup = {"deleted": False, "reason": "disabled", "worktree": root}
    if cfg["merge"]["delete_worktree"]:
        validate_branch(cfg, root, head_branch)
        worktree_cleanup = remove_merged_worktree(root, head_branch)
        if not worktree_cleanup["deleted"]:
            failures.append({"operation": "delete_worktree", **worktree_cleanup})
    return failures, branch_deleted, branch_cleanup, worktree_cleanup


def do_merge(cfg, args):
    root = bound_repo_root(cfg, args.repo)
    permission(cfg, "merge")
    branch = safe_current_branch(cfg, root)
    ready = merge_readiness(cfg, root, args.pr)
    if ready["status"] != "ready":
        emit(ready, 3)
    gate(cfg, "merge", args.approved, ready)
    if cfg["merge"]["method"] == "fast-forward":
        merge_sha = fast_forward_merge(cfg, root, ready, branch)
    else:
        repo_name = repository_name(root)
        result = gh_json(
            [
                "api", "--method", "PUT", f"repos/{repo_name}/pulls/{args.pr}/merge",
                "-f", f"merge_method={cfg['merge']['method']}", "-f", f"sha={ready['head_sha']}",
            ],
            root,
            "merge",
        )
        if not result.get("merged"):
            emit({"status": "merge_failed", "action": "merge", "result": result}, 3)
        merge_sha = result.get("sha")
    failures, branch_deleted, branch_cleanup, worktree_cleanup = cleanup_after_merge(
        cfg, root, ready["head_branch"], ready["head_sha"]
    )
    payload = {
        "status": "merged_cleanup_failed" if failures else "merged",
        "action": "merge",
        "pr": args.pr,
        "merge_sha": merge_sha,
        "method": cfg["merge"]["method"],
        "branch_deleted": branch_deleted,
        "branch_cleanup": branch_cleanup,
        "worktree_cleanup": worktree_cleanup,
    }
    if failures:
        payload["cleanup_failures"] = failures
        emit(payload, 3)
    emit(payload)


def do_cleanup(cfg, args):
    root = bound_repo_root(cfg, args.repo)
    permission(cfg, "merge")
    info = repository_info(cfg, root)
    state = pull_request_state(cfg, root, args.pr)
    view = state["view"]
    expected_owner = info["nameWithOwner"].split("/", 1)[0]
    head_repository = view.get("headRepository") or {}
    head_owner = view.get("headRepositoryOwner") or {}
    if (
        view.get("state") != "MERGED"
        or not view.get("mergedAt")
        or not state["base_branch_matches"]
        or head_repository.get("nameWithOwner") != info["nameWithOwner"]
        or head_owner.get("login") != expected_owner
    ):
        emit({"status": "cleanup_failed", "action": "cleanup", "reason": "unsafe_pull_request_state"}, 3)
    failures, branch_deleted, branch_cleanup, worktree_cleanup = cleanup_after_merge(
        cfg, root, view["headRefName"], view["headRefOid"]
    )
    payload = {
        "status": "cleanup_failed" if failures else "cleaned",
        "action": "cleanup",
        "pr": args.pr,
        "branch_deleted": branch_deleted,
        "branch_cleanup": branch_cleanup,
        "worktree_cleanup": worktree_cleanup,
    }
    if failures:
        payload["cleanup_failures"] = failures
        emit(payload, 3)
    emit(payload)


def build_parser():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("preflight", "plan", "start", "permission", "gate", "commit", "push", "pull-request", "ready-for-review", "merge-readiness", "merge", "cleanup"):
        item = sub.add_parser(name)
        item.add_argument("--config", required=True)
        if name not in {"permission", "gate"}:
            item.add_argument("--repo", required=True)
        if name in {"plan", "start"}:
            item.add_argument("--branch", required=True)
        if name in {"permission", "gate"}:
            item.add_argument("--action", required=True, choices=ACTIONS)
        if name in {"gate", "commit", "push", "pull-request", "merge"}:
            item.add_argument("--approved", action="store_true")
        if name == "commit":
            item.add_argument("--paths-file", required=True)
            item.add_argument("--message", required=True)
        if name == "pull-request":
            item.add_argument("--title", required=True)
            item.add_argument("--body-file", required=True)
        if name in {"ready-for-review", "merge-readiness", "merge", "cleanup"}:
            item.add_argument("--pr", required=True, type=int)
    return parser


def main():
    args = build_parser().parse_args()
    cfg = load_config(args.config)
    if args.command == "preflight":
        root = bound_repo_root(cfg, args.repo)
        dirty = dirty_changes(root)
        emit(
            {
                "status": "ready" if not dirty else "dirty",
                "repo_root": root,
                "mode": "worktree" if cfg["workspace"]["use_worktree"] else "branch",
                "dirty": bool(dirty),
                "changes": dirty,
            },
            0,
        )
    if args.command == "plan":
        emit(workspace_plan(cfg, args.repo, args.branch))
    if args.command == "start":
        emit(start_workspace(cfg, args.repo, args.branch))
    if args.command == "permission":
        permission(cfg, args.action)
        emit({"status": "allowed", "action": args.action, "allowed": True})
    if args.command == "gate":
        permission(cfg, args.action)
        gate(cfg, args.action, args.approved)
        emit({"status": "approved", "action": args.action, "required": cfg["gates"][GATES[args.action]]})
    if args.command == "commit":
        do_commit(cfg, args)
    if args.command == "push":
        do_push(cfg, args)
    if args.command == "pull-request":
        do_pull_request(cfg, args)
    if args.command == "ready-for-review":
        do_ready_for_review(cfg, args)
    if args.command == "merge-readiness":
        root = bound_repo_root(cfg, args.repo)
        ready = merge_readiness(cfg, root, args.pr)
        emit(ready, 0 if ready["status"] == "ready" else 3)
    if args.command == "merge":
        do_merge(cfg, args)
    if args.command == "cleanup":
        do_cleanup(cfg, args)


if __name__ == "__main__":
    main()
