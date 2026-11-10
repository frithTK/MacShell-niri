import QtQuick
import QtQuick.Pdf

Item {
    id: root
    property url source: ""
    property alias pageCount: document.pageCount
    property alias currentPage: view.currentPage
    property alias error: document.error
    property alias status: document.status
    function goToPage(page) { view.goToPage(page); }
    function goPrev() { if (view.currentPage > 0) view.goToPage(view.currentPage - 1); }
    function goNext() {
        if (document.pageCount > 0 && view.currentPage + 1 < document.pageCount)
            view.goToPage(view.currentPage + 1);
    }
    PdfDocument { id: document; source: root.source }
    PdfMultiPageView { id: view; anchors.fill: parent; document: document }
}
