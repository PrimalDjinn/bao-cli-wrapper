# bao-cli-wrapper

`bao-setup-vault.sh` is an interactive Bash wrapper around the [OpenBao](https://openbao.org)
`bao` CLI. It sets up one KV v2 mount per application with a public and a private area,
the policies for each, a named public token, and an AppRole for the private area. It is
meant for the OpenBao served by [cloudflare-openbao](https://github.com/PrimalDjinn/cloudflare-openbao),
but works against any OpenBao or Vault-compatible server.

It needs Bash and the `bao` CLI on `PATH`.

## Commands

| Command | Purpose |
| --- | --- |
| `setup` (alias `add-app`) | Interactive: mount, policies, public token and AppRole for an app. |
| `list` | List the policies on the server. |
| `renew-public-token [app env]` | Revoke and recreate an app's public token. |
| `revoke` | Revoke a token by ID or accessor. |
| `help` | Show usage. |

```sh
cp .env.example .env     # BAO_ADDR and an admin BAO_TOKEN
source .env
./bao-setup-vault.sh setup
```

## Environment

| Variable | Used by | Purpose |
| --- | --- | --- |
| `BAO_ADDR` | all | Server address. |
| `BAO_TOKEN` | all | Admin token for management commands. |
| `BAO_CLIENT_TIMEOUT` | all | Seconds to wait for each request. Defaults to 40. |
| `BAO_MAX_RETRIES` | all | Retries of 5xx responses. Defaults to 0. |
| `BAO_SETUP_SKIP_PREFLIGHT` | all | Set to `1` to skip the status check below. |

## Timeouts and a server that does not answer

The `bao` client waits 60 seconds per attempt and retries 5xx responses twice, so a hung
server can hold a command for minutes, and a retried write whose first attempt had already
succeeded reports a misleading error. The script therefore defaults to a 40-second request
timeout and no retries. The wrapper in front of OpenBao answers `504` after 30 seconds, so a
longer timeout adds nothing. A variable you set yourself, including the `VAULT_*` spelling, is
never overridden.

Commands that talk to the server first run `bao status`. A sealed server, or one that does
not answer, stops the command before the first question instead of after the last one. A
`504` or timeout on a write does not prove the write failed: check the result (`list`, or a
token lookup) before repeating `renew-public-token` or creating credentials again.

If the server itself is wedged, see the recovery runbook in
[cloudflare-openbao](https://github.com/PrimalDjinn/cloudflare-openbao/blob/main/docs/operations/container-recovery.md).

## Tests

```sh
bash tests/test.sh
```

The tests run the script against a fake `bao` that records every call, so they need no server.
They cover the client defaults and the status check.
