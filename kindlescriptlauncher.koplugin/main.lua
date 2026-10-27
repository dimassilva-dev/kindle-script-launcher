--[[--
Executa scriptlets .sh do Kindle com o framework ativo, sem fechar o KOReader.

Fluxo: o plugin solta os dispositivos de entrada (o KOReader os prende com
EVIOCGRAB) e o nome LIPC com.lab126.kaf, grava um arquivo de tarefa e dispara
launcher.sh em segundo plano. O launcher.sh congela o KOReader (SIGSTOP),
inicia o framework, roda o script, espera o app aberto por ele fechar, para o
framework e retoma o KOReader (SIGCONT). O plugin então percebe o arquivo de
retomada, reabre a entrada e redesenha a tela.
]]

local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local PathChooser = require("ui/widget/pathchooser")
local SpinWidget = require("ui/widget/spinwidget")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local ScriptLibrary = require("scriptlibrary")
local UI = require("kslauncher_ui")
local Screen = Device.screen
local T = require("ffi/util").template

-- Troca a tela "Restoring Kindle GUI…" do ZenOS (exibida ao sair do KOReader
-- sem framework) pela versão em português e no estilo deste plugin. Este
-- arquivo é carregado antes do zenos.koplugin, que obtém o patch via require.
local ZENOS_EXIT_PATCH = "modules/global/patches/kindle_exit_message"
if package.loaded[ZENOS_EXIT_PATCH] == nil then
    package.loaded[ZENOS_EXIT_PATCH] = require("kslauncher_exit")
end

local SETTINGS_KEY = "kindle_script_launcher"
local JOB_FILE = "/tmp/kindlescriptlauncher.job"
local RESUME_FLAG = "/tmp/kindlescriptlauncher.resume"
local RETURN_FB = "/var/tmp/kindlescriptlauncher-return.fb"
local LOG_FILE = "/mnt/us/koreader/kindlescriptlauncher.log"
local MAX_RECENT = 60
local DEFAULTS = {
    start_dir = "/mnt/us/documents",
    settle_time = 15,
}

local function shellQuote(str)
    return "'" .. (tostring(str):gsub("'", "'\\''")) .. "'"
end

local basename = UI.basename
local isFile = UI.isFile
local readScriptInfo = UI.readScriptInfo
local makeIconWidget = UI.makeIconWidget
local buildSplash = UI.buildSplash
local splashIconSide = UI.splashIconSide

-- O KOReader roda a partir da própria pasta e informa caminhos de plugin
-- relativos a ela (ex.: "plugins/x.koplugin"); o launcher.sh entra na pasta
-- do script antes de executá-lo, então todo caminho precisa ser absoluto.
local function absPath(path)
    if path and path:sub(1, 1) ~= "/" then
        return lfs.currentdir() .. "/" .. path
    end
    return path
end

local function isDir(path)
    return path ~= nil and lfs.attributes(path, "mode") == "directory"
end

local function showMessage(text, timeout)
    UIManager:show(InfoMessage:new{ text = text, timeout = timeout })
end

local function getPid()
    local f = io.open("/proc/self/stat", "r")
    if not f then return end
    local pid = f:read("*n")
    f:close()
    return pid
end

local KindleScriptLauncher = WidgetContainer:extend{
    name = "kindlescriptlauncher",
    is_doc_only = false,
    -- Usados pela biblioteca (scriptlibrary.lua).
    isFile = isFile,
    readScriptInfo = readScriptInfo,
    makeIconWidget = makeIconWidget,
}

function KindleScriptLauncher:init()
    local settings = G_reader_settings:readSetting(SETTINGS_KEY) or {}
    for k, v in pairs(DEFAULTS) do
        if settings[k] == nil then
            settings[k] = v
        end
    end
    settings.recent = settings.recent or {}
    settings.no_framework = settings.no_framework or {}
    settings.seeded = settings.seeded or {}
    -- Converte caminhos relativos salvos por versões anteriores.
    for i, path in ipairs(settings.recent) do
        settings.recent[i] = absPath(path)
    end
    for _, key in ipairs({ "seeded", "no_framework" }) do
        local fixed = {}
        for path, v in pairs(settings[key]) do
            fixed[absPath(path)] = v
        end
        settings[key] = fixed
    end
    self.settings = settings
    self:seedBundledScripts()

    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    self:addFileDialogButton()
end

-- Scripts que acompanham o plugin (pasta scripts/, ex.: o navegador) entram
-- na biblioteca uma única vez; se o usuário os remover, não voltam.
function KindleScriptLauncher:seedBundledScripts()
    local dir = absPath(self.path) .. "/scripts"
    if not isDir(dir) then return end
    local seeded = self.settings.seeded
    local changed = false
    for name in lfs.dir(dir) do
        local path = dir .. "/" .. name
        if name:lower():match("%.sh$") and not seeded[path] and isFile(path) then
            seeded[path] = true
            local present = false
            for _, p in ipairs(self.settings.recent) do
                if p == path then
                    present = true
                    break
                end
            end
            if not present then
                table.insert(self.settings.recent, path)
            end
            changed = true
        end
    end
    if changed then
        self:saveSettings()
    end
end

function KindleScriptLauncher:saveSettings()
    G_reader_settings:saveSetting(SETTINGS_KEY, self.settings)
end

function KindleScriptLauncher:onDispatcherRegisterActions()
    Dispatcher:registerAction("kindle_script_launcher_library", {
        category = "none",
        event = "KindleScriptLauncherLibrary",
        title = "Biblioteca de scripts do Kindle",
        general = true,
    })
    Dispatcher:registerAction("kindle_script_launcher_choose", {
        category = "none",
        event = "KindleScriptLauncherChoose",
        title = "Executar script do Kindle…",
        general = true,
    })
end

function KindleScriptLauncher:onKindleScriptLauncherLibrary()
    self:showLibrary()
    return true
end

function KindleScriptLauncher:showLibrary()
    UIManager:show(ScriptLibrary:new{ plugin = self })
end

function KindleScriptLauncher:onKindleScriptLauncherChoose()
    self:chooseScript()
    return true
end

-- Botão "Executar com framework" no diálogo de toque longo do gerenciador de
-- arquivos (só em versões do KOReader que expõem addFileDialogButtons).
function KindleScriptLauncher:addFileDialogButton()
    if not (self.ui.file_chooser and self.ui.addFileDialogButtons) then return end
    local ok, err = pcall(self.ui.addFileDialogButtons, self.ui, "kindle_script_launcher",
        function(file, is_file)
            if is_file and file:lower():match("%.sh$") then
                return {
                    {
                        text = "Executar com framework",
                        callback = function()
                            if self.ui.file_dialog then
                                UIManager:close(self.ui.file_dialog)
                            end
                            self:confirmLaunch(file)
                        end,
                    },
                }
            end
        end)
    if not ok then
        logger.warn("KindleScriptLauncher: addFileDialogButtons falhou:", err)
    end
end

function KindleScriptLauncher:onCloseWidget()
    if self.ui.file_chooser and self.ui.removeFileDialogButtons then
        pcall(self.ui.removeFileDialogButtons, self.ui, "kindle_script_launcher")
    end
end

function KindleScriptLauncher:addToMainMenu(menu_items)
    menu_items.kindle_script_launcher = {
        text = "Scripts do Kindle",
        sorting_hint = "tools",
        sub_item_table_func = function()
            return self:getMenuItems()
        end,
    }
end

function KindleScriptLauncher:getMenuItems()
    return {
        {
            text = "Biblioteca de scripts",
            callback = function()
                self:showLibrary()
            end,
        },
        {
            text = "Escolher script…",
            callback = function()
                self:chooseScript()
            end,
            separator = true,
        },
        {
            text = "Configurações",
            sub_item_table = self:getSettingsMenuItems(),
        },
    }
end

function KindleScriptLauncher:getSettingsMenuItems()
    return {
        {
            text_func = function()
                return T("Pasta inicial: %1", self.settings.start_dir)
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                self:choosePath(false, self.settings.start_dir, function(path)
                    self.settings.start_dir = path
                    self:saveSettings()
                    touchmenu_instance:updateItems()
                end)
            end,
        },
        {
            text_func = function()
                return T("Espera após iniciar o framework: %1 s", self.settings.settle_time)
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                UIManager:show(SpinWidget:new{
                    title_text = "Espera após iniciar o framework",
                    info_text = "Segundos de espera depois que o framework sobe, antes de executar o script.",
                    value = self.settings.settle_time,
                    value_min = 0,
                    value_max = 120,
                    value_step = 1,
                    value_hold_step = 5,
                    default_value = DEFAULTS.settle_time,
                    callback = function(spin)
                        self.settings.settle_time = spin.value
                        self:saveSettings()
                        touchmenu_instance:updateItems()
                    end,
                })
            end,
            separator = true,
        },
        {
            text = "Ver log da última execução",
            keep_menu_open = true,
            callback = function()
                self:showLog()
            end,
        },
    }
end

function KindleScriptLauncher:choosePath(select_file, start_dir, on_confirm)
    if not isDir(start_dir) then
        start_dir = isDir("/mnt/us") and "/mnt/us" or "/"
    end
    UIManager:show(PathChooser:new{
        select_directory = not select_file,
        select_file = select_file,
        show_files = select_file,
        file_filter = select_file and function(filename)
            return filename:lower():match("%.sh$") ~= nil
        end or nil,
        path = start_dir,
        onConfirm = on_confirm,
    })
end

function KindleScriptLauncher:chooseScript()
    self:choosePath(true, self.settings.start_dir, function(path)
        self:launch(path)
    end)
end

function KindleScriptLauncher:confirmLaunch(script)
    UIManager:show(ConfirmBox:new{
        text = self:usesFramework(script)
            and T("Executar %1?\n\nO framework do Kindle será iniciado e o KOReader ficará pausado até o app do script ser fechado.", basename(script))
            or T("Executar %1 sem o framework?\n\nO KOReader ficará pausado até o app do script ser fechado.", basename(script)),
        ok_text = "Executar",
        ok_callback = function()
            self:launch(script)
        end,
    })
end

-- Por padrão o framework é iniciado; scripts marcados rodam sem ele.
function KindleScriptLauncher:usesFramework(path)
    return not self.settings.no_framework[path]
end

function KindleScriptLauncher:setUsesFramework(path, enabled)
    self.settings.no_framework[path] = (not enabled) or nil
    self:saveSettings()
end

-- A lista "recent" é a ordem da biblioteca. Scripts novos entram no início;
-- os que já estão nela mantêm a posição escolhida pelo usuário.
function KindleScriptLauncher:indexOfScript(path)
    for i, p in ipairs(self.settings.recent) do
        if p == path then
            return i
        end
    end
end

function KindleScriptLauncher:addRecent(path)
    if self:indexOfScript(path) then return end
    table.insert(self.settings.recent, 1, path)
    while #self.settings.recent > MAX_RECENT do
        table.remove(self.settings.recent)
    end
    self:saveSettings()
end

-- where: -1/+1 (uma posição), "first" ou "last". Devolve a nova posição.
function KindleScriptLauncher:moveScript(path, where)
    local recent = self.settings.recent
    local index = self:indexOfScript(path)
    if not index then return end
    local target
    if where == "first" then
        target = 1
    elseif where == "last" then
        target = #recent
    else
        target = math.max(1, math.min(#recent, index + where))
    end
    if target ~= index then
        table.remove(recent, index)
        table.insert(recent, target, path)
        self:saveSettings()
    end
    return target
end

-- Chave de ordenação: nome em minúsculas e sem acentos.
local ACCENTS = {
    ["á"] = "a", ["à"] = "a", ["â"] = "a", ["ã"] = "a", ["ä"] = "a",
    ["é"] = "e", ["è"] = "e", ["ê"] = "e", ["ë"] = "e",
    ["í"] = "i", ["ì"] = "i", ["î"] = "i", ["ï"] = "i",
    ["ó"] = "o", ["ò"] = "o", ["ô"] = "o", ["õ"] = "o", ["ö"] = "o",
    ["ú"] = "u", ["ù"] = "u", ["û"] = "u", ["ü"] = "u",
    ["ç"] = "c", ["ñ"] = "n",
    ["Á"] = "a", ["À"] = "a", ["Â"] = "a", ["Ã"] = "a", ["Ä"] = "a",
    ["É"] = "e", ["È"] = "e", ["Ê"] = "e", ["Ë"] = "e",
    ["Í"] = "i", ["Ì"] = "i", ["Î"] = "i", ["Ï"] = "i",
    ["Ó"] = "o", ["Ò"] = "o", ["Ô"] = "o", ["Õ"] = "o", ["Ö"] = "o",
    ["Ú"] = "u", ["Ù"] = "u", ["Û"] = "u", ["Ü"] = "u",
    ["Ç"] = "c", ["Ñ"] = "n",
}
local function sortKey(name)
    local key = name:lower():gsub("[\195][\128-\191]", function(ch)
        return ACCENTS[ch] or ch
    end)
    return key
end

function KindleScriptLauncher:sortLibrary(descending)
    local keys = {}
    for _, path in ipairs(self.settings.recent) do
        keys[path] = sortKey(readScriptInfo(path).name)
    end
    table.sort(self.settings.recent, function(a, b)
        if keys[a] == keys[b] then
            return a < b
        end
        if descending then
            return keys[a] > keys[b]
        end
        return keys[a] < keys[b]
    end)
    self:saveSettings()
end

-- Tira da biblioteca os scripts cujo arquivo não existe mais.
function KindleScriptLauncher:pruneMissing()
    local recent = self.settings.recent
    local changed = false
    for i = #recent, 1, -1 do
        if not isFile(recent[i]) then
            table.remove(recent, i)
            changed = true
        end
    end
    if changed then
        self:saveSettings()
    end
end

function KindleScriptLauncher:removeRecent(path)
    local recent = self.settings.recent
    for i = #recent, 1, -1 do
        if recent[i] == path then
            table.remove(recent, i)
        end
    end
    self:saveSettings()
end

function KindleScriptLauncher:showLog()
    local f = io.open(LOG_FILE, "r")
    if not f then
        showMessage("Nenhum log encontrado.")
        return
    end
    local content = f:read("*a")
    f:close()
    UIManager:show(TextViewer:new{
        title = "Log do Kindle script launcher",
        text = content ~= "" and content or "(vazio)",
    })
end

function KindleScriptLauncher:launch(script)
    script = absPath(script)
    if not Device:isKindle() then
        showMessage("Este plugin só funciona no Kindle.")
        return
    end
    if os.getenv("STOP_FRAMEWORK") ~= "yes" then
        showMessage("Este plugin é para o KOReader aberto sem framework (ZenReader.sh).")
        return
    end
    if self.waiting_resume then
        showMessage("Já há um script em execução.")
        return
    end
    if not isFile(script) then
        showMessage(T("Script não encontrado:\n%1", script))
        return
    end
    local helper = self.path .. "/launcher.sh"
    if not isFile(helper) then
        showMessage(T("Arquivo ausente:\n%1", helper))
        return
    end
    local pid = getPid()
    if not pid then
        showMessage("Não foi possível obter o PID do KOReader.")
        return
    end

    local job, err = io.open(JOB_FILE, "w")
    if not job then
        showMessage(T("Não foi possível gravar %1:\n%2", JOB_FILE, tostring(err)))
        return
    end
    job:write(
        "SCRIPT=", shellQuote(script), "\n",
        "KO_PID=", tostring(pid), "\n",
        "RESUME_FLAG=", shellQuote(RESUME_FLAG), "\n",
        "SETTLE_TIME=", tostring(tonumber(self.settings.settle_time) or DEFAULTS.settle_time), "\n",
        "USE_FRAMEWORK=", self:usesFramework(script) and "1" or "0", "\n",
        "RETURN_FB=", shellQuote(RETURN_FB), "\n",
        "LOG=", shellQuote(LOG_FILE), "\n")
    job:close()
    os.remove(RESUME_FLAG)

    self:addRecent(script)
    G_reader_settings:flush()
    if self.ui.document and self.ui.saveSettings then
        self.ui:saveSettings()
    end

    local info = readScriptInfo(script)
    self:prepareReturnScreen(info)
    self:showSplash(info)
    -- Dá tempo da tela de início ser desenhada antes de soltar a entrada e pausar
    -- (o launcher.sh copia o framebuffer para cobrir a Home enquanto o framework sobe).
    UIManager:scheduleIn(1, function()
        self:releaseDevice()
        -- setsid/nohup para que o launcher não fique preso ao KOReader.
        local args = shellQuote(helper) .. " " .. shellQuote(JOB_FILE) .. " </dev/null >/dev/null 2>&1 &"
        local cmd = "if command -v setsid >/dev/null 2>&1; then setsid sh " .. args
            .. " else nohup sh " .. args .. " fi"
        logger.info("KindleScriptLauncher:", cmd)
        local rc = os.execute(cmd)
        if rc ~= 0 and rc ~= true then
            os.remove(JOB_FILE)
            self:restoreDevice()
            showMessage(T("Falha ao iniciar o launcher (código %1).", tostring(rc)))
            return
        end
        self.waiting_resume = true
        self:pollResume()
    end)
end

-- Tela cheia com ícone e nome do scriptlet, mostrada enquanto o app abre.
-- Tela mostrada enquanto o app abre: ícone e nome do scriptlet.
function KindleScriptLauncher:showSplash(info)
    local icon = makeIconWidget(info, splashIconSide())
    self.splash = buildSplash(icon, info.name,
        self:usesFramework(info.path) and "Abrindo…" or "Abrindo sem o framework…",
        "O KOReader volta sozinho quando o app for fechado.")
    UIManager:show(self.splash, "full")
end

-- Tela de retorno, no mesmo estilo, com o logo do KOReader. O KOReader está
-- pausado na hora da volta, então ela é desenhada agora direto no
-- framebuffer (sem atualizar o e-ink) e copiada para RETURN_FB; o launcher.sh
-- só a restaura e atualiza a tela. A tela de início cobre o desenho em seguida.
function KindleScriptLauncher:prepareReturnScreen(info)
    os.remove(RETURN_FB)
    local side = splashIconSide()
    local icon = UI.makeZenIcon(side)
    local widget = buildSplash(icon, "KOReader", "Voltando…",
        T("%1 foi fechado. Encerrando o framework do Kindle.", info.name))
    local ok, err = pcall(function()
        widget:paintTo(Screen.bb, 0, 0)
    end)
    widget:free()
    if not ok then
        logger.warn("KindleScriptLauncher: falha ao desenhar a tela de retorno:", err)
        return
    end
    os.execute("cat /dev/fb0 > " .. shellQuote(RETURN_FB) .. " 2>/dev/null")
end

-- Solta a tela de toque/botões (o KOReader os prende com EVIOCGRAB) e o nome
-- LIPC com.lab126.kaf, para o framework poder usá-los. fake_events (eventos
-- de energia) continua aberto.
function KindleScriptLauncher:releaseDevice()
    local input = Device.input
    input:inhibitInput(true)
    local paths = {}
    for path in pairs(input.opened_devices or {}) do
        if path ~= "fake_events" then
            table.insert(paths, path)
        end
    end
    for _, path in ipairs(paths) do
        local ok, err = pcall(input.close, input, path)
        if not ok then
            logger.warn("KindleScriptLauncher: falha ao fechar", path, err)
        end
    end
    if Device.framework_lipc_handle then
        pcall(Device.framework_lipc_handle.close, Device.framework_lipc_handle)
        Device.framework_lipc_handle = nil
    end
    self:stopEventServers()
end

-- O kindle-button-mapper manda as teclas para o KOReader (texto já no layout
-- do config.ini) sempre que a porta do hidpassthrough (8323) ou do HTTP
-- Inspector (8080) aceita conexão. Congelado com SIGSTOP, o KOReader ainda
-- aceita a conexão, então as teclas iriam para ele e não para o app do script
-- (ex.: AbiWord, que recebe pelo teclado virtual no X). Fecha as portas antes
-- de pausar; restartEventServers reabre ao voltar.
function KindleScriptLauncher:stopEventServers()
    self.stopped_servers = {}
    local hid = self.ui.hidpassthrough
    if hid and hid._eventServer then
        local ok, err = pcall(function() hid:_eventServer().stop() end)
        if ok then
            self.stopped_servers.hidpassthrough = true
        else
            logger.warn("KindleScriptLauncher: falha ao parar o servidor do hidpassthrough:", err)
        end
    end
    local inspector = self.ui.httpinspector
    if inspector and inspector.isRunning and inspector:isRunning() then
        local ok, err = pcall(inspector.stop, inspector)
        if ok then
            self.stopped_servers.httpinspector = true
        else
            logger.warn("KindleScriptLauncher: falha ao parar o HTTP Inspector:", err)
        end
    end
end

function KindleScriptLauncher:restartEventServers()
    local stopped = self.stopped_servers or {}
    self.stopped_servers = nil
    local hid = self.ui.hidpassthrough
    if stopped.hidpassthrough and hid and hid._syncEventServer then
        local ok, err = pcall(hid._syncEventServer, hid)
        if not ok then
            logger.warn("KindleScriptLauncher: falha ao reabrir o servidor do hidpassthrough:", err)
        end
    end
    local inspector = self.ui.httpinspector
    if stopped.httpinspector and inspector and inspector.start then
        local ok, err = pcall(inspector.start, inspector)
        if not ok then
            logger.warn("KindleScriptLauncher: falha ao reabrir o HTTP Inspector:", err)
        end
    end
end

-- Inverso de releaseDevice, depois que o launcher parou o framework e nos
-- retomou: volta a se registrar como com.lab126.kaf (como o KOReader faz ao
-- iniciar sem framework), reabre a entrada e redesenha tudo.
function KindleScriptLauncher:restoreDevice()
    if self.splash then
        UIManager:close(self.splash)
        self.splash = nil
    end
    local haslipc, lipc = pcall(require, "liblipclua")
    if haslipc and not Device.framework_lipc_handle then
        local handle = lipc.init("com.lab126.kaf")
        if handle then
            local framework_started = handle:register_int_property("frameworkStarted", "r")
            framework_started.value = 1
            pcall(handle.set_string_property, handle, "com.lab126.blanket", "unload", "splash")
            pcall(handle.set_string_property, handle, "com.lab126.blanket", "unload", "screensaver")
            Device.framework_lipc_handle = handle
        end
    end
    local ok, err = pcall(Device.openInputDevices, Device)
    if not ok then
        logger.warn("KindleScriptLauncher: falha ao reabrir a entrada:", err)
    end
    self:restartEventServers()
    UIManager:setDirty("all", "full")
    -- Descarta toques residuais antes de liberar a entrada de novo.
    UIManager:scheduleIn(1, function()
        Device.input:inhibitInput(false)
    end)
end

function KindleScriptLauncher:pollResume()
    if not self.waiting_resume then return end
    if isFile(RESUME_FLAG) then
        os.remove(RESUME_FLAG)
        self.waiting_resume = false
        logger.info("KindleScriptLauncher: retomando")
        self:restoreDevice()
        return
    end
    UIManager:scheduleIn(1, function()
        self:pollResume()
    end)
end

return KindleScriptLauncher
