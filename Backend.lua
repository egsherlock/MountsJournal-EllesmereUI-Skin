--[[----------------------------------------------------------------------------
	MountsJournal EllesmereUI Skin: skinning backend

	Resolves the primitive facade (`S`) the skin body draws through, from one of
	two sources, chosen at PLAYER_LOGIN:

	  api     EllesmereUI.RegisterSkin exists AND its dispatcher is live
	          (8.6.8+ with the EllesmereUIBlizzardSkin child addon enabled).
	          We register through the official API, appear under Blizzard
	          Window Skins > Third-Party Addons and follow its toggles, and
	          inherit EllesmereUI's own primitives -- except Shell, ScrollBar
	          and Checkbox, which stay ours because the engine's versions do
	          not reproduce this skin's approved look. See HYBRID FACADE.

	  compat  8.6.6 and earlier, or 8.6.8+ without the child addon running.
	          Rebuilds the same facade from the public helpers 8.6.6 does
	          export, the accent colour, the UI font, the pixel-perfect border
	          helper, the Dark Mode fill and the Blizzard window style
	          accessor.

	Why this file exists at all is the single most expensive lesson from
	Postbox, repeated here verbatim because this addon had shipped with exactly
	the same bug:

	> Verifying that an API exists in a project's *source* is not the same as
	> verifying it exists in a *release the user can install*.

	The first version of this skin guarded on `EllesmereUI.RegisterSkin ~= nil`
	at file scope and returned. RegisterSkin landed on EllesmereUI's master on
	2026-07-29; the newest tagged release is still 8.6.6, which is what is
	actually installed. So the addon was inert for every real user, the
	journal came up wholly unskinned, which is precisely the "Blizzard
	background is still showing" symptom this was reported as.

	The switch is automatic on update: when the user's EllesmereUI gains a
	LIVE RegisterSkin, the `api` backend takes over. Live is the operative
	word: the 8.6.8 parent ships the RegisterSkin stub even when the child
	addon is disabled, documented as "a silent no-op", so existence alone
	proves nothing -- the gate is the dispatcher the child assigns at load.
	`/mjeuiskin` prints which backend is live.

	MATCHING THE WINDOW BEHIND US
	-----------------------------
	Postbox's shim draws a flat GetDarkModeFill() plate, because a free-floating
	addon window should match the user's unit frames. This window must not do
	that. MountsJournal draws over CollectionsJournal, and the user tabs
	sideways from it into Pet Journal and Toy Box, windows EllesmereUI shells
	itself. A flat plate here would read as a different window in the same seat.

	So Shell() mirrors EllesmereUIBlizzardSkin's own window engine instead:
	the same style resolution (GetBlizzWindowStyle "collections"), the same
	cover-fit modern_blizz atlas plus 0.62 black overlay for `eui`, the same
	flat user colour for `modern`, the same 25px title bar and the same
	AdventureMap_TopBorder frame atlas. Tabbing between Mounts and Pet Journal
	crosses no visual seam.
------------------------------------------------------------------------------]]

local ADDON_NAME, ns = ...

local EUI = EllesmereUI
if not EUI then return end

local select, ipairs, pairs, type = select, ipairs, pairs, type
local CreateFrame, hooksecurefunc = CreateFrame, hooksecurefunc

-- 12.0 secret values: reading a tainted size returns a value that errors on
-- arithmetic. The engine guards every such read; so do we.
local issecretvalue = issecretvalue or function() return false end


--[[ THEME ---------------------------------------------------------------------
	Re-resolved on every call rather than cached, so a profile switch or an
	accent change is picked up without a reload wherever we repaint. These are
	the same constants EllesmereUIBlizzardSkin's own Theme table carries; the
	greys are engine constants, the accent and font are user settings.
------------------------------------------------------------------------------]]
local Theme = {}

local function resolveTheme()
	local green = EUI.ELLESMERE_GREEN or {r = .047, g = .824, b = .616}
	Theme.accR, Theme.accG, Theme.accB = green.r or .047, green.g or .824, green.b or .616
	Theme.bgR, Theme.bgG, Theme.bgB, Theme.bgA = .08, .08, .08, .92
	Theme.insetR, Theme.insetG, Theme.insetB, Theme.insetA = .04, .04, .04, .85
	Theme.brdR, Theme.brdG, Theme.brdB, Theme.brdA = .2, .2, .2, 1

	-- Tab labels. Measured rather than assumed: /mjeuiskin tabs reported
	-- Collections' own row as a single FontString per tab, gold at full alpha
	-- when unselected and white when selected. A tab the window engine had
	-- skinned would carry TWO (Blizzard's zeroed, plus its own), so that row
	-- is stock Blizzard, and the engine's white-at-half-alpha scheme is not on
	-- screen anywhere near this window to match.
	--
	-- So follow Blizzard's convention, which is what the row beside ours is
	-- actually using. Sourced from the globals rather than written out, so a
	-- client that retunes them carries us along.
	local normal = NORMAL_FONT_COLOR
	local high = HIGHLIGHT_FONT_COLOR
	Theme.tabR = normal and normal.r or 1
	Theme.tabG = normal and normal.g or .82
	Theme.tabB = normal and normal.b or 0
	Theme.tabSelR = high and high.r or 1
	Theme.tabSelG = high and high.g or 1
	Theme.tabSelB = high and high.b or 1
	Theme.fontPath = (EUI.GetFontPath and EUI.GetFontPath("blizzardSkin")) or STANDARD_TEXT_FONT
	Theme.fontFlag = (EUI.GetFontOutlineFlag and EUI.GetFontOutlineFlag("blizzardSkin")) or ""
	-- Drop shadow only in no-outline mode, honouring the user's shadow toggle.
	Theme.fontShadow = (Theme.fontFlag == "")
		and (not EUI.GetFontUseShadow or EUI.GetFontUseShadow("blizzardSkin"))
end
resolveTheme()


--[[ PER-FRAME STATE -----------------------------------------------------------
	The engine keeps its state in a weak-keyed table outside the frames rather
	than on them, so it never collides with Blizzard or addon keys and never
	holds a frame alive. Same here.
------------------------------------------------------------------------------]]
local FD = setmetatable({}, {__mode = "k"})

local function fd(frame)
	local d = FD[frame]
	if not d then d = {}; FD[frame] = d end
	return d
end


local function forbidden(frame)
	return frame.IsForbidden and frame:IsForbidden()
end


local function solid(parent, layer, r, g, b, a, sublevel)
	local t = parent:CreateTexture(nil, layer, nil, sublevel)
	t:SetColorTexture(r, g, b, a)
	return t
end


--[[ ART REMOVAL ---------------------------------------------------------------
	Alpha only, never Hide(). Same policy as the skin body, so every
	change is reversible and nothing we do to a frame we do not own can survive
	as a layout change.
------------------------------------------------------------------------------]]
local function fadeRegions(frame, keep)
	if not frame or not frame.GetRegions or forbidden(frame) then return end
	for i = 1, select("#", frame:GetRegions()) do
		local r = select(i, frame:GetRegions())
		if r and r.IsObjectType and r:IsObjectType("Texture") and not (keep and keep[r]) then
			r:SetAlpha(0)
		end
	end
	if frame.NineSlice then fadeRegions(frame.NineSlice, keep) end
end


local NINESLICE_PIECES = {
	"TopLeftCorner", "TopRightCorner", "BottomLeftCorner", "BottomRightCorner",
	"TopEdge", "BottomEdge", "LeftEdge", "RightEdge", "Center",
}

-- Blizzard re-lays-out NineSlice pieces on some updates, notably on every
-- resize, and this window is resizable, so alpha each named piece as well as
-- the container, which a relayout cannot undo.
local function fadeNineSlice(nsl)
	if not nsl then return end
	fadeRegions(nsl)
	for _, k in ipairs(NINESLICE_PIECES) do
		local p = nsl[k]
		if p and p.SetAlpha then p:SetAlpha(0) end
	end
	if nsl.SetAlpha then nsl:SetAlpha(0) end
end


local function addBorder(frame, r, g, b, a)
	local d = fd(frame)
	if d.border then return end
	local PP = EUI.PanelPP or EUI.PP
	if PP and PP.CreateBorder then
		PP.CreateBorder(frame, r or Theme.brdR, g or Theme.brdG, b or Theme.brdB,
			a or Theme.brdA, 1, "OVERLAY", 7)
		d.border = true
	end
end


--[[ WINDOW SHELL --------------------------------------------------------------
	A faithful rebuild of EllesmereUIBlizzardSkin's WSkin.Shell, so this window
	is indistinguishable from the Collections window it sits on top of.

	Both backdrop variants are built and the one matching the user's style for
	the "collections" window is shown, exactly as the engine does it, so a live
	style switch only needs the alphas swapped.
------------------------------------------------------------------------------]]
local SHELL_TEX = "Interface\\AddOns\\EllesmereUI\\media\\modern_blizz.png"
local BORDER_ATLAS = "AdventureMap_TopBorder"
local BG_ASPECT = 561 / 433
local BASE_L, BASE_R, BASE_T, BASE_B = .25, 1, 0, .75
local BASE_U, BASE_V = BASE_R - BASE_L, BASE_B - BASE_T

-- The window key we inherit our look from. MountsJournal replaces the mounts
-- half of Collections, so it follows whatever the user set for Collections.
local WIN_KEY = "collections"

local MODERN_FALLBACK = {r = .067, g = .067, b = .067, a = .97}

local function modernBG()
	local c = EllesmereUIDB and EllesmereUIDB.blizzWindowModernDefault
	if not (c and c.r) then c = MODERN_FALLBACK end
	return c.r or MODERN_FALLBACK.r, c.g or MODERN_FALLBACK.g,
		c.b or MODERN_FALLBACK.b, c.a or MODERN_FALLBACK.a
end


local function windowStyle()
	if EUI.GetBlizzWindowStyle then
		local ok, style = pcall(EUI.GetBlizzWindowStyle, WIN_KEY)
		if ok and style then return style end
	end
	return "eui"
end


--[[ THE BASELINE THE REST OF THE UI ACTUALLY SHARES ---------------------------
	GetDarkModeFill resolves the ACTIVE PROFILE's darkMode table, falling back
	to DEFAULT_DARK_MODE. Colour *and* alpha. This is the one value genuinely
	shared across the user's whole UI, unit frames, bars, panels, and it is
	what a profile import such as atrocityUI or AES actually writes. Reading the
	accessor rather than hardcoding means we follow a profile switch for free,
	and it works for everyone, not just people running those profiles: they are
	only setting EllesmereUI's own keys.

	  DEFAULT_DARK_MODE   #111111 @ 0.90
	  atrocityUI / AES    #080808 @ 0.80
------------------------------------------------------------------------------]]
local function hostBaseline()
	if EUI.GetDarkModeFill then
		local ok, r, g, b, a = pcall(EUI.GetDarkModeFill)
		if ok and r then return r, g, b, a or 1 end
	end
	local d = EUI.DEFAULT_DARK_MODE
	if d then
		return d.fillR or .067, d.fillG or .067, d.fillB or .067, d.fillA or .90
	end
	return .067, .067, .067, .90
end


--[[ BACKDROP MODE -------------------------------------------------------------
	Two ways to paint the window, because they are genuinely different goals and
	neither is right for everyone:

	"fill"   A flat plate in the Dark Mode colour, at the Dark Mode alpha. This
	         matches the user's unit frames, bars and panels, and it is the only
	         option that can be transparent at all.

	"blizz"  EllesmereUI's own window art, the modern_blizz atlas under a 0.62
	         black wash, so the window matches the Blizzard windows either side
	         of it (Pet Journal, Toy Box).

	"fill" is the default, and the reason is worth recording because it cost
	real time to learn. modern_blizz.png is a palette PNG with NO tRNS chunk:
	every pixel is 100% opaque, so that backdrop can never be made
	see-through, and a plate placed underneath it is simply invisible. It is
	also cover-fit cropped to each window's aspect ratio, so a resizable window
	shows a different, and differently lit, region of the image than a fixed
	Blizzard window does. Two windows following the identical recipe still will
	not match. The flat fill has neither problem.

	Opacity: nil follows the Dark Mode alpha, a number overrides it. Only the
	texture's OWN alpha produces transparency, an additive black wash makes a
	window darker while leaving it just as see-through.
------------------------------------------------------------------------------]]
local shellMode, shellAlpha = "fill", nil

-- Which edge the window gets. Kept independent of the backdrop mode, because
-- they answer different questions: the backdrop decides whether the window
-- matches the user's panels or Blizzard's windows, the border decides how its
-- outermost edge reads against the windows either side of it.
--
--   "line"  a crisp 1px edge, drawn in the window-edge tone below rather than
--           the panel tone. Default.
--   "art"   AdventureMap_TopBorder, the frame atlas EllesmereUI puts on the
--           windows it skins. Matches them exactly, but the atlas carries a
--           soft inner falloff that reads as a shadow inside the window once
--           the backdrop behind it is transparent rather than opaque, which
--           is why it is not the default.
--   "none"  no edge of our own.
local shellBorder = "line"

-- Theme.brd (.2) is the PANEL tone, and it is right there: it is what makes
-- an inset read as raised against the fill. On a window's outermost edge, with
-- the game world immediately behind it, the same value reads as a bright
-- outline instead. EllesmereUI's own windows have no line here at all; their
-- edge is the atlas, which reads near-black. So the window edge gets its own,
-- much darker tone: crisp like the line, dark like the atlas, and with none of
-- the atlas's inner falloff.
local EDGE_R, EDGE_G, EDGE_B, EDGE_A = 0, 0, 0, 1

-- Weak keys: a shell entry must not be what keeps a window alive.
local shells = setmetatable({}, {__mode = "k"})

local function shellOpacity()
	if shellAlpha then return shellAlpha end
	local _, _, _, a = hostBaseline()
	return a or .90
end


local function applyShellStyle(frame)
	local d = FD[frame]
	if not d then return end
	local alpha = shellOpacity()

	if shellMode == "blizz" then
		-- EllesmereUI's own window art, following the user's per-window style.
		local modern = windowStyle() == "modern"
		if d.bg then d.bg:SetAlpha(modern and 0 or alpha) end
		if d.bgOverlay then d.bgOverlay:SetAlpha(modern and 0 or alpha) end
		if d.modernBg then
			if modern then
				local r, g, b = modernBG()
				d.modernBg:SetColorTexture(r, g, b, 1)
				d.modernBg:SetAlpha(alpha)
			else
				d.modernBg:SetColorTexture(0, 0, 0, 0)
			end
		end
		if d.fill then d.fill:SetAlpha(0) end
	else
		if d.bg then d.bg:SetAlpha(0) end
		if d.bgOverlay then d.bgOverlay:SetAlpha(0) end
		if d.modernBg then d.modernBg:SetColorTexture(0, 0, 0, 0) end
		if d.fill then
			local r, g, b = hostBaseline()
			d.fill:SetColorTexture(r, g, b, 1)
			d.fill:SetAlpha(alpha)
		end
	end

	if d.atlasBorderFrame then d.atlasBorderFrame:SetShown(shellBorder == "art") end
	if d.lineBorderFrame then d.lineBorderFrame:SetShown(shellBorder == "line") end

	if d.topBar then d.topBar:SetAlpha(alpha) end
end


local function refreshShells()
	for frame in pairs(shells) do applyShellStyle(frame) end
end


local function atlasBorder(frame)
	local d = fd(frame)
	if d.atlasBorder then return end
	d.atlasBorder = true

	local info = C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(BORDER_ATLAS)
	if not info then
		addBorder(frame)
		return
	end

	local ov = CreateFrame("Frame", nil, frame)
	ov:SetAllPoints(frame)
	ov:SetFrameLevel(frame:GetFrameLevel() + 6)
	ov:EnableMouse(false)
	d.atlasBorderFrame = ov

	local tex = ov:CreateTexture(nil, "OVERLAY", nil, 7)
	tex:SetAtlas(BORDER_ATLAS)
	tex:SetAllPoints(ov)
end


-- The crisp 1px house line, on a child frame of ours so it can be toggled
-- against the atlas chrome. PP.CreateBorder writes textures onto whatever frame
-- it is handed, so it has to be its own host to stay addressable.
local function lineBorder(frame)
	local d = fd(frame)
	if d.lineBorderFrame then return end
	local host = CreateFrame("Frame", nil, frame)
	host:SetAllPoints(frame)
	host:EnableMouse(false)
	host:SetFrameLevel(frame:GetFrameLevel() + 6)
	local PP = EUI.PanelPP or EUI.PP
	if PP and PP.CreateBorder then
		PP.CreateBorder(host, EDGE_R, EDGE_G, EDGE_B, EDGE_A, 1, "OVERLAY", 7)
	end
	host:Hide()
	d.lineBorderFrame = host
end


local function shell(frame, opts)
	if not frame or forbidden(frame) then return end
	local d = fd(frame)
	if d.shell then return end
	d.shell = true

	fadeRegions(frame)
	fadeNineSlice(frame.NineSlice)

	local bg = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
	bg:SetTexture(SHELL_TEX)
	bg:SetAllPoints(frame)
	d.bg = bg

	local overlay = frame:CreateTexture(nil, "BACKGROUND", nil, -7)
	overlay:SetColorTexture(0, 0, 0, .62)
	overlay:SetAllPoints(frame)
	d.bgOverlay = overlay

	local mbg = frame:CreateTexture(nil, "BACKGROUND", nil, -6)
	mbg:SetColorTexture(0, 0, 0, 0)
	mbg:SetAllPoints(frame)
	d.modernBg = mbg

	-- The flat Dark Mode plate. It sits ABOVE the atlas rather than below it:
	-- modern_blizz.png is fully opaque, so a plate underneath would be
	-- invisible no matter what alpha it carried. Whichever backdrop is not in
	-- use is driven to alpha 0 by applyShellStyle.
	local fill = frame:CreateTexture(nil, "BACKGROUND", nil, -5)
	fill:SetAllPoints(frame)
	d.fill = fill

	-- Cover-fit: crop the atlas so it fills the frame without stretching. This
	-- window is resizable, so unlike a fixed Blizzard window it has to be
	-- recomputed on every drag of the grip, not just once.
	local function updateTexCoords()
		local w, h = frame:GetSize()
		if not w or w == 0 or not h or h == 0 then return end
		if issecretvalue(w) or issecretvalue(h) then return end
		local aspect = w / h
		if aspect > BG_ASPECT then
			local visV = BASE_V * (BG_ASPECT / aspect)
			local trim = (BASE_V - visV) / 2
			bg:SetTexCoord(BASE_L, BASE_R, BASE_T + trim, BASE_B - trim)
		else
			local visU = BASE_U * (aspect / BG_ASPECT)
			local trim = (BASE_U - visU) / 2
			bg:SetTexCoord(BASE_L + trim, BASE_R - trim, BASE_T, BASE_B)
		end
	end
	hooksecurefunc(frame, "SetSize", updateTexCoords)
	hooksecurefunc(frame, "SetWidth", updateTexCoords)
	hooksecurefunc(frame, "SetHeight", updateTexCoords)
	updateTexCoords()

	-- No title strip. The engine lays a 25px black bar behind a window's title,
	-- and copying it is what put a darker band across the top of this one,
	-- but the Collections window this sits in front of shows no such band, so
	-- here it reads as an artefact rather than as house style. The backdrop
	-- runs edge to edge instead.

	if not (opts and opts.noBorder) then
		atlasBorder(frame)
		lineBorder(frame)
	end

	shells[frame] = true
	applyShellStyle(frame)
end


--[[ PRIMITIVES ----------------------------------------------------------------
	One-for-one with EllesmereUIBlizzardSkin's own, including the guard shape:
	every one bails after a single table lookup on an already-skinned frame, so
	calling them from refresh hooks costs nothing.
------------------------------------------------------------------------------]]
local Shim = {}

function Shim.FadeRegions(frame, keep) fadeRegions(frame, keep) end
function Shim.FadeNineSlice(nsl) fadeNineSlice(nsl) end
function Shim.Shell(frame, opts) shell(frame, opts) end


function Shim.Panel(frame, opts)
	if not frame or forbidden(frame) then return end
	opts = opts or {}
	local d = fd(frame)
	local keep = {}
	if d.bg then keep[d.bg] = true end
	fadeRegions(frame, keep)
	if not d.bg and not opts.noBg then
		local r, g, b, a = Theme.bgR, Theme.bgG, Theme.bgB, Theme.bgA
		if opts.inset then r, g, b, a = Theme.insetR, Theme.insetG, Theme.insetB, Theme.insetA end
		if opts.shade then r, g, b, a = 0, 0, 0, .25 end
		local bg = solid(frame, "BACKGROUND", r, g, b, a, -6)
		bg:SetAllPoints(frame)
		d.bg = bg
	end
	if not opts.noBorder then addBorder(frame) end
end


-- InsetFrameTemplate: a Bg texture plus a rounded NineSlice box. Blend it away
-- rather than painting it, so it reads as part of the shell.
function Shim.Inset(inset)
	if not inset or forbidden(inset) then return end
	fadeRegions(inset)
	if inset.Bg then inset.Bg:SetAlpha(0) end
	if inset.NineSlice then fadeNineSlice(inset.NineSlice) end
end


function Shim.Font(fs, r, g, b)
	if not fs or not fs.GetFont or forbidden(fs) then return end
	local _, size = fs:GetFont()
	if size and issecretvalue(size) then return end
	-- 12.0.7: shadows render only from a FontObject, never from an instance
	-- SetShadowOffset. Prime BEFORE SetFont, which restores the face.
	if EUI.PrimeFontShadow then pcall(EUI.PrimeFontShadow, fs, Theme.fontShadow) end
	fs:SetFont(Theme.fontPath, size or 12, Theme.fontFlag or "")
	if r then fs:SetTextColor(r, g, b or r) end
end


function Shim.White(fs, r, g, b)
	if fs and fs.SetTextColor then fs:SetTextColor(r or 1, g or 1, b or 1) end
end


-- keepKeys names regions that carry meaning (an icon, a faction badge) and
-- must survive the flatten.
function Shim.Button(btn, keepKeys)
	if not btn or forbidden(btn) then return end
	local d = fd(btn)
	if d.skinned then return end
	d.skinned = true

	local keep = {}
	if keepKeys then
		for _, k in ipairs(keepKeys) do
			local r = btn[k]
			if r then keep[r] = true end
		end
	end
	fadeRegions(btn, keep)
	for _, getter in ipairs({"GetNormalTexture", "GetPushedTexture",
		"GetDisabledTexture", "GetHighlightTexture"}) do
		local fn = btn[getter]
		local t = fn and fn(btn)
		if t and not keep[t] then t:SetAlpha(0) end
	end
	for _, k in ipairs({"Left", "Middle", "Right", "LeftSeparator", "RightSeparator"}) do
		local r = btn[k]
		if r and not keep[r] and r.SetAlpha then r:SetAlpha(0) end
	end

	local fill = solid(btn, "BACKGROUND", Theme.bgR, Theme.bgG, Theme.bgB, Theme.bgA)
	fill:SetAllPoints(btn)
	d.bg = fill
	addBorder(btn)

	local hover = solid(btn, "HIGHLIGHT", 1, 1, 1, .1)
	hover:SetAllPoints(btn)
	d.hover = hover
end


-- Buttons re-apply their font object when re-enabled, so re-white on OnEnable
-- as well as now.
function Shim.WhiteButtonLabel(btn)
	if not btn or forbidden(btn) then return end
	local lab = btn.Text or (btn.GetFontString and btn:GetFontString())
	if not lab then return end
	Shim.White(lab)
	local d = fd(btn)
	if not d.whiteHook then
		d.whiteHook = true
		if btn.HookScript then
			btn:HookScript("OnEnable", function() Shim.White(lab) end)
		end
	end
end


function Shim.EditBox(eb)
	if not eb or forbidden(eb) then return end
	local d = fd(eb)
	if d.bg then return end
	fadeRegions(eb)
	for _, k in ipairs({"Left", "Right", "Middle", "Mid"}) do
		local r = eb[k]
		if r and r.SetAlpha then r:SetAlpha(0) end
	end
	local fill = solid(eb, "BACKGROUND", .02, .02, .02, 1)
	fill:SetAllPoints(eb)
	d.bg = fill
	addBorder(eb)
end


function Shim.Checkbox(cb)
	if not cb or forbidden(cb) then return end
	local d = fd(cb)
	if d.skinned then return end
	d.skinned = true
	if cb.SetNormalTexture then cb:SetNormalTexture("") end
	if cb.SetPushedTexture then cb:SetPushedTexture("") end
	if cb.SetHighlightTexture then cb:SetHighlightTexture("") end

	local checked = cb.GetCheckedTexture and cb:GetCheckedTexture()
	for i = 1, select("#", cb:GetRegions()) do
		local r = select(i, cb:GetRegions())
		if r and r ~= checked and r.IsObjectType and r:IsObjectType("Texture") then
			r:SetAlpha(0)
		end
	end

	local fill = solid(cb, "BACKGROUND", .02, .02, .02, 1)
	fill:SetPoint("TOPLEFT", 4, -4)
	fill:SetPoint("BOTTOMRIGHT", -4, 4)
	d.bg = fill

	-- The border hugs the fill rather than the frame. A checkbox frame is
	-- usually larger than the box it draws, the extra is click area, so a
	-- border on the frame rect sits proud of the fill by that 4px inset and
	-- the checkbox reads taller than the buttons beside it. The engine offers
	-- this as opts.borderInset; here it is unconditional, because the fill is
	-- unconditionally inset by the same 4.
	local host = CreateFrame("Frame", nil, cb)
	host:SetPoint("TOPLEFT", 4, -4)
	host:SetPoint("BOTTOMRIGHT", -4, 4)
	host:EnableMouse(false)
	host:SetFrameLevel(cb:GetFrameLevel() + 1)
	addBorder(host, .25, .25, .25, 1)
	d.borderHost = host
	if checked then
		checked:SetVertexColor(Theme.accR, Theme.accG, Theme.accB, 1)
		d.check = checked
	end
end


function Shim.CloseButton(btn)
	if not btn or forbidden(btn) then return end
	local d = fd(btn)
	if d.x then return end
	if btn.SetNormalTexture then btn:SetNormalTexture("") end
	if btn.SetPushedTexture then btn:SetPushedTexture("") end
	if btn.SetHighlightTexture then btn:SetHighlightTexture("") end
	if btn.SetDisabledTexture then btn:SetDisabledTexture("") end
	fadeRegions(btn)

	local x = btn:CreateTexture(nil, "OVERLAY")
	x:SetAtlas("uitools-icon-close")
	x:SetSize(14, 14)
	x:SetPoint("CENTER", -2, 0)
	x:SetVertexColor(1, 1, 1, .75)
	d.x = x
	btn:HookScript("OnEnter", function() x:SetVertexColor(1, 1, 1, 1) end)
	btn:HookScript("OnLeave", function() x:SetVertexColor(1, 1, 1, .75) end)
end


function Shim.Dropdown(dd)
	if not dd or forbidden(dd) then return end
	local d = fd(dd)
	if d.skinned then return end
	d.skinned = true
	fadeRegions(dd)

	local name = dd.GetName and dd:GetName()
	if name then
		for _, suffix in ipairs({"Left", "Middle", "Right"}) do
			local r = _G[name .. suffix]
			if r and r.SetAlpha then r:SetAlpha(0) end
		end
	end
	if dd.Background then dd.Background:SetAlpha(0) end
	if dd.Texture then dd.Texture:SetAlpha(0) end

	local fill = solid(dd, "BACKGROUND", Theme.bgR, Theme.bgG, Theme.bgB, Theme.bgA)
	fill:SetAllPoints(dd)
	d.bg = fill
	addBorder(dd, .25, .25, .25, 1)

	local hover = solid(dd, "HIGHLIGHT", 1, 1, 1, .05)
	hover:SetAllPoints(dd)
	d.hover = hover

	-- Our own arrow; Blizzard's went with the rest of the art. Sized to the
	-- atlas's native 62x44 aspect.
	local arrow = dd:CreateTexture(nil, "OVERLAY")
	arrow:SetAtlas("Azerite-PointingArrow")
	arrow:SetSize(14, 10)
	arrow:SetPoint("RIGHT", dd, "RIGHT", -6, 0)
	d.arrow = arrow

	local label = dd.Text or (dd.GetFontString and dd:GetFontString())
	if label then Shim.White(label) end
end


local PAGE_ARROWS = {
	["<"] = "Interface\\AddOns\\EllesmereUI\\media\\icons\\eui-arrow-left.png",
	[">"] = "Interface\\AddOns\\EllesmereUI\\media\\icons\\eui-arrow-right.png",
}


--[[ SCROLL BARS ---------------------------------------------------------------
	Two shapes in play, which is worth stating because getting it wrong is
	silent: S.ScrollBar targets MinimalScrollBar (.Track / .Back / .Forward),
	but UIPanelScrollFrameTemplate still builds the classic slider, which has
	GetThumbTexture() and no Track at all. Detect and handle both.

	The bar is drawn rather than merely stripped. Fading the track and the two
	arrows left a single thin strip floating in empty space with no indication
	of how far it could travel, there was nothing to show the extent of the
	scroll, and nothing to click to step it. So: a visible groove down the
	middle, the thumb filling its own rect so it cannot read as off-centre, and
	the step arrows kept as arrows.
------------------------------------------------------------------------------]]
local function scrollArrow(btn, rotation)
	if not btn or forbidden(btn) then return end
	local d = fd(btn)
	if d.arrow then return end

	fadeRegions(btn)
	if btn.Texture then btn.Texture:SetAlpha(0) end
	for _, g in ipairs({"GetNormalTexture", "GetPushedTexture",
		"GetDisabledTexture", "GetHighlightTexture"}) do
		local fn = btn[g]
		local t = fn and fn(btn)
		if t then t:SetAlpha(0) end
	end

	-- EllesmereUI ships left/right arrows but no vertical pair, so the left one
	-- is rotated a quarter turn. WoW rotates counter-clockwise for a positive
	-- angle, so -pi/2 takes an arrow pointing left round to pointing up.
	local tex = btn:CreateTexture(nil, "OVERLAY")
	tex:SetTexture(PAGE_ARROWS["<"])
	tex:SetSize(10, 10)
	tex:SetPoint("CENTER")
	tex:SetRotation(rotation)
	d.arrow = tex

	local function reflect()
		tex:SetAlpha(btn:IsEnabled() and .75 or .2)
	end
	btn:HookScript("OnEnter", function() if btn:IsEnabled() then tex:SetAlpha(1) end end)
	btn:HookScript("OnLeave", reflect)
	btn:HookScript("OnEnable", reflect)
	btn:HookScript("OnDisable", reflect)
	reflect()
end


function Shim.ScrollBar(sb)
	if not sb or forbidden(sb) then return end
	local d = fd(sb)
	if d.skinned then return end
	d.skinned = true

	scrollArrow(sb.Back, -math.pi / 2)
	scrollArrow(sb.Forward, math.pi / 2)

	local track = sb.Track
	if track then fadeRegions(track) end

	-- The groove. Centred on the BAR rather than on the track, so it reads as
	-- the full travel of the thumb, and inset past the arrows where there are
	-- any so it does not run underneath them.
	if not d.track then
		local inset = (sb.Back or sb.Forward) and 16 or 0
		local groove = solid(sb, "BACKGROUND", 1, 1, 1, .07)
		groove:SetPoint("TOP", sb, "TOP", 0, -inset)
		groove:SetPoint("BOTTOM", sb, "BOTTOM", 0, inset)
		groove:SetWidth(4)
		d.track = groove
	end

	local thumb = (track and track.Thumb) or (sb.GetThumb and sb:GetThumb())
	if not thumb and sb.GetThumbTexture then
		-- Classic slider: the thumb IS a texture, not a frame, so recolour it
		-- in place rather than parenting a plate to it, and name it through
		-- the fade, or the colour lands on a region already at alpha 0.
		local t = sb:GetThumbTexture()
		if t then
			fadeRegions(sb, {[t] = true})
			t:SetColorTexture(1, 1, 1, .3)
			t:SetSize(4, 16)
			d.thumbTex = t
		else
			fadeRegions(sb)
		end
		return
	end

	if thumb and not fd(thumb).bg then
		fadeRegions(thumb)
		-- The thumb's own rect, not a narrow strip down the middle of it. A
		-- 4px strip centred on a wider thumb is what made the scrubber look
		-- off-centre in its container: it was centred on the thumb, but the
		-- thumb is not the width of the bar, so the two disagreed.
		local t = solid(thumb, "ARTWORK", 1, 1, 1, .35)
		t:SetPoint("TOPLEFT", thumb, "TOPLEFT", 0, 0)
		t:SetPoint("BOTTOMRIGHT", thumb, "BOTTOMRIGHT", 0, 0)
		fd(thumb).bg = t
	end
end


-- PAGE_ARROWS is declared above the scroll bars, which rotate the left arrow
-- to make the vertical pair EllesmereUI does not ship.
function Shim.PageButton(btn, ch, size)
	if not btn or forbidden(btn) then return end
	local d = fd(btn)
	if d.block then return end
	d.block = true

	for _, g in ipairs({"GetNormalTexture", "GetPushedTexture",
		"GetDisabledTexture", "GetHighlightTexture"}) do
		local fn = btn[g]
		local t = fn and fn(btn)
		if t and t.SetAlpha then t:SetAlpha(0) end
	end

	local bg = solid(btn, "BACKGROUND", Theme.bgR, Theme.bgG, Theme.bgB, Theme.bgA)
	bg:SetAllPoints(btn)
	d.bg = bg
	addBorder(btn)

	local tex = PAGE_ARROWS[ch]
	if tex then
		local arrow = btn:CreateTexture(nil, "OVERLAY")
		arrow:SetTexture(tex)
		local s = size or 14
		arrow:SetSize(s, s)
		arrow:SetPoint("CENTER")
		arrow:SetAlpha(.9)
		d.arrow = arrow
	else
		local fs = btn:CreateFontString(nil, "OVERLAY")
		fs:SetFont(Theme.fontPath, size or 14, Theme.fontFlag or "")
		fs:SetPoint("CENTER")
		fs:SetText(ch)
		fs:SetTextColor(1, 1, 1, .9)
		d.arrow = fs
	end

	local hover = solid(btn, "HIGHLIGHT", 1, 1, 1, .1)
	hover:SetAllPoints(btn)
	d.hover = hover

	-- Cannot page further -> whole block at half opacity.
	local function reflect() btn:SetAlpha(btn:IsEnabled() and 1 or .5) end
	btn:HookScript("OnEnable", reflect)
	btn:HookScript("OnDisable", reflect)
	reflect()
end


function Shim.SquareIcon(icon)
	if not icon or not icon.SetTexCoord then return end
	icon:SetTexCoord(.08, .92, .08, .92)
end


--[[ TABS ----------------------------------------------------------------------
	The primitive owns the whole visual: it clears the native art and hides
	Blizzard's label behind its own mirrored one. Re-calling it on an
	already-skinned tab repaints it, which is the supported way to drive
	selection from outside, do not also paint the tab yourself, or you will be
	recolouring an invisible label.
------------------------------------------------------------------------------]]
local skinnedTabs = setmetatable({}, {__mode = "k"})

--[[ Selection is reported four different ways across the templates in play,
	and reading only one of them leaves every tab drawn as unselected, which
	renders the whole row at half label alpha and reads as "muted", with no tab
	ever showing the accent underline.

	  tab.isSelected     the modern TabSystem
	  parent.selectedTab vs the tab's index in parent.Tabs
	                     PanelTemplates with an explicit array, which is how
	                     MountsJournal wires Model / Map / Settings
	  parent.selectedTab vs tab.id
	                     its config window, whose tabs carry .id rather than
	                     having SetID called
	  parent.selectedTab vs tab:GetID()
	                     plain PanelTemplates
------------------------------------------------------------------------------]]
local function tabIsSelected(tab)
	if tab.isSelected ~= nil then return tab.isSelected and true or false end

	local parent = tab.GetParent and tab:GetParent()
	local selected = parent and parent.selectedTab
	if not selected then return false end

	if type(parent.Tabs) == "table" then
		for i = 1, #parent.Tabs do
			if parent.Tabs[i] == tab then return selected == i end
		end
	end
	if tab.id then return selected == tab.id end

	local id = tab.GetID and tab:GetID()
	return id ~= nil and id > 0 and selected == id
end


local function updateTabVisual(tab)
	local d = FD[tab]
	if not d or not d.underline then return end
	local sel = tabIsSelected(tab)
	if d.label then
		-- Full alpha either way; the state is carried by the colour, exactly as
		-- Blizzard's own tabs do it. Half-alpha white was what made every tab
		-- in both our rows read as muted next to Collections' gold.
		if sel then
			d.label:SetTextColor(Theme.tabSelR, Theme.tabSelG, Theme.tabSelB, 1)
		else
			d.label:SetTextColor(Theme.tabR, Theme.tabG, Theme.tabB, 1)
		end
	end
	d.underline:SetShown(sel)
	if d.activeHL then d.activeHL:SetShown(sel) end
end


local function updateAllTabs()
	for tab in pairs(skinnedTabs) do
		if not forbidden(tab) then updateTabVisual(tab) end
	end
end


local tabHooked = false
local function ensureTabHooks()
	if tabHooked then return end
	tabHooked = true
	if PanelTemplates_SetTab then hooksecurefunc("PanelTemplates_SetTab", updateAllTabs) end
	if PanelTemplates_UpdateTabs then hooksecurefunc("PanelTemplates_UpdateTabs", updateAllTabs) end
end


function Shim.Tab(tab)
	if not tab or forbidden(tab) then return end
	local d = fd(tab)
	if d.bg then
		updateTabVisual(tab)
		if d.label and d.blizLabel and d.blizLabel.GetText then
			d.label:SetText(d.blizLabel:GetText() or "")
		end
		return
	end
	d.skinned = true

	for j = 1, select("#", tab:GetRegions()) do
		local r = select(j, tab:GetRegions())
		if r and r:IsObjectType("Texture") then
			r:SetTexture("")
			if r.SetAtlas then r:SetAtlas("") end
		end
	end
	for _, k in ipairs({"Left", "Middle", "Right",
		"LeftDisabled", "MiddleDisabled", "RightDisabled"}) do
		if tab[k] and tab[k].SetTexture then tab[k]:SetTexture("") end
	end
	local hl = tab.GetHighlightTexture and tab:GetHighlightTexture()
	if hl then hl:SetTexture("") end

	d.bg = solid(tab, "BACKGROUND", .068, .056, .052, 1)
	d.bg:SetAllPoints()

	local activeHL = tab:CreateTexture(nil, "ARTWORK", nil, -6)
	activeHL:SetAllPoints()
	activeHL:SetColorTexture(1, 1, 1, .02)
	activeHL:SetBlendMode("ADD")
	activeHL:Hide()
	d.activeHL = activeHL

	local blizLabel = tab.Text or (tab.GetFontString and tab:GetFontString())
	local labelText = (blizLabel and blizLabel.GetText and blizLabel:GetText()) or ""
	if blizLabel and blizLabel.SetTextColor then blizLabel:SetTextColor(0, 0, 0, 0) end
	if tab.SetPushedTextOffset then tab:SetPushedTextOffset(0, 0) end

	local label = tab:CreateFontString(nil, "OVERLAY")
	label:SetFont(Theme.fontPath, 11, Theme.fontFlag or "")
	label:SetPoint("CENTER", tab, "CENTER", 0, 0)
	label:SetText(labelText)
	d.label, d.blizLabel = label, blizLabel

	-- Read the live text back off the hidden original after each write, so
	-- dynamic updates land: some labels carry a trailing count set through
	-- SetFormattedText or a direct FontString:SetText, neither of which routes
	-- through the button's SetText.
	local function syncLabel()
		if d.label and d.blizLabel and d.blizLabel.GetText then
			d.label:SetText(d.blizLabel:GetText() or "")
		end
	end
	if type(tab.SetText) == "function" then hooksecurefunc(tab, "SetText", syncLabel) end
	if blizLabel then
		hooksecurefunc(blizLabel, "SetText", syncLabel)
		if blizLabel.SetFormattedText then
			hooksecurefunc(blizLabel, "SetFormattedText", syncLabel)
		end
	end

	local underline = tab:CreateTexture(nil, "OVERLAY", nil, 6)
	local PP = EUI.PanelPP
	if PP and PP.DisablePixelSnap then
		PP.DisablePixelSnap(underline)
		underline:SetHeight(PP.mult or 1)
	else
		underline:SetHeight(1)
	end
	underline:SetPoint("BOTTOMLEFT", tab, "BOTTOMLEFT", 0, 0)
	underline:SetPoint("BOTTOMRIGHT", tab, "BOTTOMRIGHT", 0, 0)
	underline:SetColorTexture(Theme.accR, Theme.accG, Theme.accB, 1)
	underline:Hide()
	d.underline = underline

	skinnedTabs[tab] = true
	ensureTabHooks()
	-- TabSystem buttons do not flow through PanelTemplates_SetTab.
	tab:HookScript("OnClick", function()
		if C_Timer then C_Timer.After(0, updateAllTabs) else updateAllTabs() end
	end)
	updateTabVisual(tab)
end


--[[ GETTERS AND LIVE REFRESH --------------------------------------------------]]
function Shim.GetAccentColor() return Theme.accR, Theme.accG, Theme.accB end
function Shim.GetPanelColor() return Theme.bgR, Theme.bgG, Theme.bgB, Theme.bgA end
function Shim.GetFont() return Theme.fontPath, Theme.fontFlag end
function Shim.GetStyle() return windowStyle() end
function Shim.IsEnabled() return true end


-- 8.6.6 has no public looks-changed callback, so nothing external can tell us
-- an accent edit happened. We keep the registry and drive it from what we CAN
-- observe, our own settings changes, and window shows, which covers a
-- profile switch made while the journal is closed. A live accent edit with the
-- journal already open still needs a /reload on this backend; the api backend
-- does not.
local looksCallbacks = {}

function Shim.OnLooksChanged(fn)
	if type(fn) == "function" then looksCallbacks[#looksCallbacks + 1] = fn end
end


function Shim.RefreshLooks()
	resolveTheme()
	refreshShells()
	for _, d in pairs(FD) do
		if d.check then d.check:SetVertexColor(Theme.accR, Theme.accG, Theme.accB, 1) end
		if d.underline then
			d.underline:SetColorTexture(Theme.accR, Theme.accG, Theme.accB, 1)
		end
	end
	updateAllTabs()
	for i = 1, #looksCallbacks do pcall(looksCallbacks[i]) end
end


--[[ BACKEND SELECTION ---------------------------------------------------------
	Deferred to PLAYER_LOGIN. Deciding at file-load time is what broke this
	addon the first time: OptionalDeps affects load order, but a load-time guard
	bakes in a permanent no-op if anything is off. At PLAYER_LOGIN EllesmereUI
	is fully initialised either way, and the official dispatcher explicitly
	supports late registration.
------------------------------------------------------------------------------]]
local backend, facade, pending = nil, nil, {}

function ns.GetBackend() return backend or "pending" end
function ns.GetFacade() return facade end
function ns.HasAPI() return EUI.RegisterSkin ~= nil end

-- RegisterSkin existing proves nothing: the 8.6.8 PARENT ships the stub even
-- when the EllesmereUIBlizzardSkin child is disabled, documented as "a silent
-- no-op". Registering with a dead stub means the callback never fires and the
-- journal comes up wholly unskinned -- the same class of bug as gating on
-- master-branch source (see the header). What proves the pipeline is live is
-- the dispatcher the child's SkinAPI file assigns at load. When it is absent,
-- compat still works in full: its helpers are parent-level, and the one that
-- is not (GetBlizzWindowStyle) is pcall-guarded and "blizz" mode only.
function ns.HasDispatcher()
	return type(EUI._DispatchSkinRegistration) == "function"
end


--[[ WINDOW APPEARANCE ---------------------------------------------------------
	Driven from the settings panel. The shell is drawn by our own Shell() on
	BOTH backends now -- the hybrid facade keeps it local precisely so the
	backdrop, opacity and edge settings keep meaning something -- so this is
	unconditionally true. It stays a function because the options panel and
	the diagnostic already call it, and because a future API version that
	exposes the engine's shell textures could flip it back off.
------------------------------------------------------------------------------]]
function ns.CanStyleShell() return true end


-- mode:   "fill" (Dark Mode plate) | "blizz" (EllesmereUI window art)
-- alpha:  nil to follow the Dark Mode alpha, or an explicit 0-1 override
-- border: "art" | "line" | "none"
function ns.SetShellAppearance(mode, alpha, border)
	shellMode = (mode == "blizz") and "blizz" or "fill"
	shellAlpha = tonumber(alpha)
	if border == "line" or border == "none" or border == "art" then
		shellBorder = border
	end
	refreshShells()
end


-- What the window is painted with right now, for the diagnostic.
function ns.GetShellAppearance()
	local r, g, b, a = hostBaseline()
	return shellMode, shellOpacity(), r, g, b, a, shellBorder
end


-- Same shape as EllesmereUI.RegisterSkin, so the skin body reads identically on
-- both backends.
function ns.RegisterSkin(name, fn)
	if facade then fn(facade) else pending[#pending + 1] = fn end
end


local function dispatch(S)
	facade = S
	for i = 1, #pending do
		-- One bad callback must not cost the others. The body stages its own
		-- work as well, so this is the outer of two nets.
		pcall(pending[i], S)
	end
	pending = {}
end


--[[ HYBRID FACADE -------------------------------------------------------------
	The api backend does not hand the whole job to EllesmereUI. The day-of
	cross-check against the 8.6.8 engine source (SKINNING_NOTES §6) found
	three primitives whose engine versions do not reproduce this skin's
	approved look, so those stay ours and everything else is inherited:

	  Shell      the engine draws its opaque modern_blizz shell with a 25px
	             title bar and the atlas border: no Dark Mode fill, no
	             transparency, and every appearance setting dead. Ours keeps
	             the user's backdrop, opacity and edge choices working.
	  ScrollBar  the engine strips the arrows instead of redrawing them, has
	             no groove, uses the 4px centre-strip thumb this skin
	             deliberately widened to the thumb's own rect, and skips
	             classic GetThumbTexture sliders entirely, which would revert
	             those bars to stock Blizzard art.
	  Checkbox   the engine borders the frame rect unless passed
	             {borderInset}; the visible box is inset 4px, so the border
	             sits proud of it. Ours insets both, unconditionally.

	RefreshLooks is also ours: it repaints the shells and accent ticks the
	Shim draws, which the engine cannot know about. It is additionally
	registered with the engine's OnLooksChanged, so on this backend a live
	accent or profile edit repaints the window with no reopen and no reload,
	the one thing the compat backend cannot do.

	The overrides live in a table of our own with the api facade behind it.
	Writing into the facade itself would rewrite the primitives of every
	other addon EllesmereUI skins.
------------------------------------------------------------------------------]]
local function hybridize(api)
	if api.OnLooksChanged then
		api.OnLooksChanged(function() Shim.RefreshLooks() end)
	end
	return setmetatable({
		Shell = Shim.Shell,
		ScrollBar = Shim.ScrollBar,
		Checkbox = Shim.Checkbox,
		RefreshLooks = Shim.RefreshLooks,
	}, {__index = api})
end


local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function(self)
	self:UnregisterEvent("PLAYER_LOGIN")
	resolveTheme()
	if EUI.RegisterSkin and ns.HasDispatcher() then
		backend = "api"
		EUI.RegisterSkin(ADDON_NAME, function(api) dispatch(hybridize(api)) end)
	else
		backend = "compat"
		dispatch(Shim)
	end
end)
