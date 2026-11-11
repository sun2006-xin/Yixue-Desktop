param(
    [string]$SuitePath = (Join-Path $PSScriptRoot '..\benchmarks\translation\en-zh-baseline-v1.json'),
    [Parameter(Mandatory = $true)]
    [string]$WorkerPath,
    [Parameter(Mandatory = $true)]
    [string]$EnglishToChineseModel,
    [Parameter(Mandatory = $true)]
    [string]$ChineseToEnglishModel,
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\benchmarks\results'),
    [int]$TimeoutMilliseconds = 60000
)

$ErrorActionPreference = 'Stop'
$utf8NoBom = [Text.UTF8Encoding]::new($false)

function Resolve-RequiredPath {
    param([string]$Path, [string]$Label, [switch]$Leaf)

    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    if ($Leaf -and -not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "$Label is not a file: $resolved"
    }
    if (-not $Leaf -and -not (Test-Path -LiteralPath $resolved -PathType Container)) {
        throw "$Label is not a directory: $resolved"
    }
    return $resolved
}

function Get-DirectoryBytes {
    param([string]$Path)

    return (Get-ChildItem -LiteralPath $Path -Recurse -File |
        Measure-Object -Property Length -Sum).Sum
}

function Start-BenchmarkWorker {
    param([string]$Executable, [string]$ModelPath, [string]$Direction)

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Executable
    $startInfo.WorkingDirectory = Split-Path -Parent $Executable
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardInputEncoding = $utf8NoBom
    $startInfo.StandardOutputEncoding = $utf8NoBom
    $startInfo.StandardErrorEncoding = $utf8NoBom

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) { throw "Unable to start $Direction worker" }

    $opened = Invoke-WorkerRequest -Process $process -Request @{
        schema_version = 1
        id = "open-$Direction"
        command = 'open'
        model_path = $ModelPath
    } -Timeout $TimeoutMilliseconds
    if ($opened.Response.ok -ne $true -or $opened.Response.ready -ne $true) {
        $process.Kill($true)
        throw "$Direction model failed to open"
    }
    return [pscustomobject]@{
        Process = $process
        LoadMilliseconds = $opened.ElapsedMilliseconds
        LoadPeakWorkingSetBytes = $opened.PeakWorkingSetBytes
    }
}

function Invoke-WorkerRequest {
    param(
        [Diagnostics.Process]$Process,
        [hashtable]$Request,
        [int]$Timeout
    )

    $line = $Request | ConvertTo-Json -Compress -Depth 5
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $Process.StandardInput.WriteLine($line)
    $Process.StandardInput.Flush()
    $readTask = $Process.StandardOutput.ReadLineAsync()
    $peak = 0L
    while (-not $readTask.Wait(20)) {
        if ($stopwatch.ElapsedMilliseconds -gt $Timeout) {
            throw "Worker request timed out: $($Request.id)"
        }
        if (-not $Process.HasExited) {
            $Process.Refresh()
            $peak = [Math]::Max($peak, $Process.WorkingSet64)
        }
    }
    $stopwatch.Stop()
    if ([string]::IsNullOrWhiteSpace($readTask.Result)) {
        throw "Worker returned an empty response: $($Request.id)"
    }
    if (-not $Process.HasExited) {
        $Process.Refresh()
        $peak = [Math]::Max($peak, $Process.WorkingSet64)
    }
    return [pscustomobject]@{
        Response = $readTask.Result | ConvertFrom-Json
        ElapsedMilliseconds = $stopwatch.ElapsedMilliseconds
        PeakWorkingSetBytes = $peak
    }
}

function Stop-BenchmarkWorker {
    param([Diagnostics.Process]$Process)

    if (-not $Process.HasExited) {
        $Process.Kill($true)
        $Process.WaitForExit(3000) | Out-Null
    }
    $Process.Dispose()
}

function Get-Percentile {
    param([long[]]$Values, [double]$Percentile)

    $sorted = @($Values | Sort-Object)
    if ($sorted.Count -eq 0) { return 0 }
    $index = [Math]::Ceiling(($Percentile / 100) * $sorted.Count) - 1
    return $sorted[[Math]::Max(0, [Math]::Min($index, $sorted.Count - 1))]
}

$suiteFile = Resolve-RequiredPath $SuitePath 'Benchmark suite' -Leaf
$workerFile = Resolve-RequiredPath $WorkerPath 'Translation worker' -Leaf
$enZhModel = Resolve-RequiredPath $EnglishToChineseModel 'English-to-Chinese model'
$zhEnModel = Resolve-RequiredPath $ChineseToEnglishModel 'Chinese-to-English model'
$suite = Get-Content -LiteralPath $suiteFile -Raw -Encoding utf8 | ConvertFrom-Json
$supportedSchema = $suite.schema_version -in @(1, 2)
if (-not $supportedSchema -or @($suite.cases).Count -eq 0) {
    throw 'Benchmark suite schema is unsupported or empty'
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$outputRoot = (Resolve-Path -LiteralPath $OutputDirectory).Path
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$results = [Collections.Generic.List[object]]::new()
$workers = @{}

try {
    $workers['english-chinese'] = Start-BenchmarkWorker $workerFile $enZhModel 'english-chinese'
    $workers['chinese-english'] = Start-BenchmarkWorker $workerFile $zhEnModel 'chinese-english'

    foreach ($case in $suite.cases) {
        $direction = "$($case.source_language)-$($case.target_language)"
        $worker = $workers[$direction]
        if ($null -eq $worker) { throw "No model configured for $direction" }
        $measurement = Invoke-WorkerRequest -Process $worker.Process -Request @{
            schema_version = 1
            id = [string]$case.id
            command = 'translate'
            text = [string]$case.source
        } -Timeout $TimeoutMilliseconds
        if ($measurement.Response.ok -ne $true -or
            [string]::IsNullOrWhiteSpace([string]$measurement.Response.translation)) {
            throw "Translation failed: $($case.id)"
        }
        $translation = [string]$measurement.Response.translation
        $requiredTokens = @($case.preserve | Where-Object {
            $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_)
        })
        $preserved = @($requiredTokens | ForEach-Object {
            [pscustomobject]@{ token = [string]$_; present = $translation.Contains([string]$_) }
        })
        $results.Add([pscustomobject]@{
            id = [string]$case.id
            category = [string]$case.category
            source_language = [string]$case.source_language
            target_language = [string]$case.target_language
            source = [string]$case.source
            references = @($case.references)
            translation = $translation
            elapsed_ms = $measurement.ElapsedMilliseconds
            peak_working_set_mib = [Math]::Round($measurement.PeakWorkingSetBytes / 1MB, 2)
            preserve = $preserved
            preserve_pass = ($preserved.Count -eq 0 -or @($preserved | Where-Object { -not $_.present }).Count -eq 0)
            manual_accuracy_1_to_5 = $null
            manual_naturalness_1_to_5 = $null
            manual_terminology_1_to_5 = $null
            manual_notes = ''
        })
    }
} finally {
    foreach ($worker in $workers.Values) {
        if ($null -ne $worker.Process) { Stop-BenchmarkWorker $worker.Process }
    }
}

$elapsed = @($results | ForEach-Object { [long]$_.elapsed_ms })
$preserveCases = @($results | Where-Object { $_.preserve.Count -gt 0 })
$report = [ordered]@{
    schema_version = 1
    suite_id = [string]$suite.id
    generated_at = (Get-Date).ToString('o')
    engine = 'CTranslate2 4.8.2 / INT8'
    models = [ordered]@{
        english_to_chinese = [ordered]@{
            package = Split-Path -Leaf $enZhModel
            size_mib = [Math]::Round((Get-DirectoryBytes $enZhModel) / 1MB, 2)
            load_ms = $workers['english-chinese'].LoadMilliseconds
            load_peak_working_set_mib = [Math]::Round($workers['english-chinese'].LoadPeakWorkingSetBytes / 1MB, 2)
        }
        chinese_to_english = [ordered]@{
            package = Split-Path -Leaf $zhEnModel
            size_mib = [Math]::Round((Get-DirectoryBytes $zhEnModel) / 1MB, 2)
            load_ms = $workers['chinese-english'].LoadMilliseconds
            load_peak_working_set_mib = [Math]::Round($workers['chinese-english'].LoadPeakWorkingSetBytes / 1MB, 2)
        }
    }
    summary = [ordered]@{
        cases = $results.Count
        average_ms = [Math]::Round(($elapsed | Measure-Object -Average).Average, 2)
        p50_ms = Get-Percentile $elapsed 50
        p95_ms = Get-Percentile $elapsed 95
        max_ms = ($elapsed | Measure-Object -Maximum).Maximum
        peak_working_set_mib = ($results | Measure-Object peak_working_set_mib -Maximum).Maximum
        preserve_passed = @($preserveCases | Where-Object preserve_pass).Count
        preserve_total = $preserveCases.Count
    }
    cases = $results
}

$jsonPath = Join-Path $outputRoot "$($suite.id)-opus-mt-int8-$stamp.json"
$markdownPath = [IO.Path]::ChangeExtension($jsonPath, '.md')
[IO.File]::WriteAllText($jsonPath, ($report | ConvertTo-Json -Depth 12), $utf8NoBom)
$markdown = [Text.StringBuilder]::new()
[void]$markdown.AppendLine("# $($suite.id) · OPUS-MT INT8 基准")
[void]$markdown.AppendLine()
[void]$markdown.AppendLine("- 样例：$($report.summary.cases)")
[void]$markdown.AppendLine("- 延迟：平均 $($report.summary.average_ms) ms；P50 $($report.summary.p50_ms) ms；P95 $($report.summary.p95_ms) ms；最大 $($report.summary.max_ms) ms")
[void]$markdown.AppendLine("- 峰值工作集：$($report.summary.peak_working_set_mib) MiB")
[void]$markdown.AppendLine("- 格式保留：$($report.summary.preserve_passed)/$($report.summary.preserve_total)")
[void]$markdown.AppendLine()
[void]$markdown.AppendLine('| ID | 原文 | 模型译文 | 参考译文 | 耗时 ms | 格式 | 人工评分 |')
[void]$markdown.AppendLine('|---|---|---|---|---:|---|---|')
foreach ($item in $results) {
    $source = $item.source.Replace('|', '\|').Replace("`r", ' ').Replace("`n", ' ')
    $translation = $item.translation.Replace('|', '\|').Replace("`r", ' ').Replace("`n", ' ')
    $reference = ([string]$item.references[0]).Replace('|', '\|')
    $format = if ($item.preserve.Count -eq 0) { '—' } elseif ($item.preserve_pass) { '通过' } else { '失败' }
    [void]$markdown.AppendLine("| $($item.id) | $source | $translation | $reference | $($item.elapsed_ms) | $format | 待盲评 |")
}
[IO.File]::WriteAllText($markdownPath, $markdown.ToString(), $utf8NoBom)

Write-Output "BENCHMARK_JSON=$jsonPath"
Write-Output "BENCHMARK_MARKDOWN=$markdownPath"
Write-Output "CASES=$($report.summary.cases)"
Write-Output "AVERAGE_MS=$($report.summary.average_ms)"
Write-Output "P95_MS=$($report.summary.p95_ms)"
Write-Output "PEAK_WORKING_SET_MIB=$($report.summary.peak_working_set_mib)"
Write-Output "PRESERVE=$($report.summary.preserve_passed)/$($report.summary.preserve_total)"
