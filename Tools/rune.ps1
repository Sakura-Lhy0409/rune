# Rune 构建与测试驱动（Windows）
#
# ⚠️ 为什么不用 `swift build` / `swift test`：
#   本机的 SwiftPM **无法执行构建任务**：它能加载 manifest、能生成构建图，但在实际调用
#   swiftc 编译目标时静默退出（exit 1 且不打印任何错误）。已排除的原因：
#     · 不是中文路径（纯 ASCII 路径同样失败）
#     · 不是 Swift 工具链坏了（同一条 swiftc 命令手动执行完全成功，产出 .swiftmodule/.o）
#     · 不是命名管道/匿名管道被禁（管道创建正常）
#     · 不是 batch mode（-disable-batch-mode / -whole-module-optimization 同样失败）
#     · 不是索引库（--disable-index-store 同样失败）
#     · --use-integrated-swift-driver 能走到"Compiling …"但仍在同一步失败
#   ⇒ 结论：SwiftPM 在本环境的**子进程执行层**有问题，与我们的代码无关。
#   ⇒ 对策：自己用 swiftc 直接驱动构建与测试。RuneKernel 零依赖，因此这件事很简单。
#   ⇒ 在 macOS 上开发时，可以改回标准 `swift build` / `swift test`（届时优先用 Xcode）。
#
# 用法：
#   pwsh -File Tools\rune.ps1 build RuneKernel         # 编译为静态库
#   pwsh -File Tools\rune.ps1 test  RuneKernel         # 编译并运行 swift-testing 测试
#   pwsh -File Tools\rune.ps1 test  RuneKernel -f "路径"  # 只跑匹配的测试
#   pwsh -File Tools\rune.ps1 clean RuneKernel
#   pwsh -File Tools\rune.ps1 info                     # 打印工具链事实

param(
    [Parameter(Position = 0)]
    [ValidateSet('build', 'test', 'clean', 'info')]
    [string]$Command = 'build',

    [Parameter(Position = 1)]
    [string]$Package = 'RuneKernel',

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ExtraArgs
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- 仓库根路径（ASCII 安全）
#
# ⚠️ 本仓库的真实路径 `D:\项目\ios平台agent` **含中文**，而 Windows 上 swiftc / clang
#    会按错误代码页解码路径，导致 "error opening input file 'D:\??Ŀ\ios??agent\…'"。
#    （这也是 SwiftPM 在本机静默失败的原因之一。）
#    ⇒ 对策：建一个纯 ASCII 的目录 junction 指向仓库根，所有构建都走它。
#    创建命令：mklink /J "%USERPROFILE%\rune-ws" "D:\项目\ios平台agent"
#    junction 是透明的，产物物理上仍然落在真实仓库目录里。
$realRoot  = Split-Path -Parent $PSScriptRoot
$asciiLink = Join-Path $env:USERPROFILE 'rune-ws'

$repoRoot = $realRoot
if ($realRoot -match '[^\x00-\x7F]') {
    if (Test-Path (Join-Path $asciiLink 'PROJECT_STATE.md')) {
        $repoRoot = $asciiLink
    } else {
        Write-Warning "仓库路径含非 ASCII 字符，且未找到 ASCII junction（$asciiLink）。"
        Write-Warning "构建很可能因路径编码问题失败。请先执行："
        Write-Warning "  cmd /c mklink /J `"$asciiLink`" `"$realRoot`""
    }
}

$pkgPath   = Join-Path $repoRoot "Packages\$Package"
$srcPath   = Join-Path $pkgPath 'Sources'
$testPath  = Join-Path $pkgPath 'Tests'
$outRoot   = Join-Path $pkgPath '.build\manual'
$modDir    = Join-Path $outRoot 'Modules'

$vcvars = "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"

# ---------------------------------------------------------------- 工具链定位

function Get-PlatformRoot {
    $platforms = "C:\Users\$env:USERNAME\AppData\Local\Programs\Swift\Platforms"
    $dir = Get-ChildItem $platforms -Directory -ErrorAction SilentlyContinue |
           Sort-Object Name -Descending | Select-Object -First 1
    if (-not $dir) { throw "找不到 Swift Platforms 目录：$platforms" }
    return Join-Path $dir.FullName 'Windows.platform\Developer'
}

function Get-SdkPath {
    $root = Get-PlatformRoot
    $sdk = Join-Path $root 'SDKs\Windows.sdk'
    if (-not (Test-Path $sdk)) { throw "找不到 Windows SDK：$sdk" }
    return $sdk
}

function Get-TestingDir {
    $root = Get-PlatformRoot
    $libRoot = Join-Path $root 'Library'
    $t = Get-ChildItem $libRoot -Directory -Filter 'Testing-*' -ErrorAction SilentlyContinue |
         Sort-Object Name -Descending | Select-Object -First 1
    if (-not $t) { throw "找不到 Testing 库目录：$libRoot\Testing-*" }
    return Join-Path $t.FullName 'usr\lib\swift\windows'
}

# ---------------------------------------------------------------- 正式逻辑

if ($Command -eq 'info') {
    Write-Host "仓库根目录 : $repoRoot"
    Write-Host "包目录     : $pkgPath"
    Write-Host "平台根     : $(Get-PlatformRoot)"
    Write-Host "SDK        : $(Get-SdkPath)"
    Write-Host "Testing    : $(Get-TestingDir)"
    Write-Host "vcvars     : $vcvars ($(Test-Path $vcvars))"
    cmd /c "swiftc -version 2>&1" | Select-Object -First 2 | ForEach-Object { Write-Host "swiftc     : $_" }
    exit 0
}

if (-not (Test-Path $pkgPath))  { throw "找不到包目录：$pkgPath" }
if (-not (Test-Path $srcPath))  { throw "找不到源码目录：$srcPath" }
if (-not (Test-Path $vcvars))   { throw "找不到 vcvars64.bat：$vcvars`n请安装 Visual Studio 2022 Build Tools（C++ 生成工具 + Windows SDK）。" }

if ($Command -eq 'clean') {
    Remove-Item -Recurse -Force (Join-Path $pkgPath '.build') -ErrorAction SilentlyContinue
    Write-Host "✅ 已清理 $Package" -ForegroundColor Green
    exit 0
}

New-Item -ItemType Directory -Force -Path $modDir | Out-Null

$sdk        = Get-SdkPath
$testingDir = Get-TestingDir

# 收集源文件（递归，保持稳定顺序以免构建结果抖动）
$sources = Get-ChildItem -Recurse -Path $srcPath -Filter *.swift |
           Sort-Object FullName | Select-Object -ExpandProperty FullName
if ($sources.Count -eq 0) { throw "$srcPath 下没有 .swift 文件" }

$commonFlags = @(
    '-swift-version', '6',
    '-target', 'x86_64-unknown-windows-msvc',
    '-sdk', "`"$sdk`"",
    '-Onone', '-g',
    '-Xcc', '-D_MT', '-Xcc', '-D_DLL', '-Xcc', '-Xclang', '-Xcc', '--dependent-lib=msvcrt',
    '-Xcc', '-gdwarf',
    '-libc', 'MD',
    '-use-ld=lld',
    '-module-cache-path', "`"$(Join-Path $outRoot 'ModuleCache')`""
)

# 把参数写进一个 .bat，由 cmd 在 vcvars 环境下执行（pwsh 无法 source .bat）
# ---------- 源码体检 ----------
#
# ⚠️ 为什么在编译**之前**跑：这个检查抓的是"中文文案里手打了 ASCII 双引号"。
# 那种错的编译器报错是 `expected ',' separator` 与 `cannot find '...' in scope` ——
# 和真实原因毫不相干，每次都要往回数引号才能看出来（本项目为此浪费过五次编译往返）。
# python 版本几十毫秒就能给出**指到行**的提示，比等 swiftc 报一句谜语划算得多。
function Invoke-Lint {
    $lint = Join-Path $PSScriptRoot 'lint_quotes.py'
    if (-not (Test-Path -LiteralPath $lint)) { return 0 }
    $python = Get-Command python -ErrorAction SilentlyContinue
    if (-not $python) {
        Write-Host "（跳过引号体检：没找到 python）" -ForegroundColor DarkGray
        return 0
    }
    # ⚠️ `| Out-Host` 不能省：不写的话 python 的每一行输出都会变成
    #    **函数的返回值的一部分**，于是 `(Invoke-Lint) -ne 0` 拿一个数组去比 0 —— 永远为真、
    #    每次都判失败。这是 PowerShell 里最经典的坑之一（函数的"输出"就是它的返回值）。
    & $python.Source $lint | Out-Host
    return $LASTEXITCODE
}

function Invoke-Build([string]$batBody, [string]$label) {
    $bat = Join-Path $outRoot "rune-$label.bat"
    # chcp 65001 + 用 UTF-8 写 bat：即使路径里混入非 ASCII（例如通过 junction 之外的路径调用），
    # 也不会被按 GBK 解码而损坏。
    $content = "@echo off`r`nchcp 65001 >nul`r`ncall `"$vcvars`" >nul 2>&1`r`n" + $batBody + "`r`nexit /b %errorlevel%`r`n"
    Set-Content -LiteralPath $bat -Encoding utf8NoBOM -Value $content
    cmd /c "`"$bat`""
    return $LASTEXITCODE
}

switch ($Command) {

    'build' {
        if ((Invoke-Lint) -ne 0) {
            Write-Host "❌ 源码体检未通过，已停止编译" -ForegroundColor Red
            exit 1
        }
        $libOut = Join-Path $outRoot "$Package.lib"
        $modOut = Join-Path $modDir "$Package.swiftmodule"
        $swiftFiles = ($sources | ForEach-Object { "`"$_`"" }) -join ' '
        $line = "swiftc -parse-as-library -emit-module -emit-library -static " +
                "-module-name $Package -package-name $($Package.ToLower()) " +
                "-emit-module-path `"$modOut`" -o `"$libOut`" " +
                "-enable-testing " +
                ($commonFlags -join ' ') + " " + $swiftFiles
        Write-Host "▶ 编译 $Package（$($sources.Count) 个源文件）" -ForegroundColor Cyan
        $code = Invoke-Build $line 'build'
        if ($code -eq 0) {
            Write-Host "✅ 产物：$libOut" -ForegroundColor Green
            Write-Host "   module：$modOut" -ForegroundColor DarkGray
        } else {
            Write-Host "❌ 编译失败（exit $code）" -ForegroundColor Red
        }
        exit $code
    }

    'test' {
        if ((Invoke-Lint) -ne 0) {
            Write-Host "❌ 源码体检未通过，已停止测试编译" -ForegroundColor Red
            exit 1
        }
        if (-not (Test-Path $testPath)) { throw "找不到测试目录：$testPath" }
        $testSources = Get-ChildItem -Recurse -Path $testPath -Filter *.swift |
                       Sort-Object FullName | Select-Object -ExpandProperty FullName
        if ($testSources.Count -eq 0) { throw "$testPath 下没有 .swift 文件" }

        # 第一阶段：编译被测模块（带 -enable-testing 以便 @testable import）
        $modOut = Join-Path $modDir "$Package.swiftmodule"
        $libOut = Join-Path $outRoot "$Package.lib"
        $swiftFiles = ($sources | ForEach-Object { "`"$_`"" }) -join ' '
        $stage1 = "swiftc -parse-as-library -emit-module -emit-library -static " +
                  "-module-name $Package -package-name $($Package.ToLower()) " +
                  "-emit-module-path `"$modOut`" -o `"$libOut`" -enable-testing " +
                  ($commonFlags -join ' ') + " " + $swiftFiles

        Write-Host "▶ [1/2] 编译被测模块 $Package" -ForegroundColor Cyan
        $code = Invoke-Build $stage1 'test-stage1'
        if ($code -ne 0) { Write-Host "❌ 模块编译失败（exit $code）" -ForegroundColor Red; exit $code }

        # 第二阶段：编译测试 + 生成的入口，链接 Testing 与模块
        $runnerPath = Join-Path $outRoot 'TestRunner.swift'
        @'
// 由 Tools/rune.ps1 自动生成：swift-testing 的入口点
// 注意：Testing 里 __swiftPMEntryPoint 有两个重载（-> CInt 与 -> Never），
// 必须用显式类型标注消除歧义。
import Testing
import Foundation

@main
struct RuneTestRunner {
    static func main() async {
        let code: CInt = await Testing.__swiftPMEntryPoint()
        exit(code)
    }
}
'@ | Set-Content -LiteralPath $runnerPath -Encoding UTF8

        $exeOut = Join-Path $outRoot "$Package-tests.exe"
        $testFiles = ($testSources | ForEach-Object { "`"$_`"" }) -join ' '
        $stage2 = "swiftc -parse-as-library " +
                  "-module-name ${Package}Tests " +
                  "-I `"$modDir`" -L `"$outRoot`" -l$Package " +
                  "-I `"$testingDir`" -L `"$testingDir\x86_64`" -lTesting " +
                  "-o `"$exeOut`" " +
                  ($commonFlags -join ' ') + " " +
                  "`"$runnerPath`" " + $testFiles

        Write-Host "▶ [2/2] 编译 $($testSources.Count) 个测试文件并链接 Testing" -ForegroundColor Cyan
        $code = Invoke-Build $stage2 'test-stage2'
        if ($code -ne 0) { Write-Host "❌ 测试编译失败（exit $code）" -ForegroundColor Red; exit $code }

        # 第三阶段：运行
        Write-Host ""
        Write-Host "▶ 运行测试" -ForegroundColor Cyan
        $testArgs = if ($ExtraArgs) { ($ExtraArgs -join ' ') } else { '' }

        # ⚠️ 运行期必须能找到这些 DLL，否则进程以 0xC0000135 (STATUS_DLL_NOT_FOUND) 静默退出：
        #    · Swift 运行时：swiftCore.dll / Foundation.dll / dispatch.dll …
        #    · Testing 运行时：Testing.dll —— 位于 Testing-*/usr/**bin64**，
        #      注意**不是** x86_64 那个目录（那里只有 .lib 导入库）
        $swiftRoot   = "C:\Users\$env:USERNAME\AppData\Local\Programs\Swift"
        $runtimeBin  = Join-Path $swiftRoot 'Runtimes\6.3.3\usr\bin'
        $toolchainBin = Join-Path $swiftRoot 'Toolchains\6.3.3+Asserts\usr\bin'
        # testingDir = …\Testing-6.3.3\usr\lib\swift\windows → 上溯 3 层得到 …\usr
        $testingUsr  = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $testingDir))
        $testingDll  = Join-Path $testingUsr 'bin64'

        $env:PATH = @(
            $runtimeBin,
            $toolchainBin,
            $testingDll,
            (Join-Path $testingDir 'x86_64'),
            $env:PATH
        ) -join ';'

        & $exeOut $testArgs.Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries)
        $code = $LASTEXITCODE
        if ($code -eq 0) { Write-Host "`n✅ 测试全部通过" -ForegroundColor Green }
        else { Write-Host "`n❌ 测试失败（exit $code）" -ForegroundColor Red }
        exit $code
    }
}

