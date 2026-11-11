use std::{
    ffi::OsString,
    io::{self, BufRead, BufReader, Write},
    path::{Path, PathBuf},
    process::{Child, ChildStdin, Command, Stdio},
    sync::{
        Mutex,
        mpsc::{self, Receiver, RecvTimeoutError},
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

use serde_json::{Value, json};

use crate::{CTranslate2Runtime, CancellationToken, CoreError, VerifiedModelPackage};

#[cfg(windows)]
use std::os::windows::process::CommandExt;

const WORKER_SCHEMA_VERSION: u32 = 1;
const WAIT_POLL_INTERVAL: Duration = Duration::from_millis(20);

#[cfg(windows)]
fn worker_model_path(path: &Path) -> String {
    let value = path.to_string_lossy();
    if let Some(rest) = value.strip_prefix(r"\\?\UNC\") {
        format!(r"\\{rest}")
    } else if let Some(rest) = value.strip_prefix(r"\\?\") {
        rest.to_owned()
    } else {
        value.into_owned()
    }
}

#[cfg(not(windows))]
fn worker_model_path(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

#[derive(Clone)]
struct WorkerCommand {
    executable: PathBuf,
    arguments: Vec<OsString>,
}

impl WorkerCommand {
    fn new(executable: PathBuf, arguments: Vec<OsString>) -> Self {
        Self {
            executable,
            arguments,
        }
    }

    fn spawn(&self) -> io::Result<Child> {
        let mut command = Command::new(&self.executable);
        command
            .args(&self.arguments)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        #[cfg(windows)]
        command.creation_flags(0x0800_0000);
        command.spawn()
    }
}

struct WorkerProcess {
    child: Child,
    input: ChildStdin,
    responses: Receiver<String>,
    stdout_thread: Option<JoinHandle<()>>,
    stderr_thread: Option<JoinHandle<()>>,
    model_root: PathBuf,
    next_request_id: u64,
}

impl WorkerProcess {
    fn start(
        command: &WorkerCommand,
        model_root: &Path,
        timeout: Duration,
        cancellation: &CancellationToken,
    ) -> Result<Self, CoreError> {
        cancellation.check()?;
        let mut child = command.spawn().map_err(|_| {
            CoreError::ProviderUnavailable("local translation worker could not start".into())
        })?;
        let input = child.stdin.take().ok_or_else(|| {
            CoreError::ProviderUnavailable("local translation worker input is unavailable".into())
        })?;
        let output = child.stdout.take().ok_or_else(|| {
            CoreError::ProviderUnavailable("local translation worker output is unavailable".into())
        })?;
        let mut diagnostics = child.stderr.take().ok_or_else(|| {
            CoreError::ProviderUnavailable(
                "local translation worker diagnostics are unavailable".into(),
            )
        })?;

        let (sender, responses) = mpsc::channel();
        let stdout_thread = thread::spawn(move || {
            for line in BufReader::new(output).lines() {
                match line {
                    Ok(value) => {
                        if sender.send(value).is_err() {
                            break;
                        }
                    }
                    Err(_) => break,
                }
            }
        });
        let stderr_thread = thread::spawn(move || {
            let _ = io::copy(&mut diagnostics, &mut io::sink());
        });

        let mut worker = Self {
            child,
            input,
            responses,
            stdout_thread: Some(stdout_thread),
            stderr_thread: Some(stderr_thread),
            model_root: model_root.to_path_buf(),
            next_request_id: 1,
        };
        let response = worker.request(
            json!({"command": "open", "model_path": worker_model_path(model_root)}),
            timeout,
            cancellation,
        )?;
        if response.get("ready") != Some(&Value::Bool(true)) {
            return Err(CoreError::ProviderUnavailable(
                "local translation worker did not open the model".into(),
            ));
        }
        Ok(worker)
    }

    fn translate(
        &mut self,
        text: &str,
        timeout: Duration,
        cancellation: &CancellationToken,
    ) -> Result<String, CoreError> {
        let response = self.request(
            json!({"command": "translate", "text": text}),
            timeout,
            cancellation,
        )?;
        response
            .get("translation")
            .and_then(Value::as_str)
            .filter(|value| !value.trim().is_empty())
            .map(str::to_owned)
            .ok_or(CoreError::InvalidProviderOutput)
    }

    fn request(
        &mut self,
        mut payload: Value,
        timeout: Duration,
        cancellation: &CancellationToken,
    ) -> Result<Value, CoreError> {
        cancellation.check()?;
        let request_id = self.next_request_id.to_string();
        self.next_request_id += 1;
        payload["schema_version"] = Value::from(WORKER_SCHEMA_VERSION);
        payload["id"] = Value::from(request_id.clone());
        serde_json::to_writer(&mut self.input, &payload).map_err(|_| {
            CoreError::ProviderUnavailable("local translation worker request failed".into())
        })?;
        self.input
            .write_all(b"\n")
            .and_then(|()| self.input.flush())
            .map_err(|_| {
                CoreError::ProviderUnavailable("local translation worker request failed".into())
            })?;

        let deadline = Instant::now() + timeout;
        loop {
            cancellation.check()?;
            let now = Instant::now();
            if now >= deadline {
                return Err(CoreError::ProviderUnavailable(
                    "local translation worker timed out".into(),
                ));
            }
            let wait = WAIT_POLL_INTERVAL.min(deadline.saturating_duration_since(now));
            match self.responses.recv_timeout(wait) {
                Ok(line) => {
                    let response: Value = serde_json::from_str(&line).map_err(|_| {
                        CoreError::ProviderUnavailable(
                            "local translation worker returned invalid data".into(),
                        )
                    })?;
                    if response.get("schema_version") != Some(&Value::from(WORKER_SCHEMA_VERSION))
                        || response.get("id") != Some(&Value::from(request_id.as_str()))
                    {
                        return Err(CoreError::ProviderUnavailable(
                            "local translation worker response did not match the request".into(),
                        ));
                    }
                    if response.get("ok") != Some(&Value::Bool(true)) {
                        let message = match response.get("code").and_then(Value::as_str) {
                            Some("model_open_failed") => {
                                "local translation model could not be opened"
                            }
                            Some("invalid_model_path") => {
                                "local translation model path was rejected"
                            }
                            Some("model_not_open") => "local translation model is not open",
                            Some("translation_failed") => {
                                "local translation model failed to translate"
                            }
                            _ => "local translation worker rejected the request",
                        };
                        return Err(CoreError::ProviderUnavailable(message.into()));
                    }
                    return Ok(response);
                }
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => {
                    return Err(CoreError::ProviderUnavailable(
                        "local translation worker stopped unexpectedly".into(),
                    ));
                }
            }
        }
    }

    fn terminate(&mut self) {
        if self.child.try_wait().ok().flatten().is_none() {
            let _ = self.child.kill();
        }
        let _ = self.child.wait();
        if let Some(handle) = self.stdout_thread.take() {
            let _ = handle.join();
        }
        if let Some(handle) = self.stderr_thread.take() {
            let _ = handle.join();
        }
    }
}

impl Drop for WorkerProcess {
    fn drop(&mut self) {
        self.terminate();
    }
}

pub struct ProcessCTranslate2Runtime {
    command: WorkerCommand,
    startup_timeout: Duration,
    request_timeout: Duration,
    worker: Mutex<Option<WorkerProcess>>,
}

impl ProcessCTranslate2Runtime {
    /// Creates a process-isolated local translation runtime.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::ProviderUnavailable`] when the trusted worker
    /// executable cannot be resolved or is not a regular file.
    pub fn new(worker_executable: impl AsRef<Path>) -> Result<Self, CoreError> {
        let executable = worker_executable.as_ref().canonicalize().map_err(|_| {
            CoreError::ProviderUnavailable("local translation worker is missing".into())
        })?;
        if !executable.is_file() {
            return Err(CoreError::ProviderUnavailable(
                "local translation worker is missing".into(),
            ));
        }
        let trusted_name = executable
            .file_name()
            .and_then(|value| value.to_str())
            .is_some_and(|value| value.eq_ignore_ascii_case("yixue_ct2_worker.exe"));
        if !trusted_name {
            return Err(CoreError::ProviderUnavailable(
                "local translation worker is not trusted".into(),
            ));
        }
        let runtime_directory = executable.parent().ok_or_else(|| {
            CoreError::ProviderUnavailable(
                "local translation worker directory is unavailable".into(),
            )
        })?;
        for dependency in ["yixue_ct2_runtime.dll", "ctranslate2.dll"] {
            if !runtime_directory.join(dependency).is_file() {
                return Err(CoreError::ProviderUnavailable(
                    "local translation worker dependencies are missing".into(),
                ));
            }
        }
        Ok(Self {
            command: WorkerCommand::new(executable, Vec::new()),
            startup_timeout: Duration::from_secs(30),
            request_timeout: Duration::from_secs(60),
            worker: Mutex::new(None),
        })
    }
}

impl CTranslate2Runtime for ProcessCTranslate2Runtime {
    fn translate(
        &self,
        package: &VerifiedModelPackage,
        source_text: &str,
        cancellation: &CancellationToken,
    ) -> Result<String, CoreError> {
        cancellation.check()?;
        let mut slot = self.worker.lock().map_err(|_| {
            CoreError::ProviderUnavailable("local translation worker state is unavailable".into())
        })?;
        if slot
            .as_ref()
            .is_some_and(|worker| worker.model_root != package.root())
        {
            slot.take();
        }
        if slot.is_none() {
            *slot = Some(WorkerProcess::start(
                &self.command,
                package.root(),
                self.startup_timeout,
                cancellation,
            )?);
        }
        let result = slot.as_mut().expect("worker was initialized").translate(
            source_text,
            self.request_timeout,
            cancellation,
        );
        if result.is_err() {
            slot.take();
        }
        result
    }
}

#[cfg(test)]
mod tests {
    use std::{
        ffi::OsString,
        fs,
        path::{Path, PathBuf},
        thread,
        time::{Duration, Instant, SystemTime, UNIX_EPOCH},
    };

    use super::{ProcessCTranslate2Runtime, WorkerCommand, WorkerProcess};
    use crate::{CancellationToken, CoreError};

    #[cfg(windows)]
    #[test]
    fn worker_model_path_removes_windows_verbatim_prefix() {
        assert_eq!(
            super::worker_model_path(Path::new(r"\\?\D:\models\verified")),
            r"D:\models\verified"
        );
        assert_eq!(
            super::worker_model_path(Path::new(r"\\?\UNC\server\models\verified")),
            r"\\server\models\verified"
        );
    }

    #[test]
    fn public_runtime_rejects_an_untrusted_worker_filename() {
        let script = FakeWorkerScript::create();
        let Err(error) = ProcessCTranslate2Runtime::new(&script.0) else {
            panic!("a script must not be accepted as the native worker");
        };
        assert_eq!(
            error,
            CoreError::ProviderUnavailable("local translation worker is not trusted".into())
        );
    }

    struct FakeWorkerScript(PathBuf);

    impl FakeWorkerScript {
        fn create() -> Self {
            let suffix = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .expect("clock should be valid")
                .as_nanos();
            let path = std::env::temp_dir().join(format!("yixue-worker-{suffix}.ps1"));
            fs::write(
                &path,
                r"$ErrorPreference = 'Stop'
while (($line = [Console]::In.ReadLine()) -ne $null) {
  $request = $line | ConvertFrom-Json
  if ($request.command -eq 'open') {
    @{schema_version=1; id=$request.id; ok=$true; ready=$true} | ConvertTo-Json -Compress
  } elseif ($request.text -eq 'hang') {
    Start-Sleep -Seconds 30
  } else {
    @{schema_version=1; id=$request.id; ok=$true; translation='测试译文'} | ConvertTo-Json -Compress
  }
}",
            )
            .expect("fake worker script should be written");
            Self(path)
        }

        fn command(&self) -> WorkerCommand {
            let system_root = std::env::var_os("SystemRoot").expect("SystemRoot should exist");
            let executable =
                PathBuf::from(system_root).join("System32/WindowsPowerShell/v1.0/powershell.exe");
            WorkerCommand::new(
                executable,
                vec![
                    OsString::from("-NoProfile"),
                    OsString::from("-NonInteractive"),
                    OsString::from("-File"),
                    self.0.clone().into_os_string(),
                ],
            )
        }
    }

    impl Drop for FakeWorkerScript {
        fn drop(&mut self) {
            let _ = fs::remove_file(&self.0);
        }
    }

    fn start_worker(script: &FakeWorkerScript) -> WorkerProcess {
        WorkerProcess::start(
            &script.command(),
            Path::new("D:/verified-model"),
            Duration::from_secs(2),
            &CancellationToken::new(),
        )
        .expect("fake worker should start")
    }

    #[test]
    fn worker_round_trip_returns_translation_and_terminates_quickly() {
        let script = FakeWorkerScript::create();
        let mut worker = start_worker(&script);

        let translated = worker
            .translate("hello", Duration::from_secs(2), &CancellationToken::new())
            .expect("translation should succeed");
        assert_eq!(translated, "测试译文");

        let started = Instant::now();
        worker.terminate();
        assert!(started.elapsed() < Duration::from_secs(2));
    }

    #[test]
    fn worker_timeout_returns_stable_provider_error() {
        let script = FakeWorkerScript::create();
        let mut worker = start_worker(&script);

        let error = worker
            .translate(
                "hang",
                Duration::from_millis(100),
                &CancellationToken::new(),
            )
            .expect_err("hanging worker should time out");
        assert_eq!(
            error,
            CoreError::ProviderUnavailable("local translation worker timed out".into())
        );
    }

    #[test]
    fn worker_wait_stops_when_request_is_cancelled() {
        let script = FakeWorkerScript::create();
        let mut worker = start_worker(&script);
        let cancellation = CancellationToken::new();
        let cancellation_signal = cancellation.clone();
        thread::spawn(move || {
            thread::sleep(Duration::from_millis(50));
            cancellation_signal.cancel();
        });

        let error = worker
            .translate("hang", Duration::from_secs(5), &cancellation)
            .expect_err("cancelled worker should stop waiting");
        assert_eq!(error, CoreError::Cancelled);
    }
}
