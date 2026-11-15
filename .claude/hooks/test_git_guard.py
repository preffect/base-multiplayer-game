"""Tests for git_guard.py, the PreToolUse hook that blocks destructive git commands.

Run: python3 -m unittest discover -s .claude/hooks
"""

import json
import subprocess
import sys
import unittest
from pathlib import Path

sys.dont_write_bytecode = True  # No __pycache__ beside the hook, which .claude/.gitignore would let in.
sys.path.insert(0, str(Path(__file__).parent))
import git_guard  # noqa: E402

HOOK = Path(__file__).parent / "git_guard.py"

BLOCKED = [
    # push: force, in every place and spelling
    "git push --force",
    "git push --force origin main",
    "git push origin main --force",
    "git push origin main -f",
    "git push -f",
    "git push -uf origin main",
    "git push -fu origin main",
    "git push --force-with-lease",
    "git push --force-with-lease=main",
    "git push --force-with-lease=main:abc123 origin main",
    "git push origin main --force-if-includes",
    "git push origin +main",
    "git push origin +HEAD:main",
    "git push origin main +feature",
    # push: deleting or mirroring remote refs
    "git push --mirror",
    "git push origin --delete feature",
    "git push origin -d feature",
    "git push origin :feature",
    "git push --prune origin",
    # git's own options before the subcommand
    "git -C /workspace push -f",
    "git -c core.editor=true push --force",
    "git -c user.name=x -C . push origin +main",
    "git --git-dir=.git push -f",
    "git --no-pager push --force",
    "/usr/bin/git push -f",
    "git -c alias.p='push --force' p origin main",
    "git -c 'alias.wipe=!git reset --hard' wipe",
    # reset --hard, wherever the option is
    "git reset --hard",
    "git reset --hard HEAD~1",
    "git reset -q --hard origin/main",
    "git reset origin/main --hard",
    "git -C . reset --hard",
    # clean, with any options
    "git clean",
    "git clean -fd",
    "git clean -x -f -d",
    "git -C sub clean -fdx",
    # branch: deleting main or master
    "git branch -D main",
    "git branch -d master",
    "git branch --delete main",
    "git branch -D feature main",
    "git branch -dr origin/main",
    # history rewrites
    "git filter-branch --tree-filter 'rm x' HEAD",
    "git filter-repo --path secret --invert-paths",
    # compound commands, quoting, wrappers, nesting
    "git add . && git commit -m wip && git push -f",
    "git status; git push --force",
    "git fetch || git reset --hard origin/main",
    "echo y | git clean -fd",
    "git status\ngit push -f",
    "GIT_TRACE=1 git push -f",
    "FOO=1 BAR=2 git push --force",
    "env GIT_DIR=.git git push -f",
    "sudo git push -f",
    "timeout 60 git push --force",
    "echo main | xargs git push -f origin",
    "(cd sub && git push -f)",
    "git 'push' '--force'",
    'git "push" "-f"',
    "g\\it push -f",
    "git push\\\n  --force",
    "bash -c 'git push -f'",
    'sh -c "cd x && git reset --hard"',
    "bash -lc 'git clean -fd'",
    "eval git push -f",
    "echo $(git push -f)",
    'echo "$(git push --force)"',
    "echo `git reset --hard`",
    "bash <<'EOF'\ngit push -f\nEOF",
    # unsplittable, and naming a guarded subcommand: fail closed
    "git push -f 'unclosed",
]

ALLOWED = [
    "git status",
    "git push",
    "git push origin main",
    "git push -u origin feature",
    "git push --set-upstream origin feature",
    "git push origin HEAD",
    "git push origin HEAD:feature",
    "git push --tags",
    "git push -o ci.skip origin feature",
    "git push origin :",
    "git push --dry-run origin feature",
    "git -C /workspace push origin feature",
    "git reset",
    "git reset --soft HEAD~1",
    "git reset HEAD file.ts",
    "git reset --mixed",
    "git branch -d feature",
    "git branch -D old-feature",
    "git branch main",
    "git branch --list",
    "git checkout main",
    "git switch -c feature",
    "git rebase main",
    "git merge origin/main",
    "git stash pop",
    "git log --oneline -5",
    "git diff --stat",
    "git fetch --prune",
    "git remote -v",
    "git tag v1.0",
    "git -c alias.st=status st",
    # the words appear, but as text, not as the command
    'git commit -m "never run git push --force or git reset --hard"',
    "git commit -m 'git clean was removed'",
    "git commit -F - <<'EOF'\nDon't git push -f\nor git reset --hard\nEOF",
    "echo 'git push -f'",
    'grep -rn "git clean" docs',
    "# git push -f\ngit status",
    "./validate.sh all",
    "./run.sh",
    "pnpm test",
    "ls -la",
    "unclosed 'quote",
]


class TableTest(unittest.TestCase):
    def test_blocked(self):
        for command in BLOCKED:
            with self.subTest(command=command):
                self.assertIsNotNone(git_guard.command_problem(command))

    def test_allowed(self):
        for command in ALLOWED:
            with self.subTest(command=command):
                self.assertIsNone(git_guard.command_problem(command))


def run_hook(tool_name: str, tool_input: dict) -> subprocess.CompletedProcess:
    event = {"hook_event_name": "PreToolUse", "tool_name": tool_name, "tool_input": tool_input}
    return subprocess.run(
        [sys.executable, "-B", str(HOOK)], input=json.dumps(event), capture_output=True, text=True, check=False
    )


class HookProtocolTest(unittest.TestCase):
    """The script as Claude Code runs it: the event as JSON on stdin, a decision as JSON on stdout."""

    def test_denies_with_a_reason(self):
        result = run_hook("Bash", {"command": "git push origin main --force"})
        self.assertEqual(result.returncode, 0)
        output = json.loads(result.stdout)["hookSpecificOutput"]
        self.assertEqual(output["hookEventName"], "PreToolUse")
        self.assertEqual(output["permissionDecision"], "deny")
        self.assertIn("--force", output["permissionDecisionReason"])

    def test_says_nothing_about_a_safe_command(self):
        result = run_hook("Bash", {"command": "git push"})
        self.assertEqual((result.returncode, result.stdout), (0, ""))

    def test_ignores_other_tools(self):
        result = run_hook("Write", {"content": "git push -f"})
        self.assertEqual((result.returncode, result.stdout), (0, ""))


if __name__ == "__main__":
    unittest.main()
