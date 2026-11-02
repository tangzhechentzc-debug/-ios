use base64::{Engine as _, engine::general_purpose::STANDARD as B64};
use idevice::{
    ReadWrite,
    dvt::{
        message::AuxValue,
        remote_server::{Channel, RemoteServerClient},
    },
    remote_pairing::{
        PairableHost, PairableHostInfo, PeerDevice, RemotePairingClient, RpPairingFile,
        RpPairingSocket, connect_tls_psk_tunnel_native,
    },
    rsd::RsdHandshake,
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    ffi::{CStr, CString, c_char},
    net::Ipv4Addr,
    sync::{Arc, Mutex, OnceLock},
    time::Duration,
};
use tokio::{
    net::{TcpListener, TcpStream},
    sync::{mpsc, oneshot},
    task::JoinHandle,
    time::timeout,
};

const COMMAND_TIMEOUT: Duration = Duration::from_secs(20);
type Shared = Arc<Mutex<Value>>;

#[derive(Serialize, Deserialize)]
struct Record {
    version: u8,
    plist: String,
    peer_identifier: String,
    peer_irk: String,
    host_name: String,
}
impl Record {
    fn parse(request: &Value) -> Result<Self, &'static str> {
        let record: Self = serde_json::from_str(field(request, "pairing_record")?)
            .map_err(|_| "配对记录格式无效，请重新配对。")?;
        if record.version != 1 {
            return Err("配对记录版本不支持。");
        }
        Ok(record)
    }
    fn matches(&self, request: &Value) -> bool {
        let Ok(irk) = B64.decode(&self.peer_irk) else {
            return false;
        };
        PeerDevice::validate_auth_tag(
            &irk,
            request["service_identifier"].as_str().unwrap_or(""),
            request["auth_tag"].as_str().unwrap_or(""),
        )
    }
}
struct Pairing {
    status: Shared,
    task: JoinHandle<()>,
}
struct Session {
    commands: mpsc::Sender<Command>,
    health: Shared,
    task: JoinHandle<()>,
}
enum Action {
    Apply(f64, f64),
    Clear,
}
struct Command {
    action: Action,
    reply: oneshot::Sender<Value>,
}
#[derive(Default)]
struct State {
    pairing: Option<Pairing>,
    session: Option<Session>,
    recovery_needed: bool,
    stop_sent: bool,
}
impl State {
    fn phase(&self) -> &'static str {
        if self.stop_sent && self.session.is_none() {
            "stopped_unverified"
        } else if self.recovery_needed {
            "unknown"
        } else {
            "idle"
        }
    }
}
struct Engine {
    runtime: tokio::runtime::Runtime,
    state: tokio::sync::Mutex<State>,
}
static ENGINE: OnceLock<Engine> = OnceLock::new();

fn field<'a>(v: &'a Value, name: &str) -> Result<&'a str, &'static str> {
    v[name]
        .as_str()
        .filter(|s| !s.is_empty())
        .ok_or("缺少必要参数。")
}
fn reply(ok: bool, state: &str, message: &str) -> Value {
    json!({"ok":ok,"state":state,"message":message})
}
fn snapshot(v: &Shared) -> Value {
    v.lock().unwrap_or_else(|p| p.into_inner()).clone()
}
fn replace(v: &Shared, value: Value) {
    *v.lock().unwrap_or_else(|p| p.into_inner()) = value;
}
fn merge(mut a: Value, b: Value) -> Value {
    if let (Some(a), Some(b)) = (a.as_object_mut(), b.as_object()) {
        a.extend(b.clone());
    }
    a
}

impl Engine {
    fn new() -> Self {
        Self {
            runtime: tokio::runtime::Builder::new_multi_thread()
                .worker_threads(2)
                .enable_all()
                .build()
                .expect("native runtime"),
            state: tokio::sync::Mutex::new(State::default()),
        }
    }
    async fn request(&self, request: Value) -> Value {
        let mut state = self.state.lock().await;
        let result = self.execute(&mut state, &request).await;
        match result {
            Ok(v) => v,
            Err(message) => reply(false, state.phase(), message),
        }
    }
    async fn execute(&self, state: &mut State, request: &Value) -> Result<Value, &'static str> {
        match field(request, "op")? {
            "pair_start" => {
                if state.recovery_needed {
                    return Err("请先停止并恢复定位，再重新配对。");
                }
                if let Some(s) = state.session.take() {
                    s.task.abort();
                }
                if let Some(p) = state.pairing.take() {
                    p.task.abort();
                }
                let listener = TcpListener::bind((Ipv4Addr::UNSPECIFIED, 0))
                    .await
                    .map_err(|_| "无法启动本机配对监听。");
                let listener = listener?;
                let port = listener
                    .local_addr()
                    .map_err(|_| "无法读取配对端口。")?
                    .port();
                let hostname = format!("ChangeLocation-{}", uuid::Uuid::new_v4());
                let mut record = RpPairingFile::generate(&hostname);
                let info = PairableHostInfo::generate("ChangeLocation", "Mac17,7");
                let service_name = record.identifier.clone();
                let txt: std::collections::BTreeMap<_, _> =
                    info.mdns_txt_records(&service_name).into_iter().collect();
                let status = Arc::new(Mutex::new(merge(
                    reply(
                        true,
                        "idle",
                        "请到系统设置的开发者模式中与 ChangeLocation 配对。",
                    ),
                    json!({"pairing_state":"waiting"}),
                )));
                let shared = status.clone();
                let task = tokio::spawn(async move {
                    let work = async {
                        let (stream, _) = listener.accept().await.map_err(|_| "配对连接失败。")?;
                        let mut host = PairableHost::new(RpPairingSocket::new_device(stream), info);
                        let pin_status = shared.clone();
                        let peer = host
                            .accept(&mut record, move |pin| {
                                let shared = pin_status.clone();
                                async move {
                                    replace(
                                        &shared,
                                        merge(
                                            reply(true, "idle", "请在系统配对页面输入此验证码。"),
                                            json!({"pairing_state":"code","pairing_code":pin}),
                                        ),
                                    );
                                }
                            })
                            .await
                            .map_err(|_| "配对未完成，请返回应用重试。")?;
                        let record = Record {
                            version: 1,
                            plist: B64.encode(record.to_bytes()),
                            peer_identifier: peer.account_id.clone(),
                            peer_irk: B64.encode(peer.alt_irk),
                            host_name: hostname,
                        };
                        let encoded =
                            serde_json::to_string(&record).map_err(|_| "无法保存配对结果。")?;
                        Ok::<_, &'static str>(merge(
                            reply(true, "idle", "配对已完成，记录需存入本机钥匙串。"),
                            json!({"pairing_state":"complete","pairing_record":encoded,"peer_identifier":peer.account_id}),
                        ))
                    };
                    let result = match timeout(Duration::from_secs(300), work).await {
                        Ok(Ok(v)) => v,
                        Ok(Err(e)) => {
                            merge(reply(false, "idle", e), json!({"pairing_state":"failed"}))
                        }
                        Err(_) => merge(
                            reply(false, "idle", "配对超时，请返回应用重试。"),
                            json!({"pairing_state":"failed"}),
                        ),
                    };
                    replace(&shared, result);
                });
                state.pairing = Some(Pairing { status, task });
                Ok(merge(
                    reply(true, "idle", "本机配对已启动。"),
                    json!({"pairing_state":"waiting","port":port,"service_name":service_name,"txt":txt}),
                ))
            }
            "pair_status" => Ok(state
                .pairing
                .as_ref()
                .map(|p| {
                    let status = snapshot(&p.status);
                    if p.task.is_finished()
                        && matches!(status["pairing_state"].as_str(), Some("waiting" | "code"))
                    {
                        merge(
                            reply(false, "idle", "配对服务已中断，请重试。"),
                            json!({"pairing_state":"failed"}),
                        )
                    } else {
                        status
                    }
                })
                .unwrap_or_else(|| {
                    merge(
                        reply(true, "idle", "未开始配对。"),
                        json!({"pairing_state":"idle"}),
                    )
                })),
            "pair_cancel" => {
                if let Some(p) = state.pairing.take() {
                    p.task.abort();
                }
                Ok(reply(true, "idle", "已结束本次配对监听。"))
            }
            "match_service" => {
                let record = Record::parse(request)?;
                Ok(merge(
                    reply(true, "idle", "已检查设备身份。"),
                    json!({"matched":record.matches(request)}),
                ))
            }
            "connect" => {
                state.recovery_needed |= request["recovery_needed"].as_bool().unwrap_or(false);
                if let Some(s) = &state.session {
                    let v = snapshot(&s.health);
                    if !s.task.is_finished() && v["state"] == "active" {
                        return Ok(v);
                    }
                }
                if let Some(s) = state.session.take() {
                    s.task.abort();
                }
                state.stop_sent = false;
                let record = Record::parse(request)?;
                if !record.matches(request) {
                    return Err("发现的设备与本机配对记录不匹配。");
                }
                let host = field(request, "host")?.to_string();
                let port = request["port"]
                    .as_u64()
                    .filter(|p| *p > 0 && *p <= 65535)
                    .ok_or("设备端口无效。")? as u16;
                // This client is deliberately limited to LocalDevVPN's local device endpoint.
                if host != "10.7.0.1" {
                    return Err("请使用 LocalDevVPN 本机通道连接。");
                }
                let (tx, rx) = mpsc::channel(8);
                let (ready_tx, ready_rx) = oneshot::channel();
                let health = Arc::new(Mutex::new(reply(
                    false,
                    if state.recovery_needed {
                        "unknown"
                    } else {
                        "idle"
                    },
                    "正在连接本机定位服务…",
                )));
                let shared = health.clone();
                let recovery = state.recovery_needed;
                let task = tokio::spawn(async move {
                    session_worker(record, host, port, rx, ready_tx, shared, recovery).await;
                });
                let ready = timeout(Duration::from_secs(70), ready_rx).await;
                match ready {
                    Ok(Ok(v)) if v["ok"] == true => {
                        state.session = Some(Session {
                            commands: tx,
                            health,
                            task,
                        });
                        Ok(v)
                    }
                    Ok(Ok(v)) => {
                        task.abort();
                        Ok(v)
                    }
                    _ => {
                        task.abort();
                        Err("本机连接超时，请检查 LocalDevVPN 和本地网络权限。")
                    }
                }
            }
            "apply" | "clear" | "status" => {
                let op = request["op"].as_str().unwrap();
                if op == "status" {
                    return Ok(state
                        .session
                        .as_ref()
                        .map(|s| {
                            if s.task.is_finished() {
                                reply(
                                    false,
                                    if state.recovery_needed {
                                        "unknown"
                                    } else {
                                        "idle"
                                    },
                                    "定位会话已中断，请重新连接；此前定位恢复状态需核验。",
                                )
                            } else {
                                snapshot(&s.health)
                            }
                        })
                        .unwrap_or_else(|| {
                            reply(
                                true,
                                state.phase(),
                                if state.stop_sent {
                                    "停止请求已发送，等待确认真实位置恢复。"
                                } else {
                                    "定位服务尚未连接。"
                                },
                            )
                        }));
                }
                let action = if op == "apply" {
                    let lat = request["latitude"].as_f64().ok_or("纬度无效。")?;
                    let lon = request["longitude"].as_f64().ok_or("经度无效。")?;
                    if !lat.is_finite()
                        || !lon.is_finite()
                        || !(-90.0..=90.0).contains(&lat)
                        || !(-180.0..=180.0).contains(&lon)
                    {
                        return Err("经纬度超出范围。");
                    }
                    Action::Apply(lat, lon)
                } else {
                    Action::Clear
                };
                let Some(s) = &state.session else {
                    return Err("请先连接本机定位服务，再执行定位或恢复。");
                };
                state.recovery_needed = true;
                state.stop_sent = false;
                let (tx, rx) = oneshot::channel();
                if s.commands
                    .send(Command { action, reply: tx })
                    .await
                    .is_err()
                {
                    return Err("定位会话已中断，恢复状态未知。");
                }
                let result =
                    match timeout(Duration::from_secs(if op == "clear" { 65 } else { 45 }), rx)
                        .await
                    {
                        Ok(Ok(v)) => v,
                        _ => {
                            s.task.abort();
                            replace(
                                &s.health,
                                reply(false, "unknown", "定位命令超时，恢复状态未知。"),
                            );
                            return Err("定位命令超时，恢复状态未知。");
                        }
                    };
                if op == "clear" && result["ok"] == true && result["state"] == "stopped_unverified"
                {
                    if let Some(mut session) = state.session.take() {
                        if !matches!(
                            timeout(Duration::from_secs(5), &mut session.task).await,
                            Ok(Ok(()))
                        ) {
                            session.task.abort();
                            return Err("停止请求已发送，但会话关闭未确认，请重试停止。");
                        }
                    }
                    state.stop_sent = true;
                }
                Ok(result)
            }
            "confirm_restore" => {
                if !state.recovery_needed || !state.stop_sent || state.session.is_some() {
                    return Err("请先发送停止请求并结束定位会话，再确认地图中的真实位置已恢复。");
                }
                state.recovery_needed = false;
                state.stop_sent = false;
                Ok(reply(true, "idle", "已记录你确认的真实位置恢复结果。"))
            }
            "disconnect" => {
                if state.recovery_needed {
                    return Err("定位尚未确认停止，请先执行停止并恢复。");
                }
                if let Some(s) = state.session.take() {
                    s.task.abort();
                }
                Ok(reply(true, "idle", "已断开定位服务。"))
            }
            _ => Err("不支持的本机命令。"),
        }
    }
}

async fn open_session(
    record: Record,
    host: &str,
    port: u16,
) -> Result<
    (
        RemoteServerClient<Box<dyn ReadWrite>>,
        idevice::tcp::handle::AdapterHandle,
    ),
    &'static str,
> {
    let bytes = B64.decode(record.plist).map_err(|_| "配对记录无效。")?;
    let mut pairing = RpPairingFile::from_bytes(&bytes).map_err(|_| "配对记录无效。")?;
    let stream = TcpStream::connect((host, port))
        .await
        .map_err(|_| "无法连接本机设备，请开启 LocalDevVPN。")?;
    let mut rpc = RemotePairingClient::new(RpPairingSocket::new(stream), &record.host_name);
    rpc.attempt_pair_verify()
        .await
        .map_err(|_| "本机配对握手失败。")?;
    rpc.validate_pairing(&mut pairing)
        .await
        .map_err(|_| "设备不接受配对记录，请重新配对。")?;
    let tunnel_port = rpc
        .create_tcp_listener()
        .await
        .map_err(|_| "无法建立开发者隧道。")?;
    let stream = TcpStream::connect((host, tunnel_port))
        .await
        .map_err(|_| "本机隧道连接失败。")?;
    let tunnel = connect_tls_psk_tunnel_native(stream, rpc.encryption_key())
        .await
        .map_err(|_| "加密隧道握手失败。")?;
    let client = tunnel
        .info
        .client_address
        .parse()
        .map_err(|_| "隧道地址无效。")?;
    let server = tunnel
        .info
        .server_address
        .parse()
        .map_err(|_| "隧道地址无效。")?;
    let rsd_port = tunnel.info.server_rsd_port;
    let mss = (tunnel.info.mtu as usize).clamp(1280, 8192) - 60;
    let mut adapter =
        idevice::tcp::adapter::Adapter::new(Box::new(tunnel.into_inner()), client, server);
    adapter.set_mss(mss);
    let mut adapter = adapter.to_async_handle();
    let stream = adapter
        .connect(rsd_port)
        .await
        .map_err(|_| "无法连接远程服务目录。")?;
    let rsd = RsdHandshake::new(stream)
        .await
        .map_err(|_| "远程服务目录握手失败。")?;
    let service = rsd
        .services
        .get("com.apple.instruments.dtservicehub")
        .ok_or("定位开发者服务不可用，请检查开发者模式。")?;
    let socket = adapter
        .connect(service.port)
        .await
        .map_err(|_| "定位开发者服务连接失败。")?;
    let mut dvt = RemoteServerClient::new(socket);
    dvt.read_message(0)
        .await
        .map_err(|_| "定位服务握手失败。")?;
    Ok((dvt, adapter))
}

const LOCATION_SERVICE: &str = "com.apple.instruments.server.services.LocationSimulation";

struct DvtLocation<'a, R: ReadWrite> {
    channel: Channel<'a, R>,
}
impl<'a, R: ReadWrite> DvtLocation<'a, R> {
    async fn new(server: &'a mut RemoteServerClient<R>) -> Result<Self, idevice::IdeviceError> {
        Ok(Self {
            channel: server.make_channel(LOCATION_SERVICE).await?,
        })
    }
    async fn set(&mut self, latitude: f64, longitude: f64) -> Result<(), idevice::IdeviceError> {
        self.channel
            .call_method(
                Some("simulateLocationWithLatitude:longitude:"),
                Some(vec![
                    AuxValue::archived_value(latitude),
                    AuxValue::archived_value(longitude),
                ]),
                true,
            )
            .await?;
        self.channel.read_message().await?;
        Ok(())
    }
    async fn stop(&mut self) -> Result<(), idevice::IdeviceError> {
        // pymobiledevice3 defines this selector as expects_reply=False.
        // A write/flush is not a GPS-restoration acknowledgement.
        self.channel
            .call_method(Some("stopLocationSimulation"), None, false)
            .await
    }
}

async fn session_worker(
    record: Record,
    host: String,
    port: u16,
    mut commands: mpsc::Receiver<Command>,
    ready: oneshot::Sender<Value>,
    health: Shared,
    recovery: bool,
) {
    let connection = timeout(Duration::from_secs(45), open_session(record, &host, port)).await;
    let (mut server, mut adapter) = match connection {
        Ok(Ok(v)) => v,
        other => {
            let message = match other {
                Ok(Err(e)) => e,
                _ => "本机连接超时，请检查隧道和开发者模式。",
            };
            let v = reply(false, if recovery { "unknown" } else { "idle" }, message);
            replace(&health, v.clone());
            let _ = ready.send(v);
            return;
        }
    };
    let mut location = match timeout(COMMAND_TIMEOUT, DvtLocation::new(&mut server)).await {
        Ok(Ok(c)) => c,
        _ => {
            let v = reply(
                false,
                if recovery { "unknown" } else { "idle" },
                "无法打开定位模拟服务。",
            );
            replace(&health, v.clone());
            let _ = ready.send(v);
            return;
        }
    };
    let v = reply(
        true,
        if recovery { "unknown" } else { "ready" },
        if recovery {
            "服务已连接，请停止并恢复之前的定位。"
        } else {
            "本机定位服务已连接。"
        },
    );
    replace(&health, v.clone());
    let _ = ready.send(v);
    let mut active: Option<(f64, f64)> = None;
    let mut interval = tokio::time::interval(Duration::from_secs(5));
    loop {
        tokio::select! {
            command=commands.recv()=>{
                let Some(command)=command else{return;};
                match command.action {
                    Action::Apply(lat,lon) => {
                        if matches!(timeout(COMMAND_TIMEOUT,location.set(lat,lon)).await,Ok(Ok(()))) {
                            active=Some((lat,lon));
                            let v=reply(true,"active","模拟位置已发送；请在地图中核验。");
                            replace(&health,v.clone());let _=command.reply.send(v);
                        } else {
                            let v=reply(false,"unknown","定位命令未确认，恢复状态未知；请重新连接并停止恢复。");
                            replace(&health,v.clone());let _=command.reply.send(v);return;
                        }
                    }
                    Action::Clear => {
                        // This worker never resumes the refresh loop after a stop request.
                        let sent=matches!(timeout(COMMAND_TIMEOUT,location.stop()).await,Ok(Ok(())));
                        drop(location);
                        // A correlated read-only round trip on the same TCP transport
                        // prevents closing while the no-reply stop is merely queued locally.
                        let delivered=sent && matches!(timeout(COMMAND_TIMEOUT,server.make_channel(LOCATION_SERVICE)).await,Ok(Ok(_)));
                        drop(server);
                        let closed=adapter.close().await.is_ok();
                        drop(adapter);
                        let v=if delivered && closed {
                            reply(true,"stopped_unverified","停止请求已发送，会话已结束；请在地图核验并确认真实位置恢复。")
                        } else {
                            reply(false,"unknown","停止请求的发送或会话关闭未完成，请重连后再次停止并核验地图。")
                        };
                        replace(&health,v.clone());let _=command.reply.send(v);return;
                    }
                }
            }
            _=interval.tick(),if active.is_some()=>{
                if let Some((lat,lon))=active { if !matches!(timeout(COMMAND_TIMEOUT,location.set(lat,lon)).await,Ok(Ok(()))) {replace(&health,reply(false,"unknown","定位会话已中断，恢复状态未知。"));return;} }
            }
        }
    }
}

/// # Safety
/// `request` must point to a valid NUL-terminated UTF-8 JSON string for this call.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cl_request(request: *const c_char) -> *mut c_char {
    let response = std::panic::catch_unwind(|| {
        if request.is_null() {
            return reply(false, "unknown", "请求为空。");
        }
        let input = unsafe { CStr::from_ptr(request) }
            .to_str()
            .ok()
            .and_then(|s| serde_json::from_str::<Value>(s).ok());
        let Some(input) = input else {
            return reply(false, "unknown", "请求格式无效。");
        };
        let engine = ENGINE.get_or_init(Engine::new);
        engine.runtime.block_on(engine.request(input))
    })
    .unwrap_or_else(|_| reply(false, "unknown", "本机服务异常，定位恢复状态未知。"));
    CString::new(response.to_string()).unwrap().into_raw()
}
/// # Safety
/// `response` must be NULL or a pointer returned by cl_request, freed only once.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cl_free(response: *mut c_char) {
    if !response.is_null() {
        drop(unsafe { CString::from_raw(response) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn invalid_requests_do_not_start_network() {
        let e = Engine::new();
        for r in [
            json!({"op":"apply","latitude":91.0,"longitude":0}),
            json!({"op":"apply","latitude":0,"longitude":181.0}),
            json!({"op":"not-supported"}),
        ] {
            assert_eq!(e.runtime.block_on(e.request(r))["ok"], false);
        }
    }
    #[test]
    fn failed_reconnect_preserves_recovery_obligation() {
        let e = Engine::new();
        // A persisted recovery marker must survive even a malformed record;
        // this path fails before any socket can be opened.
        let result = e.runtime.block_on(e.request(json!({
            "op":"connect", "recovery_needed":true, "pairing_record":"invalid"
        })));
        assert_eq!(result["ok"], false);
        assert_eq!(result["state"], "unknown");
        let disconnected = e.runtime.block_on(e.request(json!({"op":"disconnect"})));
        assert_eq!(disconnected["ok"], false);
        assert_eq!(disconnected["state"], "unknown");
        let status = e.runtime.block_on(e.request(json!({"op":"status"})));
        assert_eq!(status["state"], "unknown");
        assert!(e.runtime.block_on(e.state.lock()).recovery_needed);
    }

    #[test]
    fn ready_cache_does_not_satisfy_a_new_connection_check() {
        let e = Engine::new();
        e.runtime.block_on(async {
            let (commands, _receiver) = mpsc::channel(1);
            // The worker remains alive, but its cached ready state cannot prove
            // that the remote tunnel is still connected.
            let task = tokio::spawn(std::future::pending::<()>());
            e.state.lock().await.session = Some(Session {
                commands,
                health: Arc::new(Mutex::new(reply(true, "ready", "cached"))),
                task,
            });
            let result = e
                .request(json!({"op":"connect", "pairing_record":"invalid"}))
                .await;
            assert_eq!(result["ok"], false);
            assert_ne!(result["state"], "ready");
            assert!(e.state.lock().await.session.is_none());
        });
    }

    #[test]
    fn stop_uses_no_reply_selector_and_does_not_wait_for_ack() {
        use idevice::dvt::message::{Message, MessageHeader, PayloadHeader};
        use tokio::io::AsyncWriteExt;
        let e = Engine::new();
        e.runtime.block_on(async {
            let (client, mut peer) = tokio::io::duplex(8192);
            let (observed_tx, observed_rx) = oneshot::channel();
            let (finish_tx, finish_rx) = oneshot::channel();
            let peer_task = tokio::spawn(async move {
                let open = Message::from_reader(&mut peer).await.unwrap();
                assert_eq!(
                    open.data.as_ref().and_then(|v| v.as_string()),
                    Some("_requestChannelWithCode:identifier:")
                );
                let header = open.message_header.serialize();
                let identifier = u32::from_le_bytes(header[16..20].try_into().unwrap());
                let response = Message::new(
                    MessageHeader::new(0, 1, identifier, 1, 0, false),
                    PayloadHeader::default(),
                    None,
                    None,
                )
                .serialize();
                peer.write_all(&response).await.unwrap();
                let stop = Message::from_reader(&mut peer).await.unwrap();
                assert_eq!(
                    stop.data.as_ref().and_then(|v| v.as_string()),
                    Some("stopLocationSimulation")
                );
                assert_eq!(
                    &stop.message_header.serialize()[28..32],
                    &0_u32.to_le_bytes()
                );
                observed_tx.send(()).unwrap();
                // Deliberately keep the connection open without sending a stop reply.
                let _ = finish_rx.await;
            });
            let mut server = RemoteServerClient::new(client);
            let mut location = DvtLocation::new(&mut server).await.unwrap();
            timeout(Duration::from_secs(1), location.stop())
                .await
                .unwrap()
                .unwrap();
            timeout(Duration::from_secs(1), observed_rx)
                .await
                .unwrap()
                .unwrap();
            let _ = finish_tx.send(());
            peer_task.await.unwrap();
        });
    }

    #[test]
    fn stop_requires_user_confirmation_before_clearing_recovery() {
        let e = Engine::new();
        e.runtime.block_on(async {
            let (commands, mut receiver) = mpsc::channel::<Command>(1);
            let task = tokio::spawn(async move {
                let command = receiver.recv().await.unwrap();
                assert!(matches!(command.action, Action::Clear));
                let _ = command
                    .reply
                    .send(reply(true, "stopped_unverified", "stop sent"));
            });
            {
                let mut state = e.state.lock().await;
                state.recovery_needed = true;
                state.session = Some(Session {
                    commands,
                    health: Arc::new(Mutex::new(reply(true, "active", "active"))),
                    task,
                });
            }
            assert_eq!(
                e.request(json!({"op":"confirm_restore"})).await["ok"],
                false
            );
            let stopped = e.request(json!({"op":"clear"})).await;
            assert_eq!(stopped["state"], "stopped_unverified");
            {
                let state = e.state.lock().await;
                assert!(state.recovery_needed && state.stop_sent && state.session.is_none());
            }
            let denied = e.request(json!({"op":"disconnect"})).await;
            assert_eq!(denied["ok"], false);
            assert_eq!(denied["state"], "stopped_unverified");
            assert_eq!(
                e.request(json!({"op":"status"})).await["state"],
                "stopped_unverified"
            );
            let confirmed = e.request(json!({"op":"confirm_restore"})).await;
            assert_eq!(confirmed["ok"], true);
            assert_eq!(confirmed["state"], "idle");
            assert!(!e.state.lock().await.recovery_needed);
            assert_eq!(
                e.request(json!({"op":"confirm_restore"})).await["ok"],
                false
            );
        });
    }

    #[test]
    fn mismatched_device_cannot_connect() {
        let e = Engine::new();
        let record = Record {
            version: 1,
            plist: "".into(),
            peer_identifier: "test".into(),
            peer_irk: B64.encode([1u8; 16]),
            host_name: "test".into(),
        };
        let result=e.runtime.block_on(e.request(json!({"op":"connect","pairing_record":serde_json::to_string(&record).unwrap(),"host":"10.7.0.1","port":1,"service_identifier":"other","auth_tag":"invalid"})));
        assert_eq!(result["ok"], false);
        assert_eq!(result["message"], "发现的设备与本机配对记录不匹配。");
    }
}
