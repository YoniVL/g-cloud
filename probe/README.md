# G Cloud probe

Klein testproject om te zien wat er op jouw netwerk en op de G Cloud zelf werkt.

## Opzetten (op je pc, in deze map)
```
flutter create --platforms=android --project-name gcloud_probe .
flutter pub get
```
`flutter create` laat lib/main.dart en pubspec.yaml met rust als ze al bestaan (controleer even met git diff/de inhoud als je twijfelt).

## Internet-rechten
Open `android/app/src/main/AndroidManifest.xml` en zet boven `<application>`:
```
<uses-permission android:name="android.permission.INTERNET"/>
```
Voor Android 9+ moet ook gewoon HTTP (Sonos op poort 1400) mogen. Voeg in de `<application ...>` tag toe:
```
android:usesCleartextTraffic="true"
```

## Draaien op de G Cloud
Zet op de G Cloud ontwikkelaarsopties en USB-foutopsporing aan, sluit hem aan op je pc, dan:
```
flutter run
```

## Wat te testen
1. **Knoppen**: druk op alle knoppen, vooral de G-knop. Verschijnt er een regel? Dan kan hij gebruikt worden.
2. **Hue**: IP van de bridge invullen (te vinden in de Hue-app of je router), druk op de knop van de bridge, dan Koppel, dan Scenes laden en een scene aantikken.
3. **Sonos**: IP van de Beam invullen (Sonos-app > Instellingen > Systeem > Over mijn systeem), dan Status, Play/Pauze en de volumeslider.
4. Alles wat gebeurt (ook fouten) staat in het logboek onderaan. Stuur me dat als iets niet werkt.

Chromecast (Android TV Remote-protocol) volgt als volgende stap, na deze test.
