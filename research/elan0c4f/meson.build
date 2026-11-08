project('elan0c4f-research', 'c', version: '0.0.1', license: 'LGPL-2.1-or-later',
  default_options: ['c_std=c11', 'warning_level=3', 'werror=true'])

inc = include_directories('include')
usb_dep = dependency('libusb-1.0')
add_project_arguments('-D_POSIX_C_SOURCE=200809L', language: 'c')
core = static_library('elan0c4f', 'src/elan0c4f.c', include_directories: inc)
transport = static_library('elan0c4f-usb', 'src/elan0c4f_usb.c', include_directories: inc, dependencies: usb_dep)
executable('elan-probe', 'src/probe.c', include_directories: inc, link_with: [core, transport], dependencies: usb_dep)
executable('elan-study-bridge', 'src/study_bridge.c', include_directories: inc, link_with: [core, transport], dependencies: usb_dep)
protocol_test = executable('test-protocol', 'tests/test_protocol.c', include_directories: inc, link_with: core)
test('protocol', protocol_test)
