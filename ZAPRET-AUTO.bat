<# : zapret-auto -- BU DOSYA HEM .BAT HEM POWERSHELL'DIR. Ust kisim batch (yonetici izni + baslatma), alt kisim okunabilir PowerShell.
@echo off
setlocal DisableDelayedExpansion
rem ---------------------------------------------------------------------------
rem  zapret-auto : tek dosyalik, kurulumsuz DPI atlatma + sifreli DNS araci.
rem  Bu batch kismi sadece: (1) yonetici izni ister, (2) dosyanin kendisini
rem  %ProgramData%\zapret-auto\zapret-auto.ps1 olarak kopyalar, (3) onu calistirir.
rem  Asagidaki PowerShell kodunun tamami duz metindir; Not Defteri ile okuyabilirsin.
rem  Kullanim:  ZAPRET-AUTO.bat            -> arayuz
rem             ZAPRET-AUTO.bat help       -> komut listesi
rem ---------------------------------------------------------------------------
set "ZA_SELF=%~f0"
set "ZA_SRC=%~dp0"
set "ZA_ARGS=%*"
net session >nul 2>&1
if errorlevel 1 (
  powershell -NoProfile -Command "$a=('' + $env:ZA_ARGS + ' __elevated').Trim(); $ws='Hidden'; if(('' + $env:ZA_ARGS).Trim()){ $ws='Normal' }; try { Start-Process -FilePath $env:ZA_SELF -ArgumentList $a -Verb RunAs -WindowStyle $ws -ErrorAction Stop } catch { exit 1 }"
  if errorlevel 1 (
    echo.
    echo   [zapret-auto] Yonetici izni verilmedi. / Administrator permission was denied.
    echo.
    pause
  )
  exit /b
)
set "ZA_HOME=%ProgramData%\zapret-auto"
set "ZA_PS1=%ProgramData%\zapret-auto\zapret-auto.ps1"
if exist "%ZA_PS1%" icacls "%ZA_PS1%" /reset /C /Q >nul 2>&1
powershell -NoProfile -Command "$d=$env:ZA_HOME; if(-not (Test-Path -LiteralPath $d)){ New-Item -ItemType Directory -Path $d -Force | Out-Null }; Get-Content -LiteralPath $env:ZA_SELF -Raw -Encoding UTF8 | Set-Content -LiteralPath $env:ZA_PS1 -Encoding UTF8 -NoNewline -ErrorAction Stop"
if errorlevel 1 (
  echo   [zapret-auto] %ZA_PS1% yazilamadi / could not be written.
  powershell -NoProfile -Command "Add-Type -AssemblyName PresentationFramework; [void][Windows.MessageBox]::Show('zapret-auto: ' + $env:ZA_PS1 + ' yazilamadi / could not be written.', 'zapret-auto')"
  if not "%~1"=="" if /i not "%~1"=="__elevated" pause
  exit /b 1
)
set "ZA_UI=cli"
if "%~1"=="" set "ZA_UI=gui"
if /i "%~1"=="__elevated" set "ZA_UI=gui"
if "%ZA_UI%"=="gui" (
  start "" powershell -NoProfile -ExecutionPolicy RemoteSigned -WindowStyle Hidden -STA -File "%ZA_PS1%" gui
  exit /b 0
)
powershell -NoProfile -ExecutionPolicy RemoteSigned -File "%ZA_PS1%" %*
exit /b %errorlevel%
#>
# =============================================================================
#  zapret-auto  -  her ISP'de otomatik DPI atlatma (winws) + şifreli DNS (DoH)
#  Modlar (CLI):  gui | install [yes] [/quiet] | probe | status | uninstall
#                 zapret-on|off | doh-on|off | watch-on|off | game-on|off
#                 report | pack | config | set <anahtar> <değer> | watch | help
# =============================================================================
param([string]$Mode = 'gui', [Parameter(ValueFromRemainingArguments = $true)] $Rest)

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'   # PS 5.1'de Invoke-WebRequest'i çok hızlandırır
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$ZA_VERSION = '2.4.1'
$Rest  = @($Rest | Where-Object { $_ })
$Quiet = [bool]($Rest | Where-Object { "$_" -match '^/?(quiet|q|sessiz)$' })
$Yes   = $Quiet -or [bool]($Rest | Where-Object { "$_" -match '^/?(yes|evet|y)$' })
$PauseEnd = ($Rest -contains '__elevated') -and -not $Quiet
$Mode  = "$Mode".Trim().TrimStart('/').ToLower()
if($Mode -eq '__elevated' -or -not $Mode){ $Mode = 'gui' }

# ---------------- yollar ve sabitler ----------------
$Root      = Join-Path $env:ProgramData 'zapret-auto'
$LogFile   = Join-Path $Root 'zapret-auto.log'
$CfgFile   = Join-Path $Root 'config.txt'
$StateFile = Join-Path $Root 'state.json'
$MemFile   = Join-Path $Root 'memory.json'
$WatchFile = Join-Path $Root 'watch.json'
$CacheDir  = Join-Path $Root 'cache'
$ZapDir    = Join-Path $Root 'zapret'
$DnsDir    = Join-Path $Root 'dnscrypt'
$AutoList  = Join-Path $Root 'autohostlist.txt'
$SelfPath  = $PSCommandPath

$Pkgs = @{
  zapret   = @{ Url='https://github.com/Flowseal/zapret-discord-youtube/releases/download/1.9.9c/zapret-discord-youtube-1.9.9c.zip'
                File='zapret-discord-youtube-1.9.9c.zip'; Sha='6064E4B26ED7358961A0B978FBB6263B119D8D7A5A06BB4A6454AEB855CF63E9'
                Repo='Flowseal/zapret-discord-youtube'; Pattern='zapret*discord*youtube*.zip' }
  dnscrypt = @{ Url='https://github.com/DNSCrypt/dnscrypt-proxy/releases/download/2.1.16/dnscrypt-proxy-win64-2.1.16.zip'
                File='dnscrypt-proxy-win64-2.1.16.zip'; Sha='4373C380B0E261D6D511B299FB4EDCE99F13D0D86A7DB7E2EE4CAD0FA1CE0078'
                Repo='DNSCrypt/dnscrypt-proxy'; Pattern='dnscrypt*win64*.zip' }
}
# Keşif için denenen siteler (öğrenilmiş autohostlist girdileri bunlardan ÖNCE denenir).
$DefaultTargets = @('discord.com','cdn.discordapp.com','gateway.discord.gg','x.com','telegram.org','www.roblox.com','www.wattpad.com','rutracker.org','signal.org','archive.org')
$ControlSites   = @('www.microsoft.com','www.bing.com')     # engellenmeyen, internet var mı kontrolü
# DoH sunucuları IP ile (SNI yok -> SNI tabanlı engel bunları göremez). Stamp'ler el ile üretildi ve test edildi.
$DnscryptStamps = [ordered]@{
  'cf1' = 'sdns://AgAAAAAAAAAABzEuMS4xLjEABzEuMS4xLjEKL2Rucy1xdWVyeQ'   # https://1.1.1.1/dns-query
  'cf2' = 'sdns://AgAAAAAAAAAABzEuMC4wLjEABzEuMC4wLjEKL2Rucy1xdWVyeQ'   # https://1.0.0.1/dns-query
  'g1'  = 'sdns://AgAAAAAAAAAABzguOC44LjgABzguOC44LjgKL2Rucy1xdWVyeQ'   # https://8.8.8.8/dns-query
  'g2'  = 'sdns://AgAAAAAAAAAABzguOC40LjQABzguOC40LjQKL2Rucy1xdWVyeQ'   # https://8.8.4.4/dns-query
}
$NativeDoh = [ordered]@{
  '1.1.1.1'              = 'https://cloudflare-dns.com/dns-query'
  '1.0.0.1'              = 'https://cloudflare-dns.com/dns-query'
  '2606:4700:4700::1111' = 'https://cloudflare-dns.com/dns-query'
  '2606:4700:4700::1001' = 'https://cloudflare-dns.com/dns-query'
}
$PlainDns = @('1.1.1.1','8.8.8.8','2606:4700:4700::1111','2001:4860:4860::8888')
$TaskPath = '\zapret-auto\'
$TaskName = 'zapret-auto-watch'

# Paketteki .bat'lar okunamazsa kullanılacak gömülü yedek strateji = Flowseal 1.9.9c "general (ALT)".
$EmbeddedALT = @'
--wf-tcp=80,443,2053,2083,2087,2096,8443,%GameFilterTCP% --wf-udp=443,19294-19344,50000-50100,%GameFilterUDP%
--filter-udp=443 --hostlist="%LISTS%list-general.txt" --hostlist="%LISTS%list-general-user.txt" --hostlist-exclude="%LISTS%list-exclude.txt" --hostlist-exclude="%LISTS%list-exclude-user.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --dpi-desync=fake --dpi-desync-repeats=6 --dpi-desync-fake-quic="%BIN%quic_initial_www_google_com.bin" --new
--filter-udp=19294-19344,50000-50100 --filter-l7=discord,stun --dpi-desync=fake --dpi-desync-fake-discord="%BIN%quic_initial_dbankcloud_ru.bin" --dpi-desync-fake-stun="%BIN%quic_initial_dbankcloud_ru.bin" --dpi-desync-repeats=6 --new
--filter-tcp=2053,2083,2087,2096,8443 --hostlist-domains=discord.media --dpi-desync=fake,fakedsplit --dpi-desync-repeats=6 --dpi-desync-fooling=ts --dpi-desync-fakedsplit-pattern=0x00 --dpi-desync-fake-tls="%BIN%tls_clienthello_www_google_com.bin" --new
--filter-tcp=443 --hostlist="%LISTS%list-google.txt" --ip-id=zero --dpi-desync=fake,fakedsplit --dpi-desync-repeats=6 --dpi-desync-fooling=ts --dpi-desync-fakedsplit-pattern=0x00 --dpi-desync-fake-tls="%BIN%tls_clienthello_www_google_com.bin" --new
--filter-tcp=80,443 --hostlist="%LISTS%list-general.txt" --hostlist="%LISTS%list-general-user.txt" --hostlist-exclude="%LISTS%list-exclude.txt" --hostlist-exclude="%LISTS%list-exclude-user.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --dpi-desync=fake,fakedsplit --dpi-desync-repeats=6 --dpi-desync-fooling=ts --dpi-desync-fakedsplit-pattern=0x00 --dpi-desync-fake-tls="%BIN%stun.bin" --dpi-desync-fake-tls="%BIN%tls_clienthello_www_google_com.bin" --dpi-desync-fake-http="%BIN%tls_clienthello_max_ru.bin" --new
--filter-udp=443 --ipset="%LISTS%ipset-all.txt" --hostlist-exclude="%LISTS%list-exclude.txt" --hostlist-exclude="%LISTS%list-exclude-user.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --dpi-desync=fake --dpi-desync-repeats=6 --dpi-desync-fake-quic="%BIN%quic_initial_www_google_com.bin" --new
--filter-tcp=80,443,8443 --ipset="%LISTS%ipset-all.txt" --hostlist-exclude="%LISTS%list-exclude.txt" --hostlist-exclude="%LISTS%list-exclude-user.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --dpi-desync=fake,fakedsplit --dpi-desync-repeats=6 --dpi-desync-fooling=ts --dpi-desync-fakedsplit-pattern=0x00 --dpi-desync-fake-tls="%BIN%stun.bin" --dpi-desync-fake-tls="%BIN%tls_clienthello_www_google_com.bin" --dpi-desync-fake-http="%BIN%tls_clienthello_max_ru.bin" --new
--filter-tcp=%GameFilterTCP% --ipset="%LISTS%ipset-all.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --dpi-desync=fake,fakedsplit --dpi-desync-repeats=6 --dpi-desync-any-protocol=1 --dpi-desync-cutoff=n4 --dpi-desync-fooling=ts --dpi-desync-fakedsplit-pattern=0x00 --dpi-desync-fake-tls="%BIN%stun.bin" --dpi-desync-fake-tls="%BIN%tls_clienthello_www_google_com.bin" --dpi-desync-fake-http="%BIN%tls_clienthello_max_ru.bin" --new
--filter-udp=%GameFilterUDP% --ipset="%LISTS%ipset-all.txt" --ipset-exclude="%LISTS%ipset-exclude.txt" --ipset-exclude="%LISTS%ipset-exclude-user.txt" --dpi-desync=fake --dpi-desync-repeats=12 --dpi-desync-any-protocol=1 --dpi-desync-fake-unknown-udp="%BIN%quic_initial_dbankcloud_ru.bin" --dpi-desync-cutoff=n3
'@

# ---------------- yapılandırma ----------------
$CfgDefaults = [ordered]@{ zapret='1'; doh='1'; watch='1'; game='0'; lang='auto'; dohengine='auto' }
function Load-Config {
  $c = [ordered]@{}; foreach($k in $CfgDefaults.Keys){ $c[$k] = $CfgDefaults[$k] }
  if(Test-Path -LiteralPath $CfgFile){
    foreach($ln in (Get-Content -LiteralPath $CfgFile -ErrorAction SilentlyContinue)){
      if($ln -match '^\s*([A-Za-z]+)\s*=\s*(\S+)'){ $k = $Matches[1].ToLower(); if($c.Contains($k)){ $c[$k] = $Matches[2] } }
    }
  }
  return $c
}
function Save-Config($c){
  $lines = foreach($k in $c.Keys){ "{0}={1}" -f $k, $c[$k] }
  try { Set-Content -LiteralPath $CfgFile -Value $lines -Encoding Ascii -ErrorAction Stop } catch {}
}
function On($v){ return ("$v" -match '^(1|true|on|yes|evet)$') }
function Set-Pref($k, $v){ $c = Load-Config; $c[$k] = "$v"; Save-Config $c }

# ---------------- dil ----------------
function Resolve-Lang {
  $l = (Load-Config).lang
  if($l -in @('tr','en')){ return $l }
  try { if([Globalization.CultureInfo]::InstalledUICulture.TwoLetterISOLanguageName -eq 'tr'){ return 'tr' } } catch {}
  try { if((Get-UICulture).TwoLetterISOLanguageName -eq 'tr'){ return 'tr' } } catch {}
  return 'en'
}
$script:Lang = Resolve-Lang
function T([string]$tr, [string]$en){ if($script:Lang -eq 'en'){ return $en } else { return $tr } }

# ---------------- günlük (log) ----------------
$script:GuiChild = ($env:ZA_GUI_CHILD -eq '1')
$script:Silent   = ($Mode -eq 'watch')
function Init-Log {
  try {
    if(-not (Test-Path -LiteralPath $Root)){ New-Item -ItemType Directory -Path $Root -Force | Out-Null }
    if((Test-Path -LiteralPath $LogFile) -and ((Get-Item -LiteralPath $LogFile).Length -gt 1MB)){ Move-Item -LiteralPath $LogFile -Destination "$LogFile.1" -Force }
  } catch {}
}
# seviye: i (bilgi) | ok | warn | err | head | dim
function Emit([string]$m = '', [string]$lvl = 'i'){   # sadece ekrana/arayüze (dosyaya değil)
  if($script:GuiChild){ [Console]::Out.WriteLine("$lvl|$m") }
  elseif(-not $script:Silent){
    $col = @{ ok='Green'; warn='Yellow'; err='Red'; head='Cyan'; dim='DarkGray' }[$lvl]
    if($col){ Write-Host $m -ForegroundColor $col } else { Write-Host $m }
  }
}
function Log([string]$m = '', [string]$lvl = 'i'){
  Emit $m $lvl
  try { Add-Content -LiteralPath $LogFile -Value ("{0} {1,-4} {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $lvl, $m) -Encoding UTF8 -ErrorAction SilentlyContinue } catch {}
}
function Head([string]$t){
  Log ''; Log $t 'head'
  # kurulum adımlarını arayüzdeki ilerleme listesine bildir ([0] önkontrol ... [7] nöbetçi)
  if($t -match '^\[(\d)\]'){ Mark ("STEP|" + $Matches[1]) } elseif($t -match '^\[(önkontrol|preflight)\]'){ Mark 'STEP|0' }
}
# Arayüze özel işaret (soru sor, dosya aç vb.). CLI'da hiçbir şey yazmaz.
function Mark([string]$s){ if($script:GuiChild){ [Console]::Out.WriteLine("@@$s") } }

$script:ExitCode = 0
function Fail([int]$code, [string]$msg){ if($msg){ Log $msg 'err' }; $script:ExitCode = $code; throw 'ZA_FATAL' }
function Is-Admin { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator) }
function Need-Admin { if(-not (Is-Admin)){ Fail 1 (T 'HATA: yönetici olarak çalıştır.' 'ERROR: run as administrator.') } }

# ---------------- kilit (arayüz ve nöbetçi aynı anda çalışmasın) ----------------
$script:Mutex = $null
# Kilit SYSTEM (nöbetçi) ve Yöneticiler (arayüz) için tam izinle oluşturulur. SYSTEM'in varsayılan izinleri
# yöneticiye sadece "bekle" hakkı verir; öyle bir kilit varsa sadece Synchronize ile açıp bekleriz.
# Erişim reddi ASLA "kilit alındı" sayılmaz (iki işlem aynı anda servisleri değiştirmesin).
function Get-Lock([int]$waitSec){
  $name = 'Global\zapret-auto-lock'
  try {
    $sec = New-Object Security.AccessControl.MutexSecurity
    foreach($sid in @('S-1-5-18', 'S-1-5-32-544')){ $sec.AddAccessRule((New-Object Security.AccessControl.MutexAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)), 'FullControl', 'Allow'))) }
    $created = $false
    $script:Mutex = [Threading.Mutex]::new($false, $name, [ref]$created, $sec)
  } catch {
    $ex = $_.Exception; while($ex.InnerException){ $ex = $ex.InnerException }
    if($ex -is [UnauthorizedAccessException]){
      try { $script:Mutex = [Threading.Mutex]::OpenExisting($name, [Security.AccessControl.MutexRights]'Synchronize') } catch { return $false }
    } else { return $true }   # kilit altyapısı hiç yoksa işlemi tamamen engelleme
  }
  try { if($script:Mutex.WaitOne(0)){ return $true } } catch [Threading.AbandonedMutexException] { return $true }
  if($waitSec -le 0){ return $false }
  Log (T 'Başka bir zapret-auto işlemi sürüyor (muhtemelen nöbetçi); bitmesi bekleniyor...' 'Another zapret-auto task is running (probably the watchdog); waiting...') 'warn'
  try { return $script:Mutex.WaitOne($waitSec * 1000) } catch [Threading.AbandonedMutexException] { return $true }
}

# ---------------- JSON durum dosyaları ----------------
function Read-Json($p){ if(Test-Path -LiteralPath $p){ try { return (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json) } catch {} }; return $null }
function Write-Json($o, $p){ try { ($o | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $p -Encoding UTF8 -ErrorAction Stop } catch {} }
function PGet($o, [string]$n, $d = $null){ if($null -ne $o -and $o.PSObject.Properties[$n] -and $null -ne $o.$n){ return $o.$n }; return $d }
function PSet($o, [string]$n, $v){ if($o.PSObject.Properties[$n]){ $o.$n = $v } else { $o | Add-Member -NotePropertyName $n -NotePropertyValue $v } }
$script:State = $null
function Get-State { if(-not $script:State){ $script:State = Read-Json $StateFile; if(-not $script:State){ $script:State = [pscustomobject]@{} } }; return $script:State }
function Save-State { Write-Json (Get-State) $StateFile }

# =============================================================================
#  AĞ TESTLERİ
# =============================================================================
$script:HasCurl = [bool](Get-Command curl.exe -ErrorAction SilentlyContinue)
$script:HasV6   = $false

# Bir alan adının GERÇEK IP'si (DNS zehirlenmesinden bağımsız): önce IP'ye doğrudan DoH (SNI yok).
function Get-RealIP([string]$d){
  foreach($u in @("https://1.1.1.1/dns-query?name=$d&type=A", "https://8.8.8.8/resolve?name=$d&type=A", "https://cloudflare-dns.com/dns-query?name=$d&type=A", "https://dns.google/resolve?name=$d&type=A")){
    try {
      $j  = Invoke-RestMethod -Uri $u -Headers @{ accept = 'application/dns-json' } -TimeoutSec 8 -UseBasicParsing
      $ip = ($j.Answer | Where-Object { $_.type -eq 1 } | Select-Object -First 1).data
      if($ip -match '^\d+\.\d+\.\d+\.\d+$'){ return $ip }
    } catch {}
  }
  foreach($srv in @('8.8.8.8','1.1.1.1')){
    try { $r = (Resolve-DnsName $d -Server $srv -Type A -DnsOnly -ErrorAction Stop | Where-Object { $_.IPAddress }).IPAddress; if($r){ return @($r)[0] } } catch {}
  }
  return $null
}
function Get-RealIP6([string]$d){
  foreach($u in @("https://1.1.1.1/dns-query?name=$d&type=AAAA", "https://8.8.8.8/resolve?name=$d&type=AAAA")){
    try {
      $j  = Invoke-RestMethod -Uri $u -Headers @{ accept = 'application/dns-json' } -TimeoutSec 8 -UseBasicParsing
      $ip = ($j.Answer | Where-Object { $_.type -eq 28 } | Select-Object -First 1).data
      if($ip -match ':'){ return $ip }
    } catch {}
  }
  return $null
}
# TLS el sıkışması: başarılıysa milisaniye, engelliyse -1 döner. (HTTP kodu ne olursa olsun TLS tamam = engel yok.)
# -SystemDns: adresi sistemin DNS'iyle çöz (tarayıcının gördüğü gibi); yoksa gerçek IP'yi DoH ile bulup sadece DPI'ı ölçer.
function Test-HS([string]$h, [string]$ip, [int]$sec = 6, [switch]$SystemDns){
  if(-not $ip -and -not $SystemDns){ $ip = Get-RealIP $h }
  if($script:HasCurl){
    $a = @('-s', '-o', 'NUL', '-w', '%{http_code} %{time_appconnect}', '--max-time', "$sec")
    if($ip){ $a += @('--resolve', ("{0}:443:{1}" -f $h, $ip)) }
    $a += "https://$h/"
    $out = ("" + (& curl.exe @a 2>$null)).Trim()
    if($out -match '^(\d{3}) ([\d\.,]+)$' -and [int]$Matches[1] -gt 0){
      return [int]([double]::Parse($Matches[2].Replace(',', '.'), [Globalization.CultureInfo]::InvariantCulture) * 1000)
    }
    return -1
  }
  if(-not $ip){ return -1 }
  return (Test-SslRaw $h $ip ([Net.Sockets.AddressFamily]::InterNetwork) ($sec * 1000))
}
function Test-SslRaw([string]$h, [string]$ip, $fam, [int]$ms){
  $sw  = [Diagnostics.Stopwatch]::StartNew()
  $tcp = New-Object Net.Sockets.TcpClient($fam)
  try {
    $iar = $tcp.BeginConnect([Net.IPAddress]::Parse($ip), 443, $null, $null)
    if(-not $iar.AsyncWaitHandle.WaitOne($ms)){ return -1 }
    $tcp.EndConnect($iar)
    $ssl = New-Object Net.Security.SslStream($tcp.GetStream(), $false, ([Net.Security.RemoteCertificateValidationCallback]{ param($a, $b, $c, $d) $true }))
    $t = $ssl.AuthenticateAsClientAsync($h)
    if(-not $t.Wait($ms)){ return -1 }
    if($ssl.IsAuthenticated){ return [int]$sw.ElapsedMilliseconds } else { return -1 }
  } catch { return -1 } finally { try { $tcp.Close() } catch {} }
}
function Test-HS6([string]$h, [string]$ip6){ if(-not $ip6){ return 0 }; return (Test-SslRaw $h $ip6 ([Net.Sockets.AddressFamily]::InterNetworkV6) 8000) }
function Test-TcpReach([string]$ip, [int]$port = 443, [int]$ms = 3000){
  try {
    $fam = if($ip -match ':'){ [Net.Sockets.AddressFamily]::InterNetworkV6 } else { [Net.Sockets.AddressFamily]::InterNetwork }
    $t = New-Object Net.Sockets.TcpClient($fam); $a = $t.BeginConnect([Net.IPAddress]::Parse($ip), $port, $null, $null)
    $ok = $a.AsyncWaitHandle.WaitOne($ms); if($ok){ try { $t.EndConnect($a) } catch { $ok = $false } }; $t.Close(); return $ok
  } catch { return $false }
}
function Test-Online { foreach($ip in @('1.1.1.1', '8.8.8.8')){ if(Test-TcpReach $ip){ return $true } }; return $false }
function Test-ControlSite { foreach($s in $ControlSites){ if((Test-HS $s $null 8) -ge 0){ return $true } }; return $false }

# =============================================================================
#  ADAPTÖR / DNS
# =============================================================================
function Is-Tunnel($ad){ return (("" + $ad.InterfaceDescription + ' ' + $ad.Name) -match 'VPN|WireGuard|WARP|Wintun|TAP-|TAP |TUN|OpenVPN|Proton|Nord|Hamachi|ZeroTier|Tailscale|Fortinet|Cisco AnyConnect') }
# Sadece internete gerçekten çıkan (varsayılan rotası olan) fiziksel adaptörler. Hyper-V/VirtualBox/VPN dokunulmaz.
function Get-EgressAdapters {
  $idx = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0', '::/0' -ErrorAction SilentlyContinue |
           Where-Object { $_.NextHop -and $_.NextHop -ne '0.0.0.0' -and $_.NextHop -ne '::' } |
           Select-Object -ExpandProperty ifIndex -Unique)
  $ads = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and ($idx -contains $_.ifIndex) -and -not (Is-Tunnel $_) })
  if(-not $ads.Count){ $ads = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }) }
  return $ads
}
function Split-Servers($s){ return @(("" + $s) -split '[,\s]+' | Where-Object { $_ }) }
# İlk değişiklikten önce adaptörün DNS'ini kaydet (kaldırırken birebir geri yüklemek için).
function Snapshot-Adapter($ad){
  $st = Get-State
  $snap = PGet $st 'snapshot'
  if(-not $snap){ $snap = [pscustomobject]@{ takenAt = (Get-Date).ToString('s'); adapters = @() }; PSet $st 'snapshot' $snap }
  $list = @(PGet $snap 'adapters' @())
  if($list | Where-Object { $_.guid -eq $ad.InterfaceGuid }){ return }
  $v4 = (Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($ad.InterfaceGuid)" -ErrorAction SilentlyContinue).NameServer
  $v6 = (Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters\Interfaces\$($ad.InterfaceGuid)" -ErrorAction SilentlyContinue).NameServer
  $v4l = Split-Servers $v4; $v6l = Split-Servers $v6
  # Eski sürümün bıraktığı loopback DNS'i "kullanıcı ayarı" sanma -> otomatik say.
  if($v4l -contains '127.0.0.1'){ $v4l = @() }
  if($v6l -contains '::1'){ $v6l = @() }
  $list += [pscustomobject]@{ guid = $ad.InterfaceGuid; name = $ad.Name; v4 = ($v4l -join ','); v6 = ($v6l -join ',') }
  PSet $snap 'adapters' $list
  Save-State
}
function Snapshot-Globals {
  $st = Get-State; $snap = PGet $st 'snapshot'
  if(-not $snap){ $snap = [pscustomobject]@{ takenAt = (Get-Date).ToString('s'); adapters = @() }; PSet $st 'snapshot' $snap }
  if(-not $snap.PSObject.Properties['timestamps']){
    $ts = $null; try { $ts = "" + (Get-NetTCPSetting -SettingName Internet -ErrorAction Stop).Timestamps } catch {}
    PSet $snap 'timestamps' $ts
  }
  if(-not $snap.PSObject.Properties['autoDoh']){
    $v = (Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters' -ErrorAction SilentlyContinue).EnableAutoDoh
    PSet $snap 'autoDoh' $(if($null -eq $v){ 'absent' } else { "$v" })
  }
  Save-State
}
function Set-AdapterDns($ad, [string[]]$servers){
  Snapshot-Adapter $ad
  try { Set-DnsClientServerAddress -InterfaceIndex $ad.ifIndex -ServerAddresses $servers -ErrorAction Stop; Log ("  DNS -> {0}: {1}" -f ($servers -join ', '), $ad.Name) 'ok'; return $true }
  catch { Log ("  [!] DNS ayarlanamadı ({0}): {1}" -f $ad.Name, $_.Exception.Message) 'warn'; return $false }
}
function Set-EgressDns([string[]]$servers){ foreach($ad in (Get-EgressAdapters)){ Set-AdapterDns $ad $servers | Out-Null }; ipconfig /flushdns | Out-Null; Clear-DnsClientCache -ErrorAction SilentlyContinue }
# Not: "return ,@(...)" -> tek elemanlı dizi de DİZİ olarak döner (yoksa PowerShell onu düz metne açar ve [0] ilk KARAKTER olur).
function Get-AdapterV4Dns($ad){ try { return ,@((Get-DnsClientServerAddress -InterfaceIndex $ad.ifIndex -AddressFamily IPv4 -ErrorAction Stop).ServerAddresses) } catch { return ,@() } }
function Restore-Dns {
  $snap = PGet (Get-State) 'snapshot'
  $list = @(PGet $snap 'adapters' @())
  $done = @()
  foreach($s in $list){
    $ad = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceGuid -eq $s.guid } | Select-Object -First 1
    if(-not $ad){ continue }
    try {
      Set-DnsClientServerAddress -InterfaceIndex $ad.ifIndex -ResetServerAddresses -ErrorAction Stop
      $static = @(Split-Servers $s.v4) + @(Split-Servers $s.v6)
      if($static.Count){ Set-DnsClientServerAddress -InterfaceIndex $ad.ifIndex -ServerAddresses $static -ErrorAction Stop; Log ("  DNS eski haline döndü ({0}): {1}" -f $ad.Name, ($static -join ', ')) 'ok' }
      else { Log ("  DNS otomatiğe döndü: {0}" -f $ad.Name) 'ok' }
      $done += $s.guid
    } catch { Log ("  [!] DNS geri yüklenemedi ({0}): {1}" -f $ad.Name, $_.Exception.Message) 'warn' }
  }
  # anlık görüntüsü olmayan ama hâlâ loopback'e bakan adaptörler (v1 kurulumu) -> otomatiğe al
  foreach($ad in (Get-NetAdapter -ErrorAction SilentlyContinue)){
    if($done -contains $ad.InterfaceGuid){ continue }
    if((Get-AdapterV4Dns $ad) -contains '127.0.0.1'){
      try { Set-DnsClientServerAddress -InterfaceIndex $ad.ifIndex -ResetServerAddresses -ErrorAction Stop; Log ("  DNS otomatiğe döndü: {0}" -f $ad.Name) 'ok' } catch {}
    }
  }
  ipconfig /flushdns | Out-Null
}

# =============================================================================
#  ÖN KONTROL / ÇAKIŞMALAR / ANTİVİRÜS
# =============================================================================
function Get-SacState { try { return [int](Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -ErrorAction Stop).VerifiedAndReputablePolicyState } catch { return -1 } }
function Preflight {
  Head (T '[önkontrol] Ortam denetimi' '[preflight] Environment check')
  $fatal = @()
  if(-not [Environment]::Is64BitOperatingSystem){ $fatal += (T '64-bit Windows gerekli (winws/WinDivert x64).' '64-bit Windows required (winws/WinDivert are x64).') }
  if($PSVersionTable.PSVersion.Major -lt 5){ $fatal += (T 'PowerShell 5+ gerekli.' 'PowerShell 5+ required.') }
  $online = Test-Online
  if(-not $online){ $fatal += (T 'İnternet yok (1.1.1.1:443 / 8.8.8.8:443 erişilemedi).' 'No internet (1.1.1.1:443 / 8.8.8.8:443 unreachable).') }
  $os = [Environment]::OSVersion.Version
  Log ("  Windows        : {0} (build {1})" -f $(if($os.Build -ge 22000){'11'}else{'10'}), $os.Build)
  Log ("  PowerShell     : {0}" -f $PSVersionTable.PSVersion)
  Log ("  " + (T 'İnternet       : ' 'Internet       : ') + $(if($online){ T 'var' 'yes' } else { T 'YOK' 'NO' })) $(if($online){'i'}else{'err'})
  try {
    $r  = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1
    $ad = Get-NetAdapter -InterfaceIndex $r.ifIndex -ErrorAction SilentlyContinue
    if($ad -and (Is-Tunnel $ad)){ Log ((T "  [!] Varsayılan rota bir tünel: '{0}'. Önce VPN/WARP'ı kapat, yoksa sonuçlar ISP'yi değil tüneli ölçer." "  [!] Default route is a tunnel: '{0}'. Turn off VPN/WARP first, or results measure the tunnel, not the ISP.") -f $ad.Name) 'warn' }
    elseif($ad){ Log ((T '  Varsayılan rota : {0} (fiziksel - iyi)' '  Default route  : {0} (physical - good)') -f $ad.Name) }
  } catch {}
  if((Get-Service CloudflareWARP -ErrorAction SilentlyContinue).Status -eq 'Running'){ Log (T '  [!] Cloudflare WARP servisi çalışıyor; bağlıysa önce bağlantıyı kes.' '  [!] Cloudflare WARP service is running; disconnect it first if connected.') 'warn' }
  try {
    $u = Get-NetUDPEndpoint -LocalPort 53 -ErrorAction SilentlyContinue | Select-Object -First 1
    if($u){ $p = Get-Process -Id $u.OwningProcess -ErrorAction SilentlyContinue
            if($p -and $p.ProcessName -notmatch 'dnscrypt'){ Log ((T "  [!] 53 portunu '{0}' kullanıyor (Pi-hole/Acrylic vb.). dnscrypt DoH çakışabilir." "  [!] Port 53 is used by '{0}' (Pi-hole/Acrylic etc.). dnscrypt DoH may conflict.") -f $p.ProcessName) 'warn' } }
  } catch {}
  foreach($pi in @(Find-ProxyIssues)){ Log ("  [!] " + $pi + (T ' -- açıksa ölçümler ISP''yi değil proxy''yi ölçer; Test/Kur sırasında kapat.' ' -- if active, measurements reflect the proxy, not the ISP; turn it off during Test/Install.')) 'warn' }
  $ho = @(Find-HostsOverrides)
  if($ho.Count){
    Log (T '  [!] hosts dosyasında engelli sitelere elle yazılmış IP var (DNS''i ezer, siteleri bozabilir):' '  [!] hosts file has manual IPs for blocked sites (overrides DNS, can break the sites):') 'warn'
    foreach($h in $ho){ Log ("      $h") 'warn' }
    Log ((T '      Gerekmiyorsa bu satırları sil: {0}' '      Remove these lines if not needed: {0}') -f (Join-Path $env:SystemRoot 'System32\drivers\etc\hosts')) 'dim'
  }  $sac = Get-SacState
  if($sac -eq 1){
    Log (T '  [!] Akıllı Uygulama Denetimi (Smart App Control) AÇIK. İmzasız winws.exe engellenir ve istisna eklenemez.' '  [!] Smart App Control is ON. It blocks the unsigned winws.exe and allows no exclusions.') 'err'
    Log (T '      Tek çözüm: Windows Güvenliği > Uygulama ve tarayıcı denetimi > Akıllı Uygulama Denetimi > Kapalı. (Geri açmak için Windows sıfırlaması gerekebilir.)' '      Only fix: Windows Security > App & browser control > Smart App Control > Off. (Re-enabling may require a Windows reset.)') 'warn'
    Mark 'SAC'
    if((Load-Config).zapret -and (On (Load-Config).zapret)){ $fatal += (T 'Smart App Control açık (winws çalışamaz).' 'Smart App Control is on (winws cannot run).') }
  } elseif($sac -eq 2){ Log (T '  not: Smart App Control "değerlendirme" modunda; ileride açılırsa winws engellenebilir.' '  note: Smart App Control is in evaluation mode; if it turns on later, winws may be blocked.') 'dim' }
  if($fatal.Count){ foreach($f in $fatal){ Log ("  " + (T 'KRİTİK: ' 'CRITICAL: ') + $f) 'err' }; Fail 10 '' }
}

# ---------------- çakışan araçlar ----------------
# WinDivert'i kullanan ya da aynı işi yapan DPI araçları (aynı anda çalışırsa birbirini bozar). Ada değil ÇALIŞTIRDIĞI DOSYAYA bakılır.
$ConflictExe = 'goodbyedpi|winws|ciadpi|byedpi|spoofdpi|dpitunnel|dpi-tunnel|green-?tunnel|powertunnel|nodpi'
# Proxy/VPN istemcileri: durdurulmaz, sadece uyarılır (açıksa ölçümler ISP'yi değil proxy'yi ölçer).
$ProxyExe    = 'v2rayN|v2ray|xray|sing-box|hiddify|nekoray|nekobox|psiphon|warp-plus|clash|mihomo|outline|lantern|ultrasurf'
function Test-OurPath([string]$p){ return ("$p" -like "*$Root*") }
# -Quick: servis + işlem (hızlı; arayüz için). Tam tarama ayrıca otomatik başlatmalara (Run, zamanlanmış görev) bakar.
function Find-Conflicts([switch]$Quick){
  $c = @(); $ourPids = @()
  foreach($s in @(Get-CimInstance Win32_Service -Property Name, PathName, StartMode, State, ProcessId -ErrorAction SilentlyContinue)){
    $pn = "" + $s.PathName
    # bizim servisimizin işlemi (yol okunamıyorsa -- yetkisiz bağlam -- ad 'zapret' ise bizimki say)
    if($s.ProcessId -and ((Test-OurPath $pn) -or ($s.Name -eq 'zapret' -and -not $pn))){ $ourPids += [int]$s.ProcessId }
    if($s.Name -like 'WinDivert*'){ continue }   # sürücü servisi; kim kullanıyorsa onunla birlikte durur
    if($s.Name -eq 'dnscrypt-proxy'){
      if($pn -and -not (Test-OurPath $pn)){ $c += [pscustomobject]@{ Kind = 'foreign-dns'; Name = (T 'dnscrypt-proxy (başka bir kurulum, ör. Simple DNSCrypt)' 'dnscrypt-proxy (another install, e.g. Simple DNSCrypt)'); Ref = $s.Name; Detail = $pn } }
      continue
    }
    if($pn -notmatch "($ConflictExe)(\.exe)?" -or (Test-OurPath $pn)){ continue }
    if($s.Name -eq 'zapret'){ $c += [pscustomobject]@{ Kind = 'foreign'; Name = (T 'zapret (başka bir kurulum)' 'zapret (another install)'); Ref = 'zapret'; Detail = $pn }; continue }
    if($s.StartMode -eq 'Disabled' -and $s.State -ne 'Running'){ continue }
    $c += [pscustomobject]@{ Kind = 'svc'; Name = $s.Name; Ref = $s.Name; Detail = $pn; Start = $s.StartMode }
  }
  foreach($p in @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match "^($ConflictExe)$" })){
    if($ourPids -contains $p.Id){ continue }   # kendi zapret servisimizin winws'i
    # yol: önce WMI (SYSTEM işlemleri için de çalışır), olmazsa .NET
    $path = $null; try { $path = (Get-CimInstance Win32_Process -Filter ("ProcessId=" + $p.Id) -Property ExecutablePath -ErrorAction Stop).ExecutablePath } catch {}
    if(-not $path){ try { $path = $p.Path } catch {} }
    if($path -and (Test-OurPath $path)){ continue }
    $c += [pscustomobject]@{ Kind = 'proc'; Name = $(if($path){ "$($p.ProcessName) ($path)" } else { $p.ProcessName }); Ref = $p.Id; Detail = $path }
  }
  if($Quick){ return $c }
  # açılışta kendini yeniden başlatanlar: Run anahtarları
  foreach($k in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run')){
    $props = Get-ItemProperty -LiteralPath $k -ErrorAction SilentlyContinue
    if(-not $props){ continue }
    foreach($pp in $props.PSObject.Properties){
      if($pp.Name -like 'PS*'){ continue }
      if(("" + $pp.Value) -match "($ConflictExe)(\.exe)?" -and -not (Test-OurPath $pp.Value)){ $c += [pscustomobject]@{ Kind = 'run'; Name = (T 'açılışta başlatma: ' 'autostart: ') + $pp.Name; Ref = $k; Key = $pp.Name; Detail = "" + $pp.Value } }
    }
  }
  # zamanlanmış görevler (COM ile: Get-ScheduledTask'tan ~4 kat hızlı)
  try {
    $svcCom = New-Object -ComObject Schedule.Service; $svcCom.Connect()
    $stack = New-Object Collections.Stack; $stack.Push($svcCom.GetFolder('\'))
    while($stack.Count){
      $fd = $stack.Pop(); foreach($sub in $fd.GetFolders(0)){ $stack.Push($sub) }
      $fpath = $(if($fd.Path -eq '\'){ '\' } else { $fd.Path + '\' })
      if($fpath -eq $TaskPath){ continue }
      foreach($tk in $fd.GetTasks(1)){
        if(-not $tk.Enabled){ continue }
        $cmd = (@(foreach($a in $tk.Definition.Actions){ if($a.Type -eq 0){ "$($a.Path) $($a.Arguments)" } }) -join ' ')
        if($cmd -match "($ConflictExe)(\.exe)?" -and -not (Test-OurPath $cmd)){ $c += [pscustomobject]@{ Kind = 'task'; Name = (T 'zamanlanmış görev: ' 'scheduled task: ') + $tk.Name; Ref = $fpath; Key = $tk.Name; Detail = $cmd } }
      }
    }
  } catch {}
  return $c
}
# Durdurulan/devre dışı bırakılan her şey state.json'a yazılır; Kaldır bunları eski haline getirir.
function Resolve-Conflicts($list){
  $st = Get-State
  $rec = @(PGet $st 'disabledConflicts' @())
  foreach($x in $list){
    switch($x.Kind){
      'svc' {
        Log ((T '  çakışan servis durdurulup devre dışı bırakılıyor (silinmiyor): {0}' '  stopping + disabling conflicting service (not deleting): {0}') -f $x.Name) 'warn'
        Stop-Service -Name $x.Ref -Force -ErrorAction SilentlyContinue; Set-Service -Name $x.Ref -StartupType Disabled -ErrorAction SilentlyContinue
        $rec += [pscustomobject]@{ kind = 'svc'; name = $x.Ref; start = "" + $x.Start }
      }
      'proc' { Log ((T '  çakışan işlem kapatılıyor: {0}' '  closing conflicting process: {0}') -f $x.Name) 'warn'; Stop-Process -Id $x.Ref -Force -ErrorAction SilentlyContinue }
      'run' {
        Log ((T '  açılışta başlatma kaydı yedeklenip kaldırılıyor: {0}' '  backing up + removing autostart entry: {0}') -f $x.Key) 'warn'
        $rec += [pscustomobject]@{ kind = 'run'; key = $x.Ref; name = $x.Key; value = $x.Detail }
        Remove-ItemProperty -LiteralPath $x.Ref -Name $x.Key -ErrorAction SilentlyContinue
      }
      'task' {
        Log ((T '  zamanlanmış görev devre dışı bırakılıyor: {0}' '  disabling scheduled task: {0}') -f $x.Key) 'warn'
        Disable-ScheduledTask -TaskPath $x.Ref -TaskName $x.Key -ErrorAction SilentlyContinue | Out-Null
        $rec += [pscustomobject]@{ kind = 'task'; path = $x.Ref; name = $x.Key }
      }
      'foreign'     { Log (T '  başka bir kurulumun zapret servisi devralınacak (aynı servis adı; kaldırınca geri gelmez).' '  another install''s zapret service will be taken over (same name; not restored on uninstall).') 'warn' }
      'foreign-dns' { Log (T '  başka bir dnscrypt-proxy kurulumu devralınacak (aynı servis adı; kaldırınca geri gelmez).' '  another dnscrypt-proxy install will be taken over (same name; not restored on uninstall).') 'warn' }
    }
  }
  PSet $st 'disabledConflicts' $rec; Save-State
  Start-Sleep -Milliseconds 500
}
# Kaldırırken: bizim durdurduğumuz araçları kurulum öncesi haline getir (başlatmadan; sadece başlangıç ayarlarını geri koy).
function Restore-Conflicts {
  foreach($r in @(PGet (Get-State) 'disabledConflicts' @())){
    try {
      switch($r.kind){
        'svc'  { $mode = switch("" + $r.start){ 'Auto' { 'Automatic' } 'Manual' { 'Manual' } default { 'Manual' } }
                 Set-Service -Name $r.name -StartupType $mode -ErrorAction Stop; Log ((T '  {0} servisinin başlangıç türü geri yüklendi ({1})' '  restored start type of service {0} ({1})') -f $r.name, $mode) 'ok' }
        'run'  { Set-ItemProperty -LiteralPath $r.key -Name $r.name -Value $r.value -ErrorAction Stop; Log ((T '  açılışta başlatma kaydı geri yüklendi: {0}' '  restored autostart entry: {0}') -f $r.name) 'ok' }
        'task' { Enable-ScheduledTask -TaskPath $r.path -TaskName $r.name -ErrorAction Stop | Out-Null; Log ((T '  zamanlanmış görev yeniden etkinleştirildi: {0}' '  re-enabled scheduled task: {0}') -f $r.name) 'ok' }
      }
    } catch { Log ((T '  [!] geri yüklenemedi: {0} ({1})' '  [!] could not restore: {0} ({1})') -f $r.name, $_.Exception.Message) 'warn' }
  }
}
# Proxy / VPN istemcileri ve sistem proxy'si: durdurmayız, sadece uyarırız.
function Find-ProxyIssues {
  $out = @()
  foreach($p in @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match "^($ProxyExe)$" } | Select-Object -ExpandProperty ProcessName -Unique)){ $out += ((T 'çalışan proxy/VPN istemcisi: {0}' 'running proxy/VPN client: {0}') -f $p) }
  try {
    $ie = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
    if($ie.ProxyEnable -eq 1 -and $ie.ProxyServer){
      $ps = "" + $ie.ProxyServer
      if($ps -match '(127\.0\.0\.1|localhost|\[?::1\]?):(\d+)'){
        # yerel proxy = büyük ihtimalle proxy tabanlı bir DPI aracı (ByeDPI, SpoofDPI vb.); portu kim dinliyor?
        $who = $null
        try { $cn = Get-NetTCPConnection -LocalPort ([int]$Matches[2]) -State Listen -ErrorAction Stop | Select-Object -First 1; $who = (Get-Process -Id $cn.OwningProcess -ErrorAction Stop).ProcessName } catch {}
        $out += ((T 'Windows proxy''si yerel bir programa yönlendiriyor ({0}{1}) -- ByeDPI/SpoofDPI gibi proxy tabanlı bir DPI aracı olabilir' 'Windows proxy points to a local program ({0}{1}) -- may be a proxy-based DPI tool like ByeDPI/SpoofDPI') -f $ps, $(if($who){ ", $who" } else { '' }))
      } else { $out += ((T 'Windows sistem proxy''si açık: {0}' 'Windows system proxy is on: {0}') -f $ps) }
    }
  } catch {}
  return $out
}
# hosts dosyasında engelli sitelere elle yazılmış eski IP'ler: DNS'i (DoH dahil) ezer, siteyi bozabilir.
function Find-HostsOverrides {
  $hf = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
  if(-not (Test-Path -LiteralPath $hf)){ return @() }
  $pat = '(^|\.)(discord(app)?\.(com|gg|media|net)|youtube\.com|googlevideo\.com|ytimg\.com|' + (($DefaultTargets | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')$'
  $out = @()
  foreach($ln in (Get-Content -LiteralPath $hf -ErrorAction SilentlyContinue)){
    $l = ($ln -replace '#.*$', '').Trim()
    if(-not $l){ continue }
    $parts = @($l -split '\s+')
    if($parts.Count -lt 2){ continue }
    foreach($hn in $parts[1..($parts.Count - 1)]){ if($hn -match $pat -and $parts[0] -notmatch '^(0\.0\.0\.0|127\.0\.0\.1|::1?)$'){ $out += $l; break } }
  }
  return $out
}
function Get-ActiveAV { try { return @(Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop | Select-Object -ExpandProperty displayName) } catch { return @() } }
function Get-ThirdPartyAV { return ,@(Get-ActiveAV | Where-Object { $_ -and $_ -notmatch 'Windows Defender|Microsoft Defender' }) }
function Show-AVGuidance([string]$name){
  $steps = switch -Regex ($name){
    'Kaspersky'    { 'Kaspersky: Ayarlar > Tehditler ve Dışlamalar > Dışlamaları Yönet > Ekle > Klasör'; break }
    'ESET'         { 'ESET: F5 (Gelişmiş ayarlar) > Algılama Motoru > Dışlamalar > Ekle'; break }
    'Avast'        { 'Avast: Menü > Ayarlar > Genel > İstisnalar > İstisna Ekle > Klasör'; break }
    'AVG'          { 'AVG: Menü > Ayarlar > Genel > İstisnalar > İstisna Ekle'; break }
    'Bitdefender'  { 'Bitdefender: Koruma > Antivirüs > Ayarlar > İstisnaları Yönet > İstisna Ekle'; break }
    'Norton'       { 'Norton: Ayarlar > Antivirüs > Taramalar ve Riskler > Hariç Tutulanlar > Yapılandır'; break }
    'McAfee'       { 'McAfee: Gerçek Zamanlı Tarama > Hariç tutulan dosyalar > Ekle'; break }
    'Malwarebytes' { 'Malwarebytes: Ayarlar > İzin Verilenler > İzin ver > Klasör'; break }
    'Reason|RAV'   { 'RAV/Reason: Koruma > Kurallar > İstisna ekle'; break }
    default        { T 'Windows Güvenliği > Virüs ve tehdit koruması > Ayarları yönet > Dışlamalar > Dışlama ekle > Klasör' 'Windows Security > Virus & threat protection > Manage settings > Exclusions > Add an exclusion > Folder' }
  }
  Log ("      -> $steps") 'warn'
  Log ((T '      -> Dışlanacak klasör: {0}' '      -> Folder to exclude: {0}') -f $Root) 'warn'
}
# Bilgi amaçlı: istisna EKLEMEYİZ (kendine istisna ekleyen script = zararlı yazılım kalıbı). Sadece durumu söyleriz.
function Show-AVInfo {
  $third = Get-ThirdPartyAV
  if($third.Count){
    Log ((T '  Aktif antivirüs: {0}' '  Active antivirus: {0}') -f ($third -join ', '))
    if(($third -join ' ') -match 'Kaspersky|ESET|Bitdefender|Avast|AVG'){ Log (T '  not: bu antivirüsün web/HTTPS taraması winws''in sahte paketlerini bozabilir; sorun olursa HTTPS taramasını kapat.' '  note: this AV''s web/HTTPS scanning can break winws fake packets; disable HTTPS scanning if you hit issues.') 'dim' }
    return
  }
  try {
    $mp = Get-MpComputerStatus -ErrorAction Stop
    if(-not $mp.RealTimeProtectionEnabled){ Log (T '  Defender gerçek zamanlı koruma kapalı.' '  Defender real-time protection is off.') 'dim'; return }
    Log (T '  Defender açık. winws yanlış pozitif olarak engellenirse sana adım adım yol göstereceğim.' '  Defender is on. If it false-flags winws, you will get step-by-step guidance.') 'dim'
  } catch {}
}
# winws/WinDivert antivirüs tarafından engellendiğinde: tam olarak neyin, hangi isimle yakalandığını söyle + arayüze yönlendirme işareti.
function Report-AVBlock {
  $avName = $null; $threat = $null
  try {
    $det = @(Get-MpThreatDetection -ErrorAction Stop | Where-Object { ($_.Resources -join ' ') -like "*zapret-auto*" } | Sort-Object InitialDetectionTime -Descending)
    if($det.Count){ $avName = 'Windows Defender'; $threat = (Get-MpThreat -ThreatID $det[0].ThreatID -ErrorAction SilentlyContinue).ThreatName }
  } catch {}
  if(-not $avName){ $t = Get-ThirdPartyAV; $avName = $(if($t.Count){ $t[0] } else { 'Windows Defender' }) }
  Log ''
  Log ((T '  ANTİVİRÜS ENGELİ: {0} winws/WinDivert dosyalarını engelledi{1}.' '  ANTIVIRUS BLOCK: {0} blocked the winws/WinDivert files{1}.') -f $avName, $(if($threat){ " ($threat)" } else { '' })) 'err'
  Log (T '      winws açık kaynak ve yasal bir araç; ağ paketlerini değiştirdiği için "HackTool" olarak YANLIŞ işaretleniyor.' '      winws is a legitimate open-source tool; it is FALSELY flagged as "HackTool" because it modifies network packets.') 'warn'
  Log (T '      Çözüm: klasörü istisnaya ekle, sonra Kur/Onar''a tekrar bas:' '      Fix: add the folder as an exclusion, then press Install/Repair again:') 'warn'
  Show-AVGuidance $avName
  if($avName -match 'Defender'){ Log (T '      (Kurcalama Koruması açıksa istisnayı yine de elle ekleyebilirsin; bu araç istisnayı kendisi EKLEMEZ.)' '      (Even with Tamper Protection on you can add it manually; this tool never adds exclusions by itself.)') 'dim' }
  Mark ("AV|{0}|{1}" -f $avName, $Root)
}

# =============================================================================
#  KLASÖR, İNDİRME, BAĞIMLILIKLAR
# =============================================================================
# Nöbetçi buradaki betiği SYSTEM olarak çalıştırır -> normal kullanıcılar bu klasörü DEĞİŞTİREMEMELİ (sadece okur).
# İzin SADECE klasörün kendisine verilir; alt dosya/klasörler /reset ile ondan devralır.
# (v2.0.0 hatası: /T ile dosyalara da /inheritance:r uygulanıyordu, dosyalar izinsiz kalıyordu. Bu çağrı onu da onarır.)
function Repair-Acl {
  if(-not (Is-Admin) -or -not (Test-Path -LiteralPath $Root)){ return }
  & icacls.exe $Root /setowner '*S-1-5-32-544' /T /C /Q 2>&1 | Out-Null
  & icacls.exe $Root /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' /C /Q 2>&1 | Out-Null
  & icacls.exe (Join-Path $Root '*') /reset /T /C /Q 2>&1 | Out-Null
}
function Ensure-Home {
  foreach($d in @($Root, $CacheDir)){ if(-not (Test-Path -LiteralPath $d)){ New-Item -ItemType Directory -Path $d -Force | Out-Null } }
  Repair-Acl
  # v1 göçü: eski zip'leri önbelleğe taşı (çevrimdışı paket için lazım)
  foreach($m in @(@((Join-Path $ZapDir 'zapret.zip'), 'zapret'), @((Join-Path $DnsDir 'dnscrypt.zip'), 'dnscrypt'))){
    $old = $m[0]; $p = $Pkgs[$m[1]]; $dst = Join-Path $CacheDir $p.File
    if((Test-Path -LiteralPath $old) -and -not (Test-Path -LiteralPath $dst)){
      if((Get-FileHash -LiteralPath $old -Algorithm SHA256).Hash -eq $p.Sha){ Move-Item -LiteralPath $old -Destination $dst -Force -ErrorAction SilentlyContinue }
    }
  }
}
function Get-LatestAsset([string]$repo, [string]$pattern){
  try {
    $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -Headers @{ 'User-Agent' = 'zapret-auto' } -TimeoutSec 15 -UseBasicParsing
    $a = $rel.assets | Where-Object { $_.name -like $pattern } | Select-Object -First 1
    if($a){ return @{ Url = $a.browser_download_url; File = $a.name } }
  } catch {}
  return $null
}
function Get-File([string]$url, [string]$out, [string]$sha){
  for($try = 1; $try -le 2; $try++){
    try {
      Log ((T '  indiriliyor (deneme {1}): {0}' '  downloading (try {1}): {0}') -f $url, $try)
      Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing -TimeoutSec 180
      if((Test-Path -LiteralPath $out) -and (Get-Item -LiteralPath $out).Length -gt 10000){
        if(-not $sha){ return $true }
        if((Get-FileHash -LiteralPath $out -Algorithm SHA256).Hash -eq $sha){ Log (T '    SHA256 doğrulandı.' '    SHA256 verified.') 'ok'; return $true }
        Log (T '    HATA: SHA256 uyuşmadı (bozuk/kurcalanmış indirme). Reddedildi.' '    ERROR: SHA256 mismatch (corrupt/tampered download). Rejected.') 'err'
        Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
      }
    } catch { Log ((T '    başarısız: {0}' '    failed: {0}') -f $_.Exception.Message) 'warn' }
    Start-Sleep -Seconds 2
  }
  return $false
}
# Paket zip'ini önbellekte hazır et: önbellek -> .bat'ın yanı -> sabitli URL -> (son çare) en yeni sürüm
function Ensure-Zip([string]$kind){
  $p = $Pkgs[$kind]
  $cached = Join-Path $CacheDir $p.File
  if((Test-Path -LiteralPath $cached) -and (Get-FileHash -LiteralPath $cached -Algorithm SHA256).Hash -eq $p.Sha){
    Log ((T '  {0}: önbellekte hazır ({1}), SHA256 doğrulandı -- indirme yok.' '  {0}: already cached ({1}), SHA256 verified -- no download.') -f $p.File, $CacheDir) 'dim'
    return $cached
  }
  if($env:ZA_SRC -and (Test-Path -LiteralPath $env:ZA_SRC)){
    $loc = Get-ChildItem -LiteralPath $env:ZA_SRC -Filter $p.Pattern -ErrorAction SilentlyContinue | Select-Object -First 1
    if($loc){
      $h = (Get-FileHash -LiteralPath $loc.FullName -Algorithm SHA256).Hash
      if($h -eq $p.Sha){ Log ((T '  yerel dosya kullanılıyor: {0}' '  using local file: {0}') -f $loc.Name) 'ok'; Copy-Item -LiteralPath $loc.FullName -Destination $cached -Force; return $cached }
      Log ((T '  [!] yanındaki {0} sabitli sürümle eşleşmiyor (SHA256 farklı); kullanılmıyor.' '  [!] the {0} next to the .bat does not match the pinned version (SHA256 differs); ignored.') -f $loc.Name) 'warn'
    }
  }
  if(Get-File $p.Url $cached $p.Sha){ return $cached }
  $l = Get-LatestAsset $p.Repo $p.Pattern
  if($l){
    $dst = Join-Path $CacheDir $l.File
    Log ((T '  sabitli adres çalışmadı -> en yeni sürüm deneniyor: {0} (SHA sabitlenemez, dosyalar tek tek doğrulanacak)' '  pinned URL failed -> trying latest release: {0} (cannot pin SHA; files will be validated individually)') -f $l.File) 'warn'
    if(Get-File $l.Url $dst $null){ return $dst }
  }
  return $null
}
function Test-AVMessage([string]$m){ return ($m -match 'vir[uü]s|istenmeyebilecek|potentially unwanted|malware|threat|tehdit') }
$script:BIN = $null; $script:BUNDLE = $null; $script:LISTS = $null
function Ensure-Zapret {
  $w = Get-ChildItem -LiteralPath $ZapDir -Recurse -Filter 'winws.exe' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if(-not $w){
    New-Item -ItemType Directory -Force -Path $ZapDir | Out-Null
    $zip = Ensure-Zip 'zapret'
    if(-not $zip){ Fail 20 (T 'HATA: zapret paketi indirilemedi. Zip dosyasını bu .bat''ın yanına koyup tekrar dene.' 'ERROR: could not download the zapret package. Put the zip next to this .bat and retry.') }
    try { Expand-Archive -LiteralPath $zip -DestinationPath $ZapDir -Force -ErrorAction Stop }
    catch { $em = "$_"; if(Test-AVMessage $em){ Report-AVBlock; Fail 21 '' } else { Fail 21 ((T 'HATA: arşiv açılamadı: {0}' 'ERROR: could not extract archive: {0}') -f $em) } }
    $w = Get-ChildItem -LiteralPath $ZapDir -Recurse -Filter 'winws.exe' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  }
  if(-not $w){ Report-AVBlock; Fail 22 '' }
  $script:BIN    = $w.Directory.FullName
  $script:BUNDLE = $w.Directory.Parent.FullName
  $script:LISTS  = Join-Path $script:BUNDLE 'lists'
  foreach($f in @('WinDivert.dll', 'WinDivert64.sys', 'cygwin1.dll')){ if(-not (Test-Path -LiteralPath (Join-Path $script:BIN $f))){ Report-AVBlock; Fail 22 '' } }
  if(-not (Test-Path -LiteralPath $AutoList)){ New-Item -ItemType File -Path $AutoList -Force | Out-Null }
  # Paket zip'i *-user.txt dosyalarını içermiyor; winws eksik listeyle hemen kapanır -> servis çöker. Oluştur.
  $userDefaults = @{ 'list-general-user.txt' = @('domain.example.abc'); 'list-exclude-user.txt' = @('domain.example.abc'); 'ipset-exclude-user.txt' = @('203.0.113.113/32') }
  foreach($uf in $userDefaults.Keys){ $ufp = Join-Path $script:LISTS $uf; if(-not (Test-Path -LiteralPath $ufp)){ Set-Content -LiteralPath $ufp -Value $userDefaults[$uf] -Encoding Ascii } }
  Log ("  zapret   : {0}" -f $script:BUNDLE) 'dim'
}
$script:DPEXE = $null; $script:DPDIR = $null
function Ensure-Dnscrypt {
  $dp = Get-ChildItem -LiteralPath $DnsDir -Recurse -Filter 'dnscrypt-proxy.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
  if(-not $dp){
    New-Item -ItemType Directory -Force -Path $DnsDir | Out-Null
    $zip = Ensure-Zip 'dnscrypt'
    if(-not $zip){ Log (T '  UYARI: dnscrypt indirilemedi.' '  WARNING: could not download dnscrypt.') 'warn'; return $false }
    try { Expand-Archive -LiteralPath $zip -DestinationPath $DnsDir -Force -ErrorAction Stop } catch { Log ((T '  UYARI: dnscrypt açılamadı: {0}' '  WARNING: could not extract dnscrypt: {0}') -f $_) 'warn'; return $false }
    $dp = Get-ChildItem -LiteralPath $DnsDir -Recurse -Filter 'dnscrypt-proxy.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
  }
  if(-not $dp){ return $false }
  $script:DPEXE = $dp.FullName; $script:DPDIR = $dp.Directory.FullName
  Log ("  dnscrypt : {0}" -f $script:DPDIR) 'dim'
  return $true
}

# =============================================================================
#  DNS TEŞHİSİ + DoH
# =============================================================================
function Diagnose-DNS {
  Head (T '[2] DNS zehirlenme kontrolü' '[2] DNS poisoning check')
  $d = 'discord.com'
  $sys = @(); try { $sys = @((Resolve-DnsName $d -Type A -ErrorAction Stop | Where-Object { $_.IPAddress }).IPAddress) } catch {}
  $real = Get-RealIP $d
  Log ((T '  sistem DNS  {0} -> {1}' '  system DNS  {0} -> {1}') -f $d, ($sys -join ','))
  Log ((T '  şifreli DoH {0} -> {1}' '  encrypted   {0} -> {1}') -f $d, $real)
  if($sys.Count -and $real -and ($sys -notcontains $real)){
    # Aynı CDN bloğunda olabilir; /16 ile kaba kontrol
    $same = $false; foreach($s in $sys){ if(($s -split '\.')[0..1] -join '.' -eq (($real -split '\.')[0..1] -join '.')){ $same = $true } }
    if(-not $same){ Log (T '  => DNS ZEHİRLİ görünüyor (sistem cevabı şifreli cevaptan farklı). DoH bunu düzeltir.' '  => DNS looks POISONED (system answer differs from encrypted answer). DoH fixes this.') 'warn'; return $true }
  }
  Log (T '  => DNS temiz görünüyor (ya da zaten şifreli DNS kullanılıyor).' '  => DNS looks clean (or encrypted DNS is already in use).') 'ok'
  return $false
}
function Select-DohEngine {
  $e = (Load-Config).dohengine
  if($e -in @('native', 'dnscrypt')){ return $e }
  if([Environment]::OSVersion.Version.Build -ge 22000 -and (Get-Command Add-DnsClientDohServerAddress -ErrorAction SilentlyContinue)){ return 'native' }
  return 'dnscrypt'
}
function Stop-Dnscrypt([switch]$Disable){
  if(Get-Service dnscrypt-proxy -ErrorAction SilentlyContinue){
    Stop-Service dnscrypt-proxy -Force -ErrorAction SilentlyContinue
    if($Disable){ Set-Service dnscrypt-proxy -StartupType Disabled -ErrorAction SilentlyContinue }
  }
}
function Setup-Dnscrypt {
  if(-not $script:DPEXE){ return $false }
  $cfg = Join-Path $script:DPDIR 'dnscrypt-proxy.toml'
  $names = ($DnscryptStamps.Keys | ForEach-Object { "'$_'" }) -join ', '
  $static = ($DnscryptStamps.Keys | ForEach-Object { "  [static.'$_']`r`n  stamp = '$($DnscryptStamps[$_])'" }) -join "`r`n"
  # Sunucular sabit (static) stamp ile tanımlı -> internetten resolver listesi İNDİRİLMEZ.
  $toml = @"
# zapret-auto tarafından üretildi. Sunucular IP ile tanımlı DoH (SNI gönderilmez).
listen_addresses = ['127.0.0.1:53', '[::1]:53']
max_clients = 250
server_names = [$names]
ipv4_servers = true
ipv6_servers = false
dnscrypt_servers = false
doh_servers = true
require_dnssec = false
require_nolog = false
require_nofilter = false
lb_strategy = 'p2'
bootstrap_resolvers = ['1.1.1.1:53', '8.8.8.8:53']
ignore_system_dns = true
netprobe_address = '1.1.1.1:53'
netprobe_timeout = 60
timeout = 5000
cache = true
cache_size = 4096
[query_log]
  file = ''
[nx_log]
  file = ''
[static]
$static
"@
  Set-Content -LiteralPath $cfg -Value $toml -Encoding Ascii
  # Servis yeniden kurulurken adaptör 127.0.0.1'e bakıyorsa arada DNS ölür (yarıda kesilirse internet gider).
  # Önce geçici olarak düz DNS'e al; yeni servis cevap verince çağıran taraf loopback'e geri alır.
  if(@(Get-EgressAdapters | Where-Object { (Get-AdapterV4Dns $_) -contains '127.0.0.1' }).Count){
    Log (T '  (dnscrypt yenilenirken DNS geçici olarak düz 1.1.1.1/8.8.8.8)' '  (DNS temporarily plain 1.1.1.1/8.8.8.8 while dnscrypt is refreshed)') 'dim'
    Set-EgressDns $PlainDns
  }
  & $script:DPEXE -service stop      2>&1 | Out-Null
  & $script:DPEXE -service uninstall 2>&1 | Out-Null
  & $script:DPEXE -config $cfg -service install 2>&1 | Out-Null
  & sc.exe config dnscrypt-proxy start= auto 2>&1 | Out-Null
  & sc.exe failure dnscrypt-proxy reset= 120 actions= restart/5000/restart/5000/restart/8000 2>&1 | Out-Null
  & $script:DPEXE -service start 2>&1 | Out-Null
  $ok = $false
  for($i = 0; $i -lt 20 -and -not $ok; $i++){
    Start-Sleep -Seconds 1
    try { if((Resolve-DnsName 'cloudflare.com' -Server '127.0.0.1' -Type A -DnsOnly -QuickTimeout -ErrorAction Stop | Where-Object { $_.IPAddress })){ $ok = $true } } catch {}
  }
  return $ok
}
function Get-DnsCacheServicePid { try { return [int](Get-CimInstance Win32_Service -Filter "Name='Dnscache'" -ErrorAction Stop).ProcessId } catch { return -1 } }
# Windows 11'in kendi DoH'u: ek program/servis yok. Doğrulama: DNS istemcisi (Dnscache) DoH sunucusuna 443'ten bağlanıyor mu?
function Test-NativeDohActive {
  $dpid = Get-DnsCacheServicePid
  if($dpid -le 0){ return $false }
  for($round = 0; $round -lt 3; $round++){
    Clear-DnsClientCache -ErrorAction SilentlyContinue
    foreach($n in @('www.microsoft.com', 'www.wikipedia.org', ("za{0}.cloudflare.com" -f (Get-Random)))){ try { Resolve-DnsName $n -Type A -ErrorAction SilentlyContinue | Out-Null } catch {} }
    Start-Sleep -Milliseconds 700
    $c = @(Get-NetTCPConnection -RemotePort 443 -ErrorAction SilentlyContinue | Where-Object { $_.OwningProcess -eq $dpid -and ($NativeDoh.Keys -contains $_.RemoteAddress) })
    if($c.Count){ return $true }
  }
  return $false
}
function Setup-NativeDoH {
  # Windows'un yerleşik DoH sunucu kayıtlarının ilk halini sakla (kaldırırken birebir geri yüklemek için)
  $snap = PGet (Get-State) 'snapshot'
  if($snap -and -not $snap.PSObject.Properties['dohServers']){
    $list = @()
    foreach($s in $NativeDoh.Keys){
      $e = Get-DnsClientDohServerAddress -ServerAddress $s -ErrorAction SilentlyContinue
      $list += [pscustomobject]@{ server = $s; exists = [bool]$e; template = $(if($e){ "" + $e.DohTemplate } else { '' }); autoUpgrade = $(if($e){ [bool]$e.AutoUpgrade } else { $false }); fallback = $(if($e){ [bool]$e.AllowFallbackToUdp } else { $false }) }
    }
    PSet $snap 'dohServers' $list; Save-State
  }
  try {
    foreach($s in $NativeDoh.Keys){
      $e = Get-DnsClientDohServerAddress -ServerAddress $s -ErrorAction SilentlyContinue
      if($e){ Set-DnsClientDohServerAddress -ServerAddress $s -DohTemplate $NativeDoh[$s] -AllowFallbackToUdp $false -AutoUpgrade $true -ErrorAction Stop | Out-Null }
      else  { Add-DnsClientDohServerAddress -ServerAddress $s -DohTemplate $NativeDoh[$s] -AllowFallbackToUdp $false -AutoUpgrade $true -ErrorAction Stop | Out-Null }
    }
    # DoH bilinen sunuculara otomatik yükseltme (Windows 11 "Şifreli DNS" ayarının sistem geneli karşılığı)
    Set-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters' -Name 'EnableAutoDoh' -Value 2 -Type DWord -ErrorAction Stop
  } catch { Log ((T '  [!] Windows DoH ayarlanamadı: {0}' '  [!] Could not configure Windows DoH: {0}') -f $_.Exception.Message) 'warn'; return $false }
  Stop-Dnscrypt -Disable
  foreach($ad in (Get-EgressAdapters)){
    Set-AdapterDns $ad @($NativeDoh.Keys) | Out-Null
    # Ayarlar uygulamasının arabirim başına "Şifreli DNS: Açık (otomatik şablon)" kaydı
    foreach($s in $NativeDoh.Keys){
      $fam = $(if($s -match ':'){ 'Doh6' } else { 'Doh' })
      $k = "HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\InterfaceSpecificParameters\$($ad.InterfaceGuid)\DohInterfaceSettings\$fam\$s"
      try { New-Item -Path $k -Force -ErrorAction Stop | Out-Null; New-ItemProperty -LiteralPath $k -Name 'DohFlags' -Value 1 -PropertyType QWord -Force -ErrorAction Stop | Out-Null } catch {}
    }
  }
  ipconfig /flushdns | Out-Null
  if(Test-NativeDohActive){ Log (T '  Windows yerleşik DoH aktif (DNS istemcisi 443 üzerinden şifreli konuşuyor).' '  Windows built-in DoH active (DNS client talks encrypted over 443).') 'ok'; return $true }
  Log (T '  [!] Windows DoH kuruldu ama şifreli trafik doğrulanamadı.' '  [!] Windows DoH configured but encrypted traffic could not be verified.') 'warn'
  return $false
}
function Remove-NativeDoH {
  foreach($ad in (Get-NetAdapter -ErrorAction SilentlyContinue)){
    foreach($fam in @('Doh', 'Doh6')){
      foreach($s in $NativeDoh.Keys){
        $k = "HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\InterfaceSpecificParameters\$($ad.InterfaceGuid)\DohInterfaceSettings\$fam\$s"
        if(Test-Path -LiteralPath $k){ Remove-Item -LiteralPath $k -Recurse -Force -ErrorAction SilentlyContinue }
      }
    }
  }
  foreach($d in @(PGet (PGet (Get-State) 'snapshot') 'dohServers' @())){
    try {
      if($d.exists){ Set-DnsClientDohServerAddress -ServerAddress $d.server -DohTemplate $d.template -AutoUpgrade ([bool]$d.autoUpgrade) -AllowFallbackToUdp ([bool]$d.fallback) -ErrorAction Stop | Out-Null }
      elseif(Get-Command Remove-DnsClientDohServerAddress -ErrorAction SilentlyContinue){ Remove-DnsClientDohServerAddress -ServerAddress $d.server -ErrorAction Stop -Confirm:$false | Out-Null }
    } catch {}
  }
  $prev = PGet (PGet (Get-State) 'snapshot') 'autoDoh' 'absent'
  $kp = 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters'
  if($prev -eq 'absent'){ Remove-ItemProperty -LiteralPath $kp -Name 'EnableAutoDoh' -ErrorAction SilentlyContinue }
  else { Set-ItemProperty -LiteralPath $kp -Name 'EnableAutoDoh' -Value ([int]$prev) -Type DWord -ErrorAction SilentlyContinue }
}
# DoH'u tercih edilen motorla uygula. Dönüş: 'native' | 'dnscrypt' | $null
function Apply-DoH {
  Head (T '[5] Şifreli DNS (DoH)' '[5] Encrypted DNS (DoH)')
  Snapshot-Globals
  $eng = Select-DohEngine
  if($eng -eq 'native'){
    Log (T '  Windows 11: yerleşik DoH kullanılıyor (ek program kurulmaz).' '  Windows 11: using built-in DoH (nothing extra installed).')
    if(Setup-NativeDoH){ PSet (Get-State) 'dohEngine' 'native'; Save-State; return 'native' }
    Log (T '  -> dnscrypt-proxy yedeğine geçiliyor.' '  -> falling back to dnscrypt-proxy.') 'warn'
    Remove-NativeDoH
  }
  if(-not (Ensure-Dnscrypt)){ return $null }
  if(Setup-Dnscrypt){
    Log (T '  dnscrypt-proxy DoH çözücüsü 127.0.0.1 üzerinde çalışıyor.' '  dnscrypt-proxy DoH resolver is running on 127.0.0.1.') 'ok'
    Set-EgressDns @('127.0.0.1', '::1')
    PSet (Get-State) 'dohEngine' 'dnscrypt'; Save-State
    return 'dnscrypt'
  }
  Log (T '  UYARI: dnscrypt cevap vermiyor.' '  WARNING: dnscrypt is not answering.') 'warn'
  Stop-Dnscrypt -Disable
  return $null
}
function Remove-DoH {
  Stop-Dnscrypt -Disable
  if((PGet (Get-State) 'dohEngine') -eq 'native'){ Remove-NativeDoH }
  PSet (Get-State) 'dohEngine' $null; Save-State
}

# =============================================================================
#  STRATEJİLER
# =============================================================================
$script:StratCache = $null
# Paketteki general*.bat dosyalarını oku. Satır devamlarını (^) birleştir, batch kaçışlarını (^!) çöz.
function Get-Strategies {
  if($script:StratCache){ return $script:StratCache }
  $out = @()
  foreach($f in @(Get-ChildItem -LiteralPath $script:BUNDLE -Filter 'general*.bat' -ErrorAction SilentlyContinue | Sort-Object Name)){
    try {
      $txt  = (Get-Content -LiteralPath $f.FullName -Raw) -replace '\^\r?\n', ' '
      $line = ($txt -split "`r?`n") | Where-Object { $_ -match 'winws\.exe' } | Select-Object -First 1
      if(-not $line){ continue }
      $tpl = ($line -replace '^.*?winws\.exe"?\s*', '').Replace('^!', '!').Trim()
      $s = New-Strategy $f.Name $f.BaseName $tpl
      # hostlist'li ana TCP 80/443 bölümü olmayan stratejiler (ör. ALT5: tüm trafiğe uygulanır) bu tasarıma uymaz -> sessizce atla
      if($s){ $out += $s }
    } catch {}
  }
  if(-not $out.Count){
    Log (T '  [!] Paketten strateji okunamadı -> gömülü yedek strateji (general ALT) kullanılacak.' '  [!] No strategies parsed from the bundle -> using embedded fallback (general ALT).') 'warn'
    $out = @(Get-EmbeddedStrategy)
  }
  $script:StratCache = $out
  return $out
}
function Get-EmbeddedStrategy { return (New-Strategy 'embedded (ALT)' 'embedded (ALT)' (($EmbeddedALT -replace '\s+', ' ').Trim())) }
function New-Strategy($name, $base, $tpl){
  $secs = @($tpl -split '\s--new\s')
  $main = $secs | Where-Object { $_ -match '--filter-tcp=80,443(\s|$)' -and $_ -match 'list-general\.txt' } | Select-Object -First 1
  if(-not $main){ return $null }
  $desync = ($main -replace '^.*?(--dpi-desync=)', '$1').Trim()
  if($desync -notmatch '^--dpi-desync='){ return $null }
  return [pscustomobject]@{ Name = $name; Base = $base; Template = $tpl; Desync = $desync }
}
function Expand-Args([string]$a){
  $game = $(if(On (Load-Config).game){ '1024-65535' } else { '12' })
  $a = $a.Replace('%BIN%', "$($script:BIN)\").Replace('%LISTS%', "$($script:LISTS)\").Replace('%GameFilterTCP%', $game).Replace('%GameFilterUDP%', $game).Replace('%GameFilter%', $game)
  return (($a -replace '\s+', ' ').Trim())
}
function Get-MissingFiles([string]$a){ return @([regex]::Matches($a, '="([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -match '^[A-Za-z]:\\' -and -not (Test-Path -LiteralPath $_) }) }
# Tam servis argümanı: stratejinin tamamı + ana TCP 80/443 bölümüne autohostlist.
function Build-Args($s){
  $a = Expand-Args $s.Template
  $secs = @($a -split '\s--new\s')
  for($i = 0; $i -lt $secs.Count; $i++){
    if($secs[$i] -match '--filter-tcp=80,443(\s|$)' -and $secs[$i] -match 'list-general\.txt'){
      $secs[$i] = $secs[$i] -replace '(--filter-tcp=80,443)(\s|$)', ('$1 --hostlist-auto="' + $AutoList + '"$2'); break
    }
  }
  return ($secs -join ' --new ')
}
function Kill-Winws {
  Get-Process winws -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Milliseconds 300
  & sc.exe stop WinDivert   2>&1 | Out-Null
  & sc.exe delete WinDivert 2>&1 | Out-Null
  & sc.exe stop WinDivert14   2>&1 | Out-Null
  & sc.exe delete WinDivert14 2>&1 | Out-Null
  Start-Sleep -Milliseconds 300
}
# Ölçüm için geçici winws (geçici .bat yok; doğrudan, penceresiz başlatılır)
function Start-ProbeWinws([string]$desync, [string]$doms){
  $psi = New-Object Diagnostics.ProcessStartInfo
  $psi.FileName = Join-Path $script:BIN 'winws.exe'
  $psi.Arguments = "--wf-tcp=443 --filter-tcp=443 --hostlist-domains=$doms " + (Expand-Args $desync)
  $psi.WorkingDirectory = $script:BIN
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  try { $p = [Diagnostics.Process]::Start($psi) } catch { return $false }
  Start-Sleep -Milliseconds 900
  return (-not $p.HasExited)
}
# Dönüş: geçen hedef sayısı; -1 = winws başlayamadı. $mustBeat: bu skoru geçemeyeceği anlaşılınca erken bırak.
function Test-Strategy($s, $targets, [int]$mustBeat = -1){
  $doms = ($targets | ForEach-Object { $_.Domain }) -join ','
  $miss = Get-MissingFiles (Expand-Args $s.Desync)
  if($miss.Count){ return -2 }
  $started = $false
  for($attempt = 1; $attempt -le 2 -and -not $started; $attempt++){ Kill-Winws; $started = Start-ProbeWinws $s.Desync $doms }
  if(-not $started){ return -1 }
  $pass = 0; $i = 0
  foreach($t in $targets){
    $i++
    $r = Test-HS $t.Domain $t.IP 5
    if($r -lt 0){ Start-Sleep -Milliseconds 300; $r = Test-HS $t.Domain $t.IP 5 }
    if($r -ge 0){ $pass++ }
    if(($pass + ($targets.Count - $i)) -le $mustBeat){ break }
  }
  Kill-Winws
  return $pass
}
function Bakeoff($targets, [string[]]$preferred){
  Head ((T '[4] Strateji taraması -- {0} hedef: {1}' '[4] Strategy bake-off -- {0} targets: {1}') -f $targets.Count, (($targets | ForEach-Object { $_.Domain }) -join ', '))
  $all = @(Get-Strategies)
  $ordered = @(); foreach($n in $preferred){ $ordered += @($all | Where-Object { $_.Name -eq $n }) }
  $ordered += @($all | Where-Object { $preferred -notcontains $_.Name })
  $best = $null; $bestScore = 0
  $k = 0
  foreach($s in $ordered){
    $k++; Mark ("SUB|{0}|{1}" -f ($k - 1), $ordered.Count)   # arayüz ilerleme çubuğu için ara ilerleme
    $score = Test-Strategy $s $targets $bestScore
    if($score -eq -1){ Log ((T '  {0,-30} winws BAŞLAYAMADI (sürücü kilitli?)' '  {0,-30} winws FAILED TO START (driver locked?)') -f $s.Base) 'warn'; continue }
    if($score -eq -2){ Log ((T '  {0,-30} eksik dosya, atlandı' '  {0,-30} missing files, skipped') -f $s.Base) 'dim'; continue }
    Log ("  {0,-30} {1}/{2}" -f $s.Base, $score, $targets.Count) $(if($score -eq $targets.Count){ 'ok' } elseif($score -gt 0){ 'i' } else { 'dim' })
    if($score -eq 0){ Assert-Online }   # 0 puan = belki internet koptu; öyleyse yanlış sonuç kaydetme
    if($score -gt $bestScore){ $bestScore = $score; $best = $s }
    if($bestScore -eq $targets.Count){ break }
  }
  if(-not $best){
    if(-not (Test-ControlSite)){ Fail 60 (T 'HATA: tarama sırasında bağlantı koptu (kontrol sitesi açılmıyor). İşlem iptal edildi.' 'ERROR: connection dropped during the bake-off (control site unreachable). Task cancelled.') }
    return $null
  }
  Log ((T '  KAZANAN: {0} ({1}/{2})' '  WINNER: {0} ({1}/{2})') -f $best.Base, $bestScore, $targets.Count) 'ok'
  return $best
}
function Get-DefaultStrategy {
  $s = @(Get-Strategies) | Where-Object { $_.Name -eq 'general (ALT).bat' } | Select-Object -First 1
  if($s){ return $s }
  return (Get-EmbeddedStrategy)
}
function Find-Strategy([string]$name){
  if($name -eq 'embedded (ALT)'){ return (Get-EmbeddedStrategy) }
  return (@(Get-Strategies) | Where-Object { $_.Name -eq $name } | Select-Object -First 1)
}

# ---------------- strateji hafızası (ağ parmak izine göre) ----------------
function Get-NetFingerprint {
  $raw = 'unknown'
  try {
    $r = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Sort-Object RouteMetric | Select-Object -First 1
    $n = Get-NetNeighbor -IPAddress $r.NextHop -ErrorAction SilentlyContinue | Select-Object -First 1
    if($n -and $n.LinkLayerAddress -and $n.LinkLayerAddress -notmatch '^(00-){5}00$'){ $raw = "mac:" + $n.LinkLayerAddress } else { $raw = "gw:" + $r.NextHop }
  } catch {}
  $sha = [Security.Cryptography.SHA256]::Create()
  return (($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($raw)) | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 12)
}
function Get-PreferredStrategies {
  $m = Read-Json $MemFile; $recs = @(PGet $m 'records' @())
  if(-not $recs.Count){ return @() }
  $fp = Get-NetFingerprint
  $mine = @($recs | Where-Object { $_.fp -eq $fp } | Sort-Object at -Descending | ForEach-Object { $_.strategy } | Select-Object -Unique)
  $glob = @($recs | Group-Object strategy | Sort-Object Count -Descending | ForEach-Object { $_.Name })
  return @(($mine + $glob) | Select-Object -Unique)
}
function Add-Memory([string]$name){
  $m = Read-Json $MemFile; $recs = @(PGet $m 'records' @())
  $recs += [pscustomobject]@{ fp = (Get-NetFingerprint); strategy = $name; at = (Get-Date).ToString('s') }
  if($recs.Count -gt 50){ $recs = $recs[($recs.Count - 50)..($recs.Count - 1)] }
  Write-Json ([pscustomobject]@{ records = $recs }) $MemFile
}

# =============================================================================
#  KEŞİF
# =============================================================================
function Get-LearnedDomains { if(Test-Path -LiteralPath $AutoList){ return @(Get-Content -LiteralPath $AutoList -ErrorAction SilentlyContinue | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch '^#' }) }; return @() }
function Discover-Targets {
  Head (T '[3] Bu ISP hangi siteleri DPI ile engelliyor?' '[3] Which sites does this ISP block with DPI?')
  $script:HasV6 = Test-TcpReach '2606:4700:4700::1111'
  if($script:HasV6){ Log (T '  (IPv6 çıkışı var - v4 + v6 kontrol ediliyor)' '  (IPv6 egress present - checking v4 + v6)') 'dim' }
  $cands = @((@(Get-LearnedDomains | Select-Object -First 4) + $DefaultTargets) | Select-Object -Unique)
  $found = @(); $tested = 0
  foreach($d in $cands){
    if($found.Count -ge 4 -or $tested -ge 12){ break }
    Mark ("SUB|{0}|{1}" -f $tested, [Math]::Min($cands.Count, 12))   # arayüz ilerleme çubuğu için ara ilerleme
    $ip = Get-RealIP $d
    if(-not $ip){ Assert-Online; Log ((T '  {0,-24} (IP yok, atlandı)' '  {0,-24} (no IP, skipped)') -f $d) 'dim'; continue }
    $tested++
    $ms4 = Test-HS $d $ip
    $ms6 = 0
    if($script:HasV6){ $ip6 = Get-RealIP6 $d; if($ip6){ $ms6 = Test-HS6 $d $ip6 } }
    if($ms4 -lt 0 -or $ms6 -lt 0){
      $tag = $(if($ms4 -lt 0 -and $ms6 -lt 0){ 'v4+v6' } elseif($ms4 -lt 0){ 'v4' } else { 'v6' })
      Log ((T '  {0,-24} ENGELLİ ({1})' '  {0,-24} BLOCKED ({1})') -f $d, $tag) 'warn'
      if($ms4 -lt 0){ $found += [pscustomobject]@{ Domain = $d; IP = $ip; Tag = $tag } }
    } else { Log ((T '  {0,-24} açık ({1} ms)' '  {0,-24} open ({1} ms)') -f $d, $ms4) 'dim' }
  }
  # "engelli" sonuçları gerçekten DPI mı, yoksa internet mi koptu? Engelsiz bir kontrol sitesiyle doğrula.
  if($found.Count){ Assert-Online; if(-not (Test-ControlSite)){ Fail 60 (T 'HATA: engelsiz kontrol sitesi de açılmıyor -> bağlantı sorunu var, DPI değil. İşlem iptal edildi; internet düzelince tekrar dene.' 'ERROR: the unblocked control site does not open either -> connection problem, not DPI. Task cancelled; retry when the internet is stable.') } }
  if(-not $tested){ Assert-Online; Fail 60 (T 'HATA: hiçbir sitenin adresi alınamadı (DoH erişilemiyor). İşlem iptal edildi.' 'ERROR: could not resolve any site (DoH unreachable). Task cancelled.') }
  return $found
}
function Add-ToAutoList([string[]]$domains){
  $have = Get-LearnedDomains
  $new = @($domains | Where-Object { $have -notcontains $_ })
  if($new.Count){ Add-Content -LiteralPath $AutoList -Value $new -Encoding Ascii }
}

# =============================================================================
#  winws SERVİSİ
# =============================================================================
$script:ServiceReplaced = $false
function Remove-ZapretService {
  if(Get-Service zapret -ErrorAction SilentlyContinue){
    Stop-Service zapret -Force -ErrorAction SilentlyContinue
    & sc.exe delete zapret 2>&1 | Out-Null
    for($i = 0; $i -lt 20 -and (Get-Service zapret -ErrorAction SilentlyContinue); $i++){ Start-Sleep -Milliseconds 500 }
  }
}
function Create-Service([string]$argStr, [string]$tag){
  $bp = '"' + (Join-Path $script:BIN 'winws.exe') + '" ' + $argStr
  $ok = $false
  for($i = 0; $i -lt 10 -and -not $ok; $i++){
    try { New-Service -Name 'zapret' -BinaryPathName $bp -DisplayName 'zapret (DPI bypass)' -StartupType Automatic -Description 'zapret DPI bypass - zapret-auto tarafından yönetilir' -ErrorAction Stop | Out-Null; $ok = $true }
    catch { Start-Sleep -Seconds 1 }   # "silinmek üzere işaretlendi" -> biraz bekle
  }
  if(-not $ok){ Fail 40 (T 'HATA: zapret servisi oluşturulamadı.' 'ERROR: could not create the zapret service.') }
  & sc.exe failure zapret reset= 120 actions= restart/5000/restart/5000/restart/8000 2>&1 | Out-Null
  Set-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\zapret' -Name 'zapret-discord-youtube' -Value $tag -ErrorAction SilentlyContinue
  Start-Service zapret -ErrorAction SilentlyContinue
}
function Wait-WinwsStable {
  $up = $false
  for($i = 0; $i -lt 14; $i++){ Start-Sleep -Milliseconds 500; if(Get-Process winws -ErrorAction SilentlyContinue){ $up = $true } elseif($up){ return $false } }
  return $up
}
# Dönüş: kurulu kalan strateji adı
function Install-Winws($s){
  Head ((T '[6] winws servisi kuruluyor (strateji: {0} + autohostlist)' '[6] Installing winws service (strategy: {0} + autohostlist)') -f $s.Base)
  Kill-Winws
  Remove-ZapretService
  $script:ServiceReplaced = $true
  & netsh.exe interface tcp set global timestamps=enabled 2>&1 | Out-Null
  $tries = @($s); if($s.Name -ne 'embedded (ALT)'){ $tries += (Get-EmbeddedStrategy) }
  foreach($t in $tries){
    $a = Build-Args $t
    $miss = Get-MissingFiles $a
    if($miss.Count){ Log ((T '  [!] {0}: eksik dosya ({1}) -> sonraki deneniyor' '  [!] {0}: missing file ({1}) -> trying next') -f $t.Base, ($miss[0])) 'warn'; continue }
    Create-Service $a ("{0} + autohostlist" -f $t.Base)
    if(Wait-WinwsStable){ Log ((T '  winws servisi çalışıyor: {0}' '  winws service running: {0}') -f $t.Base) 'ok'; return $t.Name }
    Log ((T '  [!] {0} ile winws ayakta kalmadı -> sonraki deneniyor' '  [!] winws did not stay up with {0} -> trying next') -f $t.Base) 'warn'
    Kill-Winws; Remove-ZapretService
  }
  # son çare: minimal tek bölüm
  Log (T '  [!] Minimal yedek yapılandırma deneniyor (autohostlist olmadan)...' '  [!] Trying minimal fallback config (no autohostlist)...') 'warn'
  $fb = '--wf-tcp=80,443 --filter-tcp=80,443 --hostlist="' + $script:LISTS + '\list-general.txt" --hostlist="' + $script:LISTS + '\list-general-user.txt" --dpi-desync=fake,fakedsplit --dpi-desync-repeats=6 --dpi-desync-fooling=ts --dpi-desync-fakedsplit-pattern=0x00 --dpi-desync-fake-tls="' + $script:BIN + '\tls_clienthello_www_google_com.bin"'
  Create-Service $fb 'minimal'
  if(Wait-WinwsStable){ Log (T '  winws minimal yapılandırmayla çalışıyor.' '  winws running with minimal config.') 'warn'; return 'minimal' }
  Log (T '  HATA: winws hiçbir yapılandırmayla ayakta kalmadı. Antivirüs/WinDivert engeli olabilir.' '  ERROR: winws would not stay up with any config. Antivirus/WinDivert block likely.') 'err'
  Report-AVBlock
  return $null
}
function Restore-ZapretIfWas { if($script:ZapWas -and -not $script:ServiceReplaced){ Log (T '  not: ölçüm için durdurulan zapret servisi geri başlatılıyor.' '  note: restarting the zapret service that was stopped for measuring.') 'dim'; Start-Service zapret -ErrorAction SilentlyContinue } }

# =============================================================================
#  İŞLEM GÜNLÜĞÜ + KURTARMA
#  Sistemi değiştiren her işlem başında "inprogress.json" yazar, düzgün bitince siler.
#  İşlem öldürülürse (pencere kapatıldı, elektrik gitti, zaman aşımı) dosya kalır;
#  bir sonraki işlem / nöbetçi / arayüz açılışı bunu görür ve sistemi toparlar.
# =============================================================================
$OpFile = Join-Path $Root 'inprogress.json'
$script:OpActive = $false
function Begin-Op([string]$mode){
  $z = Get-Service zapret -ErrorAction SilentlyContinue
  Write-Json ([pscustomobject]@{ mode = $mode; pid = $PID; at = (Get-Date).ToString('s'); zapWas = [bool]($z -and $z.Status -eq 'Running') }) $OpFile
  $script:OpActive = $true
}
function End-Op { Remove-Item -LiteralPath $OpFile -Force -ErrorAction SilentlyContinue; $script:OpActive = $false }
function Test-LocalResolver {
  try { return [bool](Resolve-DnsName 'cloudflare.com' -Server '127.0.0.1' -Type A -DnsOnly -QuickTimeout -ErrorAction Stop | Where-Object { $_.IPAddress }) } catch { return $false }
}
function Test-SystemDns {
  Clear-DnsClientCache -ErrorAction SilentlyContinue
  foreach($n in @('www.microsoft.com', 'www.cloudflare.com')){ try { if(Resolve-DnsName $n -Type A -QuickTimeout -ErrorAction Stop | Where-Object { $_.IPAddress }){ return $true } } catch {} }
  return $false
}
# Şifreli DNS çalışmıyorsa internet gitmesin: önce düz genel DNS, o da olmazsa ağın kendi (DHCP) DNS'i
# (ör. otel/kafe giriş sayfası 1.1.1.1'i engelliyorsa). Nöbetçi bağlantı düzelince şifreli DNS'e geri döner.
function Set-DnsFallback {
  Log (T '  [!] Şifreli DNS cevap vermiyor -> internet gitmesin diye DNS geçici olarak düz 1.1.1.1/8.8.8.8.' '  [!] Encrypted DNS not answering -> DNS temporarily plain 1.1.1.1/8.8.8.8 so the internet keeps working.') 'warn'
  Set-EgressDns $PlainDns
  if(Test-SystemDns){ return }
  foreach($ad in (Get-EgressAdapters)){ try { Set-DnsClientServerAddress -InterfaceIndex $ad.ifIndex -ResetServerAddresses -ErrorAction Stop } catch {} }
  ipconfig /flushdns | Out-Null
  Log (T '  [!] Düz genel DNS de çalışmıyor (giriş sayfalı ağ?) -> ağın kendi DNS''i (DHCP) kullanılıyor.' '  [!] Plain public DNS fails too (captive portal?) -> using the network''s own DNS (DHCP).') 'warn'
}
# DNS'in gerçekten çalıştığını garanti et. -NoRepair: dnscrypt'i yeniden kurmaya çalışma (ör. yarıda kalan kaldırma).
function Ensure-DnsWorks([switch]$NoRepair){
  $ads  = @(Get-EgressAdapters)
  $loop = @($ads | Where-Object { (Get-AdapterV4Dns $_) -contains '127.0.0.1' })
  $nat  = @($ads | Where-Object { $NativeDoh.Contains("" + ((Get-AdapterV4Dns $_) | Select-Object -First 1)) })
  if($loop.Count){
    if(Test-LocalResolver){ return $true }
    if(-not $NoRepair -and (On (Load-Config).doh) -and (Ensure-Dnscrypt)){
      if(Get-Service dnscrypt-proxy -ErrorAction SilentlyContinue){ Set-Service dnscrypt-proxy -StartupType Automatic -ErrorAction SilentlyContinue; Start-Service dnscrypt-proxy -ErrorAction SilentlyContinue; Start-Sleep -Seconds 3 }
      if(-not (Test-LocalResolver)){ Setup-Dnscrypt | Out-Null }
      if(Test-LocalResolver){ Set-EgressDns @('127.0.0.1', '::1'); Log (T '  dnscrypt geri getirildi, şifreli DNS çalışıyor.' '  dnscrypt restored, encrypted DNS working.') 'ok'; return $true }
    }
    Set-DnsFallback; return $false
  }
  if($nat.Count -and -not (Test-SystemDns)){
    Log (T '  [!] Windows DoH sunucularına ulaşılamıyor (443 engeli / giriş sayfalı ağ?).' '  [!] Windows DoH servers unreachable (port 443 blocked / captive portal?).') 'warn'
    Set-DnsFallback; return $false
  }
  return $true
}
function Recover-System {
  $op = Read-Json $OpFile
  if(-not $op){ return $false }
  Head ((T '[kurtarma] Önceki işlem yarıda kalmış ({0}, {1}); sistem toparlanıyor...' '[recovery] A previous task was interrupted ({0}, {1}); recovering...') -f (PGet $op 'mode' '?'), (PGet $op 'at' '?'))
  $cfg = Load-Config
  # 1) yetim ölçüm winws'i (servis çalışmıyorken açık kalan winws = yarıda kalmış ölçüm)
  $z = Get-Service zapret -ErrorAction SilentlyContinue
  if((-not $z -or $z.Status -ne 'Running') -and (Get-Process winws -ErrorAction SilentlyContinue)){ Kill-Winws; Log (T '  yarıda kalmış ölçümün geçici winws''i kapatıldı' '  closed the temporary winws of the interrupted measurement') 'ok' }
  $mode = "" + (PGet $op 'mode')
  # 2) DNS çalışıyor mu (en kritik: internet gitmesin). Kaldırma yarıda kaldıysa dnscrypt'i geri KURMA.
  Ensure-DnsWorks -NoRepair:($mode -eq 'uninstall') | Out-Null
  # 3) zapret servisi
  if($mode -eq 'uninstall'){ Log (T '  yarıda kalan işlem kaldırmaydı: servisler geri kurulmuyor; tamamlamak için Kaldır''a tekrar bas.' '  the interrupted task was an uninstall: services are not restored; press Uninstall again to finish.') 'warn' }
  elseif($mode -eq 'probe'){
    # Test Et "hiçbir şey kurmaz" sözü verir: sadece ölçümden önce çalışan servisi geri aç, ASLA yeni kurulum yapma
    $z = Get-Service zapret -ErrorAction SilentlyContinue
    if($z -and (PGet $op 'zapWas' $false) -and $z.Status -ne 'Running'){ Kill-Winws; Start-Service zapret -ErrorAction SilentlyContinue; if(Wait-WinwsStable){ Log (T '  ölçüm için durdurulan zapret servisi geri açıldı' '  restarted the zapret service stopped for measuring') 'ok' } }
    Log (T '  yarıda kalan işlem ölçümdü: hiçbir şey kurulmadı.' '  the interrupted task was a probe: nothing was installed.') 'dim'
  }
  elseif(On $cfg.zapret){
    $z = Get-Service zapret -ErrorAction SilentlyContinue
    if($z){
      if($z.Status -ne 'Running' -or -not (Get-Process winws -ErrorAction SilentlyContinue)){
        Set-Service zapret -StartupType Automatic -ErrorAction SilentlyContinue; Kill-Winws; Start-Service zapret -ErrorAction SilentlyContinue
        if(Wait-WinwsStable){ Log (T '  zapret servisi yeniden başlatıldı' '  zapret service restarted') 'ok' } else { Log (T '  [!] zapret servisi başlatılamadı; Kur/Onar gerekebilir' '  [!] zapret service could not start; Install/Repair may be needed') 'warn' }
      }
    } else {
      try {
        Ensure-Zapret
        $s = Find-Strategy (PGet (Get-State) 'strategy' ''); if(-not $s){ $s = Get-DefaultStrategy }
        Log (T '  zapret servisi yarıda silinmiş -> yeniden kuruluyor' '  zapret service was deleted mid-way -> reinstalling') 'warn'
        $n = Install-Winws $s; if($n){ PSet (Get-State) 'strategy' $n; Save-State }
      } catch { Log (T '  [!] zapret yeniden kurulamadı; Kur/Onar gerekli' '  [!] zapret could not be reinstalled; Install/Repair needed') 'warn' }
    }
  }
  Remove-Item -LiteralPath $OpFile -Force -ErrorAction SilentlyContinue
  Log (T '  kurtarma tamam.' '  recovery done.') 'ok'
  return $true
}
# Sistemi değiştiren işlemlerin girişi: kilit al, yarım kalmış işlem varsa önce kurtar, sonra günlüğe yaz.
function Enter-Op([string]$mode, [int]$wait = 600, [switch]$NoRecover){
  if(-not (Get-Lock $wait)){ Fail 31 (T 'HATA: başka bir zapret-auto işlemi bitmedi.' 'ERROR: another zapret-auto task did not finish.') }
  if(-not $NoRecover -and (Test-Path -LiteralPath $OpFile)){ try { Recover-System | Out-Null } catch { Log ((T '  [!] kurtarma tamamlanamadı: {0}' '  [!] recovery incomplete: {0}') -f $_) 'warn' } }
  # kurtarma servisi yeniden kurmuş olabilir; bu bayraklar YENİ işleme ait olmalı (yoksa sonraki temizlik atlanır)
  $script:ServiceReplaced = $false; $script:ZapWas = $false
  Begin-Op $mode
}
function Assert-Online {
  if(-not (Test-Online)){ Fail 60 (T 'HATA: internet bağlantısı koptu. İşlem iptal edildi; yapılan geçici değişiklikler geri alınıyor. İnternet gelince tekrar dene.' 'ERROR: internet connection lost. Task cancelled; temporary changes are being reverted. Retry when the connection is back.') }
}

# =============================================================================
#  NÖBETÇİ (zamanlanmış görev)
# =============================================================================
function Install-WatchTask([switch]$Quiet) {
  $esc = [Security.SecurityElement]::Escape($SelfPath)
  $start = (Get-Date).AddMinutes(15).ToString('s')
  $desc = [Security.SecurityElement]::Escape((T 'zapret-auto nöbetçisi: servisleri, DNS ayarını ve DPI stratejisinin çalıştığını kontrol eder; bozulursa onarır. Kaldırmak için ZAPRET-AUTO.bat > Kaldır.' 'zapret-auto watchdog: checks services, DNS and that the DPI strategy still works; repairs if broken. Remove via ZAPRET-AUTO.bat > Uninstall.'))
  $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Author>zapret-auto</Author><Description>$desc</Description></RegistrationInfo>
  <Triggers>
    <BootTrigger><Delay>PT2M</Delay><Enabled>true</Enabled></BootTrigger>
    <TimeTrigger><StartBoundary>$start</StartBoundary><Repetition><Interval>PT6H</Interval><StopAtDurationEnd>false</StopAtDurationEnd></Repetition><Enabled>true</Enabled></TimeTrigger>
    <EventTrigger><Enabled>true</Enabled><Delay>PT30S</Delay><Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational"&gt;&lt;Select Path="Microsoft-Windows-NetworkProfile/Operational"&gt;*[System[(EventID=10000)]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription></EventTrigger>
  </Triggers>
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <ExecutionTimeLimit>PT30M</ExecutionTimeLimit>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
  </Settings>
  <Actions Context="Author"><Exec><Command>powershell.exe</Command><Arguments>-NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "$esc" watch</Arguments></Exec></Actions>
</Task>
"@
  try { Register-ScheduledTask -Xml $xml -TaskName $TaskName -TaskPath $TaskPath -Force -ErrorAction Stop | Out-Null; if(-not $Quiet){ Log (T '  Nöbetçi kuruldu (açılışta, 6 saatte bir ve ağ değişince kontrol eder).' '  Watchdog installed (checks at boot, every 6h and on network change).') 'ok' }; return $true }
  catch { Log ((T '  [!] Nöbetçi kurulamadı: {0}' '  [!] Could not install watchdog: {0}') -f $_.Exception.Message) 'warn'; return $false }
}
function Remove-WatchTask {
  Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Confirm:$false -ErrorAction SilentlyContinue
  try { $svc = New-Object -ComObject Schedule.Service; $svc.Connect(); $svc.GetFolder('\').DeleteFolder('zapret-auto', 0) } catch {}
}
function Get-WatchTask { return (Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue) }

function Test-Health($domains){
  $pass = 0
  foreach($d in $domains){ $ip = Get-RealIP $d; if($ip -and (Test-HS $d $ip 8) -ge 0){ $pass++ } }
  return $pass
}
function Do-Watch {
  $cfg = Load-Config
  if(-not (Get-Lock 0)){ return }   # başka işlem sürüyor -> sonra
  $pending = Test-Path -LiteralPath $OpFile
  if(-not (On $cfg.watch) -and -not $pending){ return }
  $st = Get-State
  if(-not (PGet $st 'installedAt') -and -not $pending){ return }
  $w = Read-Json $WatchFile; if(-not $w){ $w = [pscustomobject]@{} }
  $events = @(PGet $w 'events' @())
  $script:WEv = New-Object Collections.ArrayList
  function Ev([string]$m, [string]$lvl = 'i'){ [void]$script:WEv.Add($m); Log ("[nöbetçi] $m") $lvl }
  $result = 'ok'
  Log ("[nöbetçi] " + (T 'kontrol başladı' 'check started')) 'dim'
  try {
    # 0) yarıda kalmış bir işlem varsa önce onu toparla (internet olmasa da yapılır)
    if($pending){
      $po = Read-Json $OpFile
      if(Recover-System){ Ev ((T 'yarıda kalmış işlem ({0}) toparlandı' 'interrupted task ({0}) recovered') -f (PGet $po 'mode' '?')) 'warn'; $result = 'fixed' }
      $st = Get-State
    }
    Begin-Op 'watch'
    if(-not (On $cfg.watch) -or -not (PGet $st 'installedAt')){ return }
    if(-not (Test-Online)){ Ensure-DnsWorks | Out-Null; Ev (T 'internet yok, kontrol ertelendi' 'no internet, check postponed'); $result = 'skip'; return }
    # 1) winws servisi
    if(On $cfg.zapret){
      try { Ensure-Zapret } catch { Ev (T 'winws dosyaları eksik (antivirüs karantinası?) - arayüzden Kur/Onar gerekli' 'winws files missing (AV quarantine?) - run Install/Repair from the UI') 'err'; $result = 'fail' }
      if($result -ne 'fail'){
        $svc = Get-Service zapret -ErrorAction SilentlyContinue
        if(-not $svc){
          $s = Find-Strategy (PGet $st 'strategy' ''); if(-not $s){ $s = Get-DefaultStrategy }
          Ev (T 'zapret servisi yoktu -> yeniden kuruldu' 'zapret service was missing -> reinstalled') 'warn'
          $n = Install-Winws $s; if($n){ PSet $st 'strategy' $n; Save-State }; $result = 'fixed'
        } elseif($svc.Status -ne 'Running' -or -not (Get-Process winws -ErrorAction SilentlyContinue)){
          if($svc.StartType -eq 'Disabled'){ Set-Service zapret -StartupType Automatic -ErrorAction SilentlyContinue }
          Kill-Winws; Start-Service zapret -ErrorAction SilentlyContinue
          if(Wait-WinwsStable){ Ev (T 'zapret servisi durmuştu -> yeniden başlatıldı' 'zapret service was stopped -> restarted') 'warn'; $result = 'fixed' }
          else { Ev (T 'zapret servisi başlatılamadı' 'zapret service could not be started') 'err'; $result = 'fail' }
        }
      }
    }
    # 2) DNS / DoH
    if(On $cfg.doh){
      $eng = PGet $st 'dohEngine'
      if(-not $eng){
        Ev (T 'DoH açık olmalı ama kurulu değil -> kuruluyor' 'DoH should be on but is not set up -> setting up') 'warn'
        $eng = Apply-DoH
        if(-not $eng){ Set-EgressDns $PlainDns; Ev (T 'DoH kurulamadı; DNS düz 1.1.1.1/8.8.8.8' 'DoH setup failed; DNS plain 1.1.1.1/8.8.8.8') 'err'; $result = 'fail' }
        elseif($result -eq 'ok'){ $result = 'fixed' }
      }
      $want = $null
      if($eng -eq 'dnscrypt'){
        $ds = Get-Service dnscrypt-proxy -ErrorAction SilentlyContinue
        if(-not $ds -or $ds.Status -ne 'Running' -or -not (Test-LocalResolver)){
          if($ds){ Set-Service dnscrypt-proxy -StartupType Automatic -ErrorAction SilentlyContinue; Restart-Service dnscrypt-proxy -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 3 }
          if(-not (Test-LocalResolver)){ if(Ensure-Dnscrypt){ Setup-Dnscrypt | Out-Null } }
          if(Test-LocalResolver){ Ev (T 'dnscrypt çalışmıyordu -> düzeltildi' 'dnscrypt was not working -> fixed') 'warn'; if($result -eq 'ok'){ $result = 'fixed' } }
          else { Ev (T 'dnscrypt düzeltilemedi -> DNS düz 1.1.1.1/8.8.8.8 (internet gitmesin)' 'dnscrypt could not be fixed -> DNS plain 1.1.1.1/8.8.8.8 (keep internet)') 'err'; $result = 'fail' }
        }
        $want = $(if(Test-LocalResolver){ @('127.0.0.1', '::1') } else { $PlainDns })
      } elseif($eng -eq 'native'){ $want = @($NativeDoh.Keys) }
      if($want){
        foreach($ad in (Get-EgressAdapters)){
          $cur = Get-AdapterV4Dns $ad
          if(-not $cur.Count -or $cur[0] -ne $want[0]){
            Set-AdapterDns $ad $want | Out-Null
            if($eng -eq 'native'){ Setup-NativeDoH | Out-Null }
            Ev ((T 'DNS ayarı kaymıştı / yeni ağ: {0} -> düzeltildi' 'DNS drifted / new network: {0} -> fixed') -f $ad.Name) 'warn'; if($result -eq 'ok'){ $result = 'fixed' }
          }
        }
        Clear-DnsClientCache -ErrorAction SilentlyContinue
        # adresler doğru olsa bile isimler gerçekten çözülüyor mu? (ör. giriş sayfalı ağda DoH ölü olabilir)
        if(-not (Ensure-DnsWorks)){ Ev (T 'şifreli DNS bu ağda çalışmıyor -> geçici olarak düz DNS (bağlantı düzelince geri dönülecek)' 'encrypted DNS not working on this network -> temporarily plain DNS (will switch back when possible)') 'warn'; $result = 'fail' }
      }
    }
    # 2b) sonradan kurulan / açılan çakışan bir araç var mı? (kullanıcının aracına kendiliğinden dokunmayız; haber veririz)
    $cf = @(Find-Conflicts -Quick)
    if($cf.Count){ Ev ((T 'çakışan DPI aracı tespit edildi: {0} -- arayüzden Kur/Onar ile durdurulabilir' 'conflicting DPI tool detected: {0} -- can be stopped via Install/Repair in the UI') -f (($cf | ForEach-Object { $_.Name }) -join ', ')) 'warn'; $result = 'fail' }
    # 3) strateji sağlığı
    $targets = @(PGet $st 'targets' @())
    if((On $cfg.zapret) -and $targets.Count -and (Get-Process winws -ErrorAction SilentlyContinue)){
      if(-not (Test-ControlSite)){ Ev (T 'kontrol sitesine erişilemedi, strateji testi atlandı' 'control site unreachable, strategy test skipped') }
      elseif((Test-Health $targets) -eq 0){
        Ev (T 'engelli siteler açılmıyor -> servis yeniden başlatılıp tekrar denenecek' 'blocked sites not opening -> restarting service and retrying') 'warn'
        Restart-Service zapret -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 60
        if((Test-Health $targets) -gt 0){ Ev (T 'yeniden başlatma sorunu çözdü' 'restart fixed it') 'ok'; $result = 'fixed' }
        else {
          $next = PGet $w 'nextRebake'
          if($next -and (Get-Date) -lt [datetime]$next){ Ev ((T 'strateji çalışmıyor; yeni tarama {0} sonrasına ertelendi' 'strategy not working; next bake-off postponed until {0}') -f $next) 'warn'; $result = 'fail' }
          else {
            Ev (T 'strateji artık çalışmıyor -> yeniden tarama başlıyor' 'strategy stopped working -> starting a new bake-off') 'warn'
            $r = Invoke-Rebake $st
            if($r -eq 'rebake'){ PSet $w 'backoffH' 0; PSet $w 'nextRebake' $null; $result = 'rebake' }
            elseif($r -eq 'ok'){ $result = 'fixed' }
            else {
              $b = [int](PGet $w 'backoffH' 0); $b = [Math]::Min(24, [Math]::Max(6, $b * 2))
              PSet $w 'backoffH' $b; PSet $w 'nextRebake' (Get-Date).AddHours($b).ToString('s')
              Ev ((T 'çalışan strateji bulunamadı; {0} saat sonra tekrar denenecek' 'no working strategy found; will retry in {0} h') -f $b) 'err'; $result = 'fail'
            }
          }
        }
      }
    }
  } catch { if("$_" -ne 'ZA_FATAL'){ Ev ("hata: $_") 'err' }; $result = 'fail' }
  finally {
    $now = (Get-Date).ToString('s')
    foreach($e in $script:WEv){ $events += [pscustomobject]@{ t = $now; m = $e } }
    if($events.Count -gt 15){ $events = $events[($events.Count - 15)..($events.Count - 1)] }
    $msg = $(if($script:WEv.Count){ $script:WEv[$script:WEv.Count - 1] } else { T 'sorun yok' 'all good' })
    PSet $w 'lastRun' $now; PSet $w 'result' $result; PSet $w 'message' $msg; PSet $w 'events' $events
    Write-Json $w $WatchFile
    Log ("[nöbetçi] " + (T 'bitti: ' 'done: ') + "$result - $msg") 'dim'
  }
}
function Invoke-Rebake($st){
  Stop-Service zapret -Force -ErrorAction SilentlyContinue; Kill-Winws
  $script:ServiceReplaced = $false; $script:ZapWas = $true
  try {
    $found = @(Discover-Targets)
    if(-not $found.Count){ Ev (T 'ISP artık engellemiyor gibi; mevcut strateji korunuyor' 'ISP no longer seems to block; keeping current strategy'); return 'ok' }
    $best = Bakeoff $found (Get-PreferredStrategies)
    if(-not $best){ return 'fail' }
    Add-ToAutoList @($found | ForEach-Object { $_.Domain })
    $old = PGet $st 'strategy' '?'
    $n = Install-Winws $best
    if(-not $n){ return 'fail' }
    PSet $st 'strategy' $n; PSet $st 'targets' @($found | ForEach-Object { $_.Domain }); Save-State
    Add-Memory $n
    Ev ((T 'yeni strateji kuruldu: {0} -> {1}' 'new strategy installed: {0} -> {1}') -f $old, $n) 'ok'
    return 'rebake'
  } finally { Restore-ZapretIfWas }
}

# =============================================================================
#  DURUM / RAPOR / PAKET
# =============================================================================
function Show-Config {
  $c = Load-Config
  Head (T 'BİLEŞEN TERCİHLERİ' 'COMPONENT PREFERENCES')
  Log ("  zapret (winws)  : " + $(if(On $c.zapret){ T 'açık' 'on' } else { T 'KAPALI' 'OFF' }))
  Log ("  doh             : " + $(if(On $c.doh){ T 'açık' 'on' } else { T 'KAPALI' 'OFF' }) + "  (" + (T 'motor' 'engine') + ": $($c.dohengine))")
  Log ("  watch           : " + $(if(On $c.watch){ T 'açık' 'on' } else { T 'KAPALI' 'OFF' }))
  Log ("  game            : " + $(if(On $c.game){ T 'açık' 'on' } else { T 'kapalı' 'off' }))
  Log ("  lang            : $($c.lang)")
  Log ("  " + (T 'dosya' 'file') + "           : $CfgFile") 'dim'
}
function Show-Status([switch]$NoTests){
  Head (T 'DURUM' 'STATUS')
  $st = Get-State
  $z = Get-Service zapret -ErrorAction SilentlyContinue
  $zOn = ($z -and $z.Status -eq 'Running' -and (Get-Process winws -ErrorAction SilentlyContinue))
  Log ("  zapret / winws  : " + $(if($zOn){ T 'ÇALIŞIYOR' 'RUNNING' } elseif($z){ T 'durmuş' 'stopped' } else { T 'kurulu değil' 'not installed' }) + $(if(PGet $st 'strategy'){ "  [$(PGet $st 'strategy')]" } else { '' })) $(if($zOn){ 'ok' } else { 'warn' })
  $eng = PGet $st 'dohEngine'
  $dOn = $false
  if($eng -eq 'native'){ $dOn = $true }
  elseif((Get-Service dnscrypt-proxy -ErrorAction SilentlyContinue).Status -eq 'Running'){ $dOn = $true; if(-not $eng){ $eng = 'dnscrypt' } }
  Log ("  DoH             : " + $(if($dOn){ (T 'AKTİF' 'ACTIVE') + " ($eng)" } else { T 'kapalı' 'off' })) $(if($dOn){ 'ok' } else { 'warn' })
  foreach($ad in (Get-EgressAdapters)){ Log ("    DNS {0,-12}: {1}" -f $ad.Name, ((Get-AdapterV4Dns $ad) -join ', ')) 'dim' }
  $t = Get-WatchTask
  $w = Read-Json $WatchFile
  $wl = $(if($t -and $t.State -ne 'Disabled'){ T 'açık' 'on' } else { T 'kapalı' 'off' })
  if($w -and (PGet $w 'lastRun')){ $wl += "  (" + (T 'son kontrol ' 'last check ') + (PGet $w 'lastRun') + ": " + (PGet $w 'message') + ")" }
  Log ("  " + (T 'nöbetçi' 'watchdog') + "         : $wl") $(if($t){ 'i' } else { 'dim' })
  Log ("  " + (T 'oyun filtresi' 'game filter') + "   : " + $(if(On (Load-Config).game){ T 'açık' 'on' } else { T 'kapalı' 'off' })) 'dim'
  Log ("  " + (T 'sürüm' 'version') + "           : $ZA_VERSION") 'dim'
  if($NoTests){ return }
  Clear-DnsClientCache -ErrorAction SilentlyContinue
  $hosts = @(@('discord.com', 'www.youtube.com') + @(PGet $st 'targets' @())) | Select-Object -Unique
  foreach($h in $hosts){
    $ms = Test-HS $h $null 8
    Log ("  " + (T 'bağlantı' 'connect') + " {0,-22}: {1}" -f $h, $(if($ms -ge 0){ (T 'AÇIK' 'OPEN') + " ($ms ms)" } else { T 'ENGELLİ' 'BLOCKED' })) $(if($ms -ge 0){ 'ok' } else { 'err' })
  }
}
function Get-OutDir {
  foreach($d in @($env:ZA_SRC, [Environment]::GetFolderPath('Desktop'), $env:TEMP)){
    if($d -and (Test-Path -LiteralPath $d)){ try { $p = Join-Path $d ('.za' + (Get-Random)); [IO.File]::WriteAllText($p, ''); Remove-Item -LiteralPath $p -Force; return $d } catch {} }
  }
  return $env:TEMP
}
function Do-Report {
  Head (T 'TEŞHİS RAPORU hazırlanıyor...' 'Preparing DIAGNOSTIC REPORT...')
  $RepLines = New-Object Collections.ArrayList
  function Add-RLine([string]$s = ''){ [void]$RepLines.Add($s) }
  Add-RLine "zapret-auto $ZA_VERSION  -  $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
  try { $os = Get-CimInstance Win32_OperatingSystem; Add-RLine ("OS        : {0} ({1}) build {2}" -f $os.Caption, $os.OSArchitecture, $os.BuildNumber) } catch {}
  Add-RLine ("PS        : {0}   admin: {1}   lang: {2}" -f $PSVersionTable.PSVersion, (Is-Admin), $script:Lang)
  Add-RLine ("AV        : {0}" -f ((Get-ActiveAV) -join ', '))
  Add-RLine ("SAC       : {0}  (0=kapalı 1=açık 2=değerlendirme -1=yok)" -f (Get-SacState))
  try { $mp = Get-MpComputerStatus -ErrorAction Stop; Add-RLine ("Defender  : RT={0}" -f $mp.RealTimeProtectionEnabled) } catch {}
  Add-RLine; Add-RLine '--- config ---'; foreach($k in (Load-Config).Keys){ Add-RLine ("{0}={1}" -f $k, (Load-Config)[$k]) }
  Add-RLine; Add-RLine '--- state ---'
  $st = Get-State
  Add-RLine ("strategy  : {0}" -f (PGet $st 'strategy')); Add-RLine ("dohEngine : {0}" -f (PGet $st 'dohEngine')); Add-RLine ("targets   : {0}" -f ((@(PGet $st 'targets' @())) -join ', ')); Add-RLine ("installed : {0}  ver {1}" -f (PGet $st 'installedAt'), (PGet $st 'version'))
  Add-RLine; Add-RLine '--- services ---'
  foreach($n in @('zapret', 'dnscrypt-proxy', 'WinDivert')){ $s = Get-Service $n -ErrorAction SilentlyContinue; Add-RLine ("{0,-15}: {1}" -f $n, $(if($s){ "$($s.Status) / $($s.StartType)" } else { '-' })) }
  Add-RLine ("winws proc     : {0}" -f [bool](Get-Process winws -ErrorAction SilentlyContinue))
  $t = Get-WatchTask; Add-RLine ("watch task     : {0}" -f $(if($t){ $t.State } else { '-' }))
  $w = Read-Json $WatchFile; if($w){ Add-RLine ("watch last     : {0} {1} {2}" -f (PGet $w 'lastRun'), (PGet $w 'result'), (PGet $w 'message')) }
  Add-RLine; Add-RLine '--- network ---'
  foreach($ad in (Get-EgressAdapters)){ Add-RLine ("{0} [{1}]  DNSv4: {2}" -f $ad.Name, $ad.InterfaceDescription, ((Get-AdapterV4Dns $ad) -join ', ')) }
  try { Add-RLine ("tcp timestamps : {0}" -f (Get-NetTCPSetting -SettingName Internet).Timestamps) } catch {}
  $cf = @(Find-Conflicts); Add-RLine ("conflicts      : {0}" -f $(if($cf.Count){ ($cf | ForEach-Object { $_.Name }) -join ', ' } else { '-' }))
  Add-RLine; Add-RLine '--- tests ---'
  foreach($h in @('discord.com', 'www.youtube.com', 'x.com')){ $ms = Test-HS $h $null 8; Add-RLine ("{0,-18}: {1}" -f $h, $(if($ms -ge 0){ "open $ms ms" } else { 'BLOCKED' })) }
  Add-RLine; Add-RLine '--- log (son 150 satır) ---'
  if(Test-Path -LiteralPath $LogFile){ foreach($logLine in (Get-Content -LiteralPath $LogFile -Tail 150 -Encoding UTF8)){ Add-RLine $logLine } }
  # gizlilik: kullanıcı/bilgisayar adı, MAC adresleri ve öğrenilmiş (ziyaret edilen) siteler maskelenir
  $txt = $RepLines -join "`r`n"
  foreach($sec in @($env:USERNAME, $env:COMPUTERNAME)){ if($sec -and $sec.Length -ge 3){ $txt = $txt -replace [regex]::Escape($sec), '<gizli>' } }
  $txt = $txt -replace '([0-9A-Fa-f]{2}[-:]){5}[0-9A-Fa-f]{2}', '<mac>'
  $i = 0; foreach($d in (Get-LearnedDomains)){ $i++; if($DefaultTargets -notcontains $d){ $txt = $txt -replace ('(?<![\w.-])' + [regex]::Escape($d) + '(?![\w-])'), "<site-$i>" } }
  $out = Join-Path (Get-OutDir) ("zapret-auto-rapor-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmm'))
  [IO.File]::WriteAllText($out, $txt, (New-Object Text.UTF8Encoding($true)))
  Log ((T '  Rapor hazır: {0}' '  Report ready: {0}') -f $out) 'ok'
  Log (T '  (kullanıcı adı, bilgisayar adı, MAC ve öğrenilmiş siteler maskelendi)' '  (user name, computer name, MACs and learned sites are masked)') 'dim'
  Mark "OPEN|$out"
}
function Do-Pack {
  Head (T 'ÇEVRİMDIŞI PAKET hazırlanıyor...' 'Preparing OFFLINE PACKAGE...')
  Ensure-Home
  $zz = Ensure-Zip 'zapret'; $dz = Ensure-Zip 'dnscrypt'
  if(-not $zz){ Fail 50 (T 'HATA: zapret paketi alınamadı.' 'ERROR: could not obtain the zapret package.') }
  $name = "zapret-auto-$ZA_VERSION-offline"
  $tmp = Join-Path $env:TEMP $name
  if(Test-Path -LiteralPath $tmp){ Remove-Item -LiteralPath $tmp -Recurse -Force }
  New-Item -ItemType Directory -Path $tmp -Force | Out-Null
  $bat = Join-Path $tmp 'ZAPRET-AUTO.bat'
  if($env:ZA_SELF -and (Test-Path -LiteralPath $env:ZA_SELF)){ Copy-Item -LiteralPath $env:ZA_SELF -Destination $bat }
  else { $b = [IO.File]::ReadAllBytes($SelfPath); $o = $(if($b[0] -eq 239){ 3 } else { 0 }); $f = [IO.File]::Create($bat); $f.Write($b, $o, $b.Length - $o); $f.Close() }
  Copy-Item -LiteralPath $zz -Destination $tmp
  if($dz){ Copy-Item -LiteralPath $dz -Destination $tmp }
  $readme = @"
zapret-auto $ZA_VERSION - ÇEVRİMDIŞI PAKET / OFFLINE PACKAGE

TR: Bu klasörü olduğu gibi (zip'ten çıkarıp) hedef bilgisayara kopyala ve ZAPRET-AUTO.bat'a çift tıkla.
    Yanındaki zip dosyaları kullanılır; internetten paket indirilmez (SHA256 ile doğrulanır).
EN: Extract this folder on the target PC and double-click ZAPRET-AUTO.bat.
    The zips next to it are used; nothing is downloaded (verified by SHA256).

SHA256:
  $([IO.Path]::GetFileName($zz))  $($Pkgs.zapret.Sha)
  $(if($dz){ "$([IO.Path]::GetFileName($dz))  $($Pkgs.dnscrypt.Sha)" })
"@
  [IO.File]::WriteAllText((Join-Path $tmp 'OKUBENI-README.txt'), $readme, (New-Object Text.UTF8Encoding($true)))
  $zipOut = Join-Path (Get-OutDir) "$name.zip"
  Compress-Archive -Path (Join-Path $tmp '*') -DestinationPath $zipOut -Force
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  Log ((T '  Paket hazır: {0}' '  Package ready: {0}') -f $zipOut) 'ok'
  Log (T '  İçinde: ZAPRET-AUTO.bat + zapret ve dnscrypt zip''leri + OKUBENI. Zip''ler GitHub''daki resmî sürümlerdir' '  Contents: ZAPRET-AUTO.bat + the zapret and dnscrypt zips + README. The zips are the official GitHub releases') 'dim'
  Log ("    zapret   : " + $Pkgs.zapret.Url) 'dim'
  Log ("    dnscrypt : " + $Pkgs.dnscrypt.Url) 'dim'
  Log (T '  (önbellekte varsa yeniden indirilmez). İnterneti olmayan / GitHub''a erişemeyen bir PC''ye bu zip''i götür, çıkar, .bat''ı çalıştır.' '  (not re-downloaded if cached). Take this zip to a PC without internet / GitHub access, extract, run the .bat.') 'dim'
  Mark "SELECT|$zipOut"
}

# =============================================================================
#  KALDIRMA / AÇ-KAPA
# =============================================================================
function Do-Uninstall {
  Need-Admin
  Enter-Op 'uninstall' -NoRecover
  Head (T 'KALDIRMA' 'UNINSTALL')
  Remove-WatchTask; Log (T '  nöbetçi görevi kaldırıldı' '  watchdog task removed') 'ok'
  Remove-ZapretService
  Get-Process winws -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Kill-Winws
  Log (T '  zapret servisi ve WinDivert sürücüsü kaldırıldı' '  zapret service and WinDivert driver removed') 'ok'
  # ÖNCE DNS'i eski haline getir, SONRA dnscrypt'i kaldır (tersi olursa arada DNS ölü kalır)
  if((PGet (Get-State) 'dohEngine') -eq 'native'){ Remove-NativeDoH; Log (T '  Windows DoH ayarları eski haline döndü' '  Windows DoH settings restored') 'ok' }
  Restore-Dns
  $dp = Get-ChildItem -LiteralPath $DnsDir -Recurse -Filter 'dnscrypt-proxy.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
  if($dp){ & $dp.FullName -service stop 2>&1 | Out-Null; & $dp.FullName -service uninstall 2>&1 | Out-Null }
  if(Get-Service dnscrypt-proxy -ErrorAction SilentlyContinue){ Stop-Service dnscrypt-proxy -Force -ErrorAction SilentlyContinue; & sc.exe delete dnscrypt-proxy 2>&1 | Out-Null }
  Log (T '  dnscrypt-proxy servisi kaldırıldı' '  dnscrypt-proxy service removed') 'ok'
  $snap = PGet (Get-State) 'snapshot'
  if((PGet $snap 'timestamps') -eq 'Disabled'){ & netsh.exe interface tcp set global timestamps=disabled 2>&1 | Out-Null; Log (T '  TCP timestamps eski haline (kapalı) döndü' '  TCP timestamps restored (disabled)') 'ok' }
  # kurulumda durdurduğumuz başka DPI araçlarını (GoodbyeDPI vb.) eski başlangıç ayarlarına döndür
  Restore-Conflicts
  Log (T '  dosyalar siliniyor...' '  deleting files...') 'dim'
  for($i = 0; $i -lt 3 -and (Test-Path -LiteralPath $Root); $i++){ Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue; if(Test-Path -LiteralPath $Root){ Start-Sleep -Seconds 1 } }
  if(Test-Path -LiteralPath $Root){ Log ((T '  [!] Bazı dosyalar silinemedi (kullanımda olabilir): {0}' '  [!] Some files could not be deleted (in use?): {0}') -f $Root) 'warn' }
  Log ''
  Log (T 'Kaldırma tamam. Sistem, kurulumdan önceki haline döndü (DNS, servisler, zamanlanmış görev, istisnalar, dosyalar).' 'Uninstall complete. The system is back to its pre-install state (DNS, services, scheduled task, exclusions, files).') 'ok'
}
function Do-ZapretOn {
  Need-Admin; Enter-Op 'zapret-on'; Set-Pref 'zapret' 1; Head (T '[zapret açılıyor]' '[enabling zapret]')
  if(Get-Service zapret -ErrorAction SilentlyContinue){
    Set-Service zapret -StartupType Automatic -ErrorAction SilentlyContinue; Kill-Winws; Start-Service zapret -ErrorAction SilentlyContinue
    if(Wait-WinwsStable){ Log (T '  zapret açıldı ve çalışıyor.' '  zapret enabled and running.') 'ok' } else { Log (T '  servis başladı ama winws ayakta kalmıyor -- Kur/Onar dene.' '  service started but winws does not stay up -- try Install/Repair.') 'warn' }
  } else { Log (T '  zapret servisi henüz yok. Önce Kur/Onar çalıştır.' '  zapret service does not exist yet. Run Install/Repair first.') 'warn' }
}
function Do-ZapretOff {
  Need-Admin; Enter-Op 'zapret-off'; Set-Pref 'zapret' 0; Head (T '[zapret kapatılıyor]' '[disabling zapret]')
  Stop-Service zapret -Force -ErrorAction SilentlyContinue; Set-Service zapret -StartupType Disabled -ErrorAction SilentlyContinue; Kill-Winws
  Log (T '  zapret kapatıldı (winws durdu). DNS/DoH etkilenmedi.' '  zapret disabled (winws stopped). DNS/DoH unaffected.') 'ok'
}
function Do-DohOn {
  Need-Admin; Enter-Op 'doh-on'; Set-Pref 'doh' 1; Ensure-Home
  $e = Apply-DoH
  if(-not $e){ Log (T '  DoH açılamadı; DNS düz 1.1.1.1/8.8.8.8''e ayarlanıyor (şifresiz ama zehirsiz).' '  DoH could not be enabled; setting plain 1.1.1.1/8.8.8.8 (unencrypted but unpoisoned).') 'warn'; Set-EgressDns $PlainDns }
}
function Do-DohOff {
  Need-Admin; Enter-Op 'doh-off'; Set-Pref 'doh' 0; Head (T '[DoH kapatılıyor]' '[disabling DoH]')
  Remove-DoH
  Set-EgressDns $PlainDns
  Log (T '  DoH kapatıldı. DNS: düz 1.1.1.1 / 8.8.8.8 (şifresiz ama ISP zehirlemesinden bağımsız).' '  DoH disabled. DNS: plain 1.1.1.1 / 8.8.8.8 (unencrypted, but independent of ISP poisoning).') 'ok'
}
function Do-WatchOn {
  Need-Admin; Set-Pref 'watch' 1; Head (T '[nöbetçi açılıyor]' '[enabling watchdog]')
  if(PGet (Get-State) 'installedAt'){ Install-WatchTask | Out-Null } else { Log (T '  Önce Kur/Onar çalıştır; nöbetçi kurulumla birlikte gelir.' '  Run Install/Repair first; the watchdog is installed with it.') 'warn' }
}
function Do-WatchOff { Need-Admin; Set-Pref 'watch' 0; Head (T '[nöbetçi kapatılıyor]' '[disabling watchdog]'); Remove-WatchTask; Log (T '  nöbetçi kapatıldı.' '  watchdog disabled.') 'ok' }
function Do-Game([bool]$on){
  Need-Admin; Enter-Op 'game'; Set-Pref 'game' $(if($on){ 1 } else { 0 })
  Head $(if($on){ T '[oyun filtresi açılıyor: TCP/UDP 1024-65535]' '[enabling game filter: TCP/UDP 1024-65535]' } else { T '[oyun filtresi kapatılıyor]' '[disabling game filter]' })
  $name = PGet (Get-State) 'strategy'
  if((Get-Service zapret -ErrorAction SilentlyContinue) -and $name -and $name -ne 'minimal'){
    Ensure-Zapret
    $s = Find-Strategy $name; if(-not $s){ $s = Get-DefaultStrategy }
    $n = Install-Winws $s; if($n){ PSet (Get-State) 'strategy' $n; Save-State }
  } else { Log (T '  Tercih kaydedildi; bir sonraki Kur/Onar''da uygulanacak.' '  Preference saved; it will apply on the next Install/Repair.') 'dim' }
}

# =============================================================================
#  KURULUM / ÖLÇÜM
# =============================================================================
$script:ZapWas = $false
function Do-Install([bool]$probe){
  Need-Admin
  Enter-Op $(if($probe){ 'probe' } else { 'install' })
  $cfg = Load-Config
  if($probe){ Log (T '*** ÖLÇÜM MODU: sadece ölçüm; servis kurulmaz, DNS değişmez ***' '*** PROBE MODE: measure only; no services installed, DNS unchanged ***') 'warn' }
  Preflight
  Ensure-Home
  if(-not $probe){
    Snapshot-Globals
    # Nöbetçiyi EN BAŞTA kur: ilk kurulum yarıda kesilse bile açılışta sistemi toparlayacak biri olsun.
    if(On $cfg.watch){ Install-WatchTask -Quiet | Out-Null }
  }
  $conf = @(Find-Conflicts)
  if($conf.Count){
    Head (T '[!] Çakışan DPI araçları bulundu' '[!] Conflicting DPI tools found')
    foreach($c in $conf){ Log ("  - " + $c.Name) 'warn' }
    if(-not $Yes){
      Log (T '  Bunlar aynı sürücü (WinDivert) için yarışır. Devam etmek için onay gerekiyor (durdurulup devre dışı bırakılırlar, SİLİNMEZLER).' '  They compete for the same driver (WinDivert). Confirmation needed to continue (they are stopped and disabled, NOT deleted).') 'warn'
      Log (T '  CLI: ZAPRET-AUTO.bat install yes' '  CLI: ZAPRET-AUTO.bat install yes') 'dim'
      Mark ("ASK|conflicts|" + (($conf | ForEach-Object { $_.Name }) -join ', '))
      Fail 30 ''
    }
    Resolve-Conflicts $conf
  }
  Head (T '[1] Bağımlılıklar' '[1] Dependencies')
  Show-AVInfo
  $needZap = $probe -or (On $cfg.zapret)
  if($needZap){ Ensure-Zapret }
  if(-not $probe){ Log ((T '  bileşenler: winws={0} | DoH={1} | nöbetçi={2} | oyun filtresi={3}' '  components: winws={0} | DoH={1} | watchdog={2} | game filter={3}') -f $(if(On $cfg.zapret){'1'}else{'0'}), $(if(On $cfg.doh){'1'}else{'0'}), $(if(On $cfg.watch){'1'}else{'0'}), $(if(On $cfg.game){'1'}else{'0'})) 'dim' }
  $script:ZapWas = ((Get-Service zapret -ErrorAction SilentlyContinue).Status -eq 'Running')
  $winner = $null; $found = @()
  try {
    if($needZap){ Stop-Service zapret -Force -ErrorAction SilentlyContinue; Kill-Winws }
    Diagnose-DNS | Out-Null
    if($needZap){
      $found = @(Discover-Targets)
      if(-not $found.Count){
        Log ''
        Log (T '  Bu ISP test edilen sitelerin hiçbirini DPI ile engellemiyor gibi.' '  This ISP does not seem to DPI-block any tested site.') 'ok'
        $winner = Get-DefaultStrategy
        Log ((T '  Güvenli varsayılan: {0} + autohostlist (ileride gelen engelleri kendisi öğrenir).' '  Safe default: {0} + autohostlist (learns future blocks by itself).') -f $winner.Base)
      } else {
        $pref = @(Get-PreferredStrategies)
        if($pref.Count){
          $cand = Find-Strategy $pref[0]
          if($cand){
            Head ((T '[4] Hafıza: bu ağda daha önce "{0}" kazanmıştı, doğrulanıyor...' '[4] Memory: "{0}" won on this network before, verifying...') -f $cand.Base)
            $sc = Test-Strategy $cand $found -1
            Log ("  {0,-30} {1}/{2}" -f $cand.Base, [Math]::Max(0, $sc), $found.Count) $(if($sc -eq $found.Count){ 'ok' } else { 'warn' })
            if($sc -eq $found.Count){ $winner = $cand; Log (T '  doğrulandı -> tam tarama atlandı.' '  verified -> full bake-off skipped.') 'ok' }
            else { Log (T '  artık tam çalışmıyor -> tam tarama yapılıyor.' '  no longer fully works -> running full bake-off.') 'warn' }
          }
        }
        if(-not $winner){ $winner = Bakeoff $found $pref }
        if(-not $winner){
          Log ''
          Log (T '  Paketteki stratejilerin hiçbiri bu ISP''nin engelini aşamadı.' '  None of the bundled strategies beat this ISP''s block.') 'err'
          $winner = Get-DefaultStrategy
          Log ((T '  Yedek olarak {0} + autohostlist kullanılacak.' '  Falling back to {0} + autohostlist.') -f $winner.Base) 'warn'
        } else { Add-Memory $winner.Name }
      }
      if($probe){
        Head (T 'ÖLÇÜM SONUCU' 'PROBE RESULT')
        Log ((T '  Kurulacak strateji: {0}' '  Strategy that would be installed: {0}') -f $winner.Base) 'ok'
        Log (T '  Hiçbir şey kurulmadı. Uygulamak için Kur/Onar.' '  Nothing was installed. Use Install/Repair to apply.')
        return
      }
    }
    # ---------------- uygula ----------------
    $dohEng = $null
    if(On $cfg.doh){
      $dohEng = Apply-DoH
      if(-not $dohEng){ Log (T '  DoH kurulamadı -> DNS düz 1.1.1.1/8.8.8.8''e ayarlanıyor (zehirsiz ama şifresiz).' '  DoH failed -> setting plain 1.1.1.1/8.8.8.8 (unpoisoned but unencrypted).') 'warn'; Set-EgressDns $PlainDns; Assert-Online }
    } else {
      Head (T '[5] DoH tercihi KAPALI -- şifreli DNS atlanıyor.' '[5] DoH preference OFF -- skipping encrypted DNS.')
      if(PGet (Get-State) 'dohEngine'){ Remove-DoH; Set-EgressDns $PlainDns }
    }
    $st = Get-State
    if(On $cfg.zapret){
      if($found.Count){ Add-ToAutoList @($found | ForEach-Object { $_.Domain }) }
      $n = Install-Winws $winner
      PSet $st 'strategy' $n
      PSet $st 'targets' @($found | ForEach-Object { $_.Domain })
    } else {
      Head (T '[6] zapret tercihi KAPALI -- winws kurulmuyor.' '[6] zapret preference OFF -- not installing winws.')
      Stop-Service zapret -Force -ErrorAction SilentlyContinue; Set-Service zapret -StartupType Disabled -ErrorAction SilentlyContinue
      $script:ZapWas = $false
    }
    PSet $st 'installedAt' (Get-Date).ToString('s'); PSet $st 'version' $ZA_VERSION; Save-State
    Head (T '[7] Nöbetçi' '[7] Watchdog')
    if(On $cfg.watch){ Install-WatchTask | Out-Null } else { Remove-WatchTask; Log (T '  nöbetçi tercihi kapalı.' '  watchdog preference off.') 'dim' }
    # önce / sonra
    if($found.Count -and (On $cfg.zapret)){
      Head (T 'ÖNCE / SONRA' 'BEFORE / AFTER')
      Start-Sleep -Seconds 2
      Log ("  {0,-24} {1,-16} {2}" -f (T 'site' 'site'), (T 'önce' 'before'), (T 'sonra' 'after')) 'dim'
      foreach($f in $found){
        $ms = Test-HS $f.Domain $f.IP 8
        Log ("  {0,-24} {1,-16} {2}" -f $f.Domain, ((T 'ENGELLİ' 'BLOCKED') + " ($($f.Tag))"), $(if($ms -ge 0){ (T 'AÇIK' 'OPEN') + " ($ms ms)" } else { T 'hâlâ engelli' 'still blocked' })) $(if($ms -ge 0){ 'ok' } else { 'err' })
      }
    }
    Show-Status
    Head (T 'HEPSİ TAMAM.' 'ALL DONE.')
    Log ("  " + (T 'DPI atlatma : ' 'DPI bypass  : ') + $(if(On $cfg.zapret){ (T 'zapret servisi (winws + autohostlist), açılışta otomatik' 'zapret service (winws + autohostlist), auto-start') } else { T 'KAPALI (tercih)' 'OFF (preference)' })) 'ok'
    Log ("  DNS         : " + $(if(-not (On $cfg.doh)){ T 'DoH kapalı (tercih) -- düz 1.1.1.1/8.8.8.8' 'DoH off (preference) -- plain 1.1.1.1/8.8.8.8' } elseif($dohEng -eq 'native'){ T 'şifreli (Windows yerleşik DoH)' 'encrypted (Windows built-in DoH)' } elseif($dohEng){ T 'şifreli (dnscrypt-proxy DoH)' 'encrypted (dnscrypt-proxy DoH)' } else { T 'düz 1.1.1.1/8.8.8.8 (DoH kurulamadı)' 'plain 1.1.1.1/8.8.8.8 (DoH failed)' })) 'ok'
    Log ("  " + (T 'Kayıt       : ' 'Log         : ') + $LogFile) 'dim'
  } finally {
    # sadece ölçüm/yarıda kalma durumunda: geçici winws'i temizle ve eski servisi geri başlat
    if($needZap -and -not $script:ServiceReplaced){ Kill-Winws; Restore-ZapretIfWas }
  }
}

function Show-Help {
  Log "zapret-auto $ZA_VERSION" 'head'
  Log (T 'Kullanım: ZAPRET-AUTO.bat [komut] [yes] [/quiet]' 'Usage: ZAPRET-AUTO.bat [command] [yes] [/quiet]')
  Log '  (yok/none)   GUI'
  Log (T '  install      ölç + en iyi ayarı kur (yes = çakışmalara onay, /quiet = sessiz)' '  install      measure + install best config (yes = approve conflicts, /quiet = silent)')
  Log (T '  probe        sadece ölç, hiçbir şey değiştirme' '  probe        measure only, change nothing')
  Log (T '  status       durum  |  uninstall  her şeyi kaldır, eski haline döndür' '  status       status |  uninstall  remove everything, restore previous state')
  Log '  zapret-on|off  doh-on|off  watch-on|off  game-on|off'
  Log (T '  report       teşhis raporu  |  pack  çevrimdışı paket  |  config  ayarları göster' '  report       diagnostic report | pack  offline package | config  show settings')
  Log (T '  set <anahtar> <değer>   ör: set lang en  |  set dohengine dnscrypt' '  set <key> <value>       e.g.: set lang en  |  set dohengine dnscrypt')
}

# =============================================================================
#  ARAYÜZ (WPF)
# =============================================================================
function Start-Gui {
  Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
  # Tek pencere: zaten açıksa yenisini açma, var olanı öne getir
  if($env:ZA_GUI_SMOKE -ne '1'){
    $created = $false
    try { $script:GuiMutex = [Threading.Mutex]::new($true, 'Local\zapret-auto-gui', [ref]$created) } catch { $created = $true }
    if(-not $created){
      try { $ev = [Threading.EventWaitHandle]::OpenExisting('Local\zapret-auto-gui-show'); [void]$ev.Set() } catch {}
      return
    }
    $script:ShowEv = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::AutoReset, 'Local\zapret-auto-gui-show')
  }
  $script:Engine = $SelfPath
  $script:SelfBytes = [IO.File]::ReadAllBytes($SelfPath)
  $Sync = [hashtable]::Synchronized(@{})
  $Sync.Q = [Collections.Queue]::Synchronized((New-Object Collections.Queue))
  $Sync.Proc = $null; $Sync.Busy = $false

  [xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="zapret-auto" Height="660" Width="960" MinHeight="580" MinWidth="840"
        WindowStartupLocation="CenterScreen" Background="#0F1116" FontFamily="Segoe UI" Foreground="#E7E9F0" WindowStyle="None" ResizeMode="CanResize">
  <Window.Resources>
    <SolidColorBrush x:Key="Accent" Color="#6D5EF6"/>
    <SolidColorBrush x:Key="Muted" Color="#8A90A6"/>
    <SolidColorBrush x:Key="Line" Color="#232736"/>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="#141722"/><Setter Property="BorderBrush" Value="#232736"/><Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="14"/><Setter Property="Padding" Value="18"/>
    </Style>
    <Style x:Key="H1" TargetType="TextBlock"><Setter Property="FontSize" Value="22"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Foreground" Value="#F2F3F8"/></Style>
    <Style x:Key="H2" TargetType="TextBlock"><Setter Property="FontSize" Value="14"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Foreground" Value="#E7E9F0"/></Style>
    <Style x:Key="Sub" TargetType="TextBlock"><Setter Property="FontSize" Value="12.5"/><Setter Property="Foreground" Value="#8A90A6"/><Setter Property="TextWrapping" Value="Wrap"/></Style>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="#D7DAE6"/><Setter Property="Background" Value="#1A1D27"/><Setter Property="BorderBrush" Value="#2E3340"/>
      <Setter Property="FontWeight" Value="SemiBold"/><Setter Property="FontSize" Value="13"/><Setter Property="Cursor" Value="Hand"/><Setter Property="Height" Value="40"/><Setter Property="Padding" Value="16,0"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="10" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" Padding="{TemplateBinding Padding}">
            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.85"/></Trigger>
            <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.7"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.35"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style x:Key="Link" TargetType="Button">
      <Setter Property="Foreground" Value="#A9A2FF"/><Setter Property="FontSize" Value="12.5"/><Setter Property="Cursor" Value="Hand"/><Setter Property="Background" Value="Transparent"/><Setter Property="Padding" Value="8,4"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="b" Background="{TemplateBinding Background}" CornerRadius="7" Padding="{TemplateBinding Padding}"><ContentPresenter VerticalAlignment="Center"/></Border>
          <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#1E2231"/></Trigger></ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style x:Key="Nav" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#9AA0B4"/><Setter Property="FontSize" Value="13.5"/><Setter Property="Cursor" Value="Hand"/><Setter Property="Margin" Value="0,2"/><Setter Property="GroupName" Value="nav"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="RadioButton">
          <Border x:Name="b" Background="Transparent" CornerRadius="10" Height="42" Padding="14,0">
            <Grid>
              <Border x:Name="bar" Width="3" Height="18" CornerRadius="2" Background="#6D5EF6" HorizontalAlignment="Left" Margin="-10,0,0,0" Visibility="Hidden"/>
              <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
                <TextBlock Text="{TemplateBinding Tag}" FontFamily="Segoe MDL2 Assets" FontSize="15" Width="22" VerticalAlignment="Center" Foreground="{TemplateBinding Foreground}"/>
                <TextBlock Text="{TemplateBinding Content}" Margin="10,0,0,0" VerticalAlignment="Center" Foreground="{TemplateBinding Foreground}"/>
              </StackPanel>
            </Grid>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#181B25"/></Trigger>
            <Trigger Property="IsChecked" Value="True"><Setter TargetName="b" Property="Background" Value="#1E2231"/><Setter TargetName="bar" Property="Visibility" Value="Visible"/><Setter Property="Foreground" Value="#FFFFFF"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style x:Key="Seg" TargetType="RadioButton">
      <Setter Property="Foreground" Value="#C9CCD8"/><Setter Property="FontSize" Value="12.5"/><Setter Property="Cursor" Value="Hand"/><Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="RadioButton">
          <Border x:Name="b" Background="#1A1D27" BorderBrush="#2E3340" BorderThickness="1" CornerRadius="9" Padding="14,7">
            <TextBlock Text="{TemplateBinding Content}" Foreground="{TemplateBinding Foreground}"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="BorderBrush" Value="#4A4F63"/></Trigger>
            <Trigger Property="IsChecked" Value="True"><Setter TargetName="b" Property="Background" Value="#6D5EF6"/><Setter TargetName="b" Property="BorderBrush" Value="#6D5EF6"/><Setter Property="Foreground" Value="White"/></Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.4"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style x:Key="Switch" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="CheckBox">
          <Border x:Name="track" Width="40" Height="22" CornerRadius="11" Background="#2A2F3D">
            <Border x:Name="knob" Width="16" Height="16" CornerRadius="8" Background="#8A90A6" HorizontalAlignment="Left" Margin="3,0,0,0"/>
          </Border>
          <ControlTemplate.Triggers>
            <Trigger Property="IsChecked" Value="True">
              <Setter TargetName="track" Property="Background" Value="#6D5EF6"/><Setter TargetName="knob" Property="HorizontalAlignment" Value="Right"/>
              <Setter TargetName="knob" Property="Margin" Value="0,0,3,0"/><Setter TargetName="knob" Property="Background" Value="White"/>
            </Trigger>
            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="track" Property="Opacity" Value="0.4"/></Trigger>
          </ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <!-- ince koyu kaydırma çubuğu (Windows'un açık renkli varsayılanı yerine) -->
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="10"/><Setter Property="MinWidth" Value="10"/><Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="ScrollBar">
          <Track x:Name="PART_Track" IsDirectionReversed="True" Focusable="False">
            <Track.Thumb><Thumb><Thumb.Template><ControlTemplate TargetType="Thumb"><Border Background="#353A4C" CornerRadius="4" Margin="2"/></ControlTemplate></Thumb.Template></Thumb></Track.Thumb>
          </Track>
        </ControlTemplate>
      </Setter.Value></Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/><Setter Property="MinWidth" Value="0"/><Setter Property="Height" Value="10"/><Setter Property="MinHeight" Value="10"/>
          <Setter Property="Template"><Setter.Value>
            <ControlTemplate TargetType="ScrollBar">
              <Track x:Name="PART_Track" IsDirectionReversed="False" Focusable="False">
                <Track.Thumb><Thumb><Thumb.Template><ControlTemplate TargetType="Thumb"><Border Background="#353A4C" CornerRadius="4" Margin="2"/></ControlTemplate></Thumb.Template></Thumb></Track.Thumb>
              </Track>
            </ControlTemplate>
          </Setter.Value></Setter>
        </Trigger>
      </Style.Triggers>
    </Style>
    <!-- ilerleme çubuğu: yuvarlak, mor geçişli -->
    <Style x:Key="Prog" TargetType="ProgressBar">
      <Setter Property="Height" Value="8"/><Setter Property="Minimum" Value="0"/><Setter Property="Maximum" Value="100"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="ProgressBar">
          <Grid>
            <Border x:Name="PART_Track" CornerRadius="4" Background="#232737"/>
            <Border x:Name="PART_Indicator" CornerRadius="4" HorizontalAlignment="Left">
              <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#6D5EF6" Offset="0"/><GradientStop Color="#B49CFF" Offset="1"/></LinearGradientBrush></Border.Background>
            </Border>
          </Grid>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <!-- başlık çubuğu düğmeleri -->
    <Style x:Key="Cap" TargetType="Button">
      <Setter Property="Width" Value="46"/><Setter Property="Height" Value="32"/><Setter Property="Foreground" Value="#9AA0B4"/><Setter Property="Background" Value="Transparent"/>
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/><Setter Property="FontSize" Value="10"/><Setter Property="WindowChrome.IsHitTestVisibleInChrome" Value="True"/>
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="b" Background="{TemplateBinding Background}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
          <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#1E2231"/><Setter Property="Foreground" Value="White"/></Trigger></ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
    <Style x:Key="CapClose" TargetType="Button" BasedOn="{StaticResource Cap}">
      <Setter Property="Template"><Setter.Value>
        <ControlTemplate TargetType="Button">
          <Border x:Name="b" Background="{TemplateBinding Background}"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border>
          <ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#E81123"/><Setter Property="Foreground" Value="White"/></Trigger></ControlTemplate.Triggers>
        </ControlTemplate>
      </Setter.Value></Setter>
    </Style>
  </Window.Resources>
  <!-- Windows'un beyaz başlık çubuğu yerine koyu, uygulamaya ait başlık (sürükleme/boyutlandırma/yaslama korunur) -->
  <WindowChrome.WindowChrome>
    <WindowChrome CaptionHeight="38" ResizeBorderThickness="6" GlassFrameThickness="0" CornerRadius="0" UseAeroCaptionButtons="False"/>
  </WindowChrome.WindowChrome>

  <Border x:Name="rootBorder" BorderBrush="#2A2E3C" BorderThickness="1">
  <Grid>
    <Grid.ColumnDefinitions><ColumnDefinition Width="212"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>

    <!-- ===== KENAR MENÜ ===== -->
    <Border Grid.Column="0" Background="#12141B" BorderBrush="#1E212C" BorderThickness="0,0,1,0">
      <Grid Margin="14,20,14,16">
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <StackPanel Orientation="Horizontal" Margin="6,0,0,26">
          <Border Width="38" Height="38" CornerRadius="11" Background="{StaticResource Accent}">
            <TextBlock Text="Z" Foreground="White" FontSize="19" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <StackPanel Margin="11,0,0,0" VerticalAlignment="Center">
            <TextBlock Text="zapret-auto" FontSize="15.5" FontWeight="SemiBold" Foreground="#F2F3F8"/>
            <TextBlock x:Name="txtVer" FontSize="11.5" Foreground="{StaticResource Muted}"/>
          </StackPanel>
        </StackPanel>
        <StackPanel Grid.Row="1">
          <RadioButton x:Name="navHome" Style="{StaticResource Nav}" Tag="&#xE80F;" IsChecked="True"/>
          <RadioButton x:Name="navSites" Style="{StaticResource Nav}" Tag="&#xE774;"/>
          <RadioButton x:Name="navWatch" Style="{StaticResource Nav}" Tag="&#xEA18;"/>
          <RadioButton x:Name="navSettings" Style="{StaticResource Nav}" Tag="&#xE713;"/>
          <RadioButton x:Name="navLog" Style="{StaticResource Nav}" Tag="&#xE8A5;"/>
        </StackPanel>
        <Border Grid.Row="2" CornerRadius="10" Background="#171A23" Padding="12,10">
          <StackPanel Orientation="Horizontal">
            <Ellipse x:Name="sideDot" Width="9" Height="9" Fill="#8A90A6" VerticalAlignment="Center"/>
            <TextBlock x:Name="sideTxt" Margin="9,0,0,0" FontSize="12.5" Foreground="#C9CCD8" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
          </StackPanel>
        </Border>
      </Grid>
    </Border>

    <!-- ===== İÇERİK ===== -->
    <Grid Grid.Column="1">
      <Grid.RowDefinitions><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
      <Grid Margin="30,44,30,14">

        <!-- ANA SAYFA -->
        <Grid x:Name="pgHome">
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
          <TextBlock x:Name="hHome" Style="{StaticResource H1}" Margin="0,0,0,18"/>
          <StackPanel Grid.Row="1">
            <Border x:Name="banWatch" Visibility="Collapsed" CornerRadius="12" Background="#1B1930" BorderBrush="#3A3470" BorderThickness="1" Padding="16,9" Margin="0,0,0,12">
              <DockPanel>
                <Button x:Name="banWatchX" Style="{StaticResource Link}" DockPanel.Dock="Right" Content="&#xE711;" FontFamily="Segoe MDL2 Assets" FontSize="10" Foreground="#8A90A6" VerticalAlignment="Center"/>
                <Button x:Name="banWatchGo" Style="{StaticResource Link}" DockPanel.Dock="Right" VerticalAlignment="Center"/>
                <TextBlock Text="&#xEA18;" FontFamily="Segoe MDL2 Assets" FontSize="15" Foreground="#A9A2FF" VerticalAlignment="Center" Margin="0,0,12,0"/>
                <TextBlock x:Name="banWatchTxt" FontSize="13" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
              </DockPanel>
            </Border>
            <Border x:Name="banConf" Visibility="Collapsed" CornerRadius="12" Background="#272114" BorderBrush="#5A4A22" BorderThickness="1" Padding="16,9" Margin="0,0,0,12">
              <DockPanel>
                <Button x:Name="banConfGo" Style="{StaticResource Link}" DockPanel.Dock="Right" VerticalAlignment="Center" Foreground="#F0C86E"/>
                <TextBlock Text="&#xE7BA;" FontFamily="Segoe MDL2 Assets" FontSize="15" Foreground="#F0C86E" VerticalAlignment="Center" Margin="0,0,12,0"/>
                <TextBlock x:Name="banConfTxt" FontSize="13" VerticalAlignment="Center" TextWrapping="Wrap"/>
              </DockPanel>
            </Border>
          </StackPanel>          <Border Grid.Row="2" Style="{StaticResource Card}" Padding="24,22">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <Border x:Name="heroBg" Width="66" Height="66" CornerRadius="33" Background="#1E2130" VerticalAlignment="Center">
                <TextBlock x:Name="heroIcon" FontFamily="Segoe MDL2 Assets" FontSize="28" Foreground="#8A90A6" HorizontalAlignment="Center" VerticalAlignment="Center"/>
              </Border>
              <StackPanel Grid.Column="1" Margin="20,0,16,0" VerticalAlignment="Center">
                <TextBlock x:Name="heroTitle" FontSize="23" FontWeight="SemiBold" Foreground="#F2F3F8"/>
                <TextBlock x:Name="heroSub" Style="{StaticResource Sub}" FontSize="13" Margin="0,5,0,0"/>
              </StackPanel>
              <StackPanel Grid.Column="2" VerticalAlignment="Center">
                <Button x:Name="btnInstall" Style="{StaticResource Btn}" Background="#6D5EF6" BorderBrush="#6D5EF6" Foreground="White" Width="178" Height="42">
                  <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE896;" FontFamily="Segoe MDL2 Assets" FontSize="14" Margin="0,0,9,0" VerticalAlignment="Center"/><TextBlock x:Name="lblInstall" VerticalAlignment="Center"/></StackPanel>
                </Button>
                <Button x:Name="btnProbe" Style="{StaticResource Btn}" Width="178" Margin="0,9,0,0">
                  <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE721;" FontFamily="Segoe MDL2 Assets" FontSize="14" Margin="0,0,9,0" VerticalAlignment="Center"/><TextBlock x:Name="lblProbe" VerticalAlignment="Center"/></StackPanel>
                </Button>
              </StackPanel>
            </Grid>
          </Border>
          <Grid Grid.Row="3" Margin="0,14,0,0">
            <UniformGrid x:Name="cards" Columns="3">
            <Border Style="{StaticResource Card}" Margin="0,0,7,0">
              <StackPanel>
                <DockPanel><CheckBox x:Name="swZap" Style="{StaticResource Switch}" DockPanel.Dock="Right"/><TextBlock x:Name="cZap" Style="{StaticResource H2}" VerticalAlignment="Center"/></DockPanel>
                <StackPanel Orientation="Horizontal" Margin="0,14,0,0"><Ellipse x:Name="dotZap" Width="9" Height="9" Fill="#8A90A6" VerticalAlignment="Center"/><TextBlock x:Name="txtZap" Margin="8,0,0,0" FontSize="13"/></StackPanel>
                <TextBlock x:Name="detZap" Style="{StaticResource Sub}" FontSize="12" Margin="0,6,0,0" TextTrimming="CharacterEllipsis" TextWrapping="NoWrap"/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}" Margin="7,0,7,0">
              <StackPanel>
                <DockPanel><CheckBox x:Name="swDoh" Style="{StaticResource Switch}" DockPanel.Dock="Right"/><TextBlock x:Name="cDoh" Style="{StaticResource H2}" VerticalAlignment="Center"/></DockPanel>
                <StackPanel Orientation="Horizontal" Margin="0,14,0,0"><Ellipse x:Name="dotDoh" Width="9" Height="9" Fill="#8A90A6" VerticalAlignment="Center"/><TextBlock x:Name="txtDoh" Margin="8,0,0,0" FontSize="13"/></StackPanel>
                <TextBlock x:Name="detDoh" Style="{StaticResource Sub}" FontSize="12" Margin="0,6,0,0" TextTrimming="CharacterEllipsis" TextWrapping="NoWrap"/>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}" Margin="7,0,0,0">
              <StackPanel>
                <DockPanel><CheckBox x:Name="swWat" Style="{StaticResource Switch}" DockPanel.Dock="Right"/><TextBlock x:Name="cWat" Style="{StaticResource H2}" VerticalAlignment="Center"/></DockPanel>
                <StackPanel Orientation="Horizontal" Margin="0,14,0,0"><Ellipse x:Name="dotWat" Width="9" Height="9" Fill="#8A90A6" VerticalAlignment="Center"/><TextBlock x:Name="txtWat" Margin="8,0,0,0" FontSize="13"/></StackPanel>
                <TextBlock x:Name="detWat" Style="{StaticResource Sub}" FontSize="12" Margin="0,6,0,0" TextTrimming="CharacterEllipsis" TextWrapping="NoWrap"/>
              </StackPanel>
            </Border>
            </UniformGrid>
            <Border x:Name="stepCard" Style="{StaticResource Card}" Visibility="Collapsed" Padding="22,16">
              <Grid>
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                <DockPanel>
                  <Button x:Name="stepClose" Style="{StaticResource Link}" DockPanel.Dock="Right" Visibility="Collapsed" VerticalAlignment="Center"/>
                  <Button x:Name="stepLog" Style="{StaticResource Link}" DockPanel.Dock="Right" VerticalAlignment="Center"/>
                  <TextBlock x:Name="stepTitle" Style="{StaticResource H2}" FontSize="15" VerticalAlignment="Center"/>
                </DockPanel>
                <Grid Grid.Row="1" Margin="0,12,0,2">
                  <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                  <ProgressBar x:Name="stepProg" Style="{StaticResource Prog}" VerticalAlignment="Center"/>
                  <TextBlock x:Name="stepPct" Grid.Column="1" FontSize="13" FontWeight="SemiBold" Foreground="#C9C2FF" Margin="12,0,0,0" MinWidth="40" TextAlignment="Right" VerticalAlignment="Center"/>
                </Grid>
                <TextBlock x:Name="stepDetail" Grid.Row="2" Style="{StaticResource Sub}" Margin="0,4,0,0" TextTrimming="CharacterEllipsis" TextWrapping="NoWrap"/>
                <UniformGrid x:Name="stepList" Grid.Row="3" Columns="2" Margin="0,10,0,0"/>
              </Grid>
            </Border>
          </Grid>          <TextBlock x:Name="hint" Grid.Row="4" Style="{StaticResource Sub}" Margin="2,16,0,0"/>
        </Grid>

        <!-- SİTELER -->
        <Grid x:Name="pgSites" Visibility="Collapsed">
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
          <DockPanel>
            <Button x:Name="btnSites" Style="{StaticResource Btn}" DockPanel.Dock="Right" VerticalAlignment="Top">
              <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE72C;" FontFamily="Segoe MDL2 Assets" FontSize="13" Margin="0,0,8,0" VerticalAlignment="Center"/><TextBlock x:Name="lblSites" VerticalAlignment="Center"/></StackPanel>
            </Button>
            <TextBlock x:Name="hSites" Style="{StaticResource H1}"/>
          </DockPanel>
          <TextBlock x:Name="sitesSub" Grid.Row="1" Style="{StaticResource Sub}" Margin="0,8,0,16"/>
          <Border Grid.Row="2" Style="{StaticResource Card}" Padding="6,4">
            <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="sitesList"/></ScrollViewer>
          </Border>
        </Grid>

        <!-- NÖBETÇİ -->
        <Grid x:Name="pgWatch" Visibility="Collapsed">
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
          <TextBlock x:Name="hWatch" Style="{StaticResource H1}" Margin="0,0,0,18"/>
          <Border Grid.Row="1" Style="{StaticResource Card}" Padding="22,20">
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <StackPanel>
                <StackPanel Orientation="Horizontal"><Ellipse x:Name="wDot" Width="10" Height="10" Fill="#8A90A6" VerticalAlignment="Center"/><TextBlock x:Name="wTitle" Margin="10,0,0,0" FontSize="17" FontWeight="SemiBold"/></StackPanel>
                <TextBlock x:Name="wSub" Style="{StaticResource Sub}" FontSize="13" Margin="20,6,0,0"/>
              </StackPanel>
              <StackPanel Grid.Column="1" VerticalAlignment="Center" Orientation="Horizontal">
                <CheckBox x:Name="swWat2" Style="{StaticResource Switch}" VerticalAlignment="Center" Margin="0,0,16,0"/>
                <Button x:Name="btnWatchNow" Style="{StaticResource Btn}" Background="#6D5EF6" BorderBrush="#6D5EF6" Foreground="White">
                  <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE768;" FontFamily="Segoe MDL2 Assets" FontSize="13" Margin="0,0,8,0" VerticalAlignment="Center"/><TextBlock x:Name="lblWatchNow" VerticalAlignment="Center"/></StackPanel>
                </Button>
              </StackPanel>
            </Grid>
          </Border>
          <TextBlock x:Name="wAbout" Grid.Row="2" Style="{StaticResource Sub}" Margin="2,14,0,16"/>
          <Border Grid.Row="3" Style="{StaticResource Card}" Padding="6,4">
            <Grid>
              <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
              <TextBlock x:Name="hEvents" Style="{StaticResource H2}" Margin="14,12,0,6"/>
              <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto"><StackPanel x:Name="watchEvents"/></ScrollViewer>
            </Grid>
          </Border>
        </Grid>

        <!-- AYARLAR -->
        <ScrollViewer x:Name="pgSettings" Visibility="Collapsed" VerticalScrollBarVisibility="Auto">
          <StackPanel Margin="0,0,6,0">
            <TextBlock x:Name="hSettings" Style="{StaticResource H1}" Margin="0,0,0,18"/>
            <Border Style="{StaticResource Card}" Margin="0,0,0,12">
              <DockPanel>
                <CheckBox x:Name="swGame" Style="{StaticResource Switch}" DockPanel.Dock="Right" VerticalAlignment="Center"/>
                <StackPanel Margin="0,0,20,0"><TextBlock x:Name="sGameT" Style="{StaticResource H2}"/><TextBlock x:Name="sGameD" Style="{StaticResource Sub}" Margin="0,5,0,0"/></StackPanel>
              </DockPanel>
            </Border>
            <Border Style="{StaticResource Card}" Margin="0,0,0,12">
              <StackPanel>
                <TextBlock x:Name="sEngT" Style="{StaticResource H2}"/><TextBlock x:Name="sEngD" Style="{StaticResource Sub}" Margin="0,5,0,12"/>
                <StackPanel Orientation="Horizontal">
                  <RadioButton x:Name="engAuto" Style="{StaticResource Seg}" GroupName="eng"/>
                  <RadioButton x:Name="engDns" Style="{StaticResource Seg}" GroupName="eng" Content="dnscrypt-proxy"/>
                  <RadioButton x:Name="engNat" Style="{StaticResource Seg}" GroupName="eng"/>
                </StackPanel>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}" Margin="0,0,0,12">
              <StackPanel>
                <TextBlock x:Name="sLangT" Style="{StaticResource H2}"/><TextBlock x:Name="sLangD" Style="{StaticResource Sub}" Margin="0,5,0,12"/>
                <StackPanel Orientation="Horizontal">
                  <RadioButton x:Name="langAuto" Style="{StaticResource Seg}" GroupName="lang"/>
                  <RadioButton x:Name="langTr" Style="{StaticResource Seg}" GroupName="lang" Content="Türkçe"/>
                  <RadioButton x:Name="langEn" Style="{StaticResource Seg}" GroupName="lang" Content="English"/>
                </StackPanel>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}" Margin="0,0,0,12">
              <StackPanel>
                <TextBlock x:Name="sToolsT" Style="{StaticResource H2}"/><TextBlock x:Name="sToolsD" Style="{StaticResource Sub}" Margin="0,5,0,12"/>
                <WrapPanel>
                  <Button x:Name="btnStatus" Style="{StaticResource Btn}" Margin="0,0,8,8"/>
                  <Button x:Name="btnReport" Style="{StaticResource Btn}" Margin="0,0,8,8"/>
                  <Button x:Name="btnPack" Style="{StaticResource Btn}" Margin="0,0,8,8"/>
                  <Button x:Name="btnLogFile" Style="{StaticResource Btn}" Margin="0,0,8,8"/>
                </WrapPanel>
              </StackPanel>
            </Border>
            <Border Style="{StaticResource Card}" BorderBrush="#4A2229" Background="#16121A">
              <DockPanel>
                <Button x:Name="btnRemove" Style="{StaticResource Btn}" DockPanel.Dock="Right" VerticalAlignment="Center" Background="#2A161B" BorderBrush="#5A2A31" Foreground="#F09098">
                  <StackPanel Orientation="Horizontal"><TextBlock Text="&#xE74D;" FontFamily="Segoe MDL2 Assets" FontSize="13" Margin="0,0,8,0" VerticalAlignment="Center"/><TextBlock x:Name="lblRemove" VerticalAlignment="Center"/></StackPanel>
                </Button>
                <StackPanel Margin="0,0,20,0"><TextBlock x:Name="sRemT" Style="{StaticResource H2}" Foreground="#F09098"/><TextBlock x:Name="sRemD" Style="{StaticResource Sub}" Margin="0,5,0,0"/></StackPanel>
              </DockPanel>
            </Border>
          </StackPanel>
        </ScrollViewer>

        <!-- KAYITLAR -->
        <Grid x:Name="pgLog" Visibility="Collapsed">
          <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
          <DockPanel Margin="0,0,0,16">
            <Button x:Name="btnLogFile2" Style="{StaticResource Link}" DockPanel.Dock="Right" VerticalAlignment="Center"/>
            <TextBlock x:Name="hLog" Style="{StaticResource H1}"/>
          </DockPanel>
          <Border Grid.Row="1" CornerRadius="14" Background="#0A0C10" BorderBrush="{StaticResource Line}" BorderThickness="1">
            <RichTextBox x:Name="log" IsReadOnly="True" Background="Transparent" Foreground="#D2D4DC" BorderThickness="0" Padding="14,12" FontFamily="Consolas" FontSize="12.5" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
          </Border>
        </Grid>
      </Grid>

      <!-- ÇALIŞIYOR ŞERİDİ -->
      <Border x:Name="busyBar" Grid.Row="1" Visibility="Collapsed" Background="#141722" BorderBrush="{StaticResource Line}" BorderThickness="0,1,0,0" Padding="30,10">
        <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <Grid x:Name="prog" Width="110" Height="4" ClipToBounds="True" VerticalAlignment="Center">
            <Border Background="#1E2231" CornerRadius="2"/>
            <Border x:Name="marqBar" Width="42" CornerRadius="2" HorizontalAlignment="Left">
              <Border.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,0"><GradientStop Color="#006D5EF6" Offset="0"/><GradientStop Color="#B49CFF" Offset="0.5"/><GradientStop Color="#006D5EF6" Offset="1"/></LinearGradientBrush></Border.Background>
            </Border>
          </Grid>
          <TextBlock x:Name="busyTxt" Grid.Column="1" Margin="14,0" FontSize="12.5" Foreground="#C9CCD8" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
          <Button x:Name="btnShowLog" Grid.Column="2" Style="{StaticResource Link}"/>
        </Grid>
      </Border>

      <!-- BAŞLIK ÇUBUĞU DÜĞMELERİ -->
      <StackPanel Grid.RowSpan="2" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Top" Panel.ZIndex="20">
        <Button x:Name="capMin" Style="{StaticResource Cap}" Content="&#xE921;"/>
        <Button x:Name="capMax" Style="{StaticResource Cap}" Content="&#xE922;"/>
        <Button x:Name="capClose" Style="{StaticResource CapClose}" Content="&#xE8BB;"/>
      </StackPanel>
      <!-- BİLDİRİM BALONCUĞU -->
      <Border x:Name="toast" Grid.RowSpan="2" Visibility="Collapsed" HorizontalAlignment="Right" VerticalAlignment="Bottom" Margin="0,0,26,66" Panel.ZIndex="30"
              CornerRadius="12" Background="#1E2231" BorderBrush="#33384A" BorderThickness="1" Padding="16,11" IsHitTestVisible="False">
        <Border.Effect><DropShadowEffect BlurRadius="18" ShadowDepth="4" Opacity="0.45" Color="Black"/></Border.Effect>
        <StackPanel Orientation="Horizontal">
          <TextBlock x:Name="toastIcon" FontFamily="Segoe MDL2 Assets" FontSize="14" VerticalAlignment="Center" Margin="0,0,10,0"/>
          <TextBlock x:Name="toastTxt" FontSize="13" VerticalAlignment="Center" Foreground="#F2F3F8"/>
        </StackPanel>
      </Border>
    </Grid>
  </Grid>
  </Border>
</Window>
'@
  $win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
  $ui = @{}
  foreach($n in @('txtVer','navHome','navSites','navWatch','navSettings','navLog','sideDot','sideTxt',
                  'pgHome','hHome','heroBg','heroIcon','heroTitle','heroSub','btnInstall','lblInstall','btnProbe','lblProbe',
                  'swZap','cZap','dotZap','txtZap','detZap','swDoh','cDoh','dotDoh','txtDoh','detDoh','swWat','cWat','dotWat','txtWat','detWat','hint',
                  'pgSites','btnSites','lblSites','hSites','sitesSub','sitesList',
                  'pgWatch','hWatch','wDot','wTitle','wSub','swWat2','btnWatchNow','lblWatchNow','wAbout','hEvents','watchEvents',
                  'pgSettings','hSettings','swGame','sGameT','sGameD','sEngT','sEngD','engAuto','engDns','engNat','sLangT','sLangD','langAuto','langTr','langEn',
                  'sToolsT','sToolsD','btnStatus','btnReport','btnPack','btnLogFile','btnRemove','lblRemove','sRemT','sRemD',
                  'pgLog','hLog','btnLogFile2','log','busyBar','prog','busyTxt','btnShowLog',
                  'banWatch','banWatchX','banWatchGo','banWatchTxt','banConf','banConfGo','banConfTxt','cards','stepCard','stepClose','stepLog','stepTitle','stepDetail','stepList',
                  'rootBorder','capMin','capMax','capClose','toast','toastIcon','toastTxt','marqBar','stepProg','stepPct')){ $ui[$n] = $win.FindName($n) }

  # ---------------- metinler ----------------
  $win.Title = "zapret-auto $ZA_VERSION"
  # Pencere/görev çubuğu simgesi: mor "Z" rozeti koddan çizilir (ek dosya yok; PowerShell simgesi görünmesin)
  try {
    $dv = New-Object Windows.Media.DrawingVisual; $dc = $dv.RenderOpen()
    $dc.DrawRoundedRectangle((New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(109, 94, 246))), $null, (New-Object Windows.Rect(0, 0, 64, 64)), 15, 15)
    $tf = New-Object Windows.Media.Typeface((New-Object Windows.Media.FontFamily('Segoe UI')), [Windows.FontStyles]::Normal, [Windows.FontWeights]::Bold, [Windows.FontStretches]::Normal)
    $ft = New-Object Windows.Media.FormattedText('Z', [Globalization.CultureInfo]::InvariantCulture, [Windows.FlowDirection]::LeftToRight, $tf, 40, [Windows.Media.Brushes]::White)
    $dc.DrawText($ft, (New-Object Windows.Point(((64 - $ft.Width) / 2), ((64 - $ft.Height) / 2))))
    $dc.Close()
    $ico = New-Object Windows.Media.Imaging.RenderTargetBitmap(64, 64, 96, 96, [Windows.Media.PixelFormats]::Pbgra32); $ico.Render($dv); $ico.Freeze()
    $win.Icon = $ico
  } catch {}
  $ui.banWatchGo.Content = T 'Ayrıntılar' 'Details'
  $ui.banConfGo.Content = T 'Kur / Onar ile çöz' 'Fix with Install / Repair'
  $ui.stepLog.Content = T 'Kayıtları göster' 'Show logs'
  $ui.stepClose.Content = T 'Kapat' 'Close'
  $ui.txtVer.Text = "v$ZA_VERSION"
  $ui.navHome.Content = T 'Ana sayfa' 'Home'; $ui.navSites.Content = T 'Siteler' 'Sites'; $ui.navWatch.Content = T 'Nöbetçi' 'Watchdog'
  $ui.navSettings.Content = T 'Ayarlar' 'Settings'; $ui.navLog.Content = T 'Kayıtlar' 'Logs'
  $ui.hHome.Text = T 'Ana sayfa' 'Home'; $ui.hSites.Text = T 'Siteler' 'Sites'; $ui.hWatch.Text = T 'Nöbetçi' 'Watchdog'; $ui.hSettings.Text = T 'Ayarlar' 'Settings'; $ui.hLog.Text = T 'Kayıtlar' 'Logs'
  $ui.lblInstall.Text = T 'Kur / Onar' 'Install / Repair'; $ui.lblProbe.Text = T 'Test Et' 'Test'
  $ui.cZap.Text = T 'DPI atlatma' 'DPI bypass'; $ui.cDoh.Text = T 'Şifreli DNS' 'Encrypted DNS'; $ui.cWat.Text = T 'Nöbetçi' 'Watchdog'
  $ui.lblSites.Text = T 'Şimdi kontrol et' 'Check now'
  $ui.lblWatchNow.Text = T 'Şimdi çalıştır' 'Run now'
  $ui.wAbout.Text = T 'Nöbetçi arka planda sürekli çalışan bir program değildir; Windows''un zamanlanmış görevidir. Açılışta, 6 saatte bir ve ağ değişince çalışır: duran servisleri başlatır, bozulan DNS ayarını düzeltir, strateji artık çalışmıyorsa yenisini bulur ve yarıda kalmış işlemleri toparlar.' 'The watchdog is not a resident program; it is a Windows scheduled task. It runs at boot, every 6 hours and on network change: restarts stopped services, fixes DNS drift, finds a new strategy if the current one stops working, and recovers interrupted tasks.'
  $ui.hEvents.Text = T 'Son olaylar' 'Recent events'
  $ui.sGameT.Text = T 'Oyun filtresi' 'Game filter'
  $ui.sGameD.Text = T 'DPI atlatmayı 1024-65535 arası TCP/UDP portlarına da uygular (sadece paketteki IP listesine giden trafik). Bir oyun ya da oyun içi ses bağlanmıyorsa aç; sorun yoksa kapalı kalsın.' 'Also applies DPI bypass to TCP/UDP ports 1024-65535 (only traffic to the bundled IP list). Turn on if a game or in-game voice won''t connect; otherwise keep it off.'
  $ui.sEngT.Text = T 'Şifreli DNS motoru' 'Encrypted DNS engine'
  $ui.sEngD.Text = T 'Otomatik: Windows 11''de Windows''un kendi DoH''u, Windows 10''da dnscrypt-proxy. Değişiklik bir sonraki DoH açılışında / Kur-Onar''da uygulanır.' 'Automatic: Windows'' own DoH on Windows 11, dnscrypt-proxy on Windows 10. Applies on the next DoH enable / Install-Repair.'
  $ui.engAuto.Content = T 'Otomatik' 'Automatic'; $ui.engNat.Content = T 'Windows yerleşik' 'Windows built-in'
  $ui.sLangT.Text = T 'Dil' 'Language'
  $ui.sLangD.Text = T 'Arayüz yeniden açılınca uygulanır.' 'Applies when the window is reopened.'
  $ui.langAuto.Content = T 'Otomatik' 'Automatic'
  $ui.sToolsT.Text = T 'Araçlar' 'Tools'
  $ui.sToolsD.Text = T 'Rapor: destek için maskelenmiş teşhis dosyası. Çevrimdışı paket: interneti / GitHub erişimi olmayan bir bilgisayar için .bat + paketler.' 'Report: masked diagnostic file for support. Offline package: .bat + packages for a PC without internet / GitHub access.'
  $ui.btnStatus.Content = T 'Ayrıntılı durum' 'Detailed status'; $ui.btnReport.Content = T 'Teşhis raporu' 'Diagnostic report'
  $ui.btnPack.Content = T 'Çevrimdışı paket' 'Offline package'; $ui.btnLogFile.Content = T 'Kayıt dosyasını aç' 'Open log file'
  $ui.sRemT.Text = T 'Kaldır' 'Uninstall'
  $ui.sRemD.Text = T 'Servisleri, nöbetçiyi ve dosyaları siler; DNS ve diğer ayarları kurulumdan önceki haline döndürür.' 'Removes services, watchdog and files; restores DNS and other settings to their pre-install state.'
  $ui.lblRemove.Text = T 'Kaldır' 'Uninstall'
  $ui.btnLogFile2.Content = T 'Dosyayı aç' 'Open file'
  $ui.btnShowLog.Content = T 'Kayıtları göster' 'Show logs'

  # ---------------- yardımcılar ----------------
  $para = New-Object Windows.Documents.Paragraph; $para.LineHeight = 15
  $ui.log.Document.Blocks.Clear(); $ui.log.Document.PagePadding = New-Object Windows.Thickness(0); $ui.log.Document.Blocks.Add($para)
  function B([string]$hex){ New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString($hex)) }
  $col = @{ i = (B '#D2D4DC'); ok = (B '#78DC8C'); warn = (B '#F0C86E'); err = (B '#F06E7A'); head = (B '#82AAFF'); dim = (B '#787E92') }
  $tone = @{
    ok   = @{ fg = (B '#50D278'); bg = (B '#173123') }
    warn = @{ fg = (B '#F0C86E'); bg = (B '#33291A') }
    err  = @{ fg = (B '#F0637A'); bg = (B '#331A20') }
    off  = @{ fg = (B '#8A90A6'); bg = (B '#1E2130') }
  }
  $script:hadErr = $false; $script:Marks = @(); $script:LastMode = ''; $script:syncing = $false; $script:SitesChecked = $false; $script:Tick = 0

  function Add-Line([string]$t, [string]$lvl = 'i'){
    if($lvl -eq 'err'){ $script:hadErr = $true }
    $run = New-Object Windows.Documents.Run($t); $run.Foreground = $(if($col[$lvl]){ $col[$lvl] } else { $col.i })
    if($lvl -eq 'head'){ $run.FontWeight = 'SemiBold' }
    $para.Inlines.Add($run); $para.Inlines.Add((New-Object Windows.Documents.LineBreak)); $ui.log.ScrollToEnd()
    if($Sync.Busy -and $t.Trim() -and $lvl -ne 'dim'){ $script:LastBusyLine = $t.Trim(); $ui.busyTxt.Text = $(if($script:StepMode){ (T "%$($script:Pct) · " "$($script:Pct)% · ") + $script:LastBusyLine } else { $script:LastBusyLine }) }
    if($script:StepMode -and $t.Trim() -and $lvl -notin @('dim', 'head')){ $ui.stepDetail.Text = $t.Trim() }
  }
  function Show-Page([string]$p){
    foreach($k in @('Home','Sites','Watch','Settings','Log')){ $ui["pg$k"].Visibility = $(if($k -eq $p){ 'Visible' } else { 'Collapsed' }) }
    $fa = New-Object Windows.Media.Animation.DoubleAnimation(0.0, 1.0, (New-Object Windows.Duration([TimeSpan]::FromMilliseconds(160)))); $ui["pg$p"].BeginAnimation([Windows.UIElement]::OpacityProperty, $fa)
    $script:syncing = $true; $ui["nav$p"].IsChecked = $true; $script:syncing = $false
  }
  function Set-Busy([bool]$b){
    $Sync.Busy = $b
    foreach($x in @($ui.btnInstall, $ui.btnProbe, $ui.btnSites, $ui.btnWatchNow, $ui.btnStatus, $ui.btnReport, $ui.btnPack, $ui.btnRemove,
                    $ui.swZap, $ui.swDoh, $ui.swWat, $ui.swWat2, $ui.swGame, $ui.engAuto, $ui.engDns, $ui.engNat, $ui.langAuto, $ui.langTr, $ui.langEn)){ $x.IsEnabled = -not $b }
    $ui.busyBar.Visibility = $(if($b){ 'Visible' } else { 'Collapsed' })
    if($b){ Start-Marquee } else { Stop-Marquee }
    if($b){ $ui.busyTxt.Text = T 'Çalışıyor... pencereyi kapatma.' 'Working... do not close the window.' }
  }
  function Set-Dot($dot, $txt, [string]$tn, [string]$label){ $dot.Fill = $tone[$tn].fg; if($txt){ $txt.Text = $label } }
  function Get-Ago([string]$iso){
    try { $d = (Get-Date) - [datetime]$iso } catch { return '' }
    if($d.TotalMinutes -lt 1){ return (T 'az önce' 'just now') }
    if($d.TotalMinutes -lt 60){ return ("{0} {1}" -f [int]$d.TotalMinutes, (T 'dk önce' 'min ago')) }
    if($d.TotalHours -lt 48){ return ("{0} {1}" -f [int]$d.TotalHours, (T 'sa önce' 'h ago')) }
    return ("{0} {1}" -f [int]$d.TotalDays, (T 'gün önce' 'days ago'))
  }
  function New-Row([string]$left, [string]$pill, [string]$tn, [string]$right){
    $bd = New-Object Windows.Controls.Border; $bd.BorderBrush = (B '#1E2230'); $bd.BorderThickness = '0,0,0,1'; $bd.Padding = '14,11'
    $g = New-Object Windows.Controls.Grid
    foreach($w in @('*', 'Auto', '96')){ $cd = New-Object Windows.Controls.ColumnDefinition; $cd.Width = $w; $g.ColumnDefinitions.Add($cd) }
    $a = New-Object Windows.Controls.TextBlock; $a.Text = $left; $a.FontSize = 13; $a.VerticalAlignment = 'Center'; $a.TextTrimming = 'CharacterEllipsis'
    $g.Children.Add($a) | Out-Null
    if($pill){
      $pb = New-Object Windows.Controls.Border; $pb.CornerRadius = 8; $pb.Padding = '10,3'; $pb.Background = $tone[$tn].bg; [Windows.Controls.Grid]::SetColumn($pb, 1)
      $pt = New-Object Windows.Controls.TextBlock; $pt.Text = $pill; $pt.FontSize = 12; $pt.FontWeight = 'SemiBold'; $pt.Foreground = $tone[$tn].fg; $pb.Child = $pt
      $g.Children.Add($pb) | Out-Null
    }
    $c = New-Object Windows.Controls.TextBlock; $c.Text = $right; $c.FontSize = 12.5; $c.Foreground = $col.dim; $c.HorizontalAlignment = 'Right'; $c.VerticalAlignment = 'Center'; [Windows.Controls.Grid]::SetColumn($c, 2)
    $g.Children.Add($c) | Out-Null
    $bd.Child = $g; return $bd
  }
  function New-EventRow([string]$time, [string]$msg){
    $bd = New-Object Windows.Controls.Border; $bd.BorderBrush = (B '#1E2230'); $bd.BorderThickness = '0,0,0,1'; $bd.Padding = '14,10'
    $sp = New-Object Windows.Controls.DockPanel
    $a = New-Object Windows.Controls.TextBlock; $a.Text = $time; $a.Width = 128; $a.FontSize = 12.5; $a.Foreground = $col.dim; [Windows.Controls.DockPanel]::SetDock($a, 'Left')
    $b2 = New-Object Windows.Controls.TextBlock; $b2.Text = $msg; $b2.FontSize = 13; $b2.TextWrapping = 'Wrap'
    if(-not $time){ $a.Visibility = 'Collapsed'; $b2.Foreground = $col.dim }
    $sp.Children.Add($a) | Out-Null; $sp.Children.Add($b2) | Out-Null; $bd.Child = $sp; return $bd
  }
  function Set-Sites-Empty {
    $ui.sitesList.Children.Clear()
    $ui.sitesList.Children.Add((New-Row (T 'Henüz kontrol edilmedi. "Şimdi kontrol et"e bas.' 'Not checked yet. Press "Check now".') '' 'off' '')) | Out-Null
  }

  # ---------------- arayüz tercihleri (pencere konumu, görülmüş nöbetçi olayları) ----------------
  $GuiFile = Join-Path $Root 'gui.json'
  $script:GuiPrefs = Read-Json $GuiFile; if(-not $script:GuiPrefs){ $script:GuiPrefs = [pscustomobject]@{} }
  function Save-GuiPrefs { try { Write-Json $script:GuiPrefs $GuiFile } catch {} }

  # ---------------- kurulum / test ilerleme adımları ----------------
  $StepNames = @((T 'Ön kontrol' 'Preflight'), (T 'Bağımlılıklar' 'Dependencies'), (T 'DNS zehirlenme kontrolü' 'DNS poisoning check'), (T 'Engel taraması' 'Block discovery'),
                 (T 'Strateji seçimi' 'Strategy selection'), (T 'Şifreli DNS' 'Encrypted DNS'), (T 'DPI servisi' 'DPI service'), (T 'Nöbetçi' 'Watchdog'))
  $script:Steps = @(); $script:StepMode = ''; $script:LastExit = 0
  function Set-StepState([int]$i, [string]$s){
    if($i -lt 0 -or $i -ge $script:Steps.Count){ return }
    $st = $script:Steps[$i]; $st.S = $s; $g = $st.G; $l = $st.L
    $g.BeginAnimation([Windows.UIElement]::OpacityProperty, $null); $g.Opacity = 1
    switch($s){
      'pending' { $g.Text = [string][char]0x25CB; $g.Foreground = $col.dim; $l.Foreground = $col.dim }
      'active'  { $g.Text = [string][char]0x25C9; $g.Foreground = (B '#A9A2FF'); $l.Foreground = (B '#F2F3F8')
                  $a = New-Object Windows.Media.Animation.DoubleAnimation(1.0, 0.25, (New-Object Windows.Duration([TimeSpan]::FromMilliseconds(650))))
                  $a.AutoReverse = $true; $a.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever; $g.BeginAnimation([Windows.UIElement]::OpacityProperty, $a) }
      'done'    { $g.Text = [string][char]0x2713; $g.Foreground = $tone.ok.fg; $l.Foreground = $col.i }
      'fail'    { $g.Text = [string][char]0x2715; $g.Foreground = $tone.err.fg; $l.Foreground = $tone.err.fg }
      'skip'    { $g.Text = [string][char]0x2013; $g.Foreground = $col.dim; $l.Foreground = $col.dim }
    }
  }
  function Init-Steps([string]$mode){
    $ui.stepList.Children.Clear(); $script:Steps = @(); $script:StepMode = $mode
    $n = $(if($mode -eq 'probe'){ 5 } else { 8 })
    $rows = [int][Math]::Ceiling($n / 2); $cells = @{}
    for($i = 0; $i -lt $n; $i++){
      $sp = New-Object Windows.Controls.StackPanel; $sp.Orientation = 'Horizontal'; $sp.Margin = '0,5'
      $g = New-Object Windows.Controls.TextBlock; $g.FontFamily = 'Segoe UI Symbol'; $g.Width = 24; $g.FontSize = 14; $g.VerticalAlignment = 'Center'
      $l = New-Object Windows.Controls.TextBlock; $l.Text = $StepNames[$i]; $l.FontSize = 13; $l.VerticalAlignment = 'Center'
      $sp.Children.Add($g) | Out-Null; $sp.Children.Add($l) | Out-Null; $cells[$i] = $sp
      $script:Steps += , @{ G = $g; L = $l; S = 'pending' }
      Set-StepState $i 'pending'
    }
    # iki sütun, yukarıdan aşağı okunsun: sol 0..(r-1), sağ r..(n-1). UniformGrid satır satır dolar -> sırayı karıştırarak ekle
    for($r = 0; $r -lt $rows; $r++){
      $ui.stepList.Children.Add($cells[$r]) | Out-Null
      if($cells.ContainsKey($r + $rows)){ $ui.stepList.Children.Add($cells[$r + $rows]) | Out-Null } else { $ui.stepList.Children.Add((New-Object Windows.Controls.Border)) | Out-Null }
    }
    $ui.stepTitle.Text = $(if($mode -eq 'probe'){ T 'Test sürüyor…' 'Testing…' } else { T 'Kurulum sürüyor…' 'Installing…' })
    $ui.stepTitle.Foreground = (B '#F2F3F8'); $ui.stepDetail.Text = ''; $ui.stepClose.Visibility = 'Collapsed'
    $ui.cards.Visibility = 'Collapsed'; $ui.stepCard.Visibility = 'Visible'
    $script:StepIdx = -1; $script:SubFrac = 0.0; $script:Pct = 0; $ui.stepProg.BeginAnimation([Windows.Controls.Primitives.RangeBase]::ValueProperty, $null); $ui.stepProg.Value = 0; $ui.stepPct.Text = (T '%0' '0%')
  }
  function Step-To([int]$n){
    for($i = 0; $i -lt [Math]::Min($n, $script:Steps.Count); $i++){
      if($script:Steps[$i].S -eq 'active'){ Set-StepState $i 'done' } elseif($script:Steps[$i].S -eq 'pending'){ Set-StepState $i 'skip' }
    }
    Set-StepState $n 'active'
    $script:StepIdx = $n; $script:SubFrac = 0.0; Update-Progress
  }
  function Finish-Steps([bool]$ok, [int]$code){
    for($i = 0; $i -lt $script:Steps.Count; $i++){
      $s = $script:Steps[$i].S
      if($s -eq 'active'){ Set-StepState $i $(if($ok){ 'done' } else { 'fail' }) } elseif($s -eq 'pending' -and $ok){ Set-StepState $i 'skip' }
    }
    if($ok){ Update-Progress 100 }
    if($ok){ $ui.stepTitle.Text = $(if($script:StepMode -eq 'probe'){ T 'Test tamamlandı — hiçbir şey kurulmadı.' 'Test completed — nothing was installed.' } else { T 'Kurulum tamamlandı.' 'Installation completed.' }); $ui.stepTitle.Foreground = $tone.ok.fg }
    elseif($code -eq 30){ $ui.stepTitle.Text = T 'Onay bekleniyor (çakışan araçlar).' 'Waiting for confirmation (conflicting tools).'; $ui.stepTitle.Foreground = $tone.warn.fg }
    elseif($code -eq 60){ $ui.stepTitle.Text = T 'İnternet koptu — iptal edildi, değişiklikler geri alındı.' 'Internet dropped — cancelled, changes reverted.'; $ui.stepTitle.Foreground = $tone.warn.fg }
    else { $ui.stepTitle.Text = T 'İşlem hatayla bitti — ayrıntılar kayıtlarda.' 'Task failed — see the logs.'; $ui.stepTitle.Foreground = $tone.err.fg }
    $ui.stepClose.Visibility = 'Visible'; $script:StepMode = ''
  }
  function Hide-Steps { $ui.stepCard.Visibility = 'Collapsed'; $ui.cards.Visibility = 'Visible' }

  # ---------------- "sen yokken" nöbetçi bildirimi ----------------
  function Mark-WatchSeen {
    $w = Read-Json $WatchFile; $ev = @(PGet $w 'events' @())
    $last = $(if($ev.Count){ "" + $ev[$ev.Count - 1].t } else { (Get-Date).ToString('s') })
    PSet $script:GuiPrefs 'lastSeenEvent' $last; Save-GuiPrefs
    $ui.banWatch.Visibility = 'Collapsed'
  }
  function Update-WatchBanner($w){
    $ev = @(PGet $w 'events' @())
    $seen = PGet $script:GuiPrefs 'lastSeenEvent'
    if(-not $seen){ Mark-WatchSeen; return }   # ilk açılış: eski olayları "yeni" diye gösterme
    $new = @($ev | Where-Object { ("" + $_.t) -gt $seen })
    if(-not $new.Count){ $ui.banWatch.Visibility = 'Collapsed'; return }
    $lastEv = $new[$new.Count - 1]
    $ui.banWatchTxt.Text = $(if($new.Count -gt 1){ (T 'Nöbetçi {0} şey yaptı. Son: {1} ({2})' 'The watchdog did {0} things. Latest: {1} ({2})') -f $new.Count, $lastEv.m, (Get-Ago $lastEv.t) } else { (T 'Nöbetçi: {0} ({1})' 'Watchdog: {0} ({1})') -f $lastEv.m, (Get-Ago $lastEv.t) })
    $ui.banWatch.Visibility = 'Visible'
  }

  # ---------------- arka plan çakışma taraması (arayüzü dondurmadan) ----------------
  $Sync.BgBusy = $false; $Sync.BgDone = $false; $Sync.BgItems = [Collections.ArrayList]::Synchronized((New-Object Collections.ArrayList))
  function Start-BgScan {
    if($Sync.BgBusy -or $env:ZA_GUI_SMOKE -eq '1'){ return }
    $Sync.BgBusy = $true; $Sync.BgItems.Clear(); Ensure-EngineFile
    $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'MTA'; $rs.Open()
    $rs.SessionStateProxy.SetVariable('Sync', $Sync); $rs.SessionStateProxy.SetVariable('Eng', $script:Engine)
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript({
      try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell.exe'; $psi.Arguments = '-NoProfile -ExecutionPolicy RemoteSigned -File "' + $Eng + '" conflicts'
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardOutput = $true; $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
        $psi.EnvironmentVariables['ZA_GUI_CHILD'] = '1'
        $p = [System.Diagnostics.Process]::Start($psi)
        while(-not $p.StandardOutput.EndOfStream){ $l = $p.StandardOutput.ReadLine(); if($l -like '@@CONF|*' -or $l -like '@@PROXY|*'){ [void]$Sync.BgItems.Add($l) } }
        $p.WaitForExit()
      } catch {} finally { $Sync.BgDone = $true }
    })
    $Sync.BgPS = $ps; $Sync.BgRS = $rs; $Sync.BgAsync = $ps.BeginInvoke()
  }
  function Update-ConfBanner {
    $conf = @($Sync.BgItems | Where-Object { $_ -like '@@CONF|*' } | ForEach-Object { $_.Substring(7) })
    $prox = @($Sync.BgItems | Where-Object { $_ -like '@@PROXY|*' } | ForEach-Object { $_.Substring(8) })
    if(-not $conf.Count -and -not $prox.Count){ $ui.banConf.Visibility = 'Collapsed'; return }
    $msg = @()
    if($conf.Count){ $msg += ((T 'Çakışan DPI aracı çalışıyor: {0}. zapret ile aynı anda çalışırsa ikisi de bozulur.' 'Conflicting DPI tool running: {0}. Running together with zapret breaks both.') -f ($conf -join ', ')) }
    if($prox.Count){ $msg += ((T '{0} — Test/Kur sırasında kapat, yoksa ölçümler yanılır.' '{0} — turn it off during Test/Install, or measurements are misleading.') -f ($prox -join '; ')) }
    $ui.banConfTxt.Text = $msg -join "`n"
    $ui.banConfGo.Visibility = $(if($conf.Count){ 'Visible' } else { 'Collapsed' })
    $ui.banConf.Visibility = 'Visible'
  }
  # ---------------- ilerleme yüzdesi (adım ağırlıkları + strateji taramasının ara ilerlemesi) ----------------
  $script:StepIdx = -1; $script:SubFrac = 0.0; $script:Pct = 0; $script:LastBusyLine = ''
  function Get-Weights { if($script:StepMode -eq 'probe'){ return @(5, 10, 5, 25, 55) } else { return @(4, 10, 4, 14, 40, 12, 12, 4) } }
  function Update-Progress([double]$force = -1){
    $w = Get-Weights; $sum = ($w | Measure-Object -Sum).Sum
    if($force -ge 0){ $p = $force } else {
      $done = 0; for($i = 0; $i -lt [Math]::Min($script:StepIdx, $w.Count); $i++){ $done += $w[$i] }
      if($script:StepIdx -ge 0 -and $script:StepIdx -lt $w.Count){ $done += $w[$script:StepIdx] * [Math]::Min(0.95, $script:SubFrac) }
      $p = [Math]::Min(99, [Math]::Round(100.0 * $done / $sum))
    }
    if($p -lt $script:Pct -and $force -lt 0){ return }   # geri gitmesin
    $script:Pct = $p
    $a = New-Object Windows.Media.Animation.DoubleAnimation($ui.stepProg.Value, [double]$p, (New-Object Windows.Duration([TimeSpan]::FromMilliseconds(450))))
    $a.EasingFunction = New-Object Windows.Media.Animation.CubicEase
    $ui.stepProg.BeginAnimation([Windows.Controls.Primitives.RangeBase]::ValueProperty, $a)
    $ui.stepPct.Text = (T "%$p" "$p%")
    if($Sync.Busy){ $ui.busyTxt.Text = (T "%$p · " "$p% · ") + $script:LastBusyLine }
  }
  # ---------------- kayan "çalışıyor" animasyonu (alt şerit) ----------------
  $marqT = New-Object Windows.Media.TranslateTransform; $ui.marqBar.RenderTransform = $marqT
  function Start-Marquee { $a = New-Object Windows.Media.Animation.DoubleAnimation(-42.0, 110.0, (New-Object Windows.Duration([TimeSpan]::FromMilliseconds(1100)))); $a.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever; $marqT.BeginAnimation([Windows.Media.TranslateTransform]::XProperty, $a) }
  function Stop-Marquee { $marqT.BeginAnimation([Windows.Media.TranslateTransform]::XProperty, $null) }
  # ---------------- bildirim baloncuğu ----------------
  function Show-Toast([string]$text, [string]$tn = 'ok'){
    $ui.toastTxt.Text = $text
    $ui.toastIcon.Text = $(switch($tn){ 'ok' { [string][char]0xE73E } 'err' { [string][char]0xE711 } default { [string][char]0xE946 } })
    $ui.toastIcon.Foreground = $(if($tone[$tn]){ $tone[$tn].fg } else { $tone.off.fg })
    $ui.toast.Visibility = 'Visible'
    $k = New-Object Windows.Media.Animation.DoubleAnimationUsingKeyFrames
    $k.KeyFrames.Add((New-Object Windows.Media.Animation.LinearDoubleKeyFrame(0.0, [Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::Zero)))) | Out-Null
    $k.KeyFrames.Add((New-Object Windows.Media.Animation.LinearDoubleKeyFrame(1.0, [Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(180))))) | Out-Null
    $k.KeyFrames.Add((New-Object Windows.Media.Animation.LinearDoubleKeyFrame(1.0, [Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(3200))))) | Out-Null
    $k.KeyFrames.Add((New-Object Windows.Media.Animation.LinearDoubleKeyFrame(0.0, [Windows.Media.Animation.KeyTime]::FromTimeSpan([TimeSpan]::FromMilliseconds(3600))))) | Out-Null
    $ui.toast.BeginAnimation([Windows.UIElement]::OpacityProperty, $k)
  }
  $ToastMsg = @{
    'zapret-on' = (T 'DPI atlatma açıldı' 'DPI bypass enabled'); 'zapret-off' = (T 'DPI atlatma kapatıldı' 'DPI bypass disabled')
    'doh-on' = (T 'Şifreli DNS açıldı' 'Encrypted DNS enabled'); 'doh-off' = (T 'Şifreli DNS kapatıldı' 'Encrypted DNS disabled')
    'watch-on' = (T 'Nöbetçi açıldı' 'Watchdog enabled'); 'watch-off' = (T 'Nöbetçi kapatıldı' 'Watchdog disabled')
    'game-on' = (T 'Oyun filtresi açıldı' 'Game filter enabled'); 'game-off' = (T 'Oyun filtresi kapatıldı' 'Game filter disabled')
    'set' = (T 'Ayar kaydedildi' 'Setting saved'); 'install' = (T 'Kurulum tamamlandı' 'Installation completed'); 'probe' = (T 'Test tamamlandı' 'Test completed')
    'uninstall' = (T 'Kaldırıldı — sistem eski haline döndü' 'Uninstalled — system restored'); 'watch-now' = (T 'Nöbetçi çalıştı' 'Watchdog ran')
    'report' = (T 'Teşhis raporu hazır' 'Diagnostic report ready'); 'pack' = (T 'Çevrimdışı paket hazır' 'Offline package ready'); 'recover' = (T 'Sistem toparlandı' 'System recovered')
    'sites' = (T 'Siteler kontrol edildi' 'Sites checked'); 'status' = (T 'Durum güncellendi' 'Status refreshed')
  }

  function Refresh-Status {
    $st = Read-Json $StateFile; $cfg = Load-Config
    $installed = [bool](PGet $st 'installedAt')
    $z = Get-Service zapret -ErrorAction SilentlyContinue
    $zOn = [bool]($z -and $z.Status -eq 'Running' -and (Get-Process winws -ErrorAction SilentlyContinue))
    $eng = PGet $st 'dohEngine'
    $dOn = $false
    if($eng -eq 'native'){ $dOn = (On $cfg.doh) } else { $dOn = ((Get-Service dnscrypt-proxy -ErrorAction SilentlyContinue).Status -eq 'Running') }
    $t = Get-WatchTask; $wOn = [bool]($t -and $t.State -ne 'Disabled')
    $w = Read-Json $WatchFile
    $wFail = ((PGet $w 'result') -eq 'fail')

    # --- büyük durum kartı ---
    if(-not $installed -and -not $zOn -and -not $dOn){ $tn = 'off'; $ic = [char]0xE946; $ti = T 'Kurulu değil' 'Not installed'; $su = T 'Kur / Onar ile başla: engelleri ölçer ve en iyi ayarı kurar.' 'Start with Install / Repair: it measures the blocks and installs the best config.' }
    elseif($zOn -and $dOn){ $tn = 'ok'; $ic = [char]0xE73E; $ti = T 'Korunuyorsun' 'You are protected'; $su = T 'Engelli siteler açılıyor · DNS şifreli' 'Blocked sites open · DNS is encrypted'; if($wFail){ $tn = 'warn'; $su += (T ' · nöbetçi bir sorun bildirdi' ' · the watchdog reported a problem') } }
    elseif($zOn -or $dOn){ $tn = 'warn'; $ic = [char]0xE7BA; $ti = T 'Kısmen korunuyorsun' 'Partially protected'; $su = $(if(-not $zOn){ T 'DPI atlatma kapalı; engelli siteler açılmayabilir.' 'DPI bypass is off; blocked sites may not open.' } else { T 'Şifreli DNS kapalı; DNS zehirlenmesine açıksın.' 'Encrypted DNS is off; DNS poisoning is possible.' }) }
    else { $tn = 'err'; $ic = [char]0xE711; $ti = T 'Koruma kapalı' 'Protection off'; $su = T 'Bileşenleri aşağıdan aç ya da Kur / Onar''a bas.' 'Turn components on below or press Install / Repair.' }
    $ui.heroBg.Background = $tone[$tn].bg; $ui.heroIcon.Foreground = $tone[$tn].fg; $ui.heroIcon.Text = "$ic"
    $ui.heroTitle.Text = $ti; $ui.heroSub.Text = $su
    $ui.sideDot.Fill = $tone[$tn].fg; $ui.sideTxt.Text = $ti

    # --- bileşen kartları ---
    $strat = ("" + (PGet $st 'strategy' '')) -replace '\.bat$', ''
    Set-Dot $ui.dotZap $ui.txtZap $(if($zOn){ 'ok' } else { 'off' }) $(if($zOn){ T 'Çalışıyor' 'Running' } elseif($z){ T 'Kapalı' 'Off' } else { T 'Kurulu değil' 'Not installed' })
    $ui.detZap.Text = $(if($strat){ $strat + $(if(On $cfg.game){ ' · ' + (T 'oyun filtresi' 'game filter') } else { '' }) } else { '—' })
    Set-Dot $ui.dotDoh $ui.txtDoh $(if($dOn){ 'ok' } else { 'off' }) $(if($dOn){ T 'Şifreli' 'Encrypted' } else { T 'Kapalı' 'Off' })
    $ui.detDoh.Text = $(if($eng -eq 'native'){ T 'Windows yerleşik DoH' 'Windows built-in DoH' } elseif($dOn){ 'dnscrypt-proxy · 1.1.1.1 / 8.8.8.8' } else { '—' })
    $wTone = $(if(-not $wOn){ 'off' } elseif($wFail){ 'warn' } else { 'ok' })
    Set-Dot $ui.dotWat $ui.txtWat $wTone $(if(-not $wOn){ T 'Kapalı' 'Off' } elseif($wFail){ T 'Uyarı' 'Warning' } else { T 'Açık' 'On' })
    $ui.detWat.Text = $(if($w -and (PGet $w 'lastRun')){ (T 'son kontrol ' 'last check ') + (Get-Ago (PGet $w 'lastRun')) } elseif($wOn){ T 'henüz kontrol yapmadı' 'no check yet' } else { '—' })

    # --- nöbetçi sayfası ---
    Set-Dot $ui.wDot $null $wTone ''
    $ui.wTitle.Text = $(if(-not $wOn){ T 'Nöbetçi kapalı' 'Watchdog off' } elseif($w -and (PGet $w 'lastRun')){ (T 'Açık · son kontrol ' 'On · last check ') + (Get-Ago (PGet $w 'lastRun')) } else { T 'Açık · henüz kontrol yapmadı' 'On · no check yet' })
    $ui.wSub.Text = $(if($w -and (PGet $w 'message')){ PGet $w 'message' } else { '' })
    $ui.watchEvents.Children.Clear()
    $evs = @(PGet $w 'events' @())
    if($evs.Count){ for($i = $evs.Count - 1; $i -ge 0; $i--){ $tt = ''; try { $tt = ([datetime]$evs[$i].t).ToString('dd.MM HH:mm') } catch {}; $ui.watchEvents.Children.Add((New-EventRow $tt ("" + $evs[$i].m))) | Out-Null } }
    else { $ui.watchEvents.Children.Add((New-EventRow '' (T 'Henüz olay yok. Nöbetçi bir şeyi düzelttiğinde burada görünür.' 'No events yet. They appear here when the watchdog fixes something.'))) | Out-Null }

    Update-WatchBanner $w
    # --- siteler alt başlığı ---
    $learned = 0; try { $learned = @(Get-LearnedDomains).Count } catch {}
    $ui.sitesSub.Text = (T 'Siteler tarayıcının yaptığı gibi (sistem DNS''i + TLS) denenir. Kurulumda engelli bulunan siteler ve Discord/YouTube listelenir. Otomatik öğrenilen site sayısı: ' 'Sites are tested like a browser does (system DNS + TLS). Sites found blocked at install plus Discord/YouTube are listed. Auto-learned sites: ') + $learned

    # --- anahtarlar / ayarlar (programatik değişiklik olay tetiklemesin) ---
    $script:syncing = $true
    $ui.swZap.IsChecked = $zOn; $ui.swDoh.IsChecked = $dOn; $ui.swWat.IsChecked = $wOn; $ui.swWat2.IsChecked = $wOn; $ui.swGame.IsChecked = (On $cfg.game)
    switch("" + $cfg.dohengine){ 'native' { $ui.engNat.IsChecked = $true } 'dnscrypt' { $ui.engDns.IsChecked = $true } default { $ui.engAuto.IsChecked = $true } }
    switch("" + $cfg.lang){ 'tr' { $ui.langTr.IsChecked = $true } 'en' { $ui.langEn.IsChecked = $true } default { $ui.langAuto.IsChecked = $true } }
    $script:syncing = $false
  }

  function Ensure-EngineFile {
    if(-not (Test-Path -LiteralPath $script:Engine)){
      $d = Split-Path -Parent $script:Engine
      if(-not (Test-Path -LiteralPath $d)){ New-Item -ItemType Directory -Path $d -Force | Out-Null }
      [IO.File]::WriteAllBytes($script:Engine, $script:SelfBytes)
    }
  }
  function Run-Engine([string]$mode, [string]$opt = '', [switch]$ShowLog){
    if($Sync.Busy){ return }
    $script:hadErr = $false; $script:Marks = @(); $script:LastMode = $mode; $script:LastExit = 0
    $para.Inlines.Clear(); Add-Line (">> $mode $opt") 'head'; Set-Busy $true
    if($ShowLog){ Show-Page 'Log' }
    if($mode -in @('install', 'probe')){ Show-Page 'Home'; Init-Steps $mode }
    if($mode -eq 'sites'){ $ui.sitesList.Children.Clear() }
    Ensure-EngineFile
    $rs = [runspacefactory]::CreateRunspace(); $rs.ApartmentState = 'MTA'; $rs.Open()
    $rs.SessionStateProxy.SetVariable('Sync', $Sync)
    $rs.SessionStateProxy.SetVariable('Eng', $script:Engine)
    $rs.SessionStateProxy.SetVariable('EArgs', ("$mode $opt").Trim())
    $ps = [powershell]::Create(); $ps.Runspace = $rs
    [void]$ps.AddScript({
      try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell.exe'
        $psi.Arguments = '-NoProfile -ExecutionPolicy RemoteSigned -File "' + $Eng + '" ' + $EArgs
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
        $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
        $psi.EnvironmentVariables['ZA_GUI_CHILD'] = '1'
        $p = [System.Diagnostics.Process]::Start($psi); $Sync.Proc = $p
        $errTask = $p.StandardError.ReadToEndAsync()
        while(-not $p.StandardOutput.EndOfStream){ $Sync.Q.Enqueue($p.StandardOutput.ReadLine()) }
        $p.WaitForExit()
        $e = $errTask.Result
        if($e -and $e.Trim()){ foreach($l in ($e -split "`r?`n")){ if($l.Trim()){ $Sync.Q.Enqueue('warn|' + $l) } } }
        $Sync.Q.Enqueue('@@EXIT|' + $p.ExitCode)
      } catch { $Sync.Q.Enqueue('err|' + $_.Exception.Message) }
      finally { $Sync.Q.Enqueue('___DONE___') }
    })
    $Sync.PS = $ps; $Sync.RS = $rs; $Sync.Async = $ps.BeginInvoke()
  }
  function Handle-Marks {
    foreach($m in $script:Marks){
      $p = $m -split '\|', 3
      switch($p[0]){
        'ASK' {
          $r = [Windows.MessageBox]::Show(((T "Çakışan DPI araçları bulundu:`n`n{0}`n`nAynı sürücü için yarışırlar. Durdurulup devre dışı bırakılsınlar mı? (SİLİNMEZLER)" "Conflicting DPI tools found:`n`n{0}`n`nThey compete for the same driver. Stop and disable them? (They are NOT deleted)") -f $p[2]), 'zapret-auto', 'YesNo', 'Warning')
          if($r -eq 'Yes'){ Run-Engine $script:LastMode 'yes'; return }
        }
        'AV' {
          $msg = (T "{0}, winws dosyalarını yanlış pozitif olarak engelledi.`n`nwinws açık kaynak bir araç; ağ paketlerini değiştirdiği için 'HackTool' sanılıyor. Bu araç güvenlik ayarlarına KENDİSİ dokunmaz; istisnayı senin eklemen gerekiyor:`n`n  Klasör: {1}`n`n'Evet': klasör yolu panoya kopyalanır{2}.`nİstisnayı ekledikten sonra Kur / Onar'a tekrar bas." "{0} falsely flagged the winws files.`n`nwinws is open source; it is mistaken for a 'HackTool' because it modifies network packets. This tool never changes security settings by itself; you need to add the exclusion:`n`n  Folder: {1}`n`n'Yes': the folder path is copied to the clipboard{2}.`nAfter adding the exclusion, press Install / Repair again.") -f $p[1], $p[2], $(if($p[1] -match 'Defender'){ T ' ve Windows Güvenliği açılır' ' and Windows Security opens' } else { '' })
          if([Windows.MessageBox]::Show($msg, (T 'Antivirüs engeli' 'Antivirus block'), 'YesNo', 'Warning') -eq 'Yes'){
            try { [Windows.Clipboard]::SetText($p[2]) } catch {}
            if($p[1] -match 'Defender'){ try { Start-Process 'windowsdefender://threatsettings' } catch {} }
          }
        }
        'SAC' { [void][Windows.MessageBox]::Show((T "Akıllı Uygulama Denetimi (Smart App Control) açık.`n`nİmzasız winws.exe'yi engeller ve istisna kabul etmez. DPI atlatma için onu kapatman gerekir:`nWindows Güvenliği > Uygulama ve tarayıcı denetimi > Akıllı Uygulama Denetimi > Kapalı.`n`nNot: Windows, kapattıktan sonra geri açmaya izin vermeyebilir (sıfırlama gerekir)." "Smart App Control is on.`n`nIt blocks the unsigned winws.exe and accepts no exclusions. To use DPI bypass you must turn it off:`nWindows Security > App & browser control > Smart App Control > Off.`n`nNote: Windows may not let you turn it back on without a reset."), 'Smart App Control', 'OK', 'Information') }
        'OPEN' { if(Test-Path -LiteralPath $p[1]){ Start-Process notepad.exe -ArgumentList ('"' + $p[1] + '"') } }
        'SELECT' { if(Test-Path -LiteralPath $p[1]){ Start-Process explorer.exe -ArgumentList ('/select,"' + $p[1] + '"') } }
      }
    }
  }
  $timer = New-Object System.Windows.Threading.DispatcherTimer
  $timer.Interval = [TimeSpan]::FromMilliseconds(120)
  $timer.Add_Tick({
    while($Sync.Q.Count -gt 0){
      $item = [string]$Sync.Q.Dequeue()
      if($item -eq '___DONE___'){
        try { if($Sync.PS){ $Sync.PS.EndInvoke($Sync.Async); $Sync.PS.Dispose() } } catch {}
        try { if($Sync.RS){ $Sync.RS.Dispose() } } catch {}
        try { if($Sync.Proc){ $Sync.Proc.Dispose() } } catch {}
        $Sync.PS = $null; $Sync.RS = $null; $Sync.Proc = $null
        Set-Busy $false; Refresh-Status
        if($script:StepMode){ Finish-Steps (-not $script:hadErr -and $script:LastExit -eq 0) $script:LastExit }
        if($script:LastMode -eq 'watch-now'){ Mark-WatchSeen }
        if($script:LastExit -eq 30){ }
        elseif($script:hadErr -or $script:LastExit -ne 0){ Show-Toast (T 'İşlem hatayla bitti — ayrıntılar Kayıtlar''da' 'Task failed — see Logs') 'err' }
        elseif($ToastMsg[$script:LastMode]){ Show-Toast $ToastMsg[$script:LastMode] 'ok' }
        Start-BgScan
        if($script:LastMode -eq 'sites'){ $script:SitesChecked = $true }
        if($script:hadErr){ $ui.hint.Foreground = $tone.err.fg; $ui.hint.Text = (T 'Son işlem hatayla bitti: ' 'Last task finished with errors: ') + $script:LastMode + (T ' — ayrıntılar Kayıtlar sayfasında.' ' — see the Logs page.') }
        else { $ui.hint.Foreground = $col.dim; $ui.hint.Text = (T 'Son işlem tamamlandı: ' 'Last task completed: ') + $script:LastMode }
        Handle-Marks
      } elseif($item.StartsWith('@@STEP|')){
        try { Step-To ([int]$item.Substring(7)) } catch {}
      } elseif($item.StartsWith('@@SUB|')){
        try { $sp = $item.Split('|'); if([int]$sp[2] -gt 0){ $script:SubFrac = [double]$sp[1] / [double]$sp[2]; Update-Progress } } catch {}
      } elseif($item.StartsWith('@@EXIT|')){
        try { $script:LastExit = [int]$item.Substring(7) } catch {}
      } elseif($item.StartsWith('@@SITE|')){
        $p = $item.Split('|'); $ms = [int]$p[2]
        $ui.sitesList.Children.Add((New-Row $p[1] $(if($ms -ge 0){ T 'Açık' 'Open' } else { T 'Engelli' 'Blocked' }) $(if($ms -ge 0){ 'ok' } else { 'err' }) $(if($ms -ge 0){ "$ms ms" } else { '—' }))) | Out-Null
      } elseif($item.StartsWith('@@')){
        if(-not $item.StartsWith('@@EXIT|') -and -not $item.StartsWith('@@LEARNED|')){ $script:Marks += $item.Substring(2) }
      } else {
        $ix = $item.IndexOf('|'); $lvl = 'i'; $txt = $item
        if($ix -gt 0 -and $ix -le 4){ $lvl = $item.Substring(0, $ix); $txt = $item.Substring($ix + 1) }
        Add-Line $txt $lvl
      }
    }
    # arka plan çakışma taraması bitti mi?
    if($Sync.BgDone){ $Sync.BgDone = $false; try { $Sync.BgPS.EndInvoke($Sync.BgAsync); $Sync.BgPS.Dispose(); $Sync.BgRS.Dispose() } catch {}; $Sync.BgBusy = $false; Update-ConfBanner }
    # ikinci kez açılmaya çalışıldıysa bu pencereyi öne getir
    if($script:ShowEv -and $script:ShowEv.WaitOne(0)){ if($win.WindowState -eq 'Minimized'){ $win.WindowState = 'Normal' }; [void]$win.Activate(); $win.Topmost = $true; $win.Topmost = $false }
    # boştayken ~60 sn'de bir durumu tazele (nöbetçi arka planda bir şey değiştirmiş olabilir)
    $script:Tick++
    if($script:Tick -ge 500){ $script:Tick = 0; if(-not $Sync.Busy){ Refresh-Status } }
  })
  $timer.Start()

  # ---------------- olaylar ----------------
  $ui.navHome.Add_Checked({ if(-not $script:syncing){ Show-Page 'Home' } })
  $ui.navSites.Add_Checked({ if(-not $script:syncing){ Show-Page 'Sites'; if(-not $script:SitesChecked -and -not $Sync.Busy){ Run-Engine 'sites' } } })
  $ui.navWatch.Add_Checked({ if(-not $script:syncing){ Show-Page 'Watch'; Mark-WatchSeen } })
  $ui.banWatchX.Add_Click({ Mark-WatchSeen })
  $ui.banWatchGo.Add_Click({ Mark-WatchSeen; Show-Page 'Watch' })
  $ui.banConfGo.Add_Click({ if([Windows.MessageBox]::Show((T 'Kur / Onar çakışan araçları durdurup devre dışı bırakmayı önerecek (silinmezler; Kaldır geri getirir). Devam?' 'Install / Repair will offer to stop and disable the conflicting tools (not deleted; Uninstall restores them). Continue?'), (T 'Kur / Onar' 'Install / Repair'), 'YesNo', 'Question') -eq 'Yes'){ Run-Engine 'install' } })
  $ui.stepClose.Add_Click({ Hide-Steps })
  $ui.stepLog.Add_Click({ Show-Page 'Log' })
  $ui.capMin.Add_Click({ $win.WindowState = 'Minimized' })
  $ui.capMax.Add_Click({ $win.WindowState = $(if($win.WindowState -eq 'Maximized'){ 'Normal' } else { 'Maximized' }) })
  $ui.capClose.Add_Click({ $win.Close() })
  # başlıksız pencere büyütülünce ekran kenarından taşar -> kenar boşluğu ver; simgeyi "geri yükle"ye çevir
  $win.Add_StateChanged({
    if($win.WindowState -eq 'Maximized'){ $ui.rootBorder.Margin = '7'; $ui.rootBorder.BorderThickness = '0'; $ui.capMax.Content = [string][char]0xE923 }
    else { $ui.rootBorder.Margin = '0'; $ui.rootBorder.BorderThickness = '1'; $ui.capMax.Content = [string][char]0xE922 }
  })
  $ui.navSettings.Add_Checked({ if(-not $script:syncing){ Show-Page 'Settings' } })
  $ui.navLog.Add_Checked({ if(-not $script:syncing){ Show-Page 'Log' } })
  $ui.btnShowLog.Add_Click({ Show-Page 'Log' })

  $ui.btnInstall.Add_Click({ if([Windows.MessageBox]::Show((T 'Ölçüm yapıp en iyi ayarı servis olarak kuracak/onaracak (seçili bileşenlerle). Devam?' 'Measures and installs/repairs the best config as services (selected components). Continue?'), (T 'Kur / Onar' 'Install / Repair'), 'YesNo', 'Question') -eq 'Yes'){ Run-Engine 'install' } })
  $ui.btnProbe.Add_Click({ Run-Engine 'probe' })
  $ui.btnSites.Add_Click({ Run-Engine 'sites' })
  $ui.btnWatchNow.Add_Click({ Run-Engine 'watch-now' })
  $ui.btnStatus.Add_Click({ Run-Engine 'status' -ShowLog })
  $ui.btnReport.Add_Click({ Run-Engine 'report' })
  $ui.btnPack.Add_Click({ Run-Engine 'pack' })
  $openLog = { if(Test-Path -LiteralPath $LogFile){ Start-Process notepad.exe -ArgumentList ('"' + $LogFile + '"') } else { [void][Windows.MessageBox]::Show((T 'Henüz kayıt yok.' 'No log yet.'), 'zapret-auto', 'OK', 'Information') } }
  $ui.btnLogFile.Add_Click($openLog); $ui.btnLogFile2.Add_Click($openLog)
  $ui.btnRemove.Add_Click({ if([Windows.MessageBox]::Show((T "Her şeyi kaldırıp sistemi kurulum öncesi haline döndürecek:`nservisler, nöbetçi görevi, DNS ayarları, dosyalar. Emin misin?" "This removes everything and restores the pre-install state:`nservices, watchdog task, DNS settings, files. Are you sure?"), (T 'Kaldır' 'Uninstall'), 'YesNo', 'Warning') -eq 'Yes'){ Run-Engine 'uninstall' -ShowLog } })
  $toggle = {
    param($sw, $onMode, $offMode)
    if($script:syncing){ return }
    if($Sync.Busy){ $script:syncing = $true; $sw.IsChecked = -not $sw.IsChecked; $script:syncing = $false; return }
    Run-Engine $(if($sw.IsChecked){ $onMode } else { $offMode })
  }
  $ui.swZap.Add_Click({ & $toggle $ui.swZap 'zapret-on' 'zapret-off' })
  $ui.swDoh.Add_Click({ & $toggle $ui.swDoh 'doh-on' 'doh-off' })
  $ui.swWat.Add_Click({ & $toggle $ui.swWat 'watch-on' 'watch-off' })
  $ui.swWat2.Add_Click({ & $toggle $ui.swWat2 'watch-on' 'watch-off' })
  $ui.swGame.Add_Click({ & $toggle $ui.swGame 'game-on' 'game-off' })
  $setPref = { param($k, $v) if($script:syncing -or $Sync.Busy){ return }; Run-Engine 'set' "$k $v" }
  $ui.engAuto.Add_Checked({ & $setPref 'dohengine' 'auto' })
  $ui.engDns.Add_Checked({ & $setPref 'dohengine' 'dnscrypt' })
  $ui.engNat.Add_Checked({ & $setPref 'dohengine' 'native' })
  $ui.langAuto.Add_Checked({ & $setPref 'lang' 'auto' })
  $ui.langTr.Add_Checked({ & $setPref 'lang' 'tr' })
  $ui.langEn.Add_Checked({ & $setPref 'lang' 'en' })
  $win.Add_Closing({
    if($Sync.Busy){
      if([Windows.MessageBox]::Show((T 'İşlem devam ediyor. Yine de kapat?' 'A task is running. Close anyway?'), 'zapret-auto', 'YesNo', 'Warning') -ne 'Yes'){ $_.Cancel = $true; return }
      try { if($Sync.Proc){ $Sync.Proc.Kill() } } catch {}
      # yarıda kesilen işlemi arka planda toparla (geçici winws, durmuş servis, ölü DNS)
      try { Start-Process powershell.exe -ArgumentList ('-NoProfile -ExecutionPolicy RemoteSigned -WindowStyle Hidden -File "' + $script:Engine + '" recover') -WindowStyle Hidden } catch {}
    }
    # pencere konumunu/boyutunu hatırla
    try {
      $rb = $(if($win.WindowState -eq 'Normal'){ New-Object Windows.Rect($win.Left, $win.Top, $win.Width, $win.Height) } else { $win.RestoreBounds })
      PSet $script:GuiPrefs 'l' $rb.Left; PSet $script:GuiPrefs 't' $rb.Top; PSet $script:GuiPrefs 'w' $rb.Width; PSet $script:GuiPrefs 'h' $rb.Height
      PSet $script:GuiPrefs 'max' ($win.WindowState -eq 'Maximized'); Save-GuiPrefs
    } catch {}
    $timer.Stop()
  })

  Add-Line (T 'zapret-auto hazır. İşlemlerin ayrıntılı çıktısı burada görünür.' 'zapret-auto ready. Detailed task output appears here.') 'head'
  Add-Line (T 'Bu dosya okunabilir düz metindir; ne yaptığını Not Defteri ile görebilirsin.' 'This file is plain readable text; open it in Notepad to see what it does.') 'dim'
  Set-Sites-Empty
  Set-Busy $false
  Refresh-Status
  $ui.hint.Foreground = $col.dim
  $ui.hint.Text = T 'Test Et hiçbir şey kurmadan ölçer. Kur / Onar ölçüp en iyi ayarı kalıcı olarak kurar.' 'Test measures without installing anything. Install / Repair measures and installs the best config permanently.'
  if($env:ZA_GUI_SMOKE -eq '1'){ return }
  Start-BgScan
  # son pencere konumunu geri yükle (ekran dışında kalmıyorsa)
  try {
    $gp = $script:GuiPrefs
    if((PGet $gp 'w') -and (PGet $gp 'h')){
      $L = [double](PGet $gp 'l'); $Tp = [double](PGet $gp 't'); $W = [double](PGet $gp 'w'); $H = [double](PGet $gp 'h')
      $vl = [Windows.SystemParameters]::VirtualScreenLeft; $vt = [Windows.SystemParameters]::VirtualScreenTop
      $vw = [Windows.SystemParameters]::VirtualScreenWidth; $vh = [Windows.SystemParameters]::VirtualScreenHeight
      if($L -ge ($vl - 20) -and $Tp -ge ($vt - 20) -and ($L + 160) -le ($vl + $vw) -and ($Tp + 80) -le ($vt + $vh)){
        $win.WindowStartupLocation = 'Manual'; $win.Left = $L; $win.Top = $Tp
        $win.Width = [Math]::Max($W, $win.MinWidth); $win.Height = [Math]::Max($H, $win.MinHeight)
      }
      if((PGet $gp 'max') -eq $true){ $win.WindowState = 'Maximized' }
    }
  } catch {}
  # Yarıda kalmış bir işlem varsa (ve o işlem artık yaşamıyorsa) açılışta otomatik toparla
  $win.Add_ContentRendered({
    $op = Read-Json $OpFile
    $opPid = [int](PGet $op 'pid' 0)
    if($op -and ($opPid -le 0 -or -not (Get-Process -Id $opPid -ErrorAction SilentlyContinue))){ Run-Engine 'recover' -ShowLog }
  })
  [void]$win.ShowDialog()
}

# Siteler sayfası için: her siteyi tarayıcının yaptığı gibi (sistem DNS'i + TLS) dene, sonucu arayüze işaretle.
function Do-Sites {
  $hosts = @(@('discord.com', 'www.youtube.com') + @(PGet (Get-State) 'targets' @())) | Select-Object -Unique
  Clear-DnsClientCache -ErrorAction SilentlyContinue
  foreach($h in $hosts){
    $ms = Test-HS $h $null 8 -SystemDns
    Mark ("SITE|{0}|{1}" -f $h, $ms)
    Log ("  {0,-24} {1}" -f $h, $(if($ms -ge 0){ (T 'AÇIK' 'OPEN') + " ($ms ms)" } else { T 'ENGELLİ' 'BLOCKED' })) $(if($ms -ge 0){ 'ok' } else { 'err' })
  }
  Mark ("LEARNED|{0}" -f @(Get-LearnedDomains).Count)
}
# Arayüzün arka plan taraması: çakışan araçlar + proxy uyarıları (salt okunur, kilit almaz)
function Do-ConflictScan {
  foreach($x in @(Find-Conflicts -Quick)){ Mark ("CONF|" + $x.Name) }
  foreach($p in @(Find-ProxyIssues)){ Mark ("PROXY|" + $p) }
}
function Do-Recover {
  Need-Admin
  if(-not (Get-Lock 600)){ Fail 31 '' }
  if(Test-Path -LiteralPath $OpFile){ Recover-System | Out-Null }
  else { Log (T 'Yarıda kalmış işlem yok; kurtarılacak bir şey yok.' 'No interrupted task; nothing to recover.') 'ok' }
}
# Nöbetçiyi gerçek koşullarda (SYSTEM hesabıyla, zamanlanmış görev olarak) hemen çalıştır ve çıktısını canlı göster.
function Do-WatchNow {
  Need-Admin
  if(-not (Get-WatchTask)){ Fail 70 (T 'Nöbetçi görevi yok (kapalı ya da kurulmamış). Önce Kur/Onar çalıştır ya da nöbetçiyi aç.' 'No watchdog task (off or not installed). Run Install/Repair or enable the watchdog first.') }
  Head (T '[nöbetçi şimdi çalıştırılıyor -- SYSTEM hesabıyla, gerçek koşullarda]' '[running the watchdog now -- as SYSTEM, under real conditions]')
  $before = PGet (Read-Json $WatchFile) 'lastRun'
  $pos = $(if(Test-Path -LiteralPath $LogFile){ (Get-Item -LiteralPath $LogFile).Length } else { 0 })
  try { Start-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction Stop } catch { Fail 71 ((T 'Görev başlatılamadı: {0}' 'Could not start the task: {0}') -f $_.Exception.Message) }
  $sw = [Diagnostics.Stopwatch]::StartNew(); $done = $false
  while(-not $done -and $sw.Elapsed.TotalMinutes -lt 20){
    Start-Sleep -Seconds 2
    # yeni log satırlarını (nöbetçinin yazdıklarını) canlı aktar
    try {
      $fs = [IO.File]::Open($LogFile, 'Open', 'Read', 'ReadWrite')
      if($fs.Length -gt $pos){ [void]$fs.Seek($pos, 'Begin'); $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::UTF8); $chunk = $sr.ReadToEnd(); $pos = $fs.Length; $sr.Close() } else { $chunk = ''; $fs.Close() }
      foreach($ln in ($chunk -split "`r?`n")){ if($ln -match '^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d (\w+)\s(.*)$'){ Emit ($Matches[2].TrimStart()) $Matches[1].Trim() } }
    } catch {}
    $state = "" + (Get-WatchTask).State
    $w = Read-Json $WatchFile
    if($state -ne 'Running' -and (PGet $w 'lastRun') -and (PGet $w 'lastRun') -ne $before){ $done = $true }
    elseif($state -ne 'Running' -and $sw.Elapsed.TotalSeconds -gt 20 -and (PGet $w 'lastRun') -eq $before){ $done = $true }
  }
  $w = Read-Json $WatchFile
  if((PGet $w 'lastRun') -and (PGet $w 'lastRun') -ne $before){
    $r = PGet $w 'result'
    Log ((T '  Nöbetçi SYSTEM olarak çalıştı. Sonuç: {0} -- {1}' '  Watchdog ran as SYSTEM. Result: {0} -- {1}') -f $r, (PGet $w 'message')) $(if($r -eq 'fail'){ 'err' } else { 'ok' })
  } else {
    $info = Get-ScheduledTaskInfo -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
    Log ((T '  [!] Nöbetçi sonuç yazmadı (görev sonucu: 0x{0:X}). Başka bir işlem sürüyor olabilir; biraz sonra tekrar dene.' '  [!] Watchdog wrote no result (task result: 0x{0:X}). Another task may be running; retry shortly.') -f [int64]$info.LastTaskResult) 'warn'
  }
}

# =============================================================================
#  ANA AKIŞ
# =============================================================================
if($Mode -notin @('help', 'config', 'sites', 'conflicts')){ try { Repair-Acl } catch {} }   # v2.0.0'ın bozduğu dosya izinlerini de onarır
if($Mode -eq 'gui'){ . Start-Gui; exit 0 }
Init-Log
if($Mode -notin @('watch', 'conflicts')){ Log ''; Log ("==================== zapret-auto $ZA_VERSION  ({0}: {1}) ====================" -f (T 'mod' 'mode'), $Mode) 'head' }
try {
  switch($Mode){
    'install'    { Do-Install $false }
    'probe'      { Do-Install $true }
    'status'     { if(Test-Path -LiteralPath $ZapDir){ try { Ensure-Zapret } catch {} }; Show-Config; Show-Status }
    'uninstall'  { Do-Uninstall }
    'config'     { Show-Config }
    'set'        {
      $k = "$($Rest | Select-Object -First 1)".ToLower(); $v = "$($Rest | Select-Object -Skip 1 -First 1)"
      if(-not $CfgDefaults.Contains($k) -or -not $v){ Fail 2 ((T 'Kullanım: set <{0}> <değer>' 'Usage: set <{0}> <value>') -f ($CfgDefaults.Keys -join '|')) }
      Set-Pref $k $v; Show-Config
    }
    'zapret-on'  { Do-ZapretOn;  Show-Status -NoTests }
    'zapret-off' { Do-ZapretOff; Show-Status -NoTests }
    'doh-on'     { Do-DohOn;     Show-Status -NoTests }
    'doh-off'    { Do-DohOff;    Show-Status -NoTests }
    'watch-on'   { Do-WatchOn }
    'watch-off'  { Do-WatchOff }
    'game-on'    { Do-Game $true;  Show-Status -NoTests }
    'game-off'   { Do-Game $false; Show-Status -NoTests }
    'watch'      { Do-Watch }
    'watch-now'  { Do-WatchNow }
    'sites'      { Do-Sites }
    'conflicts'  { Do-ConflictScan }
    'recover'    { Do-Recover; Show-Status -NoTests }
    'report'     { Do-Report }
    'pack'       { Do-Pack }
    default      { Show-Help; if($Mode -notin @('help', '?', 'h')){ $script:ExitCode = 2 } }
  }
} catch {
  if("$_" -ne 'ZA_FATAL'){
    Log ((T 'BEKLENMEYEN HATA: {0}' 'UNEXPECTED ERROR: {0}') -f $_.Exception.Message) 'err'
    Log ("  @ " + $_.InvocationInfo.PositionMessage.Split("`n")[0]) 'dim'
    $script:ExitCode = 99
    # beklenmeyen hata işlem ortasında olduysa: sistemi yarım bırakma, hemen toparla
    if($script:OpActive -and $Mode -ne 'uninstall'){ try { Recover-System | Out-Null } catch {} }
  }
} finally {
  if($script:OpActive){ End-Op }
}
if($PauseEnd){ try { Read-Host (T "`nKapatmak için Enter'a bas" "`nPress Enter to close") | Out-Null } catch {} }
exit $script:ExitCode
