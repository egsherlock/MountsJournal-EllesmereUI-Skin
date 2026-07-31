# MountsJournal EllesmereUI Skin

Reskins [MountsJournal](https://www.curseforge.com/wow/addons/mounts-journal) to match [EllesmereUI](https://github.com/EllesmereGaming/EllesmereUI).

You need both addons installed. This one contains no part of either, and if you're not running both it quietly does nothing.

The whole idea is that it follows **your** EllesmereUI setup rather than imposing a look of its own. Window colour, transparency, accent, font and border all come from your active profile, read fresh each time. Change something in EllesmereUI and the journal changes with it.

## Screenshots

![Mount list](https://raw.githubusercontent.com/egsherlock/MountsJournal-EllesmereUI-Skin/main/docs/mounts.png)

*The journal picking up a Dark Mode profile, colour and transparency both.*

![Grid view](https://raw.githubusercontent.com/egsherlock/MountsJournal-EllesmereUI-Skin/main/docs/grid.png)

*Grid view, with the mounts per row slider.*

![Settings](https://raw.githubusercontent.com/egsherlock/MountsJournal-EllesmereUI-Skin/main/docs/settings.png)

*MountsJournal's own settings, skinned to match.*

![Class settings](https://raw.githubusercontent.com/egsherlock/MountsJournal-EllesmereUI-Skin/main/docs/class-settings.png)

*Class settings, with the class list and macro editors.*

## What it takes from EllesmereUI

Nothing is hardcoded, and no profile gets special treatment. Imports like atrocityUI or AES work simply because they write these same values.

- **Window colour and transparency** — your profile's Dark Mode fill, colour and alpha both
- **Accent** (selections, checkmarks, sliders) — your EllesmereUI accent colour
- **UI font** — the font your EllesmereUI is set to
- **Window border** — the border texture and size from EllesmereUI's own options, including a size of 0 meaning no border
- **Window style** — whatever style you've set for the Collections window

These get re-read every time something is painted, never cached. Switch profile, reopen the journal, done. There's nothing to import or keep in sync.

## Options

**Game Menu > Options > AddOns > MountsJournal EllesmereUI Skin**

- **Window backdrop** (default: EllesmereUI Dark Mode) — uses your Dark Mode colour and alpha. The other choice, Blizzard window art, uses EllesmereUI's own window texture, which is fully opaque and can't be made see-through.
- **Follow EllesmereUI opacity** (default: on) — uses your Dark Mode alpha. Turn it off if you'd rather set the transparency yourself.
- **Opacity** (default: 90) — your own transparency setting. Ignored while the option above is on.
- **Window edge** (default: thin dark line) — a crisp 1px edge. The alternative, EllesmereUI window frame, matches its windows exactly but brings a soft inner shading with it.
- **Border style** (default: follow EllesmereUI) — whatever border you've set in EllesmereUI's own options, texture and size. You can also pick one yourself from its border list, including Glow, Shadow and any LibSharedMedia borders.
- **Border size** (default: 2) — thickness, 1 to 4. Ignored while following EllesmereUI.

## What it actually touches

**MountsJournal's own frames**, all over: the journal window, the mount and pet lists, the filter bar, the map and model tabs, and the config, rules, snippets and icon picker windows. Art is only ever faded, never hidden. Nothing is reparented or has its scripts replaced.

**Blizzard's Collections and MountJournal frames**, in one specific way: their chrome is faded while the journal is open and put back when it closes, so it can't show through a transparent backdrop. The Collections tab row underneath is left alone.

Cost is a one-off pass at login plus hooks. There's no OnUpdate, no polling and no per-frame work.

## If something looks wrong

`/mjeuiskin` tells you what actually ran: which backend is live, the versions installed, the colours and border it resolved, and any stage that failed. Each section is isolated, so if a frame moves in a MountsJournal update you lose that section rather than the whole window.

`/mjeuiskin behind` lists anything still drawing behind the window, and `/mjeuiskin tabs` compares the tab rows. Both print what the frames really carry, which is usually the fastest way to tell a bug here apart from a Blizzard or EllesmereUI change.

## Compatibility

Works on EllesmereUI 8.6.6 and newer. On 8.6.8+ with the Blizz UI Enhanced module running, it registers through EllesmereUI's official skinning API and shows up in its Third-Party Addons list. Without that module, the same primitives are rebuilt from the public helpers EllesmereUI exports. Either way the look is identical and you don't need to do anything.

## Licence

GPLv3. This is a derivative work of [MountsJournal_ElvUI_Skin](https://github.com/sfmict/MountsJournal-ElvUI-Skin) by sfmict. The map of which frames need skinning came from there; the EllesmereUI implementation is new. Thanks to sfmict, who wrote both MountsJournal and the ElvUI skin this was translated from, and to EllesmereGaming for EllesmereUI.

Unofficial, and not affiliated with either project. Source and issues: [GitHub](https://github.com/egsherlock/MountsJournal-EllesmereUI-Skin).
