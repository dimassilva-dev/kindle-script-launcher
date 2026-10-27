--[[--
Peças de interface compartilhadas pelo plugin, pela biblioteca e pela tela de
saída do KOReader (kslauncher_exit.lua): leitura do cabeçalho dos scriptlets,
ícones e a tela cheia no estilo "tela de início".
]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local ImageWidget = require("ui/widget/imagewidget")
local RenderImage = require("ui/renderimage")
local TextBoxWidget = require("ui/widget/textboxwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local ffi = require("ffi")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local sha2 = require("ffi/sha2")
local Screen = Device.screen

local M = {
    -- Símbolo do Zen (ensō, sem texto), usado nas telas de retorno e de saída;
    -- o mesmo ícone que o ZenOS usa. Primeiro o do plugin, depois o da pasta
    -- de ícones do usuário.
    ZEN_ICONS = {
        "/mnt/us/koreader/plugins/zenos.koplugin/icons/zen_ui.svg",
        "/mnt/us/koreader/icons/zen_ui.svg",
    },
}

local function basename(path)
    return path:match("([^/]+)$") or path
end

local function isFile(path)
    return path ~= nil and lfs.attributes(path, "mode") == "file"
end

-- Lê o cabeçalho do scriptlet: "# Name:" e "# Icon:", que pode ser um data
-- URI ("data:image/png;base64,...", às vezes seguido de lixo HTML como
-- '" alt="" />') ou um caminho de arquivo ("/mnt/us/app/icone.png").
-- Resultado em cache por caminho + data de modificação.
local info_cache = {}
local function readScriptInfo(path)
    local mtime = lfs.attributes(path, "modification")
    local cached = info_cache[path]
    if cached and cached.mtime == mtime then
        return cached.info
    end
    if cached and cached.info.icon_bb then
        cached.info.icon_bb:free()
    end
    local info = { path = path, name = (basename(path):gsub("%.[sS][hH]$", "")) }
    local f = io.open(path, "r")
    if f then
        local n = 0
        for line in f:lines() do
            n = n + 1
            if n > 40 then break end
            local name = line:match("^#%s*Name:%s*(.-)%s*$")
            if name and name ~= "" then
                info.name = name
            end
            local icon = line:match("^#%s*Icon:%s*(.-)%s*$")
            if icon then
                local b64 = icon:match("^data:image/[^;]+;base64,([A-Za-z0-9+/=]+)")
                if b64 then
                    local ok, bin = pcall(sha2.base64_to_bin, b64)
                    if ok and bin and #bin > 0 then
                        info.icon = bin
                    end
                else
                    local file = icon:gsub("^[\"']", ""):gsub("[\"']$", "")
                    if file:sub(1, 1) == "/" and isFile(file) then
                        info.icon_file = file
                    end
                end
            end
        end
        f:close()
    end
    info_cache[path] = { mtime = mtime, info = info }
    return info
end

-- Tratamento dos ícones: muitos scriptlets trazem a arte sobre um fundo
-- opaco (creme no kTerm/BT Manager) ou dentro de uma moldura (Button Mapper),
-- que no e-ink aparecem como um cartão cinza. Para parecerem "transparentes":
-- 1. o fundo claro ligado às bordas vira branco (preenchimento a partir das
--    bordas; áreas claras dentro do desenho ficam intactas);
-- 2. molduras finas (linha escura na borda seguida de interior claro) e
--    margens vazias são cortadas.
local ICON_MAX_PX = 400 -- ícones maiores são reduzidos antes (e no cache)
local LIGHT_LUM = 215   -- "claro" para o preenchimento do fundo
local WHITE_LUM = 240   -- "branco" para achar margens e o interior de molduras
local DARK_LUM = 100    -- "escuro" para achar molduras

local function pixelLum(bb, x, y)
    local c = bb:getPixel(x, y)
    if c:getAlpha() < 128 then
        return 255 -- pixel transparente conta como fundo
    end
    return c:getColor8().a
end

local function whitenBackground(bb)
    local w, h = bb:getWidth(), bb:getHeight()
    local seen = ffi.new("uint8_t[?]", w * h)
    local stack, n = {}, 0
    local function push(x, y)
        local i = y * w + x
        if seen[i] == 0 then
            seen[i] = 1
            if pixelLum(bb, x, y) >= LIGHT_LUM then
                n = n + 1
                stack[n] = i
            end
        end
    end
    for x = 0, w - 1 do
        push(x, 0)
        push(x, h - 1)
    end
    for y = 0, h - 1 do
        push(0, y)
        push(w - 1, y)
    end
    local white = Blitbuffer.COLOR_WHITE
    while n > 0 do
        local i = stack[n]
        n = n - 1
        local x, y = i % w, math.floor(i / w)
        bb:setPixel(x, y, white)
        if x > 0 then push(x - 1, y) end
        if x < w - 1 then push(x + 1, y) end
        if y > 0 then push(x, y - 1) end
        if y < h - 1 then push(x, y + 1) end
    end
end

-- Frações de pixels brancos e escuros numa linha (horizontal ou vertical)
-- dentro da caixa atual.
local function lineStats(bb, horizontal, pos, from, to)
    local white, dark = 0, 0
    for k = from, to do
        local lum = horizontal and pixelLum(bb, k, pos) or pixelLum(bb, pos, k)
        if lum >= WHITE_LUM then
            white = white + 1
        elseif lum < DARK_LUM then
            dark = dark + 1
        end
    end
    local total = to - from + 1
    return white / total, dark / total
end

-- Corta margens brancas e molduras finas. Devolve a caixa (x0, y0, x1, y1)
-- e se alguma moldura foi removida.
local function trimBox(bb)
    local x0, y0, x1, y1 = 0, 0, bb:getWidth() - 1, bb:getHeight() - 1
    local frame_max = math.max(2, math.floor(math.min(x1, y1) * 0.05))
    local removed_frame = false
    -- side: 1 = topo, 2 = base, 3 = esquerda, 4 = direita
    local function edge(side, offset)
        if side == 1 then return true, y0 + offset, x0, x1 end
        if side == 2 then return true, y1 - offset, x0, x1 end
        if side == 3 then return false, x0 + offset, y0, y1 end
        return false, x1 - offset, y0, y1
    end
    local function shrink(side, count)
        if side == 1 then y0 = y0 + count
        elseif side == 2 then y1 = y1 - count
        elseif side == 3 then x0 = x0 + count
        else x1 = x1 - count end
    end
    local changed = true
    while changed do
        changed = false
        for side = 1, 4 do
            while x1 - x0 > 8 and y1 - y0 > 8 do
                local horizontal, pos, from, to = edge(side, 0)
                local white, dark = lineStats(bb, horizontal, pos, from, to)
                if white >= 0.995 then
                    shrink(side, 1)
                    changed = true
                elseif dark >= 0.85 then
                    -- Moldura: até frame_max linhas escuras e, depois, interior claro.
                    local k = 1
                    while k <= frame_max do
                        horizontal, pos, from, to = edge(side, k)
                        local _, d = lineStats(bb, horizontal, pos, from, to)
                        if d < 0.85 then break end
                        k = k + 1
                    end
                    horizontal, pos, from, to = edge(side, k)
                    local w_next = lineStats(bb, horizontal, pos, from, to)
                    if k <= frame_max and w_next >= 0.95 then
                        shrink(side, k)
                        removed_frame = true
                        changed = true
                    else
                        break
                    end
                else
                    break
                end
            end
        end
    end
    return x0, y0, x1, y1, removed_frame
end

local function cropTo(bb, x0, y0, x1, y1)
    if x0 == 0 and y0 == 0 and x1 == bb:getWidth() - 1 and y1 == bb:getHeight() - 1 then
        return bb
    end
    local cropped = bb:viewport(x0, y0, x1 - x0 + 1, y1 - y0 + 1):copy()
    bb:free()
    return cropped
end

local function processIcon(bb)
    local w, h = bb:getWidth(), bb:getHeight()
    local biggest = math.max(w, h)
    if biggest > ICON_MAX_PX then
        local scale = ICON_MAX_PX / biggest
        local scaled = bb:scale(math.max(1, math.floor(w * scale)), math.max(1, math.floor(h * scale)))
        bb:free()
        bb = scaled
    end
    whitenBackground(bb)
    local x0, y0, x1, y1, removed_frame = trimBox(bb)
    bb = cropTo(bb, x0, y0, x1, y1)
    if removed_frame then
        -- O interior da moldura pode ter o próprio fundo opaco.
        whitenBackground(bb)
        bb = cropTo(bb, trimBox(bb))
    end
    return bb
end

-- Imagem do ícone já tratada, em cache junto com as informações do script.
local function getIconBB(info)
    if info.icon_bb == nil then
        local ok, bb
        if info.icon then
            ok, bb = pcall(RenderImage.renderImageData, RenderImage, info.icon, #info.icon)
        elseif info.icon_file and not info.icon_file:lower():match("%.svg$") then
            ok, bb = pcall(RenderImage.renderImageFile, RenderImage, info.icon_file, false)
        end
        if ok and bb then
            local ok_p, processed = pcall(processIcon, bb)
            if ok_p and processed then
                bb = processed
            else
                logger.warn("KindleScriptLauncher: falha ao tratar ícone de", info.path, processed)
            end
        else
            bb = nil
        end
        info.icon_bb = bb or false
    end
    return info.icon_bb or nil
end

-- Widget com o ícone do scriptlet encaixado em side x side, ou nil.
local function makeIconWidget(info, side)
    local bb = getIconBB(info)
    if bb then
        return ImageWidget:new{
            image = bb,
            image_disposable = false, -- o cache é dono da imagem
            width = side,
            height = side,
            scale_factor = 0,
            alpha = true,
        }
    end
    if info.icon_file then
        -- SVG (ex.: navegador) ou arquivo que o tratamento não conseguiu abrir.
        local ok, widget = pcall(function()
            local w = ImageWidget:new{ file = info.icon_file, width = side, height = side, scale_factor = 0, alpha = true }
            w:getSize() -- força o carregamento para detectar falhas aqui
            return w
        end)
        if ok then
            return widget
        end
    end
end

-- Tela cheia no estilo "tela de início": ícone, título, status e uma dica.
-- `icon` é um widget já pronto (ou nil).
local function buildSplash(icon, title, status, hint)
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local group = VerticalGroup:new{ align = "center" }
    if icon then
        table.insert(group, icon)
        table.insert(group, VerticalSpan:new{ width = Screen:scaleBySize(40) })
    end
    table.insert(group, TextBoxWidget:new{
        text = title,
        face = Font:getFace("tfont", 32),
        width = math.floor(screen_w * 0.85),
        alignment = "center",
    })
    table.insert(group, VerticalSpan:new{ width = Screen:scaleBySize(16) })
    table.insert(group, TextBoxWidget:new{
        text = status,
        face = Font:getFace("cfont", 22),
        width = math.floor(screen_w * 0.85),
        alignment = "center",
    })
    table.insert(group, VerticalSpan:new{ width = Screen:scaleBySize(60) })
    table.insert(group, TextBoxWidget:new{
        text = hint,
        face = Font:getFace("cfont", 16),
        width = math.floor(screen_w * 0.8),
        alignment = "center",
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    })
    return FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        margin = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = screen_w, h = screen_h },
            group,
        },
    }
end

local function splashIconSide()
    return math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.4)
end

-- Símbolo do Zen, com o logo do KOReader de reserva.
local function makeZenIcon(side)
    for _, file in ipairs(M.ZEN_ICONS) do
        if isFile(file) then
            local ok, widget = pcall(function()
                local w = ImageWidget:new{ file = file, width = side, height = side, is_icon = true }
                w:getSize() -- força o carregamento para detectar falhas aqui
                return w
            end)
            if ok then
                return widget
            end
        end
    end
    return ImageWidget:new{
        file = "resources/koreader.png",
        width = side,
        height = side,
        scale_factor = 0,
        alpha = true,
    }
end

M.basename = basename
M.isFile = isFile
M.readScriptInfo = readScriptInfo
M.makeIconWidget = makeIconWidget
M.makeZenIcon = makeZenIcon
M.buildSplash = buildSplash
M.splashIconSide = splashIconSide

return M
