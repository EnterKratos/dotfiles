#!/usr/bin/env python3
import json
import subprocess
import time

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

INTERNAL_OUTPUT = "eDP-1"
SETTLE_SECONDS = 1.5


def kscreen_outputs():
    out = subprocess.run(["kscreen-doctor", "-j"], capture_output=True, text=True, check=True)
    return json.loads(out.stdout)["outputs"]


def is_docked():
    return any(o["connected"] for o in kscreen_outputs() if o["name"] != INTERNAL_OUTPUT)


def internal_enabled():
    for o in kscreen_outputs():
        if o["name"] == INTERNAL_OUTPUT:
            return o["enabled"]
    return True


def internal_is_primary():
    for o in kscreen_outputs():
        if o["name"] == INTERNAL_OUTPUT:
            return o["priority"] == 1
    return False


def set_primary(name):
    subprocess.run(["kscreen-doctor", f"output.{name}.primary"], check=True)
    time.sleep(SETTLE_SECONDS)


def set_internal(enabled):
    action = "enable" if enabled else "disable"
    subprocess.run(["kscreen-doctor", f"output.{INTERNAL_OUTPUT}.{action}"], check=True)
    time.sleep(SETTLE_SECONDS)


def disable_internal():
    # Disabling the primary output while it's docked is what crashes KWin/plasmashell.
    # Hand primary off to the external monitor first, as its own settled step.
    if internal_is_primary():
        external = next(
            (o for o in kscreen_outputs() if o["name"] != INTERNAL_OUTPUT and o["connected"]),
            None,
        )
        if external is not None:
            set_primary(external["name"])
    set_internal(False)


def enable_internal():
    set_internal(True)
    set_primary(INTERNAL_OUTPUT)


def on_lid_changed(closed):
    if closed:
        if is_docked() and internal_enabled():
            disable_internal()
    else:
        if not internal_enabled():
            enable_internal()


def properties_changed(connection, sender, path, interface, signal, params):
    _iface_name, changed, _invalidated = params.unpack()
    if "LidIsClosed" in changed:
        on_lid_changed(changed["LidIsClosed"])


def main():
    bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)

    initial = bus.call_sync(
        "org.freedesktop.UPower",
        "/org/freedesktop/UPower",
        "org.freedesktop.DBus.Properties",
        "Get",
        GLib.Variant("(ss)", ("org.freedesktop.UPower", "LidIsClosed")),
        GLib.VariantType("(v)"),
        Gio.DBusCallFlags.NONE,
        -1,
        None,
    )
    on_lid_changed(initial.unpack()[0])

    # NOTE: sender must be None here, not the well-known name
    # "org.freedesktop.UPower" -- PyGObject's signal_subscribe does not
    # resolve well-known names to the owning unique name for matching,
    # so a well-known-name sender silently never matches.
    bus.signal_subscribe(
        None,
        "org.freedesktop.DBus.Properties",
        "PropertiesChanged",
        "/org/freedesktop/UPower",
        None,
        Gio.DBusSignalFlags.NONE,
        properties_changed,
    )
    GLib.MainLoop().run()


if __name__ == "__main__":
    main()
