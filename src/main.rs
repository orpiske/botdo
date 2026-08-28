//! botdo
//!
//! Authenticate as a GitHub App, obtain a short-lived, repository-scoped
//! installation token, and run a `gh` command with that token.
//!
//! This is a thin wrapper: it only negotiates the token and then hands off to
//! `gh` (or any command you pass). It does not clone, branch, commit, or push.
//!
//! Required environment variables:
//!   GITHUB_APP_ID
//!   GITHUB_PRIVATE_KEY_FILE
//!
//! When GITHUB_APP_ID is not already set, configuration is loaded from an env
//! file (default: ~/.botdo.env, overridable via BOTDO_ENV).
//!
//! The target repository (used to scope the token) is read from the `-R`/`--repo`
//! flag in the gh command, falling back to GH_REPO / GITHUB_REPOSITORY.
//!
//! Usage:
//!   botdo gh <args...>

use std::env;
use std::fs;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

const DEFAULT_API_URL: &str = "https://api.github.com";
const DEFAULT_API_VERSION: &str = "2026-03-10";
const USER_AGENT: &str = "botdo";

#[derive(Serialize)]
struct Claims {
    iat: u64,
    exp: u64,
    iss: String,
}

#[derive(Deserialize)]
struct Installation {
    id: u64,
}

#[derive(Deserialize)]
struct AccessToken {
    token: String,
    expires_at: Option<String>,
}

fn main() {
    if let Err(e) = run() {
        eprintln!("error: {e}");
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let args: Vec<String> = env::args().skip(1).collect();
    if args.is_empty() {
        return Err("usage: botdo gh <args...>".into());
    }

    // Load credentials from the env file when GITHUB_APP_ID is not already set.
    load_env_file();

    // Resolve the repository the installation token should be scoped to.
    let repo = detect_repo(&args)
        .ok_or("could not determine repository; pass -R OWNER/REPO to gh or set GH_REPO")?;
    let (owner, repo_name) = repo
        .split_once('/')
        .ok_or_else(|| format!("repository must be in OWNER/REPO form (got: {repo})"))?;

    let app_id = env::var("GITHUB_APP_ID").map_err(|_| "Set GITHUB_APP_ID")?;
    let key_file = env::var("GITHUB_PRIVATE_KEY_FILE").map_err(|_| "Set GITHUB_PRIVATE_KEY_FILE")?;
    if !Path::new(&key_file).is_file() {
        return Err(format!("private key not found: {key_file}"));
    }

    let api_url = env::var("GITHUB_API_URL").unwrap_or_else(|_| DEFAULT_API_URL.to_string());
    let api_version =
        env::var("GITHUB_API_VERSION").unwrap_or_else(|_| DEFAULT_API_VERSION.to_string());

    let jwt = create_app_jwt(&app_id, &key_file)?;

    eprintln!("Finding GitHub App installation for {repo}...");
    let installation: Installation = github_request(
        "GET",
        &format!("{api_url}/repos/{owner}/{repo_name}/installation"),
        &jwt,
        &api_version,
        None,
    )?;

    // Scope the installation token to this repository only. It still cannot
    // exceed the permissions granted to the GitHub App installation.
    let access: AccessToken = github_request(
        "POST",
        &format!(
            "{api_url}/app/installations/{}/access_tokens",
            installation.id
        ),
        &jwt,
        &api_version,
        Some(serde_json::json!({ "repositories": [repo_name] })),
    )?;

    eprintln!(
        "Installation token acquired; expires at {}.",
        access.expires_at.as_deref().unwrap_or("unknown")
    );

    // Hand off to the requested command (typically `gh`) with the token in the
    // environment. GH_TOKEN authenticates gh; GH_REPO scopes it to the same repo.
    let err = Command::new(&args[0])
        .args(&args[1..])
        .env("GH_TOKEN", &access.token)
        .env("GH_REPO", &repo)
        .exec();

    // exec() only returns on failure.
    Err(format!("failed to run {}: {err}", args[0]))
}

/// Load `KEY=value` pairs from the env file, but only when GITHUB_APP_ID is not
/// already set in the environment. Existing environment variables always win.
fn load_env_file() {
    if env::var_os("GITHUB_APP_ID").is_some() {
        return;
    }

    let path = env::var("BOTDO_ENV").unwrap_or_else(|_| {
        let home = env::var("HOME").unwrap_or_default();
        format!("{home}/.botdo.env")
    });

    let Ok(contents) = fs::read_to_string(&path) else {
        return;
    };

    for line in contents.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let line = line.strip_prefix("export ").unwrap_or(line);
        if let Some((key, value)) = line.split_once('=') {
            let key = key.trim();
            let value = value.trim().trim_matches('"').trim_matches('\'');
            if !key.is_empty() && env::var_os(key).is_none() {
                env::set_var(key, value);
            }
        }
    }
}

/// Resolve the target repository from the `-R`/`--repo` flag in the gh command,
/// falling back to the GH_REPO / GITHUB_REPOSITORY environment variables.
fn detect_repo(args: &[String]) -> Option<String> {
    let mut iter = args.iter();
    while let Some(arg) = iter.next() {
        if arg == "-R" || arg == "--repo" {
            if let Some(value) = iter.next() {
                return Some(value.clone());
            }
        } else if let Some(value) = arg.strip_prefix("--repo=") {
            return Some(value.to_string());
        } else if let Some(value) = arg.strip_prefix("-R") {
            if !value.is_empty() {
                return Some(value.to_string());
            }
        }
    }

    for var in ["GH_REPO", "GITHUB_REPOSITORY"] {
        if let Ok(value) = env::var(var) {
            if !value.is_empty() {
                return Some(value);
            }
        }
    }

    None
}

/// Build a short-lived RS256 JWT signed with the GitHub App private key.
fn create_app_jwt(app_id: &str, key_file: &str) -> Result<String, String> {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|e| format!("system clock error: {e}"))?
        .as_secs();

    let claims = Claims {
        // Backdate slightly to avoid clock-skew problems.
        iat: now - 60,
        // Stay below the documented 10-minute maximum.
        exp: now + 540,
        iss: app_id.to_string(),
    };

    let pem = fs::read(key_file).map_err(|e| format!("cannot read private key: {e}"))?;
    let key = jsonwebtoken::EncodingKey::from_rsa_pem(&pem)
        .map_err(|e| format!("invalid RSA private key: {e}"))?;
    let header = jsonwebtoken::Header::new(jsonwebtoken::Algorithm::RS256);

    jsonwebtoken::encode(&header, &claims, &key).map_err(|e| format!("failed to sign JWT: {e}"))
}

/// Perform an authenticated GitHub API request and deserialize the response.
fn github_request<T: for<'de> Deserialize<'de>>(
    method: &str,
    url: &str,
    jwt: &str,
    api_version: &str,
    body: Option<serde_json::Value>,
) -> Result<T, String> {
    let request = ureq::request(method, url)
        .set("Accept", "application/vnd.github+json")
        .set("X-GitHub-Api-Version", api_version)
        .set("Authorization", &format!("Bearer {jwt}"))
        .set("User-Agent", USER_AGENT);

    let response = match body {
        Some(json) => request.send_json(json),
        None => request.call(),
    };

    match response {
        Ok(resp) => resp
            .into_json::<T>()
            .map_err(|e| format!("failed to parse GitHub response: {e}")),
        Err(ureq::Error::Status(code, resp)) => {
            let detail = resp.into_string().unwrap_or_default();
            Err(format!("GitHub API returned HTTP {code}: {detail}"))
        }
        Err(e) => Err(format!("request to GitHub failed: {e}")),
    }
}
