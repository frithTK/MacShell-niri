use crate::{Menu, MenuItem};
use macshell_gio_bridge::{self as gio, c, Ptr, Variant};
use std::collections::HashSet;
use std::ptr;

const DBUSMENU: &str = "com.canonical.dbusmenu";
const GTK_MENUS: &str = "org.gtk.Menus";
const GTK_ACTIONS: &str = "org.gtk.Actions";
const DBUS: &str = "org.freedesktop.DBus";
const DBUS_PATH: &str = "/org/freedesktop/DBus";

const DBUSMENU_PATHS: &[&str] = &[
    "/MenuBar",
    "/com/canonical/menu/0",
    "/org/ayatana/MenuBar",
    "/org/ayatana/dbusmenu",
    "/com/canonical/dbusmenu",
];

pub struct Connection {
    bus: Ptr,
    owned: bool,
}

pub struct Export {
    pub owner: String,
    pub path: String,
    pub source: String,
    pub menus: Vec<Menu>,
}

impl Connection {
    pub fn session() -> Option<Self> {
        unsafe {
            let mut error = ptr::null_mut();
            let bus = gio::g_bus_get_sync(2, ptr::null_mut(), &mut error);
            if bus.is_null() {
                if !error.is_null() {
                    let _ = gio::error(error);
                }
                return None;
            }
            gio::g_dbus_connection_set_exit_on_close(bus, 0);
            Some(Self { bus, owned: false })
        }
    }

    pub fn address(address: &str) -> Option<Self> {
        unsafe {
            let mut error = ptr::null_mut();
            let bus = gio::g_dbus_connection_new_for_address_sync(
                c(address).as_ptr(),
                1 << 0 | 1 << 5,
                ptr::null_mut(),
                ptr::null_mut(),
                &mut error,
            );
            if bus.is_null() {
                if !error.is_null() {
                    let _ = gio::error(error);
                }
                return None;
            }
            gio::g_dbus_connection_set_exit_on_close(bus, 0);
            Some(Self { bus, owned: true })
        }
    }

    #[allow(dead_code)]
    pub fn raw(&self) -> Ptr {
        self.bus
    }

    pub fn discover(&self, pid: u32, app_id: &str) -> Option<Export> {
        let mut seen = HashSet::new();
        for name in preferred_names(app_id) {
            let owner = match self.name_owner(&name) {
                Some(owner) => owner,
                None => continue,
            };
            if !seen.insert(owner.clone()) {
                continue;
            }
            if pid != 0 && self.pid_of(&owner) != Some(pid) {
                continue;
            }
            if let Some(found) = self.menus_on(&owner) {
                return Some(found);
            }
        }
        if pid == 0 {
            return None;
        }
        for name in self.names() {
            if !seen.insert(name.clone()) {
                continue;
            }
            if self.pid_of(&name) != Some(pid) {
                continue;
            }
            if let Some(found) = self.menus_on(&name) {
                return Some(found);
            }
        }
        None
    }

    pub fn refresh(&self, owner: &str, path: &str, source: &str) -> Option<Vec<Menu>> {
        match source {
            "dbusmenu" => self.dbusmenu_at(owner, path),
            "gtk" => self.gtk_menus(owner),
            _ => None,
        }
        .filter(|menus| !menus.is_empty())
    }

    pub fn activate_dbusmenu(&self, owner: &str, path: &str, id: i32) -> bool {
        unsafe {
            let mut error = ptr::null_mut();
            let data = gio::g_variant_new_variant(gio::string(""));
            let params = gio::tuple(&[
                gio::int32(id),
                gio::string("clicked"),
                data,
                gio::uint32(0),
            ]);
            let reply = gio::g_dbus_connection_call_sync(
                self.bus,
                c(owner).as_ptr(),
                c(path).as_ptr(),
                c(DBUSMENU).as_ptr(),
                c("Event").as_ptr(),
                params,
                ptr::null_mut(),
                0,
                2000,
                ptr::null_mut(),
                &mut error,
            );
            if !error.is_null() {
                let _ = gio::error(error);
                return false;
            }
            if !reply.is_null() {
                gio::g_variant_unref(reply);
            }
            true
        }
    }

    pub fn activate_gtk(&self, owner: &str, action: &str) -> bool {
        if action.is_empty() {
            return false;
        }
        unsafe {
            let mut error = ptr::null_mut();
            let params = gio::tuple(&[
                gio::string(action),
                gio::empty_array("v"),
                gio::empty_array("{sv}"),
            ]);
            let reply = gio::g_dbus_connection_call_sync(
                self.bus,
                c(owner).as_ptr(),
                c("/org/gtk/Application").as_ptr(),
                c(GTK_ACTIONS).as_ptr(),
                c("Activate").as_ptr(),
                params,
                ptr::null_mut(),
                0,
                2000,
                ptr::null_mut(),
                &mut error,
            );
            if !error.is_null() {
                let _ = gio::error(error);
                return false;
            }
            if !reply.is_null() {
                gio::g_variant_unref(reply);
            }
            true
        }
    }

    fn menus_on(&self, owner: &str) -> Option<Export> {
        if let Some((path, menus)) = self.dbusmenu(owner) {
            return Some(Export {
                owner: owner.to_string(),
                path,
                source: "dbusmenu".into(),
                menus,
            });
        }
        let menus = self.gtk_menus(owner)?;
        Some(Export {
            owner: owner.to_string(),
            path: "/org/gtk/Menus".into(),
            source: "gtk".into(),
            menus,
        })
    }

    fn names(&self) -> Vec<String> {
        unsafe {
            let mut error = ptr::null_mut();
            let reply = gio::g_dbus_connection_call_sync(
                self.bus,
                c(DBUS).as_ptr(),
                c(DBUS_PATH).as_ptr(),
                c(DBUS).as_ptr(),
                c("ListNames").as_ptr(),
                ptr::null_mut(),
                ptr::null_mut(),
                0,
                2000,
                ptr::null_mut(),
                &mut error,
            );
            let Some(value) = Variant::from(reply) else {
                if !error.is_null() {
                    let _ = gio::error(error);
                }
                return Vec::new();
            };
            let Some(list) = value.child(0) else {
                return Vec::new();
            };
            let mut names = Vec::new();
            for i in 0..list.len() {
                if let Some(name) = list.child(i).and_then(|child| child.string()) {
                    if name.starts_with(':') {
                        names.push(name);
                    }
                }
            }
            names
        }
    }

    fn name_owner(&self, name: &str) -> Option<String> {
        if name.starts_with(':') {
            return Some(name.to_string());
        }
        unsafe {
            let mut error = ptr::null_mut();
            let reply = gio::g_dbus_connection_call_sync(
                self.bus,
                c(DBUS).as_ptr(),
                c(DBUS_PATH).as_ptr(),
                c(DBUS).as_ptr(),
                c("GetNameOwner").as_ptr(),
                gio::tuple(&[gio::string(name)]),
                ptr::null_mut(),
                0,
                1500,
                ptr::null_mut(),
                &mut error,
            );
            let Some(value) = Variant::from(reply) else {
                if !error.is_null() {
                    let _ = gio::error(error);
                }
                return None;
            };
            value.child(0).and_then(|child| child.string())
        }
    }

    fn pid_of(&self, name: &str) -> Option<u32> {
        unsafe {
            let mut error = ptr::null_mut();
            let reply = gio::g_dbus_connection_call_sync(
                self.bus,
                c(DBUS).as_ptr(),
                c(DBUS_PATH).as_ptr(),
                c(DBUS).as_ptr(),
                c("GetConnectionUnixProcessID").as_ptr(),
                gio::tuple(&[gio::string(name)]),
                ptr::null_mut(),
                0,
                1500,
                ptr::null_mut(),
                &mut error,
            );
            let Some(value) = Variant::from(reply) else {
                if !error.is_null() {
                    let _ = gio::error(error);
                }
                return None;
            };
            value.child(0).and_then(|child| child.u32())
        }
    }

    fn dbusmenu(&self, name: &str) -> Option<(String, Vec<Menu>)> {
        for path in DBUSMENU_PATHS {
            if let Some(menus) = self.dbusmenu_at(name, path) {
                if !menus.is_empty() {
                    return Some((path.to_string(), menus));
                }
            }
        }
        None
    }

    fn dbusmenu_at(&self, name: &str, path: &str) -> Option<Vec<Menu>> {
        let node = self.get_layout(name, path, 0)?;
        let children = if node.children.is_empty() {
            vec![node]
        } else {
            node.children
        };
        let menus = children
            .into_iter()
            .filter(|item| !item.sep && item.visible)
            .map(|item| Menu {
                id: item.id.clone(),
                label: if item.label.is_empty() {
                    item.id.clone()
                } else {
                    item.label.clone()
                },
                items: item.children,
            })
            .filter(|menu| !menu.label.is_empty())
            .collect();
        Some(menus)
    }

    fn get_layout(&self, name: &str, path: &str, parent: i32) -> Option<MenuItem> {
        unsafe {
            let mut error = ptr::null_mut();
            let params = gio::tuple(&[gio::int32(parent), gio::int32(-1), gio::empty_array("s")]);
            let reply = gio::g_dbus_connection_call_sync(
                self.bus,
                c(name).as_ptr(),
                c(path).as_ptr(),
                c(DBUSMENU).as_ptr(),
                c("GetLayout").as_ptr(),
                params,
                ptr::null_mut(),
                0,
                2000,
                ptr::null_mut(),
                &mut error,
            );
            let Some(value) = Variant::from(reply) else {
                if !error.is_null() {
                    let _ = gio::error(error);
                }
                return None;
            };
            value
                .child(1)
                .and_then(|layout| parse_dbusmenu_node(&layout))
        }
    }

    fn gtk_menus(&self, name: &str) -> Option<Vec<Menu>> {
        unsafe {
            let mut error = ptr::null_mut();
            let zero = gio::uint32(0);
            let ids_type = gio::g_variant_type_new(c("u").as_ptr());
            let ids = gio::g_variant_new_array(ids_type, [zero].as_ptr(), 1);
            gio::g_variant_type_free(ids_type);
            let reply = gio::g_dbus_connection_call_sync(
                self.bus,
                c(name).as_ptr(),
                c("/org/gtk/Menus").as_ptr(),
                c(GTK_MENUS).as_ptr(),
                c("Start").as_ptr(),
                gio::tuple(&[ids]),
                ptr::null_mut(),
                0,
                2000,
                ptr::null_mut(),
                &mut error,
            );
            let Some(value) = Variant::from(reply) else {
                if !error.is_null() {
                    let _ = gio::error(error);
                }
                return None;
            };
            parse_gtk_start(&value)
        }
    }
}

impl Drop for Connection {
    fn drop(&mut self) {
        unsafe {
            if self.owned {
                let mut error = ptr::null_mut();
                gio::g_dbus_connection_close_sync(self.bus, ptr::null_mut(), &mut error);
                if !error.is_null() {
                    let _ = gio::error(error);
                }
            }
            gio::g_object_unref(self.bus);
        }
    }
}

pub fn parse_dbusmenu_node(node: &Variant) -> Option<MenuItem> {
    unsafe {
        if !node.kind().starts_with('(') {
            return None;
        }
        let id = node.child(0).and_then(|child| child.i32()).unwrap_or(0);
        let props = node.child(1);
        let kind = lookup_string(props.as_ref(), "type");
        let label = lookup_string(props.as_ref(), "label");
        let enabled = lookup_bool(props.as_ref(), "enabled").unwrap_or(true);
        let visible = lookup_bool(props.as_ref(), "visible").unwrap_or(true);
        let checked = lookup_i32(props.as_ref(), "toggle-state").map(|state| state == 1);
        let checkable = !lookup_string(props.as_ref(), "toggle-type").is_empty();
        let shortcut = props
            .as_ref()
            .and_then(|dict| dict.lookup("shortcut"))
            .and_then(unwrap_variant)
            .map(|value| shortcut_from_variant(&value))
            .unwrap_or_default();
        let mut children = Vec::new();
        if let Some(list) = node.child(2) {
            for i in 0..list.len() {
                if let Some(child) = list
                    .child(i)
                    .and_then(unwrap_variant)
                    .and_then(|inner| parse_dbusmenu_node(&inner))
                {
                    if child.visible {
                        children.push(child);
                    }
                }
            }
        }
        Some(MenuItem {
            id: format!("d:{id}"),
            label: crate::strip_mnemonic(&label),
            enabled,
            visible,
            sep: kind == "separator",
            checked: if checkable { checked } else { None },
            shortcut,
            action: String::new(),
            children,
        })
    }
}

fn parse_gtk_start(value: &Variant) -> Option<Vec<Menu>> {
    unsafe {
        let groups = value.child(0)?;
        let mut by_id: Vec<(u32, Vec<GtkRow>)> = Vec::new();
        for g in 0..groups.len() {
            let group = groups.child(g)?;
            let menu_id = group.child(1).and_then(|child| child.u32()).unwrap_or(0);
            let rows = group.child(2)?;
            let mut items = Vec::new();
            for i in 0..rows.len() {
                if let Some(row) = rows.child(i).and_then(|value| gtk_row(&value)) {
                    items.push(row);
                }
            }
            by_id.push((menu_id, items));
        }
        let converted = convert_gtk(&by_id, 0, 0);
        if converted.is_empty() {
            return None;
        }
        if converted.iter().any(|item| !item.children.is_empty()) {
            Some(
                converted
                    .into_iter()
                    .filter(|item| !item.sep && !item.label.is_empty())
                    .map(|item| Menu {
                        id: item.id.clone(),
                        label: item.label.clone(),
                        items: item.children,
                    })
                    .collect(),
            )
        } else {
            Some(vec![Menu {
                id: "g:0".into(),
                label: "Menu".into(),
                items: converted,
            }])
        }
    }
}

struct GtkRow {
    label: String,
    action: String,
    accel: String,
    submenu: Option<u32>,
    section: Option<u32>,
}

fn gtk_row(row: &Variant) -> Option<GtkRow> {
    let label = lookup_string(Some(row), "label");
    let action = lookup_string(Some(row), "action");
    let accel = lookup_string(Some(row), "accel");
    let submenu = lookup_u32(Some(row), "submenu");
    let section = lookup_u32(Some(row), "section");
    if label.is_empty() && action.is_empty() && submenu.is_none() && section.is_none() {
        return None;
    }
    Some(GtkRow {
        label,
        action,
        accel,
        submenu,
        section,
    })
}

fn convert_gtk(groups: &[(u32, Vec<GtkRow>)], menu_id: u32, depth: u8) -> Vec<MenuItem> {
    if depth > 8 {
        return Vec::new();
    }
    let Some((_, rows)) = groups.iter().find(|(id, _)| *id == menu_id) else {
        return Vec::new();
    };
    let mut items = Vec::new();
    for row in rows {
        if let Some(section) = row.section {
            items.extend(convert_gtk(groups, section, depth + 1));
            continue;
        }
        let children = row
            .submenu
            .map(|id| convert_gtk(groups, id, depth + 1))
            .unwrap_or_default();
        let label = crate::strip_mnemonic(&row.label);
        if label.is_empty() && children.is_empty() && row.action.is_empty() {
            continue;
        }
        items.push(MenuItem {
            id: if row.action.is_empty() {
                format!("g:{menu_id}:{}", items.len())
            } else {
                format!("g:{}", row.action)
            },
            label,
            enabled: true,
            visible: true,
            sep: false,
            checked: None,
            shortcut: gtk_accel(&row.accel),
            action: row.action.clone(),
            children,
        });
    }
    items
}

fn lookup_string(dict: Option<&Variant>, key: &str) -> String {
    unsafe {
        dict.and_then(|value| value.lookup(key))
            .and_then(unwrap_variant)
            .and_then(|value| value.string())
            .unwrap_or_default()
    }
}

fn lookup_bool(dict: Option<&Variant>, key: &str) -> Option<bool> {
    unsafe {
        dict.and_then(|value| value.lookup(key))
            .and_then(unwrap_variant)
            .and_then(|value| value.boolean())
    }
}

fn lookup_i32(dict: Option<&Variant>, key: &str) -> Option<i32> {
    unsafe {
        dict.and_then(|value| value.lookup(key))
            .and_then(unwrap_variant)
            .and_then(|value| value.i32())
    }
}

fn lookup_u32(dict: Option<&Variant>, key: &str) -> Option<u32> {
    unsafe {
        dict.and_then(|value| value.lookup(key))
            .and_then(unwrap_variant)
            .and_then(|value| value.u32())
    }
}

fn unwrap_variant(value: Variant) -> Option<Variant> {
    unsafe {
        if value.kind().starts_with('v') {
            value.child(0)
        } else {
            Some(value)
        }
    }
}

fn shortcut_from_variant(value: &Variant) -> String {
    unsafe {
        let combo = if value.kind().starts_with("aa") {
            match value.child(0) {
                Some(child) => child,
                None => return String::new(),
            }
        } else {
            return String::new();
        };
        let mut parts = Vec::new();
        for i in 0..combo.len() {
            if let Some(part) = combo.child(i).and_then(|child| child.string()) {
                parts.push(pretty_key(&part));
            }
        }
        parts.join("+")
    }
}

fn gtk_accel(value: &str) -> String {
    value
        .replace("<Primary>", "Ctrl+")
        .replace("<Control>", "Ctrl+")
        .replace("<Shift>", "Shift+")
        .replace("<Alt>", "Alt+")
        .replace("<Meta>", "Meta+")
}

fn pretty_key(value: &str) -> String {
    match value {
        "Control" | "Primary" => "Ctrl".into(),
        "Shift" => "Shift".into(),
        "Alt" => "Alt".into(),
        "Super" | "Meta" => "Meta".into(),
        other => other.to_string(),
    }
}

fn preferred_names(app_id: &str) -> Vec<String> {
    let mut names = Vec::new();
    let trimmed = app_id.trim();
    if trimmed.contains('.') {
        names.push(trimmed.to_string());
        names.push(trimmed.replace('-', "_"));
        names.push(trimmed.replace('_', "-"));
    }
    names.sort();
    names.dedup();
    names
}

#[cfg(test)]
pub unsafe fn dict_entry(key: &str, value: Ptr) -> Ptr {
    gio::g_variant_new_dict_entry(gio::string(key), gio::g_variant_new_variant(value))
}

#[cfg(test)]
pub unsafe fn dict(entries: &[Ptr]) -> Ptr {
    let kind = gio::g_variant_type_new(c("{sv}").as_ptr());
    let value = gio::g_variant_new_array(kind, entries.as_ptr(), entries.len());
    gio::g_variant_type_free(kind);
    value
}

#[cfg(test)]
pub unsafe fn variant_array(children: &[Ptr]) -> Ptr {
    let wrapped: Vec<_> = children
        .iter()
        .map(|child| gio::g_variant_new_variant(*child))
        .collect();
    let kind = gio::g_variant_type_new(c("v").as_ptr());
    let value = gio::g_variant_new_array(kind, wrapped.as_ptr(), wrapped.len());
    gio::g_variant_type_free(kind);
    value
}

#[cfg(test)]
pub unsafe fn dbusmenu_node(id: i32, props: Ptr, children: &[Ptr]) -> Ptr {
    gio::tuple(&[gio::int32(id), props, variant_array(children)])
}
