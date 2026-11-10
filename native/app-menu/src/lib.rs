mod dbus;

use dbus::Connection;
use serde_json::{json, Map, Value};
use std::env;
use std::fs;
use std::path::Path;

pub const PROTOCOL: &str = "macshell-app-menu 1";

#[derive(Clone, Debug, Default)]
pub struct Menu {
    pub id: String,
    pub label: String,
    pub items: Vec<MenuItem>,
}

#[derive(Clone, Debug, Default)]
pub struct MenuItem {
    pub id: String,
    pub label: String,
    pub enabled: bool,
    pub visible: bool,
    pub sep: bool,
    pub checked: Option<bool>,
    pub shortcut: String,
    pub action: String,
    pub children: Vec<MenuItem>,
}

impl Menu {
    fn to_json(&self) -> Value {
        json!({
            "id": self.id,
            "label": self.label,
            "items": self.items.iter().map(MenuItem::to_json).collect::<Vec<_>>(),
        })
    }
}

impl MenuItem {
    fn to_json(&self) -> Value {
        let mut map = Map::new();
        map.insert("id".into(), json!(self.id));
        map.insert("label".into(), json!(self.label));
        map.insert("enabled".into(), json!(self.enabled));
        map.insert("sep".into(), json!(self.sep));
        map.insert("shortcut".into(), json!(self.shortcut));
        map.insert("hasChildren".into(), json!(!self.children.is_empty()));
        map.insert(
            "children".into(),
            json!(self.children.iter().map(MenuItem::to_json).collect::<Vec<_>>()),
        );
        if let Some(checked) = self.checked {
            map.insert("checked".into(), json!(checked));
        }
        if !self.action.is_empty() {
            map.insert("action".into(), json!(self.action));
        }
        Value::Object(map)
    }
}

#[derive(Default)]
struct Session {
    token: u64,
    pid: u32,
    window_id: String,
    app_id: String,
    exported: bool,
    source: String,
    menus: Vec<Menu>,
    owner: String,
    path: String,
}

pub struct MenuEnv {
    pub fixture: Option<Value>,
    pub bus_address: Option<String>,
    connection: Option<Connection>,
    tried_bus: bool,
    session: Session,
}

impl MenuEnv {
    pub fn from_os() -> Self {
        let fixture = env::var_os("MACSHELL_APP_MENU_FIXTURE").and_then(|path| {
            fs::read(path)
                .ok()
                .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        });
        let bus_address = env::var("MACSHELL_APP_MENU_BUS")
            .ok()
            .filter(|value| !value.is_empty());
        Self {
            fixture,
            bus_address,
            connection: None,
            tried_bus: false,
            session: Session::default(),
        }
    }

    fn bus(&mut self) -> Option<&Connection> {
        if self.connection.is_none() && !self.tried_bus {
            self.tried_bus = true;
            self.connection = match self.bus_address.as_deref() {
                Some(address) => Connection::address(address),
                None if self.fixture.is_none() => Connection::session(),
                None => None,
            };
        }
        self.connection.as_ref()
    }
}

pub fn handle(action: &str, data: &Value, env: &mut MenuEnv) -> Value {
    match action {
        "focus" => focus(env, data),
        "layout" => payload(env, true),
        "activate" => activate(env, data),
        "clear" => {
            env.session = Session {
                token: env.session.token.saturating_add(1),
                ..Session::default()
            };
            payload(env, true)
        }
        _ => json!({"success": false, "error": "Unknown action"}),
    }
}

fn focus(env: &mut MenuEnv, data: &Value) -> Value {
    let pid = u32::try_from(number(data.get("pid"))).unwrap_or(0);
    let window_id = text(data.get("windowId"));
    let app_id = text(data.get("appId"));
    let prev_pid = env.session.pid;
    let prev_owner = env.session.owner.clone();
    let prev_path = env.session.path.clone();
    let prev_source = env.session.source.clone();
    env.session.token = env.session.token.saturating_add(1);
    env.session.pid = pid;
    env.session.window_id = window_id;
    env.session.app_id = app_id.clone();
    env.session.exported = false;
    env.session.source = "none".into();
    env.session.menus.clear();
    env.session.owner.clear();
    env.session.path.clear();

    if let Some(menus) = fixture_menus(env.fixture.as_ref(), pid) {
        env.session.exported = true;
        env.session.source = "fixture".into();
        env.session.menus = menus;
        return payload(env, true);
    }

    if pid == 0 {
        return payload(env, true);
    }
    if prev_pid == pid && !prev_owner.is_empty() {
        if let Some(menus) = env
            .bus()
            .and_then(|conn| conn.refresh(&prev_owner, &prev_path, &prev_source))
        {
            env.session.exported = true;
            env.session.source = prev_source;
            env.session.menus = menus;
            env.session.owner = prev_owner;
            env.session.path = prev_path;
            return payload(env, true);
        }
    }
    if let Some(found) = env.bus().and_then(|conn| conn.discover(pid, &app_id)) {
        env.session.exported = !found.menus.is_empty();
        env.session.source = found.source;
        env.session.menus = found.menus;
        env.session.owner = found.owner;
        env.session.path = found.path;
    }
    payload(env, true)
}

fn activate(env: &mut MenuEnv, data: &Value) -> Value {
    let token = number(data.get("token"));
    let window_id = text(data.get("windowId"));
    let id = text(data.get("id"));
    if token != env.session.token || window_id != env.session.window_id {
        return json!({"success": false, "error": "stale"});
    }
    let Some(item) = find_item(&env.session.menus, &id) else {
        return json!({"success": false, "error": "missing"});
    };
    if !item.enabled || item.sep {
        return json!({"success": false, "error": "disabled"});
    }
    if env.session.source == "fixture" {
        return json!({"success": true, "activated": id});
    }
    let source = env.session.source.clone();
    let owner = env.session.owner.clone();
    let path = env.session.path.clone();
    let action = item.action.clone();
    let ok = match source.as_str() {
        "dbusmenu" => id
            .strip_prefix("d:")
            .and_then(|value| value.parse().ok())
            .and_then(|menu_id| {
                env.connection
                    .as_ref()
                    .map(|conn| conn.activate_dbusmenu(&owner, &path, menu_id))
            })
            .unwrap_or(false),
        "gtk" => env
            .connection
            .as_ref()
            .map(|conn| conn.activate_gtk(&owner, &action))
            .unwrap_or(false),
        _ => false,
    };
    if ok {
        json!({"success": true, "activated": id})
    } else {
        json!({"success": false, "error": "activate_failed"})
    }
}

fn payload(env: &MenuEnv, success: bool) -> Value {
    json!({
        "success": success,
        "exported": env.session.exported,
        "source": env.session.source,
        "pid": env.session.pid,
        "windowId": env.session.window_id,
        "appId": env.session.app_id,
        "token": env.session.token,
        "menus": env.session.menus.iter().map(Menu::to_json).collect::<Vec<_>>(),
    })
}

fn fixture_menus(fixture: Option<&Value>, pid: u32) -> Option<Vec<Menu>> {
    let value = fixture?;
    let want = u32::try_from(number(value.get("pid"))).unwrap_or(0);
    if want != 0 && want != pid {
        return None;
    }
    let menus = value.get("menus")?.as_array()?;
    let parsed: Vec<_> = menus.iter().filter_map(menu_from_json).collect();
    if parsed.is_empty() {
        None
    } else {
        Some(parsed)
    }
}

fn menu_from_json(value: &Value) -> Option<Menu> {
    Some(Menu {
        id: text(value.get("id")),
        label: strip_mnemonic(&text(value.get("label"))),
        items: value
            .get("items")
            .and_then(Value::as_array)
            .map(|items| items.iter().filter_map(item_from_json).collect())
            .unwrap_or_default(),
    })
    .filter(|menu| !menu.label.is_empty() || !menu.id.is_empty())
}

fn item_from_json(value: &Value) -> Option<MenuItem> {
    if value.get("sep").and_then(Value::as_bool).unwrap_or(false) {
        return Some(MenuItem {
            sep: true,
            visible: true,
            enabled: true,
            ..MenuItem::default()
        });
    }
    let id = text(value.get("id"));
    let label = text(value.get("label"));
    if id.is_empty() && label.is_empty() {
        return None;
    }
    Some(MenuItem {
        id,
        label: strip_mnemonic(&label),
        enabled: value.get("enabled").and_then(Value::as_bool).unwrap_or(true),
        visible: value.get("visible").and_then(Value::as_bool).unwrap_or(true),
        sep: false,
        checked: value.get("checked").and_then(Value::as_bool),
        shortcut: text(value.get("shortcut")),
        action: text(value.get("action")),
        children: value
            .get("children")
            .and_then(Value::as_array)
            .map(|items| items.iter().filter_map(item_from_json).collect())
            .unwrap_or_default(),
    })
}

fn find_item<'a>(menus: &'a [Menu], id: &str) -> Option<&'a MenuItem> {
    for menu in menus {
        if let Some(item) = find_in(&menu.items, id) {
            return Some(item);
        }
    }
    None
}

fn find_in<'a>(items: &'a [MenuItem], id: &str) -> Option<&'a MenuItem> {
    for item in items {
        if item.id == id {
            return Some(item);
        }
        if let Some(found) = find_in(&item.children, id) {
            return Some(found);
        }
    }
    None
}

fn number(value: Option<&Value>) -> u64 {
    value
        .and_then(Value::as_u64)
        .or_else(|| value.and_then(Value::as_i64).and_then(|n| u64::try_from(n).ok()))
        .or_else(|| {
            value
                .and_then(Value::as_str)
                .and_then(|text| text.parse().ok())
        })
        .unwrap_or(0)
}

fn text(value: Option<&Value>) -> String {
    value
        .and_then(Value::as_str)
        .map(str::to_string)
        .or_else(|| value.and_then(Value::as_u64).map(|n| n.to_string()))
        .unwrap_or_default()
}

pub fn strip_mnemonic(label: &str) -> String {
    let mut out = String::with_capacity(label.len());
    let mut chars = label.chars().peekable();
    while let Some(ch) = chars.next() {
        if ch == '_' {
            if chars.peek() == Some(&'_') {
                out.push('_');
                chars.next();
            }
            continue;
        }
        out.push(ch);
    }
    out
}

pub fn load_fixture(path: &Path) -> Option<Value> {
    fs::read(path)
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
}

#[cfg(test)]
mod tests {
    use super::*;
    use macshell_gio_bridge::{self as gio, c, Ptr, Variant};
    use serde_json::json;
    use std::ffi::c_char;
    use std::io::{BufRead, BufReader};
    use std::process::{Command, Stdio};
    use std::ptr;
    use std::sync::{mpsc, Arc, Mutex};
    use std::thread;
    use std::time::Duration;

    fn env_with(fixture: Value) -> MenuEnv {
        MenuEnv {
            fixture: Some(fixture),
            bus_address: None,
            connection: None,
            tried_bus: true,
            session: Session::default(),
        }
    }

    fn sample() -> Value {
        json!({
            "pid": 42,
            "menus": [{
                "id": "file",
                "label": "_File",
                "items": [
                    {"id": "new", "label": "_New", "shortcut": "Ctrl+N"},
                    {"sep": true},
                    {"id": "quit", "label": "Quit", "enabled": true, "children": [
                        {"id": "really", "label": "Really Quit"}
                    ]}
                ]
            }]
        })
    }

    #[test]
    fn protocol_constant_matches_installer() {
        assert_eq!(PROTOCOL, "macshell-app-menu 1");
        assert_eq!(handle("nope", &json!({}), &mut MenuEnv::from_os())["error"], "Unknown action");
    }

    #[test]
    fn mnemonic_underscores_are_stripped() {
        assert_eq!(strip_mnemonic("_File"), "File");
        assert_eq!(strip_mnemonic("Save __as"), "Save _as");
        assert_eq!(strip_mnemonic("Help"), "Help");
    }

    #[test]
    fn fixture_binds_to_matching_pid_and_rejects_stale_activate() {
        let mut env = env_with(sample());
        let focused = handle(
            "focus",
            &json!({"pid": 42, "windowId": "7", "appId": "demo"}),
            &mut env,
        );
        assert_eq!(focused["success"], true);
        assert_eq!(focused["exported"], true);
        assert_eq!(focused["source"], "fixture");
        assert_eq!(focused["menus"][0]["label"], "File");
        let token = focused["token"].as_u64().unwrap();
        let ok = handle(
            "activate",
            &json!({"id": "new", "token": token, "windowId": "7"}),
            &mut env,
        );
        assert_eq!(ok["success"], true);
        let nested = handle(
            "activate",
            &json!({"id": "really", "token": token, "windowId": "7"}),
            &mut env,
        );
        assert_eq!(nested["success"], true);
        handle(
            "focus",
            &json!({"pid": 99, "windowId": "8", "appId": "other"}),
            &mut env,
        );
        let stale = handle(
            "activate",
            &json!({"id": "new", "token": token, "windowId": "7"}),
            &mut env,
        );
        assert_eq!(stale["error"], "stale");
        let mismatch = handle(
            "focus",
            &json!({"pid": 1, "windowId": "1"}),
            &mut env,
        );
        assert_eq!(mismatch["exported"], false);
    }

    #[test]
    fn dbusmenu_layout_parses_separators_and_shortcuts() {
        unsafe {
            let file_props = dbus::dict(&[dbus::dict_entry("label", gio::string("_File"))]);
            let combo_type = gio::g_variant_type_new(c("s").as_ptr());
            let combo = gio::g_variant_new_array(
                combo_type,
                [gio::string("Control"), gio::string("n")].as_ptr(),
                2,
            );
            gio::g_variant_type_free(combo_type);
            let shortcut_type = gio::g_variant_type_new(c("as").as_ptr());
            let shortcut = gio::g_variant_new_array(shortcut_type, [combo].as_ptr(), 1);
            gio::g_variant_type_free(shortcut_type);
            let new_props = dbus::dict(&[
                dbus::dict_entry("label", gio::string("_New")),
                dbus::dict_entry("shortcut", shortcut),
            ]);
            let sep_props = dbus::dict(&[dbus::dict_entry("type", gio::string("separator"))]);
            let new_item = dbus::dbusmenu_node(1, new_props, &[]);
            let sep_item = dbus::dbusmenu_node(2, sep_props, &[]);
            let file = dbus::dbusmenu_node(10, file_props, &[new_item, sep_item]);
            let root_props = dbus::dict(&[]);
            let root = dbus::dbusmenu_node(0, root_props, &[file]);
            let variant = Variant::from(gio::g_variant_ref_sink(root)).unwrap();
            let parsed = dbus::parse_dbusmenu_node(&variant).unwrap();
            assert_eq!(parsed.children.len(), 1);
            assert_eq!(parsed.children[0].label, "File");
            assert_eq!(parsed.children[0].children[0].label, "New");
            assert_eq!(parsed.children[0].children[0].shortcut, "Ctrl+n");
            assert!(parsed.children[0].children[1].sep);
        }
    }

    const DBUSMENU_XML: &str = r#"
<node>
  <interface name="com.canonical.dbusmenu">
    <method name="GetLayout">
      <arg type="i" name="parentId" direction="in"/>
      <arg type="i" name="recursionDepth" direction="in"/>
      <arg type="as" name="propertyNames" direction="in"/>
      <arg type="u" name="revision" direction="out"/>
      <arg type="(ia{sv}av)" name="layout" direction="out"/>
    </method>
    <method name="Event">
      <arg type="i" name="id" direction="in"/>
      <arg type="s" name="eventId" direction="in"/>
      <arg type="v" name="data" direction="in"/>
      <arg type="u" name="timestamp" direction="in"/>
    </method>
  </interface>
</node>
"#;

    struct Provider {
        node: Ptr,
        registration: u32,
        _vtable: Box<gio::InterfaceVTable>,
        events: Arc<Mutex<Vec<i32>>>,
    }

    extern "C" fn provider_call(
        _: Ptr,
        _: *const c_char,
        _: *const c_char,
        _: *const c_char,
        method: *const c_char,
        parameters: Ptr,
        invocation: Ptr,
        data: Ptr,
    ) {
        unsafe {
            let provider = &mut *data.cast::<Provider>();
            let name = gio::text(method);
            if name == "GetLayout" {
                let file_props = dbus::dict(&[dbus::dict_entry("label", gio::string("_File"))]);
                let new_props = dbus::dict(&[dbus::dict_entry("label", gio::string("_New"))]);
                let new_item = dbus::dbusmenu_node(1, new_props, &[]);
                let file = dbus::dbusmenu_node(10, file_props, &[new_item]);
                let root = dbus::dbusmenu_node(0, dbus::dict(&[]), &[file]);
                let reply = gio::tuple(&[gio::uint32(1), root]);
                gio::g_dbus_method_invocation_return_value(invocation, reply);
                return;
            }
            if name == "Event" {
                if let Some(params) = Variant::from(gio::g_variant_ref(parameters)) {
                    if let Some(id) = params.child(0).and_then(|child| child.i32()) {
                        provider.events.lock().unwrap().push(id);
                    }
                }
                gio::g_dbus_method_invocation_return_value(invocation, ptr::null_mut());
            }
        }
    }

    extern "C" fn quit_loop(data: Ptr) -> i32 {
        unsafe {
            gio::g_main_loop_quit(data);
        }
        0
    }

    fn private_bus() -> Option<(std::process::Child, String)> {
        let mut child = Command::new("dbus-daemon")
            .args(["--session", "--nofork", "--print-address=1"])
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .ok()?;
        let mut address = String::new();
        BufReader::new(child.stdout.take()?)
            .read_line(&mut address)
            .ok()?;
        let address = address.trim().to_string();
        if address.is_empty() {
            let _ = child.kill();
            return None;
        }
        Some((child, address))
    }

    #[test]
    fn private_dbusmenu_matches_pid_and_activate() {
        let Some((mut daemon, address)) = private_bus() else {
            return;
        };
        let events = Arc::new(Mutex::new(Vec::new()));
        let events_thread = events.clone();
        let address_thread = address.clone();
        let (ready_tx, ready_rx) = mpsc::channel();
        let worker = thread::spawn(move || unsafe {
            let Some(conn) = dbus::Connection::address(&address_thread) else {
                return;
            };
            let mut error = ptr::null_mut();
            let node = gio::g_dbus_node_info_new_for_xml(c(DBUSMENU_XML).as_ptr(), &mut error);
            if node.is_null() {
                let _ = gio::error(error);
                return;
            }
            let info = gio::g_dbus_node_info_lookup_interface(node, c("com.canonical.dbusmenu").as_ptr());
            if info.is_null() {
                gio::g_dbus_node_info_unref(node);
                return;
            }
            let loop_ = gio::g_main_loop_new(ptr::null_mut(), 0);
            let mut provider = Box::new(Provider {
                node,
                registration: 0,
                _vtable: Box::new(gio::InterfaceVTable {
                    method_call: Some(provider_call),
                    get_property: ptr::null_mut(),
                    set_property: ptr::null_mut(),
                    padding: [ptr::null_mut(); 8],
                }),
                events: events_thread,
            });
            let vtable = &*provider._vtable;
            let registration = gio::g_dbus_connection_register_object(
                conn.raw(),
                c("/MenuBar").as_ptr(),
                info,
                vtable,
                (&mut *provider as *mut Provider).cast(),
                ptr::null_mut(),
                &mut error,
            );
            if registration == 0 {
                let _ = gio::error(error);
                gio::g_dbus_node_info_unref(node);
                gio::g_main_loop_unref(loop_);
                return;
            }
            provider.registration = registration;
            let _ = ready_tx.send(());
            gio::g_timeout_add_seconds(8, Some(quit_loop), loop_);
            gio::g_main_loop_run(loop_);
            gio::g_dbus_connection_unregister_object(conn.raw(), provider.registration);
            gio::g_dbus_node_info_unref(provider.node);
            gio::g_main_loop_unref(loop_);
            drop(conn);
        });
        if ready_rx.recv_timeout(Duration::from_secs(3)).is_err() {
            let _ = daemon.kill();
            let _ = worker.join();
            return;
        }
        let mut env = MenuEnv {
            fixture: None,
            bus_address: Some(address),
            connection: None,
            tried_bus: false,
            session: Session::default(),
        };
        let pid = std::process::id() as u64;
        let focused = handle(
            "focus",
            &json!({"pid": pid, "windowId": "w1", "appId": "org.macshell.MenuProbe"}),
            &mut env,
        );
        assert_eq!(focused["success"], true);
        assert_eq!(focused["exported"], true);
        assert_eq!(focused["source"], "dbusmenu");
        assert_eq!(focused["menus"][0]["label"], "File");
        let token = focused["token"].as_u64().unwrap();
        let activated = handle(
            "activate",
            &json!({"id": "d:1", "token": token, "windowId": "w1"}),
            &mut env,
        );
        assert_eq!(activated["success"], true);
        let seen = events.lock().unwrap().clone();
        assert_eq!(seen, vec![1]);
        drop(env);
        let _ = daemon.kill();
        let _ = worker.join();
    }
}
