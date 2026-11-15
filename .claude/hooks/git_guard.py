#!/usr/bin/env python3
"""PreToolUse hook for the Bash tool: blocks git commands that destroy history or work.

settings.json's deny rules match a command's prefix, so `git push origin main --force` or `git -C . push -f`
get past them. This hook reads the whole command line the way a shell splits it (quotes, `&&`, `;`, pipes,
newlines, `$(...)`, `bash -c`, env prefixes, wrappers such as sudo, and git's own -C and -c options) and denies:

  git push      with --force, -f, --force-with-lease (any form), --force-if-includes, --mirror, --delete, -d,
                --prune, a +refspec, or a :refspec that deletes a remote branch
  git reset     --hard
  git clean     any, apart from a dry run (-n, --dry-run)
  git branch    deleting main or master (-d, -D, --delete)
  git filter-branch, git filter-repo

Everything else passes through to the normal permission rules: this hook never allows anything by itself.
A command it can't split, such as one with an unclosed quote, is denied when it names one of those subcommands.
It follows an alias defined with git -c, but can't see through other indirection: an alias saved in git's config,
a variable holding the flag, or a script file.
"""

from __future__ import annotations

import json
import re
import sys

SHELLS = {"bash", "sh", "zsh", "dash", "ksh"}
SEPARATORS = {"&&", "||", ";", "|", "|&", "&", "\n", "(", ")", "`", "$("}
# git's options before the subcommand that take the next word as their value.
GIT_OPTIONS_WITH_VALUE = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env", "--super-prefix"}
# git push's short options that take the next word as their value.
PUSH_SHORT_OPTIONS_WITH_VALUE = {"o"}
PROTECTED_BRANCHES = {"main", "master"}
DANGEROUS_SUBCOMMANDS = re.compile(r"\bgit\b.*\b(push|reset|clean|branch|filter-branch|filter-repo)\b", re.DOTALL)


class UnsplittableCommand(Exception):
    """The command line has an unclosed quote or substitution."""


def tokenize(command: str) -> list[str]:
    """Splits a command line into words and separators, as a shell does, minus expansion.

    Quotes and backslashes are removed from words. Heredoc bodies are skipped, except one fed to a shell,
    which is kept as commands. `$(` and a backtick count as separators, so a substitution's command is a
    command of its own.
    """
    tokens: list[str] = []
    word: list[str] = []
    in_word = False
    pending_heredocs: list[tuple[str, bool, bool]] = []  # delimiter, strip tabs, body is commands
    quoted_substitutions: list[str] = []
    i = 0
    length = len(command)

    def end_word() -> None:
        nonlocal word, in_word
        if in_word:
            tokens.append("".join(word))
        word = []
        in_word = False

    while i < length:
        char = command[i]
        if char == "\\":
            if i + 1 < length and command[i + 1] == "\n":
                i += 2  # a line continuation
                continue
            if i + 1 < length:
                word.append(command[i + 1])
            in_word = True
            i += 2
            continue
        if char == "'":
            close = command.find("'", i + 1)
            if close < 0:
                raise UnsplittableCommand("unclosed single quote")
            word.append(command[i + 1 : close])
            in_word = True
            i = close + 1
            continue
        if char == '"':
            i += 1
            while True:
                if i >= length:
                    raise UnsplittableCommand("unclosed double quote")
                if command[i] == "\\" and i + 1 < length and command[i + 1] in '"\\$`\n':
                    word.append(command[i + 1])
                    i += 2
                    continue
                if command[i] == '"':
                    break
                if command.startswith("$(", i) or command[i] == "`":
                    # A substitution inside quotes still runs: check its command as a command of its own.
                    inner_end = substitution_end(command, i)
                    inner_start = i + (2 if command[i] == "$" else 1)
                    quoted_substitutions.append(command[inner_start:inner_end])
                    word.append(command[i : inner_end + 1])
                    i = inner_end + 1
                    continue
                word.append(command[i])
                i += 1
            in_word = True
            i += 1
            continue
        if char == "#" and not in_word:
            while i < length and command[i] != "\n":
                i += 1
            continue
        if char in " \t":
            end_word()
            i += 1
            continue
        if char == "\n":
            end_word()
            tokens.append("\n")
            i += 1
            for delimiter, strip_tabs, body_is_commands in pending_heredocs:
                body_start = i
                while i < length:
                    line_end = command.find("\n", i)
                    line_end = length if line_end < 0 else line_end
                    line = command[i:line_end]
                    if (line.lstrip("\t") if strip_tabs else line) == delimiter:
                        if body_is_commands:
                            tokens.extend(tokenize(command[body_start:i]))
                            tokens.append("\n")
                        i = line_end + 1
                        break
                    i = line_end + 1
            pending_heredocs = []
            continue
        if command.startswith("<<", i) and not command.startswith("<<<", i):
            end_word()
            i += 2
            strip_tabs = i < length and command[i] == "-"
            i += 1 if strip_tabs else 0
            while i < length and command[i] in " \t":
                i += 1
            match = re.match(r"""(['"]?)([^\s;&|<>()'"]+)\1""", command[i:])
            if match:
                command_words = current_command_words(tokens)
                fed_to_shell = bool(command_words) and command_words[0].rsplit("/", 1)[-1] in SHELLS
                pending_heredocs.append((match.group(2), strip_tabs, fed_to_shell))
                i += match.end()
            continue
        two = command[i : i + 2]
        if two in {"&&", "||", "|&", "$("}:
            end_word()
            tokens.append(two)
            i += 2
            continue
        if char in ";|&()`":
            end_word()
            tokens.append(char)
            i += 1
            continue
        word.append(char)
        in_word = True
        i += 1
    end_word()
    for inner in quoted_substitutions:
        tokens.extend([";", *tokenize(inner), ";"])
    return tokens


def substitution_end(command: str, start: int) -> int:
    """The index of the `)` or backtick that closes the substitution starting at start."""
    if command[start] == "`":
        close = command.find("`", start + 1)
        if close < 0:
            raise UnsplittableCommand("unclosed backtick")
        return close
    depth = 0
    for index in range(start + 1, len(command)):
        if command[index] == "(":
            depth += 1
        elif command[index] == ")":
            depth -= 1
            if depth == 0:
                return index
    raise UnsplittableCommand("unclosed $(")


def current_command_words(tokens: list[str]) -> list[str]:
    """The words of the simple command the tokens so far end in."""
    words: list[str] = []
    for token in reversed(tokens):
        if token in SEPARATORS:
            break
        words.append(token)
    return list(reversed(words))


def simple_commands(tokens: list[str]) -> list[list[str]]:
    commands: list[list[str]] = [[]]
    for token in tokens:
        if token in SEPARATORS:
            commands.append([])
        else:
            commands[-1].append(token)
    return [words for words in commands if words]


def is_git(word: str) -> bool:
    return word.rsplit("/", 1)[-1] == "git"


def nested_command_lines(words: list[str]) -> list[str]:
    """Command lines a simple command runs as text: `bash -c '...'` and `eval ...`."""
    name = words[0].rsplit("/", 1)[-1]
    if name == "eval":
        return [" ".join(words[1:])]
    if name in SHELLS:
        return [words[index + 1] for index, word in enumerate(words[:-1]) if re.fullmatch(r"-[a-z]*c[a-z]*", word)]
    return []


def git_subcommand(words: list[str]) -> tuple[str, list[str]] | None:
    """The subcommand and its arguments of a git invocation, past git's own options."""
    index = 1
    while index < len(words):
        word = words[index]
        if word in GIT_OPTIONS_WITH_VALUE:
            index += 2
        elif word.startswith("-"):
            index += 1
        else:
            return word, words[index + 1 :]
    return None


def short_flags(argument: str) -> str:
    """The letters of a cluster of short options such as -fu, or nothing for anything else."""
    return argument[1:] if re.fullmatch(r"-[A-Za-z0-9]+", argument) else ""


def push_problem(arguments: list[str]) -> str | None:
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        index += 1
        if argument == "--":
            continue
        if argument.startswith("--force"):
            return f"git push {argument.split('=', 1)[0]} rewrites the remote's history"
        if argument.split("=", 1)[0] in {"--mirror", "--delete", "--prune"}:
            return f"git push {argument.split('=', 1)[0]} deletes or overwrites remote refs"
        flags = short_flags(argument)
        if flags:
            if "f" in flags:
                return "git push -f rewrites the remote's history"
            if "d" in flags:
                return "git push -d deletes a remote branch"
            if flags[-1] in PUSH_SHORT_OPTIONS_WITH_VALUE:
                index += 1
            continue
        if argument.startswith("-"):
            continue
        if argument.startswith("+"):
            return f"git push {argument} force-pushes that refspec"
        if argument.startswith(":") and len(argument) > 1:
            return f"git push {argument} deletes that remote branch"
    return None


def branch_problem(arguments: list[str]) -> str | None:
    deleting = any(argument in {"--delete", "-D"} or "d" in short_flags(argument).lower() for argument in arguments)
    if not deleting:
        return None
    # A remote-tracking branch (-r) is named with its remote, as in origin/main; a local one by itself.
    remote = any(argument in {"--remotes", "-r"} or "r" in short_flags(argument) for argument in arguments)
    for argument in arguments:
        name = re.sub(r"^refs/(heads|remotes)/", "", argument)
        if remote:
            name = name.split("/", 1)[-1]
        if not argument.startswith("-") and name in PROTECTED_BRANCHES:
            return f"git branch deleting {argument}"
    return None


def clean_problem(arguments: list[str]) -> str | None:
    # -n or --dry-run only lists what would go, even alongside -f.
    if any(argument == "--dry-run" or "n" in short_flags(argument) for argument in arguments):
        return None
    return "git clean deletes untracked files"


def inline_aliases(words: list[str]) -> dict[str, str]:
    """Aliases defined on the command line itself, as in git -c alias.p='push -f' p."""
    aliases = {}
    for index, word in enumerate(words[:-1]):
        match = re.fullmatch(r"alias\.([^=]+)=(.*)", words[index + 1], re.DOTALL) if word == "-c" else None
        if match:
            aliases[match.group(1)] = match.group(2)
    return aliases


def git_problem(words: list[str], depth: int = 0) -> str | None:
    found = git_subcommand(words)
    if found is None:
        return None
    subcommand, arguments = found
    alias = inline_aliases(words).get(subcommand)
    if alias is not None and depth < 3:
        if alias.startswith("!"):
            return command_problem(alias[1:], depth + 1)
        return git_problem(["git", *alias.split(), *arguments], depth + 1)
    if subcommand == "push":
        return push_problem(arguments)
    if subcommand == "reset" and "--hard" in arguments:
        return "git reset --hard throws away uncommitted work"
    if subcommand == "clean":
        return clean_problem(arguments)
    if subcommand == "branch":
        return branch_problem(arguments)
    if subcommand in {"filter-branch", "filter-repo"}:
        return f"git {subcommand} rewrites history"
    return None


def command_problem(command: str, depth: int = 0) -> str | None:
    """Why the command line is blocked, or None when this hook has no objection."""
    try:
        tokens = tokenize(command)
    except UnsplittableCommand as error:
        if DANGEROUS_SUBCOMMANDS.search(command):
            return f"the command couldn't be checked ({error}) and names a git subcommand this hook guards"
        return None
    for words in simple_commands(tokens):
        if depth < 3:
            for nested in nested_command_lines(words):
                problem = command_problem(nested, depth + 1)
                if problem:
                    return problem
        # git is the command, or comes after env assignments or a wrapper such as sudo, env, xargs or timeout.
        for index, word in enumerate(words):
            if is_git(word):
                problem = git_problem(words[index:])
                if problem:
                    return problem
    return None


def main() -> None:
    event = json.load(sys.stdin)
    if event.get("tool_name") != "Bash":
        return
    problem = command_problem(event.get("tool_input", {}).get("command", ""))
    if problem:
        reason = (
            f"Blocked by .claude/hooks/git_guard.py: {problem}. Destructive git commands are never run by an agent; "
            "ask the user to run it themselves if it's really needed."
        )
        json.dump(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": reason,
                }
            },
            sys.stdout,
        )


if __name__ == "__main__":
    main()
