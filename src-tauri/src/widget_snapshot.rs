//! Write usage snapshot for the macOS WidgetKit extension.
//! Data lives in the App Group container so the widget process can read it.

use base64::{engine::general_purpose::STANDARD, Engine};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

pub const APP_GROUP_ID: &str = "group.com.sunstory.openusage";
/// Host bundle id — Application Support path the widget can read with absolute-path exception.
pub const APP_SUPPORT_ID: &str = "com.sunstory.openusage";
pub const SNAPSHOT_FILE_NAME: &str = "usage-snapshot.json";
pub const ICONS_DIR_NAME: &str = "icons";
pub const WIDGET_SUBDIR: &str = "widget";

/// One concentric ring layer (outer → inner).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WidgetRingLayerDto {
    pub label: String,
    pub fraction: f64,
    pub percent_text: String,
    pub ring_color: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WidgetRingItemDto {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub icon_data_url: String,
    pub fraction: Option<f64>,
    pub percent_text: String,
    pub detail_text: Option<String>,
    pub ring_color: Option<String>,
    pub label: Option<String>,
    /// Concentric rings when length ≥ 2 (Cursor Total/Auto/API, etc.).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rings: Option<Vec<WidgetRingLayerDto>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WidgetSnapshotDto {
    pub version: u32,
    pub updated_at: String,
    pub display_mode: String,
    pub items: Vec<WidgetRingItemDto>,
}

/// Snapshot persisted for the widget (icons referenced by relative path).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct WidgetSnapshotFile {
    version: u32,
    updated_at: String,
    display_mode: String,
    items: Vec<WidgetRingItemFile>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct WidgetRingLayerFile {
    label: String,
    fraction: f64,
    percent_text: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    ring_color: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct WidgetRingItemFile {
    id: String,
    name: String,
    /// Relative path under App Group, e.g. `icons/cursor.svg`
    icon_file: Option<String>,
    fraction: Option<f64>,
    percent_text: String,
    detail_text: Option<String>,
    ring_color: Option<String>,
    label: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    rings: Option<Vec<WidgetRingLayerFile>>,
}

/// Sideload-safe path: normal Application Support (not Group Containers).
/// Group Containers are gated by containermanagerd; sandboxed widgets get
/// "permission denied" even with absolute-path temporary exceptions.
fn application_support_widget_dir() -> Option<PathBuf> {
    let home = dirs::home_dir()?;
    Some(
        home.join("Library")
            .join("Application Support")
            .join(APP_SUPPORT_ID)
            .join(WIDGET_SUBDIR),
    )
}

fn group_containers_path() -> Option<PathBuf> {
    let home = dirs::home_dir()?;
    Some(
        home.join("Library")
            .join("Group Containers")
            .join(APP_GROUP_ID),
    )
}

/// Directory where the host writes the snapshot (+ icons/).
pub fn snapshot_write_dir() -> Option<PathBuf> {
    application_support_widget_dir()
}

/// All candidate dirs (write primary first; optional App Group mirror).
pub fn snapshot_candidate_dirs() -> Vec<PathBuf> {
    let mut dirs = Vec::new();
    if let Some(p) = application_support_widget_dir() {
        dirs.push(p);
    }
    if let Some(p) = group_containers_path() {
        dirs.push(p);
    }
    #[cfg(target_os = "macos")]
    {
        if let Some(p) = container_url_for_app_group(APP_GROUP_ID) {
            if !dirs.contains(&p) {
                dirs.push(p);
            }
        }
    }
    dirs
}

#[cfg(target_os = "macos")]
fn container_url_for_app_group(group_id: &str) -> Option<PathBuf> {
    use objc2_foundation::{NSFileManager, NSString};

    let fm = NSFileManager::defaultManager();
    let group = NSString::from_str(group_id);
    let url = fm.containerURLForSecurityApplicationGroupIdentifier(&group)?;
    let path = url.path()?.to_string();
    if path.is_empty() {
        return None;
    }
    Some(PathBuf::from(path))
}

/// Decode `data:image/svg+xml;base64,...` (or raw base64) into bytes.
fn decode_icon_data_url(data_url: &str) -> Option<Vec<u8>> {
    let trimmed = data_url.trim();
    if trimmed.is_empty() {
        return None;
    }
    let b64 = if let Some(idx) = trimmed.find("base64,") {
        &trimmed[idx + "base64,".len()..]
    } else if trimmed.starts_with("data:") {
        return None;
    } else {
        trimmed
    };
    STANDARD.decode(b64.trim()).ok()
}

fn write_icon_file(icons_dir: &Path, plugin_id: &str, icon_data_url: &str) -> Option<String> {
    let bytes = decode_icon_data_url(icon_data_url)?;
    std::fs::create_dir_all(icons_dir).ok()?;
    // Plugins ship SVG icons.
    let rel = format!("{ICONS_DIR_NAME}/{plugin_id}.svg");
    let abs = icons_dir.join(format!("{plugin_id}.svg"));
    std::fs::write(&abs, bytes).ok()?;
    Some(rel)
}

pub fn write_snapshot(snapshot: &WidgetSnapshotDto) -> Result<PathBuf, String> {
    let primary = snapshot_write_dir().ok_or("no Application Support dir")?;
    std::fs::create_dir_all(&primary)
        .map_err(|e| format!("create widget snapshot dir: {e}"))?;

    let icons_dir = primary.join(ICONS_DIR_NAME);
    let mut file_items = Vec::with_capacity(snapshot.items.len());

    for item in &snapshot.items {
        let icon_file = write_icon_file(&icons_dir, &item.id, &item.icon_data_url);
        let rings = item.rings.as_ref().map(|layers| {
            layers
                .iter()
                .map(|l| WidgetRingLayerFile {
                    label: l.label.clone(),
                    fraction: l.fraction,
                    percent_text: l.percent_text.clone(),
                    ring_color: l.ring_color.clone(),
                })
                .collect()
        });
        file_items.push(WidgetRingItemFile {
            id: item.id.clone(),
            name: item.name.clone(),
            icon_file,
            fraction: item.fraction,
            percent_text: item.percent_text.clone(),
            detail_text: item.detail_text.clone(),
            ring_color: item.ring_color.clone(),
            label: item.label.clone(),
            rings,
        });
    }

    let file = WidgetSnapshotFile {
        version: snapshot.version,
        updated_at: snapshot.updated_at.clone(),
        display_mode: snapshot.display_mode.clone(),
        items: file_items,
    };

    let json = serde_json::to_vec_pretty(&file).map_err(|e| e.to_string())?;
    let primary_path = primary.join(SNAPSHOT_FILE_NAME);
    std::fs::write(&primary_path, &json).map_err(|e| format!("write snapshot: {e}"))?;
    // World-readable for sandboxed widget with absolute-path exception.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&primary_path, std::fs::Permissions::from_mode(0o644));
        let _ = std::fs::set_permissions(&primary, std::fs::Permissions::from_mode(0o755));
    }

    // Best-effort mirror into App Group (works when both have real App Groups).
    for dir in snapshot_candidate_dirs() {
        if dir == primary {
            continue;
        }
        if std::fs::create_dir_all(&dir).is_ok() {
            let mirror = dir.join(SNAPSHOT_FILE_NAME);
            let _ = std::fs::write(&mirror, &json);
            let mirror_icons = dir.join(ICONS_DIR_NAME);
            if let Ok(entries) = std::fs::read_dir(&icons_dir) {
                let _ = std::fs::create_dir_all(&mirror_icons);
                for entry in entries.flatten() {
                    let dest = mirror_icons.join(entry.file_name());
                    let _ = std::fs::copy(entry.path(), dest);
                }
            }
        }
    }

    reload_widget_timelines();
    Ok(primary_path)
}

/// Ask WidgetKit to refresh all timelines for this app's extensions.
pub fn reload_widget_timelines() {
    #[cfg(target_os = "macos")]
    {
        reload_widget_timelines_macos();
    }
}

#[cfg(target_os = "macos")]
fn reload_widget_timelines_macos() {
    use std::ffi::CStr;
    use objc2::runtime::{AnyClass, AnyObject};
    use objc2::msg_send;

    // Ensure WidgetKit is loaded so WidgetCenter is registered.
    let _ = load_widget_kit_bundle();

    // WidgetCenter is a Swift class exported to ObjC.
    // Prefer +sharedCenter; fall back to +shared (Swift name).
    let name = CStr::from_bytes_with_nul(b"WidgetCenter\0").expect("cstr");
    let Some(cls) = AnyClass::get(name) else {
        log::debug!("WidgetCenter class not found; skip timeline reload");
        return;
    };

    unsafe {
        let mut center: *mut AnyObject = msg_send![cls, sharedCenter];
        if center.is_null() {
            center = msg_send![cls, shared];
        }
        if center.is_null() {
            log::debug!("WidgetCenter.shared unavailable");
            return;
        }
        let _: () = msg_send![center, reloadAllTimelines];
    }
    log::debug!("WidgetKit timelines reload requested");
}

#[cfg(target_os = "macos")]
fn load_widget_kit_bundle() -> bool {
    use objc2_foundation::{NSBundle, NSString};

    let paths = [
        "/System/Library/Frameworks/WidgetKit.framework",
        "/System/iOSSupport/System/Library/Frameworks/WidgetKit.framework",
    ];
    for path in paths {
        let ns_path = NSString::from_str(path);
        let bundle = NSBundle::bundleWithPath(&ns_path);
        if let Some(bundle) = bundle {
            let ok = unsafe { bundle.load() };
            if ok {
                return true;
            }
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decode_svg_data_url() {
        let raw = b"<svg xmlns='http://www.w3.org/2000/svg'/>";
        let b64 = STANDARD.encode(raw);
        let url = format!("data:image/svg+xml;base64,{b64}");
        let out = decode_icon_data_url(&url).expect("decode");
        assert_eq!(out, raw);
    }
}
