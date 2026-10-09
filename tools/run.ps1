# run.ps1 —— 带超时与完整输出捕获的 Godot 无头运行器
#
# 用法：
#   pwsh -File tools\run.ps1 -Script tools/selftest.gd -TimeoutSec 300
#   pwsh -File tools\run.ps1 -Script tools/selftest.gd -Args '-- --quick'
param(
  [string]$Script = "tools/selftest.gd",
  [int]$TimeoutSec = 300,
  [string]$Extra = "",
  # 默认 = 本脚本所在目录的上一级（即仓库根），可用环境变量 GODOT_PROJECT_DIR 覆盖
  [string]$Project = $(if ($env:GODOT_PROJECT_DIR) { $env:GODOT_PROJECT_DIR }
                       else { (Resolve-Path (Join-Path $PSScriptRoot '..')).Path }),
  # 默认 = 环境变量 GODOT 指定的 Godot 控制台可执行文件，否则用 PATH 里的同名程序
  [string]$Godot = $(if ($env:GODOT) { $env:GODOT } else { 'Godot_v4.7.2-stable_win64_console.exe' }),
  [switch]$Quiet
)
$out = Join-Path $env:TEMP "dshrl_out.txt"
$err = Join-Path $env:TEMP "dshrl_err.txt"
Remove-Item $out, $err -ErrorAction SilentlyContinue
$argList = @("--headless", "--path", "`"$Project`"", "--script", $Script)
if ($Extra -ne "") { $argList += $Extra.Split(" ") }
$p = Start-Process -FilePath $Godot -ArgumentList $argList `
      -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -NoNewWindow
$deadline = (Get-Date).AddSeconds($TimeoutSec)
while (-not $p.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 250 }
$killed = $false
if (-not $p.HasExited) { $killed = $true; Stop-Process -Id $p.Id -Force; Start-Sleep -Milliseconds 400 }
$code = if ($killed) { "TIMEOUT" } else { $p.ExitCode }
Write-Output "=== godot exit: $code (killed=$killed) ==="
$o = Get-Content $out -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
$e = Get-Content $err -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
if ($o) {
  if ($Quiet) { Write-Output $o } else { Write-Output "--- stdout ---"; Write-Output $o }
}
if ($e) { Write-Output "--- stderr ---"; Write-Output $e }
