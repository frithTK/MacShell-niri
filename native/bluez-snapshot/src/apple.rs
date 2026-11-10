//! Apple BLE proximity pairing (company 0x004C, type 0x07) battery nibbles.
//!
//! Layout matches OpenPods / Continuity: 10% steps, 0xF unknown. Classic
//! Battery1 remains preferred when BlueZ exposes it.
const APPLE: u16 = 0x004C;
const PROXIMITY: u8 = 0x07;
const SINGLE_NIBBLE: [u8; 2] = [0x09, 0x0A];
const SINGLE_MODEL: [u16; 4] = [0x0520, 0x1020, 0x0620, 0x0320];

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct AppleBattery {
    pub left: i32,
    pub right: i32,
    pub case: i32,
    pub battery: i32,
    pub charging: bool,
}

pub fn is_apple_audio(modalias: &str, name: &str) -> bool {
    let folded = modalias.to_ascii_uppercase();
    if folded.contains("V004C") {
        return true;
    }
    let name = name.to_ascii_lowercase();
    name.contains("airpods") || name.contains("beats") || name.contains("powerbeats")
}

pub fn parse(payload: &[u8]) -> Option<AppleBattery> {
    if payload.len() < 8 || payload[0] != PROXIMITY {
        return None;
    }
    let flip = (payload[5] >> 4) & 0x02 == 0;
    let high = payload[6] >> 4;
    let low = payload[6] & 0x0F;
    let left_raw = if flip { high } else { low };
    let right_raw = if flip { low } else { high };
    let charge = payload[7] >> 4;
    let case_raw = payload[7] & 0x0F;
    let charge_left = (charge & if flip { 0b10 } else { 0b01 }) != 0;
    let charge_right = (charge & if flip { 0b01 } else { 0b10 }) != 0;
    let charge_case = (charge & 0b100) != 0;
    let charge_single = (charge & 0b01) != 0;
    let model = u16::from(payload[3]) << 8 | u16::from(payload[4]);
    let single = SINGLE_NIBBLE.contains(&(payload[3] & 0x0F)) || SINGLE_MODEL.contains(&model);
    if single {
        let battery = nibble(low);
        return (battery >= 0).then_some(AppleBattery {
            battery,
            charging: charge_single,
            ..AppleBattery::default()
        });
    }
    let left = nibble(left_raw);
    let right = nibble(right_raw);
    let case = nibble(case_raw);
    let mut charging = false;
    if left >= 0 {
        charging |= charge_left;
    }
    if right >= 0 {
        charging |= charge_right;
    }
    if case >= 0 {
        charging |= charge_case;
    }
    let pods = [left, right];
    let battery = pods.into_iter().filter(|v| *v >= 0).min().unwrap_or(case);
    (battery >= 0).then_some(AppleBattery {
        left,
        right,
        case,
        battery,
        charging,
    })
}

pub fn from_company(company: u16, payload: &[u8]) -> Option<AppleBattery> {
    (company == APPLE).then(|| parse(payload)).flatten()
}

/// AACP control-channel battery frame (`04 00 04 00 04 00 …`).
/// Layout matches PacketLogger captures: count, then five-byte component
/// records (id, 0x01, level 0–100, status, 0x01). Right=0x02, left=0x04,
/// case=0x08; status 0x01 charging, 0x02 discharging, 0x04 disconnected.
pub fn parse_aap(frame: &[u8]) -> Option<AppleBattery> {
    if frame.len() < 8 {
        return None;
    }
    for start in 0..=frame.len() - 8 {
        if frame[start..start + 4] == [0x04, 0x00, 0x04, 0x00] && frame[start + 4] == 0x04 {
            if let Some(parsed) = parse_aap_at(&frame[start..]) {
                return Some(parsed);
            }
        }
    }
    None
}

fn parse_aap_at(frame: &[u8]) -> Option<AppleBattery> {
    if frame.len() < 8 || frame[..4] != [0x04, 0x00, 0x04, 0x00] || frame[4] != 0x04 {
        return None;
    }
    let count = usize::from(frame[6]);
    if count == 0 || count > 4 || frame.len() < 7 + count * 5 {
        return None;
    }
    let mut left = -1;
    let mut right = -1;
    let mut case = -1;
    let mut single = -1;
    let mut charging = false;
    for index in 0..count {
        let rec = &frame[7 + index * 5..7 + (index + 1) * 5];
        if rec[1] != 0x01 || rec[4] != 0x01 {
            continue;
        }
        let status = rec[3];
        if status == 0x04 {
            continue;
        }
        let level = i32::from(rec[2]);
        if !(0..=100).contains(&level) {
            continue;
        }
        charging |= status == 0x01;
        match rec[0] {
            0x02 => right = level,
            0x04 => left = level,
            0x08 => case = level,
            _ => single = level,
        }
    }
    let pods = [left, right];
    let battery = pods
        .into_iter()
        .filter(|v| *v >= 0)
        .min()
        .unwrap_or(if case >= 0 { case } else { single });
    (battery >= 0).then_some(AppleBattery {
        left,
        right,
        case,
        battery,
        charging,
    })
}

fn nibble(value: u8) -> i32 {
    if value <= 10 {
        i32::from(value) * 10
    } else {
        -1
    }
}

impl AppleBattery {
    pub fn merge_into(
        &self,
        battery: &mut i32,
        left: &mut i32,
        right: &mut i32,
        case: &mut i32,
        charging: &mut bool,
    ) {
        if *left < 0 {
            *left = self.left;
        }
        if *right < 0 {
            *right = self.right;
        }
        if *case < 0 {
            *case = self.case;
        }
        if *battery < 0 {
            *battery = self.battery;
        }
        *charging |= self.charging;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pro_flip_left80_right70_case50(charge: u8) -> Vec<u8> {
        vec![0x07, 0x19, 0x01, 0x0E, 0x20, 0x00, 0x87, charge]
    }

    #[test]
    fn proximity_pair_decodes_left_right_case_in_ten_percent_steps() {
        let parsed = parse(&pro_flip_left80_right70_case50(0x05)).unwrap();
        assert_eq!(
            parsed,
            AppleBattery {
                left: 80,
                right: 70,
                case: 50,
                battery: 70,
                charging: false,
            }
        );
    }

    #[test]
    fn charging_bits_follow_the_flip_flag() {
        let parsed = parse(&pro_flip_left80_right70_case50(0x25)).unwrap();
        assert!(parsed.charging);
        let unflipped = vec![0x07, 0x19, 0x01, 0x0E, 0x20, 0x20, 0x78, 0x15];
        let parsed = parse(&unflipped).unwrap();
        assert_eq!((parsed.left, parsed.right, parsed.case), (80, 70, 50));
        assert!(parsed.charging);
    }

    #[test]
    fn unknown_nibbles_are_omitted_and_empty_payloads_are_ignored() {
        assert!(parse(&[0x07, 0x19, 0x01, 0x0E, 0x20, 0x00, 0xFF, 0x0F]).is_none());
        assert!(parse(&[0x10, 0x19, 0x01, 0x0E, 0x20, 0x00, 0x87, 0x05]).is_none());
        assert!(parse(&[0x07, 0x19]).is_none());
        assert!(from_company(0x0075, &[0x07, 0x19, 0x01, 0x0E, 0x20, 0x00, 0x87, 0x05]).is_none());
    }

    #[test]
    fn airpods_max_uses_the_single_bud_nibble() {
        let parsed = parse(&[0x07, 0x19, 0x01, 0x0A, 0x20, 0x00, 0x09, 0x10]).unwrap();
        assert_eq!(
            parsed,
            AppleBattery {
                battery: 90,
                charging: true,
                ..AppleBattery::default()
            }
        );
    }

    #[test]
    fn apple_audio_matches_modalias_or_product_name() {
        assert!(is_apple_audio(
            "bluetooth:v004Cp2027d215C",
            "COLE BENNETT 2"
        ));
        assert!(is_apple_audio("", "AirPods Pro"));
        assert!(!is_apple_audio(
            "bluetooth:v045Ep02E0d0001",
            "Xbox Wireless Controller"
        ));
    }

    #[test]
    fn aap_battery_frame_decodes_left_right_case_percent() {
        let parsed = parse_aap(&[
            0x04, 0x00, 0x04, 0x00, 0x04, 0x00, 0x03, 0x04, 0x01, 0x62, 0x02, 0x01, 0x02, 0x01,
            0x64, 0x01, 0x01, 0x08, 0x01, 0x4F, 0x02, 0x01,
        ])
        .unwrap();
        assert_eq!(
            parsed,
            AppleBattery {
                left: 98,
                right: 100,
                case: 79,
                battery: 98,
                charging: true,
            }
        );
    }

    #[test]
    fn aap_disconnected_component_is_omitted_and_bad_frames_are_ignored() {
        let parsed = parse_aap(&[
            0x04, 0x00, 0x04, 0x00, 0x04, 0x00, 0x02, 0x04, 0x01, 0x32, 0x02, 0x01, 0x02, 0x01,
            0x00, 0x04, 0x01,
        ])
        .unwrap();
        assert_eq!((parsed.left, parsed.right, parsed.battery), (50, -1, 50));
        assert!(!parsed.charging);
        assert!(parse_aap(&[0x04, 0x00, 0x04, 0x00, 0x06, 0x00, 0x00, 0x02]).is_none());
        assert!(parse_aap(&[0x04, 0x00, 0x04, 0x00, 0x04, 0x00]).is_none());
        let nested = [
            0x00, 0x00, 0x04, 0x00, 0x01, 0x00, 0x02, 0x00, 0x04, 0x00, 0x04, 0x00, 0x04, 0x00,
            0x03, 0x04, 0x01, 0x62, 0x02, 0x01, 0x02, 0x01, 0x64, 0x01, 0x01, 0x08, 0x01, 0x4F,
            0x02, 0x01,
        ];
        let parsed = parse_aap(&nested).unwrap();
        assert_eq!((parsed.left, parsed.right, parsed.case), (98, 100, 79));
    }
}
