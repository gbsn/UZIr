# UZIr — Ultimate Zombie Interconnected Ranking

*Este APP é idealizado por oQuasi e Claude desde 20072026 - Não permitimos a cópia. Divirta-se! Todos os Direitos Reservados*

## O que é isso?

Bora direto ao ponto: o UZIr transforma cada partida sua de Project Zomboid num placar de verdade. Zumbi morreu, conta. Personagem sobrevivendo, conta. Tudo aparece na tela em tempo real, e assim que seu personagem dorme, sai um relatório completo do dia — tipo um extrato bancário, só que de sobrevivência \o/

## Por quê?

Sejamos sinceros: Zomboid é surreal, mas cada save vive isolado no seu próprio mundinho. Ninguém sabe se seu personagem de 3 meses vivo é "bom" perto do resto da galera, ou se aquele atropelamento генial contou pra alguma coisa. O UZIr existe pra resolver isso — primeiro capturando esses números direitinho, dentro do jogo (é o que já temos hoje ✓), e depois — ainda vem por aí — conectando tudo isso num lugar só, onde todo mundo possa comparar quem sobreviveu mais e matou mais zumbi.

## Como está sendo construído

Aqui não tem lançamento "big bang". Cada função nova é testada dentro do jogo de verdade antes de virar parte oficial do mod, e cada decisão — o que funcionou, o que quebrou, o que precisou de ajuste — fica registrada aqui no repositório. Devagar e sempre.

## Roadmap — pra onde isso vai

Só um aviso antes de qualquer coisa: isso aqui é uma intenção, não uma promessa com prazo. As coisas vão saindo na medida em que forem testadas e aprovadas dentro do jogo de verdade — sem pressa, sem "em breve" genérico.

### ✓ Já rolando
- HUD na tela com kills, tempo de vida e causa da morte (fogo/atropelamento separados do oficial)
- Relatório diário automático ao dormir, com histórico navegável
- Tudo local — nada sai do seu save ainda

### ⧗ Em ajuste fino
- Classificação de arma (hoje qualquer arma à distância vira "Fire Gun", incluindo arco — precisa refinar)
- Detecção de atropelamento (não existe um jeito nativo do jogo pra isso, então é uma aproximação que ainda tá sendo testada)

### ○ Ainda por vir
- Exportar os dados do save pra um serviço externo — o pulo do gato do projeto
- Site de ranking público, pra comparar resultados com outros jogadores
- Separar rankings por modo de jogo (Apocalypse, Survivor, Builder...) — pra você só competir contra quem joga do mesmo jeito
- Publicação oficial no Steam Workshop

## A história por trás do código

Tudo começou com uma pergunta simples: como saber se seu personagem de meses vivo é bom, se cada save de Zomboid vive isolado no próprio mundinho? Dali nasceu a ideia do UZIr — um contador de kills e tempo de vida que um dia vira ranking de verdade.

**A primeira versão** foi só um painel simples: zumbis mortos, tempo vivo. Simples no papel, mas o Project Zomboid tinha outros planos. A primeira tentativa de instalação nem apareceu na lista de mods — a pasta estava um nível errado dentro de `Zomboid/mods/`. Resolvido isso, esbarramos numa pegadinha própria do Build 42: diferente do 41, ele exige uma estrutura dividida entre `common/` (o código) e `42/` (só o manifesto) — e a gente tinha feito exatamente o contrário. Ajustado, o mod apareceu... em vermelho, marcado como quebrado. Foi aí que descobrimos, comparando com outro mod funcionando, que uma linha `require=` vazia no `mod.info` estava sendo lida como "depende de um mod com nome em branco". Tirando essa linha, finalmente rodou.

**Depois veio o visual.** Renomeamos pra UZIR, demos a cara "UZI" ao painel, e fomos ajustando: ícone de infectado, transparência, um "+1" flutuante toda vez que um zumbi cai. Foi nessa fase que percebemos algo que o próprio jogo esconde: zumbi morto por fogo não conta pro kill count oficial. Em vez de brigar com isso, decidimos abraçar — e passamos a rastrear fogo e atropelamento como categorias próprias, separadas do total "oficial".

**O relatório de sono** trouxe o bug mais chato do projeto: os números zeravam sozinhos enquanto o relatório estava aberto. A causa era o reset acontecer à meia-noite do jogo, que podia cair bem no meio do sono do personagem. A solução foi mudar o gatilho do reset pro momento exato em que o personagem dorme, não mais pro relógio do mundo — e o bug sumiu de vez. Depois vieram o histórico navegável entre dias, o botão de fechar manual, e uma tentativa de pausar o jogo ao acordar que não funcionou 100% e ficou registrada como pendência, não escondida.

**Por fim, uma auditoria de segurança séria.** Reescrevemos boa parte do código pra reduzir o que outros mods (ou scripts mal-intencionados) conseguiriam mexer nos nossos dados, corrigimos um bug real de reaproveitamento de instância de zumbi que podia inflar kills por engano, e documentamos com todas as letras o que este mod PODE e NÃO PODE garantir em termos de integridade — sem fingir uma proteção que só existiria de verdade no futuro servidor do ranking.

Cada etapa dessas foi testada dentro do jogo antes de seguir pra próxima. Nenhuma delas acertou de primeira — e tudo bem, é assim que se constrói isso.
