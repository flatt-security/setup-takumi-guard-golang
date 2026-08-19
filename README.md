<p align="center">
  <img src="branding.png" alt="Takumi Guard — a panda security guard scanning Go modules" width="300" />
</p>

<h1 align="center">Takumi Guard for Go</h1>

<p align="center">
  <strong>Stop malicious Go modules before they reach your CI.</strong><br />
  A GitHub Action that routes <code>go mod download</code> through a security proxy — no secrets, no config files, two lines of YAML.
</p>

<p align="center">
  <a href="https://github.com/flatt-security/setup-takumi-guard-golang/actions/workflows/test.yml"><img src="https://github.com/flatt-security/setup-takumi-guard-golang/actions/workflows/test.yml/badge.svg" alt="CI" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/flatt-security/setup-takumi-guard-golang" alt="License" /></a>
</p>

---

> **Not using CI?** For local setup on your laptop, see the [email registration & token management appendix](#appendix-email-registration--token-management) below.

## Contents

- [What is Takumi Guard?](#what-is-takumi-guard)
- [Quickstart (3 steps)](#quickstart)
- [Setup modes](#setup-modes)
- [Adopting Takumi Guard](#adopting-takumi-guard)
- [Inputs](#inputs)
- [Outputs](#outputs)
- [Troubleshooting](#troubleshooting)
- [Security](#security)
- [Appendix: Email registration & token management](#appendix-email-registration--token-management)

---

## What is Takumi Guard?

Every `go mod download` in your CI is a trust decision. Takumi Guard sits between your workflow and `proxy.golang.org`, **blocking known-malicious modules before they execute**.

- **How it works** -- Routes module metadata through a security proxy (`golang.flatt.tech`) that checks modules against a threat database in real time. Module `.zip` artifacts are 302-redirected to upstream, so bytes never traverse our infrastructure.
- **What you change** -- One step in your workflow YAML. No `go.mod` edits, no secrets to manage.
- **What it supports** -- The standard `go` toolchain (Go 1.21+). Speaks the [GOPROXY protocol](https://go.dev/ref/mod#goproxy-protocol).

---

## Quickstart

**Goal:** Add Takumi Guard to any GitHub Actions workflow. No account required.

**Step 1.** Add the action to your workflow file (e.g. `.github/workflows/ci.yml`):

```yaml
steps:
  - uses: actions/checkout@v4
  - uses: actions/setup-go@v5
    with:
      go-version: '1.22'

  - uses: flatt-security/setup-takumi-guard-golang@v1   # <-- add this line

  - run: go mod download
  - run: go test ./...
```

> **Ordering:** Put this action *before* `go mod download` or anything that triggers it (`go build`, `go test`). It only needs to set the `GOPROXY` env var and (optionally) write `~/.netrc` — both before any module fetch happens.

**Step 2.** Push the change. Every module fetch in this job now runs through the Takumi Guard proxy. Malicious modules are blocked automatically.

**Step 3.** *(Optional)* **Want audit logging and a dashboard?** Add a Bot ID for full visibility into module activity:

```yaml
jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      id-token: write   # Required for authentication
      contents: read
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with:
          go-version: '1.22'

      - uses: flatt-security/setup-takumi-guard-golang@v1
        with:
          bot-id: "YOUR_BOT_ID"

      - run: go mod download
```

> **Where do I get a Bot ID?** Create one at [Shisho Cloud byGMO](https://cloud.shisho.dev) -- or skip this entirely. Blocking works without it. The Bot ID is a public reference key, not a secret.

---

## Setup modes

| Mode | Blocks malware | Audit logging | Account needed | Best for |
|---|:---:|:---:|:---:|---|
| **[Blocking only](#blocking-only)** | Yes | No | No | OSS projects, quick evaluation |
| **[Full protection](#full-protection)** | Yes | Yes | Yes | Production workloads |
| **[Auth-only](#auth-only-advanced)** | You manage | Yes | Yes | Custom GOPROXY setups |

---

### Blocking only

> **No account needed.** Add one line and you are protected.

Blocks known-malicious modules. No signup, no authentication.

```yaml
- uses: flatt-security/setup-takumi-guard-golang@v1
```

Good for open-source projects or quick evaluation.

---

### Full protection

> **Recommended for production.** Blocks threats _and_ logs all module activity to your dashboard.

```yaml
permissions:
  id-token: write

steps:
  - uses: flatt-security/setup-takumi-guard-golang@v1
    with:
      bot-id: "YOUR_BOT_ID"
```

**Key details:**
- Auth is handled via **GitHub's built-in OIDC** -- no PATs or secrets to rotate.
- The action does a one-shot OIDC → STS exchange at job start, writes the resulting short-lived JWT to `~/.netrc`, and the `go` toolchain Basic-auths every request to the proxy.
- If authentication fails (invalid `bot-id`, missing OIDC permission, STS unreachable, transient upstream error), the action exits with a clear error message and the build fails. There is no silent fallback to blocking-only mode.
- Get a Bot ID from [Shisho Cloud byGMO](https://cloud.shisho.dev).

---

### Auth-only (advanced)

> **For custom setups.** You manage the `GOPROXY` environment variable yourself. The action only handles authentication (writing `~/.netrc`).

```yaml
- uses: flatt-security/setup-takumi-guard-golang@v1
  with:
    bot-id: "YOUR_BOT_ID"
    set-goproxy: false
```

**Key details:**
- Useful for projects that need full control over `GOPROXY` (e.g. multi-proxy chains, environment-aware logic).
- You must set `GOPROXY=https://golang.flatt.tech` for the proxy to be reached. Do **not** append `,direct` or `|direct` — a `direct` fallback resolves modules straight from VCS on any 404/410 from us, which lets malicious modules not carried by `proxy.golang.org` bypass the blocklist.
- If authentication fails, **the action exits with an error** -- there is no fallback.

---

## Adopting Takumi Guard

Go does not embed the registry URL into `go.mod` or `go.sum`. Most projects can adopt Takumi Guard with no file changes.

**For the `go` toolchain:** The action sets `GOPROXY=https://golang.flatt.tech`. Every module fetch routes through the proxy; `go.mod`, `go.sum`, and `vendor/` are unchanged.

**For projects with private modules:** Set [`GOPRIVATE`](https://go.dev/ref/mod#environment-variables) to a glob matching your private hosts (e.g. `GOPRIVATE=github.com/myorg/*`). Modules matching `GOPRIVATE` bypass the proxy entirely and resolve directly via VCS — which is what you want for private code. The action does not modify `GOPRIVATE`; configure it yourself.

**For projects with vendored dependencies:** Nothing to do. `go build -mod=vendor` reads from `vendor/` and never hits the network.

> **No `direct` fallback.** `GOPROXY` is set with no `direct` fallback. The `go` client treats `404`/`410` from a chain entry as "try the next one", which for `direct` resolves the module straight from VCS — letting a malicious module not carried by `proxy.golang.org` bypass the blocklist. Private modules belong in `GOPRIVATE`, not in a `direct` fallback.

---

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `bot-id` | No | -- | Bot ID from Shisho Cloud byGMO. Omit for blocking-only mode. |
| `set-goproxy` | No | `true` | Set `GOPROXY=<registry-url>` for the job. Set to `false` if you manage `GOPROXY` yourself. |
| `registry-url` | No | `https://golang.flatt.tech` | Registry endpoint (must speak the GOPROXY protocol). |
| `sts-url` | No | `https://sts.cloud.shisho.dev` | STS endpoint for token exchange. |
| `expires-in` | No | `1800` | Token lifetime in seconds (max 86400). |
| `audience` | No | `https://sts.cloud.shisho.dev` (the STS URL) | Audience for the OIDC token request. Override when your Bot trust condition expects a different value. |

---

## Outputs

| Output | Description |
|---|---|
| `token-expires-at` | ISO 8601 timestamp of token expiration. Only set when authenticated. |

---

## Troubleshooting

| Error | Cause | Fix |
|---|---|---|
| `OIDC not available` | Missing permission on the job | Add `permissions: { id-token: write }` to your job |
| `STS returned non-JSON (HTTP N)` | An error response from STS or an upstream layer was not valid JSON (e.g. an HTML error page from a transient outage) | Usually a transient infrastructure issue. The HTTP status and a body snippet are echoed to the log to help diagnose. |
| `STS returned HTTP N without an access_token` | STS rejected the auth request | The job log includes STS's own message inside this error. Common cases: `invalid ID token` -- trust condition mismatch, check the bot's trust settings in Shisho Cloud byGMO (if the trust condition sets an audience, it must equal the value the action sends -- by default the STS URL, overridable via the `audience` input); `invalid request` -- malformed bot-id, double-check the value from your console. |
| `GitHub OIDC token fetch failed` | Could not reach `token.actions.githubusercontent.com` or got a non-200 response | Usually transient; the action retries up to 5 times (see *Network retries* below). Persistent failures point at a GitHub Actions issue. |
| `go: module ...: 403 Forbidden` | Module or version is blocked by the proxy | Expected — this is the proxy doing its job. Check the dashboard for the block reason. |
| `go: module ...: reading ...: dial tcp: lookup ...` after enabling | `GOPRIVATE` mismatch — proxy is being asked for a private module | Add the host to `GOPRIVATE` (e.g. `GOPRIVATE=github.com/myorg/*`) |
| Build silently uses unblocked module | `GOPROXY` includes a `direct` fallback (`|direct` or `,direct`) — either lets blocked or unindexed modules resolve straight from VCS | Set `GOPROXY=https://golang.flatt.tech` with no fallback. Use `GOPRIVATE` for any private modules. |
| `go: module ...: 404 Not Found` | Module isn't carried by `proxy.golang.org`; the proxy has nothing to serve | If the module is private, add it to `GOPRIVATE` (e.g. `GOPRIVATE=github.com/myorg/*`). If it should be public, file an issue. |

> **Still stuck?** Open an issue on this repository with your error output and workflow file (redact any IDs).

### Network retries

Both network calls the action makes -- the GitHub OIDC token fetch and the Shisho Cloud STS exchange -- are retried up to 5 times, so a transient network condition on the runner does not fail your build.

Each attempt is a fresh request, so DNS is resolved again every time rather than reusing whatever the first attempt happened to resolve. That makes every retry an independent attempt: for a multi-homed endpoint, a later attempt can take a different path.

Backoff is 2, 4, 8 and 16 seconds plus up to 3 seconds of jitter, so concurrent jobs do not retry in lockstep. Retries cover network failures, HTTP 408, 429 and 5xx; any other 4xx fails immediately, because a rejected request will be rejected again.

Each retried attempt logs a warning, so a job that retried and then succeeded still shows what happened:

```
::warning::attempt 1/5 failed (curl exit 28, HTTP 000); retrying in 3s
```

**This means a hard failure is not immediate.** A call that cannot connect at all takes about 80-92 seconds to give up, and one that hangs until the per-attempt timeout takes up to about 167 seconds. In the worst case -- both calls hanging -- the step runs for roughly 5 minutes before failing. That is deliberate: a transient condition almost always clears well inside that window, and a job that waits and succeeds beats one that fails fast and has to be re-run by hand.

---

## Security

- **Short-lived tokens** -- 30 minutes by default, 24 hours max.
- **Auto-masked** -- Access tokens are automatically masked in workflow logs.
- **Job-scoped `.netrc`** -- The action writes to `$HOME/.netrc` on the ephemeral runner with `chmod 600`. Existing entries for *other* hosts are preserved; any prior entry for `golang.flatt.tech` is replaced (not appended) so duplicate credentials cannot accumulate.
- **No artifact egress through us** -- Module `.zip` files are served via 302 redirect to `proxy.golang.org`. Module bytes never traverse our infrastructure, so sumdb verification against `sum.golang.org` continues to work unchanged.
- **Basic auth over HTTPS** -- The `go` toolchain sends `Authorization: Basic <base64(_:JWT)>` to `golang.flatt.tech`. The JWT is never written to any file tracked by git.

---

## Appendix: Email registration & token management

> **Optional.** Register your email to receive breach notifications if a module you installed is later flagged as malicious. This works for local development -- CI workflows should use [Full protection](#full-protection) instead.

### Register

```bash
curl -X POST https://golang.flatt.tech/api/v1/tokens \
  -H "Content-Type: application/json" \
  -d '{"email": "you@example.com"}'
```

Check your inbox and click the verification link. You will receive a token like `tg_anon_xxx...`.

**Language preference:** Add `"language": "ja"` to receive emails in Japanese. Defaults to English (`"en"`) if omitted.

```bash
curl -X POST https://golang.flatt.tech/api/v1/tokens \
  -H "Content-Type: application/json" \
  -d '{"email": "you@example.com", "language": "ja"}'
```

> **Reusing an existing token:** If you have already registered with Takumi Guard for npm, PyPI, or RubyGems, the same `tg_anon_*` token works here -- it is a universal key across all ecosystems.

### Configure the `go` toolchain

Set `GOPROXY` and attach your token via `~/.netrc`:

```bash
# 1. Route module fetches through Takumi Guard.
export GOPROXY=https://golang.flatt.tech

# 2. Attach your token (the go toolchain reads $HOME/.netrc for HTTP Basic).
cat >> ~/.netrc <<EOF
machine golang.flatt.tech login _ password tg_anon_xxx...
EOF
chmod 600 ~/.netrc
```

To make `GOPROXY` permanent, either add the `export` line to your shell profile or use `go env -w`:

```bash
go env -w GOPROXY=https://golang.flatt.tech
```

After this, every `go mod download` (and transitively `go build`, `go test`, `go get`) routes through Takumi Guard with your identity attached. If a module you downloaded is later found to be malicious, you will receive a breach notification email.

> **Private modules:** If your project depends on private code (e.g. `github.com/myorg/internal`), keep them out of the proxy with `go env -w GOPRIVATE=github.com/myorg/*`.

### Check token status

```bash
curl -H "Authorization: Bearer tg_anon_xxx..." \
  https://golang.flatt.tech/api/v1/tokens/status
```

### Rotate your key

```bash
curl -X POST -H "Authorization: Bearer tg_anon_xxx..." \
  https://golang.flatt.tech/api/v1/tokens/regenerate
```

Returns a new API key. The old one is invalidated immediately. Update your `~/.netrc` with the new key.

### Revoke a token

```bash
curl -X DELETE -H "Authorization: Bearer tg_anon_xxx..." \
  https://golang.flatt.tech/api/v1/tokens
```

---

<p align="center">
  Built by <a href="https://flatt.tech">GMO Flatt Security Inc.</a><br />
  <a href="LICENSE">MIT License</a>
</p>
