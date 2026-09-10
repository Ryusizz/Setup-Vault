#!/usr/bin/env python3
"""agent-accounts registry — alias/id store for claude & codex logins.

Registry lives at $AGENT_ACCT_REGISTRY (default ~/.claude/.accounts/registry.json).
Only bind-mounted paths survive a devcontainer rebuild, which is why it sits
under ~/.claude rather than ~/.agent-accounts.

Schema:
{
  "version": 1,
  "accounts": {
    "<id>": {
      "aliases": ["d2", ...],
      "label": "human readable",
      "tools": {"claude": {"mode": "native"|"overlay"}, "codex": {...}}
    }
  }
}
"""
import json
import os
import re
import sys

TOOLS = ("claude", "codex")
# Email addresses are the natural account name, so '@' and '+' are allowed.
# The id doubles as a directory name under <shared>/.accounts/, which is fine
# for every character in this set. A leading alphanumeric keeps "." and ".."
# out.
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+@-]{0,127}$")
RESERVED = {"list", "add", "rm", "help", "none", "native", "overlay"}


def registry_path():
    return os.environ.get(
        "AGENT_ACCT_REGISTRY",
        os.path.join(os.path.expanduser("~"), ".claude", ".accounts", "registry.json"),
    )


def load():
    p = registry_path()
    if not os.path.exists(p):
        return {"version": 1, "accounts": {}}
    with open(p, encoding="utf-8") as fh:
        data = json.load(fh)
    data.setdefault("version", 1)
    data.setdefault("accounts", {})
    return data


def save(data):
    p = registry_path()
    os.makedirs(os.path.dirname(p), exist_ok=True)
    tmp = p + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    os.replace(tmp, p)
    os.chmod(p, 0o600)


def fail(msg, code=1):
    print(msg, file=sys.stderr)
    sys.exit(code)


def valid_id(name):
    return bool(ID_RE.match(name)) and name.lower() not in RESERVED


def resolve(data, key):
    """alias or id -> id, or None."""
    accounts = data["accounts"]
    if key in accounts:
        return key
    lowered = key.lower()
    for acct_id, acct in accounts.items():
        if acct_id.lower() == lowered:
            return acct_id
        for alias in acct.get("aliases", []):
            if alias.lower() == lowered:
                return acct_id
    return None


def mode(data, acct_id, tool):
    acct = data["accounts"].get(acct_id, {})
    return acct.get("tools", {}).get(tool, {}).get("mode", "overlay")


def native_holder(data, tool):
    for acct_id in data["accounts"]:
        if mode(data, acct_id, tool) == "native":
            return acct_id
    return None


# --------------------------------------------------------------------------- #
# commands
# --------------------------------------------------------------------------- #
def cmd_resolve(argv):
    data = load()
    acct_id = resolve(data, argv[0])
    if acct_id is None:
        sys.exit(3)
    print(acct_id)


def cmd_ids(argv):
    for acct_id in sorted(load()["accounts"]):
        print(acct_id)


def cmd_mode(argv):
    acct_id, tool = argv[0], argv[1]
    print(mode(load(), acct_id, tool))


def cmd_native_holder(argv):
    holder = native_holder(load(), argv[0])
    if holder is None:
        sys.exit(3)
    print(holder)


def cmd_show(argv):
    data = load()
    acct_id = resolve(data, argv[0])
    if acct_id is None:
        sys.exit(3)
    acct = data["accounts"][acct_id]
    print(f"id\t{acct_id}")
    print("aliases\t" + " ".join(acct.get("aliases", [])))
    print("label\t" + acct.get("label", ""))
    for tool in TOOLS:
        print(f"mode.{tool}\t" + mode(data, acct_id, tool))


def cmd_dump(argv):
    print(json.dumps(load(), indent=2, ensure_ascii=False))


def cmd_add(argv):
    """add <id> [--alias a,b] [--label L] [--mode tool=native|overlay ...]"""
    acct_id = argv[0].strip()
    if not valid_id(acct_id):
        fail(f"invalid account id: {acct_id!r}\n"
             "  허용: 영문/숫자로 시작, 이후 영문 숫자 . _ - + @ (최대 128자). "
             "공백과 / 는 쓸 수 없습니다.")
    aliases, label, modes = [], "", {}
    i = 1
    while i < len(argv):
        arg = argv[i]
        if arg == "--alias":
            i += 1
            aliases += [a for a in re.split(r"[,\s]+", argv[i].strip()) if a]
        elif arg == "--label":
            i += 1
            label = argv[i].strip()
        elif arg == "--mode":
            i += 1
            tool, _, m = argv[i].partition("=")
            modes[tool] = m
        i += 1

    data = load()
    existing = resolve(data, acct_id)
    if existing is not None and existing != acct_id:
        fail(f"'{acct_id}' already resolves to account '{existing}'")
    for alias in aliases:
        if not valid_id(alias):
            fail(f"invalid alias: {alias!r}\n"
                 "  허용: 영문/숫자로 시작, 이후 영문 숫자 . _ - + @ (최대 128자).")
        owner = resolve(data, alias)
        if owner is not None and owner != acct_id:
            fail(f"alias '{alias}' is already taken by account '{owner}'")

    acct = data["accounts"].setdefault(acct_id, {"aliases": [], "label": "", "tools": {}})
    for alias in aliases:
        if alias != acct_id and alias not in acct["aliases"]:
            acct["aliases"].append(alias)
    if label:
        acct["label"] = label
    for tool, m in modes.items():
        if tool not in TOOLS:
            fail(f"unknown tool: {tool}")
        if m not in ("native", "overlay"):
            fail(f"unknown mode: {m}")
        if m == "native":
            holder = native_holder(data, tool)
            if holder is not None and holder != acct_id:
                fail(f"account '{holder}' already holds the native {tool} store; "
                     f"only one account can.")
        acct.setdefault("tools", {})[tool] = {"mode": m}
    save(data)
    print(acct_id)


def cmd_alias(argv):
    """alias <id> <alias>..."""
    data = load()
    acct_id = resolve(data, argv[0])
    if acct_id is None:
        fail(f"unknown account: {argv[0]}")
    acct = data["accounts"][acct_id]
    for alias in [a.strip() for a in argv[1:] if a.strip()]:
        if not valid_id(alias):
            fail(f"invalid alias: {alias!r}\n"
                 "  허용: 영문/숫자로 시작, 이후 영문 숫자 . _ - + @ (최대 128자).")
        owner = resolve(data, alias)
        if owner is not None and owner != acct_id:
            fail(f"alias '{alias}' is already taken by account '{owner}'")
        if alias != acct_id and alias not in acct["aliases"]:
            acct["aliases"].append(alias)
    save(data)


def cmd_unalias(argv):
    data = load()
    acct_id = resolve(data, argv[0])
    if acct_id is None:
        fail(f"unknown account: {argv[0]}")
    acct = data["accounts"][acct_id]
    acct["aliases"] = [a for a in acct.get("aliases", []) if a not in argv[1:]]
    save(data)


def cmd_rm(argv):
    data = load()
    acct_id = resolve(data, argv[0])
    if acct_id is None:
        fail(f"unknown account: {argv[0]}")
    del data["accounts"][acct_id]
    save(data)
    print(acct_id)


def cmd_set_mode(argv):
    """set-mode <id> <tool> <native|overlay>"""
    data = load()
    acct_id = resolve(data, argv[0])
    if acct_id is None:
        fail(f"unknown account: {argv[0]}")
    tool, m = argv[1], argv[2]
    if tool not in TOOLS:
        fail(f"unknown tool: {tool}")
    if m not in ("native", "overlay"):
        fail(f"unknown mode: {m}")
    if m == "native":
        holder = native_holder(data, tool)
        if holder is not None and holder != acct_id:
            fail(f"account '{holder}' already holds the native {tool} store")
    data["accounts"][acct_id].setdefault("tools", {})[tool] = {"mode": m}
    save(data)


def cmd_table(argv):
    """Tab-separated rows for `agent-acct list`: id, aliases, label, mode.claude, mode.codex"""
    data = load()
    for acct_id in sorted(data["accounts"]):
        acct = data["accounts"][acct_id]
        print("\t".join([
            acct_id,
            ",".join(acct.get("aliases", [])) or "-",
            acct.get("label", "") or "-",
            mode(data, acct_id, "claude"),
            mode(data, acct_id, "codex"),
        ]))


COMMANDS = {
    "resolve": cmd_resolve, "ids": cmd_ids, "mode": cmd_mode,
    "native-holder": cmd_native_holder, "show": cmd_show, "dump": cmd_dump,
    "add": cmd_add, "alias": cmd_alias, "unalias": cmd_unalias, "rm": cmd_rm,
    "set-mode": cmd_set_mode, "table": cmd_table, "path": lambda a: print(registry_path()),
}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        fail(f"usage: registry.py <{'|'.join(COMMANDS)}> [args]", 2)
    COMMANDS[sys.argv[1]](sys.argv[2:])
