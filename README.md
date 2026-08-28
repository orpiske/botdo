# botdo

A thin wrapper that authenticates as a **GitHub App**, mints a short-lived,
repository-scoped **installation token**, and then runs your `gh` command with
that token in its environment.

It does *one* thing: negotiate the token and hand off to `gh`. It does not
clone, branch, commit, push, or open pull requests — you drive all of that
through normal `gh` (and `git`) commands.

It is written in Rust and ships as a single self-contained binary.

```console
$ botdo gh pr comment 123 --body 'Automated review comment' -R my-org/my-repo
Finding GitHub App installation for my-org/my-repo...
Installation token acquired; expires at 2026-08-28T12:34:56Z.
https://github.com/my-org/my-repo/issues/123#issuecomment-...
```

## Why use it?

Acting as a GitHub App (instead of a personal access token) means:

- Actions are attributed to the **bot**, not a human account.
- Tokens are **short-lived** (~1 hour) and **scoped to a single repository**,
  so a leak has limited blast radius.
- Permissions are exactly those granted to the App installation — nothing more.

## Requirements

- **To build:** a Rust toolchain (`cargo`, `rustc` — install via [rustup](https://rustup.rs/))
  and `make`.
- **At runtime:** only [`gh`](https://cli.github.com/), the GitHub CLI, needs to
  be on your `PATH`. All HTTP and crypto is handled inside the binary — no
  `curl`, `jq`, or `openssl` required.

On Fedora: `sudo dnf install cargo make gh`

## Installing

Build and install with `make`. The default install directory is
`/usr/local/bin`, which usually needs elevated privileges:

```console
$ sudo make install
```

Install somewhere that does not require `sudo` by overriding `PREFIX` or
`BINDIR`:

```console
$ make install PREFIX="$HOME/.local"   # installs to ~/.local/bin
$ make install BINDIR="$HOME/bin"      # installs to a specific directory
```

Other targets:

```console
$ make            # build the release binary only
$ make uninstall  # remove the installed binary (respects PREFIX/BINDIR)
$ make clean      # cargo clean
```

### Building manually

```console
$ cargo build --release
```

The binary is produced at `target/release/botdo`. Copy it onto your `PATH`
yourself, e.g.:

```console
$ install -m 755 target/release/botdo ~/.local/bin/
```

The examples below assume `botdo` is on your `PATH`. If it is not, run it by its
full path (e.g. `./target/release/botdo ...`).

## Setup

### 1. Create a GitHub App

1. Go to **Settings → Developer settings → GitHub Apps → New GitHub App**
   (for an org: `https://github.com/organizations/<ORG>/settings/apps`).
2. Give it a name and a homepage URL (any valid URL works).
3. Uncheck **Webhook → Active** (this wrapper does not use webhooks).
4. Grant the **Repository permissions** the bot needs. Common ones:
   - **Pull requests:** Read & write (comment on / create / edit PRs)
   - **Contents:** Read & write (push branches, read files)
   - **Issues:** Read & write (comment on / manage issues)
   - **Metadata:** Read-only (required, granted automatically)

   Grant only what you actually need.
5. Click **Create GitHub App**.
6. Note the **App ID** shown on the App's page.

### 2. Generate a private key

On the App's page, scroll to **Private keys → Generate a private key**. This
downloads a `.pem` file. Store it somewhere safe and lock it down:

```console
$ mv ~/Downloads/my-app.*.private-key.pem ~/my-app.private-key.pem
$ chmod 600 ~/my-app.private-key.pem
```

### 3. Install the App on your repositories

On the App's page, go to **Install App**, pick the account/org, and choose the
repositories the bot may act on. The token this wrapper mints can only touch
repositories where the App is installed.

### 4. Configure credentials

The wrapper needs two values:

| Variable                  | Meaning                              |
| ------------------------- | ------------------------------------ |
| `GITHUB_APP_ID`           | The App ID from step 1               |
| `GITHUB_PRIVATE_KEY_FILE` | Path to the `.pem` file from step 2  |

You can provide these two ways.

**Option A — env file (recommended).** If `GITHUB_APP_ID` is not already set in
your environment, the wrapper reads `~/.botdo.env` (override the path with
`BOTDO_ENV`). It is parsed as simple `KEY=value` lines — blank lines and
`#` comments are ignored, an optional leading `export ` is accepted, and
surrounding quotes are stripped. Values already present in the environment are
never overwritten.

```sh
# ~/.botdo.env
GITHUB_APP_ID=123456
GITHUB_PRIVATE_KEY_FILE=/home/opiske/my-app.private-key.pem
```

Lock it down — it points at your private key:

```console
$ chmod 600 ~/.botdo.env
```

**Option B — inline environment variables.** Explicitly set variables always
win over the env file:

```console
$ GITHUB_APP_ID=123456 \
  GITHUB_PRIVATE_KEY_FILE=~/my-app.private-key.pem \
  botdo gh pr list -R my-org/my-repo
```

## Usage

```
botdo gh <args...>
```

Everything after the binary name is passed to `gh` untouched. Before it runs,
the wrapper exports:

- `GH_TOKEN` — the installation token that authenticates `gh`
- `GH_REPO` — the resolved `OWNER/REPO`

### How the target repository is resolved

The wrapper must know which repository to scope the token to. It looks, in
order:

1. The `-R` / `--repo` flag in your `gh` command
   (`-R owner/repo`, `-Rowner/repo`, `--repo owner/repo`, `--repo=owner/repo`).
2. The `GH_REPO` environment variable.
3. The `GITHUB_REPOSITORY` environment variable.

If none of these is present, the wrapper exits with an error. Passing `-R` is
the recommended, explicit approach.

### Examples

Comment on a PR:

```console
$ botdo gh pr comment 123 --body 'Looks good to me' -R my-org/my-repo
```

List open PRs (repo via env var instead of `-R`):

```console
$ GH_REPO=my-org/my-repo botdo gh pr list
```

Create an issue:

```console
$ botdo gh issue create \
    --title 'Automated report' --body 'Details...' -R my-org/my-repo
```

## Optional configuration

| Variable             | Default                     | Purpose                                             |
| -------------------- | --------------------------- | --------------------------------------------------- |
| `BOTDO_ENV`          | `~/.botdo.env`              | Path to the env file                                |
| `GH_REPO`            | *(none)*                    | Target repo when `-R`/`--repo` is not passed        |
| `GITHUB_REPOSITORY`  | *(none)*                    | Same, checked after `GH_REPO`                        |
| `GITHUB_API_URL`     | `https://api.github.com`    | API base URL (set for GitHub Enterprise Server)     |
| `GITHUB_API_VERSION` | `2026-03-10`                | `X-GitHub-Api-Version` header sent to the API       |

## How it works

1. Builds a short-lived (9 min) RS256 JWT signed with your App private key.
2. Looks up the App's installation on the target repo
   (`GET /repos/{owner}/{repo}/installation`).
3. Requests an installation access token scoped to that single repository
   (`POST /app/installations/{id}/access_tokens`).
4. Exports `GH_TOKEN` / `GH_REPO` and `exec`s your `gh` command.

The token lives only in the wrapper's environment and is inherited by `gh`; it
is never written to disk. Status messages go to **stderr**, so `gh`'s stdout
stays clean for piping.

## Security notes

- Keep the private key and `~/.botdo.env` at mode `600`.
- Never commit the `.pem` or the env file to a repository.
- The minted token is repo-scoped and expires within ~1 hour; you cannot grant
  it more than the App installation already has.

## Troubleshooting

| Message                                             | Likely cause / fix                                                          |
| --------------------------------------------------- | -------------------------------------------------------------------------- |
| `could not determine repository; pass -R ...`       | Add `-R owner/repo` to the `gh` command, or set `GH_REPO`.                  |
| `Set GITHUB_APP_ID` / `Set GITHUB_PRIVATE_KEY_FILE` | Add them to `~/.botdo.env` or export them inline.                      |
| `private key not found: ...`                        | Fix `GITHUB_PRIVATE_KEY_FILE` to point at the real `.pem`.                  |
| `invalid RSA private key: ...`                      | The file is not a valid RSA PEM key; re-download it from the App page.      |
| `GitHub API returned HTTP 404: ...`                 | The App is not installed on that repo (see setup step 3).                   |
| `GitHub API returned HTTP 401: ...`                 | The key/App ID don't match, or the JWT is invalid. Check both values.      |
| `failed to run gh: ...`                             | `gh` is not installed or not on your `PATH`.                                |
