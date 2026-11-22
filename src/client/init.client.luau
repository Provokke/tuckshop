--!strict
-- Tuckshop client entry. Builds the UI and talks to the server. The client never changes a balance
-- itself: it sends what the player tried to do and redraws from the next Sync.
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Tuckshop")
local Config = require(Shared:WaitForChild("Config"))

local Theme = require(script.Theme)
local ShopWindow = require(script.ShopWindow)

local localPlayer = Players.LocalPlayer
local remotes = ReplicatedStorage:WaitForChild("TuckshopRemotes")
local request = remotes:WaitForChild("Request") :: RemoteEvent
local sync = remotes:WaitForChild("Sync") :: RemoteEvent

local playerGui = localPlayer:WaitForChild("PlayerGui")

local gui = Instance.new("ScreenGui")
gui.Name = "Tuckshop"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 10
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui

-- Balances, top right. Each number counts towards its new value rather than jumping.
local balanceRow = Instance.new("Frame")
balanceRow.Name = "Balances"
balanceRow.AnchorPoint = Vector2.new(1, 0)
balanceRow.Position = UDim2.new(1, -16, 0, 16)
balanceRow.Size = UDim2.fromOffset(200, 28 * 2 + 18)
balanceRow.Parent = gui
Theme.style(balanceRow, Theme.panel)

local names: { string } = {}
for name in Config.Currencies do
	table.insert(names, name)
end
table.sort(names)

local shown: { [string]: number } = {} -- what is on screen
local target: { [string]: number } = {} -- what the server last said
local labels: { [string]: TextLabel } = {}
for i, name in names do
	local label = Theme.label(balanceRow, "", 18, Theme.colour(Config.Currencies[name].colour))
	label.FontFace = Theme.fontBold
	label.Position = UDim2.fromOffset(12, 8 + (i - 1) * 28)
	label.Size = UDim2.new(1, -24, 0, 26)
	labels[name] = label
	shown[name] = Config.Currencies[name].start
	target[name] = shown[name]
	label.Text = `{name}  {shown[name]}`
end

local function stepBalances()
	for name, label in labels do
		local from, to = shown[name], target[name]
		if from ~= to then
			-- Move a fraction of the way, and at least 1, so a big change still finishes quickly.
			local gap = to - from
			local move = math.max(1, math.floor(math.abs(gap) * 0.2))
			from = if math.abs(gap) <= move then to else from + math.sign(gap) * move
			shown[name] = from
			label.Text = `{name}  {from}`
		end
	end
end

local window: any
window = ShopWindow.new({
	theme = Theme,
	parent = gui,
	currencies = Config.Currencies,
	products = Config.Products,
	onBuy = function(itemId: string)
		request:FireServer("buy", itemId)
	end,
	onProduct = function(productId: number)
		MarketplaceService:PromptProductPurchase(localPlayer, productId)
	end,
	onRefresh = function()
		request:FireServer("listing")
	end,
})

local open = Theme.button(gui, "Shop")
open.AnchorPoint = Vector2.new(0, 1)
open.Position = UDim2.new(0, 16, 1, -16)
open.Size = UDim2.fromOffset(96, 36)
open.Activated:Connect(function()
	window:toggle()
end)

sync.OnClientEvent:Connect(function(view: any)
	if type(view) ~= "table" or type(view.balances) ~= "table" then
		return
	end
	for name, value in view.balances do
		if target[name] ~= nil and type(value) == "number" then
			target[name] = value
		end
	end
	window:update(view)
end)

RunService.Heartbeat:Connect(function()
	stepBalances()
	window:tick()
end)

request:FireServer("listing")
