//! The About screen's machine-code monitor. Programs get private RAM and a
//! fresh PAL 6581, with a fixed cycle budget and no access to the player.

use std::collections::HashMap;
use std::mem::discriminant;

use mos6502::Variant;
use mos6502::cpu::CPU;
use mos6502::instruction::{AddressingMode, Nmos6502};
use mos6502::memory::Bus;
use resid::{ChipModel, SamplingMethod, Sid};

const ORIGIN: u16 = 0xC000;
const CLOCK: u32 = 985_248;
const RATE: u32 = 44_100;
const MAX_SOURCE: usize = 8192;
const MAX_CYCLES: u64 = 2 * CLOCK as u64;
const RETURN_TO_MONITOR: u16 = ORIGIN - 1;

#[derive(Debug, uniffi::Error)]
pub enum SidMonitorError {
    Failed { message: String },
}

impl std::fmt::Display for SidMonitorError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Failed { message } => f.write_str(message),
        }
    }
}

impl std::error::Error for SidMonitorError {}

impl From<String> for SidMonitorError {
    fn from(message: String) -> Self {
        Self::Failed { message }
    }
}

#[uniffi::export(async_runtime = "tokio")]
pub async fn render_sid_program(source: String) -> Result<Vec<u8>, SidMonitorError> {
    tokio::task::spawn_blocking(move || render(&assemble(&source)?))
        .await
        .map_err(|_| "SID RENDER FAILED".to_owned())?
        .map_err(Into::into)
}

fn number(text: &str) -> Option<u16> {
    if let Some(hex) = text.strip_prefix('$') {
        u16::from_str_radix(hex, 16).ok()
    } else if let Some(binary) = text.strip_prefix('%') {
        u16::from_str_radix(binary, 2).ok()
    } else {
        text.parse().ok()
    }
}

fn is_label(text: &str) -> bool {
    text.starts_with(|c: char| c.is_ascii_alphabetic() || c == '_')
        && text.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
}

// Select a form from the CPU's own opcode table. For literal addresses, prefer
// zero page if the instruction supports it. Labels are in $C000 and above.
fn operand_forms(operand: &str, relative: bool) -> Option<(&str, &'static [AddressingMode])> {
    use AddressingMode::*;
    Some(if operand.is_empty() {
        ("", &[Implied, Accumulator])
    } else if relative {
        (operand, &[Relative])
    } else if let Some(value) = operand.strip_prefix('#') {
        (value, &[Immediate])
    } else if let Some(value) = operand.strip_prefix('(') {
        if let Some(address) = value.strip_suffix(",X)") {
            (address, &[IndexedIndirectX])
        } else if let Some(address) = value.strip_suffix("),Y") {
            (address, &[IndirectIndexedY])
        } else {
            (value.strip_suffix(')')?, &[BuggyIndirect])
        }
    } else {
        let (address, index) = operand.split_once(',').unwrap_or((operand, ""));
        let byte = number(address).is_some_and(|value| value <= 0xFF);
        match (address, index, byte) {
            ("A", "", _) => (address, &[Accumulator, Absolute]),
            (_, "", true) => (address, &[ZeroPage, Absolute]),
            (_, "X", true) => (address, &[ZeroPageX, AbsoluteX]),
            (_, "Y", true) => (address, &[ZeroPageY, AbsoluteY]),
            (_, "", false) => (address, &[Absolute]),
            (_, "X", false) => (address, &[AbsoluteX]),
            (_, "Y", false) => (address, &[AbsoluteY]),
            _ => return None,
        }
    })
}

fn assemble(source: &str) -> Result<Vec<u8>, String> {
    if source.len() > MAX_SOURCE || !source.is_ascii() {
        return Err("PROGRAM MUST BE ASCII AND AT MOST 8 KB".into());
    }
    let source = source.to_ascii_uppercase();
    let mut labels = HashMap::new();
    let mut ops = Vec::new();
    let mut address = ORIGIN;
    let opcodes: Vec<_> = (0..=255)
        // The NMOS decoder also recognizes the unofficial aliases for NOP
        // and immediate SBC. Assemble the documented encodings.
        .filter(|byte| !matches!(byte, 0x1A | 0x3A | 0x5A | 0x7A | 0xDA | 0xFA | 0xEB))
        .filter_map(|byte| {
            let (instruction, mode) = Nmos6502::decode(byte)?;
            Some((format!("{instruction:?}").to_ascii_uppercase(), mode, byte))
        })
        .collect();

    // Pass one lays out the program. Pass two resolves branch/jump labels.
    for (i, source_line) in source.lines().enumerate() {
        let line = i + 1;
        let error = |message| format!("LINE {line}: {message}");
        let mut code = source_line.split(';').next().unwrap_or("").trim();
        if let Some((label, rest)) = code.split_once(':') {
            let label = label.trim();
            if !is_label(label) {
                return Err(error("INVALID LABEL"));
            }
            if labels.insert(label, address).is_some() {
                return Err(error("DUPLICATE LABEL"));
            }
            code = rest.trim();
        }
        if code.is_empty() {
            continue;
        }
        if let Some(addressed) = code.strip_prefix("A ") {
            let (location, instruction) = addressed
                .trim_start()
                .split_once(|c: char| c.is_ascii_whitespace())
                .ok_or_else(|| error("EXPECTED A C000 INSTRUCTION"))?;
            if u16::from_str_radix(location.trim_start_matches('$'), 16) != Ok(address) {
                return Err(format!("LINE {line}: NEXT ADDRESS IS ${address:04X}"));
            }
            code = instruction.trim_start();
        }
        let (mnemonic, operand) = code
            .split_once(|c: char| c.is_ascii_whitespace())
            .unwrap_or((code, ""));
        let operand = operand.trim();
        // Spaces around an index or parentheses are allowed.
        let operand = operand.replace([' ', '\t'], "");
        let matching: Vec<_> = opcodes
            .iter()
            .filter(|(name, _, _)| name == mnemonic)
            .collect();
        if matching.is_empty() || mnemonic == "JAM" {
            return Err(error("UNKNOWN OPCODE"));
        }
        let relative = matching
            .iter()
            .any(|(_, mode, _)| matches!(mode, AddressingMode::Relative));
        let (value, modes) =
            operand_forms(&operand, relative).ok_or_else(|| error("INVALID OPERAND"))?;
        let (mode, opcode) = modes
            .iter()
            .find_map(|wanted| {
                matching.iter().find_map(|(_, mode, byte)| {
                    (discriminant(mode) == discriminant(wanted)).then_some((*mode, *byte))
                })
            })
            .ok_or_else(|| error("INVALID ADDRESSING MODE"))?;
        ops.push((line, address, opcode, mode, value.to_owned()));
        address += 1 + mode.extra_bytes();
    }
    if ops.is_empty() {
        return Err("ENTER A PROGRAM OR TRY DEMO".into());
    }

    let mut bytes = Vec::with_capacity((address - ORIGIN) as usize);
    for (line, address, opcode, mode, operand) in ops {
        bytes.push(opcode);
        if mode.extra_bytes() == 0 {
            continue;
        }
        let value = number(&operand)
            .or_else(|| labels.get(operand.as_str()).copied())
            .ok_or_else(|| format!("LINE {line}: UNKNOWN VALUE {operand}"))?;
        match mode {
            AddressingMode::Relative => {
                let offset = i32::from(value) - i32::from(address + 2);
                let byte =
                    i8::try_from(offset).map_err(|_| format!("LINE {line}: BRANCH TOO FAR"))?;
                bytes.push(byte as u8);
            }
            _ if mode.extra_bytes() == 1 => {
                let byte =
                    u8::try_from(value).map_err(|_| format!("LINE {line}: EXPECTED A BYTE"))?;
                bytes.push(byte);
            }
            _ => bytes.extend(value.to_le_bytes()),
        }
    }
    Ok(bytes)
}

struct MonitorBus {
    ram: Vec<u8>,
    sid: Sid,
    pending: Vec<(u8, u8)>,
}

impl Bus for MonitorBus {
    fn get_byte(&mut self, address: u16) -> u8 {
        match address {
            0xD400..=0xD41F => self.sid.read((address - 0xD400) as u8),
            _ => self.ram[address as usize],
        }
    }

    fn set_byte(&mut self, address: u16, value: u8) {
        match address {
            0xD400..=0xD418 => self.pending.push(((address - 0xD400) as u8, value)),
            0xD419..=0xD41F => {}
            _ => self.ram[address as usize] = value,
        }
    }
}

fn render(program: &[u8]) -> Result<Vec<u8>, String> {
    let mut bus = MonitorBus {
        ram: vec![0; 0x10000],
        sid: Sid::new(ChipModel::Mos6581),
        pending: Vec::with_capacity(2),
    };
    bus.sid
        .set_sampling_parameters(SamplingMethod::Resample, CLOCK, RATE);
    let end = ORIGIN + program.len() as u16;
    bus.ram[ORIGIN as usize..end as usize].copy_from_slice(program);
    // The top-level RTS returns here. Nested JSR/RTS use the real 6502 stack.
    bus.set_word(0x01FE, RETURN_TO_MONITOR - 1);
    let mut cpu = CPU::new(bus, Nmos6502);
    cpu.registers.program_counter = ORIGIN;
    // Start as if called by a JSR from the monitor.
    cpu.registers.stack_pointer.0 = 0xFD;

    let mut samples = Vec::new();
    let mut scratch = [0; 2048];
    let mut wrote_sid = false;
    loop {
        let pc = cpu.registers.program_counter;
        if pc == RETURN_TO_MONITOR || pc == end {
            break;
        }
        if !(ORIGIN..end).contains(&pc) {
            return Err(format!("EXECUTION LEFT PROGRAM AT ${pc:04X}"));
        }
        if cpu.memory.ram[pc as usize] == 0x00 {
            break; // BRK returns to the monitor.
        }
        let before = cpu.cycles;
        if before >= MAX_CYCLES {
            return Err("TIME LIMIT. END WITH RTS OR BRK".into());
        }
        if !cpu.single_step() {
            return Err(format!("CPU STOPPED AT ${pc:04X}"));
        }
        sample(
            &mut cpu.memory.sid,
            (cpu.cycles - before) as u32,
            &mut scratch,
            &mut samples,
        );
        for (reg, value) in cpu.memory.pending.drain(..) {
            cpu.memory.sid.write(reg, value);
            wrote_sid = true;
        }
    }
    if !wrote_sid {
        return Err("NO WRITES TO SID AT $D400-$D418".into());
    }
    // Let the final note ring, then drop all three gates so the chip can release.
    sample(&mut cpu.memory.sid, CLOCK / 2, &mut scratch, &mut samples);
    let registers = cpu.memory.sid.read_state().sid_register;
    for reg in [4, 11, 18] {
        let control = registers[reg];
        cpu.memory.sid.write(reg as u8, control & !1);
    }
    sample(&mut cpu.memory.sid, CLOCK / 4, &mut scratch, &mut samples);
    Ok(wav(samples))
}

fn sample(sid: &mut Sid, mut cycles: u32, scratch: &mut [i16], output: &mut Vec<i16>) {
    while cycles != 0 {
        let (count, leftover) = sid.sample(cycles, scratch, 1);
        output.extend_from_slice(&scratch[..count]);
        cycles = leftover;
    }
}

fn wav(samples: Vec<i16>) -> Vec<u8> {
    let size = (samples.len() * 2) as u32;
    let mut output = Vec::with_capacity(44 + size as usize);
    output.extend(b"RIFF");
    output.extend((36 + size).to_le_bytes());
    output.extend(b"WAVEfmt ");
    output.extend(16u32.to_le_bytes());
    output.extend([1, 0, 1, 0]); // PCM, mono
    output.extend(RATE.to_le_bytes());
    output.extend((RATE * 2).to_le_bytes());
    output.extend([2, 0, 16, 0]); // two bytes per frame, 16 bits
    output.extend(b"data");
    output.extend(size.to_le_bytes());
    let fade = (RATE / 100) as usize;
    let len = samples.len();
    let mut dc = f32::from(samples.first().copied().unwrap_or(0));
    for (i, sample) in samples.into_iter().enumerate() {
        let signal = f32::from(sample) - dc;
        dc += 0.003 * signal;
        let gain = i.min(len - 1 - i).min(fade) as f32 / fade as f32;
        output.extend(((signal * gain) as i16).to_le_bytes());
    }
    output
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn assembles_addressed_input_branches_and_subroutines() {
        let source = "A C000 LDX #3\nloop: DEX\nBNE loop\nJSR tone\nRTS\ntone: STX $D418\nRTS";
        let program = assemble(source).unwrap();
        assert_eq!(assemble("NOP\nSBC #1").unwrap(), [0xEA, 0xE9, 1]);
        assert_eq!(
            program,
            [
                0xA2, 3, 0xCA, 0xD0, 0xFD, 0x20, 9, 0xC0, 0x60, 0x8E, 0x18, 0xD4, 0x60
            ]
        );
        assert!(render(&program).is_ok());
        assert_eq!(
            assemble("A C001 LDA #$0F").unwrap_err(),
            "LINE 1: NEXT ADDRESS IS $C000"
        );
    }

    #[test]
    fn real_sid_writes_produce_audible_pcm() {
        let source = "LDA #$0F\nSTA $D418\nLDA #$1D\nSTA $D401\nLDA #$A8\nSTA $D406\nLDA #$21\nSTA $D404\nRTS";
        let audio = render(&assemble(source).unwrap()).unwrap();
        assert_eq!(&audio[..4], b"RIFF");
        let peak = audio[44..]
            .chunks_exact(2)
            .map(|bytes| i16::from_le_bytes([bytes[0], bytes[1]]).unsigned_abs())
            .max()
            .unwrap();
        assert!(peak > 256, "SID preview was silent or too quiet: {peak}");
    }

    #[test]
    fn rejects_invalid_programs_and_limits_infinite_loops() {
        assert_eq!(
            assemble("STA #$FF").unwrap_err(),
            "LINE 1: INVALID ADDRESSING MODE"
        );
        assert_eq!(
            render(&assemble("RTS").unwrap()).unwrap_err(),
            "NO WRITES TO SID AT $D400-$D418"
        );
        assert_eq!(
            render(&assemble("HERE: JMP HERE").unwrap()).unwrap_err(),
            "TIME LIMIT. END WITH RTS OR BRK"
        );
    }
}
