# coding-bot-wrapper

A thin wrapper that authenticates as a **GitHub App**, mints a short-lived,
repository-scoped **installation token**, and then runs your `gh` command with
that token in its environment.

It does *one* thing: negotiate the token and hand off to `gh`. It does not
clone, branch, commit, push, or open pull requests — you drive all of that
through normal `gh` (and `git`) commands.

```console
$ ./coding-bot-wrapper.sh gh pr comment 123 --body 'Automated review comment' -R my-org/my-repo
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

Install these and make sure they are on your `PATH`:

- `bash`
- `curl`
- `jq`
- `openssl`
- `gh` ([GitHub CLI](https://cli.github.com/))

On Fedora: `sudo dnf install bash curl jq openssl gh`

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
your environment, the wrapper reads `~/.coding-bot.env` (override the path with
`CODING_BOT_ENV`). It is sourced as a shell snippet, so keep it to simple
`KEY=value` lines:

```sh
# ~/.coding-bot.env
GITHUB_APP_ID=123456
GITHUB_PRIVATE_KEY_FILE=/home/opiske/my-app.private-key.pem
```

Lock it down — it points at your private key:

```console
$ chmod 600 ~/.coding-bot.env
```

**Option B — inline environment variables.** Explicitly set variables always
win over the env file:

```console
$ GITHUB_APP_ID=123456 \
  GITHUB_PRIVATE_KEY_FILE=~/my-app.private-key.pem \
  ./coding-bot-wrapper.sh gh pr list -R my-org/my-repo
```

## Usage

```
./coding-bot-wrapper.sh gh <args...>
```

Everything after the script name is passed to `gh` untouched. Before it runs,
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
$ ./coding-bot-wrapper.sh gh pr comment 123 --body 'Looks good to me' -R my-org/my-repo
```

List open PRs (repo via env var instead of `-R`):

```console
$ GH_REPO=my-org/my-repo ./coding-bot-wrapper.sh gh pr list
```

Create an issue:

```console
$ ./coding-bot-wrapper.sh gh issue create \
    --title 'Automated report' --body 'Details...' -R my-org/my-repo
```

## Optional configuration

| Variable             | Default                     | Purpose                                             |
| -------------------- | --------------------------- | --------------------------------------------------- |
| `CODING_BOT_ENV`     | `~/.coding-bot.env`         | Path to the env file                                |
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

- Keep the private key and `~/.coding-bot.env` at mode `600`.
- Never commit the `.pem` or the env file to a repository.
- The minted token is repo-scoped and expires within ~1 hour; you cannot grant
  it more than the App installation already has.

## Troubleshooting

| Message                                             | Likely cause / fix                                                        |
| --------------------------------------------------- | ------------------------------------------------------------------------- |
| `required command not found: <cmd>`                 | Install the missing dependency.                                           |
| `could not determine repository; pass -R ...`       | Add `-R owner/repo` to the `gh` command, or set `GH_REPO`.                |
| `Set GITHUB_APP_ID` / `Set GITHUB_PRIVATE_KEY_FILE` | Add them to `~/.coding-bot.env` or export them inline.                     |
| `private key not found: ...`                        | Fix `GITHUB_PRIVATE_KEY_FILE` to point at the real `.pem`.                |
| `could not determine installation ID`               | The App is not installed on that repo (see setup step 3).                 |
| `GitHub did not return an installation access token` | The App lacks a permission, or the key/App ID don't match. Check the App.|
