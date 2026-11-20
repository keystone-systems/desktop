# Support Hyprpolkitagent 0.2

Use the upstream Hyprtoolkit dialog on Hyprpolkitagent 0.2 and newer.
The Qt/QML theme override still applies to older packages that ship a
QML dialog. The newer agent keeps Keystone's existing session wiring and
uses its native appearance.

Verified that desktop's standalone Nixpkgs still selects the 0.1.3 QML
patch and that the newer workstation Nixpkgs builds the native 0.2.0 agent.
The authentication dialog was not exercised in a live session.
