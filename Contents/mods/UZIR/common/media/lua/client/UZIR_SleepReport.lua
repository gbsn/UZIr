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
--   3. O painel so fecha quando o jogador clica em "Close", e ai
--      despausamos o jogo.
--   4. Botoes "< Previous Day" / "Next Day >" navegam pelo historico.
--
-- Dividido em TRES colunas internas:
--   Esquerda: VALID POINTS (mortes "oficiais", contadas pelo jogo)
--   Meio:     inVALID POINTS (fogo/atropelamento)
--   Direita:  XP GAINED (XP ganho naquele dia, por pericia)
--
-- TAMANHO DINAMICO: largura e altura sao calculadas a cada frame com
-- base no conteudo real (numero de armas/tipos naquele dia, nomes de
-- arma mais compridos, etc), do mesmo jeito que ja fizemos no HUD
-- principal. Antes o painel tinha tamanho fixo e o conteudo podia
-- vazar ou ficar espremido perto dos botoes quando havia muita
-- variedade de arma num dia. O painel fica sempre centralizado na tela.
--
-- REGRA DE ARQUITETURA: assim como o HUD principal, este arquivo e so
-- APRESENTACAO. Toda leitura de dado passa por UZIR.Tracker; a unica
-- excecao e snapshotAndResetToday, que E uma gravacao, mas e chamada de
-- propósito a partir daqui (ver updateSleepState mais abaixo) porque a
-- transicao de dormir e um evento de UI/gameplay, nao de dados puros.

require "ISUI/ISPanel"
require "ISUI/ISButton"

UZIR_SleepReport = ISPanel:derive("UZIR_SleepReport")

local MIN_PANEL_WIDTH = 520
local MIN_COLUMN_WIDTH = 160

local INNER_INSET = 6      -- distancia entre a borda externa e a interna
local CONTENT_INSET = 14   -- distancia entre a borda interna e o texto
local COLUMN_GAP = 20      -- respiro entre as colunas, ao redor de cada linha divisoria

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

-- ================== Medicao de texto ==================

local function measureWidth(text, font)
    local ok, w = pcall(function() return getTextManager():MeasureStringX(font, text) end)
    if ok and w then return w end
    return #text * 8 -- estimativa grosseira caso a medicao falhe
end

-- ================== Construcao das listas de conteudo ==================
-- Cada "entrada" descreve uma linha: texto, fonte, indentacao e o quanto
-- pular de Y depois dela. Usamos a MESMA lista tanto para medir quanto
-- para desenhar, garantindo que a altura calculada bate exatamente com
-- o que sera desenhado (fonte unica de verdade, sem duplicar formatacao).

local function buildValidEntries(player, breakdown, dayNumber)
    local entries = {}

    local title = "VALID POINTS"
    if dayNumber then title = title .. "  (Day " .. dayNumber .. ")" end
    table.insert(entries, {text = title, font = UIFont.Small, centered = true, gapAfter = ROW_HEIGHT + 4})

    local total = player and UZIR.Tracker.getKillCount(player) or 0
    table.insert(entries, {text = "TOTAL Points = " .. string.format("%04d", total), font = UIFont.NewSmall, gapAfter = ROW_HEIGHT + SECTION_GAP})

    table.insert(entries, {text = "Today's Points", font = UIFont.NewSmall, gapAfter = ROW_HEIGHT})
    table.insert(entries, {text = "Type", font = UIFont.NewSmall, gapAfter = ROW_HEIGHT, color = {0.8, 0.8, 0.8}})

    if #breakdown.order == 0 then
        table.insert(entries, {text = "(none this day)", font = UIFont.NewSmall, gapAfter = ROW_HEIGHT, color = {0.6, 0.6, 0.6}})
    end

    for _, categoryName in ipairs(breakdown.order) do
        table.insert(entries, {text = categoryName, font = UIFont.NewSmall, gapAfter = ROW_HEIGHT})
        local cat = breakdown.categories[categoryName]
        for _, weapon in ipairs(cat.weapons) do
            local line = string.format("%s = %02d Kills", weapon.name, weapon.count)
            table.insert(entries, {text = line, font = UIFont.NewSmall, indent = 8, gapAfter = ROW_HEIGHT})
        end
    end

    return entries
end

local function buildInvalidEntries(player, fireToday, vehicleToday, dayNumber)
    local entries = {}

    local title = "inVALID POINTS"
    if dayNumber then title = title .. "  (Day " .. dayNumber .. ")" end
    table.insert(entries, {text = title, font = UIFont.Small, centered = true, gapAfter = ROW_HEIGHT + 4})

    local total = player and UZIR.Tracker.getInvalidTotal(player) or 0
    table.insert(entries, {text = "inVALID TOTAL = " .. string.format("%04d", total), font = UIFont.NewSmall, gapAfter = ROW_HEIGHT + SECTION_GAP})

    table.insert(entries, {text = "Today's Points", font = UIFont.NewSmall, gapAfter = ROW_HEIGHT})
    table.insert(entries, {text = "Type", font = UIFont.NewSmall, gapAfter = ROW_HEIGHT, color = {0.8, 0.8, 0.8}})

    if fireToday <= 0 and vehicleToday <= 0 then
        table.insert(entries, {text = "(none this day)", font = UIFont.NewSmall, gapAfter = ROW_HEIGHT, color = {0.6, 0.6, 0.6}})
    end
    if fireToday > 0 then
        table.insert(entries, {text = string.format("Fire = %02d Kills", fireToday), font = UIFont.NewSmall, gapAfter = ROW_HEIGHT})
    end
    if vehicleToday > 0 then
        table.insert(entries, {text = string.format("Vehicle = %02d Kills", vehicleToday), font = UIFont.NewSmall, gapAfter = ROW_HEIGHT})
    end

    return entries
end

local function buildXPEntries(player, xpBreakdown, dayNumber)
    local entries = {}

    local title = "XP GAINED"
    if dayNumber then title = title .. "  (Day " .. dayNumber .. ")" end
    table.insert(entries, {text = title, font = UIFont.Small, centered = true, gapAfter = ROW_HEIGHT + 4})

    local total = player and UZIR.Tracker.getTotalXP(player) or 0
    table.insert(entries, {text = string.format("TOTAL XP = %.0f", total), font = UIFont.NewSmall, gapAfter = ROW_HEIGHT + SECTION_GAP})

    table.insert(entries, {text = "Today's XP", font = UIFont.NewSmall, gapAfter = ROW_HEIGHT})
    table.insert(entries, {text = "Type", font = UIFont.NewSmall, gapAfter = ROW_HEIGHT, color = {0.8, 0.8, 0.8}})

    if #xpBreakdown.order == 0 then
        table.insert(entries, {text = "(no XP this day)", font = UIFont.NewSmall, gapAfter = ROW_HEIGHT, color = {0.6, 0.6, 0.6}})
    end

    for _, categoryName in ipairs(xpBreakdown.order) do
        table.insert(entries, {text = categoryName, font = UIFont.NewSmall, gapAfter = ROW_HEIGHT})
        local cat = xpBreakdown.categories[categoryName]
        for _, skill in ipairs(cat.skills) do
            local line = string.format("%s +%.2f XP", skill.name, skill.amount)
            table.insert(entries, {text = line, font = UIFont.NewSmall, indent = 8, gapAfter = ROW_HEIGHT})
        end
    end

    return entries
end

-- Percorre uma lista de entradas medindo (e opcionalmente desenhando).
-- Retorna (alturaTotal, larguraMaxima). Usar doDraw=false so mede, sem
-- tocar a tela - e assim que descobrimos o tamanho necessario do painel
-- ANTES de desenhar qualquer coisa nele.
function UZIR_SleepReport:renderEntries(entries, startX, startY, columnWidth, doDraw)
    local cursorY = startY
    local maxWidth = 0

    for _, e in ipairs(entries) do
        local textWidth = measureWidth(e.text, e.font)
        local totalWidth = e.centered and textWidth or ((e.indent or 0) + textWidth)
        if totalWidth > maxWidth then maxWidth = totalWidth end

        if doDraw then
            local color = e.color or {1, 1, 1}
            if e.centered then
                self:drawTextCentre(e.text, startX + columnWidth / 2, cursorY, color[1], color[2], color[3], 1, e.font)
            else
                self:drawText(e.text, startX + (e.indent or 0), cursorY, color[1], color[2], color[3], 1, e.font)
            end
        end

        cursorY = cursorY + (e.gapAfter or ROW_HEIGHT)
    end

    return cursorY - startY, maxWidth
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

    -- Posicoes iniciais sao provisorias - tudo e reajustado a cada
    -- frame em prerender, conforme o painel muda de tamanho.
    self.prevButton = ISButton:new(BUTTON_MARGIN, 0, 90, BUTTON_HEIGHT, "< Previous Day", self, UZIR_SleepReport.onPrevDay)
    self.prevButton:initialise()
    self.prevButton:instantiate()
    self:addChild(self.prevButton)

    self.nextButton = ISButton:new(BUTTON_MARGIN + 96, 0, 90, BUTTON_HEIGHT, "Next Day >", self, UZIR_SleepReport.onNextDay)
    self.nextButton:initialise()
    self.nextButton:instantiate()
    self:addChild(self.nextButton)

    self.closeButton = ISButton:new(0, 0, 80, BUTTON_HEIGHT, "Close", self, UZIR_SleepReport.onClose)
    self.closeButton:initialise()
    self.closeButton:instantiate()
    self:addChild(self.closeButton)
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

-- ================== Renderizacao ==================

function UZIR_SleepReport:prerender()
    local player = UZIR.Tracker.getPlayer()
    local history = player and UZIR.Tracker.getDailyHistory(player) or {}

    if not self.viewIndex or self.viewIndex > #history then
        self.viewIndex = #history
    end
    if self.viewIndex < 1 then self.viewIndex = 1 end

    local entry = history[self.viewIndex]
    local breakdown = entry and entry.breakdown or {order = {}, categories = {}}
    local dayNumber = entry and entry.dayNumber or nil
    local fireToday = entry and entry.invalidFire or 0
    local vehicleToday = entry and entry.invalidVehicle or 0
    local xpBreakdown = entry and entry.xpBreakdown or {order = {}, categories = {}}

    local validEntries = buildValidEntries(player, breakdown, dayNumber)
    local invalidEntries = buildInvalidEntries(player, fireToday, vehicleToday, dayNumber)
    local xpEntries = buildXPEntries(player, xpBreakdown, dayNumber)

    -- ---- Passo 1: MEDIR (sem desenhar nada ainda) ----
    local validHeight, validWidth = self:renderEntries(validEntries, 0, 0, 999, false)
    local invalidHeight, invalidWidth = self:renderEntries(invalidEntries, 0, 0, 999, false)
    local xpHeight, xpWidth = self:renderEntries(xpEntries, 0, 0, 999, false)

    local columnWidth = math.max(MIN_COLUMN_WIDTH, validWidth, invalidWidth, xpWidth) + 10
    local bodyHeight = math.max(validHeight, invalidHeight, xpHeight)

    local contentX = INNER_INSET + CONTENT_INSET
    local titleRowHeight = ROW_HEIGHT + 6

    local neededWidth = math.max(MIN_PANEL_WIDTH, (contentX * 2) + (columnWidth * 3) + (COLUMN_GAP * 2))
    local neededHeight = (INNER_INSET + CONTENT_INSET) + titleRowHeight + bodyHeight
        + BUTTON_MARGIN + BUTTON_HEIGHT + BUTTON_MARGIN + INNER_INSET

    if self:getWidth() ~= neededWidth then
        self:setWidth(neededWidth)
    end
    if self:getHeight() ~= neededHeight then
        self:setHeight(neededHeight)
    end

    -- Mantem o painel sempre centralizado na tela, mesmo mudando de
    -- tamanho de um dia para o outro.
    local screenW = getCore():getScreenWidth()
    local screenH = getCore():getScreenHeight()
    self:setX((screenW - self:getWidth()) / 2)
    self:setY((screenH - self:getHeight()) / 2)

    ISPanel.prerender(self)

    local w, h = self:getWidth(), self:getHeight()

    -- Moldura de borda dupla.
    self:drawRectBorder(0, 0, w, h, 1, 0.85, 0.85, 0.85)
    self:drawRectBorder(INNER_INSET, INNER_INSET, w - INNER_INSET * 2, h - INNER_INSET * 2, 1, 0.5, 0.5, 0.5)

    local contentY = INNER_INSET + CONTENT_INSET

    self:drawTextCentre("UZIr - Sleep Report", w / 2, contentY, 1, 1, 1, 1, UIFont.Small)
    local bodyY = contentY + titleRowHeight

    self:drawRect(INNER_INSET + 4, bodyY - 4, w - (INNER_INSET + 4) * 2, 1, 0.35, 1, 1, 1)

    -- Posicoes das 3 colunas, com uma linha divisoria vertical no meio
    -- de cada respiro entre elas.
    local col1X = contentX
    local col2X = contentX + columnWidth + COLUMN_GAP
    local col3X = contentX + (columnWidth + COLUMN_GAP) * 2

    self:drawRect(col2X - COLUMN_GAP / 2, bodyY, 1, bodyHeight, 0.35, 1, 1, 1)
    self:drawRect(col3X - COLUMN_GAP / 2, bodyY, 1, bodyHeight, 0.35, 1, 1, 1)

    -- ---- Passo 2: DESENHAR de verdade, usando as mesmas listas medidas ----
    self:renderEntries(validEntries, col1X, bodyY, columnWidth, true)
    self:renderEntries(invalidEntries, col2X, bodyY, columnWidth, true)
    self:renderEntries(xpEntries, col3X, bodyY, columnWidth, true)

    -- Fileira de botoes de navegacao, ancorada no rodape do painel.
    local buttonY = h - BUTTON_MARGIN - BUTTON_HEIGHT
    if self.prevButton then self.prevButton:setY(buttonY) end
    if self.nextButton then self.nextButton:setY(buttonY) end
    if self.closeButton then
        self.closeButton:setY(buttonY)
        self.closeButton:setX(w - BUTTON_MARGIN - 80)
    end

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

    local initialHeight = 200
    local x = (screenW - MIN_PANEL_WIDTH) / 2
    local y = (screenH - initialHeight) / 2

    local panel = UZIR_SleepReport:new(x, y, MIN_PANEL_WIDTH, initialHeight)
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
        UZIR.Export.onSleepTransition(player)
        -- Acabou de dormir: tira o retrato do dia que passou e mostra o painel.
        UZIR.Tracker.snapshotAndResetToday(player)
        local history = UZIR.Tracker.getDailyHistory(player)
        panel.viewIndex = #history
        panel:setVisible(true)
    elseif (not asleep) and wasAsleep then
        -- Acabou de acordar: pausa o jogo, mas mantem o painel aberto ate
        -- o jogador clicar em "Close".
        pauseGame()
    end

    UZIR.sleepReportWasAsleep = asleep
end

Events.OnGameStart.Add(createSleepReport)
Events.OnPlayerUpdate.Add(updateSleepState)
