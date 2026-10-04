//! Native filtering adapter. No disk, network, Swift, XPC, or UI work in queries.
//! Chromium request interception and renderer application remain an M0 gate.

use adblock::resources::{MimeType, Resource, ResourceType};
use adblock::{
    Engine,
    lists::{FilterSet, ParseOptions},
    request::Request,
};
use std::{
    ffi::{CString, c_char},
    panic::{AssertUnwindSafe, catch_unwind},
    ptr, slice, str,
};

const MAX_RULE_BYTES: usize = 16 * 1024 * 1024;
const MAX_URL_BYTES: usize = 64 * 1024;
const MAX_TOKEN_BYTES: usize = 64 * 1024;

pub struct WMBlocker {
    engine: Engine,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct WMStringView {
    pub data: *const u8,
    pub length: usize,
}

#[repr(C)]
#[derive(Debug, PartialEq)]
pub enum WMStatus {
    Ok = 0,
    InvalidInput = 1,
    EngineFailure = 2,
}

#[repr(C)]
pub struct WMDecision {
    pub status: WMStatus,
    pub blocked: bool,
    pub excepted: bool,
    pub redirect: *mut c_char,
    pub rewritten_url: *mut c_char,
}

impl WMDecision {
    fn empty(status: WMStatus) -> Self {
        Self {
            status,
            blocked: false,
            excepted: false,
            redirect: ptr::null_mut(),
            rewritten_url: ptr::null_mut(),
        }
    }
}

// The FFI caller guarantees allocation validity; length caps bound parsing work.
unsafe fn text<'a>(view: WMStringView, limit: usize) -> Option<&'a str> {
    if view.length > limit || (view.data.is_null() && view.length != 0) {
        return None;
    }
    if view.length == 0 {
        return Some("");
    }
    str::from_utf8(unsafe { slice::from_raw_parts(view.data, view.length) }).ok()
}

fn owned(value: String) -> *mut c_char {
    CString::new(value).map_or(ptr::null_mut(), CString::into_raw)
}

fn compile(rules: &str) -> Option<WMBlocker> {
    // List downloads must be verified by the caller against the pinned manifest.
    // Reject truncated/error-page payloads rather than replacing a working engine.
    if rules.trim().is_empty()
        || rules.contains('\0')
        || rules.trim_start().starts_with('<')
        || rules.lines().any(|line| line.len() > 16 * 1024)
    {
        return None;
    }
    let mut set = FilterSet::new(false);
    set.add_filter_list(rules.to_owned(), ParseOptions::default());
    let mut engine = Engine::new_with_filter_set(set);
    // Version 1 resource set: a locally authored, empty JavaScript response only.
    // Lists cannot register resources or supply executable bodies.
    engine.use_resources([Resource {
        name: "empty.js".into(),
        aliases: vec![],
        kind: ResourceType::Mime(MimeType::ApplicationJavascript),
        content: String::new(),
        dependencies: vec![],
        permission: Default::default(),
    }]);
    Some(WMBlocker { engine })
}

/// # Safety
/// `rules` must satisfy the live-allocation contract in winmux_blocking.h.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn wm_blocker_create(rules: WMStringView) -> *mut WMBlocker {
    catch_unwind(AssertUnwindSafe(|| {
        let rules = unsafe { text(rules, MAX_RULE_BYTES) }?;
        compile(rules).map(|engine| Box::into_raw(Box::new(engine)))
    }))
    .ok()
    .flatten()
    .unwrap_or(ptr::null_mut())
}

/// Construct the checksum-verified snapshot embedded by the Chromium build.
/// The caller must run this on a background sequence. No sandbox file access
/// or network fetch is needed to initialize the engine.
#[cfg(feature = "chromium-bundled")]
#[unsafe(no_mangle)]
pub extern "C" fn wm_blocker_create_bundled() -> *mut WMBlocker {
    let rules = include_str!(env!("WINMUX_BUNDLED_RULES_PATH"));
    catch_unwind(AssertUnwindSafe(|| {
        compile(rules).map(|engine| Box::into_raw(Box::new(engine)))
    }))
    .ok()
    .flatten()
    .unwrap_or(ptr::null_mut())
}

/// # Safety
/// Release once, after all queries end; null is permitted.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn wm_blocker_free(blocker: *mut WMBlocker) {
    if !blocker.is_null() {
        drop(unsafe { Box::from_raw(blocker) });
    }
}

/// # Safety
/// The engine and views must remain live during this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn wm_blocker_check(
    blocker: *const WMBlocker,
    url: WMStringView,
    source: WMStringView,
    request_type: WMStringView,
    method: WMStringView,
    site_enabled: bool,
) -> WMDecision {
    catch_unwind(AssertUnwindSafe(|| {
        let Some(blocker) = (unsafe { blocker.as_ref() }) else {
            return WMDecision::empty(WMStatus::InvalidInput);
        };
        if !site_enabled {
            return WMDecision::empty(WMStatus::Ok);
        }
        let (Some(url), Some(source), Some(kind), Some(method)) = (
            unsafe { text(url, MAX_URL_BYTES) },
            unsafe { text(source, MAX_URL_BYTES) },
            unsafe { text(request_type, 32) },
            unsafe { text(method, 32) },
        ) else {
            return WMDecision::empty(WMStatus::InvalidInput);
        };
        let Ok(request) = Request::new(url, source, kind, method) else {
            return WMDecision::empty(WMStatus::InvalidInput);
        };
        let result = blocker.engine.check_network_request(&request);
        WMDecision {
            status: WMStatus::Ok,
            blocked: result.should_block(),
            excepted: result.exception.is_some(),
            redirect: result.redirect.map_or(ptr::null_mut(), owned),
            rewritten_url: result.rewritten_url.map_or(ptr::null_mut(), owned),
        }
    }))
    .unwrap_or_else(|_| WMDecision::empty(WMStatus::EngineFailure))
}

/// # Safety
/// The engine and view must remain live during this call. Free the returned string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn wm_blocker_cosmetics(
    blocker: *const WMBlocker,
    url: WMStringView,
    site_enabled: bool,
) -> *mut c_char {
    catch_unwind(AssertUnwindSafe(|| {
        let blocker = unsafe { blocker.as_ref() }?;
        let url = unsafe { text(url, MAX_URL_BYTES) }?;
        let resources = if site_enabled {
            blocker.engine.url_cosmetic_resources(url)
        } else {
            Default::default()
        };
        // Procedural actions and scriptlets need a separately audited renderer
        // interpreter. Do not expose them as executable strings in the M0 adapter.
        Some(owned(
            serde_json::json!({
                "hide_selectors": resources.hide_selectors,
                "exceptions": resources.exceptions,
                "generichide": resources.generichide || !site_enabled,
            })
            .to_string(),
        ))
    }))
    .ok()
    .flatten()
    .unwrap_or(ptr::null_mut())
}

/// # Safety
/// The engine and views must remain live during this call. Free the returned string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn wm_blocker_dynamic_cosmetics(
    blocker: *const WMBlocker,
    url: WMStringView,
    tokens: WMStringView,
    site_enabled: bool,
) -> *mut c_char {
    catch_unwind(AssertUnwindSafe(|| {
        let blocker = unsafe { blocker.as_ref() }?;
        let url = unsafe { text(url, MAX_URL_BYTES) }?;
        let tokens: serde_json::Value =
            serde_json::from_str(unsafe { text(tokens, MAX_TOKEN_BYTES) }?).ok()?;
        let classes = tokens.get("classes")?.as_array()?;
        let ids = tokens.get("ids")?.as_array()?;
        if classes.len() + ids.len() > 1024 {
            return None;
        }
        let classes: Option<Vec<_>> = classes.iter().map(|v| v.as_str()).collect();
        let ids: Option<Vec<_>> = ids.iter().map(|v| v.as_str()).collect();
        let (classes, ids) = (classes?, ids?);
        let page = blocker.engine.url_cosmetic_resources(url);
        let selectors = if !site_enabled || page.generichide {
            vec![]
        } else {
            blocker
                .engine
                .hidden_class_id_selectors(classes, ids, &page.exceptions)
        };
        Some(owned(serde_json::json!(selectors).to_string()))
    }))
    .ok()
    .flatten()
    .unwrap_or(ptr::null_mut())
}

/// # Safety
/// `value` must be null or a not-yet-freed result from this library.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn wm_string_free(value: *mut c_char) {
    if !value.is_null() {
        drop(unsafe { CString::from_raw(value) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CStr;
    fn view(value: &str) -> WMStringView {
        WMStringView {
            data: value.as_ptr(),
            length: value.len(),
        }
    }
    const RULES: &str = "||ads.example^\n@@||ads.example/allowed.js$script\nexample.com##.sponsor\n##.advert\nexample.com#@#.advert\n||replace.example^$redirect=empty.js\n";
    fn check(engine: &WMBlocker, url: &str, source: &str, kind: &str, enabled: bool) -> WMDecision {
        unsafe {
            wm_blocker_check(
                engine,
                view(url),
                view(source),
                view(kind),
                view("GET"),
                enabled,
            )
        }
    }
    unsafe fn json(value: *mut c_char) -> serde_json::Value {
        assert!(!value.is_null());
        let parsed =
            serde_json::from_str(unsafe { CStr::from_ptr(value) }.to_str().unwrap()).unwrap();
        unsafe { wm_string_free(value) };
        parsed
    }
    #[test]
    fn network_types_and_exceptions() {
        let engine = compile(RULES).unwrap();
        for kind in [
            "document",
            "subdocument",
            "script",
            "image",
            "xmlhttprequest",
            "websocket",
        ] {
            let result = check(
                &engine,
                "https://ads.example/ad",
                "https://example.com/",
                kind,
                true,
            );
            assert_eq!(result.status, WMStatus::Ok);
            assert!(result.blocked, "{kind}");
        }
        assert!(
            !check(
                &engine,
                "https://ads.example/allowed.js",
                "https://example.com/",
                "script",
                true
            )
            .blocked
        );
        assert!(
            !check(
                &engine,
                "https://ads.example/ad",
                "https://example.com/",
                "image",
                false
            )
            .blocked
        );
    }
    #[test]
    fn only_bundled_replacements_are_available() {
        let engine = compile(RULES).unwrap();
        let result = check(
            &engine,
            "https://replace.example/ad.js",
            "https://example.com/",
            "script",
            true,
        );
        assert!(result.blocked);
        assert!(!result.redirect.is_null());
        unsafe { wm_string_free(result.redirect) };
        let engine = compile("||replace.example^$redirect=untrusted.js").unwrap();
        let result = check(
            &engine,
            "https://replace.example/ad.js",
            "https://example.com/",
            "script",
            true,
        );
        assert!(result.blocked);
        assert!(result.redirect.is_null());
    }
    #[test]
    fn site_cosmetics_dynamic_deltas_and_exceptions() {
        let engine = compile(RULES).unwrap();
        let initial = unsafe {
            json(wm_blocker_cosmetics(
                &engine,
                view("https://example.com/"),
                true,
            ))
        };
        assert!(
            initial["hide_selectors"]
                .as_array()
                .unwrap()
                .contains(&serde_json::json!(".sponsor"))
        );
        let delta = view(r#"{"classes":["advert"],"ids":[]}"#);
        let excepted = unsafe {
            json(wm_blocker_dynamic_cosmetics(
                &engine,
                view("https://example.com/"),
                delta,
                true,
            ))
        };
        assert_eq!(excepted, serde_json::json!([]));
        let other = unsafe {
            json(wm_blocker_dynamic_cosmetics(
                &engine,
                view("https://other.com/"),
                delta,
                true,
            ))
        };
        assert_eq!(other, serde_json::json!([".advert"]));
        let disabled = unsafe {
            json(wm_blocker_cosmetics(
                &engine,
                view("https://example.com/"),
                false,
            ))
        };
        assert_eq!(disabled["hide_selectors"], serde_json::json!([]));
    }
    #[test]
    fn malformed_inputs_do_not_unwind_through_ffi() {
        let null = WMStringView {
            data: ptr::null(),
            length: 1,
        };
        assert!(unsafe { wm_blocker_create(null) }.is_null());
        assert!(unsafe { wm_blocker_create(view("<html>upstream error</html>")) }.is_null());
        let engine = compile(RULES).unwrap();
        assert_eq!(
            unsafe { wm_blocker_check(&engine, null, null, null, null, true) }.status,
            WMStatus::InvalidInput
        );
        assert!(
            unsafe {
                wm_blocker_dynamic_cosmetics(&engine, view("https://example.com"), view("{}"), true)
            }
            .is_null()
        );
    }
    #[test]
    fn immutable_engine_supports_concurrent_queries() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<WMBlocker>();
        let engine = compile(RULES).unwrap();
        std::thread::scope(|scope| {
            for _ in 0..4 {
                let engine = &engine;
                scope.spawn(move || {
                    for _ in 0..1000 {
                        assert!(
                            check(
                                engine,
                                "https://ads.example/ad",
                                "https://example.com",
                                "image",
                                true
                            )
                            .blocked
                        );
                    }
                });
            }
        });
    }
}
