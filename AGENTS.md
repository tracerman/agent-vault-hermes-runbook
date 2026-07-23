# AGENTS.md

Guidance for AI coding agents working with this repository.

## What this repo is

A runbook and supporting files for putting a **credential broker** in front of
a containerized AI agent, so the agent holds placeholder strings like
`__exa_api_key__` instead of real API keys. The broker substitutes the real
value on the wire.

`README.md` is the full procedure. Read it before acting.

## Division of labour

This matters more here than in most repos.

**You (the agent) can do:** stand up the broker container, extract the CA
certificate, edit compose files, run the verification tests, swap placeholders
in `.env`, restart and health-check, diagnose failures.

**The human must do:** add credential *values* to the vault, create service
rules in the web UI, choose and store the master password.

That split is deliberate. The point of this system is that agents do not hold
credentials. Asking an agent to paste real secrets into a vault in order to set
up a system that keeps secrets away from agents defeats the exercise. Do not
offer to do it, and do not read secret values out of a password manager.

If credentials need adding, tell the human to use the drag-and-drop `.env`
import in the vault's Add Credential dialog, then delete the file.

## Files

| File | Purpose |
|---|---|
| `README.md` | Full runbook, including failure modes |
| `agent-vault.yml` | Compose file for the broker. Standalone |
| `compose-snippet.yml` | Env and volume block to merge into the agent's compose |
| `test-service.sh` / `.ps1` | Verify a service rule before swapping anything |

## The one rule that matters

**Never swap a real credential for a placeholder until the paired test passes.**

Run the test with the configured placeholder AND with a deliberately
unconfigured one. A single result proves nothing: if the real key is still in
place, calls succeed by passthrough whether or not substitution works.

```bash
./test-service.sh https://api.example.com/endpoint x-api-key __example_api_key__ POST '{}'
```

Interpreting it:

| Configured | Control | Meaning |
|---|---|---|
| 200/400/405/422 | 401/403 | Working. Non-200 just means a bad request body |
| 401 | 401 | Rule not matching: host, placeholder, or surface |
| 502 | 502 | Credential name in the rule does not exist in the vault |
| identical | identical | Endpoint does not require auth. Use a different one |

## Things that will waste your time

**Find the host from the code, not the config.** Config files go stale. Grep
the running application for the hosts it actually calls. In the build this
came from, a config declared `gateway.kilo.ai` while the code resolved to
`api.kilo.ai`, and the declared host did not even resolve to a live server.

**Placeholders are exact-match and case-sensitive.** `__kilo_api_key__` and
`__kilocode_api_key__` are different strings and the failure is a bare 401.

**Do not override ENTRYPOINT.** The vendor docs suggest
`ENTRYPOINT ["agent-vault", "run", "--", "<agent>"]`. On s6-overlay images that
replaces `/init` and kills the supervisor. Set environment variables instead.

**Update both the schema and the live `.env`.** If a schema generates `.env`,
editing only `.env` means the next render silently restores the real key.

**Never run `docker compose up -d --remove-orphans`** where the broker and
agent compose files share a directory. It deletes the broker.

**An empty `AGENT_VAULT_TOKEN` breaks everything silently.** Compose
interpolates a missing variable to an empty string. Guard for it, and check the
format, not just presence: a wrong-but-present token fails auth on every call.

## Verifying your work

```bash
docker exec <agent> printenv HTTPS_PROXY          # must be non-empty
docker exec <agent> cat /path/to/gateway_state.json
docker exec <agent> sh -c "grep -cE '=__[a-z_]+__$' /path/to/.env"
```

If `HTTPS_PROXY` is empty while placeholders exist, the agent is holding fake
credentials with no broker to resolve them. That is the broken state, and it is
what a container recreate without the env vars produces.

## Diagnostics that do not work

- `ss` is usually not installed. Read `/proc/net/tcp`.
- `/proc/<pid>/environ` returns Permission denied even as root, because Docker
  drops `CAP_SYS_PTRACE`.
- The broker image has no `sqlite3`, so its config database cannot be inspected
  directly. Use the web UI.
- Quoting JSON inline through a shell into `docker run` into `curl` fails
  constantly. Write the body to a file and use `-d @file`.
