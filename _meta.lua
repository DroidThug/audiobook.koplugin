--[[--
Plugin metadata for KOReader.

@module _meta
--]]

local _ = require("gettext")

return {
    name = "audiobook",
    version = "0.1.5.40",
    fullname = _("Audiobook Read-Along"),
    description = _([[Text-to-Speech with synchronized word highlighting.

Features:
• Word-by-word highlighting as text is read
• Sentence highlighting option
• Multiple TTS engine support (espeak-ng, Piper neural, Pico, Flite, Festival, Android)
• Adjustable speech rate (0.25x to 2.0x), pitch, and volume
• Auto-advance pages
• Multiple highlight styles (background, underline, box, invert)
• Bluetooth audio and headset media button support

Usage:
1. Long-press a word to open dictionary
2. Tap "Read aloud from here"
3. Or use Tools menu → Audiobook Read-Along]]),
}
