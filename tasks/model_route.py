#!/usr/bin/env python3
"""Resolve which MODEL (brain) a Dozer ROLE runs on, and print an eval-able shell block.

One knob, one place. `org/config.yaml` maps a ROLE to a PROVIDER and a MODEL id. A role
is a lane name (`dev`, `marketing`) or a DOTTED per-pass role (`dev.architect`,
`dev.build`, `dev.review`): a nested lane entry maps each role to its own route, while a
flat entry (one carrying a `provider`/`model` key) is shared by every role in the lane.
`default` covers anything unlisted. An env override always wins:

    DOZER_MODEL_<ROLE>="<provider>[:<model>]"     e.g. DOZER_MODEL_DEV=ollama-cloud:glm-5.2
                                                  e.g. DOZER_MODEL_DEV_BUILD=ollama-cloud:kimi-k3:cloud

(the role key folds dots to `_`, so the dotted role needs no separate override name).

`small` (a plain string on a nested lane entry) or `small_model:` (on a flat entry) pins
ANTHROPIC_SMALL_FAST_MODEL for ollama-cloud / ollama-local routes instead of duplicating
the main model. Unset: small = main (the original behaviour).

Usage:
    tasks/model_route.py <role> [--config PATH]

Prints to stdout a block of `export`/`unset` lines meant to be eval'd by the crew:

    export DOZER_MODEL_PROVIDER='ollama-cloud'
    export DOZER_MODEL_NAME='glm-5.2'
    export ANTHROPIC_BASE_URL='https://ollama.com'
    ...
    export MODEL_CMD='claude -p'

Providers:
    claude        Anthropic Claude Code, the user's normal auth.  MODEL_CMD="claude -p"
                  Requires an explicit model in config — a bare `claude -p` inherits the
                  CLI's default, which drifts under you (GSAI-83).
    ollama-cloud  Claude Code pointed at https://ollama.com via the Anthropic-compatible
                  API, authenticated with OLLAMA_API_KEY as a Bearer token
                  (ANTHROPIC_AUTH_TOKEN — NOT ANTHROPIC_API_KEY, which 401-hangs).
    ollama-local  Same shape against a local ollama daemon (http://localhost:11434).
                  Requires an explicit model — there is no safe host-independent default.
    codex         OpenAI Codex CLI, headless.  MODEL_CMD="codex exec"

FAIL FAST: a role routed to a provider whose credentials/model are missing exits 2 with
a clear message on stderr. There is NO silent fallback to claude — a misconfigured route
must stop the crew, not quietly run on a different brain.

Secrets: the API key is read from the vault (`ollama_env:` in config, default
~/ecosystem/vault/ollama-cloud.env) or from an already-exported OLLAMA_API_KEY. It is
emitted ONLY inside the eval-able block (so it lands in the crew's process env). It is
never logged, never printed by `show`, and never echoed.
"""
import argparse
import os
import shlex
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(HERE)
DEFAULT_CONFIG = os.path.join(REPO_ROOT, "org", "config.yaml")

# Where OLLAMA_API_KEY lives when config doesn't say otherwise (vault-first).
DEFAULT_OLLAMA_ENV = "~/ecosystem/vault/ollama-cloud.env"

OLLAMA_CLOUD_URL = "https://ollama.com"
OLLAMA_LOCAL_URL = "http://localhost:11434"
OLLAMA_CLOUD_DEFAULT_MODEL = "glm-5.2"

PROVIDERS = ("claude", "ollama-cloud", "ollama-local", "codex")


def die(msg, code=2):
    print("model_route: %s" % msg, file=sys.stderr)
    sys.exit(code)


def expand(p):
    return os.path.expanduser(str(p)) if p else None


def load_config(path):
    """Read org/config.yaml. Missing file => empty config (legacy default = claude)."""
    if not os.path.exists(path):
        return {}
    try:
        import yaml
    except ImportError:
        die("PyYAML is required to read %s (pip3 install pyyaml)" % path, 3)
    with open(path) as f:
        data = yaml.safe_load(f) or {}
    if not isinstance(data, dict):
        die("%s did not parse to a mapping" % path)
    return data


def role_key(role):
    """DOZER_MODEL_<ROLE> — uppercased, non-alphanumerics folded to _."""
    return "DOZER_MODEL_" + "".join(c if c.isalnum() else "_" for c in role).upper()


# Keys on a nested lane entry that name the SMALL/FAST PIN: `small` is the nested
# spelling, `small_model` the flat-entry one (also tolerated nested).
LANE_SMALL_KEYS = ("small", "small_model")

# Every key on a nested lane entry that is NOT a role — the small pin, plus the
# lane-wide `max_turns:` budget (GSAI-170). A key listed here never becomes a row in
# `show`, and never appears in the "this lane has roles X, Y" error text.
LANE_META_KEYS = LANE_SMALL_KEYS + ("max_turns",)


def lane_roles(entry):
    """Role names of a nested lane entry (a mapping without a `provider` key)."""
    if not isinstance(entry, dict) or "provider" in entry:
        return []
    return [r for r in entry if r not in LANE_META_KEYS]


def _promote_small(lane, lane_entry, role):
    """`<lane>.small` — the lane's small/fast PIN promoted to a full route (GSAI-170).

    `small:` on a nested lane entry is a model ID, not a role: it exists to fill
    ANTHROPIC_SMALL_FAST_MODEL so auto-compact and title-gen stop burning the main
    model. The `lite` crew profile runs its ONE pass on exactly that cheap model, so
    asking for the dotted role `<lane>.small` resolves the pin into a real route
    instead of forcing a second copy of the same model id into config.

    The PROVIDER comes from one of the lane's own roles — a pin is a model id ON the
    lane's endpoint and carries no provider of its own. Deterministic pick: `build`
    when the lane has it, else the first role by name.
    """
    pin = ""
    for k in LANE_SMALL_KEYS:
        v = lane_entry.get(k)
        if v is None:
            continue
        if not isinstance(v, str):
            die("`models.%s.%s` must be a model-id string" % (lane, k))
        pin = v.strip()
        if pin:
            break
    if not pin:
        die(
            "role %r asks for the lane's small/fast model but `models.%s` pins none — "
            'add `small: "<model-id>"` to it' % (role, lane)
        )
    roles = sorted(lane_roles(lane_entry))
    pick = "build" if "build" in roles else (roles[0] if roles else "")
    if not pick:
        die("`models.%s` has no role to take a provider from for %r" % (lane, role))
    base = lane_entry.get(pick)
    if not isinstance(base, dict) or "provider" not in base:
        die("`models.%s.%s` must be a mapping with provider/model" % (lane, pick))
    return (
        str(base.get("provider") or "claude").strip(),
        pin,
        pin,
        "config:models.%s.small (provider via models.%s.%s)" % (lane, lane, pick),
    )


def max_turns_key(role):
    """DOZER_MAX_TURNS_<ROLE> — uppercased, non-alphanumerics folded to _."""
    return "DOZER_MAX_TURNS_" + "".join(c if c.isalnum() else "_" for c in role).upper()


# Providers whose CLI *is* Claude Code and therefore accepts `--max-turns`. The ollama
# routes are Claude Code pointed at a different endpoint, so they take the same flag.
# `codex exec` has no turn cap at all: a role routed there reports its budget as
# UNSUPPORTED and the crew enforces a WALL-CLOCK budget instead (dev-lane/crew.sh).
TURN_CAPPABLE = ("claude", "ollama-cloud", "ollama-local")


def _turns(value, where):
    s = str(value).strip()
    if not s.isdigit() or int(s) < 1:
        die("max_turns %r from %s must be a whole number of turns >= 1" % (value, where))
    return s


def resolve_max_turns(role, cfg, env):
    """Agent-TURN ceiling for a role, or "" when uncapped. Most specific wins:

        DOZER_MAX_TURNS_<ROLE>          env, this run (dots fold to _)
        DOZER_MAX_TURNS                 env, this run, every role
        models.<lane>.<role>.max_turns  config, this role
        models.<lane>.max_turns         config, shared by the lane
        (nothing)                       uncapped

    Why (GSAI-170): the 2026-09-20 spend audit attributed ~52% of all Ollama spend to
    the dev BUILD role, whose fix-the-failing-tests loop happily runs to the one-hour
    timebox. A wall-clock bound stops a HANG; only a turn cap stops a LOOP.
    """
    for key in (max_turns_key(role), "DOZER_MAX_TURNS"):
        v = (env.get(key) or "").strip()
        if v:
            return _turns(v, "env:" + key)
    models = cfg.get("models") or {}
    if not isinstance(models, dict):
        return ""
    lane, _, sub = role.partition(".")
    lane_entry = models.get(lane)
    if isinstance(lane_entry, dict):
        if sub and "provider" not in lane_entry:
            role_entry = lane_entry.get(sub)
            if isinstance(role_entry, dict) and role_entry.get("max_turns") is not None:
                return _turns(role_entry["max_turns"], "config:models.%s.max_turns" % role)
        if lane_entry.get("max_turns") is not None:
            return _turns(lane_entry["max_turns"], "config:models.%s.max_turns" % lane)
    return ""


def resolve_route(role, cfg, env):
    """(provider, model, small, source) for a role. Env override beats config.

    Config resolution order for a dotted role like `dev.build`:
        models.dev.build   (nested lane entry: role -> {provider, model})
        models.dev         (flat lane entry, shared by every role of the lane)
        models.default
        legacy             (no models: block at all -> bare claude)

    `small` is the ANTHROPIC_SMALL_FAST_MODEL pin: taken from the role's own entry,
    else the lane-level `small` (string on a nested lane) / `small_model:` (on a flat
    entry). "" means "unset" — the caller prints small = main, today's behaviour.
    """
    override = env.get(role_key(role))
    if override:
        override = override.strip()
        provider, _, model = override.partition(":")
        return provider.strip(), model.strip(), "", "env:" + role_key(role)

    models = cfg.get("models") or {}
    if not isinstance(models, dict):
        die("`models:` in config is not a mapping")

    lane, _, sub = role.partition(".")
    entry = None
    source = small = ""
    if sub:
        lane_entry = models.get(lane)
        if lane_entry is not None and not isinstance(lane_entry, dict):
            die("`models.%s` must be a mapping" % lane)
        if isinstance(lane_entry, dict) and "provider" not in lane_entry:
            # `dev.small` is the lane's pin asked for as a role (GSAI-170), not a
            # missing role: resolve it here rather than dying on "must be a mapping".
            if sub in LANE_SMALL_KEYS:
                return _promote_small(lane, lane_entry, role)
            entry = lane_entry.get(sub)
            if entry is not None:
                source = "config:models.%s" % role
                if not isinstance(entry, dict):
                    die("`models.%s` must be a mapping with provider/model" % role)
                small = str(entry.get("small_model") or "").strip()
            if not small:
                for k in LANE_SMALL_KEYS:
                    v = lane_entry.get(k)
                    if v is None:
                        continue
                    if not isinstance(v, str):
                        die("`models.%s.%s` must be a model-id string" % (lane, k))
                    small = v.strip()
                    if small:
                        break
    if entry is None:
        entry = models.get(lane)
        source = "config:models.%s" % lane
        if isinstance(entry, dict) and "provider" not in entry:
            if sub:
                # Nested lane without this role, and no lane-level fallback — fail fast.
                die(
                    "`models.%s` is a nested lane with roles %s but has no `%s` entry — "
                    "add `%s: { provider: ..., model: ... }` or rely on a flat `models.%s`"
                    % (lane, ", ".join(sorted(lane_roles(entry))) or "(none)",
                       role, sub, lane)
                )
            entry = None  # a bare lane name never routes through a nested entry
    if entry is None:
        entry = models.get("default")
        source = "config:models.default"
        if isinstance(entry, dict) and "provider" not in entry:
            die("`models.default` must be a flat mapping with provider/model")
    if entry is None:
        # No models: block at all — legacy behavior, honour flat model_cmd via claude.
        return "claude", "", "", "config:legacy-default"
    if not isinstance(entry, dict) or "provider" not in entry:
        die("`models.%s` must be a mapping with provider/model" % (role if sub else lane))
    if not small:
        small = str(entry.get("small_model") or "").strip()
    return (
        str(entry.get("provider") or "claude").strip(),
        str(entry.get("model") or "").strip(),
        small,
        source,
    )


def read_env_file(path):
    """Parse a KEY=VALUE dotenv file into a dict. Returns {} if unreadable."""
    out = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if line.startswith("export "):
                    line = line[len("export "):].strip()
                k, sep, v = line.partition("=")
                if not sep:
                    continue
                v = v.strip()
                if len(v) >= 2 and v[0] == v[-1] and v[0] in ("'", '"'):
                    v = v[1:-1]
                out[k.strip()] = v
    except OSError:
        return {}
    return out


def ollama_key(cfg, env):
    """OLLAMA_API_KEY from the environment, else from the vault file named in config.

    Fail fast: returns (key, source) or exits 2 with a message naming where we looked.
    """
    if env.get("OLLAMA_API_KEY"):
        return env["OLLAMA_API_KEY"], "env:OLLAMA_API_KEY"
    path = expand(cfg.get("ollama_env") or DEFAULT_OLLAMA_ENV)
    if not os.path.exists(path):
        die(
            "ollama provider needs OLLAMA_API_KEY — not in the environment and no vault "
            "file at %s (set `ollama_env:` in org/config.yaml or export OLLAMA_API_KEY)" % path
        )
    key = read_env_file(path).get("OLLAMA_API_KEY", "")
    if not key:
        die("vault file %s has no OLLAMA_API_KEY line" % path)
    return key, "vault:%s" % path


def emit(lines):
    sys.stdout.write("\n".join(lines) + "\n")


def build(role, cfg, env):
    provider, model, small, source = resolve_route(role, cfg, env)
    if provider not in PROVIDERS:
        die(
            "unknown provider %r for role %r (from %s) — pick one of: %s"
            % (provider, role, source, ", ".join(PROVIDERS))
        )

    out = []

    def export(name, value):
        out.append("export %s=%s" % (name, shlex.quote(str(value))))

    if provider == "claude":
        # An empty model means a bare `claude -p` — the CLI picks whatever its default
        # is that day. That is not a route, it is a coin flip, and it silently moved the
        # dev lane onto Fable 5.1 at 2x Opus 5's price for a week (GSAI-83). Config must
        # name the model. An env override stays loose on purpose: a human typing
        # DOZER_MODEL_DEV=claude for one run has chosen, and `model.sh smoke claude`
        # needs to probe the provider default.
        if not model and source.startswith("config:"):
            die(
                "role %r routes to claude with no model (from %s) — a bare `claude -p` "
                "inherits the CLI's shifting default. Name it explicitly, e.g.\n"
                "    models:\n      %s: { provider: claude, model: \"claude-opus-5\" }\n"
                "For a deliberate one-off, use %s=claude instead."
                % (role, source, role, role_key(role))
            )
        cmd = "claude -p"
        if model:
            cmd += " --model " + shlex.quote(model)

    elif provider in ("ollama-cloud", "ollama-local"):
        if provider == "ollama-cloud":
            base = OLLAMA_CLOUD_URL
            model = model or OLLAMA_CLOUD_DEFAULT_MODEL
            token, _ = ollama_key(cfg, env)
        else:
            base = OLLAMA_LOCAL_URL
            if not model:
                die(
                    "provider ollama-local needs an explicit model (there is no safe "
                    "host-independent default) — e.g. %s=ollama-local:qwen2.5:7b-instruct; "
                    "`ollama list` shows what this host has" % role_key(role)
                )
            # The local daemon speaks the Anthropic-compatible API without auth; Claude
            # Code still insists on a token being present, so send a non-secret placeholder.
            token = env.get("OLLAMA_API_KEY") or "local"
        # ANTHROPIC_API_KEY must NOT be set alongside ANTHROPIC_AUTH_TOKEN — it makes
        # Claude Code send an x-api-key these endpoints reject (401, then it hangs).
        out.append("unset ANTHROPIC_API_KEY")
        export("ANTHROPIC_BASE_URL", base)
        export("ANTHROPIC_AUTH_TOKEN", token)
        export("ANTHROPIC_MODEL", model)
        # `small` (nested lane) / `small_model:` (flat entry) pins the small/fast model
        # (auto-compact, title gen) instead of burning the main model on it. Unset:
        # small = main, the original behaviour.
        export("ANTHROPIC_SMALL_FAST_MODEL", small or model)
        # count_tokens 404s on these endpoints; disabling non-essential traffic avoids it.
        export("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "1")
        cmd = "claude -p"

    elif provider == "codex":
        cmd = "codex exec"
        if model:
            cmd += " --model " + shlex.quote(model)

    # ── Turn cap (GSAI-170) ────────────────────────────────────────────────────────
    # A budget the crew can SEE either way: DOZER_MODEL_MAX_TURNS is exported whether
    # or not the flag went on, and DOZER_MODEL_MAX_TURNS_UNSUPPORTED marks the
    # providers that cannot take it — the crew then bounds that pass by wall clock and
    # says so, rather than pretending the loop is capped. Both names are cleared first
    # so a value inherited from an earlier pass can never vouch for this one.
    out.append("unset DOZER_MODEL_MAX_TURNS DOZER_MODEL_MAX_TURNS_UNSUPPORTED")
    turns = resolve_max_turns(role, cfg, env)
    if turns:
        export("DOZER_MODEL_MAX_TURNS", turns)
        if provider in TURN_CAPPABLE:
            cmd += " --max-turns " + shlex.quote(turns)
        else:
            export("DOZER_MODEL_MAX_TURNS_UNSUPPORTED", "1")

    export("DOZER_MODEL_PROVIDER", provider)
    export("DOZER_MODEL_NAME", model)
    export("DOZER_MODEL_SOURCE", source)
    export("MODEL_CMD", cmd)
    return out


def main():
    ap = argparse.ArgumentParser(description="Resolve a Dozer role's model route.")
    ap.add_argument("role", help="role: a lane (dev, marketing) or dotted dev.architect/dev.build/dev.review; 'default' fallback")
    ap.add_argument("--config", default=DEFAULT_CONFIG, help="path to org/config.yaml")
    ap.add_argument(
        "--show", action="store_true",
        help="print a human table of role -> provider/model (NEVER prints secrets)",
    )
    args = ap.parse_args()

    cfg = load_config(args.config)
    if args.show:
        show(cfg, os.environ)
        return
    emit(build(args.role, cfg, os.environ))


def show(cfg, env):
    """Role -> provider/model table. Deliberately prints no secret values.

    A nested lane entry (models.<lane> without a `provider` key) is shown as one row
    per role — `dev.architect`, `dev.build`, `dev.review` — never as a bare lane row.
    """
    models = cfg.get("models") or {}
    roles = list(dict.fromkeys(["default"] + [r for r in models if r != "default"]))
    for lane in (cfg.get("lanes") or []):
        if lane not in roles:
            roles.append(str(lane))
    rows = []
    for role in roles:
        entry = models.get(role)
        nested = lane_roles(entry)
        if nested and role != "default":
            rows.extend("%s.%s" % (role, sub) for sub in nested)
            # The lane's small pin is a real route a crew can ask for (the `lite`
            # profile runs on it, GSAI-170) — show it as its own row, after the roles.
            if isinstance(entry, dict) and any(entry.get(k) for k in LANE_SMALL_KEYS):
                rows.append("%s.small" % role)
        else:
            rows.append(role)
    print("%-12s %-14s %-24s %s" % ("ROLE", "PROVIDER", "MODEL", "SOURCE"))
    for role in rows:
        try:
            provider, model, small, source = resolve_route(role, cfg, env)
        except SystemExit:
            provider, model, small, source = "?", "?", "", "unresolved"
        if provider == "ollama-cloud" and not model:
            model = OLLAMA_CLOUD_DEFAULT_MODEL + " (provider default)"
        model = model or "(provider default)"
        if small:
            model += " (small: %s)" % small
        try:
            turns = resolve_max_turns(role, cfg, env)
        except SystemExit:
            turns = "?"
        if turns:
            model += " [max %s turns]" % turns
        print("%-12s %-14s %-24s %s" % (role, provider, model, source))

    path = expand(cfg.get("ollama_env") or DEFAULT_OLLAMA_ENV)
    if env.get("OLLAMA_API_KEY"):
        state = "present (env OLLAMA_API_KEY)"
    elif os.path.exists(path) and read_env_file(path).get("OLLAMA_API_KEY"):
        state = "present (%s)" % path
    else:
        state = "MISSING (looked in env and %s)" % path
    print("\nollama key: %s" % state)


if __name__ == "__main__":
    main()
