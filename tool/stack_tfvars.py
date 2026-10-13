#!/usr/bin/env python3
"""Select the environment tfvars values that one Terraform stack declares.

One environment file (infra/environments/<name>.tfvars) configures the foundation,
illustrations and runtime stacks, but each stack declares only the variables it
uses. Passing the whole file would make Terraform warn about every value a stack
does not declare. This filter copies each declared assignment verbatim, so
Terraform still parses and validates every value, and rejects any key that no
environment stack declares so a misspelled setting is never silently ignored.

Environment files therefore hold one single-line top-level assignment per
setting; multi-line values (heredocs, wrapped maps or lists) are rejected
rather than guessed at.
"""
import argparse
from pathlib import Path
import re
import sys

ENVIRONMENT_STACKS = ("foundation", "illustrations", "runtime")
DECLARATION = re.compile(r'^variable\s+"([A-Za-z_][A-Za-z0-9_-]*)"', re.MULTILINE)
ASSIGNMENT = re.compile(r"^([A-Za-z_][A-Za-z0-9_-]*)\s*=\s*(\S.*)$")
OPENERS = {"{": "}", "[": "]", "(": ")"}


def declared(stack_dir):
    """Variable names declared by the root module in stack_dir."""
    names = set()
    for path in sorted(Path(stack_dir).glob("*.tf")):
        names.update(DECLARATION.findall(path.read_text()))
    return names


def balanced(value):
    """Whether brackets outside string literals close on the same line."""
    depth = 0
    quoted = False
    escaped = False
    for character in value:
        if quoted:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                quoted = False
        elif character == '"':
            quoted = True
        elif character == "#":
            break
        elif character in OPENERS:
            depth += 1
        elif character in OPENERS.values():
            depth -= 1
    return depth == 0 and not quoted


def assignments(path):
    """Ordered (name, line) pairs; raises ValueError for unsupported syntax."""
    entries = []
    seen = set()
    for number, line in enumerate(Path(path).read_text().splitlines(), start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith(("#", "//")):
            continue
        match = ASSIGNMENT.match(line)
        if not match or match.group(2).startswith("<<") or not balanced(match.group(2)):
            raise ValueError(f"{path}:{number}: expected one single-line top-level assignment")
        name = match.group(1)
        if name in seen:
            raise ValueError(f"{path}:{number}: '{name}' is assigned more than once")
        seen.add(name)
        entries.append((name, line))
    return entries


def select(infra, stack, source):
    """Return the tfvars text containing only the values `stack` declares."""
    if stack not in ENVIRONMENT_STACKS:
        raise ValueError(f"unknown environment stack: {stack}")
    infra = Path(infra)
    stack_names = declared(infra / stack)
    known = set().union(*(declared(infra / other) for other in ENVIRONMENT_STACKS))
    lines = []
    for name, line in assignments(source):
        if name not in known:
            raise ValueError(f"{source}: '{name}' is not declared by any environment stack")
        if name in stack_names:
            lines.append(line)
    return "".join(f"{line}\n" for line in lines)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("infra", type=Path, help="infra directory containing the stacks")
    parser.add_argument("stack", choices=ENVIRONMENT_STACKS)
    parser.add_argument("source", type=Path, help="shared environment tfvars file")
    parser.add_argument("output", type=Path, help="stack-specific tfvars file to write")
    args = parser.parse_args(argv)
    try:
        text = select(args.infra, args.stack, args.source)
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    args.output.write_text(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
