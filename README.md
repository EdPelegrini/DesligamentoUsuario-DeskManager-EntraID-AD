# Automação de Offboarding: Desk Manager → Active Directory → Entra ID

> Caso de estudo de uma automação de ponta a ponta que elimina o bloqueio manual de acessos no desligamento de colaboradores, reduzindo o tempo de resposta de horas/dias para **menos de 5 minutos**, com rastreabilidade completa e privilégio mínimo de acesso.

*Nomes de empresa, domínios, colaboradores e identificadores internos neste documento são fictícios, criados para fins de portfólio. A arquitetura, os desafios técnicos e as soluções descritos refletem um projeto real.*

---

## Contexto

A **Aurora Agro** (nome fictício) processa o desligamento de colaboradores através de um chamado aberto pelo RH na plataforma de Service Desk (Desk Manager). Antes desta automação, o bloqueio de acessos — Active Directory, e-mail, VPN, sistemas internos — dependia de um analista de TI executar cada passo manualmente após ler o chamado, com tempo de resposta variável e sujeito a esquecimento.

**Objetivo:** transformar a abertura do chamado de Desligamento em um gatilho que bloqueia automaticamente o acesso do colaborador, sem intervenção humana, mantendo total auditabilidade.

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

### Correlação de identidade

A matrícula do colaborador (campo já preenchido no chamado pelo RH) é usada como chave de correlação com o atributo `EmployeeID` no Active Directory — evitando qualquer dependência de nome ou e-mail, que podem ter variações/duplicidade.

## Modelo de segurança

Um dos pontos centrais do projeto foi garantir que a automação rodasse com o **menor privilégio possível**:

- Conta de serviço dedicada, **sem** associação a grupos administrativos amplos (removida de Domain Admins durante o hardening)
- Delegação de permissão granular via ACL do AD, restrita a:
  - `WriteProperty` (habilitar/desabilitar conta) e `ReadProperty` (ler o atributo de matrícula) — nada além disso
  - Escopo limitado às Unidades Organizacionais (OUs) onde efetivamente existem contas de colaboradores
- Toda ação (sucesso ou falha) é registrada como comentário no próprio chamado, com timestamp e conta afetada — auditoria nativa, sem sistema de log adicional

## Desafios técnicos e como foram resolvidos

Esse projeto envolveu bem mais troubleshooting de infraestrutura do que o esperado inicialmente. Vale documentar porque cada um foi um aprendizado sobre comportamentos não-óbvios do Windows Server / Active Directory / plataformas de iPaaS:

1. **Herança de ACL quebrada em cascata.** Ao delegar a permissão numa OU pai, a alteração simplesmente não "descia" para os colaboradores. Causa raiz: várias sub-OUs (uma por departamento) tinham a herança de permissões **explicitamente desabilitada** — um padrão de isolamento administrativo por área que não era documentado. Solução: mapear programaticamente todas as OUs com `AreAccessRulesProtected = True` na árvore relevante e aplicar a delegação diretamente em cada uma.

2. **Atributo confidencial silenciosamente vazio.** Mesmo após corrigir a ACL de escrita, a busca pela matrícula (`Get-ADUser -Filter`) não retornava nada — mas uma consulta direta por identidade funcionava, só que com o campo vazio. O atributo estava marcado como confidencial no schema, exigindo uma permissão de **leitura** (`ReadProperty`) separada da permissão de escrita já concedida.

3. **Direito de logon perdido ao reduzir privilégios.** Depois de remover a conta de serviço do grupo administrativo, a Tarefa Agendada parou de disparar silenciosamente — sem erro visível no Task Scheduler além de "0x80070529". Causa: o direito local **"Log on as a batch job"**, concedido implicitamente por associação ao grupo removido, precisou ser delegado explicitamente via política de segurança local.

4. **Comportamento não-documentado do roteamento por grupo na plataforma iPaaS.** O campo de transferência de grupo na API era, na prática, ignorado — o grupo resultante da interação era sempre determinado pela identidade (e o grupo principal) do operador autenticado que executava a chamada, não pelo valor enviado no payload. Resolvido escolhendo uma credencial de automação cujo grupo principal já era o grupo de destino correto.

5. **Inconsistência entre múltiplos Domain Controllers.** Em um ambiente com 5 DCs, criar uma ACE em um DC e validá-la consultando outro (sem replicação ainda concluída) fez a alteração "sumir" temporariamente — resolvido fixando um DC único durante toda a fase de criação/validação, seguido de `repadmin /syncall` para propagar globalmente.

## Resultado

- Tempo de bloqueio de acesso: de horas/dias (processo manual) para **< 5 minutos** (ciclo do agente + sincronização do Entra Connect)
- Zero intervenção manual no caminho feliz (chamado aberto → acesso bloqueado → chamado encerrado, tudo automático)
- Rastreabilidade completa: todo bloqueio (ou falha) fica documentado no próprio chamado
- Superfície de ataque mínima: conta de serviço sem privilégios administrativos, permissões delegadas e auditadas

## Stack

`PowerShell` · `Active Directory` · `Microsoft Entra ID / Entra Connect` · `Plataforma iPaaS low-code (Maestro)` · `REST API` · `Windows Task Scheduler`

---

*Este documento descreve um caso de estudo com dados fictícios, criado para fins de portfólio profissional.*
