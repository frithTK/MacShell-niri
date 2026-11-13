import QtQuick
import QtTest
import "../../MacShell/AboutState.js" as About

TestCase {
    name: "About"
    function test_os_cpu_memory_and_dmi() {
        compare(About.osName("NAME=Arch\nPRETTY_NAME=\"CachyOS\"\n"), "CachyOS");
        var cpu = About.parseCpu("processor\t: 0\nmodel name\t: 12th Gen Intel(R) Core(TM) i5-12450H\nprocessor\t: 1\n");
        compare(cpu.model, "12th Gen Intel Core i5-12450H");
        compare(cpu.cores, 2);
        compare(About.memoryLabel(32553904 * 1024), "32 GB");
        compare(About.computerName("Acer", "Aspire A515-57", "box"), "Acer Aspire A515-57");
        compare(About.computerName("System manufacturer", "To be filled by O.E.M.", "box"), "box");
    }
    function test_gpu_niri_and_display() {
        compare(About.parseGpu("DRIVER=i915\nPCI_ID=8086:46A3\n"), "Intel (i915)");
        compare(About.parseGpu("DEVTYPE=drm_minor\nDRIVER=i915\n---\nDRIVER=i915\nPCI_ID=8086:46A3\n"), "Intel (i915)");
        compare(About.niriLabel("niri 26.04 (v26.04-276-g59351300)\n"), "niri 26.04");
        compare(About.displayLine([{name: "eDP-1", modeWidth: 1920, modeHeight: 1080, refreshRate: 60}]), "eDP-1 · 1920×1080 @ 60 Hz");
        var snap = About.snapshot({
            osRelease: "PRETTY_NAME=\"CachyOS\"\n",
            hostname: "frith-cachy\n",
            kernel: "7.3.3-1-cachyos",
            cpuinfo: "processor : 0\nmodel name : Intel(R) Core(TM) i5\n",
            meminfo: "MemTotal: 32553904 kB\n",
            dmiVendor: "Acer",
            dmiProduct: "Aspire A515-57",
            drm: "DRIVER=i915\nPCI_ID=8086:46A3\n",
            niriVersion: "niri 26.04 (v26.04)",
            version: "1.2.5\n"
        });
        compare(snap.computer, "Acer Aspire A515-57");
        compare(snap.hostname, "frith-cachy");
        compare(snap.os, "CachyOS");
        compare(snap.memory, "32 GB");
        compare(snap.version, "1.2.5");
        compare(snap.gpu, "Intel (i915)");
        compare(snap.niri, "niri 26.04");
    }
}
