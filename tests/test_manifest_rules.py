"""The app-manifest contract is enforced in four hand-written places that
cannot share a file: the JSON schema, template-app/Makefile validate-manifest,
modules/fargate-service/variables.tf, and bootstrap/variables.tf. This test
extracts every shared rule from each copy and fails, naming each file and its
value, when the copies differ. It also checks that every schema property is
wired from template-app/main.tf into a real module variable."""

import json
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCHEMA = ROOT / "template-app/app-manifest.schema.json"
MAKEFILE = ROOT / "template-app/Makefile"
MODULE_VARS = ROOT / "modules/fargate-service/variables.tf"
BOOTSTRAP_VARS = ROOT / "bootstrap/variables.tf"
APP_MAIN = ROOT / "template-app/main.tf"


def rel(path):
    return str(path.relative_to(ROOT))


def hcl_string(raw):
    return raw.replace("\\\\", "\\")


def make_string(raw):
    return raw.replace("$$", "$")


def names(raw):
    return tuple(sorted(re.findall(r'"([^"]*)"', raw)))


def block(text, header):
    start = text.index(header)
    nxt = text.find("\nvariable ", start + 1)
    return text[start : nxt if nxt != -1 else len(text)]


def make_chunks():
    text = MAKEFILE.read_text(encoding="utf-8")
    body = text[text.index("\nvalidate-manifest:") : text.index('@echo "==> manifest OK"')]
    chunks = {}
    for chunk in body.split("\n\t@")[1:]:
        found = re.search(r"yq '\.(\w+)'", chunk)
        if found:
            chunks.setdefault(found.group(1), chunk)
    return chunks, body


def schema_rules():
    s = json.loads(SCHEMA.read_text(encoding="utf-8"))
    p = s["properties"]
    pairs = {}
    for clause in s["allOf"]:
        cpu = clause["if"]["properties"]["cpu"]["const"]
        pairs[cpu] = tuple(sorted(clause["then"]["properties"]["memory"]["enum"]))
    return {
        "name pattern": p["name"]["pattern"],
        "reserved name": p["name"]["not"]["const"],
        "alert name pattern": p["alerts"]["items"]["properties"]["name"]["pattern"],
        "secret name pattern": p["secrets"]["items"]["pattern"],
        "email.from pattern": p["email"]["properties"]["from"]["pattern"],
        "max secrets": p["secrets"]["maxItems"],
        "max alerts": p["alerts"]["maxItems"],
        "storage values": tuple(sorted(p["storage"]["enum"])),
        "auth values": tuple(sorted(p["auth"]["enum"])),
        "port range": (p["port"]["minimum"], p["port"]["maximum"]),
        "cpu values": tuple(sorted(p["cpu"]["enum"])),
        "memory by cpu": tuple(sorted(pairs.items())),
        "manifest keys": tuple(sorted(p)),
        "reserved env names (env)": tuple(sorted(r["required"][0] for r in p["env"]["not"]["anyOf"])),
        "reserved env names (secrets)": tuple(sorted(p["secrets"]["items"]["not"]["enum"])),
    }


def makefile_rules():
    c, body = make_chunks()
    pair_re = r'(\d+)\) case "\$\$mem" in ([\d|]+)\)'
    pairs = {int(cpu): tuple(sorted(int(m) for m in mems.split("|"))) for cpu, mems in re.findall(pair_re, c["cpu"])}
    lo, hi = re.search(r'-lt (\d+) \] \|\| \[ "\$\$port" -gt (\d+)', c["port"]).groups()

    def reserved(chunk):
        return tuple(sorted(set(re.findall(r"(?:^|[\s|])([A-Z][A-Z_]{3,})(?=[|)])", chunk, re.M))))

    keys = re.search(r'case " ([a-z ]+) " in', body).group(1).split()
    return {
        "name pattern": make_string(re.search(r"grep -Eq '([^']+)'", c["name"]).group(1)),
        "reserved name": re.search(r'"\$\$name" = "([^"]+)"', c["name"]).group(1),
        "alert name pattern": make_string(re.search(r"grep -Eq '([^']+)'", c["alerts"]).group(1)),
        "secret name pattern": make_string(re.search(r"grep -Eq '([^']+)'", c["secrets"]).group(1)),
        "email.from pattern": make_string(re.search(r"grep -Eq '([^']+)'", c["email"]).group(1)),
        "max secrets": int(re.search(r'"\$\$count" -gt (\d+)', c["secrets"]).group(1)),
        "max alerts": int(re.search(r'"\$\$count" -gt (\d+)', c["alerts"]).group(1)),
        "storage values": tuple(sorted(re.search(r"\n\s+([\w|-]+)\) : ;;", c["storage"]).group(1).split("|"))),
        "auth values": (re.search(r'"\$\$auth" != "(\w+)"', c["auth"]).group(1),),
        "port range": (int(lo), int(hi)),
        "cpu values": tuple(sorted(pairs)),
        "memory by cpu": tuple(sorted(pairs.items())),
        "manifest keys": tuple(sorted(keys)),
        "reserved env names (env)": reserved(c["env"]),
        "reserved env names (secrets)": reserved(c["secrets"]),
    }


def module_rules():
    t = MODULE_VARS.read_text(encoding="utf-8")

    def grab(pattern):
        return hcl_string(re.search(pattern, t).group(1))

    env, secrets = block(t, 'variable "env"'), block(t, 'variable "secrets"')
    env_conditions = "\n".join(re.findall(r"condition\s*=.*", env))
    return {
        "name pattern": grab(r'regex\("([^"]+)", var\.name\)'),
        "reserved name": grab(r'var\.name != "([^"]+)"'),
        "alert name pattern": grab(r'regex\("([^"]+)", a\.name\)'),
        "secret name pattern": grab(r'regex\("([^"]+)", name\)'),
        "email.from pattern": grab(r'regex\("([^"]+)", var\.email_from\)'),
        "max secrets": int(grab(r"length\(var\.secrets\) <= (\d+)")),
        "max alerts": int(grab(r"length\(var\.alerts\) <= (\d+)")),
        "storage values": tuple(v for v in names(grab(r"contains\(\[([^\]]*)\], var\.storage\)")) if v),
        "auth values": tuple(v for v in names(grab(r"contains\(\[([^\]]*)\], var\.auth\)")) if v),
        "reserved env names (env)": tuple(sorted(set(re.findall(r'"([A-Z][A-Z_]+)"', env_conditions)))),
        "reserved env names (secrets)": names(re.search(r"toset\(\[(.*?)\]\)", secrets, re.S).group(1)),
    }


def bootstrap_rules():
    t = BOOTSTRAP_VARS.read_text(encoding="utf-8")
    return {"email.from pattern": hcl_string(re.search(r'regex\("([^"]+)", address\)', t).group(1))}


SOURCES = {
    rel(SCHEMA): schema_rules,
    rel(MAKEFILE): makefile_rules,
    rel(MODULE_VARS): module_rules,
    rel(BOOTSTRAP_VARS): bootstrap_rules,
}


class ManifestRuleSyncTests(unittest.TestCase):
    def test_every_copy_of_a_shared_rule_is_identical(self):
        copies = {path: extract() for path, extract in SOURCES.items()}
        rules = sorted({rule for found in copies.values() for rule in found})
        failures = []
        for rule in rules:
            values = {path: found[rule] for path, found in copies.items() if rule in found}
            if len(set(map(repr, values.values()))) > 1:
                lines = "\n".join(f"    {path}: {value!r}" for path, value in values.items())
                failures.append(f"  rule '{rule}' differs between copies:\n{lines}")
        self.assertFalse(
            failures,
            "manifest rule copies drifted; edit them to match "
            "(template-app/app-manifest.schema.json is the reference):\n" + "\n".join(failures),
        )

    def test_makefile_extractor_covers_every_schema_rule(self):
        # Guards against an extractor silently dropping a rule after a rewrite.
        self.assertEqual(set(schema_rules()), set(makefile_rules()))

    def test_every_schema_property_is_wired_to_a_module_variable(self):
        props = set(json.loads(SCHEMA.read_text(encoding="utf-8"))["properties"])
        main = APP_MAIN.read_text(encoding="utf-8")
        module = re.search(r'module "app" \{(.*?)\n\}', main, re.S).group(1)
        args = dict(re.findall(r"^\s*(\w+)\s*=\s*(.*)$", module, re.M))
        module_vars = set(re.findall(r'^variable "(\w+)"', MODULE_VARS.read_text(encoding="utf-8"), re.M))
        unread = sorted(k for k in props if not any(f"local.manifest.{k}" in v for v in args.values()))
        self.assertFalse(
            unread,
            f"{rel(APP_MAIN)} never reads manifest field(s) {unread} into module \"app\"; "
            f"add `<module variable> = try(local.manifest.<field>, <default>)`",
        )
        wired = {k: arg for k in props for arg, v in args.items() if f"local.manifest.{k}" in v}
        missing = sorted(f"{k} -> {arg}" for k, arg in wired.items() if arg not in module_vars)
        self.assertFalse(
            missing,
            f"{rel(APP_MAIN)} passes manifest field(s) to module variables that {rel(MODULE_VARS)} "
            f"does not declare: {missing}",
        )


if __name__ == "__main__":
    unittest.main()
