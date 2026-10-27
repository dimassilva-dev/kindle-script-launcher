--[[--
Biblioteca de atalhos: grade em tela cheia com ícone e nome dos scriptlets do
histórico. Toque abre, toque longo remove, deslizar troca de página.
]]

local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local Button = require("ui/widget/button")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup = require("ui/widget/overlapgroup")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Screen = Device.screen
local T = require("ffi/util").template

local ScriptTile = InputContainer:extend{
    width = nil,
    height = nil,
    title = nil,
    badge = nil, -- texto pequeno abaixo do título (ex.: "sem framework")
    make_icon = nil, -- function(side) -> widget do ícone do scriptlet, ou nil
    icon_name = nil, -- ícone do KOReader, quando make_icon não dá um ícone
    callback = nil,
    hold_callback = nil,
}

function ScriptTile:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.ges_events = {
        Tap = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
        Hold = { GestureRange:new{ ges = "hold", range = function() return self.dimen end } },
    }

    local border = Size.border.thin
    local pad = Screen:scaleBySize(10)
    local inner_w = self.width - 2 * border
    local inner_h = self.height - 2 * border
    local label = TextWidget:new{
        text = self.title,
        face = Font:getFace("cfont", 18),
        max_width = inner_w - 2 * pad,
    }
    local badge
    if self.badge then
        badge = TextWidget:new{
            text = self.badge,
            face = Font:getFace("cfont", 14),
            max_width = inner_w - 2 * pad,
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        }
    end
    local text_h = label:getSize().h + (badge and badge:getSize().h or 0)
    local icon_side = math.max(1, math.min(inner_w - 2 * pad, inner_h - text_h - 3 * pad))

    local icon = self.make_icon and self.make_icon(icon_side)
    if not icon then
        local side = math.floor(icon_side * 0.55)
        icon = IconWidget:new{
            icon = self.icon_name or "appbar.tools",
            width = side,
            height = side,
        }
    end

    self[1] = FrameContainer:new{
        width = self.width,
        height = self.height,
        bordersize = border,
        radius = Size.radius.window,
        padding = 0,
        margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = inner_h },
            VerticalGroup:new{
                align = "center",
                CenterContainer:new{
                    dimen = Geom:new{ w = icon_side, h = icon_side },
                    icon,
                },
                VerticalSpan:new{ width = pad },
                label,
                badge,
            },
        },
    }
end

function ScriptTile:onTap()
    if self.callback then
        self.callback()
    end
    return true
end

function ScriptTile:onHold()
    if self.hold_callback then
        self.hold_callback()
    end
    return true
end

local ScriptLibrary = InputContainer:extend{
    plugin = nil,
    covers_fullscreen = true,
    page = 1,
}

function ScriptLibrary:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ges_events = {
        Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    self:update()
end

function ScriptLibrary:update()
    local plugin = self.plugin
    local sw, sh = self.dimen.w, self.dimen.h
    local landscape = sw > sh
    local cols = landscape and 4 or 3
    local rows = landscape and 2 or 3
    local per_page = cols * rows
    self.per_page = per_page

    -- Scripts da biblioteca (na ordem salva), mais o bloco "Adicionar".
    plugin:pruneMissing()
    local entries = {}
    for _, path in ipairs(plugin.settings.recent) do
        table.insert(entries, { path = path })
    end
    table.insert(entries, { add = true })

    self.page_count = math.max(1, math.ceil(#entries / per_page))
    self.page = math.min(math.max(self.page, 1), self.page_count)

    local title_bar = TitleBar:new{
        width = sw,
        fullscreen = true,
        with_bottom_line = true,
        title = "Scripts do Kindle",
        subtitle = "Toque para abrir · segure para opções",
        left_icon = "appbar.menu",
        left_icon_tap_callback = function() self:showLibraryMenu() end,
        close_callback = function() self:onClose() end,
        show_parent = self,
    }

    local footer_h = Screen:scaleBySize(56)
    local margin = Screen:scaleBySize(14)
    local grid_h = sh - title_bar:getHeight() - footer_h
    local tile_w = math.floor((sw - margin * (cols + 1)) / cols)
    local tile_h = math.floor((grid_h - margin * (rows + 1)) / rows)

    local grid = VerticalGroup:new{ align = "left" }
    table.insert(grid, VerticalSpan:new{ width = margin })
    for r = 1, rows do
        local row = HorizontalGroup:new{ align = "top" }
        table.insert(row, HorizontalSpan:new{ width = margin })
        for c = 1, cols do
            local entry = entries[(self.page - 1) * per_page + (r - 1) * cols + c]
            if entry then
                table.insert(row, self:makeTile(entry, tile_w, tile_h))
                table.insert(row, HorizontalSpan:new{ width = margin })
            end
        end
        table.insert(grid, row)
        table.insert(grid, VerticalSpan:new{ width = margin })
    end

    local footer = HorizontalGroup:new{ align = "center" }
    if self.page_count > 1 then
        local icon_size = Screen:scaleBySize(32)
        table.insert(footer, Button:new{
            icon = "chevron.left",
            icon_width = icon_size,
            icon_height = icon_size,
            bordersize = 0,
            enabled = self.page > 1,
            callback = function() self:goToPage(self.page - 1) end,
            show_parent = self,
        })
        table.insert(footer, HorizontalSpan:new{ width = Screen:scaleBySize(24) })
        table.insert(footer, TextWidget:new{
            text = T("%1 / %2", self.page, self.page_count),
            face = Font:getFace("cfont", 20),
        })
        table.insert(footer, HorizontalSpan:new{ width = Screen:scaleBySize(24) })
        table.insert(footer, Button:new{
            icon = "chevron.right",
            icon_width = icon_size,
            icon_height = icon_size,
            bordersize = 0,
            enabled = self.page < self.page_count,
            callback = function() self:goToPage(self.page + 1) end,
            show_parent = self,
        })
    end

    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        margin = 0,
        OverlapGroup:new{
            dimen = Geom:new{ w = sw, h = sh },
            allow_mirroring = false,
            VerticalGroup:new{
                align = "left",
                title_bar,
                grid,
            },
            BottomContainer:new{
                dimen = Geom:new{ w = sw, h = sh },
                CenterContainer:new{
                    dimen = Geom:new{ w = sw, h = footer_h },
                    footer,
                },
            },
        },
    }
end

function ScriptLibrary:makeTile(entry, w, h)
    local plugin = self.plugin
    if entry.add then
        return ScriptTile:new{
            width = w,
            height = h,
            title = "Adicionar…",
            icon_name = "plus",
            callback = function()
                plugin:choosePath(true, plugin.settings.start_dir, function(path)
                    plugin:addRecent(path)
                    self:refresh()
                end)
            end,
        }
    end
    local info = plugin.readScriptInfo(entry.path)
    return ScriptTile:new{
        width = w,
        height = h,
        title = info.name,
        badge = not plugin:usesFramework(entry.path) and "sem framework" or nil,
        make_icon = function(side)
            return plugin.makeIconWidget(info, side)
        end,
        callback = function()
            UIManager:close(self)
            plugin:launch(entry.path)
        end,
        hold_callback = function()
            self:showScriptOptions(entry.path, info)
        end,
    }
end

-- Opções do script (toque longo): abrir, ligar/desligar o framework, remover.
function ScriptLibrary:showScriptOptions(path, info)
    local plugin = self.plugin
    local dialog
    local uses_framework = plugin:usesFramework(path)
    dialog = ButtonDialog:new{
        title = info.name,
        title_align = "center",
        buttons = {
            {
                {
                    text = "Abrir",
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:close(self)
                        plugin:launch(path)
                    end,
                },
            },
            {
                {
                    text = "← Mover",
                    callback = function()
                        UIManager:close(dialog)
                        self:moveScript(path, info, -1)
                    end,
                },
                {
                    text = "Mover →",
                    callback = function()
                        UIManager:close(dialog)
                        self:moveScript(path, info, 1)
                    end,
                },
            },
            {
                {
                    text = "Para o início",
                    callback = function()
                        UIManager:close(dialog)
                        self:moveScript(path, info, "first")
                    end,
                },
                {
                    text = "Para o fim",
                    callback = function()
                        UIManager:close(dialog)
                        self:moveScript(path, info, "last")
                    end,
                },
            },
            {
                {
                    text = uses_framework and "Iniciar o framework: sim" or "Iniciar o framework: não",
                    callback = function()
                        UIManager:close(dialog)
                        plugin:setUsesFramework(path, not uses_framework)
                        self:refresh()
                        self:showScriptOptions(path, info)
                    end,
                },
            },
            {
                {
                    text = "Remover da biblioteca",
                    callback = function()
                        UIManager:close(dialog)
                        UIManager:show(ConfirmBox:new{
                            text = T("Remover %1 da biblioteca?\n\nO arquivo não é apagado.", info.name),
                            ok_text = "Remover",
                            ok_callback = function()
                                plugin:removeRecent(path)
                                self:refresh()
                            end,
                        })
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

-- Move o script, vai para a página onde ele ficou e reabre as opções, para
-- dar para mover várias vezes seguidas.
function ScriptLibrary:moveScript(path, info, where)
    local position = self.plugin:moveScript(path, where)
    if position and self.per_page then
        self.page = math.ceil(position / self.per_page)
    end
    self:refresh()
    self:showScriptOptions(path, info)
end

-- Menu da biblioteca (ícone no canto da barra de título).
function ScriptLibrary:showLibraryMenu()
    local plugin = self.plugin
    local dialog
    dialog = ButtonDialog:new{
        title = "Biblioteca",
        title_align = "center",
        buttons = {
            {
                {
                    text = "Ordenar por nome (A–Z)",
                    callback = function()
                        UIManager:close(dialog)
                        plugin:sortLibrary(false)
                        self.page = 1
                        self:refresh()
                    end,
                },
            },
            {
                {
                    text = "Ordenar por nome (Z–A)",
                    callback = function()
                        UIManager:close(dialog)
                        plugin:sortLibrary(true)
                        self.page = 1
                        self:refresh()
                    end,
                },
            },
            {
                {
                    text = "Adicionar script…",
                    callback = function()
                        UIManager:close(dialog)
                        plugin:choosePath(true, plugin.settings.start_dir, function(new_path)
                            plugin:addRecent(new_path)
                            self.page = 1
                            self:refresh()
                        end)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
end

function ScriptLibrary:refresh()
    self:free()
    self:update()
    UIManager:setDirty(self, "ui")
end

function ScriptLibrary:goToPage(page)
    if page < 1 or page > self.page_count or page == self.page then return end
    self.page = page
    self:refresh()
end

function ScriptLibrary:onSwipe(_, ges)
    if ges.direction == "west" then
        self:goToPage(self.page + 1)
        return true
    elseif ges.direction == "east" then
        self:goToPage(self.page - 1)
        return true
    end
end

function ScriptLibrary:onShow()
    UIManager:setDirty(self, "full")
end

function ScriptLibrary:onClose()
    UIManager:close(self)
    UIManager:setDirty(nil, "full")
    return true
end

return ScriptLibrary
