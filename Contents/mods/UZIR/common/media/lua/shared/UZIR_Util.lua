-- Este APP e idealizado por oQuasi e Claude desde 20072026 - Nao permitimos a copia. Divirta-se! Todos os Direitos Reservados
--
-- UZIR_Util.lua
--
-- Funcoes pequenas e reutilizadas por mais de um arquivo do UZIR. Fica em
-- "shared" (carrega antes de "client") justamente para garantir que ja
-- existe quando UZIR_Tracker.lua e UZIR_HUD.lua rodarem.
--
-- ================================================================
-- MODELO DE SEGURANCA DO UZIR - LEIA ANTES DE MEXER NOS OUTROS ARQUIVOS
-- ================================================================
-- O UZIR guarda todos os dados no ModData do proprio save (arquivo local
-- do jogador). Isso significa, sem meio-termo, que:
--
--   1. Qualquer pessoa com acesso ao save pode editar esses numeros na
--      mao (editor de save, ferramentas externas, etc).
--   2. Qualquer OUTRO mod carregado junto (incluindo "cheat menus") pode
--      chamar as funcoes publicas do UZIR diretamente, ja que "UZIR" e
--      uma tabela global comum a todos os mods no mesmo processo Lua.
--   3. O proprio modo debug/cheat nativo do jogo pode gerar kills e
--      progresso que nao refletem uma partida "limpa".
--
-- NENHUMA dessas coisas pode ser impedida de verdade por um mod Lua
-- client-side. Um "checksum" ou "assinatura" caseira NAO resolveria
-- isso - o codigo e aberto, entao dava pra recalcular o checksum depois
-- de editar os valores a mao. Isso seria seguranca de fachada, entao
-- deliberadamente NAO implementamos nada do tipo.
--
-- O que este mod faz, de forma honesta, para reduzir o problema:
--   - Expoe o MINIMO possivel de funcoes que alteram dados (a maioria
--     das funcoes do Tracker que gravam informacao sao "local", nao
--     acessiveis de fora do arquivo).
--   - Sanitiza numeros lidos do ModData (nunca confia cegamente que um
--     valor salvo e um numero valido e nao-negativo).
--   - Marca a sessao quando o modo debug/cheat do jogo e detectado
--     (UZIR.Util.isDebugActive), do mesmo jeito que o proprio jogo ja
--     desativa conquistas quando isso acontece.
--
-- A VALIDACAO DE VERDADE (a que realmente impede trapaca) só pode
-- acontecer no futuro, do lado do SERVIDOR do site de ranking: checagem
-- de plausibilidade (kills por hora, tempo de jogo vs. progresso
-- reportado, etc). Isso fica documentado aqui para quando chegarmos
-- nessa fase do projeto.
-- ================================================================

UZIR = UZIR or {}
UZIR.Util = UZIR.Util or {}

local Util = UZIR.Util

-- Relogio em milissegundos, usado para animacoes e janelas de tempo
-- (ex: "esse zumbi foi atingido por um veiculo ha quanto tempo?").
-- getTimestampMs() e a funcao nativa esperada; se por algum motivo nao
-- existir na build atual, caimos para os.clock() (menos preciso, mas
-- evita que o mod quebre).
function Util.nowMs()
    local ok, ts = pcall(function() return getTimestampMs() end)
    if ok and ts then return ts end
    return os.clock() * 1000
end

-- Converte qualquer valor lido do ModData num inteiro nao-negativo
-- seguro para exibir. Protege contra:
--   - ModData corrompido ou editado a mao com lixo (string, nil, negativo)
--   - Bugs futuros que gravem algo inesperado no lugar de um numero
-- Isso NAO detecta/impede valores editados para CIMA (ex: alguem setar
-- fireKills = 99999 continua sendo um numero "valido" do ponto de vista
-- desta funcao) - crucialmente, essa e uma limitacao que so validacao no
-- servidor consegue cobrir. Isto aqui e so higiene de dados.
function Util.sanitizeCount(value)
    if type(value) ~= "number" then return 0 end
    if value ~= value then return 0 end -- NaN nunca e igual a si mesmo
    if value < 0 then return 0 end
    return math.floor(value)
end

-- Tenta detectar se o modo debug/cheat do jogo esta (ou esteve) ativo.
-- ATENCAO: assim como outras chamadas experimentais deste mod, o nome
-- exato da funcao nativa pode variar entre builds; tentamos algumas
-- possibilidades conhecidas em sequencia. Se nenhuma existir, assumimos
-- "nao ativo" (nao bloqueia nada, so deixa de marcar a sessao).
function Util.isDebugActive()
    local candidates = {
        function() return isDebugEnabled() end,
        function() return getDebug() end,
        function() return getCore():getDebug() end,
    }
    for _, fn in ipairs(candidates) do
        local ok, result = pcall(fn)
        if ok and result then return true end
    end
    return false
end

-- ================================================================
-- CODIFICADOR JSON MINIMO, PROPRIO
-- ================================================================
-- Escrito do zero (nao depende de nenhuma biblioteca externa que
-- possa ou nao estar disponivel na instalacao do jogador) porque
-- precisamos transformar as tabelas Lua do Tracker em texto JSON para
-- o Programa Auxiliar conseguir ler. So cobre os tipos que realmente
-- usamos no formato "Camada 1" (numero, texto, booleano, nulo, lista,
-- e tabela com chaves texto) - nao e um codificador JSON genérico
-- para qualquer uso.

local function jsonEscapeString(s)
    s = tostring(s)
    s = s:gsub('\\', '\\\\')
    s = s:gsub('"', '\\"')
    s = s:gsub('\n', '\\n')
    s = s:gsub('\r', '\\r')
    s = s:gsub('\t', '\\t')
    return s
end

-- Decide se uma tabela Lua deve virar uma LISTA JSON ([...]) ou um
-- OBJETO JSON ({...}) - Lua nao distingue os dois nativamente, entao
-- olhamos se as chaves sao numeros sequenciais comecando em 1.
local function isArrayLike(t)
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    if count == 0 then return true end -- tabela vazia vira [] por padrao
    for i = 1, count do
        if t[i] == nil then return false end
    end
    return true
end

function Util.encodeJSON(value)
    local valueType = type(value)

    if value == nil then
        return "null"
    elseif valueType == "boolean" then
        return tostring(value)
    elseif valueType == "number" then
        if value ~= value then return "0" end -- NaN nao existe em JSON
        return tostring(value)
    elseif valueType == "string" then
        return '"' .. jsonEscapeString(value) .. '"'
    elseif valueType == "table" then
        if isArrayLike(value) then
            local parts = {}
            for i, v in ipairs(value) do
                parts[i] = Util.encodeJSON(v)
            end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            local parts = {}
            local i = 0
            for k, v in pairs(value) do
                i = i + 1
                parts[i] = '"' .. jsonEscapeString(k) .. '":' .. Util.encodeJSON(v)
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    end

    return "null" -- tipo nao suportado (function, userdata, etc) - nunca deveria acontecer aqui
end
