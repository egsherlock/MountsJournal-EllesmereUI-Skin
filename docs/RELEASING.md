# Releasing MountsJournal EllesmereUI Skin

## Before the tag

Any change to behaviour, appearance or wording updates the documentation in the
**same commit as the code**. A release that ships something nobody wrote down is
what this checklist exists to prevent.

- [ ] **`CHANGELOG.md`** — a new version heading and an entry for every change a
      player could notice. Never skipped: this is what CurseForge, WowUp and the
      GitHub release page show someone deciding whether to update. Voice rules
      below.
- [ ] **`README.md`** — only if the feature set or the screenshots moved.
- [ ] **`docs/curseforge-description.md`** — same test, and it reaches far more
      people than the README. Anything documented only on GitHub is invisible to
      most of the people running the addon.
- [ ] **`MountsJournal_EllesmereUI_Skin.toc`** `## Notes` — only if the one-line
      pitch changed.
- [ ] **Syntax check both Lua files.** There is no test harness and no way to run
      the game from a dev loop, so this is the one mechanical check that exists:

      ```bash
      python -c "from luaparser import ast; ast.parse(open('Backend.lua').read())"
      ```

      A syntax error means the file silently never loads.

## The changelog is written for players

It is the only documentation most users will ever read. Plain, clear English,
describing what a person actually notices.

**Lead with the effect, not the cause.** Somebody scanning the list wants to know
whether this release fixes the thing that was annoying them.

> Yes — *"Fixed: an error while scrolling the mount grid, and when the pet
> selection button was turned on."*
>
> No — *"Guard FadeRegions against Texture arguments in the facade wrapper."*

No file names, no function names, no Lua, no frame paths, no "refactored". The
*why* earns its place where it helps somebody trust a fix, or where the cause is
genuinely interesting. The mechanism does not — **commit messages are where the
mechanism goes**, and they can be as technical as they need to be.

An internal change with no visible effect still gets an entry, and it says so:
*"Nothing in the addon changed."* That is more honest than silence.

## Commit messages

Written for whoever reads the history later, which is normally us. A subject line
that says what changed, then prose explaining the mechanism and — more usefully —
why the obvious approach was not the one taken. No trailers, no co-authors, no
tool attribution: the history is the project's, not a record of how it was typed.

## Cutting the release

```bash
git tag -a vX.Y.Z -m "X.Y.Z" && git push origin vX.Y.Z
```

The workflow builds the zip, attaches it to the GitHub release, and uploads to
CurseForge (project `1633540`, key in the `CF_API_KEY` repo secret). Nothing else
is needed. Wago stays commented in the `.toc` and the workflow until that project
exists.

**Patch for fixes, minor for anything a user would call a feature.**

**CurseForge's own repository packaging must stay OFF.** The GitHub Action is the
only thing that builds and uploads; with CurseForge also watching the repo, every
tag would produce two competing files.

## Where things live

| | |
|---|---|
| What ships in the zip | `.pkgmeta` — `.github/` and `docs/` are held back |
| Changelog nomination | `.pkgmeta` → `manual-changelog` |
| CurseForge project id | the `.toc` → `## X-Curse-Project-ID` |
| CurseForge API key | GitHub repo → Settings → Secrets → `CF_API_KEY` |
| Maintainer notes | `SKINNING_NOTES.md`, gitignored on purpose |
