# NotchSpotify

MVP ultra-basico para macOS: un notch flotante con informacion y controles de Spotify.

## Objetivo de esta version (v1)
- Codigo minimo
- Sin dependencias externas
- Bajo uso de CPU/RAM
- Base clara para iterar

## Que hace
- Panel tipo notch siempre arriba (center-top)
- Estado colapsado al iniciar
- Expande en hover
- Muestra track/artist/artwork
- Controles: previous, play/pause, next
- Integracion con Spotify via AppleScript (sin API keys)

## Optimizaciones aplicadas
- Polling cada `2.0s` (menos CPU que refresco agresivo)
- Solo actualiza UI cuando cambia el track
- Solo descarga artwork cuando cambia la URL
- Sin capas extra de configuracion en runtime

## Estructura principal
- `/Users/adrien/Desktop/NotchSpotify/NotchSpotify/Sources/NotchSpotifyApp.swift`
- `/Users/adrien/Desktop/NotchSpotify/NotchSpotify/Sources/NotchWindowController.swift`
- `/Users/adrien/Desktop/NotchSpotify/NotchSpotify/Sources/NotchContentView.swift`
- `/Users/adrien/Desktop/NotchSpotify/NotchSpotify/Sources/SpotifyBridge.swift`

## Ejecutar
1. Abrir `/Users/adrien/Desktop/NotchSpotify/NotchSpotify.xcodeproj` en Xcode
2. Seleccionar target `NotchSpotify` y un Team valido
3. Run (`Cmd + R`)
4. Aceptar permiso de automatizacion cuando macOS lo pida

## Siguiente iteracion sugerida
1. Atajo global para mostrar/ocultar notch
2. Config minima (tamano, delay hover)
3. Deteccion multi-monitor mas robusta
