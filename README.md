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
| `check-approle [--ttl 15m] [--read PATH]...` | Log in with an AppRole, read, then revoke the token. |
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
| `BAO_TOKEN` | all but `check-approle` | Admin token for management commands. |
| `BAO_CLIENT_TIMEOUT` | all | Seconds to wait for each request. Defaults to 40. |
| `BAO_MAX_RETRIES` | all | Retries of 5xx responses. Defaults to 0. |
| `BAO_SETUP_SKIP_PREFLIGHT` | all | Set to `1` to skip the status check below. |
| `BAO_SETUP_TOKEN_TTL`, `BAO_SETUP_TOKEN_MAX_TTL` | `setup` | Default AppRole token TTL and max TTL offered at the prompts. Default `10m` and `1h`. |
| `BAO_ROLE_ID`, `BAO_SECRET_ID` | `check-approle` | AppRole credentials. Prompted for when unset. |
| `BAO_LOGIN_TTL` | `check-approle` | Token TTL to request. Same as `--ttl`. |

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

## Tokens and TTLs

Every AppRole login creates a token that OpenBao stores and tracks until it expires. An
application that logs in per request, or per isolate, with a long `token_ttl` fills the server
with tokens: on one deployment about 28,000 logins a day, each with a one-year TTL, coincided
with steady daily memory growth in the server. So `setup` keeps token lifetimes short by
default: `token_ttl=10m` and `token_max_ttl=1h` (renewals included). Prefer:

- the short default, or a short TTL requested per login;
- one login reused for the lifetime of the token, not one per request;
- `auth/token/revoke-self` after a one-shot read, so the token does not outlive its use.

### Choosing longer lifetimes

An app that really needs longer-lived tokens must ask for them. `setup` offers the defaults at
two prompts, so type another value (`30m`, `2h`, `720h`, or plain seconds) to override them for
that app. For scripted runs set the defaults with `BAO_SETUP_TOKEN_TTL` and
`BAO_SETUP_TOKEN_MAX_TTL`. The TTL cannot exceed the max TTL, a value that is not seconds or a
duration such as `1h30m` is rejected before anything is written, and `0` leaves that lifetime
to the server's default.

### Shorten existing roles and tidy old tokens

Roles created by an earlier version of this script keep the lifetime they were given, which
defaulted to `8760h`. Check a role, then shorten it. The write changes only the fields you
give; the role's policies and secret IDs are kept:

```sh
bao read auth/approle/role/<role-name>        # shows token_ttl and token_max_ttl
bao write auth/approle/role/<role-name> token_ttl=10m token_max_ttl=1h
```

This affects only tokens issued by later logins. Tokens that already exist keep their original
expiry, so a role that logged in thousands of times with the old lifetime leaves that many
tokens behind. In order of preference:

1. **Let them expire.** Nothing to run, and no consumer is affected, but each old token keeps
   using memory and storage until its original expiry.
2. **Tidy.** `bao write -f auth/token/tidy` removes index and accessor entries that no longer
   belong to a valid token. It runs in the background, does not revoke tokens that are still
   valid, and scans the token store, so on a very large store run it at a quiet time.
3. **Revoke by prefix, only if you must.** `bao lease revoke -prefix auth/approle/login/`
   revokes every token the AppRole mount ever issued, for all roles. Any application still
   holding one gets `403` until it logs in again, and on a large store it generates a lot of
   storage writes, so run it at a quiet time with the server's health in view. Confirm the
   prefix first with `bao list sys/leases/lookup/auth/approle/`, which lists one level only.

Avoid listing token accessors on a large store: that call enumerates all of them.

`check-approle` shows the pattern and proves a role works without leaving a token behind:

```sh
BAO_ROLE_ID=... BAO_SECRET_ID=... \
  ./bao-setup-vault.sh check-approle --ttl 15m --read myapp/production/private
```

It logs in once with the role alone (the admin token is not sent), reads each `--read` path
with that same token without printing any value, and revokes the token with revoke-self. The
exit status is non-zero if the login, a read or the revoke fails. The secret ID is sent on
stdin, never as a command argument, and neither it nor the token is printed.

`--ttl` is sent as an optional `ttl` field of the login request. A server that does not
implement it ignores the field and answers with a warning, which the check reports; the role's
`token_ttl` then applies. The check prints the TTL the token actually received.

Roles created by `setup` have no default policy, so by default a token could neither look up
nor revoke itself. `setup` therefore adds two paths to every **private** policy:

```hcl
path "auth/token/lookup-self" { capabilities = ["read"] }
path "auth/token/revoke-self" { capabilities = ["update"] }
```

Public tokens are read-only and safe to expose, so they never get these paths: anyone holding
one could otherwise revoke it. Policies written by an earlier version of this script do not
have the two paths: add them with `bao policy read` and `bao policy write`. Do not re-run
`setup` for an app that already exists. Its folder-placeholder step writes `_created` and
`_type` to the same KV path the application reads, which replaces the current secret version
(KV v2 keeps the previous version, and `bao kv rollback` restores it).

## Tests

```sh
bash tests/test.sh
```

The tests run the script against a fake `bao` that records every call, so they need no server.
They cover the client defaults, the status check, the generated policies, and `check-approle`
(login payload, token reuse, revoke-self on success and on failure, and that no secret reaches
a process argument or the output).
