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


local function rectOf(obj)
	local ok, l, b, w, h = pcall(function()
		return obj:GetLeft(), obj:GetBottom(), obj:GetWidth(), obj:GetHeight()
	end)
	if not ok or not l or not w then return nil end
	if issecretvalue and (issecretvalue(l) or issecretvalue(w)) then return nil end
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


--[[ HOW DOES THE ROW NEXT TO US ACTUALLY LOOK ---------------------------------
	/mjeuiskin tabs, run with the journal open.

	Our tabs are meant to match Collections' own row directly beside them, and
	whether they do depends on something not readable from source: whether
	EllesmereUI skinned that row at all on this client. Its Collections pack
	reaches the tabs by fixed keys (MountsTab, PetsTab, ...), so a Blizzard
	rename leaves them stock, and stock tabs carry Blizzard's gold label,
	which is nothing like the white one the engine paints.

	Rather than guess which of those two we should be copying, print every
	label with its actual colour and let the comparison settle it.
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
	print(("  %s [%s]: %s"):format(label,
		tab:IsShown() and "shown" or "hidden",
		#bits > 0 and table.concat(bits, "  ") or "no FontString"))

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
	print("  |cffffff00Collections' own row|r (what we should match):")
	local collect = CollectionsJournal
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
	local bgFrame = MountsJournalFrame and MountsJournalFrame.bgFrame
	if bgFrame and type(bgFrame.Tabs) == "table" then
		for i = 1, #bgFrame.Tabs do
			local tab = bgFrame.Tabs[i]
			local left = tab and tab.GetLeft and tab:GetLeft()
			dumpTab(("bgFrame.Tabs[%d] left=%s"):format(i, tostring(left and math.floor(left))), tab)
		end
	end
end


SLASH_MJEUISKIN1 = "/mjeuiskin"
SlashCmdList.MJEUISKIN = function(msg)
	local function yn(v) return v and "|cff44ff44yes|r" or "|cffff5555NO|r" end
	print("|cff0bd29dMountsJournal EllesmereUI Skin|r")

	if type(msg) == "string" and msg:lower():find("behind") then
		reportBehind()
		return
	end
	if type(msg) == "string" and msg:lower():find("tabs") then
		reportTabs()
		return
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


local function newEdges(parent, region, pad)
	pad = pad or 0

	-- The strips live on a child frame of ours rather than directly on the
	-- host. EllesmereUI re-fades every unprotected region of a skinned frame
	-- when it restrips (it does so whenever Collections is shown, which is our
	-- window), and only regions it knows about survive. Putting ours one level
	-- down puts them out of reach entirely, the same shape the suite's own
	-- PP border container uses, and for the same reason.
	local host = CreateFrame("Frame", nil, parent)
	host:SetAllPoints(region)
	host:EnableMouse(false)
	host:SetFrameLevel(parent:GetFrameLevel() + 1)

	local edges = {}
	for i = 1, 4 do
		local t = host:CreateTexture(nil, "OVERLAY", nil, 7)
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


local function newState(parent, region, pad)
	local state = {edges = newEdges(parent, region, pad)}
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


local function looksChanged()
	for tex, alpha in pairs(washes) do paintWash(tex, alpha) end
	for state in pairs(stateBorders) do paintState(state) end
	for slider in pairs(sliders) do paintSlider(slider) end
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
				local state = newState(infoFrame, infoFrame.icon, 1)
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

	local infoFrame = btn.infoFrame
	if not infoFrame then return end

	if infoFrame.icon then
		squareIcon(infoFrame.icon)
		local state = newState(infoFrame, infoFrame.icon, 1)
		bindHover(btn, state)
		bindQuality(state, infoFrame.qualityBorder)
	end
	if infoFrame.levelBG then S.FadeRegions(infoFrame.levelBG) end
	if infoFrame.level then S.Font(infoFrame.level) end
end


--[[ MOUNT SCROLL BUTTONS ------------------------------------------------------]]
-- Hoisted out of the loop so it is created once rather than per Update.
local function skinMountRow(btn)
	if btn and not btn.euiSkinned then
		btn.euiSkinned = true

		if btn.modelScene then
			-- Grid view: a model tile with a drag button over it. Art is
			-- faded by name rather than wholesale, these rows carry
			-- meaningful regions (faction, pet type) alongside the chrome.
			newState(btn, btn, 0)

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


-- Split into isolated sections on purpose. This function reaches well over a
-- hundred frames across MountsJournal's whole UI, and any one of those paths
-- could move between versions. Run as a single block, one wrong frame costs the
-- entire window; run like this, it costs its own section and says which.
local function journal_init(journal)
	local bgFrame = journal.bgFrame
	if not bgFrame or journal.euiInit then return end
	journal.euiInit = true

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
		-- filtersButton is deliberately untouched. MountsJournal already
		-- chains it LEFT to the search box and TOPRIGHT to the panel, so it
		-- fills whatever is left; re-anchoring it would drop the right edge.
		local gridToggle, filtersToggle = journal.gridToggleButton, journal.filtersToggle
		if gridToggle and filtersToggle then
			gridToggle:SetSize(22, 22)
			filtersToggle:SetSize(22, 22)
			gridToggle:ClearAllPoints()
			gridToggle:SetPoint("TOPLEFT", 3, -4)
			filtersToggle:ClearAllPoints()
			filtersToggle:SetPoint("LEFT", gridToggle, "RIGHT", 1, 0)
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
			box:SetPoint("LEFT", filtersToggle, "RIGHT", 4, 0)
			box:SetPoint("RIGHT", box:GetParent(), "RIGHT", -95, 0)
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
					local sel = tab.selected:CreateTexture(nil, "BACKGROUND")
					sel:SetPoint("TOPLEFT", 3, -3)
					sel:SetPoint("BOTTOMRIGHT", -3, 3)
					addWash(sel, .2)
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
		if bgFrame.leftInset then S.Inset(bgFrame.leftInset) end
		if journal.leftInset then S.ScrollBar(journal.leftInset.scrollBar) end
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
			-- The 3px inset either end was the stock spacing, sized for art with
			-- its own transparent margin. Flattened to solid blocks it reads as
			-- the row failing to reach the panel it sits in, so bring both ends
			-- out to a 1px hairline off the container edge.
			local EDGE = 1
			local control = mapSettings.mapControl
			if control and mapSettings.CurrentMap and mapSettings.existingListsToggle then
				mapSettings.existingListsToggle:ClearAllPoints()
				mapSettings.existingListsToggle:SetPoint("TOPRIGHT", control, "TOPRIGHT", -EDGE, -3)

				mapSettings.CurrentMap:ClearAllPoints()
				mapSettings.CurrentMap:SetPoint("LEFT", control, "LEFT", 134, -1)
				mapSettings.CurrentMap:SetPoint("RIGHT",
					mapSettings.existingListsToggle, "LEFT", -1, 0)

				if mapSettings.dnr then
					mapSettings.dnr:ClearAllPoints()
					mapSettings.dnr:SetPoint("TOPLEFT", control, "TOPLEFT", EDGE, -3)
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
		The tabs are deliberately NOT skinned, and this is the one place the
		addon is better off doing nothing. It took measuring both rows to see
		why.

		/mjeuiskin tabs put them side by side:

		  Collections (Pet Journal)  3 slices a=1.00 | 3 slices a=0.40 | WHITE8X8
		  Ours        (Map)          3 slices a=1.00 | 3 slices a=0.40 | our plate

		Identical three-slice geometry, 34x36 and 37x36 either side of a middle
		that scales with the label, and the same 36->42 growth on the selected
		tab. MountsJournal's tabs and Collections' tabs are the SAME Blizzard
		template. The only difference in the whole stack was what we added: an
		opaque plate over art that was already correct, plus a mirrored label
		and an accent underline.

		And the row we are meant to match is stock. EllesmereUI shells the
		Collections window but does not skin its tabs on this client, each one
		carries a single gold FontString, where a skinned tab would carry two.
		So every step of skinning ours moved them further from their neighbours,
		which is exactly how it looked: repainting them to match a house style
		that is not on screen anywhere near this window.

		Leaving them alone makes them identical to the row beside them, because
		they are the same widget underneath. If EllesmereUI ever does skin
		Collections' tabs, this is the line to revisit, S.Tab is still in the
		facade, and one call per tab brings the house style back.
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

		-- The Model/Map/Settings row is deliberately NOT touched: not its art,
		-- not its position, not its labels.
		-- 
		-- Two attempts to improve it both made it worse than doing nothing. It
		-- was flattened to match Collections' row, on the evidence that their
		-- atlas regions were cleared and ours were not; that lost the native
		-- selected-tab growth, since the growth IS the taller activetab atlas, and
		-- left a flat plate that reads nothing like the row beside it. Seating it
		-- flush removed a 2px overlap that the native art is drawn to have.
		-- 
		-- Untouched, these are the same Blizzard template as Collections' tabs
		-- and they behave identically, growth included. That is the bar to beat,
		-- and nothing tried so far has beaten it.
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
