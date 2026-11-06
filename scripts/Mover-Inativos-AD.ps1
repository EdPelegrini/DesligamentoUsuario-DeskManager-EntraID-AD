<#
.SYNOPSIS
    Move para a OU de Inativos as contas desligadas ha mais de N dias (padrao: 60).

.DESCRIPTION
    Complemento do Bloqueio-AD-Desligamento.ps1. Aquele script grava no atributo 'info' da conta
    o carimbo "[OFFBOARDING-AUTO] yyyy-MM-dd chamado=XXXX-XXXXXX" no momento do bloqueio.
    Este script roda uma vez por dia, procura contas DESABILITADAS com esse carimbo cuja data tenha
    mais de $DiasParaMover dias e as move para $OUInativos.

    Seguranca:
      - Sem -Executar o script apenas LISTA o que moveria (modo simulacao).
      - Nunca move conta habilitada (ex.: colaborador readmitido).
      - So considera contas com o carimbo do offboarding automatico.

    ATENCAO (Entra Connect): se $OUInativos estiver FORA do escopo de sincronizacao, o Entra Connect
    trata a conta como removida e ela vai para a lixeira do Entra ID (exclusao definitiva apos 30 dias,
    incluindo caixa de e-mail/OneDrive). Confirme o escopo ANTES de usar -Executar.

.PARAMETER Executar
    Efetiva a movimentacao. Sem este parametro, apenas simula.

.PARAMETER Dias
    Sobrescreve o prazo (padrao 60). Use apenas em testes, junto com -SomenteMatricula.

.PARAMETER SomenteMatricula
    Considera apenas a conta com este EmployeeID (para testes controlados).
#>
param(
    [switch]$Executar,
    [int]$Dias = 60,
    [string]$SomenteMatricula
)

$ErrorActionPreference = "Stop"

# ============================================================
# CONFIGURACAO
# ============================================================
$DiasParaMover     = $Dias
$SearchBase        = "OU=USUARIOS,OU=EMPRESA,DC=aurora,DC=local"
$OUInativos        = "OU=INATIVOS,DC=aurora,DC=local"
$MarcaDesligamento = "[OFFBOARDING-AUTO]"
$DirLog            = "C:\Scripts\logs"

# ============================================================
# FUNCOES
# ============================================================
function Write-Log {
    param([string]$Mensagem)
    $linha = "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Mensagem
    Write-Host $linha
    if (-not (Test-Path $DirLog)) { New-Item -ItemType Directory -Path $DirLog -Force | Out-Null }
    Add-Content -Path (Join-Path $DirLog ("inativos-{0}.log" -f (Get-Date -Format "yyyyMM"))) -Value $linha
}

trap {
    Write-Log "ERRO FATAL: $($_.Exception.Message) | linha $($_.InvocationInfo.ScriptLineNumber)"
    exit 1
}

# ============================================================
# EXECUCAO PRINCIPAL
# ============================================================
Import-Module ActiveDirectory

if ($OUInativos -like "PREENCHER*") {
    Write-Error "Defina `$OUInativos no topo do script (DN da OU de Inativos) antes de rodar."
    exit 1
}

try { $null = Get-ADOrganizationalUnit -Identity $OUInativos }
catch {
    Write-Error "OU de Inativos nao encontrada: $OUInativos"
    exit 1
}

$modo = if ($Executar) { "EXECUCAO" } else { "SIMULACAO (use -Executar para mover)" }
Write-Log "Inicio - modo: $modo | limite: $DiasParaMover dias | destino: $OUInativos"

$limite = (Get-Date).Date.AddDays(-$DiasParaMover)
$regex  = [regex]::Escape($MarcaDesligamento) + "\s+(\d{4}-\d{2}-\d{2})"

$candidatos = Get-ADUser -SearchBase $SearchBase -SearchScope Subtree `
    -Filter 'Enabled -eq $false' -Properties info, EmployeeID

$movidos = 0; $falhas = 0; $avaliados = 0

foreach ($u in $candidatos) {
    if ($u.DistinguishedName -like "*,$OUInativos") { continue }   # ja esta em Inativos
    if (-not $u.info) { continue }
    if ($SomenteMatricula -and $u.EmployeeID -ne $SomenteMatricula) { continue }

    $m = [regex]::Match($u.info, $regex)
    if (-not $m.Success) { continue }
    $avaliados++

    $dataDeslig = [datetime]::ParseExact($m.Groups[1].Value, "yyyy-MM-dd", [Globalization.CultureInfo]::InvariantCulture)
    if ($dataDeslig -gt $limite) { continue }

    $dias = [int]((Get-Date).Date - $dataDeslig).TotalDays
    $desc = "$($u.SamAccountName) (matricula $($u.EmployeeID), desligado em $($dataDeslig.ToString('yyyy-MM-dd')), $dias dias)"

    if (-not $Executar) {
        Write-Log "SIMULACAO: moveria $desc de '$($u.DistinguishedName)'"
        $movidos++
        continue
    }

    try {
        Move-ADObject -Identity $u.ObjectGUID -TargetPath $OUInativos
        Write-Log "MOVIDO: $desc"
        $movidos++
    }
    catch {
        Write-Log "FALHA ao mover ${desc}: $($_.Exception.Message)"
        $falhas++
    }
}

Write-Log "Fim - com carimbo: $avaliados | $(if ($Executar) {'movidos'} else {'a mover'}): $movidos | falhas: $falhas"
