# Dictado Mac

Dictado por voz para macOS: mantén un atajo, habla y suelta; el texto aparece en el campo donde estabas escribiendo. Usa el reconocimiento nativo de macOS (SpeechAnalyzer) y, opcionalmente, Apple Intelligence para pulir la puntuación. Todo ocurre en el Mac: sin Whisper, claves ni servicios de pago.

## Instalar (una vez por Mac)

```
curl -fsSL https://raw.githubusercontent.com/jorgemoraz/dictado-mac/main/instalar.sh | bash
```

Requiere Apple Silicon, macOS 26 y las Command Line Tools de Xcode (`xcode-select --install`). La primera vez crea en el llavero una identidad de firma local («DictadoMac Local Code Signing») y pide la contraseña del Mac: así macOS conserva los permisos de Micrófono y Accesibilidad en cada actualización. Después hay que activar Dictado Mac en Ajustes del Sistema → Privacidad y seguridad → Accesibilidad (si ya estaba, quitarla con − y volver a añadirla) y poner «Al pulsar la tecla 🌐» en «No hacer nada» (Ajustes → Teclado).

## Desinstalar

```
curl -fsSL https://raw.githubusercontent.com/jorgemoraz/dictado-mac/main/instalar.sh | bash -s -- desinstalar
```

## Cómo se actualiza

Cada 10 minutos la app consulta el último commit de `main`. Si es nuevo, ejecuta `instalar.sh --auto <commit>`: descarga esa versión, pasa las pruebas, la compila, la firma con la identidad local, espera a que no estés dictando y reinicia la app. Si algo falla, se queda la versión anterior y no lo reintenta hasta el siguiente commit. Registro en `~/Library/Logs/DictadoMac-update.log`. También hay un botón «Buscar actualizaciones» en la ventana.

## Funciones

- Atajos para mantener pulsado: Fn, ⌃ + ⌥ izquierdos o los que grabes (incluidas teclas F y combinaciones con tecla). ⌃⌥Espacio para empezar y terminar sin mantener.
- Preguntas por la entonación: si el tono sube al final, «Vienes mañana.» pasa a «¿Vienes mañana?».
- Revisión opcional con IA local (solo puntuación, mayúsculas y tildes; nunca cambia palabras ni cifras).
- Diccionario personal y sustituciones explícitas, compartidos entre todos tus Macs por iCloud Drive (`iCloud Drive/Dictado Mac/diccionario.json`). Lo que añadas o quites en un Mac aparece en los demás en menos de un minuto. El diccionario nunca se sube a este repositorio. La primera vez macOS pide permiso para que Dictado Mac use iCloud Drive.

## Dictado para Windows

Versión para Windows 10 y 11 (64 bits) en `windows/`. Reconoce con Whisper en local (whisper.cpp): gratis y sin que el audio salga del PC.

Instalar o actualizar, en PowerShell (sin permisos de administrador):

```
irm https://raw.githubusercontent.com/jorgemoraz/dictado-mac/main/windows/instalar.ps1 | iex
```

- Atajos por defecto: **Ctrl + Win** o **Ctrl + Alt** izquierdos, mantenidos; se pueden grabar otros desde la ventana.
- La primera vez descarga el modelo de voz: large-v3-turbo (574 MB, máxima calidad) o small (190 MB, más rápido), a elegir.
- Pega en la app activa sin dejar rastro en el historial del portapapeles, con puntuación formal o informal según la app.
- Diccionario compartido con los Macs si está instalado iCloud para Windows (`iCloudDrive\Dictado Mac\diccionario.json`).
- Arranca con Windows y se actualiza sola: cada cambio en `windows/` publica una versión `windows-v1.0.N` en GitHub Releases.
