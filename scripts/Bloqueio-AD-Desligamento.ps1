# ----- Bloqueio-AD-Desligamento.ps1 (cabecalho em comentarios de linha) -----
#
# .SYNOPSIS
# Agente on-premises de bloqueio automatico de conta no Active Directory para chamados de
# Desligamento de Usuario (Desk Manager - Aurora Agro).
#
# .DESCRIPTION
# Roda como Tarefa Agendada num servidor com o modulo ActiveDirectory (RSAT) instalado e com
# permissao para desabilitar contas no dominio.
#
# Fluxo:
#   1. Autentica na API da Desk Manager (api.desk.ms).
#   2. Busca chamados abertos na auto-categoria "TI - Acesso - Pessoas & Gestao - Desligamento"
#      (9001) que ja estao no grupo "TI - Seguranca da Informacao" com status "Andamento"
#      (e o que o fluxo de roteamento faz automaticamente na abertura do chamado).
#   3. Para cada chamado, verifica no historico se ja existe a marca de processamento
#      (evita bloquear duas vezes / evita reprocessar no proximo ciclo).
#   4. Busca a matricula do colaborador nos campos extras do chamado.
#   5. Localiza a conta no AD pelo atributo EmployeeID = matricula.
#   6. Executa Disable-ADAccount (o bloqueio sincroniza para o Entra ID automaticamente via
#      Entra Connect - nao ha chamada a Graph API aqui).
#   7. Se o bloqueio deu certo, encerra o chamado automaticamente (status Resolvido, causa
#      Revogacao de Acesso). Se falhou, mantem o chamado em Andamento com um comentario de
#      erro para acao manual da equipe. Em ambos os casos, grava a marca de processamento.
#
# .NOTES
# Autor: gerado com Claude Code a pedido de Ed Pelegrini (Aurora Agro, dados ficticios).
# Revisar com o time de Seguranca da Informacao / AD antes de agendar em producao.
# Nenhuma credencial fica hardcoded neste arquivo - leia de variaveis de ambiente ou de um
# arquivo de configuracao protegido (ver secao CONFIGURACAO abaixo).
#
param([switch]$TesteEmail)   # -TesteEmail: envia um e-mail de teste do alerta e sai (valida o SMTP)

# --- Registro de inicializacao: mostra se o script comecou e guarda qualquer erro ANTES do log principal ---
# (sem ele, uma falha na partida da Tarefa Agendada nao deixa rastro em lugar nenhum). Nao grava valores de chaves.
$LogInicial = "C:\Scripts\logs\inicio-bloqueio.log"
try {
    if (-not (Test-Path "C:\Scripts\logs")) { New-Item -ItemType Directory -Path "C:\Scripts\logs" -Force | Out-Null }
    Add-Content -Path $LogInicial -Value ("{0} inicio | usuario={1} | chave_operador={2} car. | chave_ambiente={3} car." -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $env:USERNAME, ("$env:AURORA_DESK_OPERADOR_API_KEY").Length, ("$env:AURORA_DESK_AMBIENTE_PUBLIC_KEY").Length)
} catch { }
trap {
    try { Add-Content -Path $LogInicial -Value ("{0} ERRO FATAL: {1} | linha {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber) } catch { }
    exit 1
}

# ============================================================
# CONFIGURACAO
# ============================================================
# Nunca deixe credenciais em texto puro neste arquivo. Defina como variaveis de ambiente da
# maquina/servico (Painel de Controle > Sistema > Variaveis de Ambiente), ou leia de um
# Secret/Credential Manager. Exemplo abaixo usa variaveis de ambiente.

$ErrorActionPreference = "Stop"

$OperadorApiKey = $env:AURORA_DESK_OPERADOR_API_KEY      # Chave de API do Operador (aba API do operador)
$AmbientePublicKey = $env:AURORA_DESK_AMBIENTE_PUBLIC_KEY # Chave de API do Ambiente (PublicKey)
$Prefixo = "aurora"

$CodAutoCategoriaDesligamento = "9001"
$SequenciaStatusAndamento = "000006"
$SequenciaStatusResolvido = "000002"
$SequenciaStatusAguardando = "000001"   # Aguardando Atendimento
$CodGrupoFilaManual = "000020"          # TI - Infraestrutura Nivel 1: recebe (sem operador) o chamado cuja conta nao existe no AD
$SequenciaCausaRevogacaoAcesso = "000100"
$NomeGrupoResponsavel = "TI - Seguran$([char]0xE7)a da Informa$([char]0xE7)$([char]0xE3)o"
$CodGrupoResponsavel = "000021"   # grupo da Seguranca: enviado em CodGrupo para o chamado nao mudar de fila ao interagir (a interacao assume o grupo do operador)
# Marca gravada na interacao para nao reprocessar: "[Automacao]" com cedilha e til. Montada por codigo de caractere
# para nao depender da codificacao do arquivo (.ps1 sem BOM no Windows PowerShell 5.1).
$MarcaProcessado = "[Automa" + [char]0x00E7 + [char]0x00E3 + "o]"
# Marca antiga (chamados ja processados antes da troca) e padrao tolerante: o Desk pode devolver acentos como
# entidades HTML (ex.: "Automa&ccedil;&atilde;o"), entao o teste de "ja processado" aceita as tres formas.
$MarcaLegada = "[AD-BLOQUEIO-AUTOMATICO-OK]"
$PadraoMarca = '\[Automa(&(amp;)*ccedil;&(amp;)*atilde;|ca)o\]'
$MarcaDesligamento = "[OFFBOARDING-AUTO]"          # carimbo gravado no atributo 'info' da conta (usado pelo script de inativos)

$CodCampoExtraMatricula = "9101"
$CodCampoExtraNomeColaborador = "9102"

# --- Alerta por e-mail quando o bloqueio automatico falha (acao manual necessaria) ---
# O e-mail e enviado por um Maestro (Desligamento de Usuario - Alerta por Email), via Microsoft Graph,
# de servicos@aurora.example para infra@aurora.example. Este script so faz um POST HTTPS (porta 443) para o Maestro.
# A chave compartilhada NAO fica neste arquivo: defina a variavel de ambiente AURORA_ALERTA_CHAVE (a mesma
# cadastrada na Constant CST_ALERTA_CHAVE do Maestro).
$EmailDestino = "infra@aurora.example"   # apenas informativo (o destinatario real e fixo no Maestro)
$AlertaUrl    = "https://<endereco-do-webhook-do-fluxo-de-alerta>/?token=<prefixo>.<id-do-fluxo>.<token>"
$AlertaChave  = $env:AURORA_ALERTA_CHAVE
# Preferencial: chave em arquivo criptografado (DPAPI), legivel so pela conta que o criou, nesta maquina.
# Crie (logado como a conta da Tarefa Agendada):  Read-Host "Chave do alerta" -AsSecureString | Export-Clixml C:\Scripts\alerta.chave.xml
$AlertaChaveArquivo = "C:\Scripts\alerta.chave.xml"
if (Test-Path $AlertaChaveArquivo) {
    $segura = Import-Clixml -Path $AlertaChaveArquivo
    $AlertaChave = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($segura))
}

# Intervalo recomendado de execucao (Tarefa Agendada do Windows): a cada 5-10 minutos.

# ============================================================
# FUNCOES
# ============================================================

# Chamada a API do Desk com ate 3 tentativas em falhas transitorias (timeout, 429, 502, 503, 504,
# erro de conexao). Erros definitivos (401, 403, 404, 400, 500...) falham de imediato.
$TentativasApi = 3
$EsperaEntreTentativasSeg = 10

function Invoke-DeskApi {
    param([hashtable]$Params)

    for ($tentativa = 1; $tentativa -le $TentativasApi; $tentativa++) {
        try {
            return Invoke-RestMethod @Params
        } catch {
            $status = $null
            if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
            $transitorio = (-not $status) -or ($status -in 408, 429, 502, 503, 504)
            if (-not $transitorio -or $tentativa -ge $TentativasApi) { throw }
            $rotulo = if ($status) { "HTTP $status" } else { $_.Exception.Message }
            Write-Host "  API Desk falhou ($rotulo). Tentativa $tentativa de $TentativasApi; nova tentativa em $EsperaEntreTentativasSeg s..."
            Start-Sleep -Seconds $EsperaEntreTentativasSeg
        }
    }
}

function Get-DeskToken {
    $body = @{ PublicKey = $AmbientePublicKey } | ConvertTo-Json
    $resp = Invoke-DeskApi @{ Method = "Post"; Uri = "https://api.desk.ms/Login/autenticar"
        Headers = @{ Authorization = $OperadorApiKey; "Content-Type" = "application/json" }
        Body = $body }
    return $resp
}

function Get-ChamadosDesligamentoPendentes {
    param([string]$Token)

    $filtro = @{
        Filtro = @{ CodAutoCategoria = $CodAutoCategoriaDesligamento }
        Ativo  = "EmAberto"
        Limit  = "100"
    } | ConvertTo-Json -Depth 5

    $resp = Invoke-DeskApi @{ Method = "Post"; Uri = "https://api.desk.ms/ChamadosSuporte/lista"
        Headers = @{ Authorization = $Token; "Content-Type" = "application/json" }
        Body = $filtro }

    if (-not $resp.root) { return @() }

    return $resp.root | Where-Object {
        $_.NomeGrupo -eq $NomeGrupoResponsavel -and $_.NomeStatus -eq "Andamento"
    }
}

function Test-ChamadoJaProcessado {
    param([string]$Token, [string]$Chave)

    $body = @{
        Chave    = $Chave
        Solicitante = "N"
        Colunas  = @{ Descricao = "on"; ObservacaoInterna = "on" }
    } | ConvertTo-Json -Depth 5

    # Sem SilentlyContinue: falha de API aqui nao pode virar "nao processado" (reprocessaria o chamado)
    $resp = Invoke-DeskApi @{ Method = "Post"; Uri = "https://api.desk.ms/ChamadoHistoricos/lista"
        Headers = @{ Authorization = $Token; "Content-Type" = "application/json" }
        Body = $body }

    if (-not $resp.root) { return $false }
    foreach ($interacao in $resp.root) {
        foreach ($texto in @($interacao.Descricao, $interacao.ObservacaoInterna)) {
            if ($texto -and ($texto.Contains($MarcaProcessado) -or ($texto -match $PadraoMarca) -or $texto.Contains($MarcaLegada))) {
                return $true
            }
        }
    }
    return $false
}

function Get-CamposExtrasChamado {
    param([string]$Token, [string]$Chave)

    $body = @{ Chave = $Chave } | ConvertTo-Json
    $resp = Invoke-DeskApi @{ Method = "Post"; Uri = "https://api.desk.ms/ChamadosSuporte/camposextras"
        Headers = @{ Authorization = $Token; "Content-Type" = "application/json" }
        Body = $body }

    $valores = @{}
    foreach ($campo in $resp.TCamposExtras) {
        $valores[[string]$campo.codcampoextra] = $campo.valcampoextra
    }
    return $valores
}

function Set-CarimboDesligamento {
    param($Usuario, [string]$CodChamado)

    if ($Usuario.info -and $Usuario.info.Contains($MarcaDesligamento)) { return $null }

    $carimbo = "$MarcaDesligamento $(Get-Date -Format 'yyyy-MM-dd') chamado=$CodChamado"
    $novoInfo = if ($Usuario.info) { "$($Usuario.info)`r`n$carimbo" } else { $carimbo }

    try {
        Set-ADUser -Identity $Usuario.SamAccountName -Replace @{ info = $novoInfo }
        return $null
    }
    catch {
        return " ATENCAO: carimbo de desligamento nao gravado ($($_.Exception.Message)) - a conta nao sera movida automaticamente para Inativos."
    }
}

function Get-TokensNome {
    param([string]$Nome)
    if (-not $Nome) { return @() }
    # remove acentos, caixa alta, so letras
    $d = $Nome.Normalize([System.Text.NormalizationForm]::FormD)
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $d.ToCharArray()) {
        if ([System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($c) -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) { [void]$sb.Append($c) }
    }
    $limpo = ($sb.ToString().ToUpperInvariant() -replace '[^A-Z ]', ' ')
    $particulas = @('DE', 'DA', 'DO', 'DAS', 'DOS', 'E')
    return @($limpo -split '\s+' | Where-Object { $_.Length -gt 1 -and $particulas -notcontains $_ })
}

function Test-NomeCompativel {
    # Verdadeiro se os dois nomes parecem ser da mesma pessoa: primeiro e ultimo nome iguais,
    # ou todos os nomes do mais curto contidos no mais longo (ignora acento, caixa, particulas e iniciais).
    param([string]$NomeChamado, [string]$NomeAD)
    $a = Get-TokensNome $NomeChamado
    $b = Get-TokensNome $NomeAD
    if ($a.Count -eq 0 -or $b.Count -eq 0) { return $false }
    if ($a[0] -eq $b[0] -and $a[-1] -eq $b[-1]) { return $true }
    $menor, $maior = if ($a.Count -le $b.Count) { $a, $b } else { $b, $a }
    foreach ($t in $menor) { if ($maior -notcontains $t) { return $false } }
    return $true
}

function Invoke-BloqueioAD {
    param([string]$Matricula, [string]$NomeColaborador, [string]$CodChamado)

    $Matricula = $Matricula.Trim()
    if ($Matricula -notmatch '^[0-9A-Za-z-]+$') {
        return @{ Sucesso = $false; Mensagem = "Matricula com caracteres invalidos ('$Matricula') (colaborador: $NomeColaborador). Verificar manualmente." }
    }

    # No AD a matricula pode ter zeros a esquerda (ex.: chamado '1652' x AD '01652'): busca as variantes com 0 a esquerda
    $variantes = @($Matricula)
    if ($Matricula -match '^[0-9]+$') {
        $semZeros = $Matricula.TrimStart('0')
        if ($semZeros -eq '') { $semZeros = '0' }
        $variantes = @($Matricula, $semZeros) + @($semZeros.Length..10 | ForEach-Object { $semZeros.PadLeft($_, '0') })
        $variantes = $variantes | Select-Object -Unique
    }
    $filtro = ($variantes | ForEach-Object { "EmployeeID -eq '$_'" }) -join ' -or '
    $usuario = Get-ADUser -Filter $filtro -Properties EmployeeID, Enabled, info, DisplayName, GivenName, Surname, AdminCount -ErrorAction SilentlyContinue

    if (-not $usuario) {
        return @{ Sucesso = $false; ContaNaoEncontrada = $true; Mensagem = "Nenhuma conta encontrada no AD com EmployeeID = $Matricula (colaborador: $NomeColaborador). Verificar manualmente." }
    }

    if ($usuario.Count -gt 1) {
        return @{ Sucesso = $false; Mensagem = "Mais de uma conta no AD com EmployeeID = $Matricula. Bloqueio nao executado - verificar manualmente." }
    }

    # Conferencia de seguranca: o nome do chamado precisa ser compativel com o nome da conta encontrada pela matricula
    $nomeAD = if ($usuario.DisplayName) { $usuario.DisplayName } else { $usuario.Name }
    $nomeAD2 = ("$($usuario.GivenName) $($usuario.Surname)").Trim()
    if (-not ((Test-NomeCompativel $NomeColaborador $nomeAD) -or (Test-NomeCompativel $NomeColaborador $nomeAD2))) {
        return @{ Sucesso = $false; Mensagem = "A matricula $Matricula pertence a '$nomeAD' (conta $($usuario.SamAccountName)), mas o chamado informa '$NomeColaborador'. Bloqueio NAO executado - validar a matricula e o nome manualmente." }
    }

    # Conta protegida (AdminCount=1: membro atual/antigo de grupo privilegiado): o AD substitui as permissoes delegadas
    # (AdminSDHolder). O bloqueio e feito igual; a nota abaixo explica uma eventual negativa de acesso e fica no chamado.
    $notaProtegida = if ($usuario.AdminCount -eq 1) { " Obs.: conta protegida (AdminCount=1) - as permissoes delegadas da conta de servico nao se aplicam a ela (AdminSDHolder)." } else { "" }

    if (-not $usuario.Enabled) {
        $aviso = Set-CarimboDesligamento -Usuario $usuario -CodChamado $CodChamado
        return @{ Sucesso = $true; Mensagem = "Conta $($usuario.SamAccountName) ja estava desabilitada no AD.$aviso$notaProtegida" }
    }

    try {
        Disable-ADAccount -Identity $usuario.SamAccountName
        $aviso = Set-CarimboDesligamento -Usuario $usuario -CodChamado $CodChamado
        return @{ Sucesso = $true; Mensagem = "Conta $($usuario.SamAccountName) desabilitada com sucesso no AD (sincroniza para o Entra ID automaticamente).$aviso$notaProtegida" }
    }
    catch {
        return @{ Sucesso = $false; Mensagem = "Erro ao desabilitar $($usuario.SamAccountName): $($_.Exception.Message)$notaProtegida" }
    }
}

function Send-InteracaoChamado {
    param([string]$Token, [string]$CodChamado, [bool]$Sucesso, [string]$Mensagem)

    $descricao = if ($Sucesso) {
        "Bloqueio de acesso no Active Directory e Entra ID executado automaticamente. Chamado encerrado automaticamente. $MarcaProcessado"
    } else {
        "ATENCAO: falha ao executar o bloqueio automatico no AD - necessaria acao manual. $MarcaProcessado"
    }

    $observacao = "$Mensagem`n`n$MarcaProcessado - processado em $(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')"

    $tChamado = @{
        CodFormaAtendimento = "3"
        CodStatus           = if ($Sucesso) { $SequenciaStatusResolvido } else { $SequenciaStatusAndamento }
        Descricao            = $descricao
        ObservacaoInterna    = $observacao
        CodGrupo             = $CodGrupoResponsavel
        EnviarEmail          = "N"
    }

    if ($Sucesso) {
        $tChamado["CodCausa"] = $SequenciaCausaRevogacaoAcesso
    }

    $body = @{
        Chave    = $CodChamado
        TChamado = $tChamado
    } | ConvertTo-Json -Depth 5

    # Corpo em bytes UTF-8: nomes com acento/cedilha (ex.: CONCEICAO) davam erro 500 no Desk com string simples
    Invoke-RestMethod -Method Put -Uri "https://api.desk.ms/ChamadosSuporte/interagir" `
        -Headers @{ Authorization = $Token } -ContentType "application/json; charset=utf-8" `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) | Out-Null
}

function Move-ChamadoParaFilaManual {
    # Conta nao encontrada no AD: registra o motivo, move o chamado para a fila da Infraestrutura Nivel 1 e o deixa
    # SEM operador (Aguardando Atendimento) para alguem do time puxar. A interacao do Desk sempre atribui o chamado a
    # quem chama a API; por isso, depois dela, uma edicao completa do chamado limpa o operador.
    param([string]$Token, $Chamado, [string]$Mensagem)

    $codChamado = $Chamado.CodChamado
    $obs = "$Mensagem`n`nChamado movido automaticamente para a fila da Infraestrutura Nivel 1 (sem operador) para tratamento manual.`n$MarcaProcessado - processado em $(Get-Date -Format 'dd-MM-yyyy HH:mm:ss')"
    $interacao = @{
        Chave    = $codChamado
        TChamado = @{
            CodFormaAtendimento = "3"
            CodStatus           = $SequenciaStatusAguardando
            Descricao           = "ATENCAO: nenhuma conta encontrada no AD para este colaborador - chamado encaminhado a Infraestrutura Nivel 1 para tratamento manual. $MarcaProcessado"
            ObservacaoInterna   = $obs
            CodGrupo            = $CodGrupoFilaManual
            EnviarEmail         = "N"
        }
    } | ConvertTo-Json -Depth 5
    Invoke-RestMethod -Method Put -Uri "https://api.desk.ms/ChamadosSuporte/interagir" `
        -Headers @{ Authorization = $Token } -ContentType "application/json; charset=utf-8" `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($interacao)) | Out-Null

    # Limpa o operador (a edicao exige os campos do chamado e regrava a descricao: reenvia a original)
    try {
        $edicao = @{
            TChamado = @{
                Chave             = $codChamado
                Solicitante       = [string]$Chamado.ChaveUsuario
                AutoCategoria     = $CodAutoCategoriaDesligamento
                Assunto           = $Chamado.Assunto
                Solicitacao       = $Chamado.SequenciaSolicitacao
                TipoOcorrencia    = $Chamado.SequenciaTipoOcorrencia
                Categoria         = $Chamado.SequenciaSubCategoria
                CategoriaTipo     = $Chamado.SequenciaTipo
                Impacto           = "000001"
                Urgencia          = "000001"
                Descricao         = $Chamado.Descricao
                TransfCodOperador = ""
                TransfCodGrupo    = $CodGrupoFilaManual
                EnviaEmail        = "N"
            }
        } | ConvertTo-Json -Depth 5
        Invoke-RestMethod -Method Put -Uri "https://api.desk.ms/ChamadosSuporte" `
            -Headers @{ Authorization = $Token } -ContentType "application/json; charset=utf-8" `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($edicao)) | Out-Null
    }
    catch {
        Write-Warning "  Chamado $codChamado movido de grupo, mas nao foi possivel remover o operador ($($_.Exception.Message))."
    }
}

function Send-AlertaEmail {
    param([string]$CodChamado, [string]$NomeColaborador, [string]$Matricula, [string]$Motivo, [string]$Tipo = "")

    if (-not $AlertaChave) {
        Write-Warning "Chave do alerta nao encontrada (arquivo $AlertaChaveArquivo ou variavel AURORA_ALERTA_CHAVE) - alerta por e-mail nao enviado."
        return
    }

    $corpo = @{
        chave       = $AlertaChave
        chamado     = $CodChamado
        colaborador = $NomeColaborador
        matricula   = $Matricula
        motivo      = $Motivo
        tipo        = $Tipo   # "encerrado" = chamado ja encerrado pela automacao, com pendencia
    } | ConvertTo-Json

    try {
        $resp = Invoke-RestMethod -Method Post -Uri $AlertaUrl -ContentType "application/json; charset=utf-8" `
            -Body ([System.Text.Encoding]::UTF8.GetBytes($corpo)) -TimeoutSec 60
        if ($resp.ok) {
            Write-Host "  Alerta enviado por e-mail para $EmailDestino."
        }
        else {
            Write-Warning "Alerta NAO enviado. Resposta do Maestro: $($resp | ConvertTo-Json -Compress -Depth 5)"
        }
    }
    catch {
        Write-Warning "Falha ao acionar o Maestro de alerta: $($_.Exception.Message)"
    }
}

# ============================================================
# EXECUCAO PRINCIPAL
# ============================================================

if ($TesteEmail) {
    Send-AlertaEmail -CodChamado "TESTE-000000" -NomeColaborador "Colaborador de Teste" -Matricula "00000" `
        -Motivo "Este e um e-mail de TESTE do alerta de offboarding. Nenhuma acao e necessaria."
    exit 0
}

if (-not $OperadorApiKey -or -not $AmbientePublicKey) {
    try { Add-Content -Path $LogInicial -Value ("{0} ERRO: variavel de ambiente AURORA_DESK_OPERADOR_API_KEY ou AURORA_DESK_AMBIENTE_PUBLIC_KEY vazia para este usuario." -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss")) } catch { }
    Write-Error "Defina as variaveis de ambiente AURORA_DESK_OPERADOR_API_KEY e AURORA_DESK_AMBIENTE_PUBLIC_KEY antes de rodar este script."
    exit 1
}

Import-Module ActiveDirectory

# --- Log em arquivo (mensal) e estado entre execucoes (falhas repetidas / limite de alertas) ---
$DirLog = "C:\Scripts\logs"
$ArquivoEstado = "C:\Scripts\estado-bloqueio.xml"
$FalhasParaAlertar = 3          # ciclos seguidos falhando no mesmo chamado (3 x 5 min = ~15 min)
$MinutosEntreAlertasScript = 60 # no maximo 1 alerta de falha do proprio script por hora

function Get-Estado {
    if (Test-Path $ArquivoEstado) {
        try { $e = Import-Clixml $ArquivoEstado; if ($e -is [hashtable] -and $e.falhas -is [hashtable]) { return $e } } catch { }
    }
    return @{ falhas = @{}; ultimoAlertaScript = [datetime]::MinValue }
}

function Save-Estado {
    param($Estado)
    try { $Estado | Export-Clixml -Path $ArquivoEstado } catch { Write-Warning "Nao foi possivel gravar o estado ($($_.Exception.Message))." }
}

try {
    if (-not (Test-Path $DirLog)) { New-Item -ItemType Directory -Path $DirLog -Force | Out-Null }
    Start-Transcript -Path (Join-Path $DirLog ("bloqueio-{0}.log" -f (Get-Date -Format "yyyyMM"))) -Append | Out-Null
}
catch { Write-Warning "Log em arquivo indisponivel: $($_.Exception.Message)" }

try {
    $estado = Get-Estado

    $token = Get-DeskToken
    Write-Host "Token obtido com sucesso."

    $chamados = Get-ChamadosDesligamentoPendentes -Token $token
    Write-Host "Chamados de Desligamento em 'Andamento' no grupo '$NomeGrupoResponsavel': $($chamados.Count)"

    foreach ($chamado in $chamados) {
        $codChamado = $chamado.CodChamado
        $chaveChamado = $chamado.Chave

        Write-Host "`nProcessando chamado $codChamado (chave $chaveChamado)..."

        try {
            if (Test-ChamadoJaProcessado -Token $token -Chave $chaveChamado) {
                Write-Host "  Ja processado anteriormente (marca $MarcaProcessado encontrada). Pulando."
                continue
            }

            $campos = Get-CamposExtrasChamado -Token $token -Chave $chaveChamado
            $matricula = $campos[$CodCampoExtraMatricula]
            $nomeColaborador = $campos[$CodCampoExtraNomeColaborador]

            if (-not $matricula) {
                Write-Host "  Matricula nao encontrada nos campos extras. Pulando (necessita acao manual)."
                Send-InteracaoChamado -Token $token -CodChamado $codChamado -Sucesso $false `
                    -Mensagem "Nao foi possivel localizar a matricula do colaborador nos campos extras do chamado."
                Send-AlertaEmail -CodChamado $codChamado -NomeColaborador $nomeColaborador -Matricula "(nao informada)" `
                    -Motivo "Matricula nao encontrada nos campos extras do chamado."
                continue
            }

            Write-Host "  Colaborador: $nomeColaborador | Matricula: $matricula"

            $resultado = Invoke-BloqueioAD -Matricula $matricula -NomeColaborador $nomeColaborador -CodChamado $codChamado
            Write-Host "  Resultado: $($resultado.Mensagem)"

            if ($resultado.ContaNaoEncontrada) {
                Move-ChamadoParaFilaManual -Token $token -Chamado $chamado -Mensagem $resultado.Mensagem
                Write-Host "  Chamado movido para a fila da Infraestrutura Nivel 1 (sem operador)."
                if ($estado.falhas.ContainsKey($codChamado)) { $estado.falhas.Remove($codChamado); Save-Estado $estado }
                continue
            }

            Send-InteracaoChamado -Token $token -CodChamado $codChamado -Sucesso $resultado.Sucesso -Mensagem $resultado.Mensagem

            # chegou ao fim sem erro: zera o contador de falhas deste chamado
            if ($estado.falhas.ContainsKey($codChamado)) { $estado.falhas.Remove($codChamado); Save-Estado $estado }

            if (-not $resultado.Sucesso) {
                Send-AlertaEmail -CodChamado $codChamado -NomeColaborador $nomeColaborador -Matricula $matricula -Motivo $resultado.Mensagem
            }
            elseif ($resultado.Mensagem -like "*ATENCAO*") {
                # bloqueio ok e chamado encerrado, mas ficou pendencia (ex.: carimbo nao gravado): e-mail com texto proprio
                Send-AlertaEmail -CodChamado $codChamado -NomeColaborador $nomeColaborador -Matricula $matricula -Motivo $resultado.Mensagem -Tipo "encerrado"
            }
        }
        catch {
            $n = 1 + [int]$estado.falhas[$codChamado]
            $estado.falhas[$codChamado] = $n
            $erro = $_.Exception.Message
            Write-Warning "  Falha ao processar o chamado $codChamado ($erro). Tentativa seguida numero $n; sera tentado de novo no proximo ciclo."
            if ($n -eq $FalhasParaAlertar) {
                Send-AlertaEmail -CodChamado $codChamado -NomeColaborador $nomeColaborador -Matricula $matricula `
                    -Motivo "O script falhou $n ciclos seguidos ao processar este chamado (ultimo erro: $erro). O chamado continua em Andamento sem bloqueio - tratar manualmente."
            }
            Save-Estado $estado
            continue
        }
    }

    Write-Host "`nCiclo concluido."
}
catch {
    $msg = "Erro no script de bloqueio em $($env:COMPUTERNAME): $($_.Exception.Message) (linha $($_.InvocationInfo.ScriptLineNumber))"
    Write-Warning $msg
    $e2 = Get-Estado
    if (((Get-Date) - $e2.ultimoAlertaScript).TotalMinutes -ge $MinutosEntreAlertasScript) {
        Send-AlertaEmail -CodChamado "(falha do script)" -NomeColaborador "-" -Matricula "-" -Motivo $msg
        $e2.ultimoAlertaScript = Get-Date
        Save-Estado $e2
    }
    try { Stop-Transcript | Out-Null } catch { }
    exit 1
}
try { Stop-Transcript | Out-Null } catch { }
