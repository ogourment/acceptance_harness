use portable_pty::{CommandBuilder, PtySize, native_pty_system};
use std::io::{self, Read, Write};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

const START: u8 = 0x01;
const INPUT: u8 = 0x02;
const RESIZE: u8 = 0x03;
const STOP: u8 = 0x04;
const SNAPSHOT: u8 = 0x05;

const STARTED: u8 = 0x81;
const OUTPUT: u8 = 0x82;
const EXITED: u8 = 0x83;
const RESIZED: u8 = 0x84;
const SNAPSHOT_READY: u8 = 0x85;
const ERROR: u8 = 0xff;

fn main() {
    if let Err(error) = run() {
        let stdout = Arc::new(Mutex::new(io::stdout()));
        let _ = send_frame(&stdout, ERROR, error.to_string().as_bytes());
        std::process::exit(1);
    }
}

fn run() -> Result<(), String> {
    let mut stdin = io::stdin();
    let first = read_frame(&mut stdin)?.ok_or("control stream closed before start")?;
    let request = StartRequest::decode(&first)?;

    let pair = native_pty_system()
        .openpty(PtySize {
            rows: request.rows,
            cols: request.cols,
            pixel_width: 0,
            pixel_height: 0,
        })
        .map_err(|error| format!("open PTY: {error}"))?;

    let mut command = CommandBuilder::new(&request.argv[0]);
    for argument in &request.argv[1..] {
        command.arg(argument);
    }
    if let Some(cwd) = request.cwd {
        command.cwd(cwd);
    }
    for (name, value) in request.env {
        command.env(name, value);
    }

    let child = pair
        .slave
        .spawn_command(command)
        .map_err(|error| format!("spawn {}: {error}", request.argv[0]))?;
    drop(pair.slave);

    let process_id = child
        .process_id()
        .ok_or("spawned PTY process has no process id")?;
    let mut writer = pair
        .master
        .take_writer()
        .map_err(|error| format!("open PTY writer: {error}"))?;
    let mut reader = pair
        .master
        .try_clone_reader()
        .map_err(|error| format!("open PTY reader: {error}"))?;
    let stdout = Arc::new(Mutex::new(io::stdout()));
    let parser = Arc::new(Mutex::new(vt100::Parser::new(
        request.rows,
        request.cols,
        0,
    )));
    send_frame(&stdout, STARTED, &process_id.to_be_bytes())?;

    let output = Arc::clone(&stdout);
    let output_parser = Arc::clone(&parser);
    let reader_thread = thread::spawn(move || {
        let mut buffer = [0_u8; 8192];
        let mut pending_utf8 = Vec::new();
        loop {
            match reader.read(&mut buffer) {
                Ok(0) => break,
                Ok(size) => {
                    if let Ok(mut parser) = output_parser.lock() {
                        process_terminal_bytes(&mut parser, &mut pending_utf8, &buffer[..size]);
                    }
                    if send_frame(&output, OUTPUT, &buffer[..size]).is_err() {
                        break;
                    }
                }
                Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
                Err(_) => break,
            }
        }

        if !pending_utf8.is_empty()
            && let Ok(mut parser) = output_parser.lock()
        {
            parser.process("\u{fffd}".as_bytes());
        }
    });

    let (exit_sender, exit_receiver) = mpsc::channel();
    let waiter = thread::spawn(move || {
        let mut child = child;
        let code = match child.wait() {
            Ok(status) => status.exit_code() as i32,
            Err(_) => -1,
        };
        let _ = exit_sender.send(code);
    });

    let (control_sender, control_receiver) = mpsc::channel();
    let _control_thread = thread::spawn(move || {
        loop {
            match read_frame(&mut stdin) {
                Ok(Some(frame)) => {
                    if control_sender.send(Ok(frame)).is_err() {
                        break;
                    }
                }
                Ok(None) => {
                    let _ = control_sender.send(Err("control stream closed".into()));
                    break;
                }
                Err(error) => {
                    let _ = control_sender.send(Err(error));
                    break;
                }
            }
        }
    });

    let mut control_open = true;
    let mut stopping_since = None;
    let mut sent_sigkill = false;
    let exit_code = loop {
        if let Ok(code) = exit_receiver.try_recv() {
            break code;
        }

        if stopping_since
            .is_some_and(|started: Instant| started.elapsed() >= Duration::from_millis(250))
            && !sent_sigkill
        {
            kill_process_group(process_id, libc::SIGKILL);
            sent_sigkill = true;
        }

        match control_receiver.recv_timeout(Duration::from_millis(20)) {
            Ok(Ok(frame)) => {
                let (opcode, payload) = frame.split_first().ok_or("empty control frame")?;
                match *opcode {
                    INPUT => writer
                        .write_all(payload)
                        .and_then(|_| writer.flush())
                        .map_err(|error| format!("write PTY input: {error}"))?,
                    RESIZE => {
                        if payload.len() != 4 {
                            return Err("resize payload must be four bytes".into());
                        }
                        let rows = u16::from_be_bytes([payload[0], payload[1]]);
                        let cols = u16::from_be_bytes([payload[2], payload[3]]);
                        pair.master
                            .resize(PtySize {
                                rows,
                                cols,
                                pixel_width: 0,
                                pixel_height: 0,
                            })
                            .map_err(|error| format!("resize PTY: {error}"))?;
                        parser
                            .lock()
                            .map_err(|_| "terminal parser lock poisoned")?
                            .screen_mut()
                            .set_size(rows, cols);
                        send_frame(&stdout, RESIZED, &[])?;
                    }
                    STOP => {
                        kill_process_group(process_id, libc::SIGHUP);
                        stopping_since.get_or_insert_with(Instant::now);
                    }
                    SNAPSHOT => {
                        let parser = parser.lock().map_err(|_| "terminal parser lock poisoned")?;
                        let screen = parser.screen();
                        let (rows, columns) = screen.size();
                        let text = screen.contents();
                        let mut snapshot = Vec::with_capacity(4 + text.len());
                        snapshot.extend_from_slice(&rows.to_be_bytes());
                        snapshot.extend_from_slice(&columns.to_be_bytes());
                        snapshot.extend_from_slice(text.as_bytes());
                        send_frame(&stdout, SNAPSHOT_READY, &snapshot)?;
                    }
                    other => return Err(format!("unknown control opcode {other:#04x}")),
                }
            }
            Ok(Err(_closed)) => {
                control_open = false;
                kill_process_group(process_id, libc::SIGHUP);
                stopping_since.get_or_insert_with(Instant::now);
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) if control_open => {
                control_open = false;
                kill_process_group(process_id, libc::SIGHUP);
                stopping_since.get_or_insert_with(Instant::now);
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => {}
        }
    };

    drop(writer);
    let _ = waiter.join();
    drop(pair.master);
    let _ = reader_thread.join();
    send_frame(&stdout, EXITED, &exit_code.to_be_bytes())?;
    drop(control_receiver);
    Ok(())
}

fn kill_process_group(process_id: u32, signal: i32) {
    if let Ok(pid) = i32::try_from(process_id) {
        // portable-pty makes the child a session and process-group leader.
        // A negative pid therefore targets the complete scenario-owned tree.
        unsafe {
            libc::kill(-pid, signal);
        }
    }
}

fn process_terminal_bytes(parser: &mut vt100::Parser, pending_utf8: &mut Vec<u8>, bytes: &[u8]) {
    pending_utf8.extend_from_slice(bytes);

    loop {
        match std::str::from_utf8(pending_utf8) {
            Ok(_) => {
                parser.process(pending_utf8);
                pending_utf8.clear();
                break;
            }
            Err(error) => {
                let valid_up_to = error.valid_up_to();
                let error_len = error.error_len();
                if valid_up_to > 0 {
                    parser.process(&pending_utf8[..valid_up_to]);
                    pending_utf8.drain(..valid_up_to);
                }

                match error_len {
                    None if valid_up_to == 0 => break,
                    None => continue,
                    Some(length) => {
                        parser.process("\u{fffd}".as_bytes());
                        pending_utf8.drain(..length);
                    }
                }
            }
        }
    }
}

fn read_frame(reader: &mut impl Read) -> Result<Option<Vec<u8>>, String> {
    let mut length = [0_u8; 4];
    match reader.read_exact(&mut length) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(error) => return Err(format!("read frame length: {error}")),
    }

    let length = u32::from_be_bytes(length) as usize;
    if length > 16 * 1024 * 1024 {
        return Err(format!("control frame too large: {length} bytes"));
    }
    let mut payload = vec![0_u8; length];
    reader
        .read_exact(&mut payload)
        .map_err(|error| format!("read frame payload: {error}"))?;
    Ok(Some(payload))
}

fn send_frame(stdout: &Arc<Mutex<io::Stdout>>, opcode: u8, payload: &[u8]) -> Result<(), String> {
    let length = u32::try_from(payload.len() + 1).map_err(|_| "event frame too large")?;
    let mut stdout = stdout.lock().map_err(|_| "stdout lock poisoned")?;
    stdout
        .write_all(&length.to_be_bytes())
        .and_then(|_| stdout.write_all(&[opcode]))
        .and_then(|_| stdout.write_all(payload))
        .and_then(|_| stdout.flush())
        .map_err(|error| format!("write event frame: {error}"))
}

#[derive(Debug)]
struct StartRequest {
    rows: u16,
    cols: u16,
    cwd: Option<String>,
    env: Vec<(String, String)>,
    argv: Vec<String>,
}

impl StartRequest {
    fn decode(frame: &[u8]) -> Result<Self, String> {
        let (opcode, payload) = frame.split_first().ok_or("empty start frame")?;
        if *opcode != START {
            return Err("first frame must be start".into());
        }
        let mut cursor = Cursor::new(payload);
        let rows = cursor.u16()?;
        let cols = cursor.u16()?;
        let cwd = match cursor.string()? {
            value if value.is_empty() => None,
            value => Some(value),
        };
        let env_count = cursor.u16()?;
        let mut environment = Vec::with_capacity(env_count as usize);
        for _ in 0..env_count {
            environment.push((cursor.string()?, cursor.string()?));
        }
        let argc = cursor.u16()?;
        if argc == 0 {
            return Err("start requires an executable".into());
        }
        let mut argv = Vec::with_capacity(argc as usize);
        for _ in 0..argc {
            argv.push(cursor.string()?);
        }
        if !cursor.remaining().is_empty() {
            return Err("trailing bytes in start frame".into());
        }
        Ok(Self {
            rows,
            cols,
            cwd,
            env: environment,
            argv,
        })
    }
}

struct Cursor<'a> {
    bytes: &'a [u8],
    offset: usize,
}

impl<'a> Cursor<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, offset: 0 }
    }

    fn remaining(&self) -> &'a [u8] {
        &self.bytes[self.offset..]
    }

    fn u16(&mut self) -> Result<u16, String> {
        let bytes = self.take(2)?;
        Ok(u16::from_be_bytes([bytes[0], bytes[1]]))
    }

    fn u32(&mut self) -> Result<u32, String> {
        let bytes = self.take(4)?;
        Ok(u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
    }

    fn string(&mut self) -> Result<String, String> {
        let length = self.u32()? as usize;
        String::from_utf8(self.take(length)?.to_vec())
            .map_err(|_| "control string is not UTF-8".into())
    }

    fn take(&mut self, length: usize) -> Result<&'a [u8], String> {
        let end = self
            .offset
            .checked_add(length)
            .ok_or("control field length overflow")?;
        if end > self.bytes.len() {
            return Err("truncated control frame".into());
        }
        let bytes = &self.bytes[self.offset..end];
        self.offset = end;
        Ok(bytes)
    }
}

#[cfg(test)]
mod tests {
    use super::{START, StartRequest, process_terminal_bytes};

    #[test]
    fn decodes_start_request_without_interpreting_arguments() {
        let mut frame = vec![START];
        frame.extend_from_slice(&24_u16.to_be_bytes());
        frame.extend_from_slice(&80_u16.to_be_bytes());
        push_string(&mut frame, "/tmp/fixture");
        frame.extend_from_slice(&1_u16.to_be_bytes());
        push_string(&mut frame, "TERM");
        push_string(&mut frame, "xterm-256color");
        frame.extend_from_slice(&2_u16.to_be_bytes());
        push_string(&mut frame, "repo-toolbox");
        push_string(&mut frame, "café Δ");

        let request = StartRequest::decode(&frame).expect("valid start request");

        assert_eq!(request.rows, 24);
        assert_eq!(request.cols, 80);
        assert_eq!(request.cwd.as_deref(), Some("/tmp/fixture"));
        assert_eq!(request.env, vec![("TERM".into(), "xterm-256color".into())]);
        assert_eq!(request.argv, vec!["repo-toolbox", "café Δ"]);
    }

    #[test]
    fn rejects_truncated_start_request() {
        let frame = [START, 0, 24, 0];
        assert_eq!(
            StartRequest::decode(&frame).expect_err("request must fail"),
            "truncated control frame"
        );
    }

    #[test]
    fn preserves_spacing_across_fragmented_utf8() {
        let mut parser = vt100::Parser::new(2, 40, 0);
        let mut pending = Vec::new();

        process_terminal_bytes(&mut parser, &mut pending, b"Unicode: caf\xc3");
        process_terminal_bytes(&mut parser, &mut pending, b"\xa9 \xce");
        process_terminal_bytes(&mut parser, &mut pending, b"\x94");

        assert_eq!(parser.screen().contents(), "Unicode: café Δ");
        assert!(pending.is_empty());
    }

    fn push_string(frame: &mut Vec<u8>, value: &str) {
        frame.extend_from_slice(&(value.len() as u32).to_be_bytes());
        frame.extend_from_slice(value.as_bytes());
    }
}
