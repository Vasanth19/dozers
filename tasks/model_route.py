#!/usr/bin/env python3
"""Resolve which MODEL (brain) a Dozer ROLE runs on, and print an eval-able shell block.

One knob, one place. `org/config.yaml` maps a ROLE (today: the lane name — dev,
marketing — plus `default` for anything unlisted) to a PROVIDER and a MODEL id.
An env override always wins:

    DOZER_MODEL_<ROLE>="<provider>[:<model>]"     e.g. DOZER_MODEL_DEV=ollama-cloud:glm-5.2

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


def resolve_route(role, cfg, env):
    """(provider, model, source) for a role. Env override beats config beats default."""
    override = env.get(role_key(role))
    if override:
        override = override.strip()
        provider, _, model = override.partition(":")
        return provider.strip(), model.strip(), "env:" + role_key(role)

    models = cfg.get("models") or {}
    if not isinstance(models, dict):
        die("`models:` in config is not a mapping")
    entry = models.get(role)
    source = "config:models.%s" % role
    if entry is None:
        entry = models.get("default")
        source = "config:models.default"
    if entry is None:
        # No models: block at all — legacy behavior, honour flat model_cmd via claude.
        return "claude", "", "config:legacy-default"
    if not isinstance(entry, dict):
        die("`models.%s` must be a mapping with provider/model" % role)
    return (
        str(entry.get("provider") or "claude").strip(),
        str(entry.get("model") or "").strip(),
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
    provider, model, source = resolve_route(role, cfg, env)
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
        export("ANTHROPIC_SMALL_FAST_MODEL", model)
        # count_tokens 404s on these endpoints; disabling non-essential traffic avoids it.
        export("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "1")
        cmd = "claude -p"

    elif provider == "codex":
        cmd = "codex exec"
        if model:
            cmd += " --model " + shlex.quote(model)

    export("DOZER_MODEL_PROVIDER", provider)
    export("DOZER_MODEL_NAME", model)
    export("DOZER_MODEL_SOURCE", source)
    export("MODEL_CMD", cmd)
    return out


def main():
    ap = argparse.ArgumentParser(description="Resolve a Dozer role's model route.")
    ap.add_argument("role", help="role name (lane): dev, marketing, ... ; 'default' fallback")
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
    """Role -> provider/model table. Deliberately prints no secret values."""
    models = cfg.get("models") or {}
    roles = list(dict.fromkeys(["default"] + [r for r in models if r != "default"]))
    for lane in (cfg.get("lanes") or []):
        if lane not in roles:
            roles.append(str(lane))
    print("%-12s %-14s %-24s %s" % ("ROLE", "PROVIDER", "MODEL", "SOURCE"))
    for role in roles:
        try:
            provider, model, source = resolve_route(role, cfg, env)
        except SystemExit:
            provider, model, source = "?", "?", "unresolved"
        if provider == "ollama-cloud" and not model:
            model = OLLAMA_CLOUD_DEFAULT_MODEL + " (provider default)"
        print("%-12s %-14s %-24s %s" % (role, provider, model or "(provider default)", source))

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
