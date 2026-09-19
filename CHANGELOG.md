# Changelog

## 1.1.1

**New**

- **Hovering the resize grip now tells you what it does:** drag to resize,
  right-click to snap back to the smallest size. It's the same small tooltip
  EllesmereUI uses for its own controls, and it stays out of the way while
  you drag.

**Fixed**

- **The Collections tab labels no longer drop when you open the Mounts tab.**
  1.1.0's fix hung the row from a stand-in that copied the journal window's
  size a hair too faithfully, and that hair was enough to push the text down
  a pixel. The row now sits on the Collections window's own bottom edge, and
  moves down only by whole pixels when the journal is taller.
- **The Model, Map and Settings tabs no longer change width when clicked.**
  The selected label was being measured in one font and drawn in another, so
  the tab was fitted to the wrong width until the next repaint. Both states
  now share one size, as the Collections tabs beside them do.

## 1.1.0

A polish release. Almost everything here is about the journal sitting
pixel-for-pixel alongside the other Collections tabs.

**New**

- **Right-click the resize grip** to snap the window back to its smallest
  size. It's remembered, just like dragging it there.
- **If you run atrocityUI, the Model, Map and Settings tabs now match the
  Collections tabs beside them:** same dark plate, font, hover and selected
  tint, picked up from the row next door. Without atrocityUI nothing changes,
  because the two rows already matched.

**Fixed**

- **The Collections tab labels no longer drop a pixel when you open the Mounts
  tab** and climb back when you leave it.
- **The window can be made exactly as narrow as the other Collections tabs.**
  Before, it stopped a few pixels short, and after a reload it opened a little
  wider than you had left it.
- **Resizing the window and reloading no longer scatters the tab buttons.**
- **The favourite star sits on top of the icon's edge again,** on mounts and on
  pets.
- **The Mount button's label no longer changes size when you hover it.**
- **The active filter tab's label stays crisp** instead of being tinted along
  with its background.
- **"Dungeons and Raids" under the map is no longer cut short.**
- **The mounts-per-row box in the model grid always shows its number.**

**Looks**

- **The mount list sits on a darker plate,** scroll bar and all, with a faint
  highlight under the cursor, matching the pet list the Rematch skin draws. The
  icon grid gets the same plate.
- **Grid tiles are square.** Blizzard's rounded border no longer shows inside
  the skin's edge.
- **Everything in the left column lines up:** the filter row, the type bar, the
  list and the Mount and profile buttons share the same left and right edges,
  and the scroll bar sits centred in its channel. If you also use the Rematch
  skin, switching between Mounts and Pet Journal no longer twitches by a pixel.
- **The panel on the right lines up with the list,** both in list view and on
  the Map tab, and the model grid's first column starts where the Mount button
  does.

**For bug reports**

- `/mjeuiskin tabs` now prints exact positions and fonts for both tab rows, and
  `/mjeuiskin list` and `/mjeuiskin pet` do the same for the list column and
  the pet button.

## 1.0.10

- **Fixed: an error while scrolling the mount grid, and when the pet selection
  button was turned on.** MountsJournal's latest update changed the small level
  badge those buttons carry, and the skin was trying to flatten it the way it
  flattens a whole panel. Nothing stopped working, but the error repeated as you
  scrolled and could leave the odd grid tile still wearing Blizzard's art until
  you scrolled past it again. With thanks to MountsJournal's author, who found it
  and reported it.
- **The level badge behind a pet's number is hidden now**, which is what the skin
  always meant to do. You will only see a difference on buttons that have a pet
  assigned to them.
- **The same kind of change elsewhere in MountsJournal can no longer cause that
  error.** The skin now copes wherever MountsJournal draws a single piece of art
  in a place it used to draw a group of them.

## 1.0.9

- Releases now reach CurseForge automatically. Nothing in the addon changed.

## 1.0.8

- The two buttons above the map's flags panel line up with its edges instead of
  stopping a hair short.

## 1.0.7

- `/mjeuiskin` reports the installed MountsJournal, EllesmereUI and skin
  versions, so a bug report can start with the answer to the first question it
  always raises.

## 1.0.6

- **Fixed: MountsJournal's dropdown menus kept Blizzard's backdrop instead of
  taking EllesmereUI's.** The menu library arrives with MountsJournal's interface,
  which loads after the skin has run, so the skin looks for it again once the
  journal exists.

## 1.0.5

- **Support for EllesmereUI 8.6.8's own skinning API.** The journal now appears
  under Blizzard Window Skins > Third-Party Addons and follows its toggles.
  Nothing is required of you: 8.6.6 and earlier keep working exactly as before,
  and so does 8.6.8 with the Blizzard Skin component switched off.
- **Changing your accent colour repaints the journal straight away.** It used to
  need a reload.
- **Fixed: the Dress Up button was a blank block.** Its entire appearance lives in
  unnamed artwork, which the skin was flattening along with the rest of the
  button.

## 1.0.4

- **The bottom tab row is left alone again.** Two attempts to restyle it both
  ended worse than doing nothing: the selected tab's growth *is* its artwork, so
  flattening it took away the thing that marked the tab as selected. Untouched,
  those tabs match Collections' own.
- **Fixed: a square plate appeared around the map's breadcrumb arrow on hover.**
  The button raises that artwork itself when the cursor arrives, so hiding it once
  was never going to hold.

## 1.0.3

- The tab row was given a base to sit on. (Reverted in 1.0.4.)
- `/mjeuiskin` reports each texture's colour, which is the difference between a
  dark plate and a pale haze in the output rather than only on screen.

## 1.0.2

- **Fixed: the bottom tab row rendered as pale silver blocks.** Clearing a
  texture does not make it draw nothing — it falls back to plain white, and six
  of those stacked up into light grey.
- The map control row reaches the edges of the panel around it.

## 1.0.1

- **The map's breadcrumb trail.** Every button in the row is the same height now,
  the crumbs no longer overlap far enough to bury the overflow arrow on a deep
  trail, and their dropdown arrows match the rest of the skin.

## 1.0.0

- First release. Reskins MountsJournal to match EllesmereUI, following your own
  EllesmereUI settings — window colour, transparency, accent, font and border are
  read live, so switching profile is picked up without you configuring anything.
