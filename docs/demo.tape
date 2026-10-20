# Records the demo for the README and urtti.com/szt. From the repo root:
#   vhs docs/demo.tape
Output docs/demo.gif

Require szt

Set FontSize 15
Set Width 1000
Set Height 640
Set Padding 24
Set Theme "Catppuccin Mocha"
Set TypingSpeed 75ms

Env COLORTERM "truecolor"
Env SZT_THEME "dark"

Sleep 500ms
Type "szt /Applications"
Sleep 600ms
Enter
Sleep 4s
Screenshot docs/screenshot.png
Sleep 2s
