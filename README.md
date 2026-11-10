# Automação de Offboarding: Desk Manager → Active Directory → Entra ID

> Caso de estudo de uma automação de ponta a ponta que elimina o bloqueio manual de acessos no desligamento de colaboradores, reduzindo o tempo de resposta de horas/dias para **menos de 5 minutos**, com rastreabilidade completa e privilégio mínimo de acesso.

*Nomes de empresa, domínios, colaboradores e identificadores internos neste documento são fictícios, criados para fins de portfólio. A arquitetura, os desafios técnicos e as soluções descritos refletem um projeto real.*

---

## Contexto

A **Aurora Agro** (nome fictício) processa o desligamento de colaboradores através de um chamado aberto pelo RH na plataforma de Service Desk (Desk Manager). Antes desta automação, o bloqueio de acessos — Active Directory, e-mail, VPN, sistemas internos — dependia de um analista de TI executar cada passo manualmente após ler o chamado, com tempo de resposta variável e sujeito a esquecimento.

**Objetivo:** transformar a abertura do chamado de Desligamento em um gatilho que bloqueia automaticamente o acesso do colaborador, sem intervenção humana, mantendo total auditabilidade — e, 60 dias depois, arquivar a conta numa OU de Inativos.

## Arquitetura

```
┌─────────────┐      ┌──────────────────┐      ┌───────────────────┐      ┌─────────────┐
│  RH abre    │─────▶│  iPaaS (Maestro)  │─────▶│  Agente on-premises │─────▶│   AD Local  │
│  chamado    │      │  - roteia p/grupo  │      │  (PowerShell,       │      │             │
│  Desligto.  │      │  - gera checklist  │      │   Tarefa Agendada,  │      └──────┬──────┘
└─────────────┘      └──────────────────┘      │   polling 5 min)    │             │
                                                  └───────────────────┘             │ Entra Connect
                                                                                     │ (sync automático)
                                                                                     ▼
                                                                              ┌─────────────┐
                                                                              │  Entra ID   │
                                                                              │  (nuvem)    │
                                                                              └─────────────┘
```

**Por que polling e não webhook direto para o AD?** O Active Directory on-premises não possui endpoint público. A abordagem escolhida foi um agente PowerShell rodando como Tarefa Agendada em um servidor com RSAT, consultando a API do Service Desk a cada 5 minutos — evitando expor a rede interna e sem depender de VPN site-to-site adicional.

### Componentes

| Componente | Função |
|---|---|
| **Fluxo iPaaS (low-code)** | Disparado por webhook na abertura do chamado; roteia para o grupo responsável e gera um checklist informativo na interação |
| **Agente on-premises (PowerShell)** | Consulta a API do Service Desk, localiza chamados pendentes, resolve o colaborador via matrícula (`EmployeeID`), executa `Disable-ADAccount`, registra o resultado de volta no chamado |
| **Entra Connect** | Sincroniza a desativação do AD para o Entra ID automaticamente — nenhuma chamada à Graph API foi necessária |
| **Rotina de Inativos (PowerShell)** | Segunda tarefa agendada, diária: move para a OU de Inativos as contas desabilitadas há mais de 60 dias, usando o carimbo gravado no momento do bloqueio |

### Correlação de identidade

A matrícula do colaborador (campo já preenchido no chamado pelo RH) é usada como chave de correlação com o atributo `EmployeeID` no Active Directory — evitando qualquer dependência de nome ou e-mail, que podem ter variações/duplicidade.

### Roteamento por categoria e tratamento de falhas

- **Categoria de acessos (segurança):** o orquestrador (Maestro) encaminha o chamado ao time de Segurança da Informação com o checklist; o agente on-prem bloqueia a conta, carimba a data e encerra o chamado.
- **Categoria de sistemas:** o chamado é apenas direcionado ao time de Sistemas (Nível 1), que trata e encerra manualmente. O agente de bloqueio ignora esses chamados, pois só enxerga os que estão em Andamento no grupo de Segurança.
- **Conta não encontrada no AD:** nada é bloqueado. O chamado vai para a fila da Infraestrutura Nível 1, em *Aguardando Atendimento* e **sem operador** (a interação da API sempre atribui o chamado a quem a executa, então uma edição posterior limpa o operador), com o motivo registrado, para alguém do time puxar.
- **Matrícula duplicada, inválida ou nome divergente:** nada é bloqueado. O chamado permanece em *Andamento* com o motivo registrado, e um e-mail de alerta (título `[Desligamento de Usuário] Ação manual necessária - chamado <número>`) é enviado à equipe de infraestrutura via Microsoft Graph, a partir de um segundo Maestro.
- **Bloqueio feito, mas carimbo não gravado:** o chamado é encerrado e um segundo texto de e-mail (`Pendência após encerramento`) avisa que a conta não será movida sozinha para Inativos.
- **Contas protegidas (`AdminCount = 1`):** o AD substitui as permissões delegadas nelas (AdminSDHolder). A decisão foi **não** abrir permissão no AdminSDHolder para a conta de serviço, e tratar esses casos manualmente com aviso automático. Veja [a decisão e o porquê](docs/decisao-adminsdholder.md).
- **Falha na partida do agente:** um registro de inicialização, separado do log principal, anota se o script começou e qualquer erro anterior ao log (por exemplo, variável de ambiente ausente), sem gravar valores de chaves.
- **Matrícula com zeros à esquerda:** a busca no AD aceita as variantes (ex.: `1652` no chamado e `01652` no AD) e só prossegue se houver exatamente uma conta correspondente.
- **Instabilidade da API do Service Desk:** as leituras (autenticação, listagem, histórico, campos extras) são repetidas até 3 vezes, com espera de 10 s, em falhas transitórias (timeout, 429, 502, 503, 504). Erros definitivos falham de imediato, e o alerta só é enviado se as tentativas se esgotarem. A gravação que encerra o chamado não é repetida, para não duplicar interações.

## Ciclo de vida: arquivamento após 60 dias

O bloqueio não é o fim do ciclo. Para saber *quando* uma conta completou 60 dias de desligada sem depender do histórico do Service Desk, o agente grava um **carimbo na própria conta** no momento do bloqueio (atributo de texto livre `info`):

```
[OFFBOARDING-AUTO] 2026-10-02 chamado=0000-000000
```

Uma segunda tarefa agendada, diária, faz a varredura:

1. Lista contas **desabilitadas** na árvore de colaboradores que tenham o carimbo;
2. Seleciona as com 60 dias ou mais desde a data do carimbo;
3. Move cada uma para a OU de Inativos e registra a ação em log.

Salvaguardas de projeto:

- **Simulação por padrão** — sem o parâmetro de execução, o script apenas lista o que moveria;
- **Nunca move conta habilitada** (ex.: colaborador recontratado);
- Só considera contas com o carimbo da automação — contas bloqueadas manualmente ficam de fora;
- Parâmetros de teste (`-Dias`, `-SomenteMatricula`) permitem validar em uma única conta sem risco para as demais.

**Decisão de projeto — OU de Inativos fora do escopo do Entra Connect.** Ao mover a conta para uma OU não sincronizada, o Entra Connect a trata como removida: ela vai para a lixeira do Entra ID (restaurável por 30 dias) e depois é excluída em definitivo, liberando a licença. Isso foi **validado em teste**. Consequência operacional: caixa de e-mail e OneDrive existem por cerca de 90 dias após o desligamento (60 + 30), e qualquer política de retenção precisa agir dentro dessa janela.

## Modelo de segurança

Um dos pontos centrais do projeto foi garantir que a automação rodasse com o **menor privilégio possível**:

- Conta de serviço dedicada, **sem** associação a grupos administrativos amplos (removida de Domain Admins durante o hardening)
- Delegação de permissão granular via ACL do AD, restrita a:
  - `WriteProperty` (habilitar/desabilitar conta e gravar o carimbo) e `ReadProperty` (ler o atributo de matrícula) — nada além disso
  - Para o arquivamento, somente duas permissões a mais: `CreateChild` (objetos *user*) na OU de Inativos e `DeleteChild` (objetos *user*) nas OUs de origem
  - Escopo limitado às Unidades Organizacionais (OUs) onde efetivamente existem contas de colaboradores
- Toda ação (sucesso ou falha) é registrada como comentário no próprio chamado, com timestamp e conta afetada — auditoria nativa, sem sistema de log adicional

## Desafios técnicos e como foram resolvidos

Esse projeto envolveu bem mais troubleshooting de infraestrutura do que o esperado inicialmente. Vale documentar porque cada um foi um aprendizado sobre comportamentos não-óbvios do Windows Server / Active Directory / plataformas de iPaaS:

1. **Herança de ACL quebrada em cascata.** Ao delegar a permissão numa OU pai, a alteração simplesmente não "descia" para os colaboradores. Causa raiz: várias sub-OUs (uma por departamento) tinham a herança de permissões **explicitamente desabilitada** — um padrão de isolamento administrativo por área que não era documentado. Solução: mapear programaticamente todas as OUs com `AreAccessRulesProtected = True` na árvore relevante e aplicar a delegação diretamente em cada uma.

2. **Atributo confidencial silenciosamente vazio.** Mesmo após corrigir a ACL de escrita, a busca pela matrícula (`Get-ADUser -Filter`) não retornava nada — mas uma consulta direta por identidade funcionava, só que com o campo vazio. O atributo estava marcado como confidencial no schema, exigindo uma permissão de **leitura** (`ReadProperty`) separada da permissão de escrita já concedida.

3. **Direito de logon perdido ao reduzir privilégios.** Depois de remover a conta de serviço do grupo administrativo, a Tarefa Agendada parou de disparar silenciosamente — sem erro visível no Task Scheduler além de "0x80070529". Causa: o direito local **"Log on as a batch job"**, concedido implicitamente por associação ao grupo removido, precisou ser delegado explicitamente via política de segurança local.

4. **Comportamento não-documentado do roteamento por grupo na plataforma iPaaS.** O campo de transferência de grupo na API era, na prática, ignorado — o grupo resultante da interação era sempre determinado pela identidade (e o grupo principal) do operador autenticado que executava a chamada, não pelo valor enviado no payload. Resolvido escolhendo uma credencial de automação cujo grupo principal já era o grupo de destino correto.

5. **Inconsistência entre múltiplos Domain Controllers.** Em um ambiente com 5 DCs, criar uma ACE em um DC e validá-la consultando outro (sem replicação ainda concluída) fez a alteração "sumir" temporariamente — resolvido fixando um DC único durante toda a fase de criação/validação, seguido de `repadmin /syncall` para propagar globalmente.

6. **Nomes com acento derrubavam o registro do resultado.** Ao gravar a interação no chamado, o corpo JSON era enviado como string simples; nomes com "Ç" ou acentos geravam erro 500 na API, e o ciclo terminava sem comentário nem alerta. Solução: enviar o corpo em bytes UTF-8 com `charset=utf-8` e isolar a falha por chamado, sem derrubar o ciclo.

7. **Campo de grupo do iPaaS validado só pela resposta, não pelo efeito.** A variante do fluxo para o time de Sistemas respondia "transferido" sem de fato trocar o grupo (o campo de transferência assume o grupo do operador autenticado). Descoberto ao verificar o chamado real depois do teste; corrigido usando o campo que define o grupo explicitamente e **confirmando o grupo resultante** em um chamado de ponta a ponta.

## Resultado

- Tempo de bloqueio de acesso: de horas/dias (processo manual) para **< 5 minutos** (ciclo do agente + sincronização do Entra Connect)
- Zero intervenção manual no caminho feliz (chamado aberto → acesso bloqueado → chamado encerrado, tudo automático)
- Rastreabilidade completa: todo bloqueio (ou falha) fica documentado no próprio chamado
- Ciclo completo sem toque manual: bloqueio em minutos e arquivamento da conta aos 60 dias
- Superfície de ataque mínima: conta de serviço sem privilégios administrativos, permissões delegadas e auditadas

## Código de exemplo

Os dois scripts do caso estão na pasta [`scripts/`](scripts/), com **dados fictícios** (empresa "Aurora Agro", domínio `aurora.local`, e-mails `.example`). Códigos de categoria, grupos e campos são valores de exemplo e precisam ser ajustados ao seu ambiente. Nenhuma credencial fica nos arquivos: as chaves vêm de variáveis de ambiente ou de arquivo criptografado.

| Script | O que faz |
|---|---|
| [`Bloqueio-AD-Desligamento.ps1`](scripts/Bloqueio-AD-Desligamento.ps1) | Agente da tarefa agendada (a cada 5 min): lê os chamados de desligamento, localiza a conta pela matrícula, bloqueia, carimba e encerra o chamado. Inclui conferência de nome, nova tentativa em falhas da API, log mensal, alerta por e-mail e fila manual quando a conta não existe |
| [`Mover-Inativos-AD.ps1`](scripts/Mover-Inativos-AD.ps1) | Rotina diária: move para a OU de Inativos as contas desabilitadas com o carimbo há mais de 60 dias. Sem `-Executar`, apenas simula |

## Stack

`PowerShell` · `Active Directory` · `Microsoft Entra ID / Entra Connect` · `Plataforma iPaaS low-code (Maestro)` · `REST API` · `Windows Task Scheduler`

---

*Este documento descreve um caso de estudo com dados fictícios, criado para fins de portfólio profissional.*
