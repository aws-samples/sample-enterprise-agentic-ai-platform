#!/usr/bin/env python3
"""
Backfill the lifecycle DynamoDB store with authoritative deployed-agent facts.

Makes DynamoDB the single source of truth for the console "My Deployed Agents"
view: for every AgentCore runtime that belongs to a nocode-user application, it
records the real runtime ARN, the owning application (app_name), the pattern,
and which runtime is the application's entrypoint (is_entrypoint) — read from
each app's application.yaml (role: orchestrator/supervisor).

This removes the need to reverse-engineer truncated runtime names at read time.

Data sources (authoritative):
  - AgentCore ListAgentRuntimes  -> real runtime ARNs + names + status
  - CodeCommit application.yaml   -> app name, pattern (architecture), agents+roles

Item written (keyed by agent_name = the AgentCore runtime name):
  app_name, pattern, pattern_folder, runtime_arn, runtime_name,
  endpoint_qualifier, status, is_entrypoint, deployed_by="nocode-user"

Usage:
  python3 backfill_deployed_agents.py [--table <name>] [--repo nocode-user] \
      [--domain nocode-user] [--region us-east-1] [--dry-run]
"""

import argparse
import json
import re
import sys

import boto3
import yaml

PATTERN_FOLDERS = [
    "standalone",
    "orchestration/supervisor",
    "orchestration/sequential",
    "orchestration/router",
    "choreography/swarm",
]

ORCHESTRATOR_ROLES = {"orchestrator", "supervisor", "coordinator"}
ORCHESTRATOR_RE = re.compile(r"orchestrator|supervisor|coordinator", re.IGNORECASE)


def normalize(s: str) -> str:
    """Lowercase and map hyphens/spaces to underscores (AgentCore runtime-name form)."""
    return re.sub(r"[-\s]+", "_", (s or "").strip().lower())


# ---------------------------------------------------------------------------
# Discovery: runtimes + application manifests
# ---------------------------------------------------------------------------

def list_runtimes(region: str) -> list[dict]:
    ac = boto3.client("bedrock-agentcore-control", region_name=region)
    out = []
    paginator = ac.get_paginator("list_agent_runtimes")
    for page in paginator.paginate():
        for rt in page.get("agentRuntimes", []):
            out.append({
                "name": rt.get("agentRuntimeName", ""),
                "arn": rt.get("agentRuntimeArn", ""),
                "status": rt.get("status", ""),
            })
    return out


def _get_folder(cc, repo: str, path: str) -> list[str]:
    try:
        resp = cc.get_folder(repositoryName=repo, folderPath=path)
        return [
            s.get("relativePath", "")
            for s in resp.get("subFolders", [])
            if s.get("relativePath") and not s["relativePath"].startswith(".")
        ]
    except cc.exceptions.FolderDoesNotExistException:
        return []


def _get_file(cc, repo: str, path: str) -> str | None:
    try:
        resp = cc.get_file(repositoryName=repo, filePath=path)
        return resp["fileContent"].decode("utf-8")
    except cc.exceptions.FileDoesNotExistException:
        return None


def _norm_edges(val) -> list[str]:
    """Normalize an edge field (calls/called_by/can_call/depends_on) to list[str]."""
    if val is None:
        return []
    if isinstance(val, str):
        return [val]
    if isinstance(val, list):
        return [str(x) for x in val]
    return []


def discover_apps(cc, repo: str) -> list[dict]:
    """Return [{app_name, pattern_folder, pattern, agents:[{name, role, calls, called_by, can_call, depends_on}]}].

    Parses application.yaml for the app topology: agents (or steps for sequential
    workflows) plus their relationship edges. This is the authoritative source of
    the deployed architecture graph rendered in the console.
    """
    apps = []
    for folder in PATTERN_FOLDERS:
        for app_name in _get_folder(cc, repo, f"/{folder}"):
            # application.yaml lives at canonical or double-nested path.
            yaml_text = None
            for p in (
                f"{folder}/{app_name}/application.yaml",
                f"{folder}/{app_name}/{app_name}/application.yaml",
            ):
                yaml_text = _get_file(cc, repo, p)
                if yaml_text:
                    break

            pattern = "standalone" if folder == "standalone" else "multi-agent"
            agents: list[dict] = []
            if yaml_text:
                try:
                    doc = yaml.safe_load(yaml_text) or {}
                    pattern = str(doc.get("architecture", pattern)).lower()
                    # Sequential workflows use `steps:`; others use `agents:`.
                    raw = doc.get("agents") or doc.get("steps") or []
                    for a in raw:
                        if not isinstance(a, dict):
                            continue
                        agents.append({
                            "name": str(a.get("name", "")),
                            "role": str(a.get("role", "") or "").lower(),
                            "calls": _norm_edges(a.get("calls")),
                            "called_by": _norm_edges(a.get("called_by")),
                            "can_call": _norm_edges(a.get("can_call")),
                            "depends_on": _norm_edges(a.get("depends_on")),
                        })
                except yaml.YAMLError as e:
                    print(f"  ! failed to parse {app_name}/application.yaml: {e}")

            apps.append({
                "app_name": app_name,
                "pattern_folder": folder,
                "pattern": pattern,
                "agents": agents,
            })
    return apps


# ---------------------------------------------------------------------------
# Matching: runtime -> (app, agent, is_entrypoint)
# ---------------------------------------------------------------------------

def assign(runtimes: list[dict], apps: list[dict], domain: str, bu: str = "") -> list[dict]:
    """Assign each nocode-user runtime to its (app, agent). Returns item dicts."""
    dom = normalize(domain)
    bu_value = bu or domain
    # Per-app topology JSON (authoritative agent graph) recorded on every item.
    topology_json: dict[str, str] = {}
    for app in apps:
        topology_json[app["app_name"]] = json.dumps({
            "pattern": app["pattern"],
            "agents": app["agents"],
        })

    # Candidate (app, agent) full runtime-name bases, most specific first.
    agent_specs = []  # (full, app, agent_name, role, pattern, folder, is_entry)
    for app in apps:
        app_pfx = f"{dom}_{normalize(app['app_name'])}"
        if app["agents"]:
            for ag in app["agents"]:
                full = f"{app_pfx}_{normalize(ag['name'])}"
                agent_specs.append((
                    full, app["app_name"], ag["name"], ag["role"],
                    app["pattern"], app["pattern_folder"],
                    ag["role"] in ORCHESTRATOR_ROLES,
                ))
        else:
            # No manifest: treat the app itself as a single (possibly entry) agent.
            agent_specs.append((
                app_pfx, app["app_name"], app["app_name"], "standalone",
                app["pattern"], app["pattern_folder"], True,
            ))

    # App-only prefixes for the fallback branch (longest wins).
    app_pfxs = sorted(
        ((f"{dom}_{normalize(a['app_name'])}", a) for a in apps),
        key=lambda t: len(t[0]), reverse=True,
    )

    items: list[dict] = []
    for rt in runtimes:
        n = normalize(rt["name"])
        if not n.startswith(dom):
            continue  # only nocode-user domain runtimes belong to this view

        best = None
        best_score = -1
        for full, app_name, ag_name, role, pattern, folder, is_entry in agent_specs:
            # Runtime name is a truncation of full (or equal); require prefix relation.
            if full.startswith(n) or n.startswith(full):
                score = len(_common_prefix(full, n))
                if score > best_score:
                    best_score = score
                    best = (app_name, ag_name, role, pattern, folder, is_entry)

        if best is None:
            # Fallback: match by app prefix only (longest app prefix wins).
            for pfx, app in app_pfxs:
                if n.startswith(pfx):
                    suffix = n[len(pfx):]
                    is_orch = bool(ORCHESTRATOR_RE.search(suffix))
                    best = (
                        app["app_name"], rt["name"],
                        "orchestrator" if is_orch else "worker",
                        app["pattern"], app["pattern_folder"], is_orch,
                    )
                    break

        if best is None:
            print(f"  ? no app match for runtime {rt['name']} — skipping")
            continue

        app_name, ag_name, ag_role, pattern, folder, is_entry = best
        items.append({
            "agent_name": rt["name"],
            "app_name": app_name,
            "agent_key": ag_name,
            "agent_role": ag_role,
            "pattern": pattern,
            "pattern_folder": folder,
            "runtime_arn": rt["arn"],
            "runtime_name": rt["name"],
            # Empty qualifier => invoke-proxy omits it => AgentCore DEFAULT endpoint.
            "endpoint_qualifier": "",
            "status": rt["status"],
            "is_entrypoint": bool(is_entry),
            "deployed_by": "nocode-user",
            # Owning business unit / domain — single shared table discriminator.
            "bu": bu_value,
            # Authoritative agent graph for the console architecture pane.
            "app_topology": topology_json.get(app_name, ""),
        })

    _ensure_single_entrypoint(items)
    return items


def _common_prefix(a: str, b: str) -> str:
    i = 0
    for x, y in zip(a, b):
        if x != y:
            break
        i += 1
    return a[:i]


def _ensure_single_entrypoint(items: list[dict]) -> None:
    """Guarantee exactly one entrypoint per app (prefer an orchestrator-named one)."""
    by_app: dict[str, list[dict]] = {}
    for it in items:
        by_app.setdefault(it["app_name"], []).append(it)
    for app_name, group in by_app.items():
        entries = [it for it in group if it["is_entrypoint"]]
        if len(entries) == 1:
            continue
        for it in group:
            it["is_entrypoint"] = False
        if entries:
            entries[0]["is_entrypoint"] = True  # first declared orchestrator
        else:
            named = next((it for it in group if ORCHESTRATOR_RE.search(it["runtime_name"])), None)
            (named or group[0])["is_entrypoint"] = True


# ---------------------------------------------------------------------------
# Write
# ---------------------------------------------------------------------------

def upsert(table_name: str, items: list[dict], region: str, dry_run: bool) -> None:
    if dry_run:
        for it in sorted(items, key=lambda x: (x["app_name"], not x["is_entrypoint"])):
            flag = "  <-- ENTRYPOINT" if it["is_entrypoint"] else ""
            print(f"  [{it['app_name']}] {it['runtime_name']}{flag}")
        print(f"\nDRY RUN — would upsert {len(items)} items into {table_name}")
        return

    ddb = boto3.resource("dynamodb", region_name=region)
    table = ddb.Table(table_name)
    for it in items:
        # Merge onto any existing lifecycle row (preserve current_state/version/etc).
        expr = (
            "SET app_name = :app, agent_key = :ak, agent_role = :ar, "
            "pattern = :pat, pattern_folder = :pf, "
            "runtime_arn = :arn, runtime_name = :rn, endpoint_qualifier = :eq, "
            "#st = :status, is_entrypoint = :ep, deployed_by = :db, "
            "bu = :bu, app_topology = :topo"
        )
        table.update_item(
            Key={"agent_name": it["agent_name"]},
            UpdateExpression=expr,
            ExpressionAttributeNames={"#st": "status"},
            ExpressionAttributeValues={
                ":app": it["app_name"],
                ":ak": it["agent_key"],
                ":ar": it["agent_role"],
                ":pat": it["pattern"],
                ":pf": it["pattern_folder"],
                ":arn": it["runtime_arn"],
                ":rn": it["runtime_name"],
                ":eq": it["endpoint_qualifier"],
                ":status": it["status"],
                ":ep": it["is_entrypoint"],
                ":db": it["deployed_by"],
                ":bu": it["bu"],
                ":topo": it["app_topology"],
            },
        )
    print(f"✓ upserted {len(items)} deployed-agent items into {table_name}")


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--table", default="agent-school-lifecycle-team-bu-1-dev")
    p.add_argument("--repo", default="nocode-user")
    p.add_argument("--domain", default="nocode-user")
    p.add_argument("--bu", default="",
                   help="Business unit / domain to stamp on each item (single shared table discriminator). Defaults to --domain.")
    p.add_argument("--region", default="us-east-1")
    p.add_argument("--dry-run", action="store_true")
    args = p.parse_args()

    cc = boto3.client("codecommit", region_name=args.region)

    print("Listing AgentCore runtimes...")
    runtimes = list_runtimes(args.region)
    print(f"  {len(runtimes)} runtimes")

    print(f"Discovering apps in repo '{args.repo}'...")
    apps = discover_apps(cc, args.repo)
    for a in apps:
        print(f"  {a['pattern_folder']}/{a['app_name']} [{a['pattern']}] "
              f"agents={[ag['name'] for ag in a['agents']]}")

    items = assign(runtimes, apps, args.domain, args.bu)
    if not items:
        print("No matching runtimes found — nothing to write.")
        sys.exit(0)

    upsert(args.table, items, args.region, args.dry_run)


if __name__ == "__main__":
    main()
