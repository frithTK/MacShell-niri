import QtQuick
import QtTest
import "../../MacShell/QuickLook.js" as QuickLook
import "../../MacShell/SettingsSearch.js" as SettingsSearch

TestCase {
    name: "QuickLook"

    function test_local_paths_keep_unicode_and_reject_injection() {
        compare(QuickLook.localPath("/tmp/Notes 1.txt"), "/tmp/Notes 1.txt")
        compare(QuickLook.localPath("/tmp/файл с пробелом.txt"), "/tmp/файл с пробелом.txt")
        compare(QuickLook.localPath("file:///tmp/Notes%201.txt"), "/tmp/Notes 1.txt")
        compare(QuickLook.localPath("file:///tmp/%D1%84%D0%B0%D0%B9%D0%BB.txt"), "/tmp/файл.txt")
        compare(QuickLook.localPath("file://host/tmp/notes.txt"), "")
        compare(QuickLook.localPath("notes.txt"), "")
        compare(QuickLook.localPath("/tmp/bad\npath"), "")
        compare(QuickLook.localPath(""), "")
        compare(QuickLook.fileName("/tmp/a b/c.txt"), "c.txt")
        compare(QuickLook.fileName("/tmp/файл.txt"), "файл.txt")
    }

    function test_file_urls_encode_spaces_and_reserved_characters() {
        compare(QuickLook.fileUrl("/tmp/Notes 1.txt"), "file:///tmp/Notes%201.txt")
        compare(QuickLook.fileUrl("/tmp/hash#q.png"), "file:///tmp/hash%23q.png")
        compare(QuickLook.fileUrl("/tmp/query?.txt"), "file:///tmp/query%3F.txt")
        compare(QuickLook.uriList("/tmp/Notes 1.txt"), "file:///tmp/Notes%201.txt\r\n")
        compare(QuickLook.uriList("relative"), "")
        compare(QuickLook.formatSize(512), "512 B")
        compare(QuickLook.formatSize(2048), "2.0 KB")
        verify(SettingsSearch.isLocalPath(QuickLook.localPath("/tmp/a.txt")))
    }
}
