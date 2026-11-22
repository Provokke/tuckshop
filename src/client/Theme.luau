--!strict
-- One look for every Tuckshop panel: a dark panel, one accent colour, 8 px corners, 1 px strokes.
local Theme = {}

Theme.background = Color3.fromRGB(22, 24, 30)
Theme.panel = Color3.fromRGB(32, 35, 43)
Theme.cell = Color3.fromRGB(42, 46, 56)
Theme.stroke = Color3.fromRGB(64, 69, 82)
Theme.text = Color3.fromRGB(231, 233, 238)
Theme.muted = Color3.fromRGB(143, 149, 163)
Theme.accent = Color3.fromRGB(96, 165, 250)
Theme.good = Color3.fromRGB(82, 190, 124)
Theme.bad = Color3.fromRGB(224, 98, 98)

Theme.corner = 8
Theme.strokeThickness = 1
Theme.font = Font.fromEnum(Enum.Font.BuilderSans)
Theme.fontBold = Font.fromEnum(Enum.Font.BuilderSansBold)

-- Rounds a frame and gives it the stroke every panel shares.
function Theme.style(frame: GuiObject, fill: Color3?, outline: Color3?)
	frame.BackgroundColor3 = fill or Theme.panel
	frame.BorderSizePixel = 0
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, Theme.corner)
	corner.Parent = frame
	local stroke = Instance.new("UIStroke")
	stroke.Color = outline or Theme.stroke
	stroke.Thickness = Theme.strokeThickness
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = frame
end

function Theme.label(parent: Instance, text: string, size: number?, colour: Color3?): TextLabel
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.FontFace = Theme.font
	label.Text = text
	label.TextSize = size or 16
	label.TextColor3 = colour or Theme.text
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = parent
	return label
end

function Theme.button(parent: Instance, text: string, fill: Color3?): TextButton
	local button = Instance.new("TextButton")
	button.AutoButtonColor = true
	button.FontFace = Theme.fontBold
	button.Text = text
	button.TextSize = 15
	button.TextColor3 = Theme.text
	button.Parent = parent
	Theme.style(button, fill or Theme.cell)
	return button
end

-- Config stores colours as { r, g, b } so the config stays loadable outside Roblox.
function Theme.colour(triple: { number }?): Color3
	if triple == nil then
		return Theme.muted
	end
	return Color3.fromRGB(triple[1], triple[2], triple[3])
end

return Theme
