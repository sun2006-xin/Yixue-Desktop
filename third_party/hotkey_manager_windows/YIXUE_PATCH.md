# Local Windows hotkey patch

Based on the complete `hotkey_manager_windows` 0.2.0 package; original LICENSE preserved. The hosted package ignored RegisterHotKey's BOOL result and always reported success, preventing the application from showing a real global-shortcut conflict.

This copy keeps the original API and reports `hotkey_conflict` or `hotkey_registration_failed` with GetLastError as the error details. Failed registration does not enter the identifier map. Physical HID keyboard usages are converted to Set-1 scan codes and resolved through the active Windows keyboard layout with `MapVirtualKeyExW` before calling `RegisterHotKey`, so non-US layouts keep the selected physical key position. The focused native mapping test covers US/QWERTZ resolution, extended keys, invalid usages, and unmapped keys. Pub cache is untouched; the app binds this copy through dependency_overrides. Real conflicting-key acceptance is tracked in the screenshot workflow's Task 6.
