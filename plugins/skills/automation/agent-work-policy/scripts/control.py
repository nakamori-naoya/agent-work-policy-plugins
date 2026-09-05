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
from urllib.parse import unquote, urlparse


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
        if candidate.is_absolute() or item.startswith((":", "./")) or ".." in candidate.parts or item == ".git" or item.startswith(".git/"):
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
        data = json.loads(output)
    except json.JSONDecodeError as exc:
        emit({"error": "ghのJSONを読めない", "operation": operation, "detail": str(exc)}, 2)
    if isinstance(data, dict) and data.get("errors"):
        emit({"error": "GitHub APIがerrorを返した", "operation": operation}, 2)
    return data


def pull_request_state(cfg, root, repo_name, pr_number, branch=None):
    view = gh_json(
        [
            "pr", "view", str(pr_number), "--repo", repo_name, "--json",
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


def redacted_remote_url(remote_url):
    scp = re.fullmatch(r"git@([^/:?#]+):([^/:?#]+)/([^/:?#]+?)(?:\.git)?", remote_url)
    if scp:
        return f"git@{scp.group(1)}:{scp.group(2)}/{scp.group(3)}.git"
    try:
        parsed = urlparse(remote_url)
        allowed_user = parsed.scheme == "ssh" and parsed.username == "git" and parsed.password is None
        no_credentials = parsed.username is None and parsed.password is None
        clean = (
            parsed.scheme in {"https", "ssh"}
            and (no_credentials or allowed_user)
            and parsed.hostname
            and parsed.port is None
            and not parsed.query
            and not parsed.fragment
            and not parsed.params
            and unquote(parsed.path) == parsed.path
        )
        parts = parsed.path.removeprefix("/").split("/") if clean else []
        if len(parts) != 2 or not all(parts):
            return "<redacted-invalid-remote-url>"
        user = "git@" if allowed_user else ""
        return f"{parsed.scheme}://{user}{parsed.hostname}/{parts[0]}/{parts[1]}"
    except (TypeError, ValueError):
        return "<redacted-invalid-remote-url>"


def remote_matches_repository(remote_url, data):
    candidates = {data.get("sshUrl"), data.get("url"), f"{data.get('url')}.git"}
    if remote_url in candidates:
        return True
    web = urlparse(str(data.get("url") or ""))
    expected_host = web.hostname
    remote_host = None
    remote_name = None
    scp = re.fullmatch(r"git@([^/:?#]+):([^/:?#]+)/([^/:?#]+?)(?:\.git)?", remote_url)
    if scp:
        remote_host = scp.group(1)
        remote_name = f"{scp.group(2)}/{scp.group(3)}"
    else:
        try:
            parsed = urlparse(remote_url)
            allowed_user = parsed.scheme == "ssh" and parsed.username == "git" and parsed.password is None
            no_credentials = parsed.username is None and parsed.password is None
            clean = (
                parsed.scheme in {"https", "ssh"}
                and (no_credentials or allowed_user)
                and parsed.port is None
                and not parsed.query
                and not parsed.fragment
                and not parsed.params
                and unquote(parsed.path) == parsed.path
            )
        except ValueError:
            clean = False
            parsed = None
        parts = parsed.path.removeprefix("/").split("/") if clean else []
        if len(parts) == 2 and all(parts):
            remote_host = parsed.hostname
            repository = parts[1][:-4] if parts[1].endswith(".git") else parts[1]
            remote_name = f"{parts[0]}/{repository}"
    return remote_host == expected_host and remote_name == data.get("nameWithOwner")


def repository_info(cfg, root):
    data = gh_json(["repo", "view", "--json", "id,nameWithOwner,sshUrl,url"], root, "repository-identity")
    remote = cfg["git"]["remote"]
    fetch_url = require_success(git(root, "remote", "get-url", remote), "remote-url", 2)
    push_proc = git(root, "remote", "get-url", "--push", "--all", remote)
    push_urls = require_success(push_proc, "remote-push-urls", 2).splitlines()
    inspected = [fetch_url, *push_urls]
    if len(push_urls) != 1 or any(not remote_matches_repository(item, data) for item in inspected):
        emit({
            "error": "GitHub対象とgit remoteが一致しない",
            "github_repository": data.get("nameWithOwner"),
            "remote": remote,
            "remote_urls": ["<redacted-invalid-remote-url>" for _ in inspected],
        }, 2)
    data["remote"] = remote
    data["pushUrl"] = push_urls[0]
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
    if data.get("errors") or not ((data.get("data") or {}).get("updateRefs")):
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


def branch_protection(root, repo_name, base):
    return gh_json(
        ["api", f"repos/{repo_name}/branches/{base}/protection"],
        root,
        "branch-protection",
    )


def required_checks(protection):
    status = protection.get("required_status_checks") or {}
    checks = status.get("checks") or []
    if checks:
        return [
            {"context": item.get("context"), "app_id": item.get("app_id"), "kind": "check_run"}
            for item in checks
            if item and item.get("context")
        ]
    return [
        {"context": context, "app_id": None, "kind": "context"}
        for context in (status.get("contexts") or [])
        if context
    ]


def commit_check_runs(root, repo_name, head_sha):
    owner, name = repo_name.split("/", 1)
    query = """
query($owner:String!,$name:String!,$oid:GitObjectID!){
  repository(owner:$owner,name:$name){
    object(oid:$oid){... on Commit{
      checkSuites(first:100){
        nodes{app{databaseId} checkRuns(first:100){nodes{name status conclusion startedAt completedAt} pageInfo{hasNextPage}}}
        pageInfo{hasNextPage}
      }
    }}
  }
}
"""
    data = gh_json(
        [
            "api", "graphql", "-f", f"query={query}", "-F", f"owner={owner}",
            "-F", f"name={name}", "-F", f"oid={head_sha}",
        ],
        root,
        "check-runs",
    )
    repository = (data.get("data") or {}).get("repository") or {}
    commit = repository.get("object") or {}
    suites = commit.get("checkSuites") or {}
    nodes = suites.get("nodes")
    if nodes is None or (suites.get("pageInfo") or {}).get("hasNextPage"):
        emit({"error": "check suiteを完全に取得できない"}, 2)
    runs = []
    for suite in nodes:
        check_runs = (suite or {}).get("checkRuns") or {}
        if (check_runs.get("pageInfo") or {}).get("hasNextPage"):
            emit({"error": "check runを完全に取得できない"}, 2)
        app_id = ((suite or {}).get("app") or {}).get("databaseId")
        for run in check_runs.get("nodes") or []:
            runs.append({**run, "app_id": app_id})
    return runs


def checks_passed(rollup, requirements, check_runs):
    if not requirements:
        return False
    successful_contexts = set()
    for item in rollup or []:
        conclusion = str(item.get("conclusion") or item.get("state") or "").upper()
        if conclusion == "SUCCESS":
            name = item.get("name") or item.get("context")
            if name:
                successful_contexts.add(name)
    latest_runs = {}
    for item in check_runs or []:
        key = (item.get("name"), item.get("app_id"))
        if not key[0] or key[1] is None:
            continue
        order = item.get("completedAt") or item.get("startedAt") or ""
        previous = latest_runs.get(key)
        if previous is None or order >= previous[0]:
            latest_runs[key] = (order, item)
    successful_runs = {
        key
        for key, (_, item) in latest_runs.items()
        if str(item.get("status") or "").upper() == "COMPLETED"
        and str(item.get("conclusion") or "").upper() == "SUCCESS"
    }
    for required in requirements:
        context = required["context"]
        if required["kind"] == "context":
            if context not in successful_contexts:
                return False
            continue
        if context not in successful_contexts:
            return False
        app_id = required.get("app_id")
        if app_id is None or app_id == -1:
            if not any(name == context for name, _ in successful_runs):
                return False
        elif (context, app_id) not in successful_runs:
            return False
    return True


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


def pull_request_ruleset_bypass(root, repo_name, base, merge_method, required):
    rules = gh_json(
        ["api", f"repos/{repo_name}/rules/branches/{base}"],
        root,
        "branch-rules",
    )
    if not isinstance(rules, list) or not rules:
        return {"authorized": False, "ruleset_ids": [], "reason": "no_applied_ruleset"}
    ruleset_ids = sorted(
        {
            item.get("ruleset_id")
            for item in rules
            if isinstance(item, dict) and isinstance(item.get("ruleset_id"), int)
        }
    )
    if (
        not ruleset_ids
        or any(not isinstance(item, dict) for item in rules)
        or any(not isinstance(item.get("ruleset_id"), int) for item in rules)
    ):
        return {"authorized": False, "ruleset_ids": ruleset_ids, "reason": "invalid_rules"}
    for rule in rules:
        if rule.get("type") != "pull_request":
            return {
                "authorized": False,
                "ruleset_ids": ruleset_ids,
                "reason": f"unsupported_rule:{rule.get('type')}",
            }
        parameters = rule.get("parameters") or {}
        allowed_methods = parameters.get("allowed_merge_methods") or []
        if merge_method not in allowed_methods:
            return {
                "authorized": False,
                "ruleset_ids": ruleset_ids,
                "reason": "merge_method_not_allowed",
            }
        if (
            parameters.get("required_review_thread_resolution") is True
            and not required["require_no_unresolved_threads"]
        ):
            return {
                "authorized": False,
                "ruleset_ids": ruleset_ids,
                "reason": "thread_policy_not_enforced",
            }
    for ruleset_id in ruleset_ids:
        details = gh_json(
            ["api", f"repos/{repo_name}/rulesets/{ruleset_id}"],
            root,
            "ruleset-bypass",
        )
        if not isinstance(details, dict) or (
            details.get("enforcement") != "active"
            or details.get("current_user_can_bypass")
            not in {"always", "pull_requests_only"}
        ):
            return {
                "authorized": False,
                "ruleset_ids": ruleset_ids,
                "reason": "current_user_cannot_bypass",
            }
    return {"authorized": True, "ruleset_ids": ruleset_ids, "reason": "authorized"}


def merge_readiness(cfg, root, pr_number, info=None):
    info = info or repository_info(cfg, root)
    expected_repo = info["nameWithOwner"]
    initial_state = pull_request_state(cfg, root, expected_repo, pr_number)
    initial_view = initial_state["view"]
    required = cfg["merge"]["readiness"]
    protection = branch_protection(root, expected_repo, initial_view.get("baseRefName"))
    requirements = required_checks(protection) if required["require_checks_passed"] else []
    check_runs = commit_check_runs(root, expected_repo, initial_view.get("headRefOid")) if any(item["kind"] == "check_run" for item in requirements) else []
    unresolved = unresolved_threads(root, expected_repo, pr_number) if required["require_no_unresolved_threads"] else None
    ruleset_bypass = {"authorized": False, "ruleset_ids": [], "reason": "not_required"}
    if (
        initial_view.get("mergeStateStatus") == "BLOCKED"
        and required["min_approvals"] == 0
    ):
        ruleset_bypass = pull_request_ruleset_bypass(
            root,
            expected_repo,
            initial_view.get("baseRefName"),
            cfg["merge"]["method"],
            required,
        )
    state = pull_request_state(cfg, root, expected_repo, pr_number)
    view = state["view"]
    expected_owner = expected_repo.split("/", 1)[0]
    head_repository = view.get("headRepository") or {}
    head_owner = view.get("headRepositoryOwner") or {}
    reasons = []
    approvals = approval_count(view.get("reviews"))
    snapshot_fields = {
        "headRefName": "snapshot_head_branch_changed",
        "headRefOid": "snapshot_head_changed",
        "baseRefName": "snapshot_base_branch_changed",
        "baseRefOid": "snapshot_base_changed",
        "headRepositoryOwner": "snapshot_head_repository_changed",
        "headRepository": "snapshot_head_repository_changed",
    }
    for field, reason in snapshot_fields.items():
        if initial_view.get(field) != view.get(field):
            if reason not in reasons:
                reasons.append(reason)
    if initial_view.get("baseRefName") != cfg["workspace"]["base_branch"]:
        reasons.append("initial_base_branch_mismatch")
    if view.get("isDraft"):
        reasons.append("draft")
    if view.get("state") != "OPEN":
        reasons.append(f"state:{view.get('state')}")
    if view.get("mergeable") != "MERGEABLE":
        reasons.append(f"mergeable:{view.get('mergeable')}")
    if view.get("mergeStateStatus") != "CLEAN" and not (
        view.get("mergeStateStatus") == "BLOCKED"
        and ruleset_bypass["authorized"]
    ):
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
    passed = checks_passed(view.get("statusCheckRollup"), requirements, check_runs) if required["require_checks_passed"] else True
    if required["require_checks_passed"] and not passed:
        reasons.append("checks")
    protected_reviews = protection.get("required_pull_request_reviews") or {}
    protected_approvals = protected_reviews.get("required_approving_review_count") or 0
    protect_fast_forward = cfg["merge"]["method"] == "fast-forward"
    if protect_fast_forward and required["min_approvals"] > protected_approvals:
        reasons.append("protection:approvals")
    conversation_protected = bool((protection.get("required_conversation_resolution") or {}).get("enabled"))
    if protect_fast_forward and required["require_no_unresolved_threads"] and not conversation_protected:
        reasons.append("protection:conversation_resolution")
    admins_protected = bool((protection.get("enforce_admins") or {}).get("enabled"))
    if protect_fast_forward and not admins_protected:
        reasons.append("protection:admins")
    if required["require_no_unresolved_threads"] and unresolved:
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
        "required_checks": requirements,
        "protected_approvals": protected_approvals,
        "conversation_resolution_protected": conversation_protected,
        "admins_protected": admins_protected,
        "unresolved_threads": unresolved,
        "ruleset_bypass": ruleset_bypass,
        "reasons": reasons,
    }


def do_commit(cfg, args):
    root = bound_repo_root(cfg, args.repo)
    permission(cfg, "commit")
    branch = safe_current_branch(cfg, root)
    paths = safe_paths(root, args.paths_file)
    staged = require_success(git(root, "diff", "--cached", "--name-only", "-z"), "inspect-staged-paths", 2)
    staged_paths = [item for item in staged.split("\0") if item]
    allowed = tuple(path.rstrip("/") for path in paths)
    outside = [
        item for item in staged_paths
        if not any(item == path or item.startswith(f"{path}/") for path in allowed)
    ]
    if outside:
        emit({"status": "failed", "action": "commit", "reason": "pre_staged_paths_outside_scope", "paths": outside}, 3)
    changes = git(root, "--literal-pathspecs", "status", "--porcelain", "--", *paths)
    require_success(changes, "inspect-commit-paths", 2)
    if not changes.stdout.strip():
        emit({"status": "no_changes", "action": "commit", "paths": paths}, 3)
    verification = run_verification(cfg, root)
    gate(cfg, "commit", args.approved, {"branch": branch, "paths": paths, "verification": verification})
    require_success(git(root, "--literal-pathspecs", "add", "--", *paths), "stage")
    staged = require_success(git(root, "diff", "--cached", "--name-only", "-z"), "inspect-staged-paths", 2)
    staged_paths = [item for item in staged.split("\0") if item]
    outside = [
        item for item in staged_paths
        if not any(item == path or item.startswith(f"{path}/") for path in allowed)
    ]
    if outside:
        emit({"status": "failed", "action": "commit", "reason": "staged_paths_outside_scope", "paths": outside}, 3)
    if git(root, "diff", "--cached", "--quiet").returncode == 0:
        emit({"status": "no_staged_changes", "action": "commit"}, 3)
    require_success(git(root, "commit", "-m", args.message), "commit")
    sha = require_success(git(root, "rev-parse", "HEAD"), "commit-sha", 2)
    emit({"status": "committed", "action": "commit", "branch": branch, "sha": sha, "paths": paths})


def do_push(cfg, args):
    root = bound_repo_root(cfg, args.repo)
    permission(cfg, "push")
    info = repository_info(cfg, root)
    branch = safe_current_branch(cfg, root)
    sha = require_success(git(root, "rev-parse", "HEAD"), "head-sha", 2)
    remote_ref = f"refs/heads/{branch}"
    probe = git(root, "ls-remote", "--heads", info["pushUrl"], remote_ref)
    if probe.returncode:
        emit({"status": "failed", "action": "push", "reason": "remote_ref_lookup_failed"}, 3)
    remote_sha = next((line.partition("\t")[0] for line in probe.stdout.splitlines()), None)
    if remote_sha not in {None, sha}:
        ancestor = git(root, "merge-base", "--is-ancestor", remote_sha, sha)
        if ancestor.returncode != 0:
            reason = "remote_branch_mismatch" if ancestor.returncode == 1 else "remote_ancestry_unknown"
            emit({"status": "failed", "action": "push", "reason": reason, "remote_sha": remote_sha, "local_sha": sha}, 3)
    context = {
        "repository": info["nameWithOwner"],
        "url": redacted_remote_url(info["pushUrl"]),
        "branch": branch,
        "sha": sha,
    }
    gate(cfg, "push", args.approved, context)
    require_success(git(root, "push", info["pushUrl"], f"{sha}:{remote_ref}"), "push")
    emit({"status": "pushed", "action": "push", **context, "remote": info["remote"]})


def do_pull_request(cfg, args):
    root = bound_repo_root(cfg, args.repo)
    permission(cfg, "pull_request")
    info = repository_info(cfg, root)
    branch = safe_current_branch(cfg, root)
    sha = require_success(git(root, "rev-parse", "HEAD"), "head-sha", 2)
    remote_ref = f"refs/heads/{branch}"
    probe = git(root, "ls-remote", "--heads", info["pushUrl"], remote_ref)
    if probe.returncode:
        emit({"status": "failed", "action": "pull_request", "reason": "remote_ref_lookup_failed"}, 3)
    remote_sha = next((line.partition("\t")[0] for line in probe.stdout.splitlines()), None)
    if remote_sha != sha:
        emit({"status": "failed", "action": "pull_request", "reason": "remote_head_mismatch", "remote_sha": remote_sha, "local_sha": sha}, 3)
    gate(cfg, "pull_request", args.approved, {
        "repository": info["nameWithOwner"],
        "url": redacted_remote_url(info["pushUrl"]),
        "branch": branch,
        "sha": sha,
        "base": cfg["workspace"]["base_branch"],
        "title": args.title,
    })
    cmd = [
        "pr", "create", "--repo", info["nameWithOwner"],
        "--base", cfg["workspace"]["base_branch"], "--head", branch,
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
    info = repository_info(cfg, root)
    branch = safe_current_branch(cfg, root)
    local_head = require_success(git(root, "rev-parse", "HEAD"), "head-sha", 2)
    remote_ref = f"refs/heads/{branch}"
    probe = git(root, "ls-remote", "--heads", info["pushUrl"], remote_ref)
    if probe.returncode:
        emit({"status": "failed", "action": "pull_request", "pr": args.pr, "reason": "remote_ref_lookup_failed"}, 3)
    remote_head = next((line.partition("\t")[0] for line in probe.stdout.splitlines()), None)
    if remote_head != local_head:
        emit({"status": "failed", "action": "pull_request", "pr": args.pr, "reason": "remote_head_mismatch"}, 3)
    state = pull_request_state(cfg, root, info["nameWithOwner"], args.pr, branch)
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
    expected_owner = info["nameWithOwner"].split("/", 1)[0]
    head_repository = view.get("headRepository") or {}
    head_owner = view.get("headRepositoryOwner") or {}
    if head_repository.get("nameWithOwner") != info["nameWithOwner"] or head_owner.get("login") != expected_owner:
        emit({"status": "failed", **result, "reason": "cross_repository"}, 3)
    if view.get("state") != "OPEN":
        emit({"status": "failed", **result, "reason": f"state:{view.get('state')}"}, 3)
    if view.get("headRefOid") != local_head:
        emit({"status": "failed", **result, "reason": "local_head_mismatch"}, 3)
    if not view.get("isDraft"):
        emit({"status": "ready", **result, "changed": False})
    proc = command(["gh", "pr", "ready", str(args.pr), "--repo", info["nameWithOwner"]], cwd=root)
    require_success(proc, "ready-for-review")
    emit({"status": "ready", **result, "changed": True})


def probe_remote_refs(root, push_url, refs):
    proc = git(root, "ls-remote", "--heads", push_url, *refs)
    if proc.returncode:
        return None
    found = {ref: None for ref in refs}
    for line in proc.stdout.splitlines():
        sha, _, ref = line.partition("\t")
        if ref in found:
            found[ref] = sha
    return found


def emit_uncertain_ref_update(root, info, ready, detail):
    base_ref = f"refs/heads/{ready['base_branch']}"
    head_ref = f"refs/heads/{ready['head_branch']}"
    observed = probe_remote_refs(root, info["pushUrl"], [base_ref, head_ref])
    if observed is not None and observed[base_ref] == ready["base_sha"] and observed[head_ref] == ready["head_sha"]:
        emit({
            "status": "merge_failed",
            "action": "merge",
            "reason": "atomic_ref_update_failed_unchanged",
            "detail": detail,
        }, 3)
    emit({
        "status": "merge_partial",
        "action": "merge",
        "reason": "atomic_ref_update_outcome_uncertain",
        "base_updated": observed is not None and observed[base_ref] == ready["head_sha"],
        "merge_sha": ready["head_sha"],
        "remote_base_sha": None if observed is None else observed[base_ref],
        "remote_head_sha": None if observed is None else observed[head_ref],
        "detail": detail,
    }, 4)


def fast_forward_merge(cfg, root, info, ready, branch):
    remote_url = info["pushUrl"]
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
    observed = probe_remote_refs(root, remote_url, list(refs))
    if observed is None:
        emit({
            "status": "merge_failed",
            "action": "merge",
            "reason": "remote_ref_lookup_failed",
        }, 3)
    refs.update(observed)
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
    latest = merge_readiness(cfg, root, ready["pr"], info)
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
    updated = atomic_update_refs(
        root,
        info["id"],
        [
            {"name": f"refs/heads/{base}", "before": base_sha, "after": head_sha},
            {"name": f"refs/heads/{ready['head_branch']}", "before": head_sha, "after": head_sha},
        ],
        "fast-forward-update-refs",
    )
    if not updated["ok"]:
        emit_uncertain_ref_update(root, info, ready, updated)
    remote_after = git(root, "ls-remote", "--heads", remote_url, f"refs/heads/{base}")
    if remote_after.returncode:
        emit_uncertain_ref_update(root, info, ready, {"operation": "remote-verification"})
    updated_sha = next((line.partition("\t")[0] for line in remote_after.stdout.splitlines()), None)
    reflected = {}
    reflected_ok = False
    for attempt in range(5):
        reflected = pull_request_state(cfg, root, info["nameWithOwner"], ready["pr"])["view"]
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


def cleanup_remote_branch(cfg, root, info, head_branch, head_sha):
    validate_branch(cfg, root, head_branch)
    remote = info["pushUrl"]
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


def cleanup_after_merge(cfg, root, info, head_branch, head_sha):
    failures = []
    branch_deleted = False
    branch_cleanup = {"ok": True, "branch_deleted": False, "reason": "disabled"}
    if cfg["merge"]["delete_branch"]:
        branch_cleanup = cleanup_remote_branch(cfg, root, info, head_branch, head_sha)
        branch_deleted = branch_cleanup.get("branch_deleted", False)
        if not branch_cleanup["ok"]:
            failures.append(branch_cleanup)
    worktree_cleanup = {"deleted": False, "reason": "disabled", "worktree": root}
    if cfg["merge"]["delete_worktree"] and not failures:
        validate_branch(cfg, root, head_branch)
        worktree_cleanup = remove_merged_worktree(root, head_branch)
        if not worktree_cleanup["deleted"]:
            failures.append({"operation": "delete_worktree", **worktree_cleanup})
    return failures, branch_deleted, branch_cleanup, worktree_cleanup


def do_merge(cfg, args):
    root = bound_repo_root(cfg, args.repo)
    permission(cfg, "merge")
    info = repository_info(cfg, root)
    branch = safe_current_branch(cfg, root)
    ready = merge_readiness(cfg, root, args.pr, info)
    if ready["status"] != "ready":
        emit(ready, 3)
    gate(cfg, "merge", args.approved, ready)
    if cfg["merge"]["method"] == "fast-forward":
        merge_sha = fast_forward_merge(cfg, root, info, ready, branch)
    else:
        result = gh_json(
            [
                "api", "--method", "PUT", f"repos/{info['nameWithOwner']}/pulls/{args.pr}/merge",
                "-f", f"merge_method={cfg['merge']['method']}", "-f", f"sha={ready['head_sha']}",
            ],
            root,
            "merge",
        )
        if not result.get("merged"):
            emit({"status": "merge_failed", "action": "merge", "result": result}, 3)
        merge_sha = result.get("sha")
    failures, branch_deleted, branch_cleanup, worktree_cleanup = cleanup_after_merge(
        cfg, root, info, ready["head_branch"], ready["head_sha"]
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
    state = pull_request_state(cfg, root, info["nameWithOwner"], args.pr)
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
        cfg, root, info, view["headRefName"], view["headRefOid"]
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
