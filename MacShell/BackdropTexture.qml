import QtQuick

// ShaderEffectSource captures this item's children while ignoring its own
// opacity. Keep it hidden even when the native-blur path has no texture reader.
Item {
    opacity: 0
}
