#!/usr/bin/env python3
"""GitHub project + issue seeding for a game repo (called by scripts/github-setup.sh).

Everything here goes through the GitHub API so the human never clicks in the UI (WORKFLOW.md).
Idempotent: re-running finds existing labels/milestones/project/views/issues by name/title.

Usage: setup_project.py <owner/repo> <project-title> <slug> <path-to-groundwork-issues.json> <project.env out>
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
import time
from pathlib import Path

REPO, PROJECT_TITLE, SLUG, ISSUES_FILE, PROJECT_ENV_OUT = sys.argv[1:6]
OWNER = REPO.split("/")[0]
TITLE_PLACEHOLDER, SLUG_PLACEHOLDER = "{title}", "{slug}"
STATUS_OPTIONS = [
    ("Backlog", "GRAY", "Not yet ready to start"),
    ("Ready", "BLUE", "Dependencies met; an agent can pick it up"),
    ("In progress", "YELLOW", "Being worked on"),
    ("In review", "ORANGE", "PR open; reviewers running"),
    ("Blocked", "RED", "Waiting on the user (label: pending) or another ticket"),
    ("Done", "GREEN", "Merged / closed"),
]
# (name, layout, filter, visible columns) — grouping is not exposed by the API, so views use filters.
VIEWS = [
    ("Board", "BOARD_LAYOUT", "-label:epic", ["Title", "Assignees", "Labels", "Parent issue"]),
    ("Epics (roadmap)", "TABLE_LAYOUT", "label:epic", ["Title", "Status", "Sub-issues progress", "Milestone", "Assignees"]),
    ("All tickets", "TABLE_LAYOUT", "-label:epic", ["Title", "Status", "Labels", "Parent issue", "Milestone", "Assignees"]),
    ("Needs you", "TABLE_LAYOUT", "assignee:@me", ["Title", "Status", "Labels", "Parent issue"]),
]
PAUSE_SECONDS = 0.3


def gh(*args: str, check: bool = True) -> str:
    result = subprocess.run(["gh", *args], capture_output=True, text=True)
    if result.returncode != 0 and check:
        print(f"gh {' '.join(args[:3])} failed: {result.stderr.strip()[:300]}", file=sys.stderr)
    return result.stdout.strip()


def graphql(query: str, variables: dict | None = None) -> dict:
    payload = json.dumps({"query": query, "variables": variables or {}})
    result = subprocess.run(["gh", "api", "graphql", "--input", "-"], input=payload, capture_output=True, text=True)
    data = json.loads(result.stdout or "{}")
    if result.returncode != 0 or "errors" in data:
        print(f"graphql failed: {(result.stderr or result.stdout)[:300]}", file=sys.stderr)
    return data.get("data", {})


spec = json.loads(Path(ISSUES_FILE).read_text())
fill = lambda text: text.replace(TITLE_PLACEHOLDER, PROJECT_TITLE).replace(SLUG_PLACEHOLDER, SLUG)

# ---------------------------------------------------------------- labels
existing_labels = set(gh("label", "list", "-R", REPO, "--limit", "300", "--json", "name", "--jq", ".[].name").split())
for name, (description, color) in spec["labels"].items():
    if name not in existing_labels:
        gh("label", "create", name, "-R", REPO, "-d", description, "-c", color)
print(f"labels: {len(spec['labels'])} ensured")

# ---------------------------------------------------------------- milestones
milestones = {m["title"]: m["number"] for m in json.loads(gh("api", f"repos/{REPO}/milestones?state=all&per_page=100") or "[]")}
for title, description in spec["milestones"].items():
    if title not in milestones:
        created = json.loads(gh("api", f"repos/{REPO}/milestones", "-f", f"title={title}", "-f", f"description={description}"))
        milestones[title] = created["number"]
print(f"milestones: {list(spec['milestones'])}")

# ---------------------------------------------------------------- project
projects = json.loads(gh("project", "list", "--owner", OWNER, "--format", "json", "--limit", "100") or '{"projects":[]}')["projects"]
project = next((p for p in projects if p["title"] == PROJECT_TITLE and not p.get("closed")), None)
if project is None:
    project = json.loads(gh("project", "create", "--owner", OWNER, "--title", PROJECT_TITLE, "--format", "json"))
project_number, project_id = project["number"], project["id"]
gh("project", "link", str(project_number), "--owner", OWNER, "--repo", REPO, check=False)

fields = json.loads(gh("project", "field-list", str(project_number), "--owner", OWNER, "--format", "json"))["fields"]
status_field = next(f for f in fields if f["name"] == "Status")
wanted_names = [name for name, _, _ in STATUS_OPTIONS]
if [o["name"] for o in status_field.get("options", [])] != wanted_names:
    options_literal = ",".join(f'{{name:"{n}",color:{c},description:"{d}"}}' for n, c, d in STATUS_OPTIONS)
    graphql(f'mutation {{ updateProjectV2Field(input:{{fieldId:"{status_field["id"]}", singleSelectOptions:[{options_literal}]}}) {{ projectV2Field {{ ... on ProjectV2SingleSelectField {{ id }} }} }} }}')
field_ids = {f["name"]: f["id"] for f in fields}

existing_views = {v["name"]: v["id"] for v in graphql(
    'query($id:ID!){ node(id:$id){ ... on ProjectV2 { views(first:20){ nodes{ id name } } } } }', {"id": project_id}
)["node"]["views"]["nodes"]}
default_view_id = existing_views.pop("View 1", None)
for name, layout, view_filter, columns in VIEWS:
    view_id = existing_views.get(name) or default_view_id
    default_view_id = None if view_id else default_view_id
    if view_id is None:
        view_id = graphql(
            'mutation($p:ID!,$n:String!,$l:ProjectV2ViewLayout!){ createProjectV2View(input:{projectId:$p,name:$n,layout:$l}){ projectV2View{ id } } }',
            {"p": project_id, "n": name, "l": layout},
        )["createProjectV2View"]["projectV2View"]["id"]
    graphql(
        'mutation($v:ID!,$n:String!,$l:ProjectV2ViewLayout!,$f:String!,$c:[ID!]!){ updateProjectV2View(input:{viewId:$v,name:$n,layout:$l,filter:$f,configuration:{visibleFieldIds:$c}}){ projectV2View{ id } } }',
        {"v": view_id, "n": name, "l": layout, "f": view_filter, "c": [field_ids[c] for c in columns if c in field_ids]},
    )
print(f"project: #{project_number} {project['url']} (views: {[v[0] for v in VIEWS]})")

Path(PROJECT_ENV_OUT).write_text(
    "# Generated by scripts/github-setup.sh — ids used by project-sync.sh / issue-status.sh. Safe to commit.\n"
    f"REPO={REPO}\nPROJECT_OWNER={OWNER}\nPROJECT_NUMBER={project_number}\nPROJECT_ID={project_id}\nSTATUS_FIELD_ID={status_field['id']}\n"
)

# ---------------------------------------------------------------- issues
existing_issues = {i["title"]: i["number"] for i in json.loads(gh("issue", "list", "-R", REPO, "--state", "all", "--limit", "500", "--json", "title,number") or "[]")}
numbers: dict[str, int] = {}
for issue in spec["issues"]:
    title = fill(issue["title"])
    if title in existing_issues:
        numbers[issue["key"]] = existing_issues[title]
        continue
    body = fill(issue["body"]) + ("" if issue.get("epic") else fill(spec["footer"]))
    label_args = [arg for label in issue["labels"] for arg in ("-l", label)]
    url = gh("issue", "create", "-R", REPO, "-t", title, "-b", body, "-m", issue["milestone"], *label_args)
    numbers[issue["key"]] = int(url.rstrip("/").rsplit("/", 1)[-1])
    time.sleep(PAUSE_SECONDS)
print(f"issues: {len(numbers)} ensured")

# Epic backlinks + sub-issue links (idempotent: addSubIssue on an existing child is a no-op error we ignore).
node_ids = {key: gh("issue", "view", str(num), "-R", REPO, "--json", "id", "--jq", ".id") for key, num in numbers.items()}
for epic in (i for i in spec["issues"] if i.get("epic")):
    for child_key in epic["children"]:
        child_body = gh("issue", "view", str(numbers[child_key]), "-R", REPO, "--json", "body", "--jq", ".body")
        if not child_body.startswith("**Epic:**"):
            gh("issue", "edit", str(numbers[child_key]), "-R", REPO, "-b", f"**Epic:** #{numbers[epic['key']]}\n\n{child_body}")
        graphql(
            'mutation($p:ID!,$c:ID!){ addSubIssue(input:{issueId:$p, subIssueId:$c}){ issue{ number } } }',
            {"p": node_ids[epic["key"]], "c": node_ids[child_key]},
        )
        time.sleep(PAUSE_SECONDS)
print("sub-issues linked")
