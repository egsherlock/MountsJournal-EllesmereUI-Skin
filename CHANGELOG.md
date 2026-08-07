# Changelog

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
