# Use the Qt-compatible Quickshell on newer Nixpkgs

Use the Nixpkgs Quickshell package with Qt 6.12 and newer. The flake's
pinned 0.3.1 source fails to compile with Qt 6.12's metatype checks. Older
Qt releases still use the existing pin. Quickshell stays in the private
Quattro runtime closure.

Verified the Quattro runtime contract with the workstation Nixpkgs pin.
