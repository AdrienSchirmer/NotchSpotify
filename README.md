# NotchSpotify

Basic MVP for macOS: a floating notch with Spotify information and controls.

## Objective of this version (v1)
- Minimal code  
- No external dependencies  
- Low CPU/RAM usage  
- Clear base to iterate on  

## What it does
- Always-on-top notch-style panel (center-top)  
- Starts in collapsed state  
- Expands on hover  
- Displays track/artist/artwork  
- Controls: previous, play/pause, next  
- Spotify integration via AppleScript (no API keys required)  

## Applied optimizations
- Polling every `2.0s` (lower CPU usage than aggressive refresh)  
- UI updates only when the track changes  
- Artwork downloads only when the URL changes  
- No extra runtime configuration layers  

## Main structure
- `/Users/adrien/Desktop/NotchSpotify/NotchSpotify/Sources/NotchSpotifyApp.swift`
- `/Users/adrien/Desktop/NotchSpotify/NotchSpotify/Sources/NotchWindowController.swift`
- `/Users/adrien/Desktop/NotchSpotify/NotchSpotify/Sources/NotchContentView.swift`
- `/Users/adrien/Desktop/NotchSpotify/NotchSpotify/Sources/SpotifyBridge.swift`

## Run
1. Open `/Users/adrien/Desktop/NotchSpotify/NotchSpotify.xcodeproj` in Xcode  
2. Select the `NotchSpotify` target and a valid Team  
3. Run (`Cmd + R`)  
4. Accept the automation permission when macOS prompts you  

## Funny
All this project has been done with claude+codex, it's my first time vibecoding and im kinda vibin' with it.

## EXTRA
This project has been tested on my macbook pro m4 of 14 inches, there can be size problems with other monitors since i didn't develop on them yet!
