# Cozy Safe design language

Read this before building any screen. It is the short version: what every screen must
look like, which shared pieces to use, and the numbers. `docs/ui.md` keeps the history
and the reasons behind each rule; when the two disagree, this file wins and `ui.md` gets
fixed.

Reference app: the iPhone's own **Photos** (iOS 26, Liquid Glass). When in doubt, do what
Photos does. We learn its layout and sizes; we never copy Apple's icons or artwork.

## 1. Principles

1. **Black and white.** One ink (black in light mode, white in dark) on the page colour.
   Everything else is that ink at an opacity. The only colours: a vault's own icon and
   colour, the system red for Delete and recording, Settings' small coloured icons, and
   the colour per kind of item where kinds are counted (storage).
2. **Few buttons, each on its own.** A button that does one thing is its own glass
   circle, apart from the others. Buttons share one glass only when they are one set to
   pick from (the section tabs, a segmented switch).
3. **Danger stands apart.** Delete is red and alone at the far right, never beside Send.
4. **The thumb's reach.** Actions live at the bottom. On top: the title, Back, and at
   most three round buttons.
5. **Same thing, same place, same word.** An action keeps its icon, its position and its
   name on every screen.
6. **Roomy.** 20 side margins, big title, large corners. Content runs under the glass.

## 2. Numbers (`lib/theme.dart`)

| Token | Value | Use |
|---|---|---|
| `Ui.side` | 20 | page side margin |
| `Ui.circle` | 44 | round buttons in a header |
| `Ui.bar` | 62 | the section bar at the bottom |
| `Ui.action` | 62 | each action circle at the bottom (as big as Photos' search) |
| `Ui.tap` | 48 | smallest touch target |
| `Ui.radius` | 24 | cards and tiles |
| `Ui.chip` | 40 | chips, segmented switches |
| `Ui.edge` | 10 | gap between a bottom bar and the safe area |

Type: the phone's own font, sizes from `CsType` only:

- big title 34 bold (`largeTitle`), with a 15 grey line under it (the item count)
- page title in a bar 17 semibold (`headline`)
- body and row names 17 (`body`)
- second line of a row 15 (`subhead`)
- dates, sizes, notes 13 (`footnote`)

Do not write a font size by hand.

Icons: Material rounded, 28 in an action circle, about 0.44 of a header circle.

## 3. Shared pieces: use these, do not rebuild them

| Need | Piece | Where |
|---|---|---|
| Actions for an open item, a note, a full-screen photo or video | `ActionBar` + `LeaveButton` + `BarIcon` | `widgets/bottom_bar.dart` |
| Actions while selecting many | `SelectionBar` (built on `ActionBar`) | `widgets/selection_bar.dart` |
| A form's main button pinned at the bottom | `PinnedAction` | `widgets/bottom_bar.dart` |
| A round button in a header | `GlassButton` (size `Ui.circle`) | `widgets/vault_bar.dart` |
| Glass behind anything | `Glass` (page glass), `GlassPill` (dark, over photos) | `widgets/vault_bar.dart`, `screens/glass.dart` |
| A row in a vault list | `SelectableRow` | `widgets/selectable_row.dart` |
| A small menu at the finger (long press, ⋯) | `showItemMenu` + `MenuEntry` | `widgets/item_menu.dart` |
| A long page | `pushPage` | `widgets/vault_bar.dart` |
| Short content over the page | `showCard` | `widgets/vault_bar.dart` |
| A group of settings rows | `SettingsGroup` | `screens/settings.dart` |
| A secret (password, 24 words) | `SecretField` | `widgets/secret.dart` |
| Red for Delete | `recordRed(context)` | `theme.dart` |

## 4. Layouts

**Action bar** (an open item, editing, selecting):

```
 (×)        (⤢) (⇪) (⋯)        (🗑)
 leave       the actions        Delete, red
```

- Left, the way out: × to close, ✓ to save and leave or end Select, ⤡ to leave full
  screen.
- Middle, in this order: Open or Full screen · Send · ⋯. While selecting: Select all ·
  Send · Group.
- Right: Delete or Delete for good, red. None when there is nothing to delete.
- Icons only; the word is the tooltip and what a screen reader says.
- On a narrow phone the middle circles shrink together; they never wrap or overflow.

**Section header** (Overview, Library, Files, Notes, inside a group):

```
 Library                       (⋯) (🔍) (⚙)
 18 items
```

- Select and Sort live in ⋯; inside a group, also Rename and Delete the group.

**Sub-page header** (Sync, Storage, Recently deleted…): the round Back (`Ui.circle`,
drawn for every page by the theme's `actionIconTheme`) on the left, the title 17
semibold in the middle, at most one round button on the right (Recently deleted: ⋯ with
Select).

**Text fields**: one look from the theme, a soft grey rounded field (14), no outline at
rest, a ring of ink while typing, red on an error.

**Selection marks**: round everywhere (the theme's `checkboxTheme`), as on a photo.

**Steps** (create a vault, restore): progress on top with Back, the title big on the
left, one main button the width of the page at the bottom (`PinnedAction`), a second
choice as plain text under it.

**Confirm a deletion**: a sheet with one red button the width of the page, Cancel as text
under it.

## 5. Not unified yet (do it this way when you touch them)

- Lists: one look everywhere, rows grouped in one rounded card (as Settings), rows about
  54 high, a thin line between rows, the kind's icon on the left.
- The bottom bars sit about 44 above the screen's edge; Photos' sit about 20.

## 6. Before you call a screen done

- [ ] Only pieces from section 3, only numbers from section 2.
- [ ] Every button that does one thing is its own circle; Delete red and far right.
- [ ] Looked at the mockup in light **and** dark, on the iPhone frame (430 wide).
- [ ] Any new word is in all 15 languages.
- [ ] Mockup approved by the owner before release.

## 7. Names

- An item's name is **one line**, ending in … when too long; never two lines (owner
  2026-10-29). Under every preview (photo, video, file, note), in the file grid and on
  the file page.

## 8. Icons in menus

- A menu (long press, ⋯) uses **line icons** only, the same weight on every row, as the
  iPhone's own menus (owner 2026-10-29: a solid black check on Select stood out). The
  only solid one is a state: the star of a favourite. Delete's icon and word are red.
- Bars and action circles keep solid icons.
