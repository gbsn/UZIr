-- Este APP e idealizado por oQuasi e Claude desde 20072026 - Nao permitimos a copia. Divirta-se! Todos os Direitos Reservados
--
-- UZIR_Export.lua
--
-- OBJETIVO 3 do plano: exportar os dados do personagem para um arquivo
-- .json que o Programa Auxiliar (fora do jogo) observa e envia para o
-- site. Este arquivo SO GERA os arquivos - nunca fala com a internet
-- diretamente (o mod nao tem, e nao deveria ter, acesso a rede).
--
-- Escreve em "Zomboid/Lua/UZIR_exports/" (confirmado via documentacao
-- oficial: getFileWriter(filename, createIfNull, append) grava
-- relativo a pasta Zomboid/Lua/). O Programa Auxiliar precisa observar
-- essa MESMA pasta.
--
-- TRES gatilhos, batendo com o formato "Camada 1" ja fechado com o
-- Programa Auxiliar (ver CEREBRO.md do site para o schema completo):
--   "periodic"      - a cada 10 minutos do jogo (Events.EveryTenMinutes)
--   "daily_summary" - quando o personagem dorme (chamado por
--                      UZIR_SleepReport.lua, ANTES do snapshot/reset do
--                      Tracker, para pegar o dia completo)
--   "death"         - quando o personagem morre (Events.OnPlayerDeath)
--
-- IMPORTANTE (nao testado em jogo ainda - primeira versao real desta
-- funcionalidade): os nomes de API abaixo foram confirmados via busca
-- na documentacao oficial/comunidade antes de escrever este arquivo,
-- mas nunca rodaram de verdade. Se algo falhar, o log de console do
-- jogo (prints com prefixo "[UZIR_EXPORT]") deve ajudar a apontar
-- onde.

UZIR = UZIR or {}
UZIR.Export = UZIR.Export or {}

local Export = UZIR.Export
-- CORRIGIDO (bug real encontrado em teste): NAO guardamos mais
-- "Tracker"/"Util" como aliases locais aqui no topo do arquivo. Fazer
-- isso "tira uma foto" do valor de UZIR.Tracker/UZIR.Util no exato
-- momento em que ESTE arquivo carrega - e como os arquivos carregam em
-- ordem alfabetica dentro da pasta ("Export" vem antes de "Tracker"),
-- UZIR.Tracker ainda nao existia quando essa foto seria tirada,
-- deixando a variavel local presa em "nil" para sempre (mesmo depois
-- do Tracker.lua carregar de verdade). Por isso agora usamos
-- UZIR.Tracker.xxx / UZIR.Util.xxx diretamente em todo lugar - assim,
-- cada CHAMADA (que so acontece de verdade dentro de uma funcao,
-- muito depois de todos os arquivos ja terem carregado) le o valor
-- atualizado, nao uma foto antiga.

-- CORRIGIDO nesta rodada: escrevemos DIRETO em "Zomboid/Lua/" (sem
-- subpasta) - suspeita forte de que getFileWriter consegue criar o
-- ARQUIVO (createIfNull=true) mas nao necessariamente uma SUBPASTA que
-- ainda nao existe, o que explicaria um silencio total sem nenhum
-- erro visivel. O nome do arquivo ja comeca com "uzir_" para o
-- Programa Auxiliar conseguir filtrar so' os arquivos que interessam,
-- mesmo observando a pasta Lua inteira.
local EXPORT_FOLDER = ""

-- ================== Log em arquivo (sem precisar do console) ==================
-- O oQuasi nao quer ativar o console de debug da Steam so' pra ver
-- print(). Em vez disso, escrevemos um arquivo de log PROPRIO,
-- acrescentando uma linha a cada evento importante - da' pra abrir
-- esse arquivo normalmente, a qualquer momento, sem mexer em nada do
-- jogo. Usa a MESMA API (getFileWriter) que a exportacao usa, com
-- append=true (acrescenta, nunca sobrescreve) - se esse log tambem
-- nao aparecer, isso ja e' uma pista forte de que getFileWriter nao
-- esta funcionando de jeito nenhum a partir do mod.
local function debugLog(message)
    local ok, writer = pcall(function() return getFileWriter("uzir_debug.log", true, true) end)
    if ok and writer then
        pcall(function()
            writer:write(os.date("!%Y-%m-%dT%H:%M:%SZ") .. " - " .. tostring(message) .. "\n")
        end)
        pcall(function() writer:close() end)
    end
    -- Continua tambem tentando o print(), para quem tiver o console
    -- ativado - nao custa nada manter os dois.
    pcall(function() print("[UZIR_EXPORT] " .. tostring(message)) end)
end

-- CONFIRMACAO MAIS BASICA DE TODAS: se essa linha nunca aparecer no
-- log, o proprio arquivo UZIR_Export.lua nao esta carregando (erro de
-- sintaxe, mod desativado, etc) - problema diferente de "carregou mas
-- os gatilhos nao disparam".
debugLog("modulo UZIR_Export.lua carregado com sucesso")

-- ================== IDs persistentes (mundo e personagem) ==================
-- Nao existe gerador de UUID nativo confiavel aqui - construimos um
-- identificador com entropia razoavel a partir do relogio + numeros
-- aleatorios. So' precisa ser PRATICAMENTE unico entre mundos/
-- personagens, nao resistente a ataque criptografico.

-- Contador simples, incrementado a cada chamada - junto com o relogio,
-- garante que duas chamadas seguidas nunca gerem o mesmo ID, mesmo sem
-- nenhum gerador de numero aleatorio de verdade.
local uuidCallCounter = 0

local function generatePseudoUUID()
    -- CORRIGIDO (bug real encontrado em teste): math.randomseed() nao
    -- existe na Lua reduzida (Kahlua) que o jogo usa - era essa a
    -- causa exata do erro "tried to call nil in generatePseudoUUID".
    -- Reescrito para depender SO' de coisas ja comprovadas que
    -- funcionam neste mod: string.format (usado em varios lugares do
    -- HUD, que ja funciona) e UZIR.Util.nowMs() (usado no proprio
    -- log de debug, que ja funciona). Nao usa mais math.random,
    -- math.randomseed, nem :gsub.
    uuidCallCounter = uuidCallCounter + 1
    local now = UZIR.Util.nowMs()
    return string.format("uzir-%d-%d", now, uuidCallCounter)
end

-- world_id: guardado no ModData do PROPRIO SAVE (nao do personagem) -
-- ModData.getOrCreate persiste dentro do save, entao e' naturalmente
-- um-por-mundo.
local function getOrCreateWorldID()
    local data = ModData.getOrCreate("UZIR_WorldID")
    if not data.id then
        data.id = generatePseudoUUID()
    end
    return data.id
end

-- character_id: guardado no ModData do PERSONAGEM (player:getModData()),
-- que persiste com aquele personagem especifico.
local function getOrCreateCharacterID(player)
    local modData = player:getModData()
    if not modData.UZIR_CharacterID then
        modData.UZIR_CharacterID = generatePseudoUUID()
    end
    return modData.UZIR_CharacterID
end

local function getCharacterName(player)
    local candidates = {
        function()
            local d = player:getDescriptor()
            return d:getForename() .. " " .. d:getSurname()
        end,
        function() return player:getUsername() end,
    }
    for _, fn in ipairs(candidates) do
        local ok, name = pcall(fn)
        if ok and name and name ~= "" and name ~= " " then return name end
    end
    return "Sobrevivente"
end

local function getDayNumber()
    local ok, day = pcall(function() return getGameTime():getDay() end)
    if ok and day then return day end
    return nil
end

-- ================== Conversao de formato (interno -> Camada 1) ==================
-- O Tracker guarda kill/XP breakdown num formato proprio, otimizado
-- para reconstruir na ordem certa ({order=[...], categories={nome=
-- {weapons=[{name,count}]}}}) - convertendo aqui para o formato "chave
-- direta" que o schema da Camada 1 espera (ex: {"Melee":{"Fire Axe":42}}).

local function flattenKillBreakdown(breakdown)
    local flat = {}
    for _, catName in ipairs(breakdown.order or {}) do
        local cat = breakdown.categories[catName]
        if cat then
            local weaponsFlat = {}
            for _, w in ipairs(cat.weapons) do
                weaponsFlat[w.name] = w.count
            end
            flat[catName] = weaponsFlat
        end
    end
    return flat
end

local function flattenXPBreakdown(breakdown)
    local flat = {}
    for _, catName in ipairs(breakdown.order or {}) do
        local cat = breakdown.categories[catName]
        if cat then
            local skillsFlat = {}
            for _, s in ipairs(cat.skills) do
                skillsFlat[s.name] = s.amount
            end
            flat[catName] = skillsFlat
        end
    end
    return flat
end

-- ================== Calculo de delta (so' para "periodic") ==================
-- IMPORTANTE: o Tracker acumula kills/XP desde o ultimo SONO, nao desde
-- o ultimo envio periodico. Se mandassemos esse total "cru" a cada 10
-- minutos, o site somaria o mesmo progresso repetidas vezes (contagem
-- em dobro/triplo/etc). Por isso, para envios "periodic", calculamos a
-- DIFERENCA em relacao ao ultimo envio periodico (guardado a parte, no
-- ModData do personagem) - so' assim cada pacote representa APENAS o
-- que aconteceu naquela janela de 10 minutos.

local function diffFlatNumberTables(current, previous)
    local diff = {}
    for cat, skills in pairs(current) do
        local prevCat = previous[cat] or {}
        local diffSkills = {}
        local hasAny = false
        for name, value in pairs(skills) do
            local prevValue = prevCat[name] or 0
            local delta = value - prevValue
            if delta ~= 0 then
                diffSkills[name] = delta
                hasAny = true
            end
        end
        if hasAny then
            diff[cat] = diffSkills
        end
    end
    return diff
end

local function deepCopyFlat(flat)
    local copy = {}
    for cat, skills in pairs(flat) do
        local copySkills = {}
        for name, value in pairs(skills) do
            copySkills[name] = value
        end
        copy[cat] = copySkills
    end
    return copy
end

-- ================== Montagem do pacote (Camada 1) ==================

function Export.buildPayload(player, submissionType)
    debugLog("checkpoint 1: buildPayload iniciado")

    local leagueName, isValid = UZIR.Tracker.getLeagueInfo()
    debugLog("checkpoint 2: league info obtido (" .. tostring(leagueName) .. ")")

    local weight = 0
    local okWeight, w = pcall(function() return player:getNutrition():getWeight() end)
    if okWeight and w then weight = w end
    debugLog("checkpoint 3: peso obtido (" .. tostring(weight) .. ")")

    -- Estacao atual (a mesma que o HUD ja mostra no jogo, via
    -- UZIR.Tracker.getSeasonInfo) - agora tambem exportada.
    local seasonName = nil
    local okSeason, s = pcall(function()
        local season = UZIR.Tracker.getSeasonInfo()
        return season
    end)
    if okSeason and s then seasonName = s end
    debugLog("checkpoint 4: estacao obtida (" .. tostring(seasonName) .. ")")

    local payload = {
        world_id = getOrCreateWorldID(),
        character_id = getOrCreateCharacterID(player),
        character_name = getCharacterName(player),
        submission_type = submissionType,
        day_number = getDayNumber(),
        hours_alive = UZIR.Tracker.getHoursAlive(player),
        weight = weight,
        league = leagueName,
        is_valid = isValid,
        season = seasonName,
        game_version = UZIR.Tracker.getGameVersion(),
        is_multiplayer = isClient(),
        server_name = nil, -- pendente - ver CEREBRO.md, nao confirmado ainda como obter
        zkill_count = UZIR.Tracker.getKillCount(player),
        fire_kills = UZIR.Tracker.getFireKills(player),
        vehicle_kills = UZIR.Tracker.getVehicleKills(player),
        death_cause = nil, -- so' preenchido no gatilho de morte, ver mais abaixo
        client_reported_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    }
    debugLog("checkpoint 5: payload base montado")

    local killBreakdownFull = flattenKillBreakdown(UZIR.Tracker.getTodayValidBreakdown(player))
    debugLog("checkpoint 6: kill breakdown convertido")
    local xpBreakdownFull = flattenXPBreakdown(UZIR.Tracker.getTodayXPBreakdown(player))
    debugLog("checkpoint 7: xp breakdown convertido")

    if submissionType == "periodic" then
        local modData = player:getModData()
        local lastKills = modData.UZIR_lastPeriodicKills or {}
        local lastXP = modData.UZIR_lastPeriodicXP or {}

        payload.kill_breakdown = diffFlatNumberTables(killBreakdownFull, lastKills)
        payload.xp_breakdown = diffFlatNumberTables(xpBreakdownFull, lastXP)

        modData.UZIR_lastPeriodicKills = deepCopyFlat(killBreakdownFull)
        modData.UZIR_lastPeriodicXP = deepCopyFlat(xpBreakdownFull)
    else
        -- "daily_summary" ou "death": manda o total completo (nao e'
        -- delta), e reseta a base do periodic - o dia esta virando ou
        -- acabando de qualquer jeito.
        payload.kill_breakdown = killBreakdownFull
        payload.xp_breakdown = xpBreakdownFull

        local modData = player:getModData()
        modData.UZIR_lastPeriodicKills = nil
        modData.UZIR_lastPeriodicXP = nil
    end
    debugLog("checkpoint 8: delta/reset de periodico processado")

    -- Lista de kills com horario - o Tracker ainda nao guarda isso
    -- (so' o contador total), entao fica vazia por enquanto. O schema
    -- aceita lista vazia; implementar de verdade e' uma pendencia
    -- futura, nao um esquecimento.
    payload.kill_timestamps = {}

    debugLog("checkpoint 9: buildPayload concluido, retornando")
    return payload
end

-- ================== Escrita do arquivo ==================

function Export.writeToFile(payload)
    debugLog("checkpoint 10: writeToFile iniciado")
    local json = UZIR.Util.encodeJSON(payload)
    debugLog("checkpoint 11: JSON codificado (tamanho " .. tostring(#json) .. ")")
    uuidCallCounter = uuidCallCounter + 1
    local baseName = string.format("uzir_%d_%d.json", UZIR.Util.nowMs(), uuidCallCounter)

    -- ORDEM ZERO PARCIMONIA (a pedido do oQuasi): tentamos VARIOS
    -- candidatos, registrando o resultado exato de cada um. CONFIRMADO
    -- na documentacao oficial (projectzomboid.com/modding):
    -- getModFileWriter(modId, filename, createIfNull, append) - o
    -- modId vem PRIMEIRO. "UZIR" e' o ID do nosso mod (ver mod.info).
    -- NOTA: evitamos table.unpack de proposito (e' Lua 5.2+; o Kahlua
    -- daqui e' baseado em Lua 5.1) - cada candidato chama a funcao
    -- direto, com argumentos explicitos.
    local MOD_ID = "UZIR"
    local subpastaName = "UZIR_exports/" .. baseName

    local attempts = {
        {
            label = "getModFileWriter (raiz)",
            filenameForLog = baseName,
            call = function() return getModFileWriter(MOD_ID, baseName, true, false) end,
        },
        {
            label = "getModFileWriter (subpasta)",
            filenameForLog = subpastaName,
            call = function() return getModFileWriter(MOD_ID, subpastaName, true, false) end,
        },
        {
            label = "getFileWriter (raiz)",
            filenameForLog = baseName,
            call = function() return getFileWriter(baseName, true, false) end,
        },
    }

    for _, attempt in ipairs(attempts) do
        debugLog("tentando escrever em [" .. attempt.label .. "]: " .. attempt.filenameForLog)

        local ok, writer = pcall(attempt.call)

        debugLog("  resultado: ok=" .. tostring(ok) .. " writer=" .. tostring(writer))

        if ok and writer then
            local okWrite, writeErr = pcall(function() writer:write(json) end)
            pcall(function() writer:close() end)

            if okWrite then
                debugLog("SUCESSO escrevendo em [" .. attempt.label .. "]: " .. attempt.filenameForLog)
                return true
            else
                debugLog("  abriu mas falhou ao escrever: " .. tostring(writeErr))
            end
        end
    end

    debugLog("TODOS os candidatos de escrita falharam para: " .. baseName)
    return false
end

-- ================== Ponto de entrada unico ==================

function Export.exportNow(submissionType, player)
    debugLog("gatilho disparado: " .. tostring(submissionType))

    player = player or UZIR.Tracker.getPlayer()
    if not player then
        debugLog("player nao encontrado, abortando")
        return
    end

    -- CORRIGIDO: antes, se qualquer coisa dentro de buildPayload desse
    -- erro (varias chamadas ali NAO estavam protegidas por pcall), o
    -- erro travava a funcao inteira em SILENCIO TOTAL - nem "gatilho
    -- disparado" nem nenhuma mensagem de falha apareciam depois disso.
    -- Agora envolvemos tudo numa rede de seguranca, que finalmente
    -- mostra o erro de verdade no log.
    local ok, err = pcall(function()
        local payload = Export.buildPayload(player, submissionType)
        Export.writeToFile(payload)
    end)

    if not ok then
        debugLog("ERRO durante buildPayload/writeToFile: " .. tostring(err))
    end
end

-- Chamada publica especifica para o gatilho de sono - UZIR_SleepReport.lua
-- chama isso ANTES de UZIR.Tracker.snapshotAndResetToday(), para capturar o
-- dia inteiro antes do reset.
function Export.onSleepTransition(player)
    Export.exportNow("daily_summary", player)
end

-- ================== Gatilhos ==================

-- Periodico. NOTA: o desenho original (documentado no CEREBRO) previa
-- "a cada 5 minutos" - ajustamos para 10 minutos aqui porque
-- Events.EveryTenMinutes e' o evento nativo confirmado e confiavel;
-- preferimos isso a inventar um temporizador customizado por cima.
Events.EveryTenMinutes.Add(function()
    Export.exportNow("periodic")
end)

-- Morte - death_cause ainda fica vazio (nao confirmamos a API certa
-- para descobrir a causa exata da morte).
Events.OnPlayerDeath.Add(function(player)
    Export.exportNow("death", player)
end)

debugLog("gatilhos EveryTenMinutes e OnPlayerDeath registrados com sucesso")
