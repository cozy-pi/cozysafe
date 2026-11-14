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
   the colour per kind of item where kinds are counted (storage). Since 2026-10-31
   (owner: more colour in the icons) also: each section's colour on the ways to add
   and the overview's tiles (`sectionColor`, `addWayColor`; the tabs went back to one
   ink with a word under each, 2026-11-07 review), and the two modes' shields (`topSecretRed`
   with a lock, `privateGreen` with a photo); a vault in Top Secret Mode washes the top
   of its page with a little red (`TopSecretWash`, owner 2026-10-31, in place of a shield
   on the Settings button); each common kind of file its icon and colour
   (`FileKind`, `lib/file_kinds.dart`); and since 2026-11-07 each kind of password its
   own (`entryKindColor`: a login orange, a two-factor code blue, recovery codes purple),
   wherever its icon shows.
2. **Few buttons, each on its own.** A button that does one thing is its own glass
   circle, apart from the others. Buttons share one glass only when they are one set to
   pick from (the section tabs, a segmented switch).
3. **Danger stands apart.** Delete is red and alone at the far right, never beside Send.
4. **The thumb's reach.** Actions live at the bottom. On top: the title, Back, and at
   most three round buttons.
5. **Same thing, same place, same word.** An action keeps its icon, its position and its
   name on every screen.
6. **Roomy.** 20 side margins, big title, large corners. Content runs under the glass.
7. **Grouped, as the phone's Settings** (2026-11-07 review). Light mode: the page a pale
   grey (`#F2F2F5`), cards and list groups white on it. Dark mode: black, cards
   `#1C1C1E`. Every page alike; `groupedPage` is kept for callers and changes nothing.
8. **Quiet type.** A row's name is 17 regular; bold is for the big title, a page title
   and a card's heading. Weight is not how a row stands out; its place and its icon are.

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

- big title 34 bold (`largeTitle`), with a 15 grey line under it on every tab alike:
  `N items · size`, then the Google Drive cloud (`HomeSyncIcon(dense: true)`, 8 after)
- page title in a bar 17 semibold (`headline`)
- body and row names 17 regular (`body`), also the big title of Settings (34, as every tab)
- second line of a row 15 (`subhead`)
- dates, sizes, notes 13 (`footnote`)

Do not write a font size by hand.

Icons: Material rounded, 28 in an action circle, about 0.44 of a header circle. New
pieces (since 2026-11-07, owner: modern icons) use **Material Symbols Rounded** through
`Sym` (`lib/widgets/symbols.dart`): filled (FILL 1), weight 500, grade 0, optical size
24, so they sit beside the older `Icons.*_rounded` with the same rounding and weight.
`Sym` holds only the glyphs in the bundled subset; a new one means cutting the font again
(assets/fonts/README.md). Menus keep line icons (section 8). The rest of the app moves
later (docs/backlog.md).

## 3. Shared pieces: use these, do not rebuild them

| Need | Piece | Where |
|---|---|---|
| Actions for an open item, a note, a full-screen photo or video | `ActionBar` (`start` / `leave`) + `BarIcon` | `widgets/bottom_bar.dart` |
| The top of every viewer (Back · date · ⋯) | `ViewerTopBar`, `mediaDate` | `widgets/bottom_bar.dart`, `screens/glass.dart` |
| Actions while selecting many | `SelectionBar` (built on `ActionBar`) | `widgets/selection_bar.dart` |
| A form's main button pinned at the bottom | `PinnedAction` | `widgets/bottom_bar.dart` |
| A round button in a header | `GlassButton` (size `Ui.circle`) | `widgets/vault_bar.dart` |
| Glass behind anything | `Glass` (page glass), `GlassPill` (dark, over photos) | `widgets/vault_bar.dart`, `screens/glass.dart` |
| A row in a vault list | `SelectableRow` | `widgets/selectable_row.dart` |
| Chips over Files and the Library (All, Photos, Videos, Documents, Other) | `_fileChips`, `FileGroup` | `screens/vault_home.dart`, `file_kinds.dart` |
| A small menu at the finger (long press, ⋯) | `showItemMenu` + `MenuEntry` | `widgets/item_menu.dart` |
| A long page, and every sub-page of Settings (never swapped in place: owner 2026-10-31) | `pushPage` | `widgets/vault_bar.dart` |
| Short content over the page | `showCard` | `widgets/vault_bar.dart` |
| A group of settings rows | `SettingsGroup` | `screens/settings.dart` |
| A secret (password, 24 words) | `SecretField` | `widgets/secret.dart` |
| One question per screen: Back, progress, big title on the left, main button pinned, a second choice as text | `StepPage`, `StepProgress`, `StepMainButton`, `StepTextButton` | `widgets/steps.dart` |
| Pick one of a few ways inside a step (the wizard's fallback kind chooser): big cards, icon in a coloured rounded square, title and one line | `ChoiceCard` | `widgets/steps.dart` |
| The ways to add, and a way's second choices in place | `AddCard` (`way`, `onBack`), `addSubChoices` | `widgets/vault_bar.dart` |
| A kind of password's icon and colour | `entryIcon`, `entryKindColor`, `EntryBadge`, `EntryKindLine` | `widgets/entry_row.dart`, `widgets/vault_bar.dart` |
| A new icon | `Sym` (Material Symbols Rounded) | `widgets/symbols.dart` |
| Red for Delete | `recordRed(context)` | `theme.dart` |

## 4. Layouts

**Viewer** (every preview: photo, video, note, recording, file; owner 2026-10-29, laid
out as Photos):

```
 (‹)          date · time · size          (⋯)

                  the item

           [ strip of photos ]        photos and videos only
 (⇪)               (ⓘ)                (🗑)
 Share             Info               Delete, red
```

- A photo or video opens straight to full screen; there is no preview box first. The
  strip shows every photo and video, blurred when thumbnails are hidden. Scrolling the
  strip moves the photo above with it, a haptic tick per photo passed, and it settles
  with one photo in the middle.
- A note, recording or file opens in the box over the page; a tap beside it or a swipe
  down closes it, as Back does. A tap on the item opens it (the editor, the file page).
- No ×. In Recently deleted: no ⋯; Restore · Info · Delete for good.
- Back and ⋯ are as big as the bottom circles (`Ui.action`), not header size.
- With the bars shown, a photo sits between them; a tap hides them and it fills the screen.
- ⋯ opens the item's menu right there, beside the button (`ViewerMenu`): the viewer
  stays. Never close the viewer to show a menu elsewhere.

**Action bar** (editing a note, selecting):

```
 (⇪)               (✓)                (🗑)        a note: Send · Done · Delete
 (✓)      (☐) (⇪) (#)                (🗑)        selecting: Done, then the actions
```

- Left: Send in a note (as in the viewers); ✓ to end Select.
- Right: Delete or Delete for good, red. None when there is nothing to delete.
- Icons only; the word is the tooltip and what a screen reader says.
- On a narrow phone the middle circles shrink together; they never wrap or overflow.

**Section header** (Overview, Library, Files, Notes, Passwords, inside a group; the same
on every tab, the Overview too: no search field of its own, owner 2026-11-07):

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
rest, a ring of ink while typing, red on an error. The border is `RoundFieldBorder`: the
label floats inside the field, at its top, never onto the ring.

**No helper button over a password field** (owner 2026-10-29: "Suggest a password"
removed). The strength line under it says how to make a better one.

**Selection marks**: round everywhere (the theme's `checkboxTheme`), as on a photo.

**Steps** (create a vault, restore, add a password), all in one frame, `StepPage`
(creating a vault moved onto it 2026-11-07; Back is ‹ as everywhere): create is Password → 24 words →
four typed back → Face ID → look; the intro lists them in that order. Progress on top with Back, the title big on the
left, one main button the width of the page at the bottom (`PinnedAction`), a second
choice as plain text under it (`StepPage`). Adding a password (owner 2026-11-07): the
kind is picked in the add card, then one question per screen from that kind's first,
answered with taps where possible: what the vault already holds first, then common
choices, typing last. Back from the first step leaves. A login's password step opens on
an empty field to type or paste the password in use; "Make a strong one" is the second
choice (2026-11-07 review: the ready-made one as the main button got saved by mistake).

**The add card** (owner 2026-11-07): one card, near the thumb, just above + (under Add
on a computer). A way that asks a second question (Photos / Files, Note / Voice,
Password) shows its choices **in that same card**, in place of the four ways, with ‹
in the card's header to go back; the card keeps its place and its size (owner 2026-11-14:
shrinking to fewer choices was unpleasant), growing only for more lines. Never a
separate card, a page or another dim or blur on top for a way's choices. Choosing one
closes the card and does it. With + in the middle, three quick buttons sit just above +,
solid in their colours: the ways of the three kinds the vault holds most, the most over +
(owner 2026-11-14: the card alone left no quick add; brought back from before the
2026-11-07 review). On an edge the card is alone and its lines are the quick buttons. A
finger sliding up from + picks the button or line it lets go on. The page behind dims to
60% (owner 2026-11-14: 92% was too heavy). The camera, and Note where nothing records, act at once.

**Confirm a deletion**: a sheet with one red button the width of the page, Cancel as text
under it. Where keeping is the safe and likely answer (the originals after an import),
Keep is a full button as big as Delete, not text.

**Buttons** are round-ended (stadium) everywhere: the theme's filled and outlined
buttons, a step's main button. No 10-corner buttons.

## 5. Not unified yet (do it this way when you touch them)

- Kinds and sections are ranked by how many items they hold, most first, wherever
  they are listed (bar, overview tiles, search tiles; owner 2026-11-07).
- Lists: one look everywhere, rows grouped in one rounded card (as Settings), rows about
  54 high, a thin line between rows, the kind's icon on the left. (The page and card
  colours are done, principle 7; row height and icon size are not yet.)
- The bottom bars sit about 44 above the screen's edge; Photos' sit about 20.

**Wide window** (iPad, computer): a page opened from the content (Sync from the home
page's cloud, Version history) opens on the right through `_pageContext`; the left column
stays.

**Tour tips**: no button that leaves the tour; Next, Skip, Done only (a lone tip may have a Settings button, below).

**Explaining a feature** (owner 2026-11-04): something that could pass for a fault (blurred
thumbnails) gets one tip, shown once, where the person first meets it: `showCoachTour`
with a single `TourTip` on the thing itself, remembered by a `*-tip-seen` pref. No
lasting button or status line for it on the page (both read as clutter), and do not count
on the tour at the start: people skip it and forget it. A lone tip shows no "1/1", and its
button says "Got it". When it names a setting, it also has a Settings button that opens on
that very row, lit (`_openSettings(focus:)`), as the screenshot card does: every text
that sends someone to a setting offers that same button. The words name the place with
`settingsPath()`, never typed by hand (test/settings_path_test.dart keeps it true).

**Hidden for the beta** (owner 2026-10-29: a simpler app first): groups and selecting
many, each behind one switch in `lib/hidden_features.dart`. Nothing is deleted; a screen
that offers either checks its switch.

## 6. Before you call a screen done

- [ ] Only pieces from section 3, only numbers from section 2.
- [ ] Every button that does one thing is its own circle; Delete red and far right.
- [ ] Looked at the mockup in light **and** dark, on the iPhone frame (430 wide). A bar
      or row of buttons is also shot at 393 wide (iPhone 15/16): the note's format bar
      overflowed there unseen (2026-11-05).
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
