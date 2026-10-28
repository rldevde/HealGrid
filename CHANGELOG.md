# Changelog

All notable changes to HealGrid are documented here.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.1.2] - 2026-10-28

### Fixed
- **Out-of-combat dead-click did nothing for druids** — the hybrid macro only offered the battle rez under `[dead,combat]`, and Revive does not exist on this client, so out of combat the click fell through to the heal spell on a corpse. The battle rez is now also the out-of-combat fallback (Rebirth is usable outside combat)
- **`togglemenu` bindings opened the unit menu on dead cells** — menu bindings now become the same hybrid macro; the menu still opens on live targets via a hidden proxy button

## [1.1.1]

### Fixed
- **Resurrection on dead cells now works in combat** — spell bindings are
  built as hybrid macros (`/cast [dead,combat] Battle Rez; [dead] Rez;
  <spell>`), so the button picks the right spell without protected
  attribute swaps. Druids get Rebirth in combat, Death Knights Raise Ally
  and Warlocks Soulstone; other classes keep their normal rez
- **No more menu fallback on dead cells** — when no rez resolves the click
  simply does nothing instead of opening the unit menu
- **Spell detection hardened** — `IsSpellKnown` now probes
  `C_Spell.IsSpellKnown`, `IsSpellKnownOrOverridesKnown`, `IsSpellKnown`
  and `IsPlayerSpell`, fixing empty menus on clients where only some
  APIs exist

## [1.1.0]

### Added
- **Profiles** — save/load/delete named settings snapshots, export to a
  copyable string and import shared profiles; optional per-character
  settings ("Char Profile") split from the account-wide ones
- **Custom debuff highlighting** — comma-separated spell IDs shown as a
  big centered icon on the cell
- **Dispel alert** — sound and/or border flash when a debuff your class
  can remove lands on someone
- **Cast feedback** — cells show a small castbar and an accent border for
  the unit your current spellcast targets (cast color configurable)
- **Own-HoT corner dot** — minimal opt-in indicator that turns red in the
  last 3 seconds (configurable color)
- **Context scaling** — separate scale multipliers for solo / party / raid
- **Event-driven repainting** — unit events repaint only the affected
  cells instead of a full grid pass
- **Macro pad** — small clickable zone next to the anchor running a
  user-defined macro
- **Options polish** — status footer with live cell/group counts and a
  global reset button; "Hide Anchor" option

## [1.0.0]

### Added
- Standalone healer raid grid — 8x5 group layout, no external dependencies
- Health and power bars with class, gradient or fully custom colors,
  configurable background color and alpha
- Click-cast system with a full binding matrix (5 buttons x 4 modifiers),
  per-binding action types (spell, macro, item, target, focus, menu),
  `heal` / `dispel` / `rez` class-spell keywords and rez-on-dead
- Debuff-only aura display with dispel-type colored cell borders and an
  optional "only dispellable" filter per class
- Incoming heal and absorb previews, aggro dot/border, raid marker,
  role letter, ready check, resurrection icon, AFK / offline / dead states,
  out-of-range fading with configurable alpha
- Layout options: horizontal/vertical orientation, growth directions,
  index/name/role sorting, cell size, spacing, group spacing, scale,
  hide-empty-groups, hide-in-combat and visibility rules
  (always / group / raid)
- Pets column using the owner's class color
- Test mode filling the grid with 5–40 deterministic fake cells for
  layout preview and click-cast testing
- Tabbed options window (General / Layout / Bars / Text / Icons / Colors /
  Click Cast / About) with color pickers for all bar and border colors
- Minimap launcher button and `/healgrid` / `/hg` slash commands
- Automatic visibility on healer classes
- deDE locale with English fallback
- Multi-client compatibility layer (aura access, color picker APIs,
  secret-value safe previews) and combat-deferred frame operations
