# Agent Vault + Dockerized Hermes: Setup Runbook

Credential brokering for a containerized Hermes Agent, so the agent holds
placeholder strings instead of real API keys. Written from an actual build,
including the parts that went wrong.

**Result:** 15 credentials brokered. Prompt-inject the agent into dumping its
environment and it hands over 15 fake strings.

---

## What this actually does

Traditional secrets management delivers real credentials to the application.
That assumes the application is deterministic and cannot be talked into
misusing them. Agents break that assumption.

A credential broker sits between the agent and the APIs it calls. The agent
holds `__exa_api_key__`. When it calls `api.exa.ai`, the broker swaps in the
real key on the wire and scrubs it back out of the response.

```
  Hermes container                Agent Vault container         Upstream
  ----------------                ---------------------         --------
  .env holds:                     :14321  UI / API
    EXA_API_KEY=__exa_api_key__   :14322  MITM proxy
                                                                api.exa.ai
    HTTPS_PROXY ------------------->  swaps placeholder  --------->  200
                                      for the real key
    CA cert mounted                   (real key never
                                       leaves this box)
```

---

## Prerequisites

- Docker with the Hermes container already running on a named volume
- A secrets source to populate the vault from (1Password here)
- Roughly 90 minutes, mostly spent on per-service verification

**Topology note.** Infisical recommends running the broker on a *different
host* from the agent, so a compromised agent cannot exploit shared-host access
to reach the vault. Running both on one Docker host is weaker than that. It
still defeats the main threat (prompt injection making the agent leak keys it
holds) because the agent holds only placeholders and has no path to the
broker's volume.

---

## Phase 1: Stand up the broker

`agent-vault.yml`, kept separate from the Hermes compose file:

```yaml
services:
  agent-vault:
    # Pin by digest. This is preview software with an unstable API.
    image: infisical/agent-vault@sha256:<digest>
    container_name: agent-vault
    restart: unless-stopped
    ports:
      - "127.0.0.1:14321:14321"   # UI / API
      - "127.0.0.1:14322:14322"   # MITM proxy
    environment:
      - AGENT_VAULT_MASTER_PASSWORD=${AGENT_VAULT_MASTER_PASSWORD}
      - AGENT_VAULT_ADDR=http://localhost:14321
    volumes:
      - agent-vault-data:/data
    networks:
      - broker-net

volumes:
  agent-vault-data:

networks:
  broker-net:
    name: broker-net
```

Start it with the password supplied at the command line so it never lands in
the file:

```powershell
$env:AGENT_VAULT_MASTER_PASSWORD = "<password>"
docker compose -f agent-vault.yml up -d
```

Register the owner account at `http://localhost:14321/register`.

> **Store the master password immediately.** It wraps the data encryption key
> and lives only in memory once the server unlocks. Lose it and every stored
> credential is unrecoverable.

---

## Phase 2: Extract the CA certificate

The broker terminates TLS to perform substitution, so the agent must trust its
CA or every HTTPS call fails verification.

```powershell
docker cp agent-vault:/data/.agent-vault/ca/ca.crt.pem .\agent-vault-ca\mitm-ca.pem
```

Verify it is a real CA:

```powershell
$c = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(".\agent-vault-ca\mitm-ca.pem")
"$($c.Subject) | valid to $($c.NotAfter)"
# CN=Agent Vault Root CA | valid to 2036
```

The private key stays in the broker as `ca.key.enc`. Only the public cert
leaves.

---

## Phase 3: Wire the agent container

> **Do not use the documented Dockerfile approach.** Agent Vault's docs suggest
> `ENTRYPOINT ["agent-vault", "run", "--", "hermes"]`. On the Hermes image this
> replaces `/init`, which kills s6-overlay and every supervised profile gateway.
> Set the environment directly instead. This is what the official VPS guide's
> systemd unit does, and it works with a stock pinned image, so the update path
> stays clean.

Add to the Hermes service in `docker-compose.yml`:

```yaml
    volumes:
      - "<path>/agent-vault-ca/mitm-ca.pem:/opt/agent-vault-ca.pem:ro"
    environment:
      - AGENT_VAULT_ADDR=http://agent-vault:14321
      - AGENT_VAULT_VAULT=prod
      - AGENT_VAULT_TOKEN=${AGENT_VAULT_TOKEN}
      - HTTPS_PROXY=http://${AGENT_VAULT_TOKEN}@agent-vault:14322
      - HTTP_PROXY=http://${AGENT_VAULT_TOKEN}@agent-vault:14322
      - NO_PROXY=localhost,127.0.0.1,::1,agent-vault
      - no_proxy=localhost,127.0.0.1,::1,agent-vault
      - REQUESTS_CA_BUNDLE=/opt/agent-vault-ca.pem
      - SSL_CERT_FILE=/opt/agent-vault-ca.pem
      - NODE_EXTRA_CA_CERTS=/opt/agent-vault-ca.pem
      - CURL_CA_BUNDLE=/opt/agent-vault-ca.pem
      - GIT_SSL_CAINFO=/opt/agent-vault-ca.pem
      - NODE_USE_ENV_PROXY=1
    networks:
      - broker-net

networks:
  broker-net:
    external: true
```

`NO_PROXY` must exclude the broker itself, or the `AGENT_VAULT_ADDR` API calls
loop through the proxy.

---

## Phase 4: Per-credential procedure

Repeat for each key. Do **one** first and verify it end to end before batching.

### 1. Find the host the agent actually calls

Not the host in the config file. Grep the application code:

```bash
docker exec hermes bash -c \
  'grep -rhoE "https://[a-zA-Z0-9._-]+" /opt/hermes/agent /opt/hermes/tools \
   --include=*.py | sort -u'
```

This caught a real trap: `config.yaml` declared `gateway.kilo.ai`, but the
provider resolved through the registry to `api.kilo.ai`. The config block was
dead, and `gateway.kilo.ai` did not even resolve to a live server. A rule on
the wrong host silently never matches.

### 2. Add the credential

Use the drag-and-drop `.env` import in Add Credential rather than typing
values. Generate a curated file from your secrets manager, drop it in, then
shred the file.

Do **not** drop your live `.env` once brokering has started: it will contain
placeholders and will overwrite good credentials with fake ones.

### 3. Create the service rule

| Field | Value |
|---|---|
| Name | e.g. `exa` |
| Host | the verified host |
| Authentication | Passthrough |
| Placeholder | e.g. `__exa_api_key__` |
| Credential | the stored credential name |
| Surface | tick exactly **one** |

**Surface matters.** Most APIs read the credential from a header. Telegram's
Bot API encodes the token in the URL path (`/bot<TOKEN>/getUpdates`), so it
needs `path`. Multiple surfaces may be pre-ticked; untick the extras.

### 4. Test before swapping anything

This is the step that catches everything. Send the placeholder through the
broker and compare against a deliberately unconfigured one:

```powershell
$tok = "<agent token>"
$ca  = "<path>/mitm-ca.pem"
foreach($ph in @("__exa_api_key__","__not_configured__")){
  docker run --rm --network broker-net -v "${ca}:/ca.pem:ro" curlimages/curl `
    -s -o /dev/null -w "$ph -> %{http_code}`n" `
    --proxy "http://${tok}@agent-vault:14322" --cacert /ca.pem `
    -X POST https://api.exa.ai/search `
    -H "x-api-key: $ph" -H "Content-Type: application/json" -d '{}'
}
```

Reading the result:

| Configured | Control | Meaning |
|---|---|---|
| 200 / 400 / 405 / 422 | 401 / 403 | **Working.** Authenticated; the non-200s are just a bad request body |
| 401 | 401 | Rule not matching. Wrong host, wrong placeholder, or wrong surface |
| 502 | 502 | Rule matches but the credential name does not resolve |
| same code both | same | Endpoint does not require auth. Pick a different one to test with |

> Many `/v1/models` endpoints are unauthenticated and return 200 regardless.
> They cannot discriminate. Use an endpoint that actually requires auth.

### 5. Swap the placeholder in **both** places

If a schema generates your `.env`, update the schema too, or the next render
silently restores the real key and un-brokers it.

```powershell
docker exec hermes sh -c "cp /opt/data/.env /opt/data/.env.bak.<name>"
docker exec hermes sh -c "sed -i 's|^EXA_API_KEY=.*|EXA_API_KEY=__exa_api_key__|' /opt/data/.env"
docker exec hermes hermes gateway restart
```

### 6. Verify health

Poll rather than sleeping. A gateway restart measured about 110 seconds; a
container recreate is longer.

```powershell
docker exec hermes cat /opt/data/gateway_state.json
docker exec hermes hermes chat -q "Reply with exactly: OK"
```

---

## Verified hosts

| Credential | Host | Surface |
|---|---|---|
| Telegram | `api.telegram.org` | **path** |
| Exa | `api.exa.ai` | header |
| Honcho | `api.honcho.dev` | header |
| Kilo | `api.kilo.ai` | header |
| Ollama | `ollama.com` | header |
| OpenRouter | `openrouter.ai` | header |
| Brave | `api.search.brave.com` | header |
| Tavily | `api.tavily.com` | header |
| Serper | `google.serper.dev` | header |
| Firecrawl | `api.firecrawl.dev` | header |
| Parallel | `api.parallel.ai` | header |
| FAL | `queue.fal.run` + `fal.run` | header |
| ScrapeCreators | `api.scrapecreators.com` | header |
| xAI | `api.x.ai` | header |
| GitHub | `api.github.com` | header |

**Not brokerable.** Inbound auth keys (the agent's own API server key) are
never sent upstream. Neither are local config values like allowlists and
channel IDs. Leave them as real values.

---

## Failure modes hit

**Inference working did not prove substitution worked.** The real key was still
in `.env`, so calls succeeded by passthrough. Only the control test revealed
that the configured placeholder was returning 401. Always test both arms.

**Placeholder strings are exact-match.** A service configured with
`__kilo_api_key__` while the agent sent `__kilocode_api_key__` produced a plain
401 with no hint of the cause.

**Credential name mismatch fails closed.** A rule pointing at a credential name
that does not exist returns `502: A required credential could not be resolved`
and blocks the call. Good behavior, and a legible error, but it takes the
service down until fixed.

**Rotating the agent token breaks the running container.** The old token is
invalidated immediately, so every brokered call fails with "Connection error"
until you recreate with the new one. Rotation is two steps.

**An unset `AGENT_VAULT_TOKEN` silently breaks everything.** Compose
interpolates a missing variable to an empty string, producing
`HTTPS_PROXY=http://@agent-vault:14322`. Guard against it:

```powershell
if ($env:AGENT_VAULT_TOKEN -notmatch '^av_agt_[0-9a-f]{32,}$') {
    throw "AGENT_VAULT_TOKEN missing or malformed. Refusing to run."
}
```

Non-empty is not enough. A wrong-but-present token fails auth at the broker on
every call.

**Never run `docker compose up -d --remove-orphans`** in a directory holding
both compose files. Compose treats the broker as an orphan of the agent project
and deletes it.

**Three different secrets, easily confused.**

| Secret | Format | Purpose | If lost |
|---|---|---|---|
| Master password | your choice | unlocks the vault's encryption | **unrecoverable** |
| Agent token | `av_agt_` + 64 hex | authenticates one agent | regenerate |
| Session token | `av_sess_` + ... | ephemeral, per-run sandboxes | ignore |

---

## Operations

**Rotate a brokered credential.** Update it in the vault. The agent needs no
change at all, since it only holds a placeholder. This is the payoff.

**Rotate the agent token.** Rotate in the UI, store the new value, then:

```powershell
$env:AGENT_VAULT_TOKEN = <read from secrets manager>
docker compose up -d
```

**Update the agent image.** Ensure the token is present, never use
`--remove-orphans`, poll for health rather than sleeping, and confirm the
placeholder count survived:

```powershell
docker exec hermes sh -c "grep -cE '=__[a-z_]+__$' /opt/data/.env"
```

**Roll back.** Every swap should write a timestamped `.env` backup first.
Restore it and restart the gateway.

---

## Diagnostics that do not work in-container

- `ss` is not installed. Read `/proc/net/tcp` instead; the broker at
  `172.19.0.2:14322` appears as `020013AC:37F2`.
- `/proc/<pid>/environ` returns Permission denied even as root, because Docker
  drops `CAP_SYS_PTRACE`. Useful security property, unhelpful for debugging.
- `sqlite3` is not in the broker image, so the config database cannot be
  inspected directly. Use the UI.
- Schema files must be UTF-8 **without** a BOM. PowerShell's
  `Set-Content -Encoding UTF8` adds one and parsers reject it.

---

## What this does and does not buy

**Does:** the agent cannot read the credentials it uses. Prompt injection,
environment dumps, and leaked `.env` files yield placeholders. Every brokered
credential is revocable in one click, and rotation never touches the agent.
Every request is logged with the credential name but never the value.

**Does not:** eliminate plaintext. The real values live in the broker's
encrypted store, and the master password unlocking it must be available for
unattended restart. You have traded many readable secrets for one protected
store the agent cannot reach. That is a real improvement, not a perfect one.

**Weakest link in a same-host deployment:** anything with access to the Docker
socket can reach both containers. Separate hosts, plus an egress firewall
restricting the agent to the broker, is what makes it a hard boundary.


---

## Adapting this to packaged Hermes distributions

The above assumes you run Hermes yourself: your own compose file, your own
container, your own update path. Packaged distributions like
[Fox in the Box](https://foxinthebox.io) bundle Hermes into a single managed
container with a desktop app, one-click install, and auto-updates.

The brokering concept transfers cleanly. The wiring does not. These are the
differences worth checking before you start. **None of this has been tested
against a packaged build** — treat it as a list of things to verify, not
instructions.

### Auto-updates may silently undo the wiring

This is the one that will bite hardest.

Brokering depends on `HTTPS_PROXY`, `NO_PROXY`, the CA bundle variables, and a
CA file mounted into the container. If a desktop app or updater recreates the
container from its own template, all of that disappears. The agent comes back
holding placeholder strings with no proxy to resolve them, and every brokered
call fails.

There is no error at install time and no warning. It just stops working after
an update.

Before wiring anything, find out whether the distribution supports **persistent
custom environment variables and volume mounts** that survive a container
recreate. If it does not, brokering will need re-applying after every update,
which is a maintenance burden worth knowing about up front.

A cheap canary, run after any update:

```bash
docker exec <container> printenv HTTPS_PROXY
docker exec <container> sh -c "grep -cE '=__[a-z_]+__$' /path/to/.env"
```

If the first is empty while the second is non-zero, the agent is holding
placeholders with no broker. That is the broken state.

### Single-container topologies

Packaged distributions often run everything in one container and deliberately
give it no access to the host. Good isolation, but it means the broker cannot
live on the host loopback and be reached the usual way.

Options, roughly in order of preference:

1. **Broker on a second machine**, reached over a private network. Best
   isolation, and what Infisical recommends anyway.
2. **Broker as a sibling container** on a shared Docker network, with the agent
   joined to that network. Requires the distribution to allow custom networks.
3. **Broker on the host**, reached via `host.docker.internal`. Works on Docker
   Desktop, but only if the distribution's isolation does not block it.

Hosted or cloud tiers, where you do not control the container, generally cannot
do this at all. Brokering needs to sit in the network path.

### Tailscale solves the separate-host problem

Distributions that ship Tailscale for remote access have a better answer
available than the one used above.

Running the broker and the agent on the same Docker host is the weakest part of
this setup: anything with Docker socket access reaches both. Infisical's own
guidance is to separate them.

A broker on a second machine, reachable over your tailnet, gives you that
separation without exposing the proxy port to the internet. Point
`HTTPS_PROXY` at the broker's tailnet address instead of a container name.

Watch the latency. Every brokered call is a round trip, and agents make a lot
of calls. Keep the two machines geographically close.

### Local model providers do not need brokering

If you run models locally (Ollama on the host or in-container), there is no
credential to substitute. Routing that traffic through the broker adds a hop
and a TLS interception for no benefit.

Add local endpoints to `NO_PROXY`:

```
NO_PROXY=localhost,127.0.0.1,::1,agent-vault,host.docker.internal,ollama
```

Brokering is for credentials leaving your network. Local inference is neither.

### Other chat platforms

Telegram needs the `path` surface because its Bot API puts the token in the
URL. That is unusual. Most platforms use headers, but the formats differ:

| Platform | Where the credential goes | Surface |
|---|---|---|
| Telegram | `/bot<TOKEN>/method` in the URL | **path** |
| Discord | `Authorization: Bot <TOKEN>` | header |
| Slack | `Authorization: Bearer xoxb-...` | header |
| WhatsApp (Meta) | `Authorization: Bearer <TOKEN>` | header |

The principle generalizes: find where the credential actually travels, then
pick the surface to match. The specific answer does not transfer between
platforms.

### Memory providers differ

This build used Honcho (`api.honcho.dev`). Distributions using mem0 or another
provider will have a different host, and a self-hosted memory backend needs no
brokering at all since the credential never leaves your network.

The general check applies: grep the running code for the hosts it actually
calls rather than trusting a config file or a table like the one above.
