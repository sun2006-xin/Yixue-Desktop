param(
    [string]$RuntimeDirectory = (
        Join-Path $PSScriptRoot '..\runtime\install\yixue-ct2-runtime\bin'
    ),
    [string]$ModelDirectory,
    [string]$Text = 'Technology changes life.'
)

$ErrorActionPreference = 'Stop'
$runtimeDirectoryPath = (Resolve-Path -LiteralPath $RuntimeDirectory).Path
$runtimeLibrary = Join-Path $runtimeDirectoryPath 'yixue_ct2_runtime.dll'
$ctranslate2Library = Join-Path $runtimeDirectoryPath 'ctranslate2.dll'

foreach ($path in @($runtimeLibrary, $ctranslate2Library)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required runtime library is missing: $path"
    }
}

$nativeMethods = @'
using System;
using System.Runtime.InteropServices;

public static class YixueRuntimeSmokeNative
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool SetDllDirectory(string path);

    [DllImport("yixue_ct2_runtime.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern int yixue_ct2_runtime_abi_version();

    [DllImport("yixue_ct2_runtime.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr yixue_ct2_open(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string modelDirectory,
        out IntPtr error);

    [DllImport("yixue_ct2_runtime.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr yixue_ct2_translate(
        IntPtr runtime,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string source,
        out IntPtr error);

    [DllImport("yixue_ct2_runtime.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern void yixue_ct2_close(IntPtr runtime);

    [DllImport("yixue_ct2_runtime.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern void yixue_ct2_string_free(IntPtr value);
}
'@

if (-not ('YixueRuntimeSmokeNative' -as [type])) {
    Add-Type -TypeDefinition $nativeMethods
}

if (-not [YixueRuntimeSmokeNative]::SetDllDirectory($runtimeDirectoryPath)) {
    throw "Unable to add the runtime directory to the DLL search path"
}

$abiVersion = [YixueRuntimeSmokeNative]::yixue_ct2_runtime_abi_version()
if ($abiVersion -ne 1) {
    throw "Expected runtime ABI 1 but found $abiVersion"
}

$errorPointer = [IntPtr]::Zero
$invalidModel = Join-Path $runtimeDirectoryPath '不存在的模型'
$handle = [YixueRuntimeSmokeNative]::yixue_ct2_open($invalidModel, [ref]$errorPointer)
if ($handle -ne [IntPtr]::Zero) {
    throw 'Opening a missing model unexpectedly succeeded'
}
if ($errorPointer -eq [IntPtr]::Zero) {
    throw 'Opening a missing model did not return an error message'
}

try {
    $errorMessage = [Runtime.InteropServices.Marshal]::PtrToStringUTF8($errorPointer)
    if ([string]::IsNullOrWhiteSpace($errorMessage)) {
        throw 'Opening a missing model returned a blank error message'
    }
    if (-not $errorMessage.Contains('不存在的模型')) {
        throw 'The runtime error did not preserve the UTF-8 model path'
    }
} finally {
    [YixueRuntimeSmokeNative]::yixue_ct2_string_free($errorPointer)
}

Write-Output "Yixue local runtime smoke test: PASS (ABI $abiVersion, UTF-8 error boundary)"

if (-not [string]::IsNullOrWhiteSpace($ModelDirectory)) {
    $modelPath = (Resolve-Path -LiteralPath $ModelDirectory).Path
    $openError = [IntPtr]::Zero
    $runtime = [YixueRuntimeSmokeNative]::yixue_ct2_open($modelPath, [ref]$openError)
    if ($runtime -eq [IntPtr]::Zero) {
        $message = [Runtime.InteropServices.Marshal]::PtrToStringUTF8($openError)
        if ($openError -ne [IntPtr]::Zero) {
            [YixueRuntimeSmokeNative]::yixue_ct2_string_free($openError)
        }
        throw "Unable to open model: $message"
    }

    try {
        $translationError = [IntPtr]::Zero
        $translation = [YixueRuntimeSmokeNative]::yixue_ct2_translate(
            $runtime,
            $Text,
            [ref]$translationError
        )
        if ($translation -eq [IntPtr]::Zero) {
            $message = [Runtime.InteropServices.Marshal]::PtrToStringUTF8($translationError)
            if ($translationError -ne [IntPtr]::Zero) {
                [YixueRuntimeSmokeNative]::yixue_ct2_string_free($translationError)
            }
            throw "Translation failed: $message"
        }
        try {
            $translatedText = [Runtime.InteropServices.Marshal]::PtrToStringUTF8($translation)
            Write-Output "SOURCE=$Text"
            Write-Output "TRANSLATION=$translatedText"
        } finally {
            [YixueRuntimeSmokeNative]::yixue_ct2_string_free($translation)
        }
    } finally {
        Write-Output 'MODEL_CLOSE_BEGIN'
        [YixueRuntimeSmokeNative]::yixue_ct2_close($runtime)
        Write-Output 'MODEL_CLOSE_END'
    }
}
