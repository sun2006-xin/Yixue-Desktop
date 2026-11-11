param(
    [string]$RuntimeDirectory = (
        Join-Path $PSScriptRoot '..\runtime\install\yixue-ct2-runtime\bin'
    ),
    [Parameter(Mandatory = $true)]
    [string]$ModelDirectory,
    [string]$Text = 'Technology changes life.',
    [int]$ResponseTimeoutMilliseconds = 30000,
    [int]$TerminationTimeoutMilliseconds = 2000
)

$ErrorActionPreference = 'Stop'
$runtimePath = (Resolve-Path -LiteralPath $RuntimeDirectory).Path
$modelPath = (Resolve-Path -LiteralPath $ModelDirectory).Path
$workerPath = Join-Path $runtimePath 'yixue_ct2_worker.exe'

if (-not (Test-Path -LiteralPath $workerPath -PathType Leaf)) {
    throw "Local inference worker is missing: $workerPath"
}

function Read-WorkerResponse {
    param(
        [System.Diagnostics.Process]$Process,
        [int]$TimeoutMilliseconds
    )

    $readTask = $Process.StandardOutput.ReadLineAsync()
    if (-not $readTask.Wait($TimeoutMilliseconds)) {
        throw "Worker response timed out after $TimeoutMilliseconds ms"
    }
    $line = $readTask.Result
    if ([string]::IsNullOrWhiteSpace($line)) {
        throw 'Worker returned an empty protocol response'
    }
    return $line | ConvertFrom-Json
}

function Send-WorkerRequest {
    param(
        [System.Diagnostics.Process]$Process,
        [hashtable]$Request
    )

    $line = $Request | ConvertTo-Json -Compress
    $Process.StandardInput.WriteLine($line)
    $Process.StandardInput.Flush()
}

$startInfo = [System.Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $workerPath
$startInfo.WorkingDirectory = $runtimePath
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.RedirectStandardInput = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
$startInfo.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
$startInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
$startInfo.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)

$process = [System.Diagnostics.Process]::new()
$process.StartInfo = $startInfo
if (-not $process.Start()) {
    throw 'Unable to start the local inference worker'
}

try {
    $process.StandardInput.WriteLine('{not-valid-json')
    $process.StandardInput.Flush()
    $invalidJson = Read-WorkerResponse $process $ResponseTimeoutMilliseconds
    if ($invalidJson.ok -ne $false -or $invalidJson.code -ne 'invalid_json') {
        throw 'Worker did not reject malformed JSON'
    }

    $process.StandardInput.WriteLine(('x' * (1024 * 1024 + 1)))
    $process.StandardInput.Flush()
    $tooLarge = Read-WorkerResponse $process $ResponseTimeoutMilliseconds
    if ($tooLarge.ok -ne $false -or $tooLarge.code -ne 'request_too_large') {
        throw 'Worker did not reject an oversized protocol request'
    }

    $process.StandardInput.WriteLine('[]')
    $process.StandardInput.Flush()
    $wrongShape = Read-WorkerResponse $process $ResponseTimeoutMilliseconds
    if ($wrongShape.ok -ne $false -or $wrongShape.code -ne 'invalid_request') {
        throw 'Worker did not reject a non-object JSON request'
    }

    Send-WorkerRequest $process @{
        schema_version = '1'
        id = 'wrong-version-type'
        command = 'translate'
        text = $Text
    }
    $wrongVersionType = Read-WorkerResponse $process $ResponseTimeoutMilliseconds
    if ($wrongVersionType.ok -ne $false -or $wrongVersionType.code -ne 'invalid_request') {
        throw 'Worker did not reject an invalid schema version type'
    }

    Send-WorkerRequest $process @{
        schema_version = 1
        id = 'before-open'
        command = 'translate'
        text = $Text
    }
    $beforeOpen = Read-WorkerResponse $process $ResponseTimeoutMilliseconds
    if ($beforeOpen.ok -ne $false -or $beforeOpen.code -ne 'model_not_open') {
        throw 'Worker did not reject translation before opening a model'
    }

    Send-WorkerRequest $process @{
        schema_version = 1
        id = 'open-model'
        command = 'open'
        model_path = $modelPath
    }
    $open = Read-WorkerResponse $process $ResponseTimeoutMilliseconds
    if ($open.ok -ne $true -or $open.id -ne 'open-model' -or $open.ready -ne $true) {
        throw 'Worker did not open the verified model'
    }

    Send-WorkerRequest $process @{
        schema_version = 1
        id = 'translate-text'
        command = 'translate'
        text = $Text
    }
    $translation = Read-WorkerResponse $process $ResponseTimeoutMilliseconds
    if ($translation.ok -ne $true -or
        $translation.id -ne 'translate-text' -or
        [string]::IsNullOrWhiteSpace($translation.translation)) {
        throw 'Worker did not return a valid translation'
    }

    $translatedText = [string]$translation.translation
    if ($translatedText -eq $Text) {
        throw 'Worker translation unexpectedly equals the English source text'
    }

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $process.Kill($true)
    if (-not $process.WaitForExit($TerminationTimeoutMilliseconds)) {
        throw "Worker did not terminate within $TerminationTimeoutMilliseconds ms"
    }
    $stopwatch.Stop()

    $stderr = $process.StandardError.ReadToEnd()
    if ($stderr.Contains($Text)) {
        throw 'Worker diagnostics leaked the source text to stderr'
    }

    Write-Output 'Yixue local worker smoke test: PASS'
    Write-Output "TRANSLATION=$translatedText"
    Write-Output "TERMINATION_MS=$($stopwatch.ElapsedMilliseconds)"
} finally {
    if (-not $process.HasExited) {
        $process.Kill($true)
        $process.WaitForExit($TerminationTimeoutMilliseconds) | Out-Null
    }
    $process.Dispose()
}
