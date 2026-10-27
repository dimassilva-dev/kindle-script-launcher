--[[--
Tela mostrada ao sair do KOReader sem framework, no mesmo estilo das telas de
abertura/retorno do plugin e em português.

Substitui o patch "kindle_exit_message" do ZenOS ("Restoring Kindle GUI…"):
o main.lua registra este módulo em package.loaded com o nome do módulo do
ZenOS antes de o ZenOS carregá-lo (os plugins são carregados em ordem de
caminho), sem editar arquivos do ZenOS. A lógica é a mesma do original: só
age na saída normal com STOP_FRAMEWORK=yes, desenha antes de o framebuffer ser
fechado e usa o kindle_restore_screen.sh do ZenOS para manter a imagem na tela
enquanto a interface do Kindle volta.
]]

local Device = require("device")
local UI = require("kslauncher_ui")
local logger = require("logger")

local applied = false

-- Copia a tela atual (e uma tela branca de referência) e dispara o helper do
-- ZenOS que a repinta se o Kindle apagar a tela durante a restauração.
local function preserveScreen(Screen)
    if not Screen.data or not Screen.fb_size then return end
    local ok_root, root = pcall(require, "common/plugin_root")
    if not ok_root or type(root) ~= "string" then return end
    local helper = root .. "/modules/global/kindle_restore_screen.sh"
    if not UI.isFile(helper) then return end

    local ffi = require("ffi")
    require("ffi/posix_h")
    local template = ffi.new("char[?]", 64, "/tmp/zenos-restore-XXXXXX")
    if ffi.C.mkdtemp(template) == nil then return end
    local directory = ffi.string(template)
    local blank
    local ok, err = pcall(function()
        blank = (Screen.full_bb or Screen.bb):copy()
        blank:fill(require("ffi/blitbuffer").COLOR_WHITE)
        for name, data in pairs({
            screen = ffi.string(Screen.data, Screen.fb_size),
            blank = ffi.string(blank.data, Screen.fb_size),
        }) do
            local file = assert(io.open(directory .. "/" .. name, "wb"))
            local written, write_err = file:write(data)
            local closed, close_err = file:close()
            assert(written and closed, write_err or close_err)
        end
        local util = require("util")
        local command = util.shell_escape({ "sh", helper,
            directory, tostring(Screen.fb_size), Screen.device_node,
            require("libs/libkoreader-lfs").currentdir() .. "/fbink" })
        assert(os.execute(command .. " >>crash.log 2>&1 &") == 0, "Could not start restore screen helper")
    end)
    if blank then blank:free() end
    if not ok then
        os.remove(directory .. "/screen")
        os.remove(directory .. "/blank")
        os.remove(directory)
        logger.warn("KindleScriptLauncher: falha ao preservar a tela de saída:", err)
    end
end

local function showExitScreen(Screen)
    local side = UI.splashIconSide()
    local widget = UI.buildSplash(UI.makeZenIcon(side), "Kindle", "Voltando ao Kindle…",
        "Restaurando a interface do Kindle.")
    Screen.night_mode = false
    Screen:beforePaint()
    Screen:clear()
    widget:paintTo(Screen.bb, 0, 0)
    Screen:refreshFull(0, 0, Screen:getWidth(), Screen:getHeight())
    Screen:refreshWaitForLast()
    Screen:afterPaint()
    widget:free()
end

return function()
    if applied then return end
    if not (Device.isKindle and Device:isKindle()) then return end

    local UIManager = require("ui/uimanager")
    local restoring = false
    local orig_exit = Device.exit
    local orig_close = Device.screen.close
    Device.screen.close = function(Screen, reinit, ...)
        if restoring and not reinit then
            restoring = false
            -- O Kindle restaura screensaver e modos de tela antes de fechar o framebuffer.
            local ok, err = pcall(function()
                showExitScreen(Screen)
                preserveScreen(Screen)
            end)
            if not ok then
                logger.warn("KindleScriptLauncher: falha ao mostrar a tela de saída:", err)
            end
        end
        return orig_close(Screen, reinit, ...)
    end
    Device.exit = function(self, ...)
        restoring = os.getenv("STOP_FRAMEWORK") == "yes" and (UIManager._exit_code or 0) == 0
            and not UIManager._entered_poweroff_stage
        return orig_exit(self, ...)
    end
    applied = true
end
