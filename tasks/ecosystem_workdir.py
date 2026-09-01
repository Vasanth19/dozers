#!/usr/bin/env python3
"""Resolve a Dozer task's working directory from the canonical ecosystem.yaml.

The single source of truth for on-disk paths is ~/ecosystem/ecosystem.yaml — never
hardcode a repo path in a label or in dozer config. This helper maps:

  --repo <id>    a project id (e.g. cfw-social, cfw-website, cfw-render)  -> its local path
  --team <KEY>   a Linear team key (e.g. CFW, LL) -> that org's default repo path

Resolution the Dozer uses (most-specific first):
  1) repo:<id> hint on the task   -> project.id == id
  2) the task's Linear team       -> org.linear_team == KEY, then the org's first live repo
Prints the absolute path and exits 0 on success; exits non-zero (silent) on miss so
the caller can fall back to its own default.
"""
import argparse
import os
import sys

REGISTRY = os.path.expanduser("~/ecosystem/ecosystem.yaml")


def load():
    try:
        import yaml
    except ImportError:
        sys.exit(3)
    with open(REGISTRY) as f:
        return yaml.safe_load(f)


def expand(p):
    return os.path.expanduser(str(p)).rstrip("/") if p else None


def by_repo(reg, repo_id):
    for p in reg.get("projects", []) or []:
        if str(p.get("id")) == repo_id:
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
    # first live (non-archived) project belonging to that org = the org's default repo
    for p in reg.get("projects", []) or []:
        if str(p.get("org")) == org_slug:
            local = expand(p.get("local"))
            if local and "_archive" not in local and "retired" not in local.lower():
                return local
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default="")
    ap.add_argument("--team", default="")
    a = ap.parse_args()
    reg = load()
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
