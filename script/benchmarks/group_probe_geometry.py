"""Inventory identities and WindowServer scope for the group-switch probe."""


def inventory_signature(surfaces):
    identities = {}
    for surface in surfaces:
        surface_id = surface["id"]
        if surface_id in identities:
            raise RuntimeError("Duplicate surface identity in probe inventory")
        browser = surface.get("browser")
        kind = "browser" if browser is not None else "native"
        window_id = browser.get("hostWindowID") if browser is not None else surface.get("nativeWindowID")
        available = surface["available"]
        if available and (not isinstance(window_id, int) or window_id <= 0):
            raise RuntimeError(f"Available probe surface has no native host identity: {surface_id}")
        identities[surface_id] = (surface["workspace"], available, kind, window_id)
    return identities


def require_same_inventory(expected, surfaces):
    if inventory_signature(surfaces) != expected:
        raise RuntimeError("Probe inventory changed: surfaces, availability, assignments or native host identities differ")


def scope_window_snapshot(windows, browser_pid, inventory):
    browser_ids = {item[3] for item in inventory.values() if item[1] and item[2] == "browser"}
    native_ids = {item[3] for item in inventory.values() if item[1] and item[2] == "native"}
    managed, other_browser_windows = {}, {}
    for window in windows:
        if not window["onscreen"]:
            continue
        window_id = window["id"]
        if window["pid"] == browser_pid:
            target = managed if window_id in browser_ids else other_browser_windows
            target[str(window_id)] = window["bounds"]
        elif window_id in native_ids:
            managed[str(window_id)] = window["bounds"]
    return managed, other_browser_windows
