use std::collections::HashSet;
use std::env;
use std::fs;
use std::path::Path;
use std::path::PathBuf;
use std::process::Command;

/// 构造可直接启动 Codex CLI 的命令。
///
/// 重点处理 GUI 进程 PATH 不完整的问题：
/// 先定位真实可执行路径，再把其父目录注入子进程 PATH。
pub(crate) fn new_codex_command() -> Result<Command, String> {
    let codex_path = find_codex_cli_path().ok_or_else(|| {
        "未找到 codex 可执行文件。请先安装 Codex CLI，或将其所在目录加入系统 PATH。".to_string()
    })?;

    let mut cmd = Command::new(&codex_path);

    if let Some(parent) = codex_path.parent() {
        let path_entries = if let Some(current_path) = env::var_os("PATH") {
            std::iter::once(parent.to_path_buf())
                .chain(env::split_paths(&current_path))
                .collect::<Vec<_>>()
        } else {
            vec![parent.to_path_buf()]
        };
        let merged = env::join_paths(path_entries).map_err(|e| format!("设置 PATH 失败: {e}"))?;
        cmd.env("PATH", merged);
    }

    Ok(cmd)
}

pub(crate) fn find_codex_app_path() -> Option<PathBuf> {
    let mut candidates = vec![
        PathBuf::from("/Applications/Codex.app"),
        PathBuf::from("/Applications/Codex Desktop.app"),
    ];

    if let Some(home) = dirs::home_dir() {
        candidates.push(home.join("Applications").join("Codex.app"));
        candidates.push(home.join("Applications").join("Codex Desktop.app"));
    }

    if let Some(found) = candidates.into_iter().find(|path| path.exists()) {
        return Some(found);
    }

    let spotlight_queries = [
        "kMDItemFSName == 'Codex.app'",
        "kMDItemCFBundleIdentifier == 'com.openai.codex'",
    ];

    for query in spotlight_queries {
        if let Some(path) = first_spotlight_match(query) {
            return Some(path);
        }
    }

    None
}

fn find_codex_cli_path() -> Option<PathBuf> {
    let mut candidates = codex_cli_candidates();
    append_nvm_codex_candidates(&mut candidates);
    append_macos_app_bundle_codex_candidates(&mut candidates);

    let mut seen = HashSet::new();
    for candidate in candidates {
        if !seen.insert(candidate.clone()) {
            continue;
        }
        if is_executable_file(&candidate) {
            return Some(candidate);
        }
    }

    None
}

fn codex_cli_candidates() -> Vec<PathBuf> {
    let mut candidates = Vec::new();

    if let Some(path_os) = env::var_os("PATH") {
        for dir in env::split_paths(&path_os) {
            push_codex_candidates_from_dir(&mut candidates, &dir);
        }
    }

    #[cfg(target_os = "macos")]
    {
        for dir in [
            PathBuf::from("/opt/homebrew/bin"),
            PathBuf::from("/usr/local/bin"),
            PathBuf::from("/usr/bin"),
        ] {
            push_codex_candidates_from_dir(&mut candidates, &dir);
        }
    }

    if let Some(home) = dirs::home_dir() {
        for dir in [
            home.join(".local").join("bin"),
            home.join(".npm-global").join("bin"),
            home.join(".volta").join("bin"),
            home.join(".asdf").join("shims"),
            home.join(".pnpm"),
            home.join("Library").join("pnpm"),
            home.join("bin"),
        ] {
            push_codex_candidates_from_dir(&mut candidates, &dir);
        }
    }

    candidates
}

fn append_nvm_codex_candidates(candidates: &mut Vec<PathBuf>) {
    let Some(home) = dirs::home_dir() else {
        return;
    };
    let nvm_versions_dir = home.join(".nvm").join("versions").join("node");
    let Ok(entries) = fs::read_dir(&nvm_versions_dir) else {
        return;
    };

    let mut version_dirs = entries
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| path.is_dir())
        .collect::<Vec<_>>();
    version_dirs.sort();
    version_dirs.reverse();

    for version_dir in version_dirs {
        push_codex_candidates_from_dir(candidates, &version_dir.join("bin"));
    }
}

#[cfg(target_os = "macos")]
fn append_macos_app_bundle_codex_candidates(candidates: &mut Vec<PathBuf>) {
    let mut app_paths = vec![
        PathBuf::from("/Applications/Codex.app"),
        PathBuf::from("/Applications/Codex Desktop.app"),
    ];

    if let Some(home) = dirs::home_dir() {
        app_paths.push(home.join("Applications").join("Codex.app"));
        app_paths.push(home.join("Applications").join("Codex Desktop.app"));
    }

    if let Some(found) = find_codex_app_path() {
        app_paths.push(found);
    }

    for app_path in app_paths {
        candidates.push(app_path.join("Contents").join("Resources").join("codex"));
    }
}

#[cfg(not(target_os = "macos"))]
fn append_macos_app_bundle_codex_candidates(_candidates: &mut Vec<PathBuf>) {}

fn push_codex_candidates_from_dir(candidates: &mut Vec<PathBuf>, dir: &Path) {
    #[cfg(windows)]
    let names = ["codex.exe", "codex.cmd", "codex.bat"];
    #[cfg(not(windows))]
    let names = ["codex"];

    for name in names {
        candidates.push(dir.join(name));
    }
}

fn is_executable_file(path: &Path) -> bool {
    let Ok(metadata) = fs::metadata(path) else {
        return false;
    };
    if !metadata.is_file() {
        return false;
    }

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        metadata.permissions().mode() & 0o111 != 0
    }
    #[cfg(not(unix))]
    {
        true
    }
}

fn first_spotlight_match(query: &str) -> Option<PathBuf> {
    let output = Command::new("mdfind").arg(query).output().ok()?;
    if !output.status.success() {
        return None;
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    stdout
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(PathBuf::from)
        .find(|path| path.exists())
}
