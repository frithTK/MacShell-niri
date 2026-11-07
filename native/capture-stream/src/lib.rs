//! GStreamer frame sampling for window previews. No session or file access.
//!
//! A PipeWire source and a separate converter use one-buffer queues. Sampling
//! the latest frame on demand preserves the final frame of damage-driven streams
//! without encoding unobserved frames. Instances are confined to one thread.
use std::ffi::{c_char, c_int, c_uint, c_void, CString};
use std::marker::PhantomData;
use std::ptr;
use std::rc::Rc;
use std::sync::Once;

pub mod store;

type Ptr = *mut c_void;
#[repr(C)]
struct GError {
    domain: u32,
    code: c_int,
    message: *mut c_char,
}
#[link(name = "gstreamer-1.0")]
extern "C" {
    fn gst_init(argc: Ptr, argv: Ptr);
    fn gst_parse_launch(description: *const c_char, error: *mut *mut GError) -> Ptr;
    fn gst_element_factory_find(name: *const c_char) -> Ptr;
    fn gst_bin_get_by_name(bin: Ptr, name: *const c_char) -> Ptr;
    fn gst_element_set_state(element: Ptr, state: c_int) -> c_int;
    fn gst_element_get_bus(element: Ptr) -> Ptr;
    fn gst_bus_pop_filtered(bus: Ptr, kinds: c_uint) -> Ptr;
    fn gst_object_unref(object: Ptr);
    fn gst_mini_object_unref(object: Ptr);
    fn gst_sample_get_buffer(sample: Ptr) -> Ptr;
    fn gst_sample_get_caps(sample: Ptr) -> Ptr;
    fn gst_buffer_get_size(buffer: Ptr) -> usize;
    fn gst_buffer_extract(buffer: Ptr, offset: usize, data: Ptr, size: usize) -> usize;
    fn gst_caps_get_structure(caps: Ptr, index: c_uint) -> Ptr;
    fn gst_structure_get_int(structure: Ptr, name: *const c_char, value: *mut c_int) -> c_int;
    fn gst_structure_from_string(value: *const c_char, end: Ptr) -> Ptr;
    fn gst_structure_free(structure: Ptr);
}
#[link(name = "gstapp-1.0")]
extern "C" {
    fn gst_app_sink_try_pull_sample(sink: Ptr, timeout: u64) -> Ptr;
    fn gst_app_src_push_sample(source: Ptr, sample: Ptr) -> c_int;
}
#[link(name = "gobject-2.0")]
extern "C" {
    fn g_object_set(object: Ptr, first: *const c_char, ...);
}
#[link(name = "glib-2.0")]
extern "C" {
    fn g_error_free(error: *mut GError);
}

const NULL: c_int = 1;
const PAUSED: c_int = 3;
const PLAYING: c_int = 4;
const ERROR: c_uint = 1 << 1;
static INITIALIZE: Once = Once::new();
fn c(value: &str) -> CString {
    CString::new(value).expect("internally generated GStreamer text")
}

/// Detect missing runtime plugins before selecting the native launcher.
/// This inspects factories only; it does not open a video or audio device.
pub fn available() -> bool {
    INITIALIZE.call_once(|| unsafe { gst_init(ptr::null_mut(), ptr::null_mut()) });
    [
        "pipewiresrc",
        "appsink",
        "appsrc",
        "capssetter",
        "videoscale",
        "videoconvert",
        "pngenc",
    ]
    .iter()
    .all(|name| {
        let factory = unsafe { gst_element_factory_find(c(name).as_ptr()) };
        if factory.is_null() {
            false
        } else {
            unsafe {
                gst_object_unref(factory);
            }
            true
        }
    })
}

struct Element(Ptr);
impl Drop for Element {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe { gst_object_unref(self.0) }
        }
    }
}
struct Sample(Ptr);
impl Drop for Sample {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe { gst_mini_object_unref(self.0) }
        }
    }
}
fn parse(description: &str) -> Result<Element, &'static str> {
    let mut error = ptr::null_mut();
    let pipeline = unsafe { gst_parse_launch(c(description).as_ptr(), &mut error) };
    if !error.is_null() {
        unsafe {
            g_error_free(error);
            if !pipeline.is_null() {
                gst_object_unref(pipeline);
            }
        }
        return Err("Cannot construct preview pipeline.");
    }
    if pipeline.is_null() {
        Err("Cannot construct preview pipeline.")
    } else {
        Ok(Element(pipeline))
    }
}
fn named(pipeline: &Element, name: &str) -> Result<Element, &'static str> {
    let value = unsafe { gst_bin_get_by_name(pipeline.0, c(name).as_ptr()) };
    if value.is_null() {
        Err("Preview pipeline is missing an element.")
    } else {
        Ok(Element(value))
    }
}
fn state(element: &Element, value: c_int) -> Result<(), &'static str> {
    if unsafe { gst_element_set_state(element.0, value) } == 0 {
        Err("Cannot change preview pipeline state.")
    } else {
        Ok(())
    }
}
fn failed(pipeline: &Element) -> bool {
    let bus = unsafe { gst_element_get_bus(pipeline.0) };
    if bus.is_null() {
        return true;
    }
    let msg = unsafe { gst_bus_pop_filtered(bus, ERROR) };
    unsafe {
        gst_object_unref(bus);
        if !msg.is_null() {
            gst_mini_object_unref(msg);
        }
    }
    !msg.is_null()
}

#[derive(Debug)]
pub struct Frame {
    pub png: Vec<u8>,
    pub width: u32,
    pub height: u32,
}
pub struct Pipeline {
    capture: Element,
    converter: Element,
    latest: Element,
    input: Element,
    frames: Element,
    _single_thread: PhantomData<Rc<()>>,
}
impl Pipeline {
    /// Test-only synthetic source, compiled only when explicitly requested.
    #[cfg(feature = "synthetic-test")]
    pub fn synthetic(size: u32) -> Result<Self, &'static str> {
        Self::create("videotestsrc is-live=true ! video/x-raw,width=320,height=240,framerate=15/1 ! appsink name=latest max-buffers=1 drop=true sync=false", size, false)
    }
    /// Connect to an already authorized PipeWire stream; no other node is
    /// selected. Caller owns the ScreenCast session and its privacy lifecycle.
    pub fn pipewire(node: u32, size: u32) -> Result<Self, &'static str> {
        if node == 0 {
            return Err("Invalid PipeWire stream.");
        }
        Self::create(&format!("pipewiresrc name=source path={node} client-name=macshell-preview do-timestamp=true ! video/x-raw ! queue max-size-buffers=1 leaky=downstream ! appsink name=latest max-buffers=1 drop=true sync=false"), size, true)
    }
    fn create(description: &str, size: u32, pipewire: bool) -> Result<Self, &'static str> {
        if !(160..=1024).contains(&size) {
            return Err("Invalid preview size.");
        }
        INITIALIZE.call_once(|| unsafe { gst_init(ptr::null_mut(), ptr::null_mut()) });
        let capture = parse(description)?;
        if pipewire {
            let source = named(&capture, "source")?;
            let props = c("props,application.name=(string)macshell-preview,node.name=(string)macshell-preview,media.type=(string)Video,media.category=(string)Capture,media.role=(string)Screen");
            let structure = unsafe { gst_structure_from_string(props.as_ptr(), ptr::null_mut()) };
            if structure.is_null() {
                return Err("Cannot configure preview stream.");
            }
            unsafe {
                g_object_set(
                    source.0,
                    c("stream-properties").as_ptr(),
                    structure,
                    ptr::null::<c_char>(),
                );
                gst_structure_free(structure);
            }
        }
        let converter = parse(&format!("appsrc name=input format=time is-live=true ! capssetter caps=\"video/x-raw,pixel-aspect-ratio=1/1\" ! videoscale ! video/x-raw,width=(int)[1,{size}],height=(int)[1,{size}],pixel-aspect-ratio=1/1 ! videoconvert ! pngenc compression-level=1 ! appsink name=frames max-buffers=1 drop=true sync=false"))?;
        let latest = named(&capture, "latest")?;
        let input = named(&converter, "input")?;
        let frames = named(&converter, "frames")?;
        if let Err(error) = state(&converter, PLAYING) {
            let _ = state(&converter, NULL);
            return Err(error);
        }
        if let Err(error) = state(&capture, PLAYING) {
            let _ = state(&converter, NULL);
            return Err(error);
        }
        Ok(Self {
            capture,
            converter,
            latest,
            input,
            frames,
            _single_thread: PhantomData,
        })
    }
    pub fn pause(&self) -> Result<(), &'static str> {
        state(&self.capture, PAUSED)
    }
    pub fn resume(&self) -> Result<(), &'static str> {
        state(&self.capture, PLAYING)
    }
    /// Reconnect the same authorized stream if no initial frame arrived.
    pub fn restart(&self) -> Result<(), &'static str> {
        state(&self.capture, NULL)?;
        state(&self.capture, PLAYING)
    }
    /// Submit only the newest capture and take a completed PNG, if available.
    /// Call at the configured cadence and only while a consumer requests frames.
    pub fn poll(&self) -> Result<Option<Frame>, &'static str> {
        if failed(&self.capture) || failed(&self.converter) {
            return Err("Window preview stream failed.");
        }
        let sample = Sample(unsafe { gst_app_sink_try_pull_sample(self.latest.0, 0) });
        #[cfg(feature = "test-diagnostics")]
        if !sample.0.is_null() {
            eprintln!("TEST_CAPTURE_INPUT");
        }
        if !sample.0.is_null() && unsafe { gst_app_src_push_sample(self.input.0, sample.0) } != 0 {
            return Err("Window preview conversion failed.");
        }
        let sample = Sample(unsafe { gst_app_sink_try_pull_sample(self.frames.0, 0) });
        #[cfg(feature = "test-diagnostics")]
        if !sample.0.is_null() {
            eprintln!("TEST_CAPTURE_OUTPUT");
        }
        if sample.0.is_null() {
            return Ok(None);
        }
        let caps = unsafe { gst_sample_get_caps(sample.0) };
        let buffer = unsafe { gst_sample_get_buffer(sample.0) };
        if caps.is_null() || buffer.is_null() {
            return Err("Invalid preview frame.");
        }
        let structure = unsafe { gst_caps_get_structure(caps, 0) };
        if structure.is_null() {
            return Err("Invalid preview frame.");
        }
        let mut width = 0;
        let mut height = 0;
        if unsafe { gst_structure_get_int(structure, c("width").as_ptr(), &mut width) } == 0
            || unsafe { gst_structure_get_int(structure, c("height").as_ptr(), &mut height) } == 0
            || !(1..=1024).contains(&width)
            || !(1..=1024).contains(&height)
        {
            return Err("Invalid preview dimensions.");
        }
        let size = unsafe { gst_buffer_get_size(buffer) };
        if size == 0 || size > 16 * 1024 * 1024 {
            return Err("Invalid preview frame size.");
        }
        let mut png = vec![0u8; size];
        if unsafe { gst_buffer_extract(buffer, 0, png.as_mut_ptr().cast(), size) } != size
            || !png.starts_with(b"\x89PNG\r\n\x1a\n")
        {
            return Err("Invalid preview frame.");
        }
        Ok(Some(Frame {
            png,
            width: width as u32,
            height: height as u32,
        }))
    }
}
impl Drop for Pipeline {
    fn drop(&mut self) {
        let _ = state(&self.capture, NULL);
        let _ = state(&self.converter, NULL);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};
    #[test]
    fn synthetic_video_is_scaled_encoded_and_can_pause() {
        let pipeline = Pipeline::create("videotestsrc is-live=true ! video/x-raw,width=320,height=240,framerate=15/1 ! appsink name=latest max-buffers=1 drop=true sync=false", 160, false).unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        let frame = loop {
            if let Some(frame) = pipeline.poll().unwrap() {
                break frame;
            }
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(20));
        };
        assert!(frame.png.starts_with(b"\x89PNG\r\n\x1a\n"));
        assert!(frame.width <= 160 && frame.height <= 160);
        assert_eq!(
            u32::from_be_bytes(frame.png[16..20].try_into().unwrap()),
            frame.width
        );
        assert_eq!(
            u32::from_be_bytes(frame.png[20..24].try_into().unwrap()),
            frame.height
        );
        pipeline.pause().unwrap();
        pipeline.resume().unwrap();
    }
    #[test]
    fn rejects_untrusted_node_and_bad_size() {
        assert!(Pipeline::pipewire(0, 160).is_err());
        assert!(Pipeline::pipewire(1, 159).is_err());
    }
    #[test]
    fn single_damage_driven_frame_is_not_lost() {
        let pipeline = Pipeline::create("videotestsrc num-buffers=1 is-live=true ! video/x-raw,width=320,height=240 ! appsink name=latest max-buffers=1 drop=true sync=false", 160, false).unwrap();
        // Simulate a delayed UI request: the only frame stays in the latest queue.
        std::thread::sleep(Duration::from_millis(300));
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            if let Some(frame) = pipeline.poll().unwrap() {
                assert!(frame.png.starts_with(b"\x89PNG\r\n\x1a\n"));
                break;
            }
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_millis(20));
        }
    }
}
