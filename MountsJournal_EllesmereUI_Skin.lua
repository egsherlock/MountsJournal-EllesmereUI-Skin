--[[----------------------------------------------------------------------------
	MountsJournal EllesmereUI Skin

	Reskins sfmict's MountsJournal to match EllesmereUI, following whatever
	style the user has EllesmereUI set to rather than a look of our own.

	The map of which MountsJournal frames need treatment, and the structure of
	this file, are derived from MountsJournal_ElvUI_Skin by sfmict (GPLv3).
	See LICENSE.

	Everything routes through a skinning facade (the `S` table), so frames track
	the user's live theme, window style, accent colour, UI font, panel fill,
	without this file ever knowing what that theme is. Backend.lua supplies that
	facade from EllesmereUI's own skinning API where its dispatcher is live
	(8.6.8+ with the Blizzard Skin child addon), and rebuilds it from 8.6.6's
	public helpers where it is not; this file reads the same either way. On the
	api backend three primitives stay local, Shell, ScrollBar and Checkbox,
	because the engine's versions do not reproduce this skin's look; see
	Backend.lua's HYBRID FACADE. Two primitives do not exist in API v1, sliders
	and portrait removal; both are hand-rolled against the documented getters
	and marked TODO(api-v2).

	Cost model: one-time texture setup plus hooks. No OnUpdate, no polling, no
	per-frame work.
------------------------------------------------------------------------------]]

local ADDON_NAME, ns = ...
local select, ipairs, pairs, type = select, ipairs, pairs, type
local hooksecurefunc, CreateFrame, LibStub = hooksecurefunc, CreateFrame, LibStub

-- Preconditions, captured before the early-out below so that the diagnostic can
-- still report which one failed. An addon that goes inert silently is exactly
-- what made the first round of this so hard to pin down.
--
-- Note what is NOT a precondition any more: EllesmereUI.RegisterSkin. That is
-- the fix for the bug that made this addon do nothing at all for every real
-- user, the API is on EllesmereUI's master but not in any tagged release, so
-- gating on it meant going permanently inert on 8.6.6. Backend.lua now supplies
-- the facade either way. See its header.
local haveEUI = EllesmereUI ~= nil
local haveMJ  = MountsJournal ~= nil

-- EllesmereUI's skin facade, captured when our callback fires. MountsJournal
-- builds a lot of its UI lazily (pooled rows, panels created on first open), so
-- we keep `S` and call primitives from those frames' own hooks. Every primitive
-- is idempotent, which is what makes that safe.
local S

-- LibSFDropDown, resolved at skin time; menus are opted in by name.
local lsfdd

-- EllesmereUI's house border grey. These are engine constants (the window
-- engine's Theme.brd*), not user settings, so unlike the accent colour they
-- cannot drift out from under us and are safe to state here.
local BRD_R, BRD_G, BRD_B = .2, .2, .2


--[[ FAILURE ISOLATION ---------------------------------------------------------
	EllesmereUI runs our whole skin callback inside one pcall, which is the
	right call for it (a broken third-party skin must never take the suite
	down), but it means a single bad call anywhere in here abandons everything
	after it. With scriptErrors off, as it is by default, that failure is also
	completely invisible: the journal just comes up half skinned and nothing
	says why.

	So every stage runs inside stage(), which records what happened instead of
	unwinding, and /mjeuiskin repeats it back. A failure now costs one section
	rather than the whole addon, and reports itself.
------------------------------------------------------------------------------]]
local stages, failures = {}, {}

local function stage(name, fn, ...)
	local ok, err = pcall(fn, ...)
	stages[#stages + 1] = {name = name, ok = ok}
	if not ok then failures[#failures + 1] = name .. ": " .. tostring(err) end
	return ok
end


-- hooksecurefunc raises if the field is not a function, and several
-- MountsJournal methods live inside do-blocks or only appear once a panel has
-- been built. A missing hook should cost that one feature, not the addon.
local function hook(obj, method, fn)
	if obj and type(obj[method]) == "function" then
		hooksecurefunc(obj, method, fn)
		return true
	end
	failures[#failures + 1] = ("hook %s: missing"):format(tostring(method))
	return false
end


--[[ SETTINGS ------------------------------------------------------------------
	Border style and size for the windows we skin, so users get the same
	border/glow/shadow choice EllesmereUI gives them everywhere else in the
	suite. Account-wide. "none" is the default and leaves EllesmereUI's own
	window border to speak for itself.
------------------------------------------------------------------------------]]
local DEFAULTS = {
	-- "auto" follows EllesmereUIDB's own window border, texture and size,
	-- including size 0 meaning none, so the journal carries whatever border
	-- the rest of the suite is carrying without being told twice.
	borderStyle = "auto",
	borderSize = 2,
	-- "fill" paints the window in EllesmereUI's Dark Mode colour and alpha,
	-- the value the user's whole UI shares, and the only one that can be
	-- transparent at all. "blizz" uses EllesmereUI's own window art instead, to
	-- match the Blizzard windows either side of this one.
	backdrop = "fill",
	-- Follow the Dark Mode alpha rather than an explicit override. A profile
	-- import such as atrocityUI or AES sets that to 0.80; plain EllesmereUI is
	-- 0.90. Either way the window then matches everything around it without the
	-- user configuring anything.
	followOpacity = true,
	opacity = 90,
	-- The window's outermost edge. "line" is a crisp 1px edge in the dark
	-- window-edge tone, as dark as EllesmereUI's own window frames read,
	-- without the soft inner falloff its frame atlas carries. "art" is that
	-- atlas itself, for an exact match at the cost of the falloff.
	windowBorder = "line",
}
local db = DEFAULTS

--[[ ITERATE CHILDREN WITHOUT ALLOCATING ---------------------------------------
	{frame:GetChildren()} is the idiomatic form and it builds a table every
	call. That is free when it runs once at skin time, and not free in the four
	places it runs from a ScrollBox's Update, those fire on every scroll tick,
	so dragging a mount list would produce a table per frame for the collector
	to clean up. Passing the children straight through as varargs allocates
	nothing, and reads the same at the call site.
------------------------------------------------------------------------------]]
local function eachChild(fn, ...)
	for i = 1, select("#", ...) do
		fn((select(i, ...)))
	end
end


-- Defined down in the border section, forward-declared because the diagnostic
-- below is registered at file scope, ahead of them, and closes over these
-- names. Without this the closure would bind a global instead and the border
-- line would error the moment anyone ran /mjeuiskin.
local hostBorder, resolveBorder

-- Also forward-declared: the slider frames skin their numeric entry box, and
-- they are defined above the shared widget helpers.
local editBox


--[[ DIAGNOSTICS --------------------------------------------------------------
	Registered at file scope, before anything that can fail and before the skin
	callback exists, so it answers even when nothing else ran. That matters:
	the failure mode this addon actually hit in the field was a silent one, and
	a slash command that only registers on success is no use for diagnosing a
	failure.
------------------------------------------------------------------------------]]
--[[ WHAT IS DRAWING BEHIND US ------------------------------------------------
	/mjeuiskin behind, run with the journal open.

	Three rounds of "something is still showing behind the window" were each
	diagnosed by reading source and reasoning about which frame it must be, and
	the third one was still wrong. Reasoning cannot settle this: the answer
	depends on what a particular EllesmereUI build skinned, in what order, on
	this user's settings, and none of that is visible from the source alone.

	So stop inferring and measure. This walks everything behind the window and
	reports each visible texture with its screen rect, biggest first. The
	offending pane is then identified by matching its geometry to what is
	actually on screen, rather than by another guess.
------------------------------------------------------------------------------]]
-- Assigned further down, once the suppression registry exists. Lets the report
-- separate "we never matched this" from "we matched it and something put it
-- back", two very different bugs that look identical on screen.
local isSuppressed


local function texDesc(tex)
	local ok, atlas = pcall(function() return tex.GetAtlas and tex:GetAtlas() end)
	if ok and atlas then return "atlas:" .. atlas end
	local ok2, file = pcall(function() return tex.GetTexture and tex:GetTexture() end)
	if ok2 and type(file) == "string" then
		return (file:match("[^\\/]+$")) or file
	elseif ok2 and file then
		return "fileID:" .. tostring(file)
	end
	return "colour"
end


-- Name if it has one, otherwise the parentKey chain, so unnamed Blizzard and
-- EllesmereUI frames can still be identified in the output.
local function framePath(frame, depth)
	if not frame or (depth or 0) > 6 then return "?" end
	local ok, name = pcall(function() return frame.GetName and frame:GetName() end)
	if ok and name then return name end
	local ok2, parent = pcall(function() return frame:GetParent() end)
	if not (ok2 and parent) then return "?" end
	local key
	pcall(function()
		for k, v in pairs(parent) do
			if type(k) == "string" and v == frame then key = k; break end
		end
	end)
	return framePath(parent, (depth or 0) + 1) .. "." .. (key or "?")
end


-- Floored by default, which is what the overlap tests want. `precise`
-- returns the values to four decimals as strings, for the tab report: a
-- fractional frame height that floors away is exactly what moved the
-- Collections row's labels, and a probe that rounds cannot see it.
local function rectOf(obj, precise)
	local ok, l, b, w, h = pcall(function()
		return obj:GetLeft(), obj:GetBottom(), obj:GetWidth(), obj:GetHeight()
	end)
	if not ok or not l or not w then return nil end
	if issecretvalue and (issecretvalue(l) or issecretvalue(w)) then return nil end
	if precise then
		local function f(v) return (("%.4f"):format(v or 0):gsub("%.?0+$", "")) end
		return f(l), f(b), f(w), f(h)
	end
	return math.floor(l), math.floor(b or 0), math.floor(w), math.floor(h or 0)
end


local function reportBehind()
	local journal = MountsJournalFrame
	local bgFrame = journal and journal.bgFrame
	if not (bgFrame and bgFrame:IsShown()) then
		print("  |cffff5555Open the mounts journal first, then run this again.|r")
		return
	end

	local l, b, w, h = rectOf(bgFrame)
	print(("  our window: %dx%d at %d,%d"):format(w or 0, h or 0, l or 0, b or 0))
	for _, f in ipairs({CollectionsJournal, MountJournal}) do
		if f then
			local fl, fb, fw, fh = rectOf(f)
			print(("  %s: %dx%d at %d,%d shown=%s"):format(framePath(f),
				fw or 0, fh or 0, fl or 0, fb or 0, tostring(f:IsShown())))
		end
	end

	-- Everything under our own window is ours and never the answer.
	local skip = {}
	if bgFrame then skip[bgFrame] = true end
	if journal.useMountsJournalButton then skip[journal.useMountsJournalButton] = true end

	local found = {}
	local function walk(frame, depth)
		if depth > 5 or skip[frame] then return end
		local shown = frame.IsShown and frame:IsShown()
		if shown == false then return end
		if frame.GetRegions then
			for i = 1, select("#", frame:GetRegions()) do
				local r = select(i, frame:GetRegions())
				local okType = r and r.IsObjectType and r:IsObjectType("Texture")
				if okType and r:IsShown() and (r:GetAlpha() or 0) > .05 then
					local rl, rb, rw, rh = rectOf(r)
					-- Hairline strips count too. Requiring BOTH dimensions to
					-- be large filtered out every border strip, so the report
					-- claimed nothing was visible while a Collections-sized
					-- outline was plainly on screen.
					if rw and (rw > 80 or rh > 80) then
						found[#found + 1] = {
							area = rw * rh, w = rw, h = rh, x = rl, y = rb,
							alpha = r:GetAlpha(), desc = texDesc(r),
							owner = framePath(frame),
							known = isSuppressed and isSuppressed(r),
						}
					end
				end
			end
		end
		if frame.GetChildren then
			for i = 1, select("#", frame:GetChildren()) do
				local c = select(i, frame:GetChildren())
				if c and not c:IsForbidden() then walk(c, depth + 1) end
			end
		end
	end
	if CollectionsJournal then walk(CollectionsJournal, 1) end

	table.sort(found, function(x, y) return x.area > y.area end)
	if #found == 0 then
		print("  |cff44ff44Nothing visible behind the window.|r")
		print("  If a pane is still on screen it is being drawn by our own")
		print("  frames, not by Blizzard's or EllesmereUI's.")
		return
	end

	print(("  |cffffff00%d visible textures behind the window|r (largest first):"):format(#found))
	for i = 1, math.min(#found, 20) do
		local e = found[i]
		print(("   %dx%d at %d,%d a=%.2f  %s  <%s>%s")
			:format(e.w, e.h, e.x, e.y, e.alpha, e.desc, e.owner,
				e.known and " |cffff5555[we faded this, it came back]|r" or ""))
	end
end


--[[ WHICH LOOK DOES THE COLLECTIONS ROW WEAR ----------------------------------
	Three possibilities on a given client, decided without needing the
	Collections window to have been opened:

	  "atrocity"  atrocityEssentials is loaded. It skins Collections' tabs
	              (Skinning/Frames/Collectables.lua) with a BackdropTemplate
	              plate under each one, and that is the look the row wears.
	  "eui"       no atrocityEssentials, and the Collections row carries
	              EllesmereUI's own Tab primitive: a tab the engine has
	              dressed carries two labels (Blizzard's hidden one and the
	              engine's), a stock one carries one.
	  "blizzard"  neither. The row is stock 12.x Blizzard art.

	Measured, not inferred (Rematch skin, 2026-09-19): with atrocityEssentials
	off, the Collections row on that client was plain Blizzard even with
	EllesmereUI's Collections window skin on, so the engine's window style
	says nothing about the tabs. Only the row itself does. Until the
	Collections window exists the answer is "blizzard", and the paint
	re-asks.
------------------------------------------------------------------------------]]
local function collectionsTabStyle()
	if _G.atrocityEssentials then return "atrocity" end
	local ref = CollectionsJournal and CollectionsJournal.MountsTab
	if ref and ref.GetRegions then
		local labels = 0
		for i = 1, select("#", ref:GetRegions()) do
			local r = select(i, ref:GetRegions())
			if r and r.IsObjectType and r:IsObjectType("FontString") then labels = labels + 1 end
		end
		if labels >= 2 then return "eui" end
	end
	return "blizzard"
end


--[[ HOW DOES THE ROW NEXT TO US ACTUALLY LOOK ---------------------------------
	/mjeuiskin tabs, run with the journal open.

	Our tabs are meant to match Collections' own row directly beside them, and
	whether they do depends on something not readable from source: which
	addon, if any, skinned that row on this client (see collectionsTabStyle).
	Rather than guess, print every tab with its geometry, its label's seat
	and font, and its visible art, and let the comparison settle it.

	Run it twice, once on another Collections tab and once on Mounts, and
	the difference between the two dumps says what moved: the tab itself
	(MountsJournal re-anchors CollectionsJournalTab1 to its own window
	whenever that window shows, and the whole row hangs off Tab1), the
	label within the tab (PanelTemplates seats it at a different y per
	selection state), or only its font (a state font object re-applied).
------------------------------------------------------------------------------]]
local function dumpTab(label, tab)
	if not tab then
		print(("  %s: |cffff5555missing|r"):format(label))
		return
	end
	local bits = {}
	for i = 1, select("#", tab:GetRegions()) do
		local r = select(i, tab:GetRegions())
		if r and r.IsObjectType and r:IsObjectType("FontString") then
			local ok, cr, cg, cb, ca = pcall(r.GetTextColor, r)
			local text = (r.GetText and r:GetText()) or ""
			if ok and cr then
				bits[#bits + 1] = ("'%s' %.2f/%.2f/%.2f a=%.2f")
					:format(text, cr, cg, cb, ca or 1)
			end
		end
	end
	-- Geometry first, so two rows can be compared for spacing, height and
	-- seat by subtraction rather than by eye. Two decimals, not floored:
	-- the label wobble turned out to live in the fourth decimal of a frame
	-- height, and floored numbers said the two rows were identical.
	local l, b, w, h = rectOf(tab, true)
	print(("  %s [%s] %sx%s at %s,%s: %s"):format(label,
		tab:IsShown() and "shown" or "hidden",
		tostring(w), tostring(h), tostring(l), tostring(b),
		#bits > 0 and table.concat(bits, "  ") or "no FontString"))

	-- The label's own seat and face. A label that has moved while its tab
	-- has not is PanelTemplates re-seating it (a different y per selection
	-- state); a label whose font has changed is a state font object being
	-- re-applied. Both read as "the text shifted" from across the room.
	local text = tab.Text or (tab.GetFontString and tab:GetFontString())
	if text and text.GetPoint then
		local tl, tb, tw, th = rectOf(text, true)
		local okP, point, _, relPoint, x, y = pcall(text.GetPoint, text, 1)
		local seat = (okP and point)
			and ("%s->%s %s,%s"):format(tostring(point), tostring(relPoint), tostring(x), tostring(y))
			or "?"
		local font = "?"
		local okF, face, size, flags = pcall(text.GetFont, text)
		if okF and type(face) == "string" then
			if issecretvalue and issecretvalue(size) then size = "secret" end
			font = ("%s %s %s"):format(face:match("[^\\/]+$") or face,
				tostring(size), tostring(flags or ""))
		end
		print(("      label %sx%s at %s,%s  seat %s  font %s"):format(
			tostring(tw), tostring(th), tostring(tl), tostring(tb), seat, font))
	end

	-- The labels matched once the colours did, so whatever still differs is in
	-- the plate behind them. Print the visible textures too rather than
	-- squinting at a screenshot for a third time.
	local tex = {}
	for i = 1, select("#", tab:GetRegions()) do
		local r = select(i, tab:GetRegions())
		if r and r.IsObjectType and r:IsObjectType("Texture")
			and r:IsShown() and (r:GetAlpha() or 0) > .01 then
			local _, _, w, h = rectOf(r)
			-- Vertex colour as well as size and alpha. Without it a texture
			-- with no file reads as "colour" and says nothing about whether
			-- it is a dark plate or a white one, which is the difference
			-- between a tab and a haze.
			local okC, cr, cg, cb, ca = pcall(r.GetVertexColor, r)
			local col = okC and cr
				and ("%.2f/%.2f/%.2f a=%.2f"):format(cr, cg, cb, ca or 1)
				or "?"
			tex[#tex + 1] = ("%s %sx%s regionA=%.2f rgba %s")
				:format(texDesc(r), tostring(w), tostring(h), r:GetAlpha(), col)
		end
	end
	if #tex > 0 then print("      art: " .. table.concat(tex, " | ")) end
end


local function reportTabs()
	local collect = CollectionsJournal
	local bgFrame = MountsJournalFrame and MountsJournalFrame.bgFrame
	print("  Collections row wears: " .. collectionsTabStyle())

	-- The two frames the rows hang off. MountsJournal re-anchors Collections'
	-- first tab from one to the other as its window shows and hides, so if
	-- their bottom edges differ, the whole Collections row moves with it.
	for _, pair in ipairs({{"CollectionsJournal", collect}, {"bgFrame", bgFrame}}) do
		if pair[2] then
			local l, b, w, h = rectOf(pair[2], true)
			print(("  %s %sx%s at %s,%s"):format(pair[1], tostring(w), tostring(h), tostring(l), tostring(b)))
		end
	end
	local t1 = CollectionsJournalTab1
	if t1 and t1.GetPoint then
		local ok, point, rel, relPoint, x, y = pcall(t1.GetPoint, t1, 1)
		if ok and point then
			local relName = rel and ((rel.GetName and rel:GetName()) or tostring(rel)) or "nil"
			print(("  CollectionsJournalTab1 anchored %s -> %s %s at %s,%s"):format(
				tostring(point), relName, tostring(relPoint), tostring(x), tostring(y)))
		end
	end

	print("  |cffffff00Collections' own row|r (what we should match):")
	if collect then
		for _, key in ipairs({"MountsTab", "PetsTab", "ToysTab", "HeirloomsTab",
			"WardrobeTab", "WarbandScenesTab"}) do
			if collect[key] then dumpTab("CollectionsJournal." .. key, collect[key]) end
		end
		if type(collect.Tabs) == "table" then
			for i = 1, #collect.Tabs do
				dumpTab(("CollectionsJournal.Tabs[%d]"):format(i), collect.Tabs[i])
			end
		end
	end

	print("  |cffffff00Ours|r:")
	if bgFrame and type(bgFrame.Tabs) == "table" then
		for i = 1, #bgFrame.Tabs do
			local tab = bgFrame.Tabs[i]
			local left = tab and tab.GetLeft and tab:GetLeft()
			dumpTab(("bgFrame.Tabs[%d] left=%s"):format(i, tostring(left and math.floor(left))), tab)
		end
	end
end


-- /mjeuiskin list: the left column's geometry, to four decimals, so a
-- clipped row or a misaligned edge is a subtraction rather than a guess.
local function reportList()
	local journal = MountsJournalFrame
	local bgFrame = journal and journal.bgFrame
	if not bgFrame then print("  no journal window") return end
	local function line(label, obj)
		if not obj then print(("  %s: missing"):format(label)) return end
		local l, b, w, h = rectOf(obj, true)
		local shown = obj.IsShown and (obj:IsShown() and "shown" or "hidden") or ""
		print(("  %s [%s] %sx%s at %s,%s"):format(label, shown,
			tostring(w), tostring(h), tostring(l), tostring(b)))
	end
	line("bgFrame", bgFrame)
	line("CollectionsJournal", CollectionsJournal)
	line("navBar", journal.navBar)
	line("filtersPanel", journal.filtersPanel)
	line("shownPanel", journal.shownPanel)
	line("leftInset", bgFrame.leftInset)
	line("plate", journal.euiListPlate)
	local box = journal.scrollBox
	line("scrollBox", box)
	line("scrollBox.ScrollTarget", box and box.ScrollTarget)
	line("scrollBar", bgFrame.leftInset and bgFrame.leftInset.scrollBar)
	if box and box.ScrollTarget then
		local row = (select(1, box.ScrollTarget:GetChildren()))
		line("first row", row)
		if row then
			line("  row.dragButton", row.dragButton)
			line("  row.fly", row.fly)
			line("  row.swimming", row.swimming)
			line("  row.name", row.name)
		end
	end
	print(("  view: curGrid=%s gridN=%s"):format(tostring(journal.curGrid), tostring(journal.gridN)))
	line("summonButton", journal.summonButton)
	line("profilesMenu", bgFrame.profilesMenu)
	line("useMountsJournalButton", journal.useMountsJournalButton)
	line("RematchFrame", RematchFrame)
	if RematchFrame then
		line("RematchFrame.Canvas", RematchFrame.Canvas)
		local pets = RematchFrame.PetsPanel
		line("Rematch PetsPanel", pets)
		line("Rematch PetsPanel.List", pets and pets.List)
		line("Rematch bottombar", RematchFrame.BottomBar or _G.RematchBottomBar)
	end
end


-- /mjeuiskin pet: every frame and shown texture on the mount info panel's
-- pet button, with frame level, draw layer and sublevel, colour and size,
-- so "what draws over the favourite star" is read off rather than guessed.
local function reportPet()
	local journal = MountsJournalFrame
	local info = journal and journal.mountDisplay and journal.mountDisplay.info
	local btn = info and info.petSelectionBtn
	if not btn then print("  no pet button (open the journal in list view)") return end
	local function walk(frame, label, depth)
		if depth > 4 or not frame.GetRegions then return end
		local l, b, w, h = rectOf(frame, true)
		print(("  %s%s level=%s %sx%s at %s,%s%s"):format(("  "):rep(depth), label,
			tostring(frame:GetFrameLevel()), tostring(w), tostring(h), tostring(l), tostring(b),
			frame:IsShown() and "" or " [hidden]"))
		for i = 1, select("#", frame:GetRegions()) do
			local r = select(i, frame:GetRegions())
			if r and r.IsObjectType and r:IsShown() and (r:GetAlpha() or 0) > .01 then
				local layer, sub = r:GetDrawLayer()
				local key = "?"
				for k, v in pairs(frame) do if v == r and type(k) == "string" then key = k break end end
				if r:IsObjectType("Texture") then
					local rl, rb, rw, rh = rectOf(r, true)
					local ok, cr, cg, cb, ca = pcall(r.GetVertexColor, r)
					print(("  %s  tex %s %s/%s %sx%s at %s,%s a=%.2f rgb %s %s"):format(("  "):rep(depth),
						key, tostring(layer), tostring(sub), tostring(rw), tostring(rh), tostring(rl), tostring(rb),
						r:GetAlpha(), ok and cr and ("%.2f/%.2f/%.2f"):format(cr, cg, cb) or "?", texDesc(r)))
				elseif r:IsObjectType("FontString") then
					print(("  %s  text %s %s/%s '%s'"):format(("  "):rep(depth), key,
						tostring(layer), tostring(sub), tostring(r:GetText() or "")))
				end
			end
		end
		for i = 1, select("#", frame:GetChildren()) do
			local child = select(i, frame:GetChildren())
			if child and not child:IsForbidden() then
				local key = "?"
				for k, v in pairs(frame) do if v == child and type(k) == "string" then key = k break end end
				walk(child, key, depth + 1)
			end
		end
	end
	walk(btn, "petSelectionBtn", 0)
end


SLASH_MJEUISKIN1 = "/mjeuiskin"
SlashCmdList.MJEUISKIN = function(msg)
	local function yn(v) return v and "|cff44ff44yes|r" or "|cffff5555NO|r" end
	print("|cff0bd29dMountsJournal EllesmereUI Skin|r")

	if type(msg) == "string" and msg:lower():find("behind") then
		reportBehind()
		return
	end
	if type(msg) == "string" and msg:lower():find("list") then
		reportList()
		return
	end
	if type(msg) == "string" and msg:lower():find("pet") then
		reportPet()
		return
	end
	if type(msg) == "string" and msg:lower():find("tabs") then
		reportTabs()
		return
	end

	-- Versions, so a bug report carries the one variable every path-based
	-- stage depends on. Resolved only when the command runs; this costs the
	-- addon nothing. Deliberately above the inert bail-out, an inert report
	-- needs them most.
	do
		local getMeta = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
		if getMeta then
			local function ver(name)
				local ok, v = pcall(getMeta, name, "Version")
				return (ok and v) or "?"
			end
			print(("  versions: skin %s, MountsJournal %s, EllesmereUI %s"):format(
				ver(ADDON_NAME), ver("MountsJournal"), ver("EllesmereUI")))
		end
	end

	if not (haveEUI and haveMJ) then
		print("  |cffff5555Addon is inert. A precondition was missing at load.|r")
		print("  EllesmereUI loaded:", yn(haveEUI))
		print("  MountsJournal loaded:", yn(haveMJ))
		return
	end

	local backendNote
	if ns.GetBackend() == "api" then
		backendNote = "(EllesmereUI's skinning API; shell, scroll bars and checkboxes drawn locally)"
	elseif ns.HasAPI() then
		-- The stub exists but nothing will ever fire it: the parent ships
		-- RegisterSkin as a documented no-op when the child addon is off.
		backendNote = "(API stub present but EllesmereUIBlizzardSkin is not running; using 8.6.6 helpers)"
	else
		backendNote = "(rebuilt from 8.6.6 helpers; update EllesmereUI for the native one)"
	end
	print("  backend:", ns.GetBackend(), backendNote)

	if not S then
		print("  |cffff5555The skin callback never ran.|r")
		print("  It is dispatched at PLAYER_LOGIN. On the api backend, check")
		print("  EllesmereUI options > Blizz UI Enhanced > Blizzard Window")
		print("  Skins > Third-Party Addons.")
		return
	end

	print("  style:", S.GetStyle(), " skinning enabled:", yn(S.IsEnabled()))
	local j = MountsJournalFrame
	print("  MountsJournalFrame:", yn(j), " bgFrame:", yn(j and j.bgFrame))
	print("  journal skinned:", yn(j and j.euiInit))
	print("  dropdown menu style:", yn(lsfdd))
	do
		local key, size = resolveBorder()
		local hostKey, hostSize = hostBorder()
		print(("  border: %s %s -> %s %s   (EllesmereUI's own: %s %s)"):format(
			tostring(db.borderStyle), tostring(db.borderSize),
			tostring(key), tostring(size), tostring(hostKey), tostring(hostSize)))
	end

	-- The numbers that decide what the window looks like. If the skin ever
	-- looks unlike the rest of the suite again, this is the line that says why:
	-- it prints what EllesmereUI reports as the shared baseline alongside what
	-- we actually painted, so the two can be compared without guessing from a
	-- screenshot.
	if ns.CanStyleShell and ns.CanStyleShell() and ns.GetShellAppearance then
		local floor = math.floor
		local mode, alpha, r, g, b, a, edge = ns.GetShellAppearance()
		print(("  backdrop: %s at %d%% opacity, edge: %s")
			:format(mode, floor(alpha * 100 + .5), tostring(edge)))
		print(("  EllesmereUI Dark Mode fill: #%02x%02x%02x at %d%%"):format(
			floor(r * 255 + .5), floor(g * 255 + .5), floor(b * 255 + .5),
			floor((a or 0) * 100 + .5)))
	else
		print("  backdrop: drawn by EllesmereUI (the api backend owns the shell)")
	end

	local line = "  stages:"
	for i = 1, #stages do
		line = line .. " " .. stages[i].name .. (stages[i].ok and "=ok" or "=|cffff5555FAIL|r")
	end
	print(line)

	if #failures == 0 then
		print("  no failures recorded")
	else
		print("  |cffff5555failures:|r")
		for i = 1, #failures do print("   ", failures[i]) end
	end

	print("  |cff888888/mjeuiskin behind|r lists what is still drawing behind")
	print("  |cff888888the window, largest first.|r")
	print("  |cff888888/mjeuiskin tabs|r compares our tab labels against")
	print("  |cff888888Collections' own row beside them.|r")
end



-- Registering a skin is free, so this is the only gate we need. Hard TOC
-- dependencies cover the case where either addon is absent; the checks keep us
-- inert regardless, but the diagnostic above is already registered, so an
-- inert addon can still say so.
if not (haveEUI and haveMJ) then return end


local function resolveDB()
	if type(MountsJournalEllesmereUISkinDB) ~= "table" then
		MountsJournalEllesmereUISkinDB = {}
	end
	db = MountsJournalEllesmereUISkinDB
	for k, v in pairs(DEFAULTS) do
		if db[k] == nil then db[k] = v end
	end

	-- One-time correction. v1.0.9 shipped with the window edge defaulting to
	-- the frame atlas, which brought back the soft inner falloff it was meant
	-- to avoid. Changing the default alone does not help anyone who ran that
	-- build: resolveDB only fills in keys that are missing, and theirs is
	-- already set to "art". Move those back once, then never touch it again,
	-- so a deliberate choice of "art" made after this point still sticks.
	if not db.edgeDefaultFixed then
		db.edgeDefaultFixed = true
		if db.windowBorder == "art" then db.windowBorder = DEFAULTS.windowBorder end
	end
end


-- Push the window appearance into the backend. Safe to call before any window
-- exists: it records the choice, and the shell reads it as it is built.
local function applyShell()
	if not (ns.CanStyleShell and ns.CanStyleShell()) then return end
	local alpha
	if not db.followOpacity then alpha = (tonumber(db.opacity) or 90) / 100 end
	ns.SetShellAppearance(db.backdrop, alpha, db.windowBorder)
end


--[[ BORDER STYLE --------------------------------------------------------------
	EllesmereUI's shared border engine, the same texture list, size steps and
	Glow/Shadow entries as the Border Style pickers in Damage Meters and the
	unit frames. ApplyBorderStyle draws onto a host frame the *caller* owns, so
	each window we border gets an empty frame of ours pinned over it.
------------------------------------------------------------------------------]]
-- Weak keys throughout these registries. Every one is keyed by a frame or a
-- texture we do not own, and several of those come from pools that
-- MountsJournal recycles, so a strong key here would pin a released widget
-- alive for the session. Nothing needs the entry once the widget is gone.
local borderHosts = setmetatable({}, {__mode = "k"})


--[[ FOLLOW THE USER'S OWN WINDOW BORDER ----------------------------------------
	EllesmereUI stores the border it puts on its own windows, Damage Meters
	and friends, as two account-wide keys, and the Border Style pickers
	throughout the suite write them. Reading them is what makes "Follow
	EllesmereUI" mean something rather than being a second, unrelated setting
	the user has to keep in sync by hand. Postbox does exactly this.

	  EllesmereUIDB.windowBorderTexture   "solid", "glow", "shadow", "sm:<name>"
	  EllesmereUIDB.windowBorderSize      step 1-4; 0 means no border at all

	Read-only, and re-read on every call, so changing it in EllesmereUI's own
	options and reopening the journal is enough, there is nothing to import.
	Note size 0 is a real answer, not a missing one: plenty of setups run with
	no window border, and honouring that is the whole point.
------------------------------------------------------------------------------]]
function hostBorder()
	local edb = EllesmereUIDB
	if type(edb) ~= "table" then return "none", 2 end
	local size = tonumber(edb.windowBorderSize)
	local tex = edb.windowBorderTexture
	if size == nil and tex == nil then return "none", 2 end
	if (size or 0) <= 0 then return "none", 2 end
	return tex or "solid", math.max(1, math.min(4, size))
end


-- What the picker resolves to right now: the user's own EllesmereUI setting
-- when it is on "auto", otherwise whatever they chose here.
function resolveBorder()
	if db.borderStyle == "auto" then return hostBorder() end
	return db.borderStyle, db.borderSize or 2
end


local function applyBorder(frame)
	local host = borderHosts[frame]
	if not host then
		host = CreateFrame("Frame", nil, frame)
		host:SetAllPoints(frame)
		host:EnableMouse(false)
		borderHosts[frame] = host
	end

	if not EllesmereUI.ApplyBorderStyle then return end

	local key, size = resolveBorder()
	if not key or key == "none" then
		-- Size 0 tears down whichever implementation (solid or textured) is
		-- currently live on the host.
		EllesmereUI.ApplyBorderStyle(host, 0, 0, 0, 0, 1, "solid")
		host:Hide()
		return
	end

	local colour, behind = EllesmereUI.GetBorderStyleSelectDefaults(key)
	local level = frame:GetFrameLevel()
	-- Shadow only reads as depth when it sits *under* the window it hugs;
	-- everything else goes above EllesmereUI's own window border overlay.
	host:SetFrameLevel(behind and (level > 0 and level - 1 or 0) or level + 7)
	host:Show()
	EllesmereUI.ApplyBorderStyle(host, size, colour.r, colour.g, colour.b, 1, key)
end


-- Windows opt in as they are skinned; the picker replays over all of them.
local function addBorder(frame)
	if frame and not borderHosts[frame] then applyBorder(frame) end
end


local function refreshBorders()
	for frame in pairs(borderHosts) do applyBorder(frame) end
end


--[[ LIVE-COLOURED ELEMENTS ----------------------------------------------------
	Anything we colour ourselves via the getters has to be repainted when the
	user changes their accent or theme, so each such element goes into one of
	these registries and S.OnLooksChanged replays them. Getter results are never
	cached; they are re-read inside the paint functions.
------------------------------------------------------------------------------]]

-- Selection tints (accent wash behind a checked or selected element).
local washes = setmetatable({}, {__mode = "k"})

local function paintWash(tex, alpha)
	local r, g, b = S.GetAccentColor()
	tex:SetColorTexture(r, g, b, alpha)
end

local function addWash(tex, alpha)
	if not tex then return end
	alpha = alpha or .25
	washes[tex] = alpha
	paintWash(tex, alpha)
end


-- Borders whose colour carries information: item quality, current selection,
-- hover. S.SquareIcon draws a fixed black 1px border and is one-shot, so rows
-- that encode state in their border need one we can repaint.
local stateBorders = setmetatable({}, {__mode = "k"})


-- Where an edge draws in the stack. An edge around an ICON must sit above
-- the icon and below whatever the button lays over it: the favourite star
-- (OVERLAY), the weight badge, the "hidden" cross. So it goes on a host at
-- the parent's own frame level, where regions from the two frames
-- interleave by draw layer (the engine's border container does the same),
-- in the icon's OWN layer one sublevel up. Not the next layer: the pet
-- icon is ARTWORK and its star OVERLAY, and strips at OVERLAY sub 0 drew
-- over a star at OVERLAY sub 2, because sublevels are not honoured across
-- frames within a layer, layers are. A host one level up would draw above
-- everything on the button. An edge around a whole frame keeps the
-- top-of-everything placement. Lifted from the Rematch skin, which hit
-- the same thing with its level badges.
local NEXT_LAYER = {BACKGROUND = "BORDER", BORDER = "ARTWORK", ARTWORK = "OVERLAY"}

-- onParent: draw the strips as regions of `parent` itself, anchored to the
-- icon, rather than on a host frame. For the pet icons (MJPetInfo): the
-- icon is ARTWORK and the star OVERLAY on the same frame, and a host at
-- that frame's level still drew above the star whatever layer its strips
-- used, while the mount icons (icon and star on the drag button, host a
-- child of it) came out right with the same code. Whatever the engine's
-- rule for that case is, same-frame ordering is defined: a region one
-- sublevel above the icon is above the icon and below the star, always.
-- Safe because MJPetInfo is never handed to an engine primitive, so no
-- restrip pass can reach regions we put on it.
local function newEdges(parent, region, pad, onParent)
	pad = pad or 0

	-- The strips live on a child frame of ours rather than directly on the
	-- host. EllesmereUI re-fades every unprotected region of a skinned frame
	-- when it restrips (it does so whenever Collections is shown, which is our
	-- window), and only regions it knows about survive. Putting ours on a
	-- frame of our own puts them out of reach entirely, the same shape the
	-- suite's own PP border container uses, and for the same reason.
	local layer, sub = "OVERLAY", 7
	local level = parent:GetFrameLevel() + 1
	local iconLayer, iconSub
	if region ~= parent and region.GetDrawLayer then iconLayer, iconSub = region:GetDrawLayer() end
	if iconLayer and NEXT_LAYER[iconLayer] then
		iconSub = tonumber(iconSub) or 0
		if iconSub < 7 then
			layer, sub = iconLayer, iconSub + 1
		else
			layer, sub = NEXT_LAYER[iconLayer], 0
		end
		level = parent:GetFrameLevel()
	end

	local owner, host
	if onParent and region ~= parent then
		owner, host = parent, region
	else
		host = CreateFrame("Frame", nil, parent)
		host:SetAllPoints(region)
		host:EnableMouse(false)
		host:SetFrameLevel(level)
		owner = host
	end

	local edges = {}
	for i = 1, 4 do
		local t = owner:CreateTexture(nil, layer, nil, sub)
		t:SetColorTexture(BRD_R, BRD_G, BRD_B, 1)
		edges[i] = t
	end
	local top, bottom, left, right = edges[1], edges[2], edges[3], edges[4]
	top:SetPoint("TOPLEFT", host, "TOPLEFT", -pad, pad)
	top:SetPoint("TOPRIGHT", host, "TOPRIGHT", pad, pad)
	top:SetHeight(1)
	bottom:SetPoint("BOTTOMLEFT", host, "BOTTOMLEFT", -pad, -pad)
	bottom:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", pad, -pad)
	bottom:SetHeight(1)
	left:SetPoint("TOPLEFT", host, "TOPLEFT", -pad, pad)
	left:SetPoint("BOTTOMLEFT", host, "BOTTOMLEFT", -pad, -pad)
	left:SetWidth(1)
	right:SetPoint("TOPRIGHT", host, "TOPRIGHT", pad, pad)
	right:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", pad, -pad)
	right:SetWidth(1)
	return edges
end


local function paintState(state)
	local r, g, b
	if state.hovered then
		r, g, b = 1, 1, 1
	elseif state.selected then
		r, g, b = S.GetAccentColor()
	elseif state.quality then
		r, g, b = state.quality[1], state.quality[2], state.quality[3]
	else
		r, g, b = BRD_R, BRD_G, BRD_B
	end
	local edges = state.edges
	for i = 1, 4 do edges[i]:SetColorTexture(r, g, b, 1) end
end


local function newState(parent, region, pad, onParent)
	local state = {edges = newEdges(parent, region, pad, onParent)}
	stateBorders[state] = true
	return state
end


local function bindHover(btn, state)
	btn:HookScript("OnEnter", function() state.hovered = true; paintState(state) end)
	btn:HookScript("OnLeave", function() state.hovered = nil; paintState(state) end)
end


local function bindSelected(state, selectedTexture)
	if not selectedTexture then return end
	local function pull()
		state.selected = selectedTexture:IsShown() or nil
		paintState(state)
	end
	hook(selectedTexture, "SetShown", pull)
	hook(selectedTexture, "Show", pull)
	hook(selectedTexture, "Hide", pull)
	pull()
end


local function bindQuality(state, qualityBorder)
	if not qualityBorder then return end
	qualityBorder:SetAlpha(0)
	local function pull()
		if qualityBorder:IsShown() then
			local r, g, b = qualityBorder:GetVertexColor()
			state.quality = {r, g, b}
		else
			state.quality = nil
		end
		paintState(state)
	end
	hook(qualityBorder, "SetVertexColor", pull)
	hook(qualityBorder, "Show", pull)
	hook(qualityBorder, "Hide", pull)
	pull()
end


--[[ SLIDERS -------------------------------------------------------------------
	TODO(api-v2): EllesmereUI's API v1 has no slider primitive; the ElvUI
	reference uses one in twelve places. Hand-rolled from the documented getters
	until one ships, ask Ellesmere for S.Slider and swap this out when it
	lands. Track takes the house panel fill, thumb the accent, and both repaint
	from S.OnLooksChanged so a live accent change reaches them.
------------------------------------------------------------------------------]]
local sliders = setmetatable({}, {__mode = "k"})


local function paintSlider(slider)
	local track = sliders[slider]
	if track then
		-- Not the panel fill. A track painted in the same colour as the panel
		-- it lies on is invisible by construction, which is what made the
		-- mounts-per-row slider so hard to find. A groove has to read against
		-- its surroundings, so this is a light tint instead, the same idea as
		-- the scroll bar thumb, one step quieter.
		track:SetColorTexture(1, 1, 1, .18)
	end
	local thumb = slider.GetThumbTexture and slider:GetThumbTexture()
	if thumb then
		local r, g, b = S.GetAccentColor()
		thumb:SetColorTexture(r, g, b, 1)
	end
end


local function skinSlider(slider)
	if not slider or sliders[slider] then return end

	local thumb = slider.GetThumbTexture and slider:GetThumbTexture()

	-- Alpha-only art removal, the same policy the primitives follow. Nothing is
	-- ever Hide()n and the thumb is left addressable.
	local function fade(frame)
		if not frame or not frame.GetRegions then return end
		for i = 1, select("#", frame:GetRegions()) do
			local r = select(i, frame:GetRegions())
			if r ~= thumb and r.IsObjectType and r:IsObjectType("Texture") then
				r:SetAlpha(0)
			end
		end
	end
	fade(slider)
	-- MinimalSliderTemplate keeps some of its track art in child frames.
	for i = 1, select("#", slider:GetChildren()) do
		fade(select(i, slider:GetChildren()))
	end

	local track = slider:CreateTexture(nil, "BACKGROUND")
	track:SetPoint("LEFT")
	track:SetPoint("RIGHT")
	track:SetHeight(4)
	sliders[slider] = track

	if thumb then thumb:SetSize(8, 16) end
	paintSlider(slider)
end


-- MJSliderFrameTemplate: the slider plus the small numeric edit box beside it.
local function skinSliderFrame(frame)
	if not frame then return end
	skinSlider(frame.slider)
	if frame.edit then editBox(frame.edit) end
	if frame.slider and frame.slider.text then S.Font(frame.slider.text) end
end


-- The bottom tab row repaints from here too; it reads its colours live off
-- the neighbouring Collections row. Declared up here because that section
-- comes later in the file, and assigned there as `function repaintBottomTabs`
-- (never `local function`, which would bind a second, unrelated local).
local repaintBottomTabs

local function looksChanged()
	for tex, alpha in pairs(washes) do paintWash(tex, alpha) end
	for state in pairs(stateBorders) do paintState(state) end
	for slider in pairs(sliders) do paintSlider(slider) end
	if repaintBottomTabs then repaintBottomTabs() end
end


--[[ DROPDOWN MENUS ------------------------------------------------------------
	MountsJournal's menus come from LibSFDropDown, which lets a skin register a
	named backdrop style through its public CreateMenuStyle. We register one and
	opt MountsJournal's own dropdowns into it by name.

	Deliberately NOT calling SetDefaultStyle/SetMenuStyle: those are
	library-global and would restyle the menus of every other addon embedding
	the library, which is outside this addon's remit.
------------------------------------------------------------------------------]]
local DD_STYLE = "EllesmereUI"


local function setupMenuStyle()
	-- Idempotent: once the library is resolved and the style registered,
	-- calling again is a no-op. That matters because this runs twice, see the
	-- second call site in skinUI for why.
	if lsfdd then return end
	-- Resolved by prefix rather than a pinned version so a library bump in
	-- MountsJournal does not silently drop the menu skin.
	if LibStub and LibStub.IterateLibraries then
		for name, lib in LibStub:IterateLibraries() do
			if type(name) == "string" and name:find("^LibSFDropDown%-") then
				lsfdd = lib
				break
			end
		end
	end
	if not (lsfdd and lsfdd.CreateMenuStyle) then return end

	-- Returns false when the name is already taken; either way the style then
	-- exists and ddSetDisplayMode can reach it.
	lsfdd:CreateMenuStyle(DD_STYLE, function(parent)
		local f = CreateFrame("Frame", nil, parent)
		S.Panel(f)
		return f
	end)
end


-- Opt one dropdown's menu into our registered style.
local function ddStyle(dd)
	if lsfdd and dd and dd.ddSetDisplayMode then dd:ddSetDisplayMode(DD_STYLE) end
end


-- LibSFDropDown combobox button: Background + Arrow + label.
local function ddButton(btn)
	if not btn then return end
	ddStyle(btn)
	S.Dropdown(btn)
end


-- LibSFDropDown stretch button: a plain button carrying its own arrow.
local function ddStretchButton(btn)
	if not btn then return end
	ddStyle(btn)
	-- Stretch buttons inherit BackdropTemplate; clear the backdrop edge or it
	-- sits outside the house border as a second outline.
	if btn.SetBackdropBorderColor then btn:SetBackdropBorderColor(0, 0, 0, 0) end
	if btn.SetBackdropColor then btn:SetBackdropColor(0, 0, 0, 0) end
	S.Button(btn, {"Arrow"})
	if btn.Arrow then btn.Arrow:SetVertexColor(1, 1, 1, .9) end
	S.WhiteButtonLabel(btn)
end


--[[ SHARED WIDGET HELPERS -----------------------------------------------------]]

-- S.SquareIcon crops to .08/.92 to cut the bevel baked into Interface/Icons
-- art. That is exactly wrong for a texture that already carries TexCoords,
-- because those coords are how it picks ITS OWN image out of a sprite sheet,
-- overwrite them and you get an arbitrary slice of the sheet instead.
--
-- The class list is the clearest case: every class is drawn from one
-- UI-CharacterCreate-Classes sheet via CLASS_ICON_TCOORDS, so cropping turned
-- each row into a grid of the wrong classes. The source filter icons come off
-- shared sheets the same way.
--
-- Detect it rather than maintaining a list: a texture still on the full 0..1
-- rect has no crop of its own to lose.
local function squareIcon(tex)
	if not (tex and tex.GetTexCoord and tex.SetTexCoord) then return end
	if tex.euiSquared then return end

	local ok, ulx, uly, llx, lly, urx, ury, lrx, lry = pcall(tex.GetTexCoord, tex)
	if not ok or ulx == nil then return end

	-- Untouched art: hand it to the primitive and let EllesmereUI own the
	-- trim, so it tracks any future change to what "squared" means.
	if ulx == 0 and uly == 0 and llx == 0 and lly == 1 and urx == 1 and ury == 0 then
		tex.euiSquared = true
		S.SquareIcon(tex)
		return
	end

	-- Already cropped, which means the coords are load-bearing: they are how
	-- the texture selects its own image out of a sheet. Overwriting them with
	-- a fixed 0.08/0.92 rect was what turned the class list into a grid of
	-- wrong classes. Trimming the SAME proportion off whatever rect it already
	-- has cuts the bevel without touching which image it points at, so the
	-- class icons lose the rounded corners baked into the sheet and match every
	-- other icon in the addon, instead of being skipped entirely.
	--
	-- Axis-aligned coords only. SetTexCoord(left, right, top, bottom) puts the
	-- same x on both left corners and the same y on both top corners; anything
	-- else is rotated or flipped and cannot be inset from four numbers.
	if ulx ~= llx or urx ~= lrx or uly ~= ury or lly ~= lry then return end
	local left, right = ulx, urx
	local top, bottom = uly, lly
	if not (right > left and bottom > top) then return end

	tex.euiSquared = true
	local iw, ih = (right - left) * .08, (bottom - top) * .08
	tex:SetTexCoord(left + iw, right - iw, top + ih, bottom - ih)
end


-- Every MJViewToggleTemplate / MJArrowToggle in the addon: a flat block whose
-- whole content is a parentKey "icon" glyph. Named through, or the button
-- renders as an empty box.
local function toggleButton(btn)
	if not btn then return end
	S.Button(btn, {"icon"})
end


--[[ CONFIG SCROLL BARS ---------------------------------------------------------
	MountsJournal leaves a 26px channel between the scroll frame's right edge
	and the panel's (BOTTOMRIGHT -26), then seats the bar 6px into it. That was
	right for the stock art, whose visible bar sits right of centre inside its
	own frame. Ours draws the groove down the middle of the frame, so the same
	anchor now leaves the whole bar hard against the left of the channel.

	Centre the frame in the channel instead, derived from the bar's own width
	rather than a fixed nudge, so it stays centred if either changes.
------------------------------------------------------------------------------]]
local SCROLL_CHANNEL = 26

local function centreScrollBar(scroll)
	local sb = scroll and scroll.ScrollBar
	if not sb then return end
	local ok, w = pcall(sb.GetWidth, sb)
	if not ok or not w or w <= 0 or w >= SCROLL_CHANNEL then return end
	local x = (SCROLL_CHANNEL - w) / 2
	sb:ClearAllPoints()
	sb:SetPoint("TOPLEFT", scroll, "TOPRIGHT", x, 0)
	sb:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", x, 0)
end


-- SearchBoxTemplate draws its magnifier as an ordinary texture region, so the
-- fade inside S.EditBox takes it along with the border art, which is why the
-- search boxes kept the space the icon occupies with nothing in it. Restore it
-- afterwards rather than naming it through, so this works the same on either
-- backend regardless of whether S.EditBox grows a keep list.
function editBox(eb)
	if not eb then return end
	S.EditBox(eb)
	if eb.searchIcon then
		eb.searchIcon:SetAlpha(.5)
		-- Re-seated as well as re-shown. Its stock anchor is measured against
		-- the inset of the border art the template draws, and with that art
		-- flattened away the icon ends up hanging over the left edge of the
		-- box. Anchor it to the box itself instead.
		eb.searchIcon:ClearAllPoints()
		eb.searchIcon:SetPoint("LEFT", eb, "LEFT", 7, -1)

		-- The typed text and the placeholder have to clear the icon by the
		-- same amount it moved, or the two drift apart as one is nudged.
		if eb.SetTextInsets then eb:SetTextInsets(20, 6, 0, 0) end
		if eb.Instructions then
			eb.Instructions:ClearAllPoints()
			eb.Instructions:SetPoint("LEFT", eb, "LEFT", 20, 0)
			eb.Instructions:SetPoint("RIGHT", eb, "RIGHT", -6, 0)
		end
	end
end

-- Several MountsJournal widgets inherit BackdropTemplate and draw their edge
-- through SetBackdrop rather than as texture regions. No fade can reach that,
-- so it reads as a second border sitting outside the house one. Cleared by
-- colour alpha, which keeps to the alpha-only policy.
local function clearBackdrop(frame)
	if frame and frame.SetBackdropBorderColor then
		frame:SetBackdropBorderColor(0, 0, 0, 0)
	end
	if frame and frame.SetBackdropColor then
		frame:SetBackdropColor(0, 0, 0, 0)
	end
end


-- S.Button plus that backdrop cleanup, for the plain labelled buttons.
local function flatButton(btn, keepKeys)
	if not btn then return end
	clearBackdrop(btn)
	S.Button(btn, keepKeys)
	S.WhiteButtonLabel(btn)
end


-- A button swaps its label's font object per state (normal, highlight,
-- disabled), and the three need not share a size: on this client the
-- Mount button's label grew on hover. Point the highlight and disabled
-- objects at the normal one's face, size and flags, keeping each state's
-- own colour, so only the colour changes with the state.
local function pinButtonFonts(btn)
	if not (btn and btn.GetNormalFontObject) then return end
	local normal = btn:GetNormalFontObject()
	if not (normal and normal.GetFont) then return end
	local face, size, flags = normal:GetFont()
	if type(face) ~= "string" or (issecretvalue and issecretvalue(size)) then return end
	for _, pair in ipairs({{"GetHighlightFontObject", "SetHighlightFontObject"},
		{"GetDisabledFontObject", "SetDisabledFontObject"}}) do
		local get, set = btn[pair[1]], btn[pair[2]]
		local cur = get and get(btn)
		if cur and set and cur.GetFont then
			local obj = CreateFont("MJEUISkinBtnFont" .. pair[1] .. (tostring(btn):gsub("%W", "")))
			obj:CopyFontObject(cur)
			obj:SetFont(face, size, flags)
			pcall(set, btn, obj)
		end
	end
end

-- Icon-bearing action button: flatten the frame but keep the icon, and square
-- the icon's baked bevel.
--
-- Note the keepKeys. S.Button registers the button for EllesmereUI's restrip
-- pass, which re-fades every region not named through, so anything of the
-- button's own art we want to survive has to be listed here, not just re-shown
-- afterwards. checkedTexture is in the list because some of these buttons show
-- their state as an accent wash over it.
local function itemButton(btn)
	if not btn then return end
	local icon = btn.icon or btn.Icon or btn.ItemIcon
	S.Button(btn, {"icon", "Icon", "ItemIcon", "checkedTexture"})
	if icon then
		icon:SetDrawLayer("OVERLAY")
		-- S.SquareIcon's own border draws onto the button and would be lost to
		-- that same restrip, so square without it and use ours.
		squareIcon(icon)
		newEdges(btn, icon, 1)
	end
end


-- Toggle button that shows its checked state as an accent wash.
local function checkButton(btn, alpha)
	if not btn then return end
	-- Parked on a key of our own purely so it can be named through keepKeys.
	btn.euiChecked = btn.GetCheckedTexture and btn:GetCheckedTexture()
	S.Button(btn, {"icon", "euiChecked"})
	-- Deliberately NOT squared. These are the filter glyphs, the Types
	-- fly/ground/swimming art and the Sources icons, and they are purpose-cut
	-- UI images, not Interface/Icons art with a bevel to trim. Cropping them
	-- ate their edges, and on the sheet-based Sources icons it replaced them
	-- outright. The ElvUI reference leaves them alone for the same reason.
	addWash(btn.euiChecked, alpha or .15)
end


--[[ PORTRAIT ------------------------------------------------------------------
	TODO(api-v2): the window engine has RemovePortrait but API v1 does not put
	it on the public facade, so the portrait is alpha'd out here alongside
	S.Shell. Swap to the primitive if a PortraitFrame entry ships.
------------------------------------------------------------------------------]]
-- Defined down with the entry point; the main window hooks these as it is
-- shelled. fadeCollections(false) restores; suppressBehind() applies and then
-- replays, to stay ahead of EllesmereUI putting its own backdrop back.
local fadeCollections, suppressBehind


local function fadePortrait(frame)
	local pc = frame.PortraitContainer
	if pc and pc.GetRegions then
		for i = 1, select("#", pc:GetRegions()) do
			local r = select(i, pc:GetRegions())
			if r.IsObjectType and r:IsObjectType("Texture") then r:SetAlpha(0) end
		end
		if pc.portrait then pc.portrait:SetAlpha(0) end
	end
	if frame.portrait then frame.portrait:SetAlpha(0) end
	if frame.PortraitFrame then frame.PortraitFrame:SetAlpha(0) end
end


--[[ MAIN WINDOW CHROME --------------------------------------------------------
	S.Shell paints the themed backdrop and fades the frame's OWN texture
	regions, which on a PortraitFrameTemplate leaves plenty standing. This
	window is a PortraitFrameTemplateNoCloseButton and it is resizable, so on
	top of the usual title/portrait art the ornate NineSlice gets re-laid-out
	every time the user drags the grip, a plain alpha pass does not survive
	that. S.FadeNineSlice is the durable form and zeroes the container itself,
	which is what actually keeps the gold frame down.

	MountsJournal then adds art of its own: the gold achievement banner behind
	the mount count, and three InsetFrameTemplate panels whose Bg + NineSlice
	need S.Inset rather than a shallow fade.
------------------------------------------------------------------------------]]
local function shellPortraitFrame(frame)
	S.Shell(frame)

	-- Ornate window border, durably. Without this it comes back on resize.
	if frame.NineSlice then S.FadeNineSlice(frame.NineSlice) end
	if frame.Bg then frame.Bg:SetAlpha(0) end
	if frame.TitleBg then frame.TitleBg:SetAlpha(0) end
	if frame.TitleContainer then
		S.FadeRegions(frame.TitleContainer)
		if frame.TitleContainer.TitleBg then
			frame.TitleContainer.TitleBg:SetAlpha(0)
		end
	end
	if frame.Inset then S.Inset(frame.Inset) end

	fadePortrait(frame)
	-- MountsJournal re-asserts the portrait through SetPortraitToAsset; re-fade
	-- there so a later call cannot resurrect it.
	if frame.SetPortraitToAsset then
		hook(frame, "SetPortraitToAsset", fadePortrait)
	end

	-- The achievement plate behind the mount count is deliberately left alone,
	-- which is what the ElvUI reference does too, it never mentions achiev.
	--
	-- It was being flattened to a house button, and that was wrong twice over.
	-- Its art is drawn as UNNAMED texture regions, two
	-- PetJournal-PetBattleAchievementBG wing plates and the shield icon, so
	-- keepKeys cannot name them through and S.Button faded the lot, leaving the
	-- bare number floating in an empty block. And it is not window chrome to
	-- begin with: the shield reads as an achievement, exactly as it does in the
	-- Pet Journal next door. There is nothing here to put a house surface under.

	-- Suppress whatever Blizzard and EllesmereUI are drawing behind us for as
	-- long as this window is up, and hand it straight back when it closes.
	frame:HookScript("OnShow", function()
		suppressBehind()
		-- Both backends provide RefreshLooks now (on api it is the Shim's,
		-- supplied by the hybrid facade). This is where a profile, accent or
		-- Dark Mode change made while the journal was closed gets picked up:
		-- the engine's live callback covers accent edits, but not every value
		-- the shell reads, and compat has no live callback at all.
		if S.RefreshLooks then S.RefreshLooks() end
	end)
	frame:HookScript("OnHide", function() fadeCollections(false) end)

	-- Collections showing is the other way the engine gets a turn, switching
	-- to Pet Journal and back re-runs its window pack. Only replay while our
	-- window is actually up, so a plain visit to Toy Box is untouched.
	if CollectionsJournal then
		CollectionsJournal:HookScript("OnShow", function()
			if frame:IsShown() then suppressBehind() end
		end)
	end

	if frame:IsShown() then suppressBehind() end

	addBorder(frame)
end


--[[ PET LIST ------------------------------------------------------------------]]
local function petButtonSkin(btn)
	if not btn then return end

	if btn.background then
		-- petTypeIcon is a region of the button and carries meaning, so it is
		-- named through rather than flattened with the rest of the art.
		S.Button(btn, {"petTypeIcon"})
		if btn.selectedTexture then btn.selectedTexture:SetAlpha(0) end

		local infoFrame = btn.infoFrame
		if infoFrame then
			if infoFrame.icon then
				squareIcon(infoFrame.icon)
				local state = newState(infoFrame, infoFrame.icon, 1, true)
				bindHover(btn, state)
				bindSelected(state, btn.selectedTexture)
				bindQuality(state, infoFrame.qualityBorder)
			end
			if infoFrame.levelBG then S.FadeRegions(infoFrame.levelBG) end
			if infoFrame.level then S.Font(infoFrame.level) end
		end

		if btn.petTypeIcon then btn.petTypeIcon:SetDrawLayer("OVERLAY") end
	else
		-- The three control buttons along the bottom of the pet list.
		S.Button(btn)
		if btn.levelBG then S.FadeRegions(btn.levelBG) end
		if btn.level then S.Font(btn.level) end
	end
end


-- Hoisted out of the loop so it is created once rather than per Update.
local function skinPetRow(btn)
	if btn and not btn.euiSkinned then
		btn.euiSkinned = true
		petButtonSkin(btn)
	end
end


local function scrollPetButtons(frame)
	if not frame or not frame.ScrollTarget then return end
	eachChild(skinPetRow, frame.ScrollTarget:GetChildren())
end


local function petListSkin(petList)
	if not petList or petList.euiSkinned then return end
	petList.euiSkinned = true

	S.Panel(petList)

	-- controlPanel, filtersPanel, petListFrame and controlButtons are all
	-- InsetFrameTemplate; blend the box away rather than just the surface art.
	if petList.controlPanel then S.Inset(petList.controlPanel) end
	-- MJViewToggleTemplate again; its glyph is a parentKey "icon" region.
	S.Button(petList.viewToggle, {"icon"})
	editBox(petList.searchBox)
	S.CloseButton(petList.closeButton)

	if petList.filtersPanel then
		S.Inset(petList.filtersPanel)
		for _, btn in ipairs(petList.filtersPanel.buttons or {}) do
			checkButton(btn)
		end
	end

	if petList.petListFrame then
		S.Inset(petList.petListFrame)
		S.ScrollBar(petList.petListFrame.scrollBar)
	end

	if petList.controlButtons then S.Inset(petList.controlButtons) end
	petButtonSkin(petList.randomFavoritePet)
	petButtonSkin(petList.randomPet)
	petButtonSkin(petList.noPet)

	if petList.scrollBox then
		hook(petList.scrollBox, "Update", scrollPetButtons)
		scrollPetButtons(petList.scrollBox)
	end

	ddStyle(petList.companionOptionsMenu)
	addBorder(petList)
end


--[[ PET SELECTION BUTTON ------------------------------------------------------]]
local function petSelectionBtnSkin(btn)
	if not btn or btn.euiSkinned then return end
	btn.euiSkinned = true

	S.Button(btn, {"bg"})
	if btn.bg then squareIcon(btn.bg) end

	-- S.Button puts the facade's 1px border on the button, on a container
	-- one frame level UP (PP.CreateBorder: level + 1, OVERLAY 7). The
	-- button and the icon are the same 38x38 rect, and the favourite star
	-- hangs off the icon's top-left corner, so that border's top and left
	-- strips run through the star (/mjeuiskin pet: container level 1004,
	-- star on infoFrame at level 1003). The icon's own quality edge, a
	-- pixel outside, is the border this button shows; the facade's is
	-- faded. Alpha on the container, so a restrip pass cannot bring it
	-- back region by region.
	for i = 1, select("#", btn:GetChildren()) do
		local child = select(i, btn:GetChildren())
		if child and child ~= btn.infoFrame and child._top and child._bottom then
			child:SetAlpha(0)
		end
	end

	local infoFrame = btn.infoFrame
	if not infoFrame then return end

	if infoFrame.icon then
		squareIcon(infoFrame.icon)
		local state = newState(infoFrame, infoFrame.icon, 1, true)
		bindHover(btn, state)
		bindQuality(state, infoFrame.qualityBorder)
	end
	if infoFrame.levelBG then S.FadeRegions(infoFrame.levelBG) end
	if infoFrame.level then S.Font(infoFrame.level) end
end


--[[ MOUNT SCROLL BUTTONS ------------------------------------------------------]]
-- How much the list was narrowed from the right (journal:list). List rows
-- are a fixed 188 wide from their template (/mjeuiskin list: ScrollTarget
-- 184, row 188), so a narrower box alone pushed the type buttons hanging
-- off the row's right past the box's clip edge. Each row gives up the same
-- amount instead; the name column has room to spare (147 wide in 188).
-- Applied from a hook on the view's ResizeFrame, not here: the grid list
-- view calls frame:SetSize(templateWidth, templateHeight) on EVERY acquire
-- (ScrollBoxListBiaxalViewMixin:ResizeFrame), so a width set once at skin
-- time lasted until the row was next recycled.
local listNarrow = 0

-- Hoisted out of the loop so it is created once rather than per Update.
local function skinMountRow(btn)
	if btn and not btn.euiSkinned then
		btn.euiSkinned = true

		if btn.modelScene then
			-- Grid view: a model tile with a drag button over it. Art is
			-- faded by name rather than wholesale, these rows carry
			-- meaningful regions (faction, pet type) alongside the chrome.
			--
			-- The tile is a BackdropTemplate wearing Blizzard's rounded
			-- tooltip border (MJMountListButton_OnLoad), which showed as
			-- rounded corners inside our square edge. Swap it for the same
			-- backdrop minus the edge, so only the square edge remains. The
			-- fill is kept as MountsJournal's own: the tooltip background
			-- texture under .1 grey, which is darker than a plain white
			-- texture under the same colour would be (tried, and the tiles
			-- came out lighter than before). Insets go to 0 now that there
			-- is no edge to inset from.
			-- MountsJournal writes the tile's state into the border colour on
			-- every refresh and hover (gold selected, grey otherwise); with no
			-- edge file those writes draw nothing, but the `selected` flag
			-- it sets alongside them is the signal, mirrored into our edge
			-- from a hook on the same call.
			if btn.SetBackdrop then
				btn:SetBackdrop({bgFile = "Interface/Tooltips/UI-Tooltip-Background",
					tile = true, tileSize = 14})
				btn:SetBackdropColor(.1, .1, .1, .9)
			end
			-- The type selector (fly / ground / swim) chains down from `fly`,
			-- which MountsJournal seats at x=6, 2px right of the icon at 4.
			-- Bring it out to x=3, the icon's visible left edge: our 1px strip
			-- sits one pixel outside the icon. Ground and swim follow it.
			if btn.fly and btn.fly.SetPoint then
				btn.fly:SetPoint("TOPLEFT", btn, "TOPLEFT", 3, -44)
			end
			local tile = newState(btn, btn, 0)
			bindHover(btn, tile)
			if btn.SetBackdropBorderColor then
				hook(btn, "SetBackdropBorderColor", function(self)
					tile.selected = self.selected or nil
					paintState(tile)
				end)
			end

			local drag = btn.dragButton
			if drag then
				if drag.highlight then drag.highlight:SetAlpha(0) end
				if drag.icon then
					squareIcon(drag.icon)
					local state = newState(drag, drag.icon, 1)
					bindHover(drag, state)
					bindSelected(state, btn.selectedTexture)
					bindQuality(state, drag.qualityBorder)
				end
				addWash(drag.selectedTexture)
			end

			petSelectionBtnSkin(btn.petSelectionBtn)

		elseif btn.dragButton then
			-- List view row.
			if btn.background then btn.background:SetAlpha(0) end
			if btn.highlight then btn.highlight:SetAlpha(0) end
			if btn.selectedTexture then btn.selectedTexture:SetAlpha(0) end

			local state = newState(btn, btn, 0)
			bindHover(btn, state)
			bindSelected(state, btn.selectedTexture)

			-- The same faint hover wash the Rematch skin gives its pet rows,
			-- so the two lists read as one family on the inset plate.
			local hover = btn:CreateTexture(nil, "HIGHLIGHT")
			hover:SetAllPoints(btn)
			hover:SetColorTexture(1, 1, 1, .05)

			if btn.factionIcon then btn.factionIcon:SetDrawLayer("OVERLAY") end

			local drag = btn.dragButton
			if drag.highlight then drag.highlight:SetAlpha(0) end
			if drag.icon then
				squareIcon(drag.icon)
				local iconState = newState(drag, drag.icon, 1)
				bindHover(drag, iconState)
				bindQuality(iconState, drag.qualityBorder)
			end
			addWash(drag.activeTexture)

		else
			-- Small grid icon button.
			if btn.highlight then btn.highlight:SetAlpha(0) end
			if btn.icon then
				squareIcon(btn.icon)
				local state = newState(btn, btn.icon, 1)
				bindHover(btn, state)
				bindSelected(state, btn.selectedTexture)
				bindQuality(state, btn.qualityBorder)
			end
			if btn.selectedTexture then btn.selectedTexture:SetAlpha(0) end
		end
	end
end


local function scrollMountButtons(frame)
	if not frame or not frame.ScrollTarget then return end
	eachChild(skinMountRow, frame.ScrollTarget:GetChildren())
end


--[[ JOURNAL -------------------------------------------------------------------]]

-- Defined further down with the rest of the summon panel; journal_init calls it
-- as one of three chances to catch buttons MountsJournal creates on its own
-- schedule, so it has to be visible here.
local skinSummonPanel


local function tabOnEnter(self)
	-- Accent is re-read per hover, never cached, so live changes land for free.
	if self.text then self.text:SetTextColor(S.GetAccentColor()) end
end


local function tabOnLeave(self)
	if self.text then self.text:SetTextColor(1, 1, 1) end
end


--[[ THE MODEL / MAP / SETTINGS ROW --------------------------------------------
	These three are stock PanelTabButtonTemplate tabs, the same widget as
	Collections' Mounts / Pets / Toys row beside them, and for a long time
	the right call was to leave them alone: stock beside stock matches by
	construction, and every attempt to dress them moved them away from
	their neighbours (the stage comment in journal_init has that history).

	That holds only while Collections' row IS stock. Where something else
	dresses that row, ours stay Blizzard next to it and stop matching. The
	Rematch skin found who that something is on this client: not
	EllesmereUI, whose Collections pack steps over foreign frames, but
	atrocityEssentials, part of the atrocityUI package, which hangs a
	BackdropTemplate plate under each Collections tab (the /fstack tell: an
	anonymous child frame carrying a Center texture). So the row is dressed
	to match whichever of the three looks collectionsTabStyle reports.

	"atrocity", its recipe read from atrocityEssentials' SkinningAPI: every
	texture stripped; a backdrop plate inset 2px in the control colour with
	a 1px edge in the theme border colour, one frame level below the tab; a
	grey 15% hover over the plate; the theme font at 12pt outlined, set
	through the button's three state font objects so Blizzard's gold/white
	colouring keeps working; and a brand-coloured 35% plate inside the
	backdrop while selected. The fill colour and the fonts are then read
	live off Collections' own tabs once atrocityEssentials has dressed them,
	which is the reference that matters, with its public Theme table and
	its documented constants as the fallbacks. Plates inset 2px on a 1px
	seam means the frames overlap by 3, and the end tab's plate sits flush
	with the window's right edge, the mirror of how atrocityEssentials
	aligns Collections' first plate with the left one.

	"eui": one S.Tab per tab, then the engine's own row treatment, 2px off
	the height and a 1px seam. "blizzard": untouched, as before.

	Ported from the Rematch skin, where the atrocity recipe was measured
	against the Collections row and confirmed. Rematch's tabs needed a
	Blizzard face created on top of them; these already are that face, so
	the dressing goes straight on.
------------------------------------------------------------------------------]]
local bottomTabs = setmetatable({}, {__mode = "k"})

-- atrocityEssentials' documented constants; the live values are preferred
-- wherever they can be read (aeReference).
local AE_CONTROL = {.055, .055, .055, .90}
local AE_HOVER = {.851, .851, .851, .15}
local AE_SELECTED_A = .35

local function aeTheme()
	local ae = _G.atrocityEssentials
	return ae and type(ae.Theme) == "table" and ae.Theme or nil
end

local function aeBrand()
	local t = aeTheme()
	local b = t and t.brand
	if type(b) == "table" and b[1] then return b[1], b[2], b[3] end
	return .451, .506, 1
end

local function aeBorder()
	local t = aeTheme()
	local b = t and t.border
	if type(b) == "table" and b[1] then return b[1], b[2], b[3], b[4] or 1 end
	return 0, 0, 0, 1
end


-- What atrocityEssentials actually drew on Collections' row: the plate's
-- fill, read off the anonymous BackdropTemplate child it parks under a tab,
-- and the label fonts. Two fonts, because a selected tab is disabled and
-- Blizzard's select swaps its disabled font object for GameFontHighlightSmall
-- (which atrocityEssentials re-fonts globally, at its own size), while a
-- deselected tab wears the pinned 12pt one. Copying both from the tab in
-- each state is what makes ours change exactly as theirs do. Returns nil
-- until atrocityEssentials has dressed the row, so callers keep their
-- fallbacks until then and re-ask later.
local function aeReference()
	local collect = CollectionsJournal
	if not collect then return nil end
	local out = {}
	for _, key in ipairs({"MountsTab", "PetsTab", "ToysTab", "HeirloomsTab",
		"WardrobeTab", "WarbandScenesTab"}) do
		local tab = collect[key]
		if tab and not tab:IsForbidden() then
			if not out.control and tab.GetChildren then
				for i = 1, select("#", tab:GetChildren()) do
					local child = select(i, tab:GetChildren())
					if child and child.GetBackdropColor then
						local ok, r, g, b, a = pcall(child.GetBackdropColor, child)
						if ok and r then out.control = {r, g, b, a or 1} end
						break
					end
				end
			end
			local text = tab.Text
			if text and text.GetFont then
				local ok, face, size, flags = pcall(text.GetFont, text)
				if ok and type(face) == "string" and not (issecretvalue and issecretvalue(size)) then
					local enabled = not tab.IsEnabled or tab:IsEnabled()
					if enabled and not out.font then out.font = {face, size, flags} end
					if not enabled and not out.fontSelected then out.fontSelected = {face, size, flags} end
				end
			end
		end
	end
	if not out.control then return nil end
	return out
end


-- Dress a Blizzard tab the way atrocityEssentials dresses Collections'.
local function dressFaceAtrocity(face)
	local d = {style = "atrocity"}
	for _, t in ipairs(face.TabTextures or {}) do t:SetAlpha(0) end
	for _, k in ipairs({"Left", "Middle", "Right", "LeftActive", "MiddleActive", "RightActive",
		"LeftHighlight", "MiddleHighlight", "RightHighlight"}) do
		if face[k] then face[k]:SetAlpha(0) end
	end
	local hl = face.GetHighlightTexture and face:GetHighlightTexture()
	if hl then hl:SetAlpha(0) end
	if face.SetPushedTextOffset then face:SetPushedTextOffset(0, 0) end
	-- Zero the per-state label offsets, so PanelTemplates' own re-seating on
	-- every selection change lands centred rather than fighting ours. Both
	-- of Blizzard's offsets are measured against art that is now invisible.
	face.selectedTextX, face.selectedTextY = 0, 0
	face.deselectedTextX, face.deselectedTextY = 0, 0

	local bd = CreateFrame("Frame", nil, face, "BackdropTemplate")
	bd:SetPoint("TOPLEFT", face, "TOPLEFT", 2, -2)
	bd:SetPoint("BOTTOMRIGHT", face, "BOTTOMRIGHT", -2, 2)
	local lvl = face:GetFrameLevel()
	bd:SetFrameLevel(lvl > 0 and lvl - 1 or 0)
	bd:SetBackdrop({bgFile = "Interface\\Buttons\\WHITE8x8",
		edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1})
	bd:SetBackdropColor(AE_CONTROL[1], AE_CONTROL[2], AE_CONTROL[3], AE_CONTROL[4])
	bd:SetBackdropBorderColor(aeBorder())
	d.bd = bd

	local hover = face:CreateTexture(nil, "HIGHLIGHT")
	hover:SetColorTexture(AE_HOVER[1], AE_HOVER[2], AE_HOVER[3], AE_HOVER[4])
	hover:SetPoint("TOPLEFT", bd, "TOPLEFT", 1, -1)
	hover:SetPoint("BOTTOMRIGHT", bd, "BOTTOMRIGHT", -1, 1)
	d.hover = hover

	local sel = face:CreateTexture(nil, "ARTWORK")
	local br, bg, bb = aeBrand()
	sel:SetColorTexture(br, bg, bb, AE_SELECTED_A)
	sel:SetPoint("TOPLEFT", bd, "TOPLEFT", 1, -1)
	sel:SetPoint("BOTTOMRIGHT", bd, "BOTTOMRIGHT", -1, 1)
	sel:Hide()
	d.sel = sel

	local t = aeTheme()
	local fontPath = t and t.fontFace
	local size = (t and t.fontSizeNormal) or 12
	local outline = (t and t.fontOutline) or "OUTLINE"
	if face.Text and fontPath then
		-- Blizzard's three state font objects carry the gold/white colours;
		-- only the face, size and outline change, per state, so the colour
		-- state machine keeps working. Kept on the dress record because
		-- PanelTemplates_SelectTab overwrites the disabled one with
		-- Blizzard's own small font on every selection; paint re-pins them.
		d.fonts = {}
		for _, pair in ipairs({{"GetNormalFontObject", "SetNormalFontObject"},
			{"GetHighlightFontObject", "SetHighlightFontObject"},
			{"GetDisabledFontObject", "SetDisabledFontObject"}}) do
			local get, set = face[pair[1]], face[pair[2]]
			local cur = get and get(face)
			if cur and set then
				local obj = CreateFont("MJEUISkinTabFont" .. pair[1] .. (tostring(face):gsub("%W", "")))
				obj:CopyFontObject(cur)
				obj:SetFont(fontPath, size, outline)
				obj:SetShadowOffset(0, 0)
				d.fonts[pair[2]] = obj
				pcall(set, face, obj)
			end
		end
	end
	return d
end


-- Once atrocityEssentials has dressed the Collections row, take the fill
-- and fonts off it rather than off its constants. One-shot per tab: the
-- reference does not change within a session short of a /reload.
local function applyReference(d)
	if d.refApplied or not d.bd then return end
	local ref = aeReference()
	if not ref then return end
	d.refApplied = true
	local c = ref.control
	d.bd:SetBackdropColor(c[1], c[2], c[3], c[4])
	if d.fonts and ref.font then
		local f = ref.font
		local fs = ref.fontSelected or f
		for setter, obj in pairs(d.fonts) do
			local use = setter == "SetDisabledFontObject" and fs or f
			pcall(obj.SetFont, obj, use[1], use[2], use[3])
		end
	end
end


local function repinFonts(face)
	local d = bottomTabs[face]
	if not (d and d.fonts) then return end
	for setter, obj in pairs(d.fonts) do
		local set = face[setter]
		if set then pcall(set, face, obj) end
	end
end


local function dressFaceEui(face)
	face.selectedTextX, face.selectedTextY = 0, 0
	face.deselectedTextX, face.deselectedTextY = 0, 0
	S.Tab(face)
end


-- PanelTemplates_SetTab writes the parent's selectedTab before it walks
-- the row, so this is current from inside the select/deselect hooks too.
local function isSelectedTab(tab)
	local parent = tab:GetParent()
	local sel = parent and parent.selectedTab
	local tabs = parent and parent.Tabs
	if not (sel and type(tabs) == "table") then return false end
	return tabs[sel] == tab
end


--[[ SEATING THE ROW -----------------------------------------------------------
	MountsJournal chains the three right-to-left from settingsTab, which it
	seats TOPRIGHT to the window's BOTTOMRIGHT at (-6, 2), each next tab 3px
	further left: Blizzard's spacing, which the stock art is drawn for.
	Nothing of MountsJournal's re-anchors them at runtime, so this is set
	once.

	The y is read off Collections' first tab rather than assumed. Blizzard's
	XML says 2, and so does MountsJournal's; measured under
	atrocityEssentials the Collections row sits at 1 (/mjeuiskin tabs:
	"CollectionsJournalTab1 anchored TOPLEFT -> ... at -2,1", tab tops at
	718 against a window bottom of 717). At 2 ours sat a pixel higher, and
	the 2px-inset plate's top landed ON the window edge instead of leaving
	the 1px seam the row beside it has. Whatever the number is on a given
	client, matching it is what makes the rows level.
------------------------------------------------------------------------------]]
local function collectionsRowY()
	-- The seat as Blizzard set it, recorded by journal:collectionsRow
	-- before that stage starts adding the window-height correction to the
	-- live offset. Reading the live offset here seated our row a whole
	-- window-height correction too low after a taller window was restored.
	local j = MountsJournalFrame
	if j and type(j.euiCollectionsRowY) == "number" then return j.euiCollectionsRowY end
	local t1 = CollectionsJournalTab1
	if t1 and t1.GetPoint then
		local ok, point, _, _, _, y = pcall(t1.GetPoint, t1, 1)
		if ok and point and type(y) == "number" and not (issecretvalue and issecretvalue(y)) then
			return y
		end
	end
	return 1
end

local function seatBottomTabs(bgFrame, style)
	local s, m, mo = bgFrame.settingsTab, bgFrame.mapTab, bgFrame.modelTab
	if not (s and m and mo) then return end
	if style == "atrocity" then
		-- Plates inset 2px on a 1px seam: the frames overlap by 3. The end
		-- plate flush with the window edge, as atrocityEssentials' gap
		-- calibration puts Collections' first one flush with the left.
		s:ClearAllPoints()
		s:SetPoint("TOPRIGHT", bgFrame, "BOTTOMRIGHT", 2, collectionsRowY())
		m:ClearAllPoints()
		m:SetPoint("RIGHT", s, "LEFT", 3, 0)
		mo:ClearAllPoints()
		mo:SetPoint("RIGHT", m, "LEFT", 3, 0)
	elseif style == "eui" then
		-- The engine's NormalizeTabRow, which it runs over Collections' row:
		-- 2px off every skinned tab's height, once, and a 1px seam.
		for _, t in ipairs({s, m, mo}) do
			if not t.euiTrimmed then
				t.euiTrimmed = true
				local h = t:GetHeight() or 0
				if h > 2 then t:SetHeight(h - 2) end
			end
		end
		m:ClearAllPoints()
		m:SetPoint("RIGHT", s, "LEFT", -1, 0)
		mo:ClearAllPoints()
		mo:SetPoint("RIGHT", m, "LEFT", -1, 0)
	end
end


local function paintBottomTab(tab, selected)
	local d = bottomTabs[tab]
	if not d then return end
	-- A tab dressed stock before the Collections window existed is promoted
	-- to the engine look if that row turns out to wear it.
	if d.style == "blizzard" and collectionsTabStyle() == "eui" then
		d.style = "eui"
		dressFaceEui(tab)
		seatBottomTabs(tab:GetParent(), "eui")
	end
	if d.style == "blizzard" then return end
	if selected == nil then selected = isSelectedTab(tab) end

	if d.style == "eui" then
		-- The engine's primitive re-reads selection itself and is guarded,
		-- so a repeat call is its own repaint.
		S.Tab(tab)
		return
	end

	-- Sized to the label, as atrocityEssentials sizes Collections' tabs
	-- (its PinTextFit is this same call). MountsJournal's come up a fixed
	-- 72 each, and that width is what set the window's minimum: its
	-- getMinMaxSize adds the two tab rows plus 20, and with Collections'
	-- row label-sized and ours not, the sum overshot Collections' own 703
	-- by a few pixels, so the journal could never be dragged as narrow as
	-- the tabs beside it. Label-sized, the rows fit inside 703 with room.
	--
	-- With an explicit minimum of 1: TabResize otherwise floors a tab at
	-- the width of its Left + Right art, ~72, which is exactly the 72 all
	-- three came up at, so the plain call changed nothing. Collections'
	-- labels are all wider than that floor, so its tabs are text + 20 in
	-- practice, and this makes ours the same rule.
	if PanelTemplates_TabResize then pcall(PanelTemplates_TabResize, tab, 0, nil, 1) end
	-- Blizzard offsets the label per state to sit on its own art; with the
	-- art gone it is centred, as the row beside us has it.
	if tab.Text then
		tab.Text:ClearAllPoints()
		tab.Text:SetPoint("CENTER", tab, "CENTER", 0, 0)
	end
	applyReference(d)
	repinFonts(tab)
	-- MountsJournal replaces Enable and Disable on these tabs with no-ops
	-- (its secure handler disables them on click instead), so Blizzard's
	-- select does not always reach the disabled state whose font object
	-- carries the white selected label. Point the normal object at the
	-- selected one while selected, and the label is white either way.
	if d.fonts and tab.SetNormalFontObject then
		local obj = (selected and d.fonts.SetDisabledFontObject) or d.fonts.SetNormalFontObject
		if obj then pcall(tab.SetNormalFontObject, tab, obj) end
	end
	local br, bg, bb = aeBrand()
	d.sel:SetColorTexture(br, bg, bb, AE_SELECTED_A)
	d.sel:SetShown(selected and true or false)
	d.bd:SetBackdropBorderColor(aeBorder())
end


-- Blizzard re-seats the label and swaps the disabled font object on every
-- selection change, so the repaint runs after each of those, from the
-- global helpers MountsJournal drives its row through. Guarded to our own
-- tabs; the same functions serve every tab row in the game.
local bottomTabsHooked = false
local function ensureBottomTabHooks()
	if bottomTabsHooked then return end
	bottomTabsHooked = true
	if PanelTemplates_SelectTab then
		hooksecurefunc("PanelTemplates_SelectTab", function(tab)
			if tab and bottomTabs[tab] then paintBottomTab(tab, true) end
		end)
	end
	if PanelTemplates_DeselectTab then
		hooksecurefunc("PanelTemplates_DeselectTab", function(tab)
			if tab and bottomTabs[tab] then paintBottomTab(tab, false) end
		end)
	end
	if PanelTemplates_SetDisabledTabState then
		hooksecurefunc("PanelTemplates_SetDisabledTabState", function(tab)
			if tab and bottomTabs[tab] then paintBottomTab(tab, false) end
		end)
	end
end


local function dressBottomTabs(bgFrame)
	local tabs = bgFrame.Tabs
	if type(tabs) ~= "table" or #tabs == 0 then return end
	local style = collectionsTabStyle()
	for i = 1, #tabs do
		local tab = tabs[i]
		if tab and not tab:IsForbidden() and not bottomTabs[tab] then
			if style == "atrocity" then
				bottomTabs[tab] = dressFaceAtrocity(tab)
				-- PanelTabButtonMixin re-sizes the tab on every OnShow and
				-- on DISPLAY_SIZE_CHANGED, so the label fit is re-applied
				-- after both; HookScript runs after the template's own.
				tab:HookScript("OnShow", function(t) paintBottomTab(t) end)
				tab:HookScript("OnEvent", function(t) paintBottomTab(t) end)
			else
				if style == "eui" then dressFaceEui(tab) end
				bottomTabs[tab] = {style = style}
			end
		end
	end
	ensureBottomTabHooks()
	seatBottomTabs(bgFrame, style)
	for i = 1, #tabs do paintBottomTab(tabs[i]) end
	-- The reference row may not have been dressed yet the first time
	-- through (atrocityEssentials and MountsJournal both build on
	-- Blizzard_Collections loading, in no fixed order), so re-ask on show.
	bgFrame:HookScript("OnShow", function()
		for i = 1, #tabs do paintBottomTab(tabs[i]) end
	end)
end


-- Filled in for the forward declaration by looksChanged.
function repaintBottomTabs()
	for tab in pairs(bottomTabs) do
		if not tab:IsForbidden() then paintBottomTab(tab) end
	end
end


-- Split into isolated sections on purpose. This function reaches well over a
-- hundred frames across MountsJournal's whole UI, and any one of those paths
-- could move between versions. Run as a single block, one wrong frame costs the
-- entire window; run like this, it costs its own section and says which.
local function journal_init(journal)
	local bgFrame = journal.bgFrame
	if not bgFrame or journal.euiInit then return end
	journal.euiInit = true

	--[[ KEEP THE COLLECTIONS TAB ROW ON THE COLLECTIONS FRAME -----------------
		MountsJournal re-anchors CollectionsJournalTab1 from CollectionsJournal
		to its own window whenever that window shows, and back when it hides
		(journal:updateCollectionTabs, plus the secure handler's update
		snippet for the protected case), so that the row follows the bottom
		edge of a window the user has made taller. Every other Collections
		tab chains off Tab1, so the whole row moves with it.

		Measured to four decimals (/mjeuiskin tabs on Toy Box, then Mounts),
		the two anchor frames sit at the same bottom edge and the tab rects
		are identical either way, but the labels are not: hanging off
		Collections they read 698.0000, a snapped whole number, and hanging
		off the journal window they read 697.9998, tab-plus-eleven with no
		snap at all, which is also what our own three labels read in both
		runs because their tabs are children of that window. Text whose
		position derives from the journal window is not pixel-snapped the
		way the rest of the Collections frame is, so the row's labels render
		a pixel lower the moment Mounts is engaged and climb back on leaving.

		The window is a child of a CheckButton MountsJournal flattens with
		SetFlattensRenderLayers; whatever the exact rule, the cure is to not
		derive the row's position from it. After each of MountsJournal's
		re-anchors, the row goes back on CollectionsJournal, offset by the
		whole-unit difference between the two windows' bottom edges, which
		is zero at the default size and exactly the amount MountsJournal
		wanted otherwise. OnSizeChanged keeps it following a resize drag
		live. Only Blizzard's y offset is derived; x is re-read each time
		because atrocityEssentials calibrates it.
	--------------------------------------------------------------------------]]
	stage("journal:collectionsRow", function()
		local tab, collect = CollectionsJournalTab1, CollectionsJournal
		if not (tab and collect and tab.GetPoint) then return end
		local ok, _, _, _, _, y0 = pcall(tab.GetPoint, tab, 1)
		if not (ok and type(y0) == "number") then return end
		if issecretvalue and issecretvalue(y0) then return end
		local baseY = y0
		-- The seat Blizzard gave the row, for our own row to read
		-- (collectionsRowY). Nothing below ever changes it.
		journal.euiCollectionsRowY = baseY

		--[[ A proxy for the window, outside the flattened subtree ---------
			Two earlier versions re-hung the row on CollectionsJournal with
			a computed offset (measured bottoms, then the height difference)
			and both lost the row after a reload with a resized window: a
			computed offset is only right at the moment it is computed, and
			every path that re-seats Tab1 afterwards (MountsJournal's own,
			the secure handler's, atrocityEssentials' calibration) carried
			or reset it. So: no offset. A plain frame parented to
			CollectionsJournal, at its top-left, kept the same SIZE as the
			journal window, and Tab1 hung off that proxy's bottom with
			Blizzard's own x and y, untouched. The row follows the window
			height because the proxy does, whatever seats it and whenever;
			and the proxy is a child of CollectionsJournal, not of the
			flattened CheckButton the window lives under, so the labels
			snap the way the rest of Collections does. When the window is
			hidden MountsJournal itself puts the row back on Collections,
			and this leaves that alone.
		------------------------------------------------------------------]]
		local proxy = CreateFrame("Frame", nil, collect)
		proxy:SetPoint("TOPLEFT", collect, "TOPLEFT", 0, 0)
		proxy:EnableMouse(false)
		local function syncProxy()
			local w, h = bgFrame:GetSize()
			if w and h and w > 0 and h > 0 then proxy:SetSize(w, h) end
		end
		syncProxy()

		local function reseat()
			if InCombatLockdown and InCombatLockdown() then return end
			if not bgFrame:IsShown() then return end
			syncProxy()
			local okP, point, rel, rPoint, x, y = pcall(tab.GetPoint, tab, 1)
			if not (okP and point) or rel == proxy then return end
			pcall(tab.SetPoint, tab, point, proxy, rPoint, x or 0, y or baseY)
		end

		hook(journal, "updateCollectionTabs", reseat)
		bgFrame:HookScript("OnShow", reseat)
		bgFrame:HookScript("OnSizeChanged", syncProxy)
		reseat()
	end)

	--[[ RIGHT-CLICK THE RESIZE GRIP TO RESET ---------------------------------
		The grip resizes on a left drag; a right-click puts the window back
		at its minimum size, which is Collections' own. The sequence is the
		one MountsJournal runs when a drag stops, minus the StopMovingOrSizing
		there was no drag for: save the size, re-anchor, re-lay the list, and
		tell the map and model display the window changed.
	--------------------------------------------------------------------------]]
	stage("journal:resetSize", function()
		local resize = bgFrame.resize
		if not (resize and resize.HookScript and journal.getMinMaxSize) then return end
		resize:HookScript("OnMouseUp", function(_, button)
			if button ~= "RightButton" then return end
			if InCombatLockdown and InCombatLockdown() then return end
			if bgFrame.isSizing then return end
			local ok, minW, minH = pcall(journal.getMinMaxSize, journal)
			if not (ok and minW and minH) then return end
			bgFrame:SetSize(minW, minH)
			local cfg = _G.MountsJournal and _G.MountsJournal.config
			if cfg then cfg.journalWidth, cfg.journalHeight = minW, minH end
			if CollectionsJournal then
				bgFrame:ClearAllPoints()
				bgFrame:SetPoint("TOPLEFT", CollectionsJournal, "TOPLEFT", 0, 0)
			end
			if journal.setScrollGridMounts then journal:setScrollGridMounts(true) end
			if journal.event then pcall(journal.event, journal, "JOURNAL_RESIZED") end
		end)
	end)

	stage("journal:shell", function()
		shellPortraitFrame(bgFrame)
		S.CloseButton(bgFrame.closeButton)
	end)

	stage("journal:navbar", function()
		-- NAV BAR
		local navBar = journal.navBar
		if navBar then
			S.FadeRegions(navBar)
			if navBar.overlay then S.FadeRegions(navBar.overlay) end
			if navBar.homeButton then
				S.FadeRegions(navBar.homeButton)
				flatButton(navBar.homeButton)
			end

			--[[ The breadcrumb trail ---------------------------------------
				Only the home button used to be skinned, which is why World
				looked right and every crumb after it kept Blizzard's chevron
				art. The rest are built on demand as the user drills into the
				map, so they are caught as they appear.

				Flattening them brought a problem of its own. The template's
				chevrons are drawn to interlock, so consecutive buttons are
				anchored to OVERLAP by the width of the notch; invisible while
				the art is a chevron, and a collision once each button is a
				solid rectangle. On a deep trail that collision lands on the
				overflow arrow and buries it.

				Two fixes, because they cover different halves of it. xoffset is
				Blizzard's own spacing hook, read when the NEXT button is
				seated, so setting it as each button is added spaces the whole
				chain within the same rebuild rather than one refresh late.
				And the overflow arrow is raised above the trail, so even if a
				crumb reaches it the arrow stays visible and clickable.
			----------------------------------------------------------------]]
			local NAV_SEAM = 1
			-- MJNavButtonTemplate is 28 tall. The home and overflow buttons come
			-- from Blizzard's NavBarTemplate at 24, a difference the chevron art
			-- hid and flat blocks do not, so the row had two odd ones out.
			local NAV_HEIGHT = 28

			-- The dropdown arrow is a child button carrying its own
			-- SquareButtonTextures art, so flattening the crumb never reached
			-- it. Give it the same arrow S.Dropdown draws, which is what the
			-- map's own navigation button gets.
			local function skinMenuArrow(btn)
				local arrowBtn = btn and btn.MenuArrowButton
				if not arrowBtn or arrowBtn.euiSkinned then return end
				arrowBtn.euiSkinned = true

				S.FadeRegions(arrowBtn)

				-- Fading once is not enough here. The template ships its
				-- Normal and Pushed art at alpha 0 and RAISES it from the
				-- button's own mouse scripts, so a build-time fade is undone
				-- the moment the cursor arrives: that is the square button
				-- plate appearing around the arrow on hover. Re-zero from the
				-- same scripts, which run after the template's own.
				local function hideArt()
					for _, getter in ipairs({"GetNormalTexture", "GetPushedTexture",
						"GetDisabledTexture", "GetHighlightTexture"}) do
						local fn = arrowBtn[getter]
						local tex = fn and fn(arrowBtn)
						if tex then tex:SetAlpha(0) end
					end
				end
				hideArt()
				for _, script in ipairs({"OnEnter", "OnLeave", "OnMouseDown", "OnMouseUp"}) do
					arrowBtn:HookScript(script, hideArt)
				end

				local arrow = arrowBtn:CreateTexture(nil, "OVERLAY")
				arrow:SetAtlas("Azerite-PointingArrow")
				arrow:SetSize(12, 9)
				arrow:SetPoint("CENTER", 0, -1)
				arrow:SetVertexColor(1, 1, 1, .8)
				arrowBtn:HookScript("OnEnter", function() arrow:SetVertexColor(1, 1, 1, 1) end)
				arrowBtn:HookScript("OnLeave", function() arrow:SetVertexColor(1, 1, 1, .8) end)
			end

			local function skinNavButton(btn)
				if not btn or btn.euiSkinned then return end
				btn.euiSkinned = true
				btn.xoffset = NAV_SEAM
				S.FadeRegions(btn)
				flatButton(btn)
				skinMenuArrow(btn)
			end

			-- xoffset is a real NavBar field, and both of these ship with a
			-- large negative one (-15 on home, -18 on overflow) so the next
			-- button slides back under their chevron overhang. That is the
			-- overlap burying the overflow arrow on a deep trail; a 1px seam
			-- fixes it at the anchor rather than by stacking frame levels.
			if navBar.homeButton then
				navBar.homeButton.xoffset = NAV_SEAM
				navBar.homeButton:SetHeight(NAV_HEIGHT)
			end
			if navBar.overflowButton then
				navBar.overflowButton.xoffset = NAV_SEAM
				navBar.overflowButton:SetHeight(NAV_HEIGHT)
			end

			-- Hooked on the global rather than on refresh, so each button is
			-- seated before the one after it is placed. Guarded to our own bar:
			-- the world map and encounter journal use this same function.
			if type(NavBar_AddButton) == "function" then
				hooksecurefunc("NavBar_AddButton", function(bar)
					if bar ~= navBar then return end
					local list = bar.navList
					if list then skinNavButton(list[#list]) end
				end)
			end

			local function skinNavButtons()
				for _, btn in ipairs(navBar.navList or {}) do skinNavButton(btn) end
			end
			hook(navBar, "refresh", skinNavButtons)
			skinNavButtons()

			if navBar.overflowButton then
				navBar.overflowButton:SetFrameLevel(navBar:GetFrameLevel() + 10)
			end

			ddStyle(navBar.dropDown)
			-- The overflow button is a "there is more to the left" affordance, which
			-- is exactly what the house page arrow says.
			S.PageButton(navBar.overflowButton, "<")
		end

		-- mountCount is an InsetFrameTemplate3: Bg plus a NineSlice box, so it needs
		-- S.Inset to blend rather than a surface fade.
		if journal.mountCount then S.Inset(journal.mountCount) end
		if bgFrame.rightInset then S.Inset(bgFrame.rightInset) end

		if journal.mountDisplay then
			local display = journal.mountDisplay
			S.FadeRegions(display)
			-- The big orange MountJournal-BG wash behind the model, and its
			-- no-mounts counterpart. MountsJournal toggles these with Show/Hide,
			-- which does not disturb alpha, so zeroing them once holds.
			if display.yesMountsTex then display.yesMountsTex:SetAlpha(0) end
			if display.noMountsTex then display.noMountsTex:SetAlpha(0) end
			if display.shadowOverlay then S.FadeRegions(display.shadowOverlay) end
		end

	end)

	stage("journal:slot", function()
		-- SLOT / DYNAMIC FLIGHT
		if bgFrame.slotButton then
			itemButton(bgFrame.slotButton)
		end

		if bgFrame.OpenDynamicFlightSkillTreeButton then
			local function dynamicFlightButton(button)
				if not button then return end
				-- The icon is an unnamed region on these, the fourth, which is
				-- where the template puts it. Park it on a key of our own first so
				-- it can be named through keepKeys and survive a restrip.
				local icon = select(4, button:GetRegions())
				if icon and icon.IsObjectType and icon:IsObjectType("Texture") then
					button.euiIcon = icon
				end
				-- targetMount comes through here too, and shows its state as a wash
				-- over checkedTexture, so that is named through as well.
				S.Button(button, {"euiIcon", "checkedTexture"})
				if button.euiIcon then
					squareIcon(button.euiIcon)
					newEdges(button, button.euiIcon, 1)
				end
			end
			dynamicFlightButton(bgFrame.OpenDynamicFlightSkillTreeButton)
			dynamicFlightButton(bgFrame.DynamicFlightModeButton)
			dynamicFlightButton(bgFrame.targetMount)
		else
			itemButton(bgFrame.targetMount)
		end

		-- The "this is your target's mount" tick reads as a state, so it takes the
		-- accent rather than a colour of our own.
		if bgFrame.targetMount and bgFrame.targetMount.checkedTexture then
			addWash(bgFrame.targetMount.checkedTexture, .3)
		end

		itemButton(bgFrame.summon1)
		itemButton(bgFrame.summon2)

		ddStyle(bgFrame.summonPanelSettings)
		if MountsJournal.summonPanel then
			skinSliderFrame(MountsJournal.summonPanel.fade)
			skinSliderFrame(MountsJournal.summonPanel.resize)
			-- Last of the three chances at the summon buttons; see skinSummonPanel.
			skinSummonPanel()
		end

	end)

	stage("journal:filters", function()
		-- FILTERS
		if journal.filtersPanel then S.Inset(journal.filtersPanel) end
		-- Both are UIMenuButtonStretchTemplate derivatives (MJViewToggleTemplate
		-- and MJArrowToggle) whose glyph is a parentKey "icon" region. Without
		-- naming it through, S.Button fades it with the rest of the art and
		-- leaves two blank blocks beside the search box.
		toggleButton(journal.gridToggleButton)
		toggleButton(journal.filtersToggle)
		editBox(journal.searchBox)
		ddStretchButton(journal.filtersButton)

		-- Seat the filter row. Each of these templates baked its own transparent
		-- padding into its art and the stock anchors were spaced to suit that,
		-- so once the art is a flat edge-to-edge block the leftover gaps read
		-- as misalignment: two toggles floating off the search box, which then
		-- does not reach the Filter button. Same seating as the reference.
		--
		--
		-- One bar, the width of the panel: the view toggle on the panel's
		-- left edge (the type bar and the list plate start there too), the
		-- filters toggle 1px after it, the search box 1px after that, and
		-- the Filter button on the panel's right edge, 1px after the box.
		-- The box is the one that flexes; the buttons keep their size.
		--
		-- MountsJournal creates filtersButton with no width, LEFT chained to
		-- the search box and TOPRIGHT at -3, so it filled whatever was
		-- left. Anchoring the box's RIGHT to it would close a loop, so the
		-- button gets its width in numbers instead: MountsJournal's box
		-- ends 95 in from the right, its button starts 1 before that, so
		-- 94 keeps the same 1px seam in the model grid too, where the box
		-- is MountsJournal's to seat (see seatSearchBox).
		local gridToggle, filtersToggle = journal.gridToggleButton, journal.filtersToggle
		if gridToggle and filtersToggle then
			gridToggle:SetSize(22, 22)
			filtersToggle:SetSize(22, 22)
			gridToggle:ClearAllPoints()
			gridToggle:SetPoint("TOPLEFT", 0, -4)
			filtersToggle:ClearAllPoints()
			filtersToggle:SetPoint("LEFT", gridToggle, "RIGHT", 1, 0)
		end
		local filtersButton = journal.filtersButton
		if filtersButton and journal.filtersPanel then
			filtersButton:ClearAllPoints()
			filtersButton:SetPoint("TOPRIGHT", journal.filtersPanel, "TOPRIGHT", 0, -4)
			filtersButton:SetSize(94, 22)
		end

		-- The search box has to be re-seated after MountsJournal, not merely at
		-- skin time. setScrollGridMounts runs on every tab change and grid
		-- toggle and does ClearAllPoints() followed by a lone TOPRIGHT, which
		-- drops the LEFT anchor that gives the box its width. Anchoring once
		-- here would look right until the first tab switch and then silently
		-- snap back, so re-apply from a hook on it. Purely additive: it never
		-- clears MountsJournal's own points, so its width still follows the
		-- window.
		local function seatSearchBox()
			local box = journal.searchBox
			if not (box and filtersToggle) then return end
			box:SetHeight(22)

			-- The grid view is MountsJournal's own layout and must be left to
			-- it. There it hides filtersToggle, shows the mounts-per-row slider
			-- in that space, and anchors the search box's LEFT to the slider
			-- itself. Adding ours on top was a second, conflicting LEFT anchor
			-- that pulled the box back underneath the slider, the overlap in
			-- the grid view. Only take over the seat when the toggle is the
			-- thing actually sitting there.
			--
			-- The vertical is still ours to correct, and can be without
			-- disturbing that: re-setting TOPRIGHT replaces the one point
			-- MountsJournal set and leaves its LEFT alone. -4 instead of -5
			-- puts the box on the same top edge as the Filter button beside it.
			if not filtersToggle:IsShown() then
				box:SetPoint("TOPRIGHT", -95, -4)
				return
			end

			-- Own all three points rather than adding to MountsJournal's, so
			-- there is no argument about which anchor sets the top edge. Its
			-- TOPRIGHT sits at -5 while every other control in the row is at
			-- -4, which is the 1px step that made the box look out of line.
			box:ClearAllPoints()
			box:SetPoint("TOP", filtersToggle, "TOP", 0, 0)
			box:SetPoint("LEFT", filtersToggle, "RIGHT", 1, 0)
			if filtersButton then
				box:SetPoint("RIGHT", filtersButton, "LEFT", -1, 0)
			else
				box:SetPoint("RIGHT", box:GetParent(), "RIGHT", -95, 0)
			end
		end
		seatSearchBox()
		hook(journal, "setScrollGridMounts", seatSearchBox)

		-- filtersBar draws its edge through SetBackdrop rather than as regions, so
		-- the fade inside S.Panel cannot reach it. Cleared by colour alpha, which
		-- keeps to the same alpha-only policy as everything else here.
		if journal.filtersBar then
			if journal.filtersBar.SetBackdropBorderColor then
				journal.filtersBar:SetBackdropBorderColor(0, 0, 0, 0)
			end
			S.Panel(journal.filtersBar)
		end

		if journal.gridModelSettings then
			skinSliderFrame(journal.gridModelSettings.strideSlider)
			-- The mounts-per-row value box is 28x17 by template, which
			-- lost some values; the same 22 height as the row's other
			-- controls, a little wider, centred on the slider beside it
			-- (slider: 17 tall, 2 up from the frame's bottom, in a 31 frame).
			local edit = journal.gridModelSettings.strideSlider
				and journal.gridModelSettings.strideSlider.edit
			if edit then
				edit:SetSize(34, 22)
				edit:ClearAllPoints()
				edit:SetPoint("RIGHT", journal.gridModelSettings.strideSlider, "RIGHT", -1, -5)
			end
		end
		ddButton(journal.gridModelAnimation)

	end)

	stage("journal:inspect", function()
		-- INSPECT
		local inspectFrame = journal.inspectFrame
		if inspectFrame then
			S.Panel(inspectFrame)
			if inspectFrame.TitleContainer and inspectFrame.TitleContainer.TitleBg then
				inspectFrame.TitleContainer.TitleBg:SetAlpha(0)
			end
			S.CloseButton(inspectFrame.close)
			ddStyle(inspectFrame.settings)
			addBorder(inspectFrame)
		end

	end)

	stage("journal:filtertabs", function()
		-- FILTER TABS
		if journal.filtersBar and journal.filtersBar.tabs then
			for _, tab in ipairs(journal.filtersBar.tabs) do
				S.FadeRegions(tab)
				if tab.selected then
					S.FadeRegions(tab.selected)
					-- `selected` is a child FRAME MountsJournal shows on the
					-- active tab, one level above the tab, so a wash drawn on
					-- it sat over the label and dulled it. The wash goes on
					-- the tab itself, BACKGROUND under the ARTWORK label, and
					-- follows the child's visibility instead of living on it.
					local selFrame = tab.selected
					local sel = tab:CreateTexture(nil, "BACKGROUND", nil, 1)
					sel:SetPoint("TOPLEFT", selFrame, "TOPLEFT", 3, -3)
					sel:SetPoint("BOTTOMRIGHT", selFrame, "BOTTOMRIGHT", -3, 3)
					addWash(sel, .2)
					local function pull() sel:SetShown(selFrame:IsShown()) end
					hook(selFrame, "Show", pull)
					hook(selFrame, "Hide", pull)
					hook(selFrame, "SetShown", pull)
					pull()
				end
				tab:HookScript("OnEnter", tabOnEnter)
				tab:HookScript("OnLeave", tabOnLeave)
				if tab.text then S.White(tab.text) end

				if tab.content and tab.content.childs then
					for _, btn in ipairs(tab.content.childs) do
						checkButton(btn)
					end
				end
			end
		end

	end)

	stage("journal:list", function()
		-- SHOWN PANEL / LIST
		if journal.shownPanel then
			-- Also an InsetFrameTemplate; blend the box away before painting.
			S.Inset(journal.shownPanel)
			S.Panel(journal.shownPanel)
			ddStyle(journal.shownPanel.resetFilter)
		end
		-- The list takes the darker inset plate the Rematch skin gives its
		-- pet lists, so the rows sit on a surface one step below the window
		-- rather than straight on the backdrop. Blend the InsetFrameTemplate
		-- box away first, as before.
		--
		-- The plate is a child frame rather than S.Panel on the inset
		-- itself, for two reasons. MountsJournal seats the scroll bar 4px
		-- OUTSIDE the inset's right edge (scrollBox inset 4, bar 8 to its
		-- right), and the plate should hold the bar too, so its right edge
		-- follows the bar's. And the plate is for the list only: the model
		-- grid is laid out with its own margins and a scroll column that
		-- read as a box-within-a-box once there was a plate to see them
		-- against, so it is hidden whenever the view is not the list.
		if bgFrame.leftInset then
			local inset = bgFrame.leftInset
			S.Inset(inset)
			--[[ Line up with Rematch's pet list on the tab next door ---------
				Measured with /mjeuiskin list on both tabs: Rematch's list
				sits at x=21 with its bottom at 745 and its bottom bar from
				743 down to 721; MountsJournal's column sat at x=20 with the
				Mount button from 744 to 722. One pixel right and, for the
				bottom row, one pixel down, and switching tabs stops
				twitching. That means every frame in the column: the filter
				block above (re-seated by MountsJournal on every view switch,
				so its +1 lives in the seatList hook), the Shown strip, the
				inset, and Mount, which is a SecureActionButton and so is
				moved once, out of combat, with a retry on leaving it.
				Nothing of MountsJournal's re-anchors the inset or the strip.
			------------------------------------------------------------------]]
			inset:SetPoint("LEFT", bgFrame, "LEFT", 5, 0)
			inset:SetPoint("BOTTOM", bgFrame, "BOTTOM", 0, 27)
			if journal.shownPanel then
				journal.shownPanel:SetPoint("LEFT", bgFrame, "LEFT", 5, 0)
			end
			-- The right-hand panel (the model display in list view; the map
			-- and its flags panel on the Map tab, both of which hang off it)
			-- is seated by MountsJournal 1px right of the filter block and
			-- with its bottom at 26. Its right edge is 4 from the window's,
			-- so give it the same 4 from the list column, and the same
			-- bottom as the list (27) so the two panels end level. Nothing
			-- of MountsJournal's re-anchors it.
			if bgFrame.rightInset and journal.filtersPanel then
				bgFrame.rightInset:SetPoint("TOPLEFT", journal.filtersPanel, "TOPRIGHT", 4, 0)
				bgFrame.rightInset:SetPoint("BOTTOM", bgFrame, "BOTTOM", 0, 27)
			end
			do
				local summon = journal.summonButton
				local function seatSummon()
					if not summon then return true end
					if InCombatLockdown and InCombatLockdown() then return false end
					summon:SetPoint("BOTTOMLEFT", bgFrame, "BOTTOMLEFT", 5, 3)
					return true
				end
				if not seatSummon() then
					local waiter = CreateFrame("Frame")
					waiter:RegisterEvent("PLAYER_REGEN_ENABLED")
					waiter:SetScript("OnEvent", function(self)
						if seatSummon() then
							self:UnregisterAllEvents()
							self:SetScript("OnEvent", nil)
						end
					end)
				end
			end

			-- The bar first: the narrowing below reads its width.
			local bar = inset.scrollBar
			if bar then S.ScrollBar(bar) end

			--[[ Width, and the bottom row under the list ------------------
				MountsJournal seats the scroll bar 4px OUTSIDE the inset's
				right edge (scrollBox inset 4, bar anchored 8 to its right),
				so a plate that holds the bar with the same 4px margin the
				rows have on the left ends at inset.right + 8 + barWidth. In
				list view the inset's right is at 267 and the MountsJournal
				checkbox, seated at x=281 by MountsJournal's secure handler on
				every show, sits 3px past where the bottom row should end
				(278). The bar is wider than 3px, so the plate overshot the
				checkbox, and ending the plate at the checkbox instead put
				the bar outside the plate (tried; it did).

				So the inset is narrowed from the right by the overshoot,
				barWidth - 3, once. That also answers the user's ask to pull
				the list in a touch, and it is view-independent: the inset
				keeps following the filters panel, which MountsJournal moves
				between views, so nothing here runs per view and the model
				grid's tile extents (computed from the scrollBox width) stay
				consistent. MountsJournal has already laid the grid out for
				the old width by the time this runs, so it is asked to lay
				out again next frame, the same call it makes after a resize
				drag, once the new width has resolved.
			------------------------------------------------------------------]]
			local barW = bar and bar:GetWidth() or 0
			if issecretvalue and issecretvalue(barW) then barW = 0 end
			barW = math.ceil(barW)
			local narrow = math.max(0, barW - 3)
			if narrow > 0 and journal.filtersPanel then
				listNarrow = narrow
				-- The filter block above the list (search row, Types /
				-- Selected / Sources, the type bar) is 280 wide from its
				-- template in the list and icon-grid views (in the model
				-- grid MountsJournal anchors its RIGHT instead, which wins
				-- over a width). The plate has to end where that block
				-- ends, or the type bar reads as belonging to a different
				-- column than the list it filters. So: the block gives up
				-- the 6px the checkbox forced off the plate, and the inset
				-- sits 8 + barWidth inside the block's right edge, which is
				-- exactly what puts the bar's 4px margin on the block's
				-- edge. Box width is unchanged by the pair.
				journal.filtersPanel:SetWidth(280 - 6)
				inset:SetPoint("RIGHT", journal.filtersPanel, "RIGHT", -(8 + barW), 0)

				-- The rows: see listNarrow. The view re-sizes every row to
				-- its template on acquire, so the shrink rides on that call;
				-- rows already acquired get it once here, and a later
				-- re-acquire resets to the template first, so it never
				-- compounds. Only list rows: a model tile has modelScene,
				-- the icon-grid button has no dragButton.
				local function narrowRow(frame)
					if frame and frame.dragButton and not frame.modelScene then
						local w = frame:GetWidth()
						if w and w > listNarrow + 60 then frame:SetWidth(w - listNarrow) end
					end
				end
				if journal.view and type(journal.view.ResizeFrame) == "function" then
					hook(journal.view, "ResizeFrame", function(_, _, frame) narrowRow(frame) end)
					if journal.view.GetFrames then
						for _, frame in ipairs(journal.view:GetFrames()) do narrowRow(frame) end
					end
				end
				if C_Timer then
					C_Timer.After(0, function()
						if journal.setScrollGridMounts then journal:setScrollGridMounts(true) end
					end)
				end
			end

			-- The bar, centred in its channel. The channel runs from the
			-- scroll box's right edge (the inset's less 4) to the plate's,
			-- which is the filter block's: 4 + 8 + barWidth wide, 20 here.
			-- MountsJournal seats the bar 8 right of the box, which put its
			-- groove right of centre; (20 - barWidth) / 2 = 6 centres it.
			-- Only the x changes; the 1px vertical inset is MountsJournal's.
			if bar and journal.scrollBox then
				-- (channel - barW) / 2 with channel = 4 + 8 + barW: the bar's
				-- own width cancels, so 6 whatever the bar measures.
				local x = 6
				bar:ClearAllPoints()
				bar:SetPoint("TOPLEFT", journal.scrollBox, "TOPRIGHT", x, 1)
				bar:SetPoint("BOTTOMLEFT", journal.scrollBox, "BOTTOMRIGHT", x, -1)
			end

			-- The plate: the inset's top, bottom and left, and the filter
			-- block's right, so it ends where the block ends whatever the
			-- bar does. Same four-anchor shape the inset's own XML uses.
			local plate = CreateFrame("Frame", nil, inset)
			plate:EnableMouse(false)
			plate:SetFrameLevel(inset:GetFrameLevel())
			plate:SetPoint("TOPLEFT", inset, "TOPLEFT", 0, 0)
			plate:SetPoint("BOTTOMLEFT", inset, "BOTTOMLEFT", 0, 0)
			if journal.filtersPanel then
				plate:SetPoint("RIGHT", journal.filtersPanel, "RIGHT", 0, 0)
			else
				plate:SetPoint("RIGHT", inset, "RIGHT", 0, 0)
			end
			S.Panel(plate, {inset = true})
			journal.euiListPlate = plate

			-- Mount (a SecureActionButton, 140 wide, seated BOTTOMLEFT 4,4
			-- and never moved by us) and the profile dropdown (130 wide, 4px
			-- to its right, seated by MountsJournal's Profiles module) ended
			-- a few pixels short of the plate, with a gap between them. In
			-- the list view the dropdown now fills from a 1px divide after
			-- Mount to the plate's right edge. In the grids the checkbox
			-- shares that row with a much wider panel, so the dropdown goes
			-- back to MountsJournal's own seat, and the plate is hidden on
			-- the model grid, whose tiles carry their own fill.
			local summon, menu = journal.summonButton, bgFrame.profilesMenu

			-- curGrid is 1 for the list, 2 for the icon grid, 3 for the
			-- model grid; setScrollGridMounts writes it on every switch.
			--[[ The model grid's first column, flush with the buttons -------
				The scroll box sits 4px inside the inset on every side, which
				is the list plate's margin. The model grid has no plate, so
				its tiles started 4px right of the Mount button below them.
				Shifting the grid would leave that 4px on the other side,
				before the bar; instead the box's LEFT goes to the inset's
				edge in that view only, and the tiles, sized by MountsJournal
				as floor(boxWidth / n), absorb the width.

				They are sized inside setScrollGridMounts, from the box as
				it is at that moment, so the box has to be re-seated BEFORE
				that read, not from the post-hook after it (a second layout a
				frame later fixed the size but showed as a hitch on every
				switch). setScrollGridMounts opens by asking getGridToggle
				which view is coming; a post-hook on that runs between the
				answer and the width read, and asks the same question itself
				(re-entrancy guarded) to learn the answer.
			------------------------------------------------------------------]]
			local function seatBox(self, grid)
				local box = self.scrollBox
				local wantLeft = (grid == 3) and 0 or 4
				if box and self.euiBoxLeft ~= wantLeft then
					self.euiBoxLeft = wantLeft
					box:SetPoint("TOPLEFT", inset, "TOPLEFT", wantLeft, -4)
				end
			end
			local asking = false
			hook(journal, "getGridToggle", function(self)
				if asking then return end
				asking = true
				local ok, grid = pcall(self.getGridToggle, self)
				asking = false
				if ok then seatBox(self, grid) end
			end)

			local function seatList(self)
				local list = self.curGrid == nil or self.curGrid == 1
				plate:SetShown(self.curGrid ~= 3)
				seatBox(self, self.curGrid)
				-- The filter block: MountsJournal has just seated it at x=4
				-- (or 1px left of the nav bar, which is at 5). One pixel
				-- right, keeping its own y and its RIGHT anchor.
				local fp = self.filtersPanel
				if fp and fp.GetPoint then
					local okP, point, rel, relPoint, x, y = pcall(fp.GetPoint, fp, 1)
					if okP and point == "TOPLEFT" and type(x) == "number" then
						fp:SetPoint("TOPLEFT", rel or bgFrame, relPoint or "TOPLEFT", x + 1, y or 0)
					end
				end
				if menu and summon then
					menu:ClearAllPoints()
					if list then
						menu:SetPoint("TOPLEFT", summon, "TOPRIGHT", 1, 0)
						-- Plate bottom 27, button bottoms 3.
						menu:SetPoint("BOTTOMRIGHT", plate, "BOTTOMRIGHT", 0, -24)
					else
						menu:SetSize(130, 22)
						menu:SetPoint("LEFT", summon, "RIGHT", 4, -.5)
					end
				end
			end
			hook(journal, "setScrollGridMounts", seatList)
			seatList(journal)
		end
		if journal.scrollBox then
			hook(journal.scrollBox, "Update", scrollMountButtons)
			scrollMountButtons(journal.scrollBox)
		end

		if journal.tags then ddStyle(journal.tags.mountOptionsMenu) end
		skinSliderFrame(journal.percentSlider)

	end)

	stage("journal:camera", function()
		-- CAMERA
		skinSliderFrame(journal.xInitialAcceleration)
		skinSliderFrame(journal.xAcceleration)
		skinSliderFrame(journal.xMinSpeed)
		skinSliderFrame(journal.yInitialAcceleration)
		skinSliderFrame(journal.yAcceleration)
		skinSliderFrame(journal.yMinSpeed)

		if bgFrame.mountColor then
			skinSliderFrame(bgFrame.mountColor.threshold)
			flatButton(bgFrame.mountColor.reset)
		end

	end)

	stage("journal:mountinfo", function()
		-- MOUNT INFO
		local mountInfo = journal.mountDisplay and journal.mountDisplay.info
		if mountInfo then
			ddStyle(mountInfo.linkLang)
			if mountInfo.linkLang and mountInfo.linkLang.arrow then
				mountInfo.linkLang.arrow:SetVertexColor(1, 1, 1, .9)
			end
			if mountInfo.icon then squareIcon(mountInfo.icon) end
			if mountInfo.mountDescriptionToggle then
				-- MJArrowToggle; the expand arrow is a parentKey "icon" region.
				S.Button(mountInfo.mountDescriptionToggle, {"icon"})
			end
			petSelectionBtnSkin(mountInfo.petSelectionBtn)

			-- The pet list is built on first click; skin it the moment it exists.
			if mountInfo.petSelectionBtn then
				mountInfo.petSelectionBtn:HookScript("OnClick", function(self)
					petListSkin(self.petSelectionList)
				end)
			end
			ddStyle(mountInfo.modelSceneSettingsButton)
		end

		ddStyle(journal.multipleMountBtn)
		if journal.modelScene then ddButton(journal.modelScene.animationsCombobox) end

	end)

	stage("journal:map", function()
		-- MAP
		-- worldMap, mapSettings and mapControl are all InsetFrameTemplate, so
		-- they carry a Bg plus a rounded NineSlice box, not just surface art.
		-- A region fade leaves the box standing, which is what put a
		-- Blizzard-sized panel behind the map. S.Inset is the durable form and
		-- zeroes the NineSlice container itself.
		if journal.worldMap then
			S.Inset(journal.worldMap)
			ddButton(journal.worldMap.navigation)
		end

		local mapSettings = journal.mapSettings
		if mapSettings then
			S.Inset(mapSettings)
			S.Panel(mapSettings)
			if mapSettings.mapControl then S.Inset(mapSettings.mapControl) end
			ddStretchButton(mapSettings.dnr)
			flatButton(mapSettings.CurrentMap)
			-- An MJArrowToggle, not a labelled button: its whole content is the
			-- parentKey "icon" arrow, so flatButton faded it and left an empty
			-- block at the right end of the row.
			toggleButton(mapSettings.existingListsToggle)

			-- Seat the three controls as one row. The stock anchors leave the
			-- gaps uneven once the native art is gone, because each template
			-- padded itself differently; chaining edge-to-edge with a 1px seam
			-- is what the ElvUI reference does and it is the only way the row
			-- lines up at every window width.
			--
			-- The row's OUTER edges anchor to mapSettings itself, not to
			-- mapControl, and flush at 0: the surface the row should line up
			-- with is the flags panel background, and that background is drawn
			-- on mapSettings. Anchoring to the frame that owns the background
			-- makes the edges match by construction. (A 1px hairline off
			-- mapControl was tried first and read as the row stopping short of
			-- the panel below it, a few pixels at screen scale, either side.)
			-- Vertical stays on mapControl, whose band the row sits in.
			local control = mapSettings.mapControl
			if control and mapSettings.CurrentMap and mapSettings.existingListsToggle then
				mapSettings.existingListsToggle:ClearAllPoints()
				mapSettings.existingListsToggle:SetPoint("TOP", control, "TOP", 0, -3)
				mapSettings.existingListsToggle:SetPoint("RIGHT", mapSettings, "RIGHT", 0, 0)

				-- The split between the two dropdowns. MountsJournal's 134
				-- truncated "Dungeons and Raids" to "Dungeons and R..." while
				-- "Current Location" had most of the row to itself; 170
				-- fits the longer label with margin and leaves the other
				-- plenty at the window's minimum width (the panel is ~440).
				mapSettings.CurrentMap:ClearAllPoints()
				mapSettings.CurrentMap:SetPoint("LEFT", control, "LEFT", 170, -1)
				mapSettings.CurrentMap:SetPoint("RIGHT",
					mapSettings.existingListsToggle, "LEFT", -1, 0)

				if mapSettings.dnr then
					mapSettings.dnr:ClearAllPoints()
					mapSettings.dnr:SetPoint("TOP", control, "TOP", 0, -3)
					mapSettings.dnr:SetPoint("LEFT", mapSettings, "LEFT", 0, 0)
					mapSettings.dnr:SetPoint("RIGHT", mapSettings.CurrentMap, "LEFT", -1, 0)
				end
			end

			S.Checkbox(mapSettings.Flags)
			S.Checkbox(mapSettings.Ground)
			S.Checkbox(mapSettings.WaterWalk)
			if mapSettings.HerbGathering then S.Checkbox(mapSettings.HerbGathering) end
			ddStretchButton(mapSettings.listFromMap)

			local existingLists = mapSettings.existingLists
			if existingLists then
				S.Panel(existingLists)
				editBox(existingLists.searchBox)
				S.ScrollBar(existingLists.scrollBar)
				addBorder(existingLists)
			end
		end

		flatButton(journal.summonButton)
		pinButtonFonts(journal.summonButton)
		ddStretchButton(bgFrame.profilesMenu)
		flatButton(journal.mountSpecial)

	end)

	stage("journal:calendar", function()
		-- CALENDAR
		if bgFrame.calendarFrame then
			S.FadeRegions(bgFrame.calendarFrame)
			S.PageButton(bgFrame.calendarFrame.prevMonthButton, "<")
			S.PageButton(bgFrame.calendarFrame.nextMonthButton, ">")
		end

	end)

	--[[ TABS ------------------------------------------------------------------
		The Model/Map/Settings row follows whichever look the Collections
		row beside it wears (see THE MODEL / MAP / SETTINGS ROW above). Where
		that row is stock, ours are deliberately NOT skinned, and this is the
		one place the addon is better off doing nothing. It took measuring
		both rows to see why.

		/mjeuiskin tabs put them side by side:

		  Collections (Pet Journal)  3 slices a=1.00 | 3 slices a=0.40 | WHITE8X8
		  Ours        (Map)          3 slices a=1.00 | 3 slices a=0.40 | our plate

		Identical three-slice geometry, 34x36 and 37x36 either side of a middle
		that scales with the label, and the same 36->42 growth on the selected
		tab. MountsJournal's tabs and Collections' tabs are the SAME Blizzard
		template. The only difference in the whole stack was what we added: an
		opaque plate over art that was already correct, plus a mirrored label
		and an accent underline.

		And on that client the row we were meant to match was stock as far
		as EllesmereUI is concerned: it shells the Collections window but
		does not skin its tabs, each one carries a single gold FontString,
		where an engine-skinned tab would carry two. So every step of
		skinning ours moved them further from their neighbours, which is
		exactly how it looked: repainting them to match a house style that
		was not on screen anywhere near this window.

		Leaving them alone makes them identical to the row beside them,
		because they are the same widget underneath. What that reading
		missed, found later through the Rematch skin, is that the row WAS
		being dressed, just not by EllesmereUI: atrocityEssentials was. So
		"match the row beside us" now means "wear whatever it wears", and
		the stock case is one of the three answers rather than the only one.
	--------------------------------------------------------------------------]]
	stage("journal:tabs", function()
		-- MJOptionBackgroundTemplate, which is an InsetFrameTemplate: the panel
		-- behind the whole Settings tab, so its NineSlice box showing through
		-- reads as a Blizzard-sized panel behind ours. The panel still wants
		-- blending; only its tabs are left as they are.
		if bgFrame.settingsBackground then
			local settingsBG = bgFrame.settingsBackground
			S.Inset(settingsBG)

			-- The config window's tabs are the opposite case to the row along
			-- the bottom. Those sit directly beside Collections' stock tabs and
			-- match by being left alone; these sit at the top of a panel we
			-- have skinned, with nothing native anywhere near them, so leaving
			-- them native makes them the only Blizzard widget in the window.
			-- Give them the flat treatment Mount and the profile selector have,
			-- since that is what surrounds them.
			local tabs = {}
			for _, child in ipairs({settingsBG:GetChildren()}) do
				if child.id and child.content and child.GetFontString then
					tabs[#tabs + 1] = child
				end
			end

			local function repaintTabs()
				for _, tab in ipairs(tabs) do
					if tab.euiWash then
						tab.euiWash:SetShown(settingsBG.selectedTab == tab.id)
					end
					-- Re-centre on every switch, not once at skin time.
					-- PanelTemplates re-seats a tab's label whenever selection
					-- changes, with a different offset per state, both of them
					-- measured against the tab art we have removed. That is why
					-- the labels sat low, and why the active one sat at a
					-- different height from the rest.
					local label = tab.euiLabel
					if label then
						label:ClearAllPoints()
						label:SetPoint("CENTER", tab, "CENTER", 0, 0)
					end
				end
			end

			-- Ordered by id, which the config sets explicitly, rather than by
			-- child order or screen position. Deterministic, so unlike the
			-- bottom row this cannot rebuild itself backwards.
			table.sort(tabs, function(a, b) return a.id < b.id end)

			for i, tab in ipairs(tabs) do
				flatButton(tab)

				-- PanelTopTabButtonTemplate's frame is considerably taller than
				-- the tab it draws; the surplus is transparent art above the
				-- label. Flattening the art to a solid block made that surplus
				-- visible as dead space along the top of every tab, so give
				-- them the height of the block instead and re-centre the label
				-- in it.
				tab:SetHeight(24)

				-- tab.Text first: on this template the label is a named key,
				-- and GetFontString can come back empty, in which case the
				-- re-centre below silently did nothing, which is why the text
				-- stayed low after the frame was resized.
				local label = tab.Text or (tab.GetFontString and tab:GetFontString())
				tab.euiLabel = label
				-- Zero the per-state offsets PanelTemplates applies, so its own
				-- re-seating lands centred too rather than fighting ours.
				tab.selectedTextX, tab.selectedTextY = 0, 0
				tab.deselectedTextX, tab.deselectedTextY = 0, 0

				-- Line the row up with the panel below it. The first tab sits
				-- at x=54 by default while the settings content starts at x=8,
				-- so the row read as indented from everything under it.
				tab:ClearAllPoints()
				if i == 1 then
					tab:SetPoint("TOPLEFT", settingsBG, "TOPLEFT", 8, 32)
				else
					tab:SetPoint("TOPLEFT", tabs[i - 1], "TOPRIGHT", 1, 0)
				end

				-- Which tab is current has to stay legible once they are all
				-- the same flat block, so the active one takes the accent wash
				-- used for every other selected thing in the addon.
				local wash = tab:CreateTexture(nil, "ARTWORK")
				wash:SetPoint("TOPLEFT", 1, -1)
				wash:SetPoint("BOTTOMRIGHT", -1, 1)
				addWash(wash, .25)
				wash:Hide()
				tab.euiWash = wash
				tab:HookScript("OnClick", repaintTabs)
			end
			settingsBG:HookScript("OnShow", repaintTabs)
			repaintTabs()
		end

		-- The Model/Map/Settings row: dressed to match whatever Collections'
		-- row wears, and where that row is stock, NOT touched at all: not its
		-- art, not its position, not its labels.
		--
		-- Two attempts to improve the stock case both made it worse than
		-- doing nothing. It was flattened to match Collections' row, on the
		-- evidence that their atlas regions were cleared and ours were not;
		-- that lost the native selected-tab growth, since the growth IS the
		-- taller activetab atlas, and left a flat plate that reads nothing
		-- like the row beside it. Seating it flush removed a 2px overlap that
		-- the native art is drawn to have.
		--
		-- Untouched, these are the same Blizzard template as Collections'
		-- tabs and they behave identically, growth included. That is the bar
		-- to beat for the stock case, and nothing tried so far has beaten it.
		-- The other two cases are the row beside us having already changed.
		dressBottomTabs(bgFrame)

		--[[ The window opens at its saved width, not a few pixels wider ---
			MountsJournal sizes the window at init as Clamp(saved, min,
			max), with min from getMinMaxSize, which reads the tab rows as
			they are at that moment: ours still 72 wide and at MountsJournal's
			own seat. So a saved width below that stale minimum opened wider
			than it should, and wider than the drag minimum once the skin had
			seated the tabs (reported: "reload lands wider than dragging to
			the minimum"). Once the window has laid out, re-do the clamp with
			the rows as they now are, then tell MountsJournal exactly what it
			tells itself after a resize drag. Once per session; from then on
			the bounds MountsJournal sets at drag start are live.
		--------------------------------------------------------------------]]
		local function reclampWidth()
			if journal.euiReclamped then return end
			local mj = _G.MountsJournal
			local cfg = mj and mj.config
			if not (cfg and journal.getMinMaxSize and bgFrame:IsVisible()) then return end
			if InCombatLockdown and InCombatLockdown() then return end
			local ok, minW, _, maxW = pcall(journal.getMinMaxSize, journal)
			if not (ok and minW and maxW) then return end
			journal.euiReclamped = true
			local w, h = bgFrame:GetSize()
			local want = Clamp(cfg.journalWidth or minW, minW, maxW)
			-- MountsJournal saves the width only when a resize drag stops,
			-- and a drag to the minimum saves whatever the minimum was at
			-- the time. Before this skin sized the tabs that was 706 (or 714
			-- with the tabs at MountsJournal's own seat), so a saved width
			-- sitting a few pixels above today's minimum is yesterday's
			-- minimum, not a choice: snap it to the minimum. The saved value
			-- is left alone; the next drag to the minimum rewrites it.
			if want > minW and want - minW <= 12 then want = minW end
			if w and h and math.abs(want - w) >= .5 then
				bgFrame:SetSize(want, h)
				if journal.setScrollGridMounts then journal:setScrollGridMounts(true) end
				if journal.event then pcall(journal.event, journal, "JOURNAL_RESIZED") end
			end
		end
		bgFrame:HookScript("OnShow", function()
			if C_Timer then C_Timer.After(0, reclampWidth) else reclampWidth() end
		end)
		if bgFrame:IsVisible() and C_Timer then C_Timer.After(0, reclampWidth) end
	end)

end


local function journal_updateFilterNavBar(journal)
	if not (journal.shownPanel and journal.shownPanel.framePool) then return end
	for btn in journal.shownPanel.framePool:EnumerateActive() do
		if not btn.euiSkinned then
			btn.euiSkinned = true
			S.Button(btn, {"texture"})
		end
	end
end


--[[ SUMMON PANEL --------------------------------------------------------------
	The two summon buttons are created inside MountsJournal's own ADDON_INIT,
	which fires during its PLAYER_LOGIN and is then unregistered, so hooking
	that event from our login-time callback would be a race. Instead we skin
	them whenever we next see them: at callback time, on the panel's first show,
	and again when the journal initialises. All three paths are idempotent.
------------------------------------------------------------------------------]]
local function skinSummonButton(btn)
	if not btn or btn.euiSkinned then return end
	btn.euiSkinned = true
	if btn.IconMask then btn.IconMask:SetAlpha(0) end
	itemButton(btn)
	addBorder(btn)
end


function skinSummonPanel()
	local panel = MountsJournal.summonPanel
	if not panel then return end
	skinSummonButton(panel.summon1)
	skinSummonButton(panel.summon2)
end


--[[ OPTIONS -------------------------------------------------------------------]]
local function config_onShow(self)
	if self.euiSkinned then return end
	self.euiSkinned = true

	S.Panel(self.leftPanel)
	S.Checkbox(self.waterJump)
	itemButton(self.summon1Icon)
	itemButton(self.summon2Icon)

	local function bindButton(btn)
		if not btn then return end
		S.Button(btn, {"selectedHighlight"})
		S.WhiteButtonLabel(btn)
		if btn.selectedHighlight then addWash(btn.selectedHighlight, .25) end
	end
	bindButton(self.bindSummon1Key1)
	bindButton(self.bindSummon1Key2)
	bindButton(self.bindSummon2Key1)
	bindButton(self.bindSummon2Key2)
	ddButton(self.modifierCombobox)

	S.Panel(self.rightPanel)
	if self.rightPanelScroll then
		S.ScrollBar(self.rightPanelScroll.ScrollBar)
		centreScrollBar(self.rightPanelScroll)
	end

	-- Grouped option blocks: flat inset panels with their checkboxes.
	local function group(frame, ...)
		if frame then S.Panel(frame, {inset = true}) end
		for i = 1, select("#", ...) do
			S.Checkbox((select(i, ...)))
		end
	end

	if self.showMinimapButton then
		group(self.minimapGroup, self.showMinimapButton, self.lockMinimapButton)
	end
	if self.useHerbMounts then
		group(self.herbGroup, self.useHerbMounts, self.herbMountsOnZones)
	end
	group(self.repairGroup, self.useRepairMounts, self.repairFlyable, self.freeSlots)
	ddButton(self.repairMountsCombobox)

	if self.magicBroomGroup then S.Panel(self.magicBroomGroup, {inset = true}) end
	S.Checkbox(self.useMagicBroom)
	if self.magicBroomCombobox then ddButton(self.magicBroomCombobox) end

	if self.useUnderlightAngler then
		group(self.underlightAnglerGroup, self.useUnderlightAngler, self.autoUseUnderlightAngler)
	end

	group(self.petGroup, self.summonPetEvery, self.summonPetOnlyFavorites,
		self.noPetInRaid, self.noPetInGroup)

	group(self.mountListGroup, self.arrowButtons, self.showTypeSelBtn)
	if self.coloredMountNames then S.Checkbox(self.coloredMountNames) end

	S.Checkbox(self.copyMountTarget)
	S.Checkbox(self.openLinks)
	S.Checkbox(self.showWowheadLink)
	S.Checkbox(self.statisticCollection)
	S.Checkbox(self.tooltipMount)

	if self.resetHelp then
		group(self.tooltipGroup, self.tooltipItems)
		flatButton(self.resetHelp)
	end
	flatButton(self.applyBtn)
	flatButton(self.cancelBtn)
end


--[[ ICON PICKER ---------------------------------------------------------------]]
local function config_iconData_onShow(self)
	if self.euiSkinned then return end
	self.euiSkinned = true

	S.Panel(self)
	itemButton(self.selectedIconBtn)
	editBox(self.searchBox)
	ddStretchButton(self.filtersButton)
	S.ScrollBar(self.scrollBar)
	flatButton(self.cancel)
	flatButton(self.ok)
	addBorder(self)

	if not self.scrollBox then return end

	local function skinIconRow(btn)
		if not btn or btn.euiSkinned then return end
		btn.euiSkinned = true
		-- Not itemButton: these rows need a border that tracks hover and
		-- selection rather than the static one it draws.
		S.Button(btn, {"icon"})
		if btn.icon then
			btn.icon:SetDrawLayer("OVERLAY")
			squareIcon(btn.icon)
			local state = newState(btn, btn.icon, 1)
			bindHover(btn, state)
			bindSelected(state, btn.selectedTexture)
		end
	end

	hook(self.scrollBox, "Update", function(frame)
		if not frame or not frame.ScrollTarget then return end
		eachChild(skinIconRow, frame.ScrollTarget:GetChildren())
	end)
end


--[[ CLASS SETTINGS ------------------------------------------------------------]]

-- The multi-line macro editors use a full WowScrollBar rather than the
-- MinimalScrollBar S.ScrollBar targets, so their arrows and thumb are handled
-- here. Alpha-only, and the thumb follows the accent live.
local function reskinEditScrollBar(scrollBar)
	if not scrollBar or scrollBar.euiSkinned then return end
	scrollBar.euiSkinned = true

	if scrollBar.Background then scrollBar.Background:SetAlpha(0) end
	S.FadeRegions(scrollBar)

	local track = scrollBar.Track
	if track then
		S.FadeRegions(track)
		local thumb = track.Thumb
		if thumb then
			S.FadeRegions(thumb)
			for _, k in ipairs({"Middle", "Begin", "End"}) do
				if thumb[k] then thumb[k]:SetAlpha(0) end
			end
			local t = thumb:CreateTexture(nil, "ARTWORK")
			t:SetPoint("TOP")
			t:SetPoint("BOTTOM")
			t:SetWidth(4)
			addWash(t, 1)
		end
	end

	S.PageButton(scrollBar.Back, "<")
	S.PageButton(scrollBar.Forward, ">")
end


local function classConfig_onShow(self)
	if self.euiSkinned then return end
	self.euiSkinned = true

	S.Panel(self.leftPanel)
	S.Checkbox(self.charCheck)

	-- Class icons: squared and bordered like every other icon. squareIcon now
	-- trims a proportion of their EXISTING sheet coords rather than replacing
	-- them, so the rounded corners baked into UI-CharacterCreate-Classes come
	-- off without disturbing which class the coords point at.
	if self.leftPanel then
		for _, btn in ipairs({self.leftPanel:GetChildren()}) do
			if btn.icon and not btn.euiIconEdged then
				btn.euiIconEdged = true
				squareIcon(btn.icon)
				newEdges(btn, btn.icon, 1)
			end
		end
	end

	S.Panel(self.rightPanel)
	if self.rightPanelScroll then
		S.ScrollBar(self.rightPanelScroll.ScrollBar)
		centreScrollBar(self.rightPanelScroll)
	end

	local function reskinEditBox(editFrame)
		if not editFrame then return end
		if editFrame.background then S.Panel(editFrame.background) end
		S.Checkbox(editFrame.enable)
		for _, k in ipairs({"defaultBtn", "cancelBtn", "saveBtn"}) do
			flatButton(editFrame[k])
		end
		if editFrame.limitText then S.Font(editFrame.limitText) end
		reskinEditScrollBar(editFrame.scrollBar)
	end

	reskinEditBox(self.moveFallMF)
	reskinEditBox(self.combatMF)
end


local function classConfig_showClassSettings(self)
	if self.sliderPool then
		for option in self.sliderPool:EnumerateActive() do
			if not option.euiSkinned then
				option.euiSkinned = true
				skinSliderFrame(option)
			end
		end
	end

	if self.checkPool then
		for option in self.checkPool:EnumerateActive() do
			if not option.euiSkinned then
				option.euiSkinned = true
				S.Checkbox(option)
			end
		end
	end
end


--[[ RULES ---------------------------------------------------------------------]]

-- Small inline dropdown buttons inside the rule editor.
local function ruleDropdown(btn)
	if not btn then return end
	S.Dropdown(btn)
end


local function ruleEditor_onShow(self)
	if self.euiSkinned then return end
	self.euiSkinned = true

	ddStyle(self.menu)
	if self.panel then S.Panel(self.panel) end
	S.ScrollBar(self.scrollBar)
	flatButton(self.cancel)
	flatButton(self.ok)

	if self.mapSelect then
		S.Panel(self.mapSelect)
		flatButton(self.mapSelect.cancel)
		flatButton(self.mapSelect.ok)
	end

	if self.mountSelect then
		S.Panel(self.mountSelect)
		S.CloseButton(self.mountSelect.close)
	end

	if self.scrollBox then
		local function skinRulePanel(panel)
			if not panel or panel.euiSkinned then return end
			panel.euiSkinned = true
			S.Checkbox(panel.notCheck)
			ruleDropdown(panel.optionType)
		end

		hook(self.scrollBox, "Update", function(frame)
			if not frame or not frame.ScrollTarget then return end
			eachChild(skinRulePanel, frame.ScrollTarget:GetChildren())
		end)
	end

	ruleDropdown(self.mapOptionBtn)
	if self.actionPanel then
		ruleDropdown(self.actionPanel.optionType)
		if self.actionPanel.macro then
			S.Panel(self.actionPanel.macro)
			reskinEditScrollBar(self.actionPanel.macro.scrollBar)
		end
		if self.actionPanel.groupName then editBox(self.actionPanel.groupName) end
	end

	local function onAcquire()
		if self.btnPool then
			for btn in self.btnPool:EnumerateActive() do
				if not btn.euiSkinned then
					btn.euiSkinned = true
					ruleDropdown(btn)
				end
			end
		end
		if self.editPool then
			for edit in self.editPool:EnumerateActive() do
				if not edit.euiSkinned then
					edit.euiSkinned = true
					if edit.border then edit.border:SetAlpha(0) end
					editBox(edit)
				end
			end
		end
	end

	hook(self, "setCondValueOption", onAcquire)
	hook(self, "setActionValueOption", onAcquire)
end


local function rules_onShow(self)
	if self.euiSkinned then return end
	self.euiSkinned = true

	ddStretchButton(self.ruleSets)
	flatButton(self.snippetToggle)
	ddButton(self.summons)
	flatButton(self.addRuleBtn)
	flatButton(self.importRuleBtn)
	editBox(self.searchBox)
	flatButton(self.resetRulesBtn)
	S.Checkbox(self.altMode)
	S.ScrollBar(self.scrollBar)
	ddStyle(self.ruleMenu)

	if self.ruleEditor then
		self.ruleEditor:HookScript("OnShow", ruleEditor_onShow)
	end
end


--[[ SNIPPETS ------------------------------------------------------------------]]
local function snippets_onShow(self)
	if self.euiSkinned then return end
	self.euiSkinned = true

	S.Panel(self)
	if self.TitleContainer and self.TitleContainer.TitleBg then
		self.TitleContainer.TitleBg:SetAlpha(0)
	end

	flatButton(self.addSnipBtn)
	flatButton(self.importBtn)
	editBox(self.searchBox)
	-- Also MJOptionBackgroundTemplate; needs the inset treatment, not a fade.
	if self.bg then S.Inset(self.bg) end
	S.ScrollBar(self.scrollBar)
	ddStyle(self.snipMenu)
	addBorder(self)
end


local function codeEdit_onShow(self)
	if self.euiSkinned then return end
	self.euiSkinned = true

	S.Panel(self)
	editBox(self.nameEdit)
	editBox(self.line)
	ddStretchButton(self.settings)
	ddStretchButton(self.examples)
	for _, k in ipairs({"nextBtn", "backBtn", "cancelBtn", "completeBtn"}) do
		flatButton(self[k])
	end
	if self.codeBtn then S.Panel(self.codeBtn, {inset = true}) end
	reskinEditScrollBar(self.scrollBar)
	addBorder(self)
end


local function dataDialog_onShow(self)
	if self.euiSkinned then return end
	self.euiSkinned = true

	S.Panel(self)
	if self.TitleContainer and self.TitleContainer.TitleBg then
		self.TitleContainer.TitleBg:SetAlpha(0)
	end
	editBox(self.nameEdit)
	if self.codeBtn then S.Panel(self.codeBtn, {inset = true}) end
	reskinEditScrollBar(self.scrollBar)
	flatButton(self.btn1)
	flatButton(self.btn2)
	addBorder(self)
end


--[[ DRESS UP ------------------------------------------------------------------]]
local function skinDressUpButton()
	local mjBtn = DressUpFrame and DressUpFrame.mjBtn
	if not mjBtn then return end

	-- The button's whole visual is its Normal/Pushed art, the RedButton-Expand
	-- arrow; it has no label and no named regions. Unnamed state textures
	-- cannot ride through keepKeys, so park them on keys of our own first,
	-- the same dance as dynamicFlightButton. Without this S.Button fades them
	-- and the hover tint below lands on invisible art: a blank block.
	mjBtn.euiNormal = mjBtn.GetNormalTexture and mjBtn:GetNormalTexture()
	mjBtn.euiPushed = mjBtn.GetPushedTexture and mjBtn:GetPushedTexture()
	S.Button(mjBtn, {"euiNormal", "euiPushed"})
	local normal, pushed = mjBtn.euiNormal, mjBtn.euiPushed

	local function colour(r, g, b)
		if normal then normal:SetVertexColor(r, g, b) end
		if pushed then pushed:SetVertexColor(r, g, b) end
	end
	mjBtn:HookScript("OnEnter", function() colour(S.GetAccentColor()) end)
	mjBtn:HookScript("OnLeave", function() colour(1, 1, 1) end)
end


--[[ COLLECTIONS BACKDROP ------------------------------------------------------
	MountsJournal draws its own window over Blizzard's Collections frame, at its
	own resizable size, so whatever sits behind shows around the edges. This is
	the "Blizzard-sized border and background behind our skinned one", most
	obvious on the Map tab, where the window is at its widest and the panel
	behind reaches furthest past it.

	The reference ElvUI skin is doing something more specific than it first
	looks. It hides `collect.backdrop`, not Blizzard's art, which ElvUI has
	already stripped for good when it skinned Collections, but ElvUI's OWN
	replacement backdrop, which would otherwise sit at Collections' fixed size
	behind a window that is not that size. Same shape of problem here, same fix,
	but the thing to hide is EllesmereUI's shell.

	And that is where the first attempt fell short. EllesmereUI's window engine
	puts its flat fill, atlas backdrop and black overlay on the frame as regions
	-- which a GetRegions() sweep does find, but it puts the window border in
	a CHILD FRAME (AtlasBorder creates one and parents a single atlas texture to
	it, so it can sit six levels above the backdrop). A regions sweep cannot see
	that, which is exactly why the border kept showing through after the
	background stopped.

	So the sweep now walks two levels down and matches the engine's own shell
	art by atlas and file name. That is deliberately narrow: it cannot touch
	Collections' content, only the two textures the window engine draws.

	Two further things were missing, both only visible once the window stopped
	being opaque, while it was painted with EllesmereUI's window art it hid
	whatever was behind it, and hid these bugs with it.

	1. BLIZZARD'S OWN MountJournal IS BEHIND US, NOT JUST COLLECTIONS.
	   MountsJournal parents its window to MountJournal.useMountsJournalButton,
	   so Blizzard's mount journal is literally our grandparent. MountsJournal's
	   hideFrames() hides its child frames, but only the UNPROTECTED ones, and
	   never MountJournal's own texture regions, and EllesmereUI skins that
	   frame too. That is the residual pane at Blizzard's default size.

	   The sweep must not descend into our own window while doing this: with the
	   Blizzard-art backdrop selected, bgFrame carries the very textures we
	   match on, and we would zero our own shell.

	2. A ONE-SHOT FADE LOSES A RACE IT CANNOT WIN.
	   The window engine re-raises its own backdrop alpha whenever it restyles,
	   with the comment "a foreign restrip pass may have zeroed it", and we
	   are exactly that foreign pass. Fading once on show is undone the next
	   time anything triggers a restyle. So suppression re-asserts on regions it
	   already owns, and is replayed after the engine has had its turn.

	This is the one place the addon reaches past MountsJournal's own frames, and
	it stays within the same policy as everything else: alpha only, regions
	only, fully reversible, nothing Hide()n, reparented or rescripted. Note the
	regions-only part is load-bearing here, MountJournal is our ancestor, so
	dropping the alpha of the FRAME would take our own window with it.
------------------------------------------------------------------------------]]
local collectionsArt = setmetatable({}, {__mode = "k"})

-- Fills in the forward declaration up by the diagnostic.
function isSuppressed(region) return collectionsArt[region] ~= nil end

-- The window engine's two shell textures: the AdventureMap_TopBorder frame
-- atlas, and the modern_blizz backdrop. Matched by identity rather than by
-- position so a future engine change to layering cannot slip past us.
local SHELL_ATLAS = "AdventureMap_TopBorder"
local SHELL_FILE = "modern_blizz"


local function isShellArt(region)
	if not (region.IsObjectType and region:IsObjectType("Texture")) then return false end
	if region.GetAtlas and region:GetAtlas() == SHELL_ATLAS then return true end
	local file = region.GetTexture and region:GetTexture()
	return type(file) == "string" and file:find(SHELL_FILE, 1, true) ~= nil
end


--[[ MATCH BY GEOMETRY, NOT BY TEXTURE IDENTITY --------------------------------
	Every previous version of this test tried to recognise EllesmereUI's chrome
	by what texture it was, and every one got it wrong in a different way:

	  - matched atlas and file name, so SetColorTexture plates (no atlas, no
	    file) could never match;
	  - then treated a colour texture as "nil or a string naming white/solid",
	    so the plate reporting the NUMBER -666 fell into the reject branch;
	  - then treated a positive fileID as proof of real art, but
	    PP.CreateBorder's strips are SetTexture(WHITE8X8), whose fileID is
	    130871, positive. Rejected again.

	Three wrong guesses at one question. So stop asking it. What actually
	matters is not what a texture is made of but WHERE IT IS: anything sizeable
	inside our window's rect, belonging to a frame behind us, is chrome we are
	covering. MountsJournal hides Blizzard's own frames while its window is up,
	so there is no content back there to protect, and this stays alpha-only and
	restored on close.

	The overlap test earns its keep immediately. Collections' bottom TAB ROW
	sits just below our window, CollectionsJournalTab2 and Tab5 showed up in
	the report at y 569-596 against our window's 599, and those tabs are live
	navigation the user clicks. A rule based on texture identity would have
	blanked them, since they are built from the very same WHITE8X8 strips and
	colour plates. A rule based on position cannot: they do not overlap us.
------------------------------------------------------------------------------]]
local PLATE_MIN = 120

local function overlaps(ax, ay, aw, ah, bx, by, bw, bh)
	return ax < bx + bw and bx < ax + aw and ay < by + bh and by < ay + ah
end


-- win = {x, y, w, h} of our own window, in screen coordinates.
local function isChrome(region, win)
	if not (region.IsObjectType and region:IsObjectType("Texture")) then return false end
	if not win then return false end

	local x, y, w, h = rectOf(region)
	if not (x and w and h) then return false end

	-- Plates and hairline border strips alike: sizeable in at least one axis.
	-- A 703x1 edge is as much chrome as a 703x606 fill.
	if w < PLATE_MIN and h < PLATE_MIN then return false end

	return overlaps(x, y, w, h, win.x, win.y, win.w, win.h)
end


local function stash(region)
	if not (region and region.GetAlpha and region.SetAlpha) then return end

	if collectionsArt[region] then
		-- Already ours. Re-assert rather than return: the engine puts its own
		-- backdrop alpha back whenever it restyles, so without this a single
		-- restyle undoes the whole suppression and the pane reappears.
		region:SetAlpha(0)
		return
	end

	local a = region:GetAlpha()
	if a and a > 0 then
		collectionsArt[region] = a
		region:SetAlpha(0)
	end
end


-- Every texture the frame itself draws, plus the pieces Blizzard hangs off
-- named keys rather than plain regions.
local function stashOwnArt(frame)
	if not (frame and frame.GetRegions) then return end
	for i = 1, select("#", frame:GetRegions()) do
		stash((select(i, frame:GetRegions())))
	end
	if frame.NineSlice then stash(frame.NineSlice) end
	if frame.PortraitContainer then stash(frame.PortraitContainer) end
end


-- Chrome parked in child frames: the engine's border overlay, and its panel
-- and inset plates. Four levels rather than two, because the plates live on
-- MountJournal's insets, which are deeper than Collections' own border frame.
local function stashShellArt(frame, depth, skip, win)
	if depth > 4 or not frame.GetChildren then return end
	for i = 1, select("#", frame:GetChildren()) do
		local child = select(i, frame:GetChildren())
		if child and child.GetRegions and not child:IsForbidden() and not skip[child] then
			for j = 1, select("#", child:GetRegions()) do
				local r = select(j, child:GetRegions())
				if r and (isShellArt(r) or isChrome(r, win)) then stash(r) end
			end
			stashShellArt(child, depth + 1, skip, win)
		end
	end
end


function fadeCollections(fade)
	local collect = CollectionsJournal
	local mountJournal = MountJournal

	if not fade then
		for region, alpha in pairs(collectionsArt) do
			if region.SetAlpha then region:SetAlpha(alpha) end
		end
		wipe(collectionsArt)
		return
	end

	-- Our own window and the button it hangs from. Everything below these is
	-- ours to draw, and with the Blizzard-art backdrop selected our shell is
	-- made of the same textures the sweep matches on.
	local skip = {}
	local journal = MountsJournalFrame
	if journal then
		if journal.bgFrame then skip[journal.bgFrame] = true end
		if journal.useMountsJournalButton then
			skip[journal.useMountsJournalButton] = true
		end
	end

	-- Our window's rect decides what counts as "behind us". Without it there is
	-- nothing to compare against, so the sweep does nothing rather than
	-- guessing, notably it will not touch the bottom tab row.
	local wx, wy, ww, wh = rectOf(journal and journal.bgFrame)
	local win = wx and {x = wx, y = wy, w = ww, h = wh} or nil

	if collect then
		stashOwnArt(collect)
		if collect.CloseButton then stash(collect.CloseButton) end
		if CollectionsJournalTitleText then stash(CollectionsJournalTitleText) end
		stashShellArt(collect, 1, skip, win)
	end

	-- Blizzard's mount journal: our own grandparent, directly behind the
	-- window. Regions only, see the header; alpha on the frame would take us
	-- down with it.
	if mountJournal then
		stashOwnArt(mountJournal)
		stashShellArt(mountJournal, 1, skip, win)
	end
end


-- Suppress, then suppress again after the engine has had its turn. Its
-- Collections re-skin is debounced onto a later frame, so whichever of us runs
-- first, this makes us last. Cheap: each replay is a few table lookups per
-- region once everything is already stashed.
function suppressBehind()
	fadeCollections(true)
	if not C_Timer then return end
	local journal = MountsJournalFrame
	local bgFrame = journal and journal.bgFrame
	for _, delay in ipairs({0, .1, .5}) do
		C_Timer.After(delay, function()
			if bgFrame and bgFrame:IsShown() then fadeCollections(true) end
		end)
	end
end


--[[ ENTRY POINT ---------------------------------------------------------------]]

-- journal_init touches well over a hundred frames, any one of which could have
-- moved between MountsJournal versions. Isolated so a single bad frame costs
-- that one line's worth of skin rather than the whole window.
local function initJournal(journal)
	if journal and journal.bgFrame then stage("journal_init", journal_init, journal) end
end


local function skinUI()
	-- LibSFDropDown ships inside MountsJournal's UI addon, which loads on
	-- demand AFTER our PLAYER_LOGIN dispatch, so the login-time resolution in
	-- stage("menuStyle") can run before the library exists and come up empty:
	-- that was the permanent "dropdown menu style: NO" with every stage ok.
	-- skinUI only runs once MountsJournalFrame does, which is after that
	-- addon has loaded, so this retry is the one that sticks. Guarded, so on
	-- setups where the first pass already resolved it this is a no-op.
	stage("menuStyleLate", setupMenuStyle)

	stage("tooltip", function()
		if MJTooltipModel then S.Panel(MJTooltipModel) end
	end)

	stage("journal", function()
	local journal = MountsJournalFrame
	if journal then
		S.Checkbox(journal.useMountsJournalButton)

		-- Timing here is genuinely awkward and worth spelling out. The reference
		-- hooks journal:init at file-load time, before anything can have run.
		-- EllesmereUI dispatches at PLAYER_LOGIN instead, by which point
		-- MountsJournal may already have built its journal, init deletes
		-- itself when it runs (`self.init = nil`), and so does the ADDON_LOADED
		-- handler that leads to it. Hooking either one is therefore a bet on
		-- load order that we lose on some setups, with nothing skinned at all.
		--
		-- So do not bet. Hook init when it is still pending as the early path,
		-- and otherwise drive off the window itself: bgFrame's first OnShow is
		-- unmissable and by definition late enough that everything exists.
		-- journal_init guards itself, so every path is safe to fire.
		if journal.init then
			hook(journal, "init", initJournal)
		end
		-- Whether or not the hook above took, the window's own first OnShow is
		-- unmissable and late enough that everything exists. initJournal guards
		-- itself, so both firing is fine.
		initJournal(journal)
		if journal.useMountsJournalButton then
			journal.useMountsJournalButton:HookScript("OnShow", function()
				initJournal(MountsJournalFrame)
			end)
		end
		hook(journal, "updateFilterNavBar", journal_updateFilterNavBar)
	end
	end)

	stage("config", function()
		if MountsJournalConfig then
			MountsJournalConfig:HookScript("OnShow", config_onShow)
			if MountsJournalConfig.iconData then
				MountsJournalConfig.iconData:HookScript("OnShow", config_iconData_onShow)
			end
		end
	end)

	stage("classes", function()
		if MountsJournalConfigClasses then
			MountsJournalConfigClasses:HookScript("OnShow", classConfig_onShow)
			hook(MountsJournalConfigClasses, "showClassSettings", classConfig_showClassSettings)
		end
	end)

	stage("rules", function()
		if MountsJournalConfigRules then
			MountsJournalConfigRules:HookScript("OnShow", rules_onShow)
		end
	end)

	stage("snippets", function()
		if MountsJournalSnippets then
			MountsJournalSnippets:HookScript("OnShow", snippets_onShow)
		end
		if MountsJournalCodeEdit then
			MountsJournalCodeEdit:HookScript("OnShow", codeEdit_onShow)
		end
		if MountsJournalDataDialog then
			MountsJournalDataDialog:HookScript("OnShow", dataDialog_onShow)
		end
	end)

	stage("dressup", skinDressUpButton)
end


--[[ SETTINGS PANEL ------------------------------------------------------------
	Window backdrop and opacity, then border style and size, the last two
	offering EllesmereUI's own texture list so users see the same names,
	including Glow and Shadow, that they get in the rest of the suite.
	Registered through Blizzard's Settings API, which means no custom widgets
	and no dependency on EllesmereUI's options internals.

	Wrapped in pcall: if the Settings API signature ever shifts under us, the
	panel quietly does not appear rather than throwing on load, and the saved
	choices still apply.
------------------------------------------------------------------------------]]
local function buildOptions()
	if not (Settings and Settings.RegisterVerticalLayoutCategory
		and Settings.RegisterAddOnSetting and Settings.CreateDropdown) then return end

	local category = Settings.RegisterVerticalLayoutCategory("MountsJournal EllesmereUI Skin")

	-- WINDOW BACKDROP
	if ns.CanStyleShell and ns.CanStyleShell() then
		local bgSetting = Settings.RegisterAddOnSetting(category,
			"MJEUISkin_Backdrop", "backdrop", db, Settings.VarType.String,
			"Window backdrop", DEFAULTS.backdrop)
		bgSetting:SetValueChangedCallback(applyShell)

		Settings.CreateDropdown(category, bgSetting, function()
			local container = Settings.CreateControlTextContainer()
			container:Add("fill", "EllesmereUI Dark Mode",
				"The colour and transparency your unit frames, bars and panels use.")
			container:Add("blizz", "Blizzard window art",
				"EllesmereUI's own window texture, matching Pet Journal and Toy Box. Always opaque.")
			return container:GetData()
		end, "What the journal window is painted with.")

		-- Blizzard has spelled this both ways across expansions and neither is
		-- guaranteed on a given client. Getting it wrong would cost the whole
		-- options panel, including the backdrop control above, which is the
		-- one that actually matters here, so probe rather than assume.
		local makeCheckbox = Settings.CreateCheckbox or Settings.CreateCheckBox
		if makeCheckbox then
			local followSetting = Settings.RegisterAddOnSetting(category,
				"MJEUISkin_FollowOpacity", "followOpacity", db,
				Settings.VarType.Boolean, "Follow EllesmereUI opacity",
				DEFAULTS.followOpacity)
			followSetting:SetValueChangedCallback(applyShell)
			makeCheckbox(category, followSetting,
				"Use your Dark Mode transparency. Turn off to set it yourself below.")
		end

		local edgeSetting = Settings.RegisterAddOnSetting(category,
			"MJEUISkin_WindowBorder", "windowBorder", db, Settings.VarType.String,
			"Window edge", DEFAULTS.windowBorder)
		edgeSetting:SetValueChangedCallback(applyShell)

		Settings.CreateDropdown(category, edgeSetting, function()
			local container = Settings.CreateControlTextContainer()
			container:Add("line", "Thin dark line",
				"A crisp 1px edge, as dark as the other windows read, with no inner shading.")
			container:Add("art", "EllesmereUI window frame",
				"The exact frame EllesmereUI draws on its own windows. Carries a soft inner falloff.")
			container:Add("none", "None", "No edge of our own.")
			return container:GetData()
		end, "The outermost edge of the journal window.")

		local opacitySetting = Settings.RegisterAddOnSetting(category,
			"MJEUISkin_Opacity", "opacity", db, Settings.VarType.Number,
			"Opacity", DEFAULTS.opacity)
		opacitySetting:SetValueChangedCallback(applyShell)

		if Settings.CreateSlider and Settings.CreateSliderOptions then
			local options = Settings.CreateSliderOptions(0, 100, 1)
			if MinimalSliderWithSteppersMixin then
				options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right)
			end
			Settings.CreateSlider(category, opacitySetting, options,
				"Ignored while Follow EllesmereUI opacity is on. Has no effect on Blizzard window art, which cannot be made transparent.")
		end
	end

	local styleSetting = Settings.RegisterAddOnSetting(category,
		"MJEUISkin_BorderStyle", "borderStyle", db, Settings.VarType.String,
		"Border style", DEFAULTS.borderStyle)
	styleSetting:SetValueChangedCallback(refreshBorders)

	Settings.CreateDropdown(category, styleSetting, function()
		local container = Settings.CreateControlTextContainer()
		container:Add("auto", "Follow EllesmereUI",
			"Use the window border set in EllesmereUI's own options, including its size.")
		container:Add("none", "None")
		if EllesmereUI.GetBorderTextureList then
			for _, entry in ipairs(EllesmereUI.GetBorderTextureList()) do
				container:Add(entry.key, entry.name)
			end
		end
		return container:GetData()
	end, "Border drawn around the MountsJournal windows. Uses EllesmereUI's own border list.")

	local sizeSetting = Settings.RegisterAddOnSetting(category,
		"MJEUISkin_BorderSize", "borderSize", db, Settings.VarType.Number,
		"Border size", DEFAULTS.borderSize)
	sizeSetting:SetValueChangedCallback(refreshBorders)

	if Settings.CreateSlider and Settings.CreateSliderOptions then
		local options = Settings.CreateSliderOptions(1, 4, 1)
		-- Label formatter is cosmetic; never let it cost us the whole panel.
		if MinimalSliderWithSteppersMixin then
			options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right)
		end
		Settings.CreateSlider(category, sizeSetting, options,
			"Border thickness, 1 (thin) to 4 (heavy).")
	end

	Settings.RegisterAddOnCategory(category)
end


--[[ REGISTRATION --------------------------------------------------------------
	One callback, fired once at PLAYER_LOGIN. Every step is staged so that a
	failure in any one of them costs that step alone, EllesmereUI wraps the
	whole callback in a single pcall, so without this the first error anywhere
	silently abandons everything after it.
------------------------------------------------------------------------------]]
ns.RegisterSkin(ADDON_NAME, function(skin)
	-- Our own view of the facade, not the facade itself. A great many of
	-- MountsJournal's panels, every MJOptionsPanel, the filters bar, the
	-- macro editors, are BackdropTemplate frames that draw their fill and
	-- edge through SetBackdrop rather than as texture regions. No region fade
	-- can reach that, so it survives underneath as a second panel with its own
	-- outline. Clearing it belongs with painting it, not remembered at two
	-- dozen call sites.
	--
	-- Copying rather than assigning into `skin` is the point: on the api
	-- backend that table is EllesmereUI's own, shared with every other addon it
	-- skins, and writing to it would change their primitives too.
	S = setmetatable({
		Panel = function(frame, opts)
			clearBackdrop(frame)
			return skin.Panel(frame, opts)
		end,

		-- FadeRegions means "make this art go away", and the call sites do not
		-- all hand it a frame. levelBG, the plate behind a pet's level number,
		-- is a bare Texture rather than a container of them. The engine's
		-- version walks frame:GetRegions() with no type check, so a Texture
		-- reaching it is a hard error; the compat shim type-checks first and so
		-- silently does nothing. Neither is what the call site asked for, and
		-- the two backends have to read the same from up here, so absorb the
		-- difference once rather than at two dozen call sites: a Texture goes to
		-- alpha 0, which is exactly what fading its regions would have done had
		-- it been the frame we assumed.
		FadeRegions = function(frame, keep)
			if not frame then return end
			if not frame.GetRegions then
				if frame.IsObjectType and frame:IsObjectType("Texture") then
					frame:SetAlpha(0)
				end
				return
			end
			return skin.FadeRegions(frame, keep)
		end,
	}, {__index = skin})

	stage("db", resolveDB)
	-- Before anything builds a window, so the shell is painted right the first
	-- time rather than repainted after the fact.
	stage("shell", applyShell)
	stage("menuStyle", setupMenuStyle)
	stage("looksHook", function() S.OnLooksChanged(looksChanged) end)

	stage("summonPanel", function()
		skinSummonPanel()
		if MountsJournal.summonPanel then
			MountsJournal.summonPanel:HookScript("OnShow", skinSummonPanel)
		end
	end)

	-- Our own listener rather than a hook on MountsJournal's ADDON_LOADED
	-- handler: that handler nils itself and unregisters the event the moment it
	-- has loaded the UI, so hooking it only works if we happen to get there
	-- first. Waiting for the frame to exist works whatever the load order was.
	if MountsJournalFrame then
		skinUI()
	else
		local waiter = CreateFrame("Frame")
		waiter:RegisterEvent("ADDON_LOADED")
		waiter:SetScript("OnEvent", function(self)
			if MountsJournalFrame then
				self:UnregisterAllEvents()
				self:SetScript("OnEvent", nil)
				skinUI()
			end
		end)
	end

	stage("options", buildOptions)
end)
