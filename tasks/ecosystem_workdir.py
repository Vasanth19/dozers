#!/usr/bin/env python3
"""Resolve a Dozer task's working directory from the canonical ecosystem.yaml.

The single source of truth for on-disk paths is ~/ecosystem/ecosystem.yaml — never
hardcode a repo path in a label or in dozer config. This helper maps:

  --repo <id>    a project id (e.g. cfw-social, cfw-website, cfw-render)  -> its local path
  --team <KEY>   a Linear team key (e.g. CFW, LL) -> that org's default repo path

Repos live in TWO lists of the registry (GSAI-17): `projects:` (product/brand/client
repos, each with an `org`) and `infrastructure:` (paperclip, openclaw, gbrain-source,
harbour... — no org, they belong to the whole factory). `--repo` and `--flag` search
both, `projects:` first so a project id always wins a name collision. `--team` only
walks `projects:` — an infrastructure entry has no org, so it can never be a team's
default repo.

It also answers the reverse question (GSAI-27) — given a path on disk, what does the
registry say ABOUT that project:

  --flag <name> --path <dir>   -> print that key's value from the project entry whose
                                  `local` is <dir> (e.g. --flag no_test_gate). Exits
                                  non-zero (silent) when the project or key is absent,
                                  so a caller can treat "no answer" as "not set".

Resolution the Dozer uses (most-specific first):
  1) repo:<id> hint on the task   -> project.id == id
  2) the task's Linear team       -> org.linear_team == KEY, then the org's first live repo
Prints the absolute path and exits 0 on success; exits non-zero (silent) on miss so
the caller can fall back to its own default.

ECOSYSTEM_REGISTRY=<file> overrides the registry path (tests point it at a fixture).
"""
import argparse
import os
import sys

REGISTRY = os.path.expanduser(os.environ.get("ECOSYSTEM_REGISTRY") or "~/ecosystem/ecosystem.yaml")

# The registry lists repos in these top-level sections, searched in this order.
REPO_SECTIONS = ("projects", "infrastructure")


def load():
    try:
        import yaml
    except ImportError:
        sys.exit(3)
    with open(REGISTRY) as f:
        return yaml.safe_load(f)


def expand(p):
    return os.path.expanduser(str(p)).rstrip("/") if p else None


def _slug(s):
    # basename of a path or a git URL, minus a trailing .git
    if not s:
        return ""
    return os.path.basename(str(s).rstrip("/")).replace(".git", "").lower()


def repo_entries(reg):
    """Every registry entry that can own a checkout: `projects:` then `infrastructure:`.
    Order matters — the first match wins, so a project id shadows an infra id."""
    for section in REPO_SECTIONS:
        for p in reg.get(section) or []:
            if isinstance(p, dict):
                yield p


def by_repo(reg, hint):
    """Resolve a repo:<hint> flexibly: match the hint against the project id, its
    local-folder basename, OR its repo-URL basename. So `cfw-social`, `cfw-social-v2`
    (repo name), or the folder name all resolve to the same project — the marketing
    lane never has to know the exact registry id. Searches `projects:` AND
    `infrastructure:` (GSAI-17) — infra repos like paperclip / openclaw / gbrain-source
    must resolve too, or a fix in them can never be greenlit."""
    h = str(hint).strip().lower()
    for p in repo_entries(reg):
        cands = {str(p.get("id")).lower(), _slug(p.get("local")), _slug(p.get("repo"))}
        cands.discard("")
        if h in cands:
            return expand(p.get("local"))
    return None


def by_team(reg, team_key):
    # Linear team key -> org slug (via the org's linear_team field)
    org_slug = None
    for slug, org in (reg.get("orgs") or {}).items():
        if str(org.get("linear_team")) == team_key:
            org_slug = slug
            break
    if not org_slug:
        return None
    # first live (non-archived) project belonging to that org = the org's default repo.
    # projects: only — infrastructure: entries carry no org (see repo_entries).
    for p in reg.get("projects", []) or []:
        if str(p.get("org")) == org_slug:
            local = expand(p.get("local"))
            if local and "_archive" not in local and "retired" not in local.lower():
                return local
    return None


def flag_for_path(reg, name, path):
    """Look up a per-repo setting from the project entry that owns <path>.

    Per-repo only, by design: there is deliberately no org-wide or global default
    here — a gate you can switch off everywhere at once is not a gate.
    """
    want = os.path.realpath(expand(path) or "")
    if not want:
        return None
    for p in repo_entries(reg):
        local = expand(p.get("local"))
        if local and os.path.realpath(local) == want:
            return p.get(name)
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default="")
    ap.add_argument("--team", default="")
    ap.add_argument("--flag", default="")
    ap.add_argument("--path", default="")
    a = ap.parse_args()
    reg = load()
    if a.flag:
        v = flag_for_path(reg, a.flag, a.path)
        if v is None:
            return 1
        print("true" if v is True else ("false" if v is False else str(v)))
        return 0
    path = None
    if a.repo:
        path = by_repo(reg, a.repo)
    if not path and a.team:
        path = by_team(reg, a.team)
    if path and os.path.isdir(path):
        print(path)
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
