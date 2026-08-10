-- Este APP e idealizado por oQuasi e Claude desde 20072026 - Nao permitimos a copia. Divirta-se! Todos os Direitos Reservados
--
-- UZIR_Tracker.lua
-- UZIR (Ultimate Zombie Interconnected Ranking) / apelido "UZI"
--
-- Camada de DADOS do mod: le, guarda e classifica o progresso do
-- personagem. Nenhum arquivo de UI (HUD, SleepReport) deveria acessar
-- player:getModData() diretamente - sempre atraves das funcoes publicas
-- listadas abaixo. Isso mantem um unico lugar responsavel por gravar
-- cada campo, o que facilita auditar o mod no futuro.
--
-- IMPORTANTE - leia o bloco de seguranca em UZIR_Util.lua antes de
-- adicionar novas funcoes publicas aqui. Regra geral: se a funcao GRAVA
-- dado, prefira deixar "local" (privada deste arquivo) a menos que outro
-- arquivo do mod realmente precise chama-la de fora.
--
-- API PUBLICA deste arquivo (Tracker.*), pensada para ser so LEITURA
-- exceto snapshotAndResetToday (ver comentario dela mais abaixo):
--   getPlayer()                    - jogador local atual
--   getKillCount(player)           - total oficial de kills (nativo do jogo)
--   getFireKills(player)           - total de mortes por fogo (todo o save)
--   getVehicleKills(player)        - total de atropelamentos (todo o save)
--   getInvalidTotal(player)        - fogo + atropelamento somados
--   getHoursAlive(player)          - horas de vida do personagem atual (inteiro, usado na exportacao)
--   getAliveClockLine(player)      - relogio "HH:MM:SS" do tempo de vida, pronto pra exibir
--   getDaysAlive(player)           - total de dias vivos (numero cru, sem traducao)
--   getKillCountLine(player)       - string "zKILL 0000" pronta pro HUD
--   getWeightLine(player)          - string "Weight-85.5" pronta pro HUD
--   getWeightStatus(player)        - {text, r, g, b} High Weight/Regular/Under Weight
--   getWeightIndicator(player)     - {symbol, r, g, b} seta/circulo de tendencia de peso
--   getSeasonInfo()                - estacao atual, mes atual, mes inicio/fim da estacao
--   getLeagueInfo()                - nome do modo de jogo (League) + se bate com um preset oficial (Valid/inValid)
--   getGameVersion()               - string da versao do jogo (ex "42.20.0"), ou "Unknown"
--   getTotalXP(player)             - XP total do personagem (nativo do jogo)
--   getPerkXP(player, perkName)    - XP de uma pericia especifica
--   getPerkLevelByName(player, perkName) - nivel atual de uma pericia (0-10)
--   getLastTrainedSkill(player)    - nome da pericia mais recente a ganhar XP (ou nil)
--   getSkillLevelProgress(player, perkName) - nivel, XP atual, XP restante ate o proximo nivel
--   getTodayXPBreakdown(player)    - XP ganho HOJE, por categoria/pericia (ao vivo, usado no Sleep Report)
--   drainXPEvents()                - eventos de XP recentes, para o HUD montar os flutuantes
--   getTodayValidBreakdown(player) - kills validos acumulados HOJE (ao vivo)
--   getDailyHistory(player)        - snapshots de dias passados (sleep report)
--   snapshotAndResetToday(player)  - ver aviso na propria funcao

UZIR = UZIR or {}
UZIR.Tracker = UZIR.Tracker or {}

local Tracker = UZIR.Tracker
local Util = UZIR.Util -- definido em UZIR_Util.lua (shared, carrega antes)

-- Janela de tempo para aceitar uma causa de morte como valida depois de
-- um evento (atropelamento ou golpe de arma). Sem essa janela, um
-- zumbi que morresse bem depois por outro motivo (armadilha, outro mod,
-- reaproveitamento da instancia) poderia ser creditado errado.
local VEHICLE_HIT_WINDOW_MS = 3000
local WEAPON_HIT_WINDOW_MS = 5000

-- ================== Jogador local ==================

-- Retorna o jogador local (0 = primeiro jogador da tela, cobre single
-- player e a maioria dos casos de splitscreen para o slot principal).
-- LIMITACAO CONHECIDA: em multiplayer com mais de um jogador local, ou
-- ao adaptar este mod para rastrear outros jogadores, este indice fixo
-- precisara ser revisto.
function Tracker.getPlayer()
    return getSpecificPlayer(0)
end

-- Garante que o personagem tem a estrutura de dados inicializada.
-- Privada: so o proprio arquivo precisa chamar isso (hook no fim do arquivo).
local function initPlayerData(player)
    if not player then return end
    local modData = player:getModData()
    if modData.UZIR_hoursAlive == nil then
        modData.UZIR_hoursAlive = 0
    end
end

-- Chamado a cada hora de jogo (Events.EveryHours). Incrementa o
-- contador de horas vivas (fallback caso o jogo nao exponha um getter
-- nativo equivalente) e aproveita para atualizar a marca de "debug
-- usado neste save", ja que checar isso a cada hora e barato o
-- suficiente e nao precisa ser por frame.
local function onEveryHour()
    local player = Tracker.getPlayer()
    if not player then return end

    if Util.isDebugActive() then
        player:getModData().UZIR_debugEverActive = true
    end

    if player:isDead() then return end

    local modData = player:getModData()
    modData.UZIR_hoursAlive = (modData.UZIR_hoursAlive or 0) + 1
end

-- Numero de zumbis mortos pelo personagem (KillCount oficial do jogo).
-- Tenta usar o getter nativo do jogo (ja usado por outros mods de
-- ranking); se por algum motivo nao existir na build atual, retorna 0
-- em vez de crashar. O resultado sempre passa por sanitizeCount.
function Tracker.getKillCount(player)
    player = player or Tracker.getPlayer()
    if not player then return 0 end

    local ok, kills = pcall(function() return player:getZombieKills() end)
    if ok then
        return Util.sanitizeCount(kills)
    end
    return 0
end

-- Se este save ja teve o modo debug/cheat do jogo ativo em algum
-- momento. Nao bloqueia nada por si so - serve como contexto para uma
-- futura revisao manual ou para o backend do site de ranking decidir o
-- que fazer com esse resultado (o mesmo principio que o proprio jogo ja
-- usa para desativar conquistas).
function Tracker.wasDebugEverActive(player)
    player = player or Tracker.getPlayer()
    if not player then return false end
    return player:getModData().UZIR_debugEverActive == true
end

-- ================== Mortes por fogo e por atropelamento ==================
-- O contador nativo do jogo (getKillCount, acima) so soma mortes causadas
-- diretamente por golpe de arma do jogador. Zumbis mortos por fogo ou
-- atropelamento NAO entram nesse numero em lugar nenhum nativamente, entao
-- rastreamos isso por conta propria, separado do zKILL oficial.

function Tracker.getFireKills(player)
    player = player or Tracker.getPlayer()
    if not player then return 0 end
    return Util.sanitizeCount(player:getModData().UZIR_fireKills)
end

function Tracker.getVehicleKills(player)
    player = player or Tracker.getPlayer()
    if not player then return 0 end
    return Util.sanitizeCount(player:getModData().UZIR_vehicleKills)
end

-- TOTAL Points do lado "inValid" = fogo + atropelamento somados (todo o save).
function Tracker.getInvalidTotal(player)
    player = player or Tracker.getPlayer()
    if not player then return 0 end
    return Tracker.getFireKills(player) + Tracker.getVehicleKills(player)
end

-- Marca, na propria instancia do zumbi, que ele acabou de ser atingido por
-- um veiculo, com o horario do toque. Usado em onZombieDead para decidir a
-- causa da morte. Privada: ninguem de fora precisa chamar isso.
--
-- ATENCAO: nao existe um evento oficial "zumbi atropelado" no Lua do jogo;
-- isso e uma aproximacao via OnObjectCollide e pode nao pegar 100% dos casos
-- (ou raramente marcar um caso que nao era realmente atropelamento).
local function onObjectCollide(object, collided)
    local ok, isVehicle = pcall(function() return instanceof(object, "BaseVehicle") end)
    if not (ok and isVehicle) then return end

    local ok2, isZombie = pcall(function() return instanceof(collided, "IsoZombie") end)
    if not (ok2 and isZombie) then return end

    pcall(function()
        collided:getModData().UZIR_vehicleHitTime = Util.nowMs()
    end)
end

-- ================== Rastreamento de arma para "Valid Points" ==================
-- Para o relatorio de sono, precisamos saber nao so QUANTOS zumbis
-- morreram oficialmente, mas COM QUE ARMA. Guardamos, na propria
-- instancia do zumbi, qual foi a ultima arma do jogador que o atingiu E
-- QUANDO, para so confiar nisso se a morte aconteceu logo em seguida
-- (ver WEAPON_HIT_WINDOW_MS).

-- Classifica a arma em categoria ampla. ATENCAO: usamos weapon:isRanged()
-- para separar "Fire Gun" de "Melee" - isso tambem classificaria arcos
-- como "Fire Gun", entao pode precisar de ajuste fino apos teste real.
local function classifyWeapon(weapon)
    local ok, ranged = pcall(function() return weapon:isRanged() end)
    if ok and ranged then
        return "Fire Gun"
    end
    return "Melee"
end

-- Privada: so o proprio arquivo precisa chamar isso (hook no fim do arquivo).
local function onHitZombie(zombie, attacker, bodyPart, weapon)
    local player = Tracker.getPlayer()
    if not player or attacker ~= player or not weapon then return end

    pcall(function()
        local zModData = zombie:getModData()
        zModData.UZIR_lastWeaponName = weapon:getDisplayName() or "Unknown"
        zModData.UZIR_lastWeaponCategory = classifyWeapon(weapon)
        zModData.UZIR_lastWeaponHitTime = Util.nowMs()
    end)
end

-- Registra um kill "oficial" no acumulado do dia (ao vivo). Privada:
-- so onZombieDead (deste mesmo arquivo) deveria chamar isso. Manter
-- privada reduz a chance de outro script injetar kills falsos chamando
-- essa funcao diretamente de fora.
--
-- Estrutura guardada em player:getModData().UZIR_todayValid:
--   { order = {"Melee", "Fire Gun", ...},
--     categories = { Melee = { weapons = { {name="Base Ball Bat", count=2}, ... } }, ... } }
local function recordValidKill(player, category, weaponName)
    if not player or not category or not weaponName then return end
    local modData = player:getModData()
    if not modData.UZIR_todayValid then
        modData.UZIR_todayValid = {order = {}, categories = {}}
    end
    local today = modData.UZIR_todayValid

    local cat = today.categories[category]
    if not cat then
        cat = {weapons = {}}
        today.categories[category] = cat
        table.insert(today.order, category)
    end

    local entry = nil
    for _, w in ipairs(cat.weapons) do
        if w.name == weaponName then
            entry = w
            break
        end
    end
    if not entry then
        entry = {name = weaponName, count = 0}
        table.insert(cat.weapons, entry)
    end
    entry.count = entry.count + 1
end

-- Kills validos acumulados desde o ultimo sono (ainda "ao vivo", muda a
-- cada kill). O Sleep Report NAO le isso diretamente para exibir - ele
-- le o snapshot congelado em getDailyHistory. Esta funcao fica
-- disponivel para outros usos futuros (ex: um widget de HUD "hoje").
function Tracker.getTodayValidBreakdown(player)
    player = player or Tracker.getPlayer()
    if not player then return {order = {}, categories = {}} end
    return player:getModData().UZIR_todayValid or {order = {}, categories = {}}
end

-- Copia profunda da tabela de breakdown, para o snapshot nao ficar "vivo"
-- (se copiassemos so a referencia, o reset logo em seguida apagaria o
-- snapshot tambem, ja que em Lua tabelas sao referencias).
local function deepCopyBreakdown(breakdown)
    local copy = {order = {}, categories = {}}
    for i, catName in ipairs(breakdown.order) do
        copy.order[i] = catName
    end
    for catName, cat in pairs(breakdown.categories) do
        local weapons = {}
        for i, w in ipairs(cat.weapons) do
            weapons[i] = {name = w.name, count = Util.sanitizeCount(w.count)}
        end
        copy.categories[catName] = {weapons = weapons}
    end
    return copy
end

-- Copia profunda do breakdown de XP (mesma razao da deepCopyBreakdown
-- acima: o snapshot nao pode ficar "vivo" apontando pra mesma tabela
-- que vai ser zerada em seguida). Definida aqui (nao junto do resto da
-- logica de XP, mais abaixo no arquivo) porque snapshotAndResetToday
-- precisa dela e Lua exige que funcoes locais existam antes de usadas.
local function deepCopyXPBreakdown(breakdown)
    local copy = {order = {}, categories = {}}
    for i, catName in ipairs(breakdown.order) do
        copy.order[i] = catName
    end
    for catName, cat in pairs(breakdown.categories) do
        local skills = {}
        for i, s in ipairs(cat.skills) do
            skills[i] = {name = s.name, amount = s.amount}
        end
        copy.categories[catName] = {skills = skills}
    end
    return copy
end

-- Chamado quando o personagem DORME. Tira um "retrato" do que foi
-- acumulado desde o ultimo sono e guarda no historico; so depois zera o
-- contador "ao vivo" para comecar a acumular o proximo periodo.
--
-- Esta funcao PRECISA continuar publica porque UZIR_SleepReport.lua (um
-- arquivo diferente) chama ela na transicao de dormir. E a unica funcao
-- de escrita deste arquivo exposta publicamente por necessidade real de
-- uso externo.
function Tracker.snapshotAndResetToday(player)
    if not player then return end
    local modData = player:getModData()

    local today = modData.UZIR_todayValid or {order = {}, categories = {}}
    local snapshot = deepCopyBreakdown(today)

    local todayXP = modData.UZIR_todayXP or {order = {}, categories = {}}
    local xpSnapshot = deepCopyXPBreakdown(todayXP)

    local fireToday = Util.sanitizeCount(modData.UZIR_fireKillsToday)
    local vehicleToday = Util.sanitizeCount(modData.UZIR_vehicleKillsToday)

    modData.UZIR_dayCounter = (modData.UZIR_dayCounter or 0) + 1
    modData.UZIR_dailyHistory = modData.UZIR_dailyHistory or {}
    table.insert(modData.UZIR_dailyHistory, {
        dayNumber = modData.UZIR_dayCounter,
        breakdown = snapshot,
        invalidFire = fireToday,
        invalidVehicle = vehicleToday,
        xpBreakdown = xpSnapshot,
    })

    modData.UZIR_todayValid = {order = {}, categories = {}}
    modData.UZIR_fireKillsToday = 0
    modData.UZIR_vehicleKillsToday = 0
    modData.UZIR_todayXP = {order = {}, categories = {}}
end

-- Historico de dias (cada entrada = um periodo entre dois sonos).
function Tracker.getDailyHistory(player)
    player = player or Tracker.getPlayer()
    if not player then return {} end
    return player:getModData().UZIR_dailyHistory or {}
end

-- Ao zumbi morrer, decide a causa (fogo, veiculo, ou golpe direto do
-- jogador) e credita o tipo certo de ponto. Privada: so este arquivo
-- precisa reagir a esse evento.
--
-- Em todos os ramos, limpamos os campos temporarios gravados na
-- instancia do zumbi depois de usa-los. Isso e importante porque o
-- jogo RECICLA instancias de IsoZombie (object pooling) - sem essa
-- limpeza, um zumbi reaproveitado poderia "herdar" informacao de arma
-- de um zumbi completamente diferente morto muito antes.
local function onZombieDead(zombie)
    local player = Tracker.getPlayer()
    if not player then return end

    local zModData = zombie:getModData()

    local okFire, onFire = pcall(function() return zombie:isOnFire() end)
    if okFire and onFire then
        local modData = player:getModData()
        modData.UZIR_fireKills = (modData.UZIR_fireKills or 0) + 1
        modData.UZIR_fireKillsToday = (modData.UZIR_fireKillsToday or 0) + 1
        zModData.UZIR_vehicleHitTime = nil
        zModData.UZIR_lastWeaponName = nil
        zModData.UZIR_lastWeaponCategory = nil
        zModData.UZIR_lastWeaponHitTime = nil
        return
    end

    local hitTime = zModData.UZIR_vehicleHitTime
    if hitTime and (Util.nowMs() - hitTime) <= VEHICLE_HIT_WINDOW_MS then
        local modData = player:getModData()
        modData.UZIR_vehicleKills = (modData.UZIR_vehicleKills or 0) + 1
        modData.UZIR_vehicleKillsToday = (modData.UZIR_vehicleKillsToday or 0) + 1
        zModData.UZIR_vehicleHitTime = nil
        zModData.UZIR_lastWeaponName = nil
        zModData.UZIR_lastWeaponCategory = nil
        zModData.UZIR_lastWeaponHitTime = nil
        return
    end

    -- Kill "oficial" (Valid Points): so credita a arma se o golpe foi
    -- recente o suficiente (evita atribuir um golpe antigo/obsoleto a
    -- uma morte causada por outra coisa).
    local wName = zModData.UZIR_lastWeaponName
    local wCat = zModData.UZIR_lastWeaponCategory
    local wTime = zModData.UZIR_lastWeaponHitTime
    if wName and wCat and wTime and (Util.nowMs() - wTime) <= WEAPON_HIT_WINDOW_MS then
        recordValidKill(player, wCat, wName)
    end

    zModData.UZIR_vehicleHitTime = nil
    zModData.UZIR_lastWeaponName = nil
    zModData.UZIR_lastWeaponCategory = nil
    zModData.UZIR_lastWeaponHitTime = nil
end

-- ================== Tempo de vida (Live: h/D/W/M/Y) ==================

-- Horas totais de vida do personagem atual.
--
-- HISTORICO DA INVESTIGACAO (pra quem for mexer aqui depois):
-- 1a tentativa: player:getHoursSurvived() com pcall -> sempre caia no
--   fallback (o pcall falhava), entao nunca vimos o bug de verdade.
-- 2a tentativa: getGameTime():getHoursSurvived() -> reiniciava a cada
--   sessao nova, inaceitavel.
-- 3a tentativa: player:getHoursSurvived() direto (sem pcall), copiando
--   o mod de referencia "Twiston Stats" -> os numeros bateram com a
--   tela nativa "Tempo de Sobrevivencia" do jogo (23 horas)... mas o
--   AUTOR confirmou que isso esta ERRADO: o personagem tinha sobrevivido
--   vários dias de verdade (o site UZIrVector, alimentado por
--   exportacoes antigas que caiam no fallback, mostrava 8 dias -
--   condizente com a memoria do autor). A explicacao: o sono acelera o
--   tempo DE JOGO, que roda "no seu proprio tempo", sem relacao com o
--   relogio real - e a funcao nativa (seja qual for a fonte exata)
--   parece nao acompanhar isso direito.
--
-- CONCLUSAO E FONTE FINAL: o unico contador em que confiamos e o nosso
-- proprio, alimentado por Events.EveryHours (ver onEveryHour acima) -
-- ele dispara com base no RELOGIO DO JOGO (acelera certo durante o
-- sono, por definicao) e fica salvo no ModData do personagem
-- (sobrevive entre sessoes). Paramos de tentar qualquer funcao nativa
-- de "horas sobrevividas".
function Tracker.getHoursAlive(player)
    player = player or Tracker.getPlayer()
    if not player then return 0 end

    return Util.sanitizeCount(player:getModData().UZIR_hoursAlive)
end

-- Mesma fonte que Tracker.getHoursAlive. Nao tem "Raw" fracionario de
-- verdade porque o contador manual so incrementa de hora em hora (sem
-- precisao de minuto/segundo) - decisao consciente do autor: preferir
-- um numero de horas/dias CORRETO (tempo de jogo) a um relogio com
-- minutos/segundos bonitos porem baseados em fonte nao confiavel.
-- TODO (pedido do autor, sem prioridade agora): no futuro, adicionar
-- TAMBEM uma contagem de tempo REAL (relogio de parede) como metrica
-- separada, sem substituir esta.
local function getHoursAliveRaw(player)
    return Tracker.getHoursAlive(player)
end

-- Strings ja formatadas no padrao pedido: "zKILL 0000"
function Tracker.getKillCountLine(player)
    return string.format("zKILL %04d", Tracker.getKillCount(player))
end

-- Relogio HH:MM:SS do tempo de vida do personagem atual, contado no
-- tempo DE JOGO (nao tempo real - acelera certo durante o sono, pois a
-- fonte e o contador manual por hora de jogo, ver comentario de
-- Tracker.getHoursAlive acima). MM e SS ficam sempre "00" porque essa
-- fonte so tem precisao de hora inteira - preferimos um numero de horas
-- correto a minutos/segundos "bonitos" vindos de uma fonte que nao
-- acompanha o tempo de jogo direito. Sem limite de 99 em HH - depois de
-- varios dias passa de 2 digitos naturalmente (ex "240:00:00"). Pronta
-- para exibir, nao precisa de traducao (so numeros).
function Tracker.getAliveClockLine(player)
    local totalHours = getHoursAliveRaw(player)
    return string.format("%02d:00:00", totalHours)
end

-- Total de dias vivos do personagem atual (numero inteiro, horas totais
-- / 24). Devolvido CRU (sem formatar como texto) porque a linha exibida
-- ("XX Days" / "XX Dias") depende do idioma ativo - a formatacao/
-- traducao acontece so no HUD (camada de apresentacao), nunca aqui.
function Tracker.getDaysAlive(player)
    return math.floor(getHoursAliveRaw(player) / 24)
end

-- ================== League: modo de jogo (Valid / inValid) ==================
-- Compara as configuracoes de sandbox ATUAIS do mundo contra os modos
-- oficiais do jogo (ver UZIR_Presets.lua) para decidir se o jogador
-- esta numa "League" oficial sem alteracoes ("Valid") ou num Sandbox
-- customizado ("inValid").
--
-- SEGURANCA: aqui SO LEMOS a tabela global "SandboxVars" (configuracao
-- atual, somente leitura). NUNCA chamamos getSandboxOptions():loadPresetFile(),
-- que descobrimos ser uma funcao que APLICA um preset (efeito colateral
-- perigoso) - usar ela so para comparar mudaria as configuracoes de
-- verdade do jogador sem querer.

-- Percorre recursivamente e ACUMULA toda diferenca encontrada entre um
-- valor de preset (a) e o valor correspondente no mundo atual (b), em
-- vez de so retornar true/false. Isso e o que nos deixa mostrar
-- exatamente QUAL campo nao bateu, para diagnosticar o problema em vez
-- de so saber que "algo" diverge.
local function collectDifferences(path, a, b, diffs)
    if type(a) ~= type(b) then
        table.insert(diffs, {path = path, expected = tostring(a), actual = tostring(b)})
        return
    end
    if type(a) == "table" then
        for k, v in pairs(a) do
            local childPath = (path == "" and tostring(k)) or (path .. "." .. tostring(k))
            collectDifferences(childPath, v, b[k], diffs)
        end
        return
    end
    if a ~= b then
        table.insert(diffs, {path = path, expected = tostring(a), actual = tostring(b)})
    end
end

-- Retorna a lista de diferencas entre um preset e o mundo atual (lista
-- vazia = bate perfeitamente), ou nil se a comparacao falhou por algum
-- motivo (ex: SandboxVars ainda nao existe nesse momento).
-- Campos que NAO representam uma escolha do jogador, entao sao
-- excluidos da comparacao (senao gerariam falso "inValid" mesmo sem
-- ninguem ter mexido em nada):
--   Version              - versao do FORMATO do arquivo de sandbox
--   WaterShutModifier,
--   ElecShutModifier,
--   AlarmDecayModifier   - HIPOTESE (confirmada por teste real: o log
--     mostrou WaterShutModifier divergindo mesmo no modo Extinction
--     "de fabrica", sem alteracao nenhuma). Esses "Modifier" parecem
--     ser o dia-alvo em torno do qual o jogo SORTEIA quando a agua/luz
--     de fato desligam - ou seja, o valor no preset e so a media usada
--     pelo sorteio, e o valor real do mundo varia a cada save mesmo
--     sem o jogador mudar a configuracao.
local IGNORED_FIELDS = {
    Version = true,
    WaterShutModifier = true,
    ElecShutModifier = true,
    AlarmDecayModifier = true,
}

-- Retorna a lista de diferencas entre um preset e o mundo atual (lista
-- vazia = bate perfeitamente), ou nil se a comparacao falhou por algum
-- motivo (ex: SandboxVars ainda nao existe nesse momento).
local function getPresetDifferences(preset)
    local diffs = {}
    local ok = pcall(function()
        for k, v in pairs(preset) do
            if not IGNORED_FIELDS[k] then
                collectDifferences(tostring(k), v, SandboxVars[k], diffs)
            end
        end
    end)
    if not ok then return nil end
    return diffs
end

-- Ordem de checagem e nomes de exibicao dos presets catalogados.
-- FALTAM Survivor e Builder (ver aviso no topo de UZIR_Presets.lua).
local LEAGUE_PRESETS = {
    {key = "APOCALYPSE", name = "Apocalypse"},
    {key = "EXTINCTION", name = "Extinction"},
    {key = "OUTBREAK", name = "Outbreak"},
    {key = "RISING", name = "Rising"},
}

-- Resultado fica em cache (as configuracoes de sandbox sao fixas pela
-- vida toda do save - nao faz sentido recalcular isso a cada frame).
local leagueCache = nil

-- Retorna (nomeDaLeague, valido). Se as configuracoes do mundo baterem
-- EXATAMENTE com um dos presets oficiais catalogados, retorna o nome
-- dele e "true". Caso contrario, retorna "Custom Sandbox" e "false".
--
-- DIAGNOSTICO: se nenhum preset bater EXATAMENTE, escrevemos no log do
-- jogo (procure por "[UZIR_LEAGUE_DEBUG]" no DebugLog mais recente em
-- Zomboid/Logs/) quais campos especificamente nao bateram com o preset
-- mais proximo - assim da pra saber se e um valor desatualizado na
-- nossa tabela (ver UZIR_Presets.lua) ou uma diferenca real.
function Tracker.getLeagueInfo()
    if leagueCache then
        return leagueCache.name, leagueCache.valid
    end

    local matchedName = nil
    local bestName = nil
    local bestDiffs = nil

    for _, entry in ipairs(LEAGUE_PRESETS) do
        local preset = UZIR.Presets and UZIR.Presets[entry.key]
        if preset then
            local diffs = getPresetDifferences(preset)
            if diffs then
                if #diffs == 0 then
                    matchedName = entry.name
                    break
                end
                if not bestDiffs or #diffs < #bestDiffs then
                    bestDiffs = diffs
                    bestName = entry.name
                end
            end
        end
    end

    local name = matchedName or "Custom Sandbox"
    local valid = matchedName ~= nil

    if not matchedName and bestDiffs then
        pcall(function()
            print("[UZIR_LEAGUE_DEBUG] No exact preset match. Closest: " .. tostring(bestName) .. " with " .. #bestDiffs .. " differing field(s):")
            for i, d in ipairs(bestDiffs) do
                if i <= 30 then -- limita para nao floodar o log
                    print("[UZIR_LEAGUE_DEBUG]   " .. d.path .. " -- preset=" .. d.expected .. " live=" .. d.actual)
                end
            end
        end)
    end

    leagueCache = {name = name, valid = valid}
    return name, valid
end

-- Game version string (ex: "42.20.0"), shown next to Valid/inValid.
--
-- ATTENTION: getCore():getVersionNumber() is known to be unreliable in
-- some builds (confirmed by other mod authors reporting it simply
-- doesn't work). We try a few candidates in order and cache whichever
-- one works first; if none work, we show "Unknown" instead of
-- crashing or showing a blank line.
local gameVersionCache = nil

function Tracker.getGameVersion()
    if gameVersionCache then return gameVersionCache end

    local candidates = {
        function() return getCore():getVersionNumber() end,
        function() return getCore():getGameVersion() end,
        function() return tostring(getCore():getVersion()) end,
    }

    for _, fn in ipairs(candidates) do
        local ok, result = pcall(fn)
        if ok and result and tostring(result) ~= "" then
            gameVersionCache = tostring(result)
            return gameVersionCache
        end
    end

    gameVersionCache = "Unknown"
    return gameVersionCache
end

-- ================== Char Info: peso do personagem ==================

-- Peso atual do personagem, no formato "Weight-85.5" (uma casa decimal).
--
-- ATENCAO (bug corrigido): a primeira tentativa usava player:getWeight()
-- direto, mas esse metodo pertence a hierarquia de IsoMovingObject e
-- retorna um valor de fisica/colisao (viemos a ver "0.3" na tela, sem
-- nenhuma relacao com o peso corporal de verdade). O peso que aparece
-- no painel de Info do personagem ("Peso 77") vem do sistema de
-- Nutricao, entao usamos player:getNutrition():getWeight() agora.
function Tracker.getWeightLine(player)
    player = player or Tracker.getPlayer()
    if not player then return "Weight-00.0" end

    local ok, weight = pcall(function() return player:getNutrition():getWeight() end)
    if not (ok and type(weight) == "number") then
        return "Weight-00.0"
    end

    return string.format("Weight-%.1f", weight)
end

-- Status do peso, mostrado so ao passar o mouse (ver UZIR_HUD.lua):
--   >= 85kg        -> "High Weight"  (vermelho)
--   75kg ate 84kg  -> "Regular"      (verde)
--   <= 74kg        -> "Under Weight" (vermelho)
-- Faixas definidas a pedido do autor; ajuste aqui se os limites do jogo
-- mudarem ou se quiser afinar os numeros depois de testar.
function Tracker.getWeightStatus(player)
    player = player or Tracker.getPlayer()
    if not player then return {text = "Regular", r = 0, g = 1, b = 0} end

    local ok, weight = pcall(function() return player:getNutrition():getWeight() end)
    if not (ok and type(weight) == "number") then
        return {text = "Regular", r = 0, g = 1, b = 0}
    end

    if weight >= 85 then
        return {text = "High Weight", r = 1, g = 0.2, b = 0.2}
    elseif weight >= 75 then
        return {text = "Regular", r = 0.2, g = 1, b = 0.2}
    else
        return {text = "Under Weight", r = 1, g = 0.2, b = 0.2}
    end
end

-- Indicador visual da tendencia de peso (icone + cor), pronto para o
-- HUD desenhar do lado do "Weight-XX.X":
--   engordando -> icone de seta para cima, verde
--   estavel    -> icone de circulo, amarelo
--   emagrecendo -> icone de seta para baixo, vermelho
--
-- HISTORICO: a primeira versao usava caracteres Unicode (bug: a fonte
-- do jogo nao tem esses glifos, sempre aparecia "?"). A segunda versao
-- passou a usar icones de textura, mas calculava a tendencia por conta
-- propria (amostra de peso a cada hora). Esta versao usa a fonte oficial
-- do jogo: a classe Nutrition ja expoe isIncWeight()/isIncWeightLot()/
-- isDecWeight(), os MESMOS flags que o proprio painel de Info do
-- personagem usa para desenhar a seta dele. Mais simples e mais preciso
-- que reinventar a logica.
function Tracker.getWeightIndicator(player)
    player = player or Tracker.getPlayer()
    if not player then
        return {icon = "UZIR_WeightStable", r = 1, g = 1, b = 1}
    end

    local okDec, decreasing = pcall(function() return player:getNutrition():isDecWeight() end)
    if okDec and decreasing then
        return {icon = "UZIR_WeightDown", r = 1, g = 1, b = 1}
    end

    local okInc, increasing = pcall(function() return player:getNutrition():isIncWeight() end)
    local okIncLot, increasingLot = pcall(function() return player:getNutrition():isIncWeightLot() end)
    if (okInc and increasing) or (okIncLot and increasingLot) then
        return {icon = "UZIR_WeightUp", r = 1, g = 1, b = 1}
    end

    return {icon = "UZIR_WeightStable", r = 1, g = 1, b = 1}
end

-- ================== Game Info: estacao atual do jogo ==================
-- ATENCAO: nao existe uma funcao nativa documentada "getSeason()" no
-- Lua do jogo. Calculamos a estacao a partir do mes atual, seguindo o
-- padrao de hemisferio norte (o jogo se passa em Knox County, Kentucky):
--   Winter: Dez, Jan, Fev   Spring: Mar, Abr, Mai
--   Summer: Jun, Jul, Ago   Autumn: Set, Out, Nov

local MONTH_NAMES = {
    "January", "February", "March", "April", "May", "June",
    "July", "August", "September", "October", "November", "December",
}

local SEASON_BY_MONTH = {
    [1] = "Winter", [2] = "Winter", [3] = "Spring", [4] = "Spring", [5] = "Spring",
    [6] = "Summer", [7] = "Summer", [8] = "Summer",
    [9] = "Autumn", [10] = "Autumn", [11] = "Autumn", [12] = "Winter",
}

local SEASON_RANGE = {
    Winter = {12, 2},
    Spring = {3, 5},
    Summer = {6, 8},
    Autumn = {9, 11},
}

-- Mes atual do jogo (1-12). getGameTime():getMonth() retorna 0-11 (base
-- 0), por isso somamos 1. Se por algum motivo a chamada falhar, caimos
-- em Janeiro (1) em vez de quebrar.
local function getCurrentGameMonth()
    local ok, month0 = pcall(function() return getGameTime():getMonth() end)
    if ok and type(month0) == "number" then
        return month0 + 1
    end
    return 1
end

-- Retorna: nome da estacao, mes atual, mes de inicio da estacao, mes de
-- fim da estacao (todos numeros 1-12).
function Tracker.getSeasonInfo()
    local currentMonth = getCurrentGameMonth()
    local season = SEASON_BY_MONTH[currentMonth] or "Spring"
    local range = SEASON_RANGE[season]
    return season, currentMonth, range[1], range[2]
end

-- ================== XP (QMTR: Quadro de Monitoramento em Tempo Real) ==================
-- O jogo ja mantem o XP total e por pericia calculado (getXp():getTotalXp()
-- e getXp():getXP(perk)) - diferente de kills/fogo/veiculo, aqui NAO
-- precisamos manter nosso proprio total. O que precisamos fazer por
-- conta propria e:
--   1. Classificar cada pericia numa categoria ampla (o jogo nao expoe
--      isso pronto).
--   2. Registrar CADA evento de ganho de XP (nao so o total), para o
--      relatorio diario listar "Manutencao +200 XP" etc.
--   3. Manter uma fila de eventos recentes, para o HUD desenhar os
--      flutuantes de XP em tempo real (a fila e consumida e limpa a
--      cada frame pelo HUD, entao NAO fica salva no ModData - e so
--      um estado de UI transitorio, nao dado de progresso).

-- ATUALIZADO para a B42.20 Stable (lancada em 29/07/2026), que trouxe
-- "novas pericias" (profissoes como Blacksmith, DIY Expert, Rancher, e
-- o sistema de criacao de animais). A lista de nomes novos veio do mod
-- de referencia "OSRS XP Drops Retextured" (seus icones cobrem
-- praticamente toda pericia do jogo, incluindo as novas do B42).
-- Pericias fora desta tabela caem em "Other" (ver getPerkCategory) -
-- nao quebra nada, so fica sem categoria especifica ate catalogarmos.
local PERK_CATEGORY = {
    -- Passivas
    Strength = "Passive", Fitness = "Passive",
    -- Combate corpo a corpo
    Blunt = "Combat", SmallBlunt = "Combat", LongBlade = "Combat", SmallBlade = "Combat",
    Axe = "Combat", Spear = "Combat", Maintenance = "Combat",
    -- Armas de fogo
    Aiming = "Firearms", Reloading = "Firearms",
    -- Agilidade
    Sprinting = "Agility", Nimble = "Agility", Sneaking = "Agility", Sneak = "Agility",
    Lightfoot = "Agility", Lockpicking = "Agility",
    -- Oficios
    Carpentry = "Crafting", Woodwork = "Crafting", Cooking = "Crafting", Farming = "Crafting",
    Doctor = "Crafting", Electricity = "Crafting", Mechanics = "Crafting",
    MetalWelding = "Crafting", Metalworking = "Crafting", Tailoring = "Crafting",
    Blacksmith = "Crafting", Carving = "Crafting", Cleaning = "Crafting", Efficiency = "Crafting",
    Glassmaking = "Crafting", Husbandry = "Crafting", Masonry = "Crafting", Pottery = "Crafting",
    -- Sobrevivencialista
    Fishing = "Survivalist", Trapping = "Survivalist", Foraging = "Survivalist",
    Butchering = "Survivalist", Flintknapping = "Survivalist", PlantScavenging = "Survivalist",
    Scavenging = "Survivalist", Tracking = "Survivalist",
    -- Veiculos (nova na B42)
    Driving = "Vehicles",
    -- Estilo de vida / bem-estar (novas na B42)
    Dancing = "Lifestyle", Meditation = "Lifestyle", Music = "Lifestyle",
}

-- Nome de exibicao da pericia.
--
-- HISTORICO (bug corrigido): a primeira tentativa tentava ler campos do
-- proprio objeto Perk recebido no evento (perk.name, perk:getName(),
-- tostring(perk)) - na pratica, isso voltava vazio/invalido, e o nome
-- da pericia sumia dos flutuantes de XP. A solucao mais confiavel nao
-- e tentar EXTRAIR o nome do objeto, e sim COMPARAR o objeto recebido
-- contra as entradas conhecidas da tabela global "Perks" (a mesma usada
-- em getPerkXP/getPerkLevelByName) ate achar qual bate - assim nao
-- dependemos de nenhum campo/metodo incerto do objeto Perk.
local function getPerkDisplayName(perk)
    local ok, found = pcall(function()
        for name, _ in pairs(PERK_CATEGORY) do
            if Perks[name] == perk then
                return name
            end
        end
        return nil
    end)
    if ok and found then return found end

    -- Fallbacks antigos, mantidos so como ultimo recurso caso a pericia
    -- ganha XP nao esteja na nossa tabela PERK_CATEGORY (pericia nova
    -- que ainda nao catalogamos).
    local ok1, name1 = pcall(function() return perk.name end)
    if ok1 and type(name1) == "string" and name1 ~= "" then return name1 end

    local ok2, name2 = pcall(function() return perk:getName() end)
    if ok2 and type(name2) == "string" and name2 ~= "" then return name2 end

    return "Unknown"
end

local function getPerkCategory(perkName)
    return PERK_CATEGORY[perkName] or "Other"
end

-- Fila de eventos de XP recentes, so em memoria (nao persistida). O HUD
-- consome (drainXPEvents) e agrupa em flutuantes a cada frame.
local pendingXPEvents = {}

function Tracker.drainXPEvents()
    local events = pendingXPEvents
    pendingXPEvents = {}
    return events
end

-- Acumula o XP de hoje por categoria/pericia. Mesma estrutura usada para
-- os kills validos: { order = {...}, categories = { Cat = { skills = { {name, amount}, ... } } } }
-- Privada: so onAddXP (deste arquivo) deveria chamar isso.
local function recordXPGain(player, category, skillName, amount)
    if not player or not category or not skillName then return end
    local modData = player:getModData()
    if not modData.UZIR_todayXP then
        modData.UZIR_todayXP = {order = {}, categories = {}}
    end
    local today = modData.UZIR_todayXP

    local cat = today.categories[category]
    if not cat then
        cat = {skills = {}}
        today.categories[category] = cat
        table.insert(today.order, category)
    end

    local entry = nil
    for _, s in ipairs(cat.skills) do
        if s.name == skillName then
            entry = s
            break
        end
    end
    if not entry then
        entry = {name = skillName, amount = 0}
        table.insert(cat.skills, entry)
    end
    entry.amount = entry.amount + amount
end

-- Chamado pelo jogo toda vez que o personagem local ganha XP em
-- qualquer pericia. Privada: so o proprio arquivo precisa reagir a isso.
local function onAddXP(character, perk, amount)
    local player = Tracker.getPlayer()
    if not player or character ~= player then return end
    if not amount or amount <= 0 then return end

    local skillName = getPerkDisplayName(perk)
    local category = getPerkCategory(skillName)

    recordXPGain(player, category, skillName, amount)

    -- Guarda qual foi a ULTIMA pericia a ganhar XP, para o bloco QMTR
    -- mostrar "so ela" (a pedido do autor, no padrao do mod "Show XP
    -- Gain"). Persistido (nao so em memoria) para sobreviver a troca de
    -- tela/painel.
    local modData = player:getModData()
    modData.UZIR_lastTrainedSkill = skillName
    modData.UZIR_lastTrainedCategory = category

    table.insert(pendingXPEvents, {
        skillName = skillName,
        category = category,
        amount = amount,
        timeMs = Util.nowMs(),
    })
end

-- XP total do personagem (todas as pericias somadas).
--
-- HISTORICO (bug corrigido): a primeira versao so lia getXp():getTotalXp(),
-- que na pratica voltou 0 o tempo todo mesmo com XP sendo ganho de
-- verdade (confirmado por comparacao com outro mod rodando em paralelo).
-- A segunda tentativa usou um contador proprio (UZIR_totalXPTracked),
-- mas isso so soma XP ganho DEPOIS que esta versao do mod comecou a
-- rodar - personagens que ja tinham XP acumulado antes ficariam com o
-- total errado (faltando tudo que já existia).
--
-- A solucao final: somamos o XP REAL de cada pericia catalogada
-- (getXp():getXP(perk), que sabemos funcionar - e a mesma chamada que
-- ja usamos com sucesso em getPerkXP) direto do jogo, toda vez que
-- alguem pede o total. Isso sempre reflete o valor verdadeiro atual,
-- nao importa se o personagem ja tinha XP antes de instalar o mod.
function Tracker.getTotalXP(player)
    player = player or Tracker.getPlayer()
    if not player then return 0 end

    local ok, sum = pcall(function()
        local xpObj = player:getXp()
        local total = 0
        for perkName, _ in pairs(PERK_CATEGORY) do
            local perk = Perks[perkName]
            if perk then
                local v = xpObj:getXP(perk)
                if type(v) == "number" then
                    total = total + v
                end
            end
        end
        return total
    end)
    if ok and type(sum) == "number" then
        return sum
    end

    return 0
end

-- XP acumulado numa pericia especifica (busca pelo nome, ex: "Woodwork").
-- Precisa achar o objeto Perks.<nome> correspondente - tentamos indexar
-- a tabela global "Perks" pelo nome recebido.
function Tracker.getPerkXP(player, perkName)
    player = player or Tracker.getPlayer()
    if not player or not perkName then return 0 end

    local ok, xp = pcall(function()
        local perk = Perks[perkName]
        return player:getXp():getXP(perk)
    end)
    if ok and type(xp) == "number" then
        return xp
    end
    return 0
end

-- Nivel atual (0-10) de uma pericia especifica, pelo nome.
function Tracker.getPerkLevelByName(player, perkName)
    player = player or Tracker.getPlayer()
    if not player or not perkName then return 0 end

    local ok, level = pcall(function()
        local perk = Perks[perkName]
        return player:getPerkLevel(perk)
    end)
    if ok and type(level) == "number" then
        return level
    end
    return 0
end

-- Nome da ultima pericia a ganhar XP (ou nil se nenhuma ainda nesta
-- partida). E o que o bloco QMTR usa para decidir qual pericia mostrar.
function Tracker.getLastTrainedSkill(player)
    player = player or Tracker.getPlayer()
    if not player then return nil end
    return player:getModData().UZIR_lastTrainedSkill
end

-- Progresso de NIVEL de uma pericia especifica (no padrao do mod de
-- referencia "Show XP Gain"):
--   level        - nivel atual (0-10)
--   currentXP    - XP acumulado DENTRO do nivel atual
--   nextLevelXP  - XP necessario para completar o nivel atual e subir (nil se ja no nivel 10, o maximo)
--   remainingXP  - nextLevelXP - currentXP (nil se ja no nivel maximo)
--
-- HISTORICO (bug corrigido, duas tentativas anteriores):
--   1) Usar getXp():getXP(perk) direto como "XP atual" - batia certo
--      so para pericias no nivel 0 (por coincidencia, ja que nao ha
--      nivel anterior a descontar). Para pericias ja niveladas, vinha
--      bem maior que o valor real.
--   2) Rastrear XP por conta propria (somando os eventos AddXP,
--      zerando a cada level up) - corrigia o problema acima, mas
--      comecava sempre do ZERO ao instalar o mod, perdendo qualquer
--      progresso que a pericia ja tinha antes.
--
-- A causa raiz (descoberta comparando com o codigo-fonte do mod de
-- referencia "OSRS XP Drops Retextured", que faz essa mesma conta
-- corretamente): getXp():getXP(perk) retorna o XP ACUMULADO DESDE A
-- CRIACAO DO PERSONAGEM (nunca reseta ao subir de nivel) - nosso valor
-- lido na tentativa 1 estava CERTO, so faltava subtrair o custo de
-- cada nivel ja completado. E o custo de cada nivel individualmente
-- vem de perk:getXp1() ate perk:getXp10() (dez getters, um por nivel -
-- NAO de getXpForLevel(), que usavamos antes).
--
-- BASEADO NO MOD EXEMPLO "OSRS XP Drops Retextured" (funcoes
-- ISExpBar:cleanExp/getExpCurrent/getExpMax do arquivo ISExpBar.lua):
function Tracker.getSkillLevelProgress(player, skillName)
    player = player or Tracker.getPlayer()
    if not player or not skillName then return 0, 0, nil, nil end

    local ok, level, currentXP, nextLevelXP = pcall(function()
        local perk = Perks[skillName]
        local lvl = player:getPerkLevel(perk)
        local rawXP = player:getXp():getXP(perk)

        -- Custo INDIVIDUAL de cada nivel (nao acumulado) - mesma
        -- tabela que o mod de referencia monta em ISExpBar:new().
        local costPerLevel = {
            perk:getXp1(), perk:getXp2(), perk:getXp3(), perk:getXp4(), perk:getXp5(),
            perk:getXp6(), perk:getXp7(), perk:getXp8(), perk:getXp9(), perk:getXp10(),
        }

        -- Mesma logica de ISExpBar:cleanExp(): desconta do XP bruto o
        -- custo de cada nivel ja completado (1 ate o nivel atual).
        local withinLevel = rawXP
        for i = 1, lvl do
            withinLevel = withinLevel - costPerLevel[i]
        end

        -- Mesma logica de ISExpBar:getExpMax(): custo do PROXIMO nivel
        -- e so o valor daquela posicao na tabela, sem subtracao.
        local nextXP = nil
        if lvl < 10 then
            nextXP = costPerLevel[lvl + 1]
        end

        return lvl, withinLevel, nextXP
    end)

    if not ok then return 0, 0, nil, nil end

    local remainingXP = nil
    if nextLevelXP then
        remainingXP = nextLevelXP - currentXP
    end

    return level, currentXP, nextLevelXP, remainingXP
end

-- XP ganho HOJE, por categoria/pericia (ainda "ao vivo", muda a cada
-- ganho de XP). Assim como getTodayValidBreakdown, o Sleep Report le o
-- snapshot congelado do historico, nao isto aqui diretamente.
function Tracker.getTodayXPBreakdown(player)
    player = player or Tracker.getPlayer()
    if not player then return {order = {}, categories = {}} end
    return player:getModData().UZIR_todayXP or {order = {}, categories = {}}
end

-- ================== Registro dos eventos do jogo ==================

Events.OnCreatePlayer.Add(function(playerIndex, player)
    initPlayerData(player)
end)

Events.EveryHours.Add(onEveryHour)
Events.OnObjectCollide.Add(onObjectCollide)
Events.OnHitZombie.Add(onHitZombie)
Events.OnZombieDead.Add(onZombieDead)
Events.AddXP.Add(onAddXP)
