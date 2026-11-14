//! Listen on iPhone: the Mac plays a tune into a paired device instead of
//! its speakers. resonance-remote's design/PROTOCOL.md ("Listening") has the
//! wire format; design/README.md there has the measurements behind the
//! numbers here.
//!
//! The device asks over its TLS connection (`listen.start`) and gets this
//! listener's UDP port and a fresh 32-byte key. Every packet either way is
//! sealed with ChaCha20-Poly1305 under that key: what's playing stays
//! private, and nobody else can point the stream somewhere else, since the
//! device's address is taken only from packets that open.
//!
//! Time is counted in samples: sample `s` is due `s / RATE` seconds after
//! `origin`, the same clock the pongs report. Outputs come and go (an engine
//! change, a switch back from the speakers) while the listener stays, and
//! each new one picks up at the sample the clock has reached, so the
//! device sees a gap, never a jump back.

use std::io::ErrorKind;
use std::net::{SocketAddr, UdpSocket};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::thread;
use std::time::{Duration, Instant};

use aws_lc_rs::aead::{Aad, LessSafeKey, Nonce, UnboundKey, CHACHA20_POLY1305};

/// Opus takes 48 kHz; the engine renders at it while a device listens.
pub(crate) const RATE: u32 = 48_000;
/// 10 ms frames, RESTRICTED_LOWDELAY: 12.5 ms of codec delay, 100 packets a
/// second (opus_bench).
pub(crate) const FRAME: usize = 480;
/// 0.3 Mbit/s with headers; nothing on a home network.
pub(crate) const BITRATE: i32 = 256_000;
/// The device counts as gone after this long without a hello or a ping;
/// it says hello once a second.
const PEER_TIMEOUT: Duration = Duration::from_secs(5);
/// How often the receiving thread looks up from the socket to see whether
/// the listener is still wanted.
const POLL: Duration = Duration::from_millis(250);

/// Packet kinds. Device to Mac: hello and ping. Mac to device: pong and audio.
pub(crate) const HELLO: u8 = 0x01;
pub(crate) const PING: u8 = 0x02;
pub(crate) const PONG: u8 = 0x03;
pub(crate) const AUDIO: u8 = 0x10;

/// The nonce's first four bytes, by direction, so the two directions never
/// share a nonce under the one key.
const FROM_MAC: u32 = 1;
const FROM_DEVICE: u32 = 2;
/// Kind and counter, in the clear and authenticated.
const HEADER: usize = 9;
const TAG: usize = 16;

pub(crate) struct Listener {
    socket: UdpSocket,
    key: LessSafeKey,
    origin: Instant,
    /// Counter for the Mac's packets; each one's nonce.
    sent: AtomicU64,
    peer: Mutex<Peer>,
}

struct Peer {
    addr: Option<SocketAddr>,
    seen: Instant,
    /// The newest counter accepted from the device; older ones are replays.
    counter: u64,
}

impl Listener {
    /// Bind a UDP port on every interface and start answering the device.
    pub(crate) fn open(key: &[u8]) -> Result<Arc<Self>, String> {
        let unbound = UnboundKey::new(&CHACHA20_POLY1305, key)
            .map_err(|_| "The listening key must be 32 bytes.".to_string())?;
        let socket = UdpSocket::bind(("::", 0)).map_err(|e| format!("Couldn't open a port for listening: {e}"))?;
        socket.set_read_timeout(Some(POLL)).map_err(|e| e.to_string())?;
        allow_peer_to_peer(&socket);
        let origin = Instant::now();
        let listener = Arc::new(Self {
            socket,
            key: LessSafeKey::new(unbound),
            origin,
            sent: AtomicU64::new(0),
            peer: Mutex::new(Peer { addr: None, seen: origin, counter: 0 }),
        });
        let weak = Arc::downgrade(&listener);
        let socket = listener.socket.try_clone().map_err(|e| e.to_string())?;
        thread::Builder::new()
            .name("resonance-listen".into())
            .spawn(move || answer(socket, weak))
            .map_err(|e| e.to_string())?;
        Ok(listener)
    }

    pub(crate) fn port(&self) -> u16 {
        self.socket.local_addr().map(|a| a.port()).unwrap_or(0)
    }

    /// Nanoseconds since the stream's origin, the clock pongs report.
    pub(crate) fn now_ns(&self) -> u64 {
        self.origin.elapsed().as_nanos() as u64
    }

    /// When sample `s` is due, in `now_ns` time.
    pub(crate) fn due_ns(s: u64) -> u64 {
        (s as u128 * 1_000_000_000 / RATE as u128) as u64
    }

    /// The first frame an output starting now should send: the next frame
    /// boundary the clock hasn't reached.
    pub(crate) fn next_frame(&self) -> u64 {
        let now = self.now_ns() as u128 * RATE as u128 / 1_000_000_000;
        (now as u64 / FRAME as u64 + 1) * FRAME as u64
    }

    /// The device's address, while it keeps saying hello.
    pub(crate) fn peer(&self) -> Option<SocketAddr> {
        let peer = self.peer.lock().unwrap_or_else(|e| e.into_inner());
        peer.addr.filter(|_| peer.seen.elapsed() < PEER_TIMEOUT)
    }

    /// Send one Opus frame, if a device is there.
    pub(crate) fn send_audio(&self, seq: u32, first_sample: u64, opus: &[u8], out: &mut Vec<u8>) {
        let Some(to) = self.peer() else { return };
        let mut body = [0u8; 30];
        body[0..4].copy_from_slice(&seq.to_le_bytes());
        body[4..12].copy_from_slice(&first_sample.to_le_bytes());
        body[12..20].copy_from_slice(&Self::due_ns(first_sample).to_le_bytes());
        body[20..28].copy_from_slice(&self.now_ns().to_le_bytes());
        body[28..30].copy_from_slice(&(FRAME as u16).to_le_bytes());
        out.clear();
        out.extend_from_slice(&body);
        out.extend_from_slice(opus);
        self.seal_and_send(AUDIO, out, to);
    }

    /// Seals `body` in place (appending the tag) and sends it with its header.
    fn seal_and_send(&self, kind: u8, body: &mut Vec<u8>, to: SocketAddr) {
        let counter = self.sent.fetch_add(1, Ordering::Relaxed) + 1;
        let header = header(kind, counter);
        let Ok(tag) = self
            .key
            .seal_in_place_separate_tag(nonce(FROM_MAC, counter), Aad::from(header), body)
        else {
            return;
        };
        let mut packet = Vec::with_capacity(HEADER + body.len() + TAG);
        packet.extend_from_slice(&header);
        packet.extend_from_slice(body);
        packet.extend_from_slice(tag.as_ref());
        let _ = self.socket.send_to(&packet, to);
    }

    /// Opens a device's packet in place: its kind and body, or None if it
    /// isn't from the device holding the key, or is a replay.
    fn open_packet<'a>(&self, packet: &'a mut [u8]) -> Option<(u8, &'a [u8])> {
        if packet.len() < HEADER + TAG {
            return None;
        }
        let (head, rest) = packet.split_at_mut(HEADER);
        let kind = head[0];
        let counter = u64::from_le_bytes(head[1..9].try_into().ok()?);
        let header: [u8; HEADER] = head.try_into().ok()?;
        let body = self
            .key
            .open_in_place(nonce(FROM_DEVICE, counter), Aad::from(header), rest)
            .ok()?;
        let mut peer = self.peer.lock().unwrap_or_else(|e| e.into_inner());
        if counter <= peer.counter {
            return None;
        }
        peer.counter = counter;
        Some((kind, body))
    }
}

/// The receiving thread: takes the device's address from its hellos and
/// pings, and answers pings at once. Ends when the listener is dropped.
fn answer(socket: UdpSocket, listener: Weak<Listener>) {
    let mut buf = [0u8; 2048];
    loop {
        let received = socket.recv_from(&mut buf);
        let Some(listener) = listener.upgrade() else { return };
        let (len, from) = match received {
            Ok(got) => got,
            Err(e) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut | ErrorKind::Interrupted) => continue,
            Err(e) => {
                eprintln!("[listen] receive failed: {e}");
                thread::sleep(POLL);
                continue;
            }
        };
        let now = listener.now_ns();
        let Some((kind, body)) = listener.open_packet(&mut buf[..len]) else { continue };
        let reply = match kind {
            HELLO => None,
            PING if body.len() >= 8 => {
                let mut pong = Vec::with_capacity(16 + TAG);
                pong.extend_from_slice(&body[..8]);
                pong.extend_from_slice(&now.to_le_bytes());
                Some(pong)
            }
            _ => continue,
        };
        {
            let mut peer = listener.peer.lock().unwrap_or_else(|e| e.into_inner());
            if peer.addr != Some(from) {
                eprintln!("[listen] device at {from}");
            }
            peer.addr = Some(from);
            peer.seen = Instant::now();
        }
        if let Some(mut pong) = reply {
            listener.seal_and_send(PONG, &mut pong, from);
        }
    }
}

fn header(kind: u8, counter: u64) -> [u8; HEADER] {
    let mut header = [0u8; HEADER];
    header[0] = kind;
    header[1..].copy_from_slice(&counter.to_le_bytes());
    header
}

fn nonce(direction: u32, counter: u64) -> Nonce {
    let mut bytes = [0u8; 12];
    bytes[..4].copy_from_slice(&direction.to_le_bytes());
    bytes[4..].copy_from_slice(&counter.to_le_bytes());
    Nonce::assume_unique_for_key(bytes)
}

/// Lets a device reach the port over peer-to-peer Wi-Fi too, as the TLS
/// listener allows; without it the socket ignores the AWDL interface.
fn allow_peer_to_peer(socket: &UdpSocket) {
    use std::os::fd::AsRawFd;
    const SO_RECV_ANYIF: libc::c_int = 0x1104;
    let on: libc::c_int = 1;
    unsafe {
        libc::setsockopt(
            socket.as_raw_fd(),
            libc::SOL_SOCKET,
            SO_RECV_ANYIF,
            &on as *const libc::c_int as *const libc::c_void,
            std::mem::size_of::<libc::c_int>() as libc::socklen_t,
        );
    }
}

/// A device's end of the stream, for tests here and in the player.
#[cfg(test)]
pub(crate) mod testing {
    use super::*;

    /// A device's side, enough to test against: seals with the device's
    /// direction and opens the Mac's.
    pub(crate) struct Device {
        key: LessSafeKey,
        pub socket: UdpSocket,
        counter: u64,
    }

    impl Device {
        pub(crate) fn new(key: &[u8]) -> Self {
            let socket = UdpSocket::bind(("::1", 0)).unwrap();
            socket.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
            Self {
                key: LessSafeKey::new(UnboundKey::new(&CHACHA20_POLY1305, key).unwrap()),
                socket,
                counter: 0,
            }
        }

        pub(crate) fn packet(&mut self, kind: u8, body: &[u8]) -> Vec<u8> {
            self.counter += 1;
            let header = header(kind, self.counter);
            let mut sealed = body.to_vec();
            let tag = self
                .key
                .seal_in_place_separate_tag(nonce(FROM_DEVICE, self.counter), Aad::from(header), &mut sealed)
                .unwrap();
            [&header[..], &sealed, tag.as_ref()].concat()
        }

        pub(crate) fn send(&self, packet: &[u8], port: u16) {
            self.socket.send_to(packet, ("::1", port)).unwrap();
        }

        pub(crate) fn receive(&self) -> Option<(u8, Vec<u8>)> {
            let mut buf = [0u8; 2048];
            let (len, _) = self.socket.recv_from(&mut buf).ok()?;
            let header: [u8; HEADER] = buf[..HEADER].try_into().unwrap();
            let counter = u64::from_le_bytes(header[1..9].try_into().unwrap());
            let body = self
                .key
                .open_in_place(nonce(FROM_MAC, counter), Aad::from(header), &mut buf[HEADER..len])
                .ok()?;
            Some((header[0], body.to_vec()))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::testing::Device;
    use super::*;

    #[test]
    fn a_ping_gets_a_pong_and_audio_follows() {
        let key = [7u8; 32];
        let listener = Listener::open(&key).unwrap();
        let mut device = Device::new(&key);
        let ping = device.packet(PING, &42u64.to_le_bytes());
        device.send(&ping, listener.port());
        let (kind, body) = device.receive().expect("a pong");
        assert_eq!(kind, PONG);
        assert_eq!(u64::from_le_bytes(body[..8].try_into().unwrap()), 42);
        assert!(listener.peer().is_some());

        let mut out = Vec::new();
        listener.send_audio(3, 1440, b"opus", &mut out);
        let (kind, body) = device.receive().expect("audio");
        assert_eq!(kind, AUDIO);
        assert_eq!(u32::from_le_bytes(body[0..4].try_into().unwrap()), 3);
        assert_eq!(u64::from_le_bytes(body[4..12].try_into().unwrap()), 1440);
        assert_eq!(u64::from_le_bytes(body[12..20].try_into().unwrap()), 30_000_000);
        assert_eq!(&body[30..], b"opus");
    }

    /// Someone without the key can't take the stream, and a recorded hello
    /// can't be played back.
    #[test]
    fn a_stranger_or_a_replay_gets_nothing() {
        let listener = Listener::open(&[7u8; 32]).unwrap();
        let mut stranger = Device::new(&[8u8; 32]);
        let hello = stranger.packet(HELLO, &[]);
        stranger.send(&hello, listener.port());
        thread::sleep(Duration::from_millis(100));
        assert!(listener.peer().is_none());

        let mut device = Device::new(&[7u8; 32]);
        let ping = device.packet(PING, &1u64.to_le_bytes());
        device.send(&ping, listener.port());
        assert!(device.receive().is_some());
        device.send(&ping, listener.port());
        device.socket.set_read_timeout(Some(Duration::from_millis(200))).unwrap();
        assert!(device.receive().is_none(), "a replayed ping was answered");
    }

    #[test]
    fn frames_start_on_a_boundary_ahead_of_the_clock() {
        let listener = Listener::open(&[1u8; 32]).unwrap();
        thread::sleep(Duration::from_millis(25));
        let next = listener.next_frame();
        assert_eq!(next % FRAME as u64, 0);
        assert!(Listener::due_ns(next) > listener.now_ns());
        assert!(next >= 1440);
    }

    #[test]
    fn the_thread_ends_with_the_listener() {
        let listener = Listener::open(&[1u8; 32]).unwrap();
        let weak = Arc::downgrade(&listener);
        drop(listener);
        thread::sleep(POLL * 2);
        assert!(weak.upgrade().is_none());
    }
}
