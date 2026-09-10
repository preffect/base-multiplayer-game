#!/usr/bin/env python3
"""GitHub project + issue seeding for a game repo (called by scripts/github-setup.sh).

Everything here goes through the GitHub API so the human never clicks in the UI (docs/WORKFLOW.md).
Idempotent: re-running finds existing labels/milestones/project/views/issues by name/title.
Write calls are BATCHED (many aliased mutations per GraphQL request) and paced, because GitHub's
secondary rate limit counts requests, not mutations, and trips on bursts of single creates.

Usage: setup_project.py <owner/repo> <project-title> <slug> <path-to-groundwork-issues.json> <project.env out> [--seed|--no-seed]
  --no-seed: labels + project + views only (no milestones, no groundwork epics) — for non-game repos.
"""
from __future__ import annotations

import json
import subprocess
import sys
import time
from pathlib import Path

REPO, PROJECT_TITLE, SLUG, ISSUES_FILE, PROJECT_ENV_OUT = sys.argv[1:6]
SEED_ISSUES = (sys.argv[6] if len(sys.argv) > 6 else "--seed") != "--no-seed"
OWNER, REPO_NAME = REPO.split("/")
TITLE_PLACEHOLDER, SLUG_PLACEHOLDER = "{title}", "{slug}"
STATUS_OPTIONS = [
    ("Backlog", "GRAY", "Not yet ready to start"),
    ("Ready", "BLUE", "Dependencies met; an agent can pick it up"),
    ("In progress", "YELLOW", "Being worked on"),
    ("In review", "ORANGE", "PR open; reviewers running"),
    ("Blocked", "RED", "Waiting on the user (label: pending) or another ticket"),
    ("Done", "GREEN", "Merged / closed"),
]
GITHUB_DEFAULT_STATUS_OPTIONS = ["Todo", "In Progress", "Done"]
# (name, layout, filter, visible columns) — grouping is not exposed by the API, so views use filters.
VIEWS = [
    ("Board", "BOARD_LAYOUT", "-label:epic", ["Title", "Assignees", "Labels", "Parent issue"]),
    ("Epics (roadmap)", "TABLE_LAYOUT", "label:epic", ["Title", "Status", "Sub-issues progress", "Milestone", "Assignees"]),
    ("All tickets", "TABLE_LAYOUT", "-label:epic", ["Title", "Status", "Labels", "Parent issue", "Milestone", "Assignees"]),
    ("Needs you", "TABLE_LAYOUT", "assignee:@me", ["Title", "Status", "Labels", "Parent issue"]),
]
BATCH_SIZE = 20          # aliased mutations per GraphQL request
PAUSE_SECONDS = 1.0      # between write requests
RATE_LIMIT_BACKOFF_SECONDS = 60
RATE_LIMIT_MAX_RETRIES = 10
TOLERATED_ERROR_FRAGMENTS = ("already", "sub-issue", "Name has already been taken")


class GitHubError(RuntimeError):
    """A gh / GraphQL call failed; setup cannot continue meaningfully."""


def _report_github_error(exc_type, exc, tb):  # actionable one-liner instead of a stack trace
    if issubclass(exc_type, GitHubError):
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(1)
    sys.__excepthook__(exc_type, exc, tb)


sys.excepthook = _report_github_error


def _is_rate_limited(text: str) -> bool:
    lowered = text.lower()
    return "rate limit" in lowered or "secondary" in lowered


def _run_with_backoff(argv: list[str], stdin: str | None = None) -> subprocess.CompletedProcess:
    """Run a gh command; on GitHub's (secondary) rate limit wait and retry instead of failing."""
    result = subprocess.run(argv, input=stdin, capture_output=True, text=True)
    for attempt in range(RATE_LIMIT_MAX_RETRIES):
        if not _is_rate_limited(result.stderr + result.stdout[:500]):
            return result
        print(f"rate limited by GitHub; waiting {RATE_LIMIT_BACKOFF_SECONDS}s (attempt {attempt + 1}/{RATE_LIMIT_MAX_RETRIES})", file=sys.stderr)
        time.sleep(RATE_LIMIT_BACKOFF_SECONDS)
        result = subprocess.run(argv, input=stdin, capture_output=True, text=True)
    return result


def gh(*args: str, check: bool = True) -> str:
    result = _run_with_backoff(["gh", *args])
    if result.returncode != 0 and check:
        raise GitHubError(f"gh {' '.join(args[:3])} failed: {result.stderr.strip()[:300]}")
    return result.stdout.strip()


def graphql(query: str, variables: dict | None = None, tolerate: tuple[str, ...] = ()) -> dict:
    """One GraphQL request; fail fast on transport/API errors except tolerated re-run conditions."""
    payload = json.dumps({"query": query, "variables": variables or {}})
    result = _run_with_backoff(["gh", "api", "graphql", "--input", "-"], stdin=payload)
    data = json.loads(result.stdout or "{}")
    errors = data.get("errors", [])
    if result.returncode != 0 or errors:
        message = "; ".join(e.get("message", "") for e in errors) or result.stderr.strip()
        if errors and all(any(fragment in (e.get("message") or "") for fragment in tolerate) for e in errors):
            return data.get("data") or {}
        raise GitHubError(f"graphql failed: {message[:300]}")
    return data["data"]


def graphql_batch(mutation_field: str, input_type: str, inputs: list[dict], selection: str,
                  tolerate: tuple[str, ...] = ()) -> list[dict | None]:
    """Run `mutation_field(input:$iN) { selection }` for every input, BATCH_SIZE aliases per request.

    Returns one result per input (None where the mutation errored with a tolerated message).
    """
    results: list[dict | None] = []
    for start in range(0, len(inputs), BATCH_SIZE):
        chunk = inputs[start:start + BATCH_SIZE]
        declarations = ", ".join(f"$i{n}: {input_type}!" for n in range(len(chunk)))
        fields = " ".join(f"m{n}: {mutation_field}(input: $i{n}) {{ {selection} }}" for n in range(len(chunk)))
        data = graphql(f"mutation({declarations}) {{ {fields} }}", {f"i{n}": value for n, value in enumerate(chunk)}, tolerate)
        results.extend(data.get(f"m{n}") for n in range(len(chunk)))
        time.sleep(PAUSE_SECONDS)
    return results


spec = json.loads(Path(ISSUES_FILE).read_text())
fill = lambda text: text.replace(TITLE_PLACEHOLDER, PROJECT_TITLE).replace(SLUG_PLACEHOLDER, SLUG)

repository_id = graphql('query($o:String!,$n:String!){ repository(owner:$o,name:$n){ id } }', {"o": OWNER, "n": REPO_NAME})["repository"]["id"]

# ---------------------------------------------------------------- labels (one batched request)
# gh label list paginates for us, so a repo with more than 100 labels is handled correctly.
label_ids = {label["name"]: label["id"] for label in json.loads(gh("label", "list", "-R", REPO, "--limit", "1000", "--json", "name,id") or "[]")}
missing_labels = [
    {"repositoryId": repository_id, "name": name, "color": color, "description": description}
    for name, (description, color) in spec["labels"].items() if name not in label_ids
]
for created in graphql_batch("createLabel", "CreateLabelInput", missing_labels, "label { id name }", TOLERATED_ERROR_FRAGMENTS):
    if created:
        label_ids[created["label"]["name"]] = created["label"]["id"]
print(f"labels: {len(spec['labels'])} ensured ({len(missing_labels)} created)")

# ---------------------------------------------------------------- milestones (games only)
# --paginate walks every page, so a repo with more than 100 milestones is handled correctly.
milestone_ids = {
    m["title"]: m["node_id"]
    for m in map(json.loads, gh("api", "--paginate", "--jq", ".[] | {title, node_id}", f"repos/{REPO}/milestones?state=all&per_page=100").splitlines())
}
if SEED_ISSUES:
    for title, description in spec["milestones"].items():
        if title not in milestone_ids:
            created = json.loads(gh("api", f"repos/{REPO}/milestones", "-f", f"title={title}", "-f", f"description={description}"))
            milestone_ids[title] = created["node_id"]
            time.sleep(PAUSE_SECONDS)
    print(f"milestones: {list(spec['milestones'])}")

# ---------------------------------------------------------------- project + views
projects = json.loads(gh("project", "list", "--owner", OWNER, "--format", "json", "--limit", "100") or '{"projects":[]}')["projects"]
project = next((p for p in projects if p["title"] == PROJECT_TITLE and not p.get("closed")), None)
if project is None:
    project = json.loads(gh("project", "create", "--owner", OWNER, "--title", PROJECT_TITLE, "--format", "json"))
project_number, project_id = project["number"], project["id"]
gh("project", "link", str(project_number), "--owner", OWNER, "--repo", REPO, check=False)  # already linked on re-run

fields = json.loads(gh("project", "field-list", str(project_number), "--owner", OWNER, "--format", "json"))["fields"]
status_field = next(f for f in fields if f["name"] == "Status")
current_options = [o["name"] for o in status_field.get("options", [])]
wanted_names = [name for name, _, _ in STATUS_OPTIONS]
if current_options == GITHUB_DEFAULT_STATUS_OPTIONS:
    # Replacing options without ids resets every item's Status, so only ever do it to a fresh board.
    options_literal = ",".join(f'{{name:"{n}",color:{c},description:"{d}"}}' for n, c, d in STATUS_OPTIONS)
    graphql(f'mutation {{ updateProjectV2Field(input:{{fieldId:"{status_field["id"]}", singleSelectOptions:[{options_literal}]}}) {{ projectV2Field {{ ... on ProjectV2SingleSelectField {{ id }} }} }} }}')
elif current_options != wanted_names:
    print(f"note: Status options are customised ({current_options}); leaving them untouched. "
          f"project-sync.sh needs {['Backlog', 'Blocked', 'Done']} to exist.")
field_ids = {f["name"]: f["id"] for f in fields}

existing_views = {v["name"]: v["id"] for v in graphql(
    'query($id:ID!){ node(id:$id){ ... on ProjectV2 { views(first:20){ nodes{ id name } } } } }', {"id": project_id}
)["node"]["views"]["nodes"]}
default_view_id = existing_views.pop("View 1", None)
view_updates = []
for name, layout, view_filter, columns in VIEWS:
    view_id = existing_views.get(name) or default_view_id
    default_view_id = None if view_id else default_view_id
    if view_id is None:
        view_id = graphql(
            'mutation($p:ID!,$n:String!,$l:ProjectV2ViewLayout!){ createProjectV2View(input:{projectId:$p,name:$n,layout:$l}){ projectV2View{ id } } }',
            {"p": project_id, "n": name, "l": layout},
        )["createProjectV2View"]["projectV2View"]["id"]
        time.sleep(PAUSE_SECONDS)
    view_updates.append({"viewId": view_id, "name": name, "layout": layout, "filter": view_filter,
                         "configuration": {"visibleFieldIds": [field_ids[c] for c in columns if c in field_ids]}})
graphql_batch("updateProjectV2View", "UpdateProjectV2ViewInput", view_updates, "projectV2View { id }")
print(f"project: #{project_number} {project['url']} (views: {[v[0] for v in VIEWS]})")

Path(PROJECT_ENV_OUT).write_text(
    "# Generated by scripts/github-setup.sh — ids used by project-sync.sh / issue-status.sh. Safe to commit.\n"
    f"REPO={REPO}\nPROJECT_OWNER={OWNER}\nPROJECT_NUMBER={project_number}\nPROJECT_ID={project_id}\nSTATUS_FIELD_ID={status_field['id']}\n"
)

# ---------------------------------------------------------------- issues (games only)
if not SEED_ISSUES:
    print("issues: --no-seed, skipping the groundwork seed")
    sys.exit(0)

all_issues = json.loads(gh("issue", "list", "-R", REPO, "--state", "all", "--limit", "500", "--json", "title,number,id,body,labels") or "[]")
existing_by_title = {i["title"]: i for i in all_issues}
seed_titles = {fill(i["title"]) for i in spec["issues"]}
has_epics = any(label["name"] == "epic" for issue in all_issues for label in issue["labels"])
if has_epics and not (seed_titles & set(existing_by_title)):
    print("issues: repo already has epics that were not seeded from this template — skipping the groundwork seed "
          "so hand-written planning is not duplicated (nothing else to do).")
    sys.exit(0)

spec_by_key = {issue["key"]: issue for issue in spec["issues"]}
to_create = [issue for issue in spec["issues"] if fill(issue["title"]) not in existing_by_title]
create_inputs = [{
    "repositoryId": repository_id,
    "title": fill(issue["title"]),
    "body": fill(issue["body"]) + ("" if issue.get("epic") else fill(spec["footer"])),
    "labelIds": [label_ids[label] for label in issue["labels"] if label in label_ids],
    "milestoneId": milestone_ids.get(issue["milestone"]),
} for issue in to_create]
created_issues = graphql_batch("createIssue", "CreateIssueInput", create_inputs, "issue { id number title body }")
for issue, created in zip(to_create, created_issues):
    if created is None:
        raise GitHubError(f"issue '{fill(issue['title'])}' was not created")
    existing_by_title[created["issue"]["title"]] = created["issue"]
numbers = {key: existing_by_title[fill(issue["title"])]["number"] for key, issue in spec_by_key.items()}
node_ids = {key: existing_by_title[fill(issue["title"])]["id"] for key, issue in spec_by_key.items()}
print(f"issues: {len(spec['issues'])} ensured ({len(to_create)} created)")

# Epic backlinks (body prefix) + native sub-issue links — both batched; already-linked children tolerated.
backlinks, links = [], []
for epic in (issue for issue in spec["issues"] if issue.get("epic")):
    for child_key in epic["children"]:
        child = existing_by_title[fill(spec_by_key[child_key]["title"])]
        body = child.get("body") or ""
        if not body.startswith("**Epic:**"):
            backlinks.append({"id": child["id"], "body": f"**Epic:** #{numbers[epic['key']]}\n\n{body}"})
        links.append({"issueId": node_ids[epic["key"]], "subIssueId": node_ids[child_key]})
graphql_batch("updateIssue", "UpdateIssueInput", backlinks, "issue { id }")
graphql_batch("addSubIssue", "AddSubIssueInput", links, "issue { number }", TOLERATED_ERROR_FRAGMENTS)
print(f"sub-issues linked ({len(links)}), epic backlinks written ({len(backlinks)})")
