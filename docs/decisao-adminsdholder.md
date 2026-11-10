# Decisão: não delegar permissões no AdminSDHolder para a conta da automação de desligamento

**Data:** novembro/2026 (exemplo com dados fictícios)
**Assunto:** contas protegidas do AD (AdminCount = 1) na automação de desligamento de usuários
**Decisão:** **não** conceder permissões à conta de serviço da automação (`svc.offboarding`) no objeto `AdminSDHolder`. Contas protegidas continuam sendo tratadas manualmente, com aviso automático à equipe.

## O que motivou a discussão

Em um chamado real a automação encontrou a conta do colaborador já desabilitada, mas não conseguiu gravar o carimbo de desligamento: `Insufficient access rights`. A conta tinha `AdminCount = 1`, ou seja, é uma **conta protegida** (é, ou já foi, membro de um grupo privilegiado).

Para essas contas o AD desliga a herança de permissões e, a cada 60 minutos (processo SDProp), reaplica sobre elas o modelo de segurança do objeto `CN=AdminSDHolder`. Por isso as permissões delegadas nas OUs de usuários não valem para elas: a conta de serviço não consegue desabilitar nem gravar atributos em uma conta protegida, e a rotina de 60 dias ficaria sem o carimbo.

## Opção avaliada

Conceder à `svc.offboarding`, no `AdminSDHolder`, permissão de escrita em `userAccountControl` e `info`. O SDProp propagaria essa permissão para **todas** as contas protegidas do domínio, e o bloqueio imediato funcionaria também para elas.

## Por que não seguir com ela

1. **Alcance muito maior que o benefício.** A permissão passaria a valer sobre todos os administradores do domínio, e não apenas sobre quem está sendo desligado. O caso que a motivou é raro, e o alcance é o de maior privilégio do ambiente.
2. **Risco de abuso se a conta de serviço for comprometida.** A escrita em `userAccountControl` permite não só desabilitar contas privilegiadas (indisponibilidade), mas também alterar flags perigosas, como dispensar a pré-autenticação Kerberos ou a exigência de senha. A conta roda sem supervisão a cada 5 minutos e depende de chaves em variáveis de ambiente, ou seja, é um alvo mais exposto que as contas que passaria a controlar.
3. **Contradiz o princípio do projeto.** O desenho da automação é de privilégio mínimo: conta sem privilégios administrativos, permissões delegadas só nas OUs de colaboradores. Abrir o AdminSDHolder inverte isso para o conjunto mais sensível de contas.
4. **Existe um tratamento seguro e já funcionando.** O custo de não delegar é apenas uma ação manual em casos raros, e ela já é avisada automaticamente (abaixo).

## Como as contas protegidas ficam tratadas

| Situação | O que a automação faz | Ação humana |
|---|---|---|
| Conta protegida **habilitada** | Tenta desabilitar, é negada, mantém o chamado em *Andamento*, anota no chamado que a conta é protegida (AdminCount = 1) e envia o e-mail de ação manual | Bloquear a conta manualmente (AD e Entra ID) e encerrar o chamado |
| Conta protegida **já desabilitada** | Considera o bloqueio feito, encerra o chamado, mas não grava o carimbo. Envia e-mail de "pendência após encerramento" | Mover a conta manualmente para Inativos após 60 dias (ou gravar o carimbo à mão no atributo `info`) |

Nos dois casos o aviso é automático. Nenhuma conta fica sem tratamento silenciosamente.

## Medida complementar recomendada (time de AD)

Muitas contas com `AdminCount = 1` são resíduo: o colaborador já saiu do grupo privilegiado, mas o atributo e a herança desligada permanecem. Revisar essas contas reduz os casos manuais sem abrir permissão alguma. Lista para revisão:

```powershell
Get-ADUser -Filter 'AdminCount -eq 1' -Properties AdminCount, MemberOf, Enabled |
  Select-Object SamAccountName, Enabled,
    @{ n = 'Grupos'; e = { ($_.MemberOf | ForEach-Object { ($_ -split ',')[0] -replace 'CN=' }) -join '; ' } }
```

Para uma conta que não pertence mais a nenhum grupo privilegiado, o procedimento do AD é zerar o `AdminCount` e reativar a herança de permissões no objeto. Isso é decisão do time de AD.

## Revisão

Reavaliar se a quantidade de contas protegidas de colaboradores desligados se tornar frequente.

---

*Documento de estudo de caso com dados fictícios (Aurora Agro), criado para fins de portfólio.*
