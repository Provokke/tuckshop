--!strict
-- The shop panel: tabs, item cards, a rotation countdown and a confirm dialogue. It only draws what
-- the server last sent and reports what the player clicked. It never changes a balance itself.
local ShopWindow = {}
ShopWindow.__index = ShopWindow

type Item = {
	id: string,
	name: string,
	price: number,
	currency: string,
	pool: string?,
	limit: number?,
	bought: number,
}

type View = { balances: { [string]: number }, listing: { Item }, secondsLeft: number, viewOnly: boolean }

export type Deps = {
	theme: any,
	parent: Instance,
	currencies: { [string]: { colour: { number } } },
	products: { [number]: { grant: string, amount: number } },
	onBuy: (itemId: string) -> (),
	onProduct: (productId: number) -> (), -- opens the Roblox purchase prompt
	onRefresh: () -> (), -- the shop should have changed: ask for the listing
}

export type ShopWindow = typeof(setmetatable(
	{} :: {
		deps: Deps,
		root: Frame,
		body: ScrollingFrame,
		countdown: TextLabel,
		notice: TextLabel,
		tabs: { [string]: TextButton },
		tab: string,
		view: View?,
		receivedAt: number,
		askedAt: number,
		confirm: Frame,
		confirmText: TextLabel,
		confirmItem: Item?,
	},
	ShopWindow
))

local TABS = { "Featured", "Skins", "Boosts", "Buy Gems" }
local TAB_POOL: { [string]: string } = { Skins = "skins", Boosts = "boosts" }

local function clockText(seconds: number): string
	seconds = math.max(0, math.floor(seconds))
	return string.format("%d:%02d", math.floor(seconds / 60), seconds % 60)
end

function ShopWindow.new(deps: Deps): ShopWindow
	local theme = deps.theme

	local root = Instance.new("Frame")
	root.Name = "Shop"
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.Position = UDim2.fromScale(0.5, 0.5)
	root.Size = UDim2.fromOffset(560, 420)
	root.Visible = false
	root.Parent = deps.parent
	theme.style(root, theme.panel)

	local title = theme.label(root, "Tuckshop", 20)
	title.FontFace = theme.fontBold
	title.Position = UDim2.fromOffset(14, 10)
	title.Size = UDim2.fromOffset(160, 26)

	local countdown = theme.label(root, "", 14, theme.muted)
	countdown.AnchorPoint = Vector2.new(1, 0)
	countdown.Position = UDim2.new(1, -52, 0, 14)
	countdown.Size = UDim2.fromOffset(200, 20)
	countdown.TextXAlignment = Enum.TextXAlignment.Right

	local close = theme.button(root, "X")
	close.AnchorPoint = Vector2.new(1, 0)
	close.Position = UDim2.new(1, -12, 0, 10)
	close.Size = UDim2.fromOffset(30, 26)

	local tabRow = Instance.new("Frame")
	tabRow.BackgroundTransparency = 1
	tabRow.Position = UDim2.fromOffset(14, 46)
	tabRow.Size = UDim2.new(1, -28, 0, 30)
	tabRow.Parent = root
	local tabLayout = Instance.new("UIListLayout")
	tabLayout.FillDirection = Enum.FillDirection.Horizontal
	tabLayout.Padding = UDim.new(0, 8)
	tabLayout.Parent = tabRow

	local body = Instance.new("ScrollingFrame")
	body.BackgroundTransparency = 1
	body.BorderSizePixel = 0
	body.Position = UDim2.fromOffset(14, 86)
	body.Size = UDim2.new(1, -28, 1, -128)
	body.ScrollBarThickness = 4
	body.AutomaticCanvasSize = Enum.AutomaticSize.Y
	body.CanvasSize = UDim2.new()
	body.Parent = root
	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.fromOffset(166, 112)
	grid.CellPadding = UDim2.fromOffset(8, 8)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = body

	-- One line along the bottom for the view-only warning.
	local notice = theme.label(root, "", 13, theme.bad)
	notice.AnchorPoint = Vector2.new(0, 1)
	notice.Position = UDim2.new(0, 14, 1, -8)
	notice.Size = UDim2.new(1, -28, 0, 28)
	notice.TextWrapped = true
	notice.Visible = false

	-- Confirm dialogue, over everything else in the panel.
	local confirm = Instance.new("Frame")
	confirm.AnchorPoint = Vector2.new(0.5, 0.5)
	confirm.Position = UDim2.fromScale(0.5, 0.5)
	confirm.Size = UDim2.fromOffset(340, 160)
	confirm.Visible = false
	confirm.ZIndex = 10
	confirm.Parent = root
	theme.style(confirm, theme.background, theme.accent)
	local confirmText = theme.label(confirm, "", 16)
	confirmText.Position = UDim2.fromOffset(16, 14)
	confirmText.Size = UDim2.new(1, -32, 0, 80)
	confirmText.TextWrapped = true
	confirmText.ZIndex = 11
	local yes = theme.button(confirm, "Buy", theme.accent)
	yes.AnchorPoint = Vector2.new(1, 1)
	yes.Position = UDim2.new(0.5, -6, 1, -14)
	yes.Size = UDim2.fromOffset(120, 32)
	yes.ZIndex = 11
	local no = theme.button(confirm, "Cancel")
	no.AnchorPoint = Vector2.new(0, 1)
	no.Position = UDim2.new(0.5, 6, 1, -14)
	no.Size = UDim2.fromOffset(120, 32)
	no.ZIndex = 11

	local self: ShopWindow = setmetatable({
		deps = deps,
		root = root,
		body = body,
		countdown = countdown,
		notice = notice,
		tabs = {},
		tab = "Featured",
		view = nil,
		receivedAt = 0,
		askedAt = 0,
		confirm = confirm,
		confirmText = confirmText,
		confirmItem = nil,
	}, ShopWindow)

	for _, name in TABS do
		local button = theme.button(tabRow, name)
		button.Size = UDim2.fromOffset(110, 30)
		button.Activated:Connect(function()
			self.tab = name
			self:redraw()
		end)
		self.tabs[name] = button
	end

	close.Activated:Connect(function()
		root.Visible = false
	end)
	no.Activated:Connect(function()
		confirm.Visible = false
		self.confirmItem = nil
	end)
	yes.Activated:Connect(function()
		local item = self.confirmItem
		confirm.Visible = false
		self.confirmItem = nil
		if item ~= nil then
			deps.onBuy(item.id)
		end
	end)
	return self
end

function ShopWindow.setVisible(self: ShopWindow, visible: boolean)
	self.root.Visible = visible
end

function ShopWindow.toggle(self: ShopWindow)
	self.root.Visible = not self.root.Visible
end

-- The server sent a new view.
function ShopWindow.update(self: ShopWindow, view: View)
	self.view = view
	self.receivedAt = os.clock()
	self.confirm.Visible = false -- the numbers behind a dialogue may just have changed
	self.confirmItem = nil
	self:redraw()
end

local function clear(body: Instance)
	for _, child in body:GetChildren() do
		if not child:IsA("UIGridLayout") then
			child:Destroy()
		end
	end
end

function ShopWindow.openConfirm(self: ShopWindow, item: Item, balance: number)
	self.confirmItem = item
	self.confirmText.Text = `Buy {item.name} for {item.price} {item.currency}?\n`
		.. `You will have {balance - item.price} {item.currency} left.`
	self.confirm.Visible = true
end

local function itemCard(self: ShopWindow, item: Item, order: number, view: View)
	local theme = self.deps.theme
	local card = Instance.new("Frame")
	card.LayoutOrder = order
	card.Parent = self.body
	theme.style(card, theme.cell)

	local name = theme.label(card, item.name, 15)
	name.FontFace = theme.fontBold
	name.Position = UDim2.fromOffset(10, 8)
	name.Size = UDim2.new(1, -20, 0, 36)
	name.TextWrapped = true
	name.TextYAlignment = Enum.TextYAlignment.Top

	local def = self.deps.currencies[item.currency]
	local price =
		theme.label(card, `{item.price} {item.currency}`, 14, theme.colour(if def then def.colour else nil))
	price.Position = UDim2.fromOffset(10, 48)
	price.Size = UDim2.new(1, -20, 0, 18)

	local balance = view.balances[item.currency] or 0
	local limitReached = item.limit ~= nil and item.bought >= item.limit
	local label = "Buy"
	if view.viewOnly then
		label = "View-only"
	elseif limitReached then
		label = "Sold out"
	elseif balance < item.price then
		label = "Can't afford"
	end
	local canBuy = label == "Buy"
	local button = theme.button(card, label, if canBuy then theme.accent else theme.cell)
	button.AnchorPoint = Vector2.new(0.5, 1)
	button.Position = UDim2.new(0.5, 0, 1, -8)
	button.Size = UDim2.new(1, -20, 0, 28)
	button.AutoButtonColor = canBuy
	if not canBuy then
		button.TextColor3 = theme.muted
	end
	button.Activated:Connect(function()
		if canBuy then
			self:openConfirm(item, balance)
		end
	end)
end

local function gemsTab(self: ShopWindow)
	local theme = self.deps.theme
	local order = 0
	local ids: { number } = {}
	for productId in self.deps.products do
		if productId > 0 then
			table.insert(ids, productId)
		end
	end
	table.sort(ids)
	for _, productId in ids do
		local def = self.deps.products[productId]
		order += 1
		local card = Instance.new("Frame")
		card.LayoutOrder = order
		card.Parent = self.body
		theme.style(card, theme.cell)
		local name = theme.label(card, `{def.amount} {def.grant}`, 16)
		name.FontFace = theme.fontBold
		name.Position = UDim2.fromOffset(10, 10)
		name.Size = UDim2.new(1, -20, 0, 24)
		local button = theme.button(card, "Buy with Robux", theme.accent)
		button.AnchorPoint = Vector2.new(0.5, 1)
		button.Position = UDim2.new(0.5, 0, 1, -8)
		button.Size = UDim2.new(1, -20, 0, 28)
		button.Activated:Connect(function()
			self.deps.onProduct(productId)
		end)
	end
	if order == 0 then
		local empty = theme.label(self.body, "No developer products are set up yet.", 15, theme.muted)
		empty.Size = UDim2.fromOffset(330, 40)
		empty.TextWrapped = true
	end
end

function ShopWindow.redraw(self: ShopWindow)
	local theme = self.deps.theme
	clear(self.body)
	for name, button in self.tabs do
		button.BackgroundColor3 = if name == self.tab then theme.accent else theme.cell
	end
	local view = self.view
	self.notice.Visible = view ~= nil and view.viewOnly
	if self.notice.Visible then
		self.notice.Text = "View-only: this server can't save your data, so nothing can be bought here."
	end
	if view == nil then
		local waiting = theme.label(self.body, "Loading...", 15, theme.muted)
		waiting.Size = UDim2.fromOffset(200, 24)
		return
	end
	if self.tab == "Buy Gems" then
		gemsTab(self)
		return
	end
	local pool = TAB_POOL[self.tab]
	local order = 0
	for _, item in view.listing do
		if pool == nil or item.pool == pool then
			order += 1
			itemCard(self, item, order, view)
		end
	end
end

-- Called every frame by the entry script. Keeps the countdown moving and asks for a fresh listing
-- once the window has turned over (at most once every 3 seconds).
function ShopWindow.tick(self: ShopWindow)
	local view = self.view
	if view == nil then
		return
	end
	local left = view.secondsLeft - (os.clock() - self.receivedAt)
	self.countdown.Text = `Stock changes in {clockText(left)}`
	if left <= 0 and os.clock() - self.askedAt > 3 then
		self.askedAt = os.clock()
		self.deps.onRefresh()
	end
end

return ShopWindow
