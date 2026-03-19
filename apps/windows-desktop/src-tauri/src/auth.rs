use base64::engine::general_purpose::URL_SAFE;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use serde_json::Map;
use serde_json::Value;
use std::fs;
use std::path::PathBuf;
use std::time::UNIX_EPOCH;

use crate::models::CurrentAuthStatus;
use crate::models::ExtractedAuth;
use crate::utils::set_private_permissions;
use crate::utils::truncate_for_error;

pub(crate) struct CodexOAuthTokens {
    pub(crate) access_token: String,
    pub(crate) refresh_token: String,
    pub(crate) account_id: Option<String>,
    pub(crate) expires_at_ms: Option<i64>,
}

pub(crate) fn read_current_codex_auth() -> Result<Value, String> {
    let path = codex_auth_path()?;
    let raw = fs::read_to_string(&path)
        .map_err(|e| format!("读取当前 Codex 认证文件失败 {}: {e}", path.display()))?;
    serde_json::from_str(&raw).map_err(|e| format!("当前 Codex 认证文件不是合法 JSON: {e}"))
}

pub(crate) fn read_current_codex_auth_optional() -> Result<Option<Value>, String> {
    let path = codex_auth_path()?;
    if !path.exists() {
        return Ok(None);
    }

    let raw = fs::read_to_string(&path)
        .map_err(|e| format!("读取当前 Codex 认证文件失败 {}: {e}", path.display()))?;
    let value =
        serde_json::from_str(&raw).map_err(|e| format!("当前 Codex 认证文件不是合法 JSON: {e}"))?;
    Ok(Some(value))
}

pub(crate) fn read_current_auth_status() -> Result<CurrentAuthStatus, String> {
    let path = codex_auth_path()?;
    if !path.exists() {
        return Ok(CurrentAuthStatus {
            available: false,
            account_id: None,
            email: None,
            plan_type: None,
            auth_mode: None,
            last_refresh: None,
            file_modified_at: None,
            fingerprint: None,
        });
    }

    let metadata = fs::metadata(&path)
        .map_err(|e| format!("读取 auth.json 文件信息失败 {}: {e}", path.display()))?;
    let modified_at = metadata
        .modified()
        .ok()
        .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
        .map(|duration| duration.as_secs() as i64);

    let raw = fs::read_to_string(&path)
        .map_err(|e| format!("读取 auth.json 失败 {}: {e}", path.display()))?;
    let value: Value =
        serde_json::from_str(&raw).map_err(|e| format!("auth.json 不是合法 JSON: {e}"))?;

    let auth_mode = value
        .get("auth_mode")
        .and_then(Value::as_str)
        .map(ToString::to_string);
    let last_refresh = value
        .get("last_refresh")
        .and_then(Value::as_str)
        .map(ToString::to_string);

    let extracted = extract_auth(&value).ok();
    let principal_id = extracted.as_ref().map(|auth| auth.principal_id.clone());
    let account_id = extracted.as_ref().map(|auth| auth.account_id.clone());
    let email = extracted.as_ref().and_then(|auth| auth.email.clone());
    let plan_type = extracted.as_ref().and_then(|auth| auth.plan_type.clone());

    let fingerprint = Some(format!(
        "{}|{}|{}|{}|{}",
        principal_id.unwrap_or_default(),
        account_id.clone().unwrap_or_default(),
        last_refresh.clone().unwrap_or_default(),
        modified_at.unwrap_or_default(),
        auth_mode.clone().unwrap_or_default()
    ));

    Ok(CurrentAuthStatus {
        available: true,
        account_id,
        email,
        plan_type,
        auth_mode,
        last_refresh,
        file_modified_at: modified_at,
        fingerprint,
    })
}

pub(crate) fn write_active_codex_auth(auth_json: &Value) -> Result<(), String> {
    let path = codex_auth_path()?;
    let parent = path
        .parent()
        .ok_or_else(|| format!("无法解析 auth 目录 {}", path.display()))?;
    fs::create_dir_all(parent)
        .map_err(|e| format!("创建 auth 目录失败 {}: {e}", parent.display()))?;

    let serialized = serde_json::to_string_pretty(auth_json)
        .map_err(|e| format!("序列化 auth.json 失败: {e}"))?;
    fs::write(&path, serialized)
        .map_err(|e| format!("写入 auth.json 失败 {}: {e}", path.display()))?;
    set_private_permissions(&path);
    Ok(())
}

pub(crate) fn remove_active_codex_auth() -> Result<(), String> {
    let path = codex_auth_path()?;
    if !path.exists() {
        return Ok(());
    }
    fs::remove_file(&path).map_err(|e| format!("删除 auth.json 失败 {}: {e}", path.display()))
}

pub(crate) fn normalize_imported_auth_json(auth_json: Value) -> Value {
    let Some(root) = auth_json.as_object() else {
        return auth_json;
    };

    if root.get("tokens").and_then(Value::as_object).is_some() {
        return auth_json;
    }

    let Some(access_token) = root.get("access_token").and_then(Value::as_str) else {
        return auth_json;
    };
    let Some(id_token) = root.get("id_token").and_then(Value::as_str) else {
        return auth_json;
    };

    let mut tokens = Map::new();
    tokens.insert(
        "access_token".to_string(),
        Value::String(access_token.to_string()),
    );
    tokens.insert("id_token".to_string(), Value::String(id_token.to_string()));

    if let Some(refresh_token) = root.get("refresh_token").and_then(Value::as_str) {
        tokens.insert(
            "refresh_token".to_string(),
            Value::String(refresh_token.to_string()),
        );
    }
    if let Some(account_id) = root.get("account_id").and_then(Value::as_str) {
        tokens.insert(
            "account_id".to_string(),
            Value::String(account_id.to_string()),
        );
    }

    let mut normalized = Map::new();
    normalized.insert(
        "auth_mode".to_string(),
        Value::String(
            root.get("auth_mode")
                .and_then(Value::as_str)
                .unwrap_or("chatgpt")
                .to_string(),
        ),
    );
    normalized.insert("tokens".to_string(), Value::Object(tokens));

    if let Some(last_refresh) = root.get("last_refresh") {
        normalized.insert("last_refresh".to_string(), last_refresh.clone());
    }

    Value::Object(normalized)
}

/// 解析当前 auth.json，提取账号标识和用量接口所需 token。
///
/// 注意：`auth_mode` 在某些版本可能缺失，因此优先按 `tokens` 字段判断是否可用。
pub(crate) fn extract_auth(auth_json: &Value) -> Result<ExtractedAuth, String> {
    let mode = auth_json
        .get("auth_mode")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_ascii_lowercase();

    let tokens = auth_token_object(auth_json);
    let tokens = match tokens {
        Some(value) => value,
        None => {
            if !mode.is_empty() && mode != "chatgpt" && mode != "chatgpt_auth_tokens" {
                return Err(
                    "当前账号不是 ChatGPT 登录模式，无法读取 Codex 5h/1week 用量。请先执行 codex login。"
                        .to_string(),
                );
            }
            return Err("当前未检测到 ChatGPT 登录令牌，请先执行 codex login。".to_string());
        }
    };

    let access_token = tokens
        .get("access_token")
        .and_then(Value::as_str)
        .ok_or_else(|| "auth.json 缺少 access_token".to_string())?
        .to_string();

    let id_token = tokens
        .get("id_token")
        .and_then(Value::as_str)
        .ok_or_else(|| "auth.json 缺少 id_token".to_string())?;

    let mut account_id = tokens
        .get("account_id")
        .and_then(Value::as_str)
        .map(ToString::to_string);
    let mut email = None;
    let mut plan_type = None;
    let mut principal_id = None;
    let mut team_name = None;

    if let Ok(claims) = decode_jwt_payload(id_token) {
        email = claims
            .get("email")
            .and_then(Value::as_str)
            .map(ToString::to_string);

        let auth_claim = claims
            .get("https://api.openai.com/auth")
            .and_then(Value::as_object);
        if account_id.is_none() {
            account_id = auth_claim
                .and_then(|value| value.get("chatgpt_account_id"))
                .and_then(Value::as_str)
                .map(ToString::to_string);
        }
        plan_type = auth_claim
            .and_then(|value| value.get("chatgpt_plan_type"))
            .and_then(Value::as_str)
            .map(ToString::to_string);
        team_name = extract_team_name(auth_json, Some(&claims), account_id.as_deref());
        principal_id = email
            .as_deref()
            .and_then(normalize_principal_key)
            .or_else(|| {
                auth_claim
                    .and_then(|value| {
                        value
                            .get("chatgpt_user_id")
                            .or_else(|| value.get("user_id"))
                    })
                    .and_then(Value::as_str)
                    .and_then(normalize_principal_key)
            })
            .or_else(|| {
                claims
                    .get("sub")
                    .and_then(Value::as_str)
                    .and_then(normalize_principal_key)
            });
    }

    if team_name.is_none() {
        team_name = extract_team_name(auth_json, None, account_id.as_deref());
    }

    let account_id =
        account_id.ok_or_else(|| "无法从 auth.json 识别 chatgpt_account_id".to_string())?;
    let principal_id = principal_id.unwrap_or_else(|| account_id.clone());

    Ok(ExtractedAuth {
        principal_id,
        account_id,
        access_token,
        email,
        plan_type,
        team_name,
    })
}

pub(crate) fn current_auth_account_key() -> Option<String> {
    read_current_codex_auth()
        .ok()
        .and_then(|auth_json| extract_auth(&auth_json).ok())
        .map(|auth| account_group_key(&auth.principal_id, &auth.account_id))
}

pub(crate) fn normalize_plan_type_key(plan_type: Option<&str>) -> String {
    let Some(value) = plan_type.map(str::trim).filter(|value| !value.is_empty()) else {
        return "unknown".to_string();
    };
    value.to_ascii_lowercase()
}

pub(crate) fn account_group_key(principal_id: &str, account_id: &str) -> String {
    format!("{}|{}", principal_id.trim(), account_id.trim())
}

pub(crate) fn account_variant_key(
    principal_id: &str,
    account_id: &str,
    plan_type: Option<&str>,
) -> String {
    format!(
        "{}|{}",
        account_group_key(principal_id, account_id),
        normalize_plan_type_key(plan_type)
    )
}

pub(crate) fn auth_variant_key(auth_json: &Value) -> Option<String> {
    let extracted = extract_auth(auth_json).ok()?;
    Some(account_variant_key(
        &extracted.principal_id,
        &extracted.account_id,
        extracted.plan_type.as_deref(),
    ))
}

pub(crate) fn current_auth_variant_key() -> Option<String> {
    read_current_codex_auth()
        .ok()
        .and_then(|auth_json| auth_variant_key(&auth_json))
}

fn normalize_principal_key(value: &str) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return None;
    }
    if trimmed.contains('@') {
        Some(trimmed.to_ascii_lowercase())
    } else {
        Some(trimmed.to_string())
    }
}

fn extract_team_name(
    auth_json: &Value,
    claims: Option<&Value>,
    account_id_hint: Option<&str>,
) -> Option<String> {
    let preferred_ids = preferred_workspace_ids(auth_json, claims, account_id_hint);

    if let Some(name) = extract_name_from_containers(claims, &preferred_ids, false)
        .or_else(|| extract_name_from_containers(Some(auth_json), &preferred_ids, false))
    {
        return Some(name);
    }

    for path in [
        &["https://api.openai.com/auth", "chatgpt_team_name"][..],
        &["https://api.openai.com/auth", "chatgpt_workspace_slug"][..],
        &["https://api.openai.com/auth", "workspace_slug"][..],
        &["https://api.openai.com/auth", "team_slug"][..],
        &["https://api.openai.com/auth", "organization_slug"][..],
        &["https://api.openai.com/auth", "chatgpt_org_name"][..],
        &["https://api.openai.com/auth", "organization_name"][..],
        &["https://api.openai.com/auth", "org_name"][..],
        &["https://api.openai.com/auth", "team_name"][..],
        &["organization", "name"][..],
        &["org", "name"][..],
        &["team", "name"][..],
        &["workspace", "name"][..],
    ] {
        if let Some(value) = normalized_team_name(string_at_path(claims, path), false) {
            return Some(value);
        }
    }

    for path in [
        &["tokens", "workspace_slug"][..],
        &["tokens", "team_slug"][..],
        &["tokens", "organization_slug"][..],
        &["organization", "name"][..],
        &["org", "name"][..],
        &["team", "name"][..],
        &["workspace", "name"][..],
        &["tokens", "organization_name"][..],
        &["tokens", "org_name"][..],
        &["tokens", "team_name"][..],
    ] {
        if let Some(value) = normalized_team_name(string_at_path(Some(auth_json), path), false) {
            return Some(value);
        }
    }

    let candidate_keys = [
        "teamname",
        "organizationname",
        "orgname",
        "workspacename",
        "tenantname",
        "displayname",
    ];

    find_first_string(claims, &candidate_keys, false)
        .or_else(|| find_first_string(Some(auth_json), &candidate_keys, false))
}

fn string_at_path<'a>(root: Option<&'a Value>, path: &[&str]) -> Option<&'a str> {
    let mut current = root?;
    for key in path {
        current = current.get(*key)?;
    }
    current.as_str()
}

fn normalized_team_name(value: Option<&str>, allow_personal: bool) -> Option<String> {
    let normalized = value
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToString::to_string)?;
    if !allow_personal && is_personal_name(&normalized) {
        return None;
    }
    Some(normalized)
}

fn is_personal_name(value: &str) -> bool {
    let normalized = value
        .trim()
        .to_ascii_lowercase()
        .replace([' ', '-', '_'], "");
    matches!(
        normalized.as_str(),
        "personal" | "personalworkspace" | "myworkspace"
    )
}

fn normalized_key(key: &str) -> String {
    key.replace(['_', '-'], "").to_ascii_lowercase()
}

fn find_first_string(
    value: Option<&Value>,
    candidate_keys: &[&str],
    allow_personal: bool,
) -> Option<String> {
    let value = value?;
    match value {
        Value::Object(map) => {
            for (key, item) in map {
                if candidate_keys.contains(&normalized_key(key).as_str()) {
                    if let Some(found) = normalized_team_name(item.as_str(), allow_personal) {
                        return Some(found);
                    }
                }
            }
            for item in map.values() {
                if let Some(found) = find_first_string(Some(item), candidate_keys, allow_personal) {
                    return Some(found);
                }
            }
            None
        }
        Value::Array(items) => items
            .iter()
            .find_map(|item| find_first_string(Some(item), candidate_keys, allow_personal)),
        _ => None,
    }
}

#[derive(Clone)]
struct WorkspaceCandidate {
    id: Option<String>,
    display_name: Option<String>,
    is_default: bool,
    is_current: bool,
    is_active: bool,
}

fn extract_name_from_containers(
    root: Option<&Value>,
    preferred_ids: &[String],
    allow_personal_fallback: bool,
) -> Option<String> {
    let root = root?;
    let mut candidates = collect_workspace_candidates(root);
    if candidates.is_empty() {
        return None;
    }

    if let Some(candidate) = candidates.iter().find(|candidate| {
        candidate
            .id
            .as_deref()
            .map(|id| preferred_ids.iter().any(|preferred| preferred == id))
            .unwrap_or(false)
    }) {
        if let Some(display_name) =
            normalized_team_name(candidate.display_name.as_deref(), allow_personal_fallback)
        {
            return Some(display_name);
        }
    }

    candidates.sort_by_key(|candidate| {
        let preferred_match = candidate
            .id
            .as_deref()
            .map(|id| preferred_ids.iter().any(|preferred| preferred == id))
            .unwrap_or(false);
        let non_personal = candidate
            .display_name
            .as_deref()
            .map(|value| !is_personal_name(value))
            .unwrap_or(false);
        (
            preferred_match,
            candidate.is_current,
            candidate.is_active,
            candidate.is_default,
            non_personal,
        )
    });
    candidates.reverse();

    for candidate in &candidates {
        if let Some(display_name) = normalized_team_name(candidate.display_name.as_deref(), false) {
            return Some(display_name);
        }
    }

    if allow_personal_fallback {
        for candidate in &candidates {
            if let Some(display_name) =
                normalized_team_name(candidate.display_name.as_deref(), true)
            {
                return Some(display_name);
            }
        }
    }

    None
}

fn collect_workspace_candidates(value: &Value) -> Vec<WorkspaceCandidate> {
    match value {
        Value::Object(map) => {
            let mut candidates = Vec::new();
            for key in ["organizations", "orgs", "teams", "workspaces", "groups"] {
                if let Some(Value::Array(items)) = map.get(key) {
                    for item in items {
                        let Some(object) = item.as_object() else {
                            continue;
                        };
                        candidates.push(WorkspaceCandidate {
                            id: extract_string(
                                object,
                                &["id", "organization_id", "org_id", "workspace_id", "group_id"],
                            ),
                            display_name: extract_string(
                                object,
                                &[
                                    "slug",
                                    "workspace_slug",
                                    "team_slug",
                                    "organization_slug",
                                    "name",
                                    "display_name",
                                    "displayName",
                                    "title",
                                    "label",
                                ],
                            ),
                            is_default: extract_bool(object, &["is_default", "default"]),
                            is_current: extract_bool(object, &["is_current", "current", "selected"]),
                            is_active: extract_bool(object, &["is_active", "active"]),
                        });
                    }
                }
            }

            for nested in map.values() {
                candidates.extend(collect_workspace_candidates(nested));
            }

            candidates
        }
        Value::Array(items) => items
            .iter()
            .flat_map(collect_workspace_candidates)
            .collect(),
        _ => Vec::new(),
    }
}

fn extract_string(
    object: &serde_json::Map<String, Value>,
    keys: &[&str],
) -> Option<String> {
    keys.iter().find_map(|key| {
        object
            .get(*key)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(ToString::to_string)
    })
}

fn extract_bool(object: &serde_json::Map<String, Value>, keys: &[&str]) -> bool {
    keys.iter().any(|key| {
        object
            .get(*key)
            .and_then(Value::as_bool)
            .unwrap_or(false)
    })
}

fn preferred_workspace_ids(
    auth_json: &Value,
    claims: Option<&Value>,
    account_id_hint: Option<&str>,
) -> Vec<String> {
    let mut ids = Vec::new();
    if let Some(account_id_hint) = account_id_hint
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(|value| value.to_ascii_lowercase())
    {
        ids.push(account_id_hint);
    }

    for path in [
        &["https://api.openai.com/auth", "chatgpt_org_id"][..],
        &["https://api.openai.com/auth", "chatgpt_organization_id"][..],
        &["https://api.openai.com/auth", "organization_id"][..],
        &["https://api.openai.com/auth", "org_id"][..],
        &["https://api.openai.com/auth", "active_organization_id"][..],
        &["https://api.openai.com/auth", "active_org_id"][..],
        &["https://api.openai.com/auth", "current_organization_id"][..],
        &["https://api.openai.com/auth", "default_organization_id"][..],
        &["tokens", "organization_id"][..],
        &["tokens", "org_id"][..],
        &["tokens", "active_organization_id"][..],
        &["tokens", "active_org_id"][..],
    ] {
        if let Some(value) = string_at_path(claims, path)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(|value| value.to_ascii_lowercase())
        {
            if !ids.contains(&value) {
                ids.push(value);
            }
        }
        if let Some(value) = string_at_path(Some(auth_json), path)
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(|value| value.to_ascii_lowercase())
        {
            if !ids.contains(&value) {
                ids.push(value);
            }
        }
    }

    ids
}

/// 为第三方客户端同步登录态时，提取可复用的 OpenAI OAuth token。
pub(crate) fn extract_codex_oauth_tokens(auth_json: &Value) -> Result<CodexOAuthTokens, String> {
    let tokens = auth_token_object(auth_json).ok_or_else(|| "auth.json 缺少 tokens".to_string())?;

    let access_token = tokens
        .get("access_token")
        .and_then(Value::as_str)
        .ok_or_else(|| "auth.json 缺少 access_token".to_string())?
        .to_string();
    let refresh_token = tokens
        .get("refresh_token")
        .and_then(Value::as_str)
        .ok_or_else(|| "auth.json 缺少 refresh_token".to_string())?
        .to_string();
    let account_id = tokens
        .get("account_id")
        .and_then(Value::as_str)
        .map(ToString::to_string);

    let expires_at_ms = tokens
        .get("id_token")
        .and_then(Value::as_str)
        .and_then(|id_token| decode_jwt_payload(id_token).ok())
        .and_then(|payload| payload.get("exp").and_then(Value::as_i64))
        .map(|value| value * 1000);

    Ok(CodexOAuthTokens {
        access_token,
        refresh_token,
        account_id,
        expires_at_ms,
    })
}

/// 使用 auth.json 内的 refresh_token 刷新 ChatGPT OAuth 令牌。
///
/// 返回更新后的 auth.json（仅内存对象，不会自动写盘）。
pub(crate) async fn refresh_chatgpt_auth_tokens(auth_json: &Value) -> Result<Value, String> {
    let tokens = auth_token_object(auth_json).ok_or_else(|| "auth.json 缺少 tokens".to_string())?;

    let refresh_token = tokens
        .get("refresh_token")
        .and_then(Value::as_str)
        .ok_or_else(|| "auth.json 缺少 refresh_token".to_string())?;
    let id_token = tokens
        .get("id_token")
        .and_then(Value::as_str)
        .ok_or_else(|| "auth.json 缺少 id_token".to_string())?;

    let claims = decode_jwt_payload(id_token)?;
    let issuer = claims
        .get("iss")
        .and_then(Value::as_str)
        .unwrap_or("https://auth.openai.com")
        .trim_end_matches('/')
        .to_string();
    let token_url = format!("{issuer}/oauth/token");

    let mut form_pairs: Vec<(&str, String)> = vec![
        ("grant_type", "refresh_token".to_string()),
        ("refresh_token", refresh_token.to_string()),
    ];
    if let Some(client_id) = extract_client_id_from_claims(&claims) {
        form_pairs.push(("client_id", client_id));
    }

    let client = reqwest::Client::builder()
        .user_agent("codex-tools/0.1")
        .build()
        .map_err(|e| format!("创建 HTTP 客户端失败: {e}"))?;

    let response = client
        .post(&token_url)
        .form(&form_pairs)
        .send()
        .await
        .map_err(|e| format!("刷新登录令牌失败 {token_url}: {e}"))?;

    let status = response.status();
    if !status.is_success() {
        let body = response.text().await.unwrap_or_default();
        return Err(format!(
            "刷新登录令牌失败 {token_url} -> {status}: {}",
            truncate_for_error(&body, 140)
        ));
    }

    let refreshed: RefreshedTokenPayload = response
        .json()
        .await
        .map_err(|e| format!("解析刷新令牌响应失败: {e}"))?;

    let mut updated = auth_json.clone();
    let root = updated
        .as_object_mut()
        .ok_or_else(|| "auth.json 结构异常（根节点不是对象）".to_string())?;
    let tokens = root
        .get_mut("tokens")
        .and_then(Value::as_object_mut)
        .ok_or_else(|| "auth.json 缺少 tokens".to_string())?;

    tokens.insert(
        "access_token".to_string(),
        Value::String(refreshed.access_token),
    );
    tokens.insert("id_token".to_string(), Value::String(refreshed.id_token));
    if let Some(refresh_token) = refreshed.refresh_token {
        tokens.insert("refresh_token".to_string(), Value::String(refresh_token));
    }

    Ok(updated)
}

fn codex_auth_path() -> Result<PathBuf, String> {
    let home = dirs::home_dir().ok_or_else(|| "无法读取 HOME 目录".to_string())?;
    Ok(home.join(".codex").join("auth.json"))
}

fn auth_token_object(auth_json: &Value) -> Option<&Map<String, Value>> {
    auth_json
        .get("tokens")
        .and_then(Value::as_object)
        .or_else(|| {
            let root = auth_json.as_object()?;
            if root.contains_key("access_token") && root.contains_key("id_token") {
                Some(root)
            } else {
                None
            }
        })
}

fn decode_jwt_payload(token: &str) -> Result<Value, String> {
    let payload = token
        .split('.')
        .nth(1)
        .ok_or_else(|| "id_token 格式无效".to_string())?;

    let decoded = URL_SAFE_NO_PAD
        .decode(payload)
        .or_else(|_| {
            let remainder = payload.len() % 4;
            let padded = if remainder == 0 {
                payload.to_string()
            } else {
                format!("{payload}{}", "=".repeat(4 - remainder))
            };
            URL_SAFE.decode(padded)
        })
        .map_err(|e| format!("解码 id_token 失败: {e}"))?;

    serde_json::from_slice(&decoded).map_err(|e| format!("解析 id_token payload 失败: {e}"))
}

#[derive(Debug, serde::Deserialize)]
struct RefreshedTokenPayload {
    access_token: String,
    id_token: String,
    refresh_token: Option<String>,
}

fn extract_client_id_from_claims(claims: &Value) -> Option<String> {
    let aud = claims.get("aud")?;
    match aud {
        Value::String(value) => {
            if value.is_empty() {
                None
            } else {
                Some(value.to_string())
            }
        }
        Value::Array(items) => items.iter().find_map(|item| {
            item.as_str().and_then(|value| {
                if value.is_empty() {
                    None
                } else {
                    Some(value.to_string())
                }
            })
        }),
        _ => None,
    }
}
