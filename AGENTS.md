# Instrucciones para agentes

- Cada push a `main` se instala solo en los Macs de Jorge en menos de 10 minutos. Solo se sube a `main` código que compila y pasa las pruebas.
- Antes de subir: `bash -n instalar.sh` y todas las pruebas de `tests/*/` (cada carpeta lista en `fuentes.txt` los archivos de `src/` que necesita). Las pruebas nuevas van en su carpeta con su `fuentes.txt`.
- Swift 6 estricto, macOS 26, Apple Silicon. La app se compila con `src/build-app.sh` (todos los `src/*.swift`).
- Sube `CFBundleShortVersionString` y `CFBundleVersion` en `src/Info.plist` con cada cambio visible.
- No cambies el identificador `es.jorge.dictadomac`, el nombre del certificado ni la etiqueta del agente: los permisos de macOS dependen de ellos.
- Nada de credenciales, claves ni datos personales en el repositorio (es público). El diccionario personal se sincroniza por iCloud Drive (`DictionarySync.swift`); nunca lo copies aquí.
- Textos de la interfaz en español peninsular, horas con punto (23.00).
- Windows (`windows/`): .NET 8, WinForms, Whisper.net y NAudio. El núcleo (`windows/Core`) es multiplataforma y tiene pruebas xUnit (`dotnet test windows/Core.Tests`); mantén su lógica alineada con la de Mac (atajos, puntuación, diccionario). Cada push a `windows/` publica una versión en Releases que los PCs instalan solos.
- Los Macs solo se actualizan con commits que tocan `src/`.
