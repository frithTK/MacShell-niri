//! Pure recording selection checks; no capture or system access.

pub mod audio;
pub mod lifecycle;
pub mod niri;
pub mod outputs;
pub mod owned;
pub mod preview;
pub mod validation;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Output {
    pub x: i64,
    pub y: i64,
    pub width: u64,
    pub height: u64,
}

/// Validate global logical coordinates against the selected output. Do not
/// scale or rotate them here: the recording backend handles those transforms.
pub fn geometry(text: &str, output: Output) -> Result<String, &'static str> {
    const INVALID: &str = "Invalid selection. Choose the area again.";
    const OUTSIDE: &str = "The area must fit entirely inside the selected monitor.";
    let (origin, size) = text.split_once(' ').ok_or(INVALID)?;
    let (x, y) = origin.split_once(',').ok_or(INVALID)?;
    let (width, height) = size.split_once('x').ok_or(INVALID)?;
    fn signed(value: &str) -> bool {
        let digits = value.strip_prefix('-').unwrap_or(value);
        !digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit())
    }
    fn unsigned(value: &str) -> bool {
        !value.is_empty() && value.bytes().all(|b| b.is_ascii_digit())
    }
    if !signed(x) || !signed(y) || !unsigned(width) || !unsigned(height) {
        return Err(INVALID);
    }
    let x: i64 = x.parse().map_err(|_| INVALID)?;
    let y: i64 = y.parse().map_err(|_| INVALID)?;
    let width: i64 = width.parse().map_err(|_| INVALID)?;
    let height: i64 = height.parse().map_err(|_| INVALID)?;
    let output_width = i64::try_from(output.width).map_err(|_| OUTSIDE)?;
    let output_height = i64::try_from(output.height).map_err(|_| OUTSIDE)?;
    let right = x.checked_add(width).ok_or(OUTSIDE)?;
    let bottom = y.checked_add(height).ok_or(OUTSIDE)?;
    let output_right = output.x.checked_add(output_width).ok_or(OUTSIDE)?;
    let output_bottom = output.y.checked_add(output_height).ok_or(OUTSIDE)?;
    if width < 2
        || height < 2
        || x < output.x
        || y < output.y
        || right > output_right
        || bottom > output_bottom
    {
        return Err(OUTSIDE);
    }
    Ok(format!("{x},{y} {width}x{height}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    const SCREEN: Output = Output {
        x: -1920,
        y: -100,
        width: 1920,
        height: 1080,
    };
    #[test]
    fn accepts_negative_global_coordinates_and_normalizes_numbers() {
        assert_eq!(
            geometry("-01920,-0100 01920x01080", SCREEN).unwrap(),
            "-1920,-100 1920x1080"
        );
        assert_eq!(geometry("-200,0 100x99", SCREEN).unwrap(), "-200,0 100x99");
    }
    #[test]
    fn rejects_areas_outside_or_too_small() {
        for input in [
            "-1921,0 10x10",
            "-100,0 101x10",
            "-100,-101 10x10",
            "-100,979 10x2",
            "-100,0 1x10",
        ] {
            assert!(geometry(input, SCREEN).is_err(), "{input}");
        }
    }
    #[test]
    fn rejects_malformed_and_overflow_without_panicking() {
        for input in [
            "",
            "+1,2 3x4",
            "1,2 3x4 extra",
            "1,2 -3x4",
            "--1,2 3x4",
            "99999999999999999999999,0 3x3",
        ] {
            assert!(geometry(input, SCREEN).is_err(), "{input}");
        }
        assert!(geometry(
            "0,0 2x2",
            Output {
                x: i64::MAX,
                y: 0,
                width: 1,
                height: 1
            }
        )
        .is_err());
    }
}
