-- Este APP e idealizado por oQuasi e Claude desde 20072026 - Nao permitimos a copia. Divirta-se! Todos os Direitos Reservados
--
-- UZIR_SleepReport.lua
-- Painel maior e menos transparente que o HUD principal, com moldura de
-- borda dupla (efeito de "quadro"). Fluxo:
--
--   1. Personagem DORME -> tiramos um "retrato" (snapshot) do que foi
--      acumulado desde o ultimo sono, guardamos no historico, zeramos o
--      contador "ao vivo", e mostramos o painel com esse retrato (o "dia
--      que passou"). Isso evita o numero mudar sozinho enquanto o painel
--      esta aberto (era o que causava o bug de resetar a meia-noite).
--   2. Personagem ACORDA -> tentamos pausar o jogo (o painel atrapalha a
--      visão do jogo). O painel continua visivel.
--   3. O painel so fecha quando o jogador clica em "Fechar", e ai
--      despausamos o jogo.
--   4. Botoes "< Dia anterior" / "Proximo dia >" navegam pelo historico.
--
-- Dividido em duas colunas internas:
--   Esquerda: VALID POINTS (mortes "oficiais", contadas pelo jogo)
--   Direita:  inVALID POINTS (fogo/atropelamento)
--
-- REGRA DE ARQUITETURA: assim como o HUD principal, este arquivo e so
-- APRESENTACAO. Toda leitura de dado passa por UZIR.Tracker; a unica
-- excecao e snapshotAndResetToday, que E uma gravacao, mas e chamada de
-- propósito a partir daqui (ver updateSleepState mais abaixo) porque a
-- transicao de dormir e um evento de UI/gameplay, nao de dados puros.

require "ISUI/ISPanel"
require "ISUI/ISButton"

UZIR_SleepReport = ISPanel:derive("UZIR_SleepReport")

local PANEL_WIDTH = 360
local PANEL_HEIGHT = 320

local INNER_INSET = 6      -- distancia entre a borda externa e a interna
local CONTENT_INSET = 14   -- distancia entre a borda interna e o texto

local ROW_HEIGHT = 16
local SECTION_GAP = 8

local BUTTON_HEIGHT = 24
local BUTTON_MARGIN = 10

-- ================== Pausar/retomar o jogo (experimental) ==================
-- ATENCAO: nao ha uma unica funcao de "pausar" universalmente documentada
-- para todas as versoes/builds. Tentamos algumas conhecidas em sequencia;
-- se nenhuma funcionar, o jogo so nao pausa (nao trava o mod).
local function trySetGameSpeed(speed)
    local candidates = {
        function() getGameTime():setGameSpeed(speed) end,
        function() getCore():setGameSpeed(speed) end,
    }
    for _, fn in ipairs(candidates) do
        local ok = pcall(fn)
        if ok then return true end
    end
    return false
end

local function pauseGame()
    trySetGameSpeed(0)
end

local function resumeGame()
    trySetGameSpeed(1)
end

-- ================== Estado de sono (transicao dormir/acordar) ==================

local function isPlayerAsleep(player)
    local ok, asleep = pcall(function() return player:isAsleep() end)
    return ok and asleep
end

-- ================== Construcao ==================

function UZIR_SleepReport:new(x, y, width, height)
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self

    o.backgroundColor = {r = 0, g = 0, b = 0, a = 0.75}
    o.borderColor = {r = 0, g = 0, b = 0, a = 0} -- desenhamos a moldura na mao
    o.moving = false
    o.viewIndex = nil -- indice do historico sendo exibido

    return o
end

function UZIR_SleepReport:initialise()
    ISPanel.initialise(self)
end

function UZIR_SleepReport:createChildren()
    ISPanel.createChildren(self)

    local w, h = self:getWidth(), self:getHeight()
    local y = h - BUTTON_MARGIN - BUTTON_HEIGHT

    self.prevButton = ISButton:new(BUTTON_MARGIN, y, 90, BUTTON_HEIGHT, "< Dia anterior", self, UZIR_SleepReport.onPrevDay)
    self.prevButton:initialise()
    self.prevButton:instantiate()
    self:addChild(self.prevButton)

    self.nextButton = ISButton:new(BUTTON_MARGIN + 96, y, 90, BUTTON_HEIGHT, "Proximo dia >", self, UZIR_SleepReport.onNextDay)
    self.nextButton:initialise()
    self.nextButton:instantiate()
    self:addChild(self.nextButton)

    self.closeButton = ISButton:new(w - BUTTON_MARGIN - 80, y, 80, BUTTON_HEIGHT, "Fechar", self, UZIR_SleepReport.onClose)
    self.closeButton:initialise()
    self.closeButton:instantiate()
    self:addChild(self.closeButton)

    -- Botao dentro da coluna esquerda (Valid Points), na ultima posicao do
    -- conteudo. Serve para reexibir o HUD principal (UZI) caso ele tenha
    -- sido escondido por algum motivo. Posicao real (x/y) e ajustada a
    -- cada frame em prerender, pois o tamanho do conteudo da coluna muda
    -- de um dia para o outro.
    self.uziButton = ISButton:new(0, 0, 70, 20, "UZIr", self, UZIR_SleepReport.onShowMainHud)
    self.uziButton:initialise()
    self.uziButton:instantiate()
    self:addChild(self.uziButton)
end

-- ================== Navegacao pelo historico ==================

function UZIR_SleepReport:onPrevDay()
    if self.viewIndex and self.viewIndex > 1 then
        self.viewIndex = self.viewIndex - 1
    end
end

function UZIR_SleepReport:onNextDay()
    local player = UZIR.Tracker.getPlayer()
    local history = player and UZIR.Tracker.getDailyHistory(player) or {}
    if self.viewIndex and self.viewIndex < #history then
        self.viewIndex = self.viewIndex + 1
    end
end

function UZIR_SleepReport:onClose()
    self:setVisible(false)
    resumeGame()
end

-- Reexibe o HUD principal (painel "UZI" com zKILL/Live/etc), caso ele
-- tenha sido escondido. Nao mexe em nenhum dado, so em visibilidade de UI.
function UZIR_SleepReport:onShowMainHud()
    if UZIR.hudInstance then
        UZIR.hudInstance:setVisible(true)
        UZIR.hudInstance:bringToTop()
    end
end

-- ================== Conteudo: VALID POINTS (esquerda) ==================

function UZIR_SleepReport:drawValidPoints(startX, startY, columnWidth, breakdown, dayNumber)
    local cursorY = startY

    local title = "VALID POINTS"
    if dayNumber then
        title = title .. "  (Dia " .. dayNumber .. ")"
    end
    self:drawTextCentre(title, startX + columnWidth / 2, cursorY, 1, 1, 1, 1, UIFont.Small)
    cursorY = cursorY + ROW_HEIGHT + 4

    local player = UZIR.Tracker.getPlayer()
    local total = player and UZIR.Tracker.getKillCount(player) or 0
    self:drawText("TOTAL Points = " .. string.format("%04d", total), startX, cursorY, 1, 1, 1, 1, UIFont.NewSmall)
    cursorY = cursorY + ROW_HEIGHT + SECTION_GAP

    self:drawText("Today's Points", startX, cursorY, 1, 1, 1, 1, UIFont.NewSmall)
    cursorY = cursorY + ROW_HEIGHT

    self:drawText("Type", startX, cursorY, 0.8, 0.8, 0.8, 1, UIFont.NewSmall)
    cursorY = cursorY + ROW_HEIGHT

    if #breakdown.order == 0 then
        self:drawText("(nenhuma neste dia)", startX, cursorY, 0.6, 0.6, 0.6, 1, UIFont.NewSmall)
        cursorY = cursorY + ROW_HEIGHT
    end

    for _, categoryName in ipairs(breakdown.order) do
        local cat = breakdown.categories[categoryName]
        self:drawText(categoryName, startX, cursorY, 1, 1, 1, 1, UIFont.NewSmall)
        cursorY = cursorY + ROW_HEIGHT

        for _, weapon in ipairs(cat.weapons) do
            local line = string.format("%s = %02d Kills", weapon.name, weapon.count)
            self:drawText(line, startX + 8, cursorY, 1, 1, 1, 1, UIFont.NewSmall)
            cursorY = cursorY + ROW_HEIGHT
        end
    end

    return cursorY
end

-- ================== Conteudo: inVALID POINTS (direita) ==================
-- Mortes por fogo/atropelamento sao so demonstrativas/curiosidade - NUNCA
-- entram no total oficial (Valid Points). Por isso tem o proprio total
-- separado aqui, o "inVALID TOTAL", em vez de reusar o rotulo "TOTAL Points"
-- do lado esquerdo (que e o total oficial de verdade).

function UZIR_SleepReport:drawInvalidPoints(startX, startY, columnWidth, fireToday, vehicleToday, dayNumber)
    local cursorY = startY

    local title = "inVALID POINTS"
    if dayNumber then
        title = title .. "  (Dia " .. dayNumber .. ")"
    end
    self:drawTextCentre(title, startX + columnWidth / 2, cursorY, 1, 1, 1, 1, UIFont.Small)
    cursorY = cursorY + ROW_HEIGHT + 4

    local player = UZIR.Tracker.getPlayer()
    local total = player and UZIR.Tracker.getInvalidTotal(player) or 0
    self:drawText("inVALID TOTAL = " .. string.format("%04d", total), startX, cursorY, 1, 1, 1, 1, UIFont.NewSmall)
    cursorY = cursorY + ROW_HEIGHT + SECTION_GAP

    self:drawText("Today's Points", startX, cursorY, 1, 1, 1, 1, UIFont.NewSmall)
    cursorY = cursorY + ROW_HEIGHT

    self:drawText("Type", startX, cursorY, 0.8, 0.8, 0.8, 1, UIFont.NewSmall)
    cursorY = cursorY + ROW_HEIGHT

    if fireToday <= 0 and vehicleToday <= 0 then
        self:drawText("(nenhuma neste dia)", startX, cursorY, 0.6, 0.6, 0.6, 1, UIFont.NewSmall)
        cursorY = cursorY + ROW_HEIGHT
    end

    if fireToday > 0 then
        self:drawText(string.format("Fire = %02d Kills", fireToday), startX, cursorY, 1, 1, 1, 1, UIFont.NewSmall)
        cursorY = cursorY + ROW_HEIGHT
    end

    if vehicleToday > 0 then
        self:drawText(string.format("Vehicle = %02d Kills", vehicleToday), startX, cursorY, 1, 1, 1, 1, UIFont.NewSmall)
        cursorY = cursorY + ROW_HEIGHT
    end

    return cursorY
end

-- ================== Renderizacao ==================

function UZIR_SleepReport:prerender()
    ISPanel.prerender(self)

    local w, h = self:getWidth(), self:getHeight()

    -- Moldura de borda dupla.
    self:drawRectBorder(0, 0, w, h, 1, 0.85, 0.85, 0.85)
    self:drawRectBorder(INNER_INSET, INNER_INSET, w - INNER_INSET * 2, h - INNER_INSET * 2, 1, 0.5, 0.5, 0.5)

    local contentX = INNER_INSET + CONTENT_INSET
    local contentY = INNER_INSET + CONTENT_INSET
    local contentWidth = w - (contentX * 2)

    self:drawTextCentre("UZIr - Sleep Report", w / 2, contentY, 1, 1, 1, 1, UIFont.Small)
    local bodyY = contentY + ROW_HEIGHT + 6

    self:drawRect(INNER_INSET + 4, bodyY - 4, w - (INNER_INSET + 4) * 2, 1, 0.35, 1, 1, 1)
    self:drawRect(w / 2, bodyY, 1, h - bodyY - INNER_INSET - BUTTON_HEIGHT - BUTTON_MARGIN * 2, 0.35, 1, 1, 1)

    local player = UZIR.Tracker.getPlayer()
    local history = player and UZIR.Tracker.getDailyHistory(player) or {}

    if not self.viewIndex or self.viewIndex > #history then
        self.viewIndex = #history
    end
    if self.viewIndex < 1 then self.viewIndex = 1 end

    local entry = history[self.viewIndex]
    local breakdown = entry and entry.breakdown or {order = {}, categories = {}}
    local dayNumber = entry and entry.dayNumber or nil

    local validEndY = self:drawValidPoints(contentX, bodyY, (w / 2) - contentX, breakdown, dayNumber)

    local fireToday = entry and entry.invalidFire or 0
    local vehicleToday = entry and entry.invalidVehicle or 0
    self:drawInvalidPoints((w / 2) + CONTENT_INSET - INNER_INSET, bodyY, (w / 2) - contentX, fireToday, vehicleToday, dayNumber)

    -- Botao "UZIr" fica sempre logo depois do ultimo item da coluna
    -- esquerda, entao sua posicao acompanha o tamanho do conteudo do dia.
    if self.uziButton then
        self.uziButton:setX(contentX)
        self.uziButton:setY(validEndY + 4)
    end

    -- Habilita/desabilita os botoes de navegacao conforme os limites do historico.
    if self.prevButton then
        self.prevButton:setEnable(self.viewIndex and self.viewIndex > 1)
    end
    if self.nextButton then
        self.nextButton:setEnable(self.viewIndex and self.viewIndex < #history)
    end
end

-- ================== Criacao / controle de sono ==================

local function createSleepReport()
    if UZIR.sleepReportInstance then return end

    local screenW = getCore():getScreenWidth()
    local screenH = getCore():getScreenHeight()

    local x = (screenW - PANEL_WIDTH) / 2
    local y = (screenH - PANEL_HEIGHT) / 2

    local panel = UZIR_SleepReport:new(x, y, PANEL_WIDTH, PANEL_HEIGHT)
    panel:initialise()
    panel:addToUIManager()
    panel:setVisible(false)

    UZIR.sleepReportInstance = panel
    UZIR.sleepReportWasAsleep = false
end

local function updateSleepState()
    local panel = UZIR.sleepReportInstance
    if not panel then return end

    local player = UZIR.Tracker.getPlayer()
    if not player then return end

    local asleep = isPlayerAsleep(player)
    local wasAsleep = UZIR.sleepReportWasAsleep

    if asleep and not wasAsleep then
        -- Acabou de dormir: tira o retrato do dia que passou e mostra o painel.
        UZIR.Tracker.snapshotAndResetToday(player)
        local history = UZIR.Tracker.getDailyHistory(player)
        panel.viewIndex = #history
        panel:setVisible(true)
    elseif (not asleep) and wasAsleep then
        -- Acabou de acordar: pausa o jogo, mas mantem o painel aberto ate
        -- o jogador clicar em "Fechar".
        pauseGame()
    end

    UZIR.sleepReportWasAsleep = asleep
end

Events.OnGameStart.Add(createSleepReport)
Events.OnPlayerUpdate.Add(updateSleepState)
