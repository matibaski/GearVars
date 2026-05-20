# Changelog

## 1.1.2 (2026-05-20)

- Add Wago distribution alongside CurseForge.

## 1.1.1 (2026-05-20)

- Fixed: `EditMacro` no longer resets the macro's custom icon when expanding a template. Previously the icon ID was being overwritten with nil (invisible in most cases because `#showtooltip` overrides display, but a real bug for macros without it).

## 1.1.0 (2026-05-20)

- Window now shows a scrollable list of bound macros on the right side, with macro count in the header.
- Hover a row to preview its template body in a tooltip.
- Right-click a row to unbind that macro.
- Orphan templates (macro deleted/renamed elsewhere) are flagged in red.

## 1.0.1 (2026-05-20)

- Auto-Bind now also picks up macros that already contain `{MH}`/`[OH]`/`<SH>` tokens but have never been bound. Previously it only acted on macros that contained literal current item names.

## 1.0.0 (2026-05-20)

Initial release.

- Three-slot UI for Main Hand / Off Hand / Shield with click-to-assign and drag-and-drop.
- Tokens `{MH}` / `[OH]` / `<SH>` (any of three delimiter styles) supported in macro bodies.
- **Detect from Currently Equipped** reads your slot 16/17 items.
- **Auto-Bind Macros** scans every account and per-character macro and converts literal item names to tokens.
- 2H main-hand automatically disables and clears the off-hand slot.
- Combat-safe: macro writes are queued during combat lockdown and flushed on `PLAYER_REGEN_ENABLED`.
- Item info cached on `GET_ITEM_INFO_RECEIVED` so slot names resolve after login.
- Movable minimap button (toggleable with `/gv minimap`).
- ESC closes the window.
- `/gv reset` with confirmation popup.
- First-run welcome message guides new users through setup.
