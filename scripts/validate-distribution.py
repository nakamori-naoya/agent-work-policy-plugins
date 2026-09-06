#!/usr/bin/env python3
"""Validate a marketplace whose only install target is one playbook package."""

from __future__ import annotations

import json
import os
import re
import shutil
import stat
import sys
import tempfile
from pathlib import Path


def fail(message: str) -> None:
    raise ValueError(message)


def load_json(path: Path) -> dict:
    with path.open(encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        fail(f"JSON objectではありません: {path}")
    return value


def write_json(path: Path, value: dict) -> None:
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def require_regular_file(path: Path, label: str) -> None:
    try:
        mode = path.lstat().st_mode
    except OSError as exc:
        fail(f"{label}がありません: {path}: {exc}")
    if not stat.S_ISREG(mode) or path.is_symlink():
        fail(f"{label}がregular fileではありません: {path}")


def reject_symlinks(root: Path) -> None:
    if root.is_symlink():
        fail(f"配布packageがsymlinkです: {root}")
    for directory, subdirectories, filenames in os.walk(root, followlinks=False):
        parent = Path(directory)
        for name in [*subdirectories, *filenames]:
            path = parent / name
            if path.is_symlink():
                fail(f"配布package内にsymlinkがあります: {path}")


def safe_member(root: Path, raw: object, label: str) -> Path:
    if not isinstance(raw, str) or not raw.startswith("./"):
        fail(f"{label}は./から始まる相対pathでなければなりません")
    relative = Path(raw)
    if relative.is_absolute() or ".." in relative.parts or raw.endswith("/"):
        fail(f"{label}に不正なpathがあります: {raw}")
    boundary = os.path.realpath(os.fspath(root))
    lexical = os.path.abspath(os.path.join(boundary, raw))
    candidate = os.path.realpath(lexical)
    if not candidate.startswith(boundary + os.sep):
        fail(f"{label}が配布package外を指しています: {raw}")
    if candidate != lexical:
        fail(f"{label}がsymlinkです: {raw}")
    declared = Path(candidate)
    if not declared.exists():
        fail(f"{label}が実在しません: {raw}")
    if declared.is_symlink():
        fail(f"{label}がsymlinkです: {raw}")
    return declared


def catalog_entry(path: Path, runtime: str) -> tuple[str, dict]:
    catalog = load_json(path)
    name = catalog.get("name")
    plugins = catalog.get("plugins")
    if not isinstance(name, str) or not name:
        fail(f"marketplace名が不正です: {path}")
    if not isinstance(plugins, list) or len(plugins) != 1:
        fail(f"公開インストール対象はPlaybook package 1件でなければなりません: {path}")
    entry = plugins[0]
    if not isinstance(entry, dict):
        fail(f"catalog entryがobjectではありません: {path}")
    source = entry.get("source")
    if runtime == "codex":
        if not isinstance(source, dict) or source.get("source") != "local":
            fail("Codex sourceがlocal形式ではありません")
        source = source.get("path")
    identity = {"name": entry.get("name"), "version": entry.get("version"), "source": source}
    if not all(isinstance(value, str) and value for value in identity.values()):
        fail(f"catalog identityが不正です: {path}")
    if identity["source"] != "./plugins":
        fail("公開sourceは./pluginsのPlaybook packageだけでなければなりません")
    return name, identity


def manifest(root: Path, runtime: str) -> tuple[Path, dict]:
    path = root / f".{runtime}-plugin/plugin.json"
    require_regular_file(path, f"{runtime} manifest")
    return path, load_json(path)


IDENTIFIER = re.compile(r"^[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*$")
CAPABILITY_SLUG = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
IMPLEMENTS_KEYS = {"id", "version", "kind", "playbook", "types", "actions"}
ENTRY_FILES = ("playbook.yml", "scripts/resolve.sh", "scripts/prepare.sh", "SKILL.md")


def contract_id(value: object, label: str) -> tuple[str, str]:
    if not isinstance(value, str) or value.count("/") != 1:
        fail(f"{label}が契約IDの形ではありません: {value}")
    marketplace, plugin = value.split("/")
    if not IDENTIFIER.fullmatch(marketplace) or not IDENTIFIER.fullmatch(plugin):
        fail(f"{label}が契約IDの形ではありません: {value}")
    return marketplace, plugin


def validate_implements(package_root: Path, harness: dict, marketplace_name: str,
                        playbooks: dict[str, str]) -> None:
    """公開契約の自己宣言を検査する（§3.4 I1〜I9）。kind は playbook のみ。"""
    declared = harness.get("marketplace")
    if not isinstance(declared, str) or not IDENTIFIER.fullmatch(declared):
        fail("metadata.harness.marketplaceを宣言しなければなりません")
    if declared != marketplace_name:
        fail("metadata.harness.marketplaceがmarketplace名と一致しません")
    raw = harness.get("implements")
    if raw is None:
        return
    if not isinstance(raw, list):
        fail("metadata.harness.implementsは配列でなければなりません")
    seen: set[str] = set()
    for entry in raw:
        if not isinstance(entry, dict):
            fail("implementsの要素がobjectではありません")
        unknown = sorted(set(entry) - IMPLEMENTS_KEYS)
        if unknown:
            fail(f"implementsに未知のキーがあります: {unknown[0]}")
        for required in ("id", "version", "kind", "playbook"):
            if required not in entry:
                fail(f"implementsに{required}がありません")
        # 差し替え先は他人の契約IDを実装するので、id の marketplace 部の一致は求めない。
        contract_id(entry["id"], "implements.id")
        if type(entry["version"]) is not int or entry["version"] != 1:
            fail("implements.versionは1でなければなりません")
        if entry["kind"] != "playbook":
            fail("implements.kindはplaybookだけです")
        name = entry["playbook"]
        if not isinstance(name, str) or name not in playbooks:
            fail(f"implements.playbookが宣言済みplaybookではありません: {name}")
        component = safe_member(package_root, playbooks[name], f"playbooks.{name}")
        for relative in ENTRY_FILES:
            require_regular_file(component / relative, f"公開入口 {name}/{relative}")
        for key in ("types", "actions"):
            if key not in entry:
                continue
            values = entry[key]
            if not isinstance(values, list) or not all(
                isinstance(value, str) and CAPABILITY_SLUG.fullmatch(value) for value in values
            ):
                fail(f"implements.{key}はslug文字列の配列でなければなりません")
        if entry["id"] in seen:
            fail(f"implementsのidが重複しています: {entry['id']}")
        seen.add(entry["id"])


def mapping(harness: dict, key: str) -> dict[str, str]:
    value = harness.get(key)
    if not isinstance(value, dict):
        fail(f"metadata.harness.{key}がobjectではありません")
    if key == "playbooks" and not value:
        fail("Playbook packageにはplaybooks宣言が必要です")
    if not all(isinstance(name, str) and name and isinstance(path, str) and path for name, path in value.items()):
        fail(f"metadata.harness.{key}の識別情報が不正です")
    return value


def validate_component(root: Path, name: str, raw: str, kind: str) -> Path:
    component = safe_member(root, raw, f"{kind}.{name}")
    if not component.is_dir():
        fail(f"{kind}.{name}がdirectoryではありません")
    if kind == "playbooks":
        require_regular_file(component / "playbook.yml", f"playbook {name}")
    for runtime in ("claude", "codex"):
        _, data = manifest(component, runtime)
        if data.get("name") != name:
            fail(f"{kind}.{name}の{runtime} manifest identityが一致しません")
    return component


def validate_repository(root: Path) -> int:
    root_license = root / "LICENSE"
    package_root = root / "plugins"
    require_regular_file(root_license, "root LICENSE")
    if not package_root.is_dir() or package_root.is_symlink():
        fail("pluginsがPlaybook package directoryではありません")
    reject_symlinks(package_root)
    require_regular_file(package_root / "LICENSE", "package LICENSE")
    if root_license.read_bytes() != (package_root / "LICENSE").read_bytes():
        fail("package LICENSEがroot LICENSEと一致しません")

    claude_name, claude_entry = catalog_entry(root / ".claude-plugin/marketplace.json", "claude")
    codex_name, codex_entry = catalog_entry(root / ".agents/plugins/marketplace.json", "codex")
    if claude_name != codex_name or claude_entry != codex_entry:
        fail("Claude/Codex catalogの公開packageが一致しません")
    marketplace_name = claude_name
    package_name = claude_entry["name"]

    manifests: dict[str, dict] = {}
    for runtime in ("claude", "codex"):
        _, data = manifest(package_root, runtime)
        if data.get("name") != package_name or data.get("version") != claude_entry["version"]:
            fail(f"{runtime} package manifest identityがcatalogと一致しません")
        manifests[runtime] = data
    capabilities = manifests["codex"].get("interface", {}).get("capabilities")
    if not isinstance(capabilities, list) or "Skills" not in capabilities:
        fail("Codex packageはSkills capabilityを宣言しなければなりません")

    harnesses: dict[str, dict] = {}
    for runtime, data in manifests.items():
        harness = data.get("metadata", {}).get("harness")
        if not isinstance(harness, dict) or harness.get("installationSurface") != "playbook-package":
            fail(f"{runtime} packageはplaybook-package境界を宣言しなければなりません")
        harnesses[runtime] = harness
    if harnesses["claude"] != harnesses["codex"]:
        fail("Claude/Codex package metadataが一致しません")

    playbooks = mapping(harnesses["claude"], "playbooks")
    internals = mapping(harnesses["claude"], "internalPlugins")
    validate_implements(package_root, harnesses["claude"], marketplace_name, playbooks)
    if set(playbooks) & set(internals):
        fail("playbook名と内部plugin名が重複しています")
    declared_roots: set[Path] = set()
    for name, raw in playbooks.items():
        declared_roots.add(validate_component(package_root, name, raw, "playbooks"))
    for name, raw in internals.items():
        declared_roots.add(validate_component(package_root, name, raw, "internalPlugins"))

    entry_root = harnesses["claude"].get("entryRoot")
    if entry_root is not None:
        resolved_entry = safe_member(package_root, entry_root, "entryRoot")
        if resolved_entry not in declared_roots or entry_root not in playbooks.values():
            fail("entryRootは宣言済みplaybookを指さなければなりません")

    skill_paths = manifests["claude"].get("skills")
    if skill_paths != manifests["codex"].get("skills"):
        fail("Claude/Codex skills宣言が一致しません")
    if not isinstance(skill_paths, list) or not skill_paths:
        fail("Playbook packageのskillsは非空配列でなければなりません")
    for index, raw in enumerate(skill_paths):
        skill_root = safe_member(package_root, raw, f"skills[{index}]")
        require_regular_file(skill_root / "SKILL.md", f"skills[{index}] SKILL.md")
        if not (skill_root / "SKILL.md").read_text(encoding="utf-8").strip():
            fail(f"skills[{index}] SKILL.mdが空です")
        if not any(skill_root == component or component in skill_root.parents for component in declared_roots):
            fail(f"skills[{index}]が宣言済みplaybookまたは内部pluginに属していません")

    discovered_by_runtime: dict[str, set[Path]] = {}
    for runtime in ("claude", "codex"):
        found: set[Path] = set()
        for path in package_root.rglob(f".{runtime}-plugin/plugin.json"):
            component = path.parent.parent.resolve(strict=True)
            if component != package_root:
                found.add(component)
        discovered_by_runtime[runtime] = found
    if discovered_by_runtime["claude"] != declared_roots or discovered_by_runtime["codex"] != declared_roots:
        fail("未宣言または不足した内部plugin manifestがあります")
    if set(skill_paths) != set(playbooks.values()):
        fail("Playbook packageの公開skillsはplaybook entryだけでなければなりません")

    print(f"Distribution: passed (1 public package, {len(playbooks)} playbooks, {len(internals)} internal plugins)")
    return 0


def mutate_catalog(root: Path, callback) -> None:
    for relative in (".claude-plugin/marketplace.json", ".agents/plugins/marketplace.json"):
        path = root / relative
        value = load_json(path)
        callback(value, "claude" if relative.startswith(".claude") else "codex")
        write_json(path, value)


def expect_rejected(root: Path, name: str, expected: str, mutate) -> None:
    with tempfile.TemporaryDirectory(prefix="distribution-negative-") as temporary:
        fixture = Path(temporary) / "repository"
        shutil.copytree(root, fixture, ignore=shutil.ignore_patterns(".git"), symlinks=True)
        mutate(fixture)
        try:
            validate_repository(fixture)
        except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as exc:
            if expected not in str(exc):
                fail(f"負例を期待した理由で拒否できません: {name}: {exc}")
        else:
            fail(f"負例を拒否できません: {name}")


def self_test(root: Path) -> int:
    def package_manifest(fixture: Path, runtime: str) -> Path:
        return fixture / f"plugins/.{runtime}-plugin/plugin.json"

    def first_mapping(fixture: Path, key: str) -> tuple[str, str]:
        data = load_json(package_manifest(fixture, "claude"))
        return next(iter(data["metadata"]["harness"][key].items()))

    def remove_first_internal(fixture: Path) -> None:
        key = first_mapping(fixture, "internalPlugins")[0]
        for runtime in ("claude", "codex"):
            path = package_manifest(fixture, runtime)
            data = load_json(path)
            data["metadata"]["harness"]["internalPlugins"].pop(key)
            write_json(path, data)

    def set_harness(fixture: Path, mutate) -> None:
        for runtime in ("claude", "codex"):
            path = package_manifest(fixture, runtime)
            data = load_json(path)
            mutate(data["metadata"]["harness"])
            write_json(path, data)

    cases = [
        (
            "marketplace-missing",
            "metadata.harness.marketplace",
            lambda f: set_harness(f, lambda h: h.pop("marketplace", None)),
        ),
        (
            "marketplace-mismatch",
            "marketplace名と一致しません",
            lambda f: set_harness(f, lambda h: h.update({"marketplace": "other-market"})),
        ),
        (
            "implements-kind",
            "implements.kindはplaybookだけです",
            lambda f: set_harness(f, lambda h: h.update({"implements": [
                {"id": h["marketplace"] + "/" + next(iter(h["playbooks"])), "version": 1,
                 "kind": "skill", "playbook": next(iter(h["playbooks"]))}]})),
        ),
        (
            "implements-id-invalid",
            "契約IDの形",
            lambda f: set_harness(f, lambda h: h.update({"implements": [
                {"id": next(iter(h["playbooks"])), "version": 1,
                 "kind": "playbook", "playbook": next(iter(h["playbooks"]))}]})),
        ),
        (
            "implements-unknown-key",
            "未知のキー",
            lambda f: set_harness(f, lambda h: h.update({"implements": [
                {"id": h["marketplace"] + "/" + next(iter(h["playbooks"])), "version": 1,
                 "kind": "playbook", "playbook": next(iter(h["playbooks"])), "skills": ["x"]}]})),
        ),
        (
            "internal-exposed",
            "1件",
            lambda f: mutate_catalog(f, lambda c, _r: c["plugins"].append(dict(c["plugins"][0]))),
        ),
        (
            "source-narrowed-to-internal",
            "./plugins",
            lambda f: mutate_catalog(
                f,
                lambda c, r: c["plugins"][0].update(
                    {"source": "./plugins/skills"}
                    if r == "claude"
                    else {"source": {"source": "local", "path": "./plugins/skills"}}
                ),
            ),
        ),
        (
            "surface-changed",
            "playbook-package",
            lambda f: [
                (lambda p, d: (d["metadata"]["harness"].update({"installationSurface": "skill"}), write_json(p, d)))(
                    package_manifest(f, r), load_json(package_manifest(f, r))
                )
                for r in ("claude", "codex")
            ],
        ),
        (
            "skills-empty",
            "非空配列",
            lambda f: [
                (lambda p, d: (d.update({"skills": []}), write_json(p, d)))(package_manifest(f, r), load_json(package_manifest(f, r)))
                for r in ("claude", "codex")
            ],
        ),
        (
            "skill-empty",
            "SKILL.mdが空",
            lambda f: (f / "plugins" / load_json(package_manifest(f, "claude"))["skills"][0] / "SKILL.md").write_text(" \n", encoding="utf-8"),
        ),
        (
            "internal-undeclared",
            "未宣言または不足した内部plugin manifestがあります",
            remove_first_internal,
        ),
        (
            "internal-path-escape",
            "不正なpath",
            lambda f: [
                (lambda p, d: (d["metadata"]["harness"]["internalPlugins"].update({first_mapping(f, "internalPlugins")[0]: "./../LICENSE"}), write_json(p, d)))(
                    package_manifest(f, r), load_json(package_manifest(f, r))
                )
                for r in ("claude", "codex")
            ],
        ),
        (
            "skill-path-escape",
            "不正なpath",
            lambda f: [
                (lambda p, d: (d["skills"].__setitem__(0, "./../LICENSE"), write_json(p, d)))(
                    package_manifest(f, r), load_json(package_manifest(f, r))
                )
                for r in ("claude", "codex")
            ],
        ),
        (
            "playbook-missing",
            "playbook",
            lambda f: (f / "plugins" / first_mapping(f, "playbooks")[1] / "playbook.yml").unlink(),
        ),
        (
            "internal-identity",
            "manifest identity",
            lambda f: (lambda p, d: (d.update({"name": "wrong"}), write_json(p, d)))(
                f / "plugins" / first_mapping(f, "internalPlugins")[1] / ".claude-plugin/plugin.json",
                load_json(f / "plugins" / first_mapping(f, "internalPlugins")[1] / ".claude-plugin/plugin.json"),
            ),
        ),
        (
            "package-symlink",
            "symlink",
            lambda f: (f / "plugins/forbidden-link").symlink_to("LICENSE"),
        ),
        (
            "license-mismatch",
            "LICENSE",
            lambda f: (f / "plugins/LICENSE").write_text("different\n", encoding="utf-8"),
        ),
    ]
    for name, expected, mutate in cases:
        expect_rejected(root, name, expected, mutate)
    print(f"Distribution negative tests: passed ({len(cases)} mutations)")
    return 0


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    if len(sys.argv) == 2 and sys.argv[1] == os.fspath(root):
        return validate_repository(root)
    if len(sys.argv) == 3 and sys.argv[1] == "--self-test" and sys.argv[2] == os.fspath(root):
        return self_test(root)
    print(f"usage: {Path(sys.argv[0]).name} [--self-test] {root}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError) as exc:
        print(f"Distribution: failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
