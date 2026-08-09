-- Este APP e idealizado por oQuasi e Claude desde 20072026 - Nao permitimos a copia. Divirta-se! Todos os Direitos Reservados
--
-- UZIR_HUD.lua
-- Painel PRINCIPAL e UNICO do UZIR. Ele existe sozinho (nao ha varias
-- janelas soltas) e cresce/encolhe para caber os blocos de informacao
-- que estiverem ligados. Cada bloco tem sua propria moldura (retangulo
-- com borda) para ficar visualmente separado dos outros, mas todos
-- vivem dentro deste unico ISPanel.
--
-- PRIORIDADES (a pedido do autor):
--   Prioridade 1 - zKILL (+ fogo/veiculo): SEMPRE visivel, nao pode ser
--                  desligada. Fica logo abaixo do titulo/botao Report.
--   XP  - QMTR (Quadro de Monitoramento em Tempo Real): logo abaixo do
--         zKILL. Mostra "XP  NomeDaPericia Lvl N" no cabecalho (a
--         ULTIMA pericia que ganhou XP) e, embaixo, o PROGRESSO DE
--         NIVEL dela: XP total acumulado nessa pericia, e quanto falta
--         para o proximo nivel (ou "MAX LEVEL" se ja no nivel 10).
--         Flutuantes tipo "Woodwork +12.50 XP" aparecem por cima toda
--         vez que o jogador ganha XP (ganhos da mesma pericia dentro
--         de ~1,5s sao agrupados num so flutuante, para nao poluir a
--         tela).
--   Prioridade 2 - "Hora e Data" (bloco Live: Hours/Days/Week/Month/Year)
--   Prioridade 3 - "Nutricao" (bloco Char Info: peso + tendencia)
--   Prioridade 4 - "Clima/Estacao" (bloco Game Info: estacao + mes)
--
-- XP e as Prioridades 2, 3 e 4 podem ser ligadas/desligadas com o
-- BOTAO DIREITO do mouse em qualquer lugar do painel (abre um menu de
-- contexto). A prioridade 1 (zKILL) nao aparece nesse menu porque e
-- obrigatoria.
--
-- POSICIONAMENTO (IMPORTANTE - historico de seguranca):
-- Ate uma versao anterior, o jogador podia clicar e arrastar o painel
-- inteiro para qualquer lugar da tela. Isso criava uma area GRANDE em
-- cima do jogo que engolia cliques - inclusive cliques de ataque em
-- zumbis, o que e um problema serio em combate. Por isso:
--   - O clique ESQUERDO nao arrasta mais nada; a posicao so muda pelo
--     botaozinho "⇄" (area minuscula, de proposito).
--   - O painel comeca sempre fixo no canto SUPERIOR ESQUERDO da tela
--     (cornerIndex = 1) na primeira vez que roda; depois disso, lembra
--     a escolha do jogador.
--   - O clique DIREITO (menu de ligar/desligar blocos) so e capturado
--     quando o mouse esta sobre o painel, igual qualquer UI do jogo.
--     Como o painel so fica nos 4 cantos (nunca no meio da tela), o
--     risco de atrapalhar uma acao de clique direito no mundo (abrir
--     menu de contexto em cima de algo) e bem menor que o problema
--     original, mas nao e zero - vale ficar de olho.
--
-- REGRA DE ARQUITETURA: este arquivo e so APRESENTACAO. Ele nunca le ou
-- grava em player:getModData() diretamente para DADOS DE JOGO - toda
-- leitura desse tipo passa pelas funcoes publicas de UZIR.Tracker (ver
-- UZIR_Tracker.lua). Preferencias de UI (posicao, blocos ligados/
-- desligados) sao guardadas aqui mesmo, via ModData proprio, por serem
-- config de tela e nao progresso de personagem.

require "ISUI/ISPanel"
require "ISUI/ISButton"
require "ISUI/ISContextMenu"

UZIR_HUD = ISPanel:derive("UZIR_HUD")

local PANEL_WIDTH = 230
local SCREEN_MARGIN = 20 -- distancia das bordas da tela em cada canto

local TITLE_Y = 4
local LEAGUE_Y = 20
local STATUS_Y = 34
local DIVIDER_Y = 52

local REPORT_BUTTON_HEIGHT = 20
local REPORT_BUTTON_GAP = 4      -- espaco entre a divisoria do titulo e o botao Report
local CONTENT_START_Y = DIVIDER_Y + REPORT_BUTTON_GAP + REPORT_BUTTON_HEIGHT + 8

local BLOCK_PADDING = 6          -- respiro interno de cada bloco (moldura)
local BLOCK_GAP = 8              -- espaco entre um bloco e o proximo
local ROW_HEIGHT = 20

local BOTTOM_PADDING = 8

local CORNER_BUTTON_SIZE = 18

local ICON_SIZE = 18
local ICON_X = 6
local TEXT_WITH_ICON_X = ICON_X + ICON_SIZE + 4

local BLOCK_BORDER_COLOR = {r = 1, g = 1, b = 1, a = 0.15}

-- ================== "+1" flutuante ao matar zumbi ==================

local FLOATER_DURATION_MS = 900
local FLOATER_RISE_PX = 16
local FLOATER_X = ICON_X + 4

-- Flutuantes de XP (QMTR - Quadro de Monitoramento em Tempo Real):
-- ganhos da MESMA pericia que chegam dentro dessa janela sao somados
-- num so flutuante, em vez de um flutuante por micro-ganho (o jogo da
-- XP em quantidades pequenas e frequentes, ex: +0.25 por golpe - sem
-- agrupar, viraria uma poluicao ilegivel de numeros na tela).
local XP_AGGREGATION_WINDOW_MS = 1500
local XP_FLOATER_DURATION_MS = 900
local XP_FLOATER_RISE_PX = 16

-- ================== Icones (infectado / fogo / veiculo / peso) ==================

local iconCache = {}

local function loadIcon(baseName)
    if iconCache[baseName] ~= nil then return iconCache[baseName] end

    local candidates = {
        "media/textures/" .. baseName .. ".png",
        "media/textures/" .. baseName,
        baseName .. ".png",
        baseName,
    }

    for _, path in ipairs(candidates) do
        local ok, tex = pcall(function() return getTexture(path) end)
        if ok and tex then
            iconCache[baseName] = tex
            return tex
        end
    end

    iconCache[baseName] = false -- marca como "ja tentou e nao achou"
    return false
end

local function drawIcon(self, baseName, x, y, size)
    size = size or ICON_SIZE
    local tex = loadIcon(baseName)
    if not tex then return false end
    local ok = pcall(function()
        self:drawTextureScaled(tex, x, y, size, size, 1, 1, 1, 1)
    end)
    return ok
end

-- ================== Blocos ligar/desligar (clique direito) ==================
-- Prioridade 1 (zKILL) nunca aparece aqui - e obrigatoria. Preferencia
-- de UI, guardada separada dos dados de jogo (ver nota de arquitetura
-- no topo do arquivo).

local TOGGLABLE_BLOCKS = {
    {key = "xp", label = "XP"},
    {key = "live", label = "Alive"},
    {key = "charinfo", label = "Nutrition"},
    {key = "gameinfo", label = "Weather/Season"},
}

local function getBlockPrefsData()
    return ModData.getOrCreate("UZIR_HUD_Blocks")
end

-- Por padrao (chave ainda nao definida), o bloco fica visivel.
local function isBlockVisible(key)
    local data = getBlockPrefsData()
    if data[key] == nil then return true end
    return data[key]
end

local function toggleBlock(key)
    local data = getBlockPrefsData()
    data[key] = not isBlockVisible(key)
end

-- ================== Idioma (Portugues/Ingles) ==================
-- Preferencia de UI (igual blocos ligados/desligados) - NAO e dado de
-- jogo, entao guardamos aqui mesmo, via ModData proprio.
-- Padrao: Ingles (a pedido do autor).

local LANGUAGE_OPTIONS = {
    {key = "en", label = "English"},
    {key = "pt", label = "Portugues"},
}

local function getLanguageData()
    return ModData.getOrCreate("UZIR_HUD_Language")
end

local function getCurrentLanguage()
    local data = getLanguageData()
    return data.current or "en"
end

local function setLanguage(key)
    local data = getLanguageData()
    data.current = key
end

-- ================== Modo de exibicao (Solo/Live) ==================
-- Preferencia de UI (igual idioma e blocos ligados/desligados) - guardada
-- em ModData proprio. Padrao: Solo Mode (comportamento atual, sem
-- mudancas). Live Mode deixa o fundo do HUD transparente e aplica um
-- gradiente de cor animado no texto neutro (branco/cinza) - pensado pra
-- quem esta transmitindo a partida ao vivo. Elementos que ja tem cor
-- propria com significado (status de peso, MAX LEVEL, floaters de
-- kill/XP) NAO entram no gradiente, ficam do jeito que sempre foram.
local DISPLAY_MODE_OPTIONS = {
    {key = "solo", label = "Solo Mode"},
    {key = "live", label = "Live Mode"},
}

local function getDisplayModeData()
    return ModData.getOrCreate("UZIR_HUD_DisplayMode")
end

local function getDisplayMode()
    local data = getDisplayModeData()
    return data.current or "solo"
end

-- Estado do gradiente animado do Live Mode. currentT vai de 0 (branco)
-- a 1 (preto), passando por 0.5 (verde). A cada disparo, anima da
-- posicao atual ate uma nova posicao aleatoria em GRADIENT_TRANSITION_MS,
-- depois fica parado ate o proximo disparo (intervalo aleatorio entre
-- GRADIENT_MIN_GAP_MS e GRADIENT_MAX_GAP_MS).
local GRADIENT_TRANSITION_MS = 6000
local GRADIENT_MIN_GAP_MS = 30 * 1000
local GRADIENT_MAX_GAP_MS = 20 * 60 * 1000

local liveGradientState = {
    currentT = 0,
    fromT = 0,
    toT = 0,
    transitionStart = nil,
    nextTriggerAt = nil,
}

local function setDisplayMode(key)
    local data = getDisplayModeData()
    local wasLive = data.current == "live"
    data.current = key

    -- A pedido do autor: a primeira transicao de cor do Live Mode
    -- acontece assim que o modo e ativado, sem esperar o intervalo
    -- aleatorio normal.
    if key == "live" and not wasLive then
        liveGradientState.nextTriggerAt = UZIR.Util.nowMs()
    end
end

-- ================== Textos traduzidos (Portugues/Ingles) ==================
-- Cada chave do bloco corrente e' o TEXTO DE VERDADE mostrado na tela.
-- Season/Weight guardam so o IDENTIFICADOR interno em ingles no
-- UZIR_Tracker.lua (ver comentario la) - a traducao pra exibicao
-- acontece so aqui, na camada de apresentacao, sem mexer no Tracker.
local STRINGS = {
    en = {
        dateTime = "Alive",
        daysAliveFmt = "%d Days",
        nutrition = "Nutrition",
        weatherSeason = "Weather/Season",
        report = "Report",
        league = "League - ",
        valid = "Valid - v",
        invalid = "inValid - v",
        xpHeaderFmt = "XP  %s Lvl %d",
        xpOnly = "XP",
        noXPYet = "(no XP yet)",
        maxLevel = "MAX LEVEL",
        toLvlFmt = "-%.2f to Lvl %d",
        durationFmt = "%s Duration Month %d to Month %d",
        monthLabelFmt = "%s-Month %d",
        weightHigh = "High Weight",
        weightRegular = "Regular",
        weightLow = "Under Weight",
        seasonWinter = "Winter",
        seasonSpring = "Spring",
        seasonSummer = "Summer",
        seasonAutumn = "Autumn",
        langLabel = "Language",
        modeLabel = "Display Mode",
    },
    pt = {
        dateTime = "Vivo",
        daysAliveFmt = "%d Dias",
        nutrition = "Nutricao",
        weatherSeason = "Clima/Estacao",
        report = "Relatorio",
        league = "Liga - ",
        valid = "Valido - v",
        invalid = "Invalido - v",
        xpHeaderFmt = "XP  %s Niv %d",
        xpOnly = "XP",
        noXPYet = "(sem XP ainda)",
        maxLevel = "NIVEL MAXIMO",
        toLvlFmt = "-%.2f para o Niv %d",
        durationFmt = "Duracao de %s: Mes %d ate Mes %d",
        monthLabelFmt = "%s-Mes %d",
        weightHigh = "Peso Alto",
        weightRegular = "Regular",
        weightLow = "Peso Baixo",
        seasonWinter = "Inverno",
        seasonSpring = "Primavera",
        seasonSummer = "Verao",
        seasonAutumn = "Outono",
        langLabel = "Idioma",
        modeLabel = "Modo de Exibicao",
    },
}

-- L() sempre devolve a tabela de textos do idioma ATUAL - chame de novo
-- toda vez que precisar (nunca guarde o resultado, ele pode mudar a
-- qualquer momento se o jogador trocar de idioma no menu).
local function L()
    return STRINGS[getCurrentLanguage()]
end

local SEASON_TRANSLATE_KEY = {
    Winter = "seasonWinter",
    Spring = "seasonSpring",
    Summer = "seasonSummer",
    Autumn = "seasonAutumn",
}

-- Traduz o NOME da estacao para exibicao - o identificador interno que
-- vem do Tracker continua sempre em ingles (usado so como chave
-- tecnica, nunca mostrado direto na tela sem passar por aqui).
local function translateSeason(seasonEn)
    local key = SEASON_TRANSLATE_KEY[seasonEn]
    return key and L()[key] or seasonEn
end

local WEIGHT_TRANSLATE_KEY = {
    ["High Weight"] = "weightHigh",
    ["Regular"] = "weightRegular",
    ["Under Weight"] = "weightLow",
}

-- Traduz o texto de status de peso que vem do Tracker (sempre em
-- ingles) para o idioma atual, sem precisar mexer no Tracker.
local function translateWeightStatus(textEn)
    local key = WEIGHT_TRANSLATE_KEY[textEn]
    return key and L()[key] or textEn
end

local BLOCK_LABEL_KEYS = {
    xp = "xpOnly",
    live = "dateTime",
    charinfo = "nutrition",
    gameinfo = "weatherSeason",
}

-- ================== Posicao (canto da tela) ==================
-- Guardamos so um indice de canto (1 a 4), nunca mais um x/y livre em
-- pixels. A posicao real e recalculada a cada frame a partir do canto
-- escolhido e do tamanho atual da tela/painel - assim funciona certo
-- mesmo se a resolucao mudar entre sessoes. O padrao (sem preferencia
-- salva ainda) e SEMPRE canto 1 (superior esquerdo), a pedido do autor.

local CORNERS = {
    "Superior esquerdo",
    "Superior direito",
    "Inferior esquerdo",
    "Inferior direito",
}

local function getPositionData()
    return ModData.getOrCreate("UZIR_HUD_Position")
end

local function loadCornerIndex()
    local data = getPositionData()
    return data.corner or 1
end

local function saveCornerIndex(index)
    local data = getPositionData()
    data.corner = index
end

-- Calcula o x/y real na tela para o canto atual, dado o tamanho do
-- painel neste frame (que muda conforme os blocos ligam/desligam).
local function computeCornerPosition(cornerIndex, panelWidth, panelHeight)
    local screenW = getCore():getScreenWidth()
    local screenH = getCore():getScreenHeight()

    local left = SCREEN_MARGIN
    local right = screenW - panelWidth - SCREEN_MARGIN
    local top = SCREEN_MARGIN
    local bottom = screenH - panelHeight - SCREEN_MARGIN

    if cornerIndex == 2 then return right, top end
    if cornerIndex == 3 then return left, bottom end
    if cornerIndex == 4 then return right, bottom end
    return left, top -- 1: superior esquerdo (padrao)
end

-- ================== Construcao do painel ==================

function UZIR_HUD:new(x, y, width, height)
    local o = ISPanel:new(x, y, width, height)
    setmetatable(o, self)
    self.__index = self

    o.backgroundColor = {r = 0, g = 0, b = 0, a = 0.35}
    o.borderColor = {r = 1, g = 1, b = 1, a = 0.25}

    o.cornerIndex = loadCornerIndex()
    o.floaters = {}
    o.xpFloaters = {}
    o.lastKillCount = nil

    return o
end

function UZIR_HUD:initialise()
    ISPanel.initialise(self)
end

function UZIR_HUD:createChildren()
    ISPanel.createChildren(self)

    -- Botao pequeno para alternar entre os 4 cantos da tela. E uma das
    -- duas UNICAS areas clicaveis deste painel (a outra e o botao
    -- Report) - de proposito pequena, para nunca atrapalhar cliques de
    -- combate no resto da tela.
    self.cornerButton = ISButton:new(
        self:getWidth() - CORNER_BUTTON_SIZE - 4, 3,
        CORNER_BUTTON_SIZE, CORNER_BUTTON_SIZE,
        "\226\135\132", self, UZIR_HUD.onCycleCorner) -- "⇄"
    self.cornerButton:initialise()
    self.cornerButton:instantiate()
    self:addChild(self.cornerButton)

    -- Botao para abrir o Sleep Report a qualquer momento, sem precisar
    -- dormir. Fica logo abaixo do titulo/divisoria. Largura ajustada a
    -- cada frame em prerender, pois o painel pode mudar de tamanho.
    self.reportButton = ISButton:new(6, DIVIDER_Y + REPORT_BUTTON_GAP, self:getWidth() - 12, REPORT_BUTTON_HEIGHT, "Report", self, UZIR_HUD.onOpenReport)
    self.reportButton:initialise()
    self.reportButton:instantiate()
    self:addChild(self.reportButton)
end

-- Alterna para o proximo canto da tela (1 -> 2 -> 3 -> 4 -> 1 ...) e
-- salva a escolha. Chamado so pelo clique no botaozinho "⇄".
function UZIR_HUD:onCycleCorner()
    self.cornerIndex = (self.cornerIndex % #CORNERS) + 1
    saveCornerIndex(self.cornerIndex)
end

-- Abre o painel do relatorio mostrando o dia mais recente do historico,
-- sem tirar um snapshot novo (snapshot so acontece de verdade quando o
-- personagem dorme - ver UZIR_SleepReport.lua). Se ainda nao existe
-- nenhum dia no historico, o proprio relatorio ja sabe mostrar o estado
-- vazio normalmente.
function UZIR_HUD:onOpenReport()
    local report = UZIR.sleepReportInstance
    if not report then return end

    local player = UZIR.Tracker.getPlayer()
    local history = player and UZIR.Tracker.getDailyHistory(player) or {}

    report.viewIndex = #history
    report:setVisible(true)
    report:bringToTop()
end

-- ================== Clique direito: ligar/desligar blocos ==================

function UZIR_HUD:onToggleBlockClick(key)
    toggleBlock(key)
end

function UZIR_HUD:onSelectLanguage(key)
    setLanguage(key)
end

function UZIR_HUD:onSelectDisplayMode(key)
    setDisplayMode(key)
end

function UZIR_HUD:onRightMouseDown(x, y)
    local player = UZIR.Tracker.getPlayer()
    local playerNum = 0
    local okNum, pn = pcall(function() return player:getPlayerNum() end)
    if okNum and pn then playerNum = pn end

    local absX = self:getX() + x
    local absY = self:getY() + y

    local okMenu, context = pcall(function() return ISContextMenu.get(playerNum, absX, absY) end)
    if not (okMenu and context) then return true end

    for _, block in ipairs(TOGGLABLE_BLOCKS) do
        local visible = isBlockVisible(block.key)
        local prefix = visible and "[X] " or "[ ] "
        local label = L()[BLOCK_LABEL_KEYS[block.key]] or block.label
        context:addOption(prefix .. label, self, UZIR_HUD.onToggleBlockClick, block.key)
    end

    -- ---- Separador + selecao de idioma ----
    -- NOTA HONESTA: nao confirmamos ainda, testando dentro do jogo, se
    -- o ISContextMenu do PZ tem um separador nativo documentado nem se
    -- "notAvailable" e mesmo a propriedade certa para deixar uma opcao
    -- so-texto (nao clicavel). Isso e a aposta mais segura com o que
    -- ja sabemos do resto do menu - se aparecer errado/clicavel, e o
    -- primeiro lugar pra ajustar depois de testar no jogo.
    local divider = context:addOption("——————————", nil, nil)
    if divider then divider.notAvailable = true end

    local langLabel = context:addOption(L().langLabel, nil, nil)
    if langLabel then langLabel.notAvailable = true end

    local currentLang = getCurrentLanguage()
    for _, lang in ipairs(LANGUAGE_OPTIONS) do
        local prefix = (currentLang == lang.key) and "[X] " or "[ ] "
        context:addOption(prefix .. lang.label, self, UZIR_HUD.onSelectLanguage, lang.key)
    end

    -- ---- Separador + selecao de modo (Solo/Live) ----
    -- Mesma logica/nota honesta do separador de idioma acima.
    local divider2 = context:addOption("——————————", nil, nil)
    if divider2 then divider2.notAvailable = true end

    local modeLabel = context:addOption(L().modeLabel, nil, nil)
    if modeLabel then modeLabel.notAvailable = true end

    local currentMode = getDisplayMode()
    for _, mode in ipairs(DISPLAY_MODE_OPTIONS) do
        local prefix = (currentMode == mode.key) and "[X] " or "[ ] "
        context:addOption(prefix .. mode.label, self, UZIR_HUD.onSelectDisplayMode, mode.key)
    end

    return true
end

-- ================== Logica do "+1" flutuante ==================

function UZIR_HUD:checkForNewKills(currentKills)
    if self.lastKillCount == nil then
        self.lastKillCount = currentKills
        return
    end

    if currentKills > self.lastKillCount then
        local delta = currentKills - self.lastKillCount
        table.insert(self.floaters, {
            text = "+" .. delta,
            startTime = UZIR.Util.nowMs(),
        })
    end

    self.lastKillCount = currentKills
end

function UZIR_HUD:drawFloaters(originY)
    local now = UZIR.Util.nowMs()
    for i = #self.floaters, 1, -1 do
        local f = self.floaters[i]
        local elapsed = now - f.startTime
        if elapsed >= FLOATER_DURATION_MS then
            table.remove(self.floaters, i)
        else
            local t = elapsed / FLOATER_DURATION_MS
            local alpha = 1 - t
            local y = (originY - 2) - (FLOATER_RISE_PX * t)
            self:drawText(f.text, FLOATER_X, y, 0, 1, 0, alpha, UIFont.Large)
        end
    end
end

-- ================== Flutuantes de XP (agrupados por pericia) ==================
-- Cada flutuante tem duas fases:
--   1. "Acumulando" (displayStartTime == nil): novos eventos da MESMA
--      pericia continuam sendo somados aqui, e o relogio de inatividade
--      reseta a cada novo evento.
--   2. "Em exibicao" (displayStartTime definido): parou de receber
--      eventos novos por XP_AGGREGATION_WINDOW_MS, entao comeca a subir
--      e sumir, igual o flutuante de kill.
function UZIR_HUD:updateXPFloaters()
    local now = UZIR.Util.nowMs()
    local events = UZIR.Tracker.drainXPEvents()

    for _, evt in ipairs(events) do
        local target = nil
        for _, f in ipairs(self.xpFloaters) do
            if f.skillName == evt.skillName and f.displayStartTime == nil then
                target = f
                break
            end
        end
        if target then
            target.amount = target.amount + evt.amount
            target.lastEventTime = now
        else
            table.insert(self.xpFloaters, {
                skillName = evt.skillName,
                amount = evt.amount,
                lastEventTime = now,
                displayStartTime = nil,
            })
        end
    end

    for i = #self.xpFloaters, 1, -1 do
        local f = self.xpFloaters[i]
        if f.displayStartTime == nil then
            if (now - f.lastEventTime) >= XP_AGGREGATION_WINDOW_MS then
                f.displayStartTime = now
            end
        else
            if (now - f.displayStartTime) >= XP_FLOATER_DURATION_MS then
                table.remove(self.xpFloaters, i)
            end
        end
    end
end

function UZIR_HUD:drawXPFloaters(originY)
    local now = UZIR.Util.nowMs()
    local stackIndex = 0

    for _, f in ipairs(self.xpFloaters) do
        if f.displayStartTime ~= nil then
            local elapsed = now - f.displayStartTime
            local t = elapsed / XP_FLOATER_DURATION_MS
            local alpha = 1 - t
            local text = string.format("%s +%.2f XP", f.skillName, f.amount)
            local y = (originY - 2) - (XP_FLOATER_RISE_PX * t) - (stackIndex * 14)
            self:drawText(text, 10, y, 0, 1, 0, alpha, UIFont.Large)
            stackIndex = stackIndex + 1
        end
    end
end

-- ================== Hover (sem capturar clique) ==================
-- So usado para decidir se mostramos linhas extras (status do peso,
-- duracao da estacao). getMouseX()/getMouseY() aqui sao metodos de
-- instancia (posicao do mouse RELATIVA a este painel), nao globais -
-- por isso funcionam so olhando, sem interceptar clique nenhum.
local function isMouseHovering(self)
    local ok, mx = pcall(function() return self:getMouseX() end)
    local ok2, my = pcall(function() return self:getMouseY() end)
    if not (ok and ok2) then return false end

    return mx >= 0 and mx <= self:getWidth() and my >= 0 and my <= self:getHeight()
end

-- ================== Moldura de cada bloco ==================
-- Desenha um retangulo com borda sutil ao redor da area do bloco, para
-- separar visualmente as "prioridades" dentro do painel unico.
-- No Live Mode o fundo inteiro fica transparente (so o texto aparece),
-- entao a borda tambem e pulada.
local function drawBlockFrame(self, y, height)
    if getDisplayMode() == "live" then return end
    self:drawRectBorder(4, y, self:getWidth() - 8, height, BLOCK_BORDER_COLOR.a, BLOCK_BORDER_COLOR.r, BLOCK_BORDER_COLOR.g, BLOCK_BORDER_COLOR.b)
end

-- Cor no gradiente branco -> verde -> preto na posicao t (0 a 1).
-- t <= 0.5: interpola branco(1,1,1) ate verde(0,1,0)
-- t  > 0.5: interpola verde(0,1,0) ate preto(0,0,0)
local function gradientColorAt(t)
    if t <= 0.5 then
        local k = t / 0.5
        return 1 - k, 1, 1 - k
    else
        local k = (t - 0.5) / 0.5
        return 0, 1 - k, 0
    end
end

-- Avanca o "relogio" do gradiente do Live Mode e devolve o RGB atual.
-- Ver comentario acima de liveGradientState para o funcionamento.
local function getLiveGradientRGB()
    local now = UZIR.Util.nowMs()
    local s = liveGradientState

    if not s.nextTriggerAt then
        s.nextTriggerAt = now + math.random(GRADIENT_MIN_GAP_MS, GRADIENT_MAX_GAP_MS)
    end

    if not s.transitionStart and now >= s.nextTriggerAt then
        s.fromT = s.currentT
        s.toT = math.random(0, 10000) / 10000
        s.transitionStart = now
    end

    if s.transitionStart then
        local elapsed = now - s.transitionStart
        if elapsed >= GRADIENT_TRANSITION_MS then
            s.currentT = s.toT
            s.transitionStart = nil
            s.nextTriggerAt = now + math.random(GRADIENT_MIN_GAP_MS, GRADIENT_MAX_GAP_MS)
        else
            local p = elapsed / GRADIENT_TRANSITION_MS
            s.currentT = s.fromT + (s.toT - s.fromT) * p
        end
    end

    return gradientColorAt(s.currentT)
end

-- Wrapper central usado pelos textos "neutros" do HUD (labels em cinza e
-- valores em branco). No Solo Mode desenha com a cor original, sem
-- nenhuma mudanca. No Live Mode ignora r/g/b recebidos e usa a cor atual
-- do gradiente. NAO usar em textos que ja tem cor propria com
-- significado (status de peso, MAX LEVEL, floaters de kill/XP) - esses
-- continuam chamando self:drawText diretamente.
function UZIR_HUD:drawColorText(text, x, y, r, g, b, a, font)
    if getDisplayMode() == "live" then
        r, g, b = getLiveGradientRGB()
    end
    self:drawText(text, x, y, r, g, b, a, font)
end

-- ================== Renderizacao ==================

function UZIR_HUD:prerender()
    local player = UZIR.Tracker.getPlayer()

    local liveLines = player
        and {UZIR.Tracker.getAliveClockLine(player), string.format(L().daysAliveFmt, UZIR.Tracker.getDaysAlive(player))}
        or {"00:00:00"}
    local fireKills = player and UZIR.Tracker.getFireKills(player) or 0
    local vehicleKills = player and UZIR.Tracker.getVehicleKills(player) or 0
    local hovering = isMouseHovering(self)

    local showXP = isBlockVisible("xp")
    local showLive = isBlockVisible("live")
    local showCharInfo = isBlockVisible("charinfo")
    local showGameInfo = isBlockVisible("gameinfo")

    self:updateXPFloaters()

    -- ---- Altura de cada bloco (0 se estiver desligado) ----

    local block1Rows = 1 -- zKILL
    if fireKills > 0 then block1Rows = block1Rows + 1 end
    if vehicleKills > 0 then block1Rows = block1Rows + 1 end
    local block1Height = BLOCK_PADDING * 2 + block1Rows * ROW_HEIGHT

    -- Bloco de XP: cabecalho + linha de "XP atual do nivel" + linha de
    -- "quanto falta pro proximo nivel" (ou "MAX LEVEL" se ja no 10).
    -- Os flutuantes de XP sobem POR CIMA do conteudo, nao alteram a
    -- altura do bloco - mesmo esquema ja usado no flutuante de "+1" do zKILL.
    local blockXPHeight = 0
    if showXP then
        blockXPHeight = BLOCK_PADDING * 2 + ROW_HEIGHT + ROW_HEIGHT + ROW_HEIGHT
    end

    local block2Height = 0
    if showLive then
        block2Height = BLOCK_PADDING * 2 + ROW_HEIGHT + (#liveLines * ROW_HEIGHT)
    end

    local block3Height = 0
    if showCharInfo then
        block3Height = BLOCK_PADDING * 2 + ROW_HEIGHT + ROW_HEIGHT + (hovering and ROW_HEIGHT or 0)
    end

    local block4Height = 0
    if showGameInfo then
        block4Height = BLOCK_PADDING * 2 + ROW_HEIGHT + ROW_HEIGHT + (hovering and ROW_HEIGHT or 0)
    end

    local neededHeight = CONTENT_START_Y + block1Height + BLOCK_GAP
    if showXP then neededHeight = neededHeight + blockXPHeight + BLOCK_GAP end
    if showLive then neededHeight = neededHeight + block2Height + BLOCK_GAP end
    if showCharInfo then neededHeight = neededHeight + block3Height + BLOCK_GAP end
    if showGameInfo then neededHeight = neededHeight + block4Height + BLOCK_GAP end
    neededHeight = neededHeight + BOTTOM_PADDING

    -- ---- Largura dinamica ----
    -- O painel tinha largura FIXA (230px), mas linhas como a duracao da
    -- estacao ("Summer Duration Month 6 to Month 8") sao mais largas que
    -- isso e vazavam para fora da borda. Medimos o texto mais largo que
    -- vai aparecer ESTE frame (considerando blocos ligados/desligados e
    -- hover) e crescemos o painel para caber, com uma folga de seguranca.
    local function measureWidth(text, font)
        local ok, w = pcall(function() return getTextManager():MeasureStringX(font, text) end)
        if ok and w then return w end
        return #text * 8 -- estimativa grosseira caso a medicao falhe
    end

    local widestText = 0
    local function considerWidth(text, font)
        local w = measureWidth(text, font)
        if w > widestText then widestText = w end
    end

    do
        local leagueName, isValid = UZIR.Tracker.getLeagueInfo()
        local gameVersion = UZIR.Tracker.getGameVersion()
        considerWidth(L().league .. leagueName, UIFont.Small)
        local statusPrefix = isValid and L().valid or L().invalid
        considerWidth(statusPrefix .. gameVersion, UIFont.Small)
    end

    considerWidth(UZIR.Tracker.getKillCountLine(player), UIFont.Medium)
    if fireKills > 0 then considerWidth(string.format("%04d", fireKills), UIFont.Medium) end
    if vehicleKills > 0 then considerWidth(string.format("%04d", vehicleKills), UIFont.Medium) end

    if showXP then
        local lastSkill = UZIR.Tracker.getLastTrainedSkill(player)
        if lastSkill then
            local level, currentXP, nextLevelXP, remainingXP = UZIR.Tracker.getSkillLevelProgress(player, lastSkill)
            considerWidth(string.format(L().xpHeaderFmt, lastSkill, level), UIFont.Small)
            considerWidth(string.format("%.2f XP", currentXP), UIFont.Medium)
            if remainingXP then
                considerWidth(string.format(L().toLvlFmt, remainingXP, level + 1), UIFont.Small)
            else
                considerWidth(L().maxLevel, UIFont.Small)
            end
        else
            considerWidth("XP", UIFont.Small)
        end
        for _, f in ipairs(self.xpFloaters) do
            considerWidth(string.format("%s +%.2f XP", f.skillName, f.amount), UIFont.Small)
        end
    end

    if showLive then
        for _, line in ipairs(liveLines) do considerWidth(line, UIFont.Medium) end
    end

    if showCharInfo then
        considerWidth(UZIR.Tracker.getWeightLine(player), UIFont.Medium)
        if hovering then
            considerWidth(translateWeightStatus(UZIR.Tracker.getWeightStatus(player).text), UIFont.Small)
        end
    end

    if showGameInfo then
        local season, currentMonth, startMonth, endMonth = UZIR.Tracker.getSeasonInfo()
        considerWidth(string.format(L().monthLabelFmt, translateSeason(season), currentMonth), UIFont.Medium)
        if hovering then
            considerWidth(string.format(L().durationFmt, translateSeason(season), startMonth, endMonth), UIFont.Small)
        end
    end

    local SIDE_MARGIN_ALLOWANCE = 50 -- cobre margem esquerda + icone + margem direita com folga
    local neededWidth = math.max(PANEL_WIDTH, widestText + SIDE_MARGIN_ALLOWANCE)

    if self:getWidth() ~= neededWidth then
        self:setWidth(neededWidth)
    end

    if self:getHeight() ~= neededHeight then
        self:setHeight(neededHeight)
    end

    -- Reposiciona o painel de acordo com o canto escolhido, recalculando
    -- a cada frame (a altura muda, entao o canto inferior precisa ser
    -- recalculado sempre que o painel cresce/diminui).
    local x, y = computeCornerPosition(self.cornerIndex, self:getWidth(), neededHeight)
    self:setX(x)
    self:setY(y)

    if self.cornerButton then
        self.cornerButton:setX(self:getWidth() - CORNER_BUTTON_SIZE - 4)
    end
    if self.reportButton then
        self.reportButton:setWidth(self:getWidth() - 12)
        -- NOTA HONESTA: nao confirmamos se ISButton tem setTitle() nessa
        -- versao do jogo - protegido com pcall para nunca quebrar o HUD
        -- caso o metodo nao exista ou tenha outro nome.
        pcall(function() self.reportButton:setTitle(L().report) end)
    end

    -- Fundo/borda nativos do ISPanel: no Live Mode zeramos o alpha pra
    -- ficarem invisiveis, sem perder os valores originais do Solo Mode.
    if getDisplayMode() == "live" then
        self.backgroundColor.a = 0
        self.borderColor.a = 0
    else
        self.backgroundColor.a = 0.35
        self.borderColor.a = 0.25
    end

    ISPanel.prerender(self)

    -- Faixa mais escura atras do titulo, com linha divisoria sutil.
    -- No Live Mode ambos ficam pulados, deixando so o texto visivel.
    if getDisplayMode() ~= "live" then
        self:drawRect(0, 0, self:getWidth(), DIVIDER_Y, 0.25, 0, 0, 0)
        self:drawRect(0, DIVIDER_Y - 1, self:getWidth(), 1, 0.35, 1, 1, 1)
    end

    self:drawTextCentre("UZI", self:getWidth() / 2, TITLE_Y, 1, 1, 1, 1, UIFont.Medium)

    -- League (game mode) + Valid/inValid: compares the current world
    -- against the game's official presets (see
    -- UZIR_Tracker.getLeagueInfo). The result is cached in the
    -- Tracker, so reading this every frame is cheap (the comparison
    -- itself doesn't run every frame).
    local leagueName, isValid = UZIR.Tracker.getLeagueInfo()
    local gameVersion = UZIR.Tracker.getGameVersion()
    self:drawTextCentre(L().league .. leagueName, self:getWidth() / 2, LEAGUE_Y, 0.7, 0.7, 0.7, 1, UIFont.Small)
    if isValid then
        self:drawTextCentre(L().valid .. gameVersion, self:getWidth() / 2, STATUS_Y, 0.2, 1, 0.2, 1, UIFont.Small)
    else
        self:drawTextCentre(L().invalid .. gameVersion, self:getWidth() / 2, STATUS_Y, 1, 0.2, 0.2, 1, UIFont.Small)
    end

    if not player then return end

    local cursorY = CONTENT_START_Y

    -- ================== Prioridade 1: zKILL (obrigatoria) ==================
    drawBlockFrame(self, cursorY, block1Height)
    local innerY = cursorY + BLOCK_PADDING

    local currentKills = UZIR.Tracker.getKillCount(player)
    self:checkForNewKills(currentKills)

    local killLine = UZIR.Tracker.getKillCountLine(player)
    local killTextX = TEXT_WITH_ICON_X
    if not drawIcon(self, "UZIR_Infected", ICON_X, innerY - 2) then
        killTextX = 6
    end
    self:drawColorText(killLine, killTextX, innerY, 1, 1, 1, 1, UIFont.Medium)
    self:drawFloaters(innerY)
    innerY = innerY + ROW_HEIGHT

    if fireKills > 0 then
        local textX = TEXT_WITH_ICON_X
        if not drawIcon(self, "UZIR_Fire", ICON_X, innerY - 2) then
            textX = 6
        end
        self:drawColorText(string.format("%04d", fireKills), textX, innerY, 1, 1, 1, 1, UIFont.Medium)
        innerY = innerY + ROW_HEIGHT
    end

    if vehicleKills > 0 then
        local textX = TEXT_WITH_ICON_X
        if not drawIcon(self, "UZIR_Vehicle", ICON_X, innerY - 2) then
            textX = 6
        end
        self:drawColorText(string.format("%04d", vehicleKills), textX, innerY, 1, 1, 1, 1, UIFont.Medium)
        innerY = innerY + ROW_HEIGHT
    end

    cursorY = cursorY + block1Height + BLOCK_GAP

    -- ================== Prioridade 2: Alive / Vivo (logo abaixo do zKILL) ==================
    if showLive then
        drawBlockFrame(self, cursorY, block2Height)
        innerY = cursorY + BLOCK_PADDING

        self:drawColorText(L().dateTime, 10, innerY, 0.65, 0.65, 0.65, 1, UIFont.Small)
        innerY = innerY + ROW_HEIGHT

        for _, line in ipairs(liveLines) do
            self:drawColorText(line, 10, innerY, 1, 1, 1, 1, UIFont.Medium)
            innerY = innerY + ROW_HEIGHT
        end

        cursorY = cursorY + block2Height + BLOCK_GAP
    end

    -- ================== Bloco QMTR: XP ==================
    if showXP then
        drawBlockFrame(self, cursorY, blockXPHeight)
        innerY = cursorY + BLOCK_PADDING

        local lastSkill = UZIR.Tracker.getLastTrainedSkill(player)

        if lastSkill then
            local level, currentXP, nextLevelXP, remainingXP = UZIR.Tracker.getSkillLevelProgress(player, lastSkill)

            -- Cabecalho "XP" + nome da ultima pericia treinada + nivel atual.
            local headerText = string.format(L().xpHeaderFmt, lastSkill, level)
            self:drawColorText(headerText, 10, innerY, 0.65, 0.65, 0.65, 1, UIFont.Small)
            innerY = innerY + ROW_HEIGHT

            -- XP total acumulado nessa pericia (a vida toda do personagem).
            self:drawColorText(string.format("%.2f XP", currentXP), 10, innerY, 1, 1, 1, 1, UIFont.Medium)
            self:drawXPFloaters(innerY)
            innerY = innerY + ROW_HEIGHT

            -- Quanto falta pro proximo nivel, ou o texto de nivel maximo se ja no 10.
            if remainingXP then
                self:drawColorText(string.format(L().toLvlFmt, remainingXP, level + 1), 10, innerY, 0.8, 0.8, 0.8, 1, UIFont.Small)
            else
                self:drawText(L().maxLevel, 10, innerY, 0.2, 1, 0.2, 1, UIFont.Small)
            end
            innerY = innerY + ROW_HEIGHT
        else
            -- Nenhuma pericia ganhou XP ainda nesta partida.
            self:drawColorText(L().xpOnly, 10, innerY, 0.65, 0.65, 0.65, 1, UIFont.Small)
            innerY = innerY + ROW_HEIGHT
            self:drawColorText(L().noXPYet, 10, innerY, 0.6, 0.6, 0.6, 1, UIFont.NewSmall)
            self:drawXPFloaters(innerY)
            innerY = innerY + (ROW_HEIGHT * 2)
        end

        cursorY = cursorY + blockXPHeight + BLOCK_GAP
    end

    -- ================== Prioridade 3: Nutricao ==================
    if showCharInfo then
        drawBlockFrame(self, cursorY, block3Height)
        innerY = cursorY + BLOCK_PADDING

        self:drawColorText(L().nutrition, 10, innerY, 0.65, 0.65, 0.65, 1, UIFont.Small)
        innerY = innerY + ROW_HEIGHT

        local weightLine = UZIR.Tracker.getWeightLine(player)
        self:drawColorText(weightLine, 10, innerY, 1, 1, 1, 1, UIFont.Medium)

        local indicator = UZIR.Tracker.getWeightIndicator(player)
        local okWidth, textWidth = pcall(function()
            return getTextManager():MeasureStringX(UIFont.Medium, weightLine)
        end)
        local indicatorX = 10 + (okWidth and textWidth or 90) + 6
        local WEIGHT_ICON_SIZE = 22
        if not drawIcon(self, indicator.icon, indicatorX, innerY - 3, WEIGHT_ICON_SIZE) then
            self:drawText("*", indicatorX, innerY, indicator.r, indicator.g, indicator.b, 1, UIFont.Medium)
        end
        innerY = innerY + ROW_HEIGHT

        if hovering then
            local status = UZIR.Tracker.getWeightStatus(player)
            self:drawText(translateWeightStatus(status.text), 10, innerY, status.r, status.g, status.b, 1, UIFont.Small)
            innerY = innerY + ROW_HEIGHT
        end

        cursorY = cursorY + block3Height + BLOCK_GAP
    end

    -- ================== Prioridade 4: Clima/Estacao ==================
    if showGameInfo then
        drawBlockFrame(self, cursorY, block4Height)
        innerY = cursorY + BLOCK_PADDING

        self:drawColorText(L().weatherSeason, 10, innerY, 0.65, 0.65, 0.65, 1, UIFont.Small)
        innerY = innerY + ROW_HEIGHT

        local season, currentMonth, startMonth, endMonth = UZIR.Tracker.getSeasonInfo()
        self:drawColorText(string.format(L().monthLabelFmt, translateSeason(season), currentMonth), 10, innerY, 1, 1, 1, 1, UIFont.Medium)
        innerY = innerY + ROW_HEIGHT

        if hovering then
            local durationLine = string.format(L().durationFmt, translateSeason(season), startMonth, endMonth)
            self:drawColorText(durationLine, 10, innerY, 1, 1, 1, 1, UIFont.Small)
            innerY = innerY + ROW_HEIGHT
        end

        cursorY = cursorY + block4Height + BLOCK_GAP
    end
end

-- ================== Criacao da instancia global ==================

local function createHUD()
    if UZIR.hudInstance then return end

    -- Comeca sempre no canto 1 (superior esquerdo) se ainda nao existe
    -- preferencia salva - loadCornerIndex ja retorna 1 como padrao.
    local cornerIndex = loadCornerIndex()
    local initialHeight = CONTENT_START_Y + (BLOCK_PADDING * 2 + ROW_HEIGHT) + BLOCK_GAP + BOTTOM_PADDING
    local x, y = computeCornerPosition(cornerIndex, PANEL_WIDTH, initialHeight)

    local hud = UZIR_HUD:new(x, y, PANEL_WIDTH, initialHeight)
    hud:initialise()
    hud:addToUIManager()

    UZIR.hudInstance = hud
end

Events.OnGameStart.Add(createHUD)
