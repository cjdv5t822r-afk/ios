# Monastyr AR — iOS

Natywna wersja aplikacji na iPhone'a: Swift, SwiftUI, ARKit i RealityKit. Ma te same funkcje, układ ekranu i polskie
teksty co wersja na Androida (`../android`), i korzysta z tej samej zawartości (`../content`).

> **Stan: kod nie był jeszcze ani razu skompilowany ani uruchomiony.**
> Powstał na komputerze z Windows, bez Maca, bez kompilatora Swift i bez iPhone'a. Zamiast kompilacji każde użyte
> API Apple i bibliotek zostało sprawdzone w aktualnej dokumentacji albo w źródłach biblioteki (lista niżej).
> Pierwszy build na Macu albo w CI będzie pierwszą kompilacją — trzeba się liczyć z błędami do poprawienia.

## Co jest w tym folderze

```
ios/
  project.yml            opis projektu dla XcodeGen (z niego powstaje MonastyrAR.xcodeproj)
  StageCore/             pakiet Swift z logiką niezależną od platformy + testy jednostkowe (swift test)
    Sources/StageCore/   oś czasu klipów, mieszanie póz, układ znaku wodnego, reguły nazw klipów,
                         character.json, limity importu, ustawienia, parser GLB z próbkowaniem animacji,
                         porządkowanie skinów (GLBSkinNormalizer), biblioteka postaci: catalog.json
                         (sprawdzanie wpisów, limity, wersje), adresy serwera, polski porządek nazw i wyszukiwanie
    Tests/StageCoreTests testy jednostkowe, w tym przeniesione 1:1 testy z Androida
  MonastyrAR/            aplikacja
    App/                 punkt wejścia, StageViewModel
    Content/             paczki postaci w Dokumentach, biblioteka (katalog z serwera, pobieranie), import GLB / ZIP
    Stage/               scena: StageState, StageController (ARView, sesja AR, gesty), ClipPlayer, ModelLoader
    Capture/             nagrywanie klatek sceny, mikrofon, logo, zapis do Zdjęć, udostępnianie,
                         dopisywanie podkładu do gotowego filmu (MusicMux)
    Music/               podkłady: lista (wbudowane + importowane), import pliku audio, odsłuch, dekoder
    Settings/            zapis ustawień (UserDefaults)
    UI/                  ekran i komponenty SwiftUI, teksty (Strings.swift), kolory marki (Theme.swift)
    Assets.xcassets      ikona aplikacji (z content/branding/logo.webp), kolory
    PrivacyInfo.xcprivacy  manifest prywatności wymagany przez App Store (patrz „Manifest prywatności")
  scripts/make-app-icon.sh   odtwarza ikonę po podmianie logo (na Macu)
../.github/workflows/ios-build.yml   build w GitHub Actions
```

Zawartość nie jest kopiowana do `ios/`: projekt wskazuje pliki tam, gdzie leżą — `../content/branding`.

**W aplikacji nie ma żadnej postaci.** Z folderu `content/characters` nic nie jest pakowane, niezależnie od tego,
co się w nim znajdzie. Postacie trafiają na telefon z serwera (patrz „Biblioteka postaci") albo przez import pliku.
Postać testowa `content/characters/stage_dummy` służy już tylko testom `StageCore` i jako przykład paczki do
wgrania na serwer.

## Wybrany silnik i dlaczego

**RealityKit (`ARView`) + GLTFKit2 0.5.15 do siatek, materiałów i szkieletu + własne odtwarzanie animacji.**

- RealityKit sam wczytuje tylko USD / USDZ / Reality. GLB trzeba przetworzyć w aplikacji.
- GLTFKit2 (binarny pakiet Swift, wersja przypięta) zamienia siatki, materiały, tekstury i skiny na obiekty RealityKit.
  Skiny buduje dopiero od **iOS 18** (`MeshResource.Skeleton`), stąd **minimalna wersja systemu: iOS 18.0**.
- Część GLTFKit2 odpowiedzialna za animacje nie jest używana. W wersji 0.5.15 przepróbkowuje klipy do 30 kl./s,
  wiąże je po nazwach kości, nie obsługuje interpolacji sześciennej i ma w kodzie dopisek „TODO" przy przeliczaniu
  kości głównej. Aplikacja sama czyta węzły, skiny i klipy z pliku (`StageCore/GLB`), sama liczy pozę w każdej
  klatce i wpisuje ją do RealityKit przez `ModelEntity.jointTransforms`.
- Odrzucone: SceneViewSwift (wersja alfa, zgłoszony brak obsługi glTF w jej kodzie) oraz SceneKit jako silnik
  główny (Apple oznaczył go jako wycofywany od iOS 26; zostaje jako plan awaryjny, patrz „Ryzyka").

### Animacja: co jest tak samo, a co inaczej niż na Androidzie

Tak samo: `ClipTimeline` (jeden klip naraz, przenikanie 0,22 s, klip jednorazowy trzyma ostatnią klatkę i wraca do
klipu spoczynkowego, tempo, pauza zamraża pozę) i `PoseBlender` są przeniesione linia po linii, razem z testami.
W każdej klatce poza liczona jest od zera: poza spoczynkowa → klip w bieżącym czasie → przy przenikaniu to samo dla
drugiego klipu i zmieszanie węzeł po węźle.

Inaczej:

| | Android (Filament) | iOS (RealityKit) |
|---|---|---|
| kto próbuje klatki kluczowe | `Animator` Filamentu | własny kod w `GLBDocument` (LINEAR, STEP, CUBICSPLINE) |
| gdzie trafia poza | transformacje węzłów, macierze kości liczy Filament | `jointTransforms` każdej siatki ze skinem (kość względem kości nadrzędnej, kość główna względem węzła siatki) oraz transformacje encji animowanych węzłów |
| morph targets | obsługiwane przez Filament | nieobsługiwane (GLTFKit2 nie przenosi ich do RealityKit) |
| zakotwiczenie w AR | kotwica ARCore pod każdą postacią | pozycja w układzie świata sesji ARKit, bez własnej kotwicy |

## Budowanie

### Na Macu

Wymagane: macOS z **Xcode 26 lub nowszym** i [XcodeGen](https://github.com/yonaskolb/XcodeGen) (pisane pod 2.46).

```bash
brew install xcodegen
```

```bash
cd ios && xcodegen generate
```

```bash
open MonastyrAR.xcodeproj
```

W Xcode: cel `MonastyrAR` → *Signing & Capabilities* → wybierz swój *Team*. Podłącz iPhone'a, wybierz go jako
urządzenie docelowe i uruchom (⌘R). Swift Package Manager sam pobierze GLTFKit2 i ZIPFoundation.

Testy logiki, bez symulatora:

```bash
cd ios/StageCore && swift test
```

Budowanie pod symulator nie było brane pod uwagę: tryb AR i tak wymaga prawdziwego urządzenia.

### W GitHub Actions (bez Maca)

Plik `.github/workflows/ios-build.yml` po wypchnięciu repozytorium na GitHub uruchamia na maszynie `macos-26`
(Xcode 26.x) dwa zadania: testy `StageCore` oraz wygenerowanie projektu i **niepodpisane archiwum**. Wynik
(`MonastyrAR-unsigned.ipa`) i log `xcodebuild` są do pobrania jako artefakty. Tego folderu nie ma jeszcze w żadnym
repozytorium Git, więc workflow nie był uruchomiony.

Niepodpisanego pliku `.ipa` nie da się zainstalować. Służy do sprawdzenia, że kod się kompiluje; do instalacji
trzeba go podpisać (niżej).

## Instalacja na iPhonie

iPhone z **iOS 18 lub nowszym**. Tryb AR działa na każdym iPhonie, który obsługuje iOS 18; zasłanianie przez
otoczenie wymaga LiDAR-u (modele Pro), bez niego zasłaniają tylko ludzie.

Na telefonie trzeba raz włączyć *Ustawienia → Prywatność i ochrona → Tryb dewelopera*, a po pierwszej instalacji
zaufać swojemu certyfikatowi w *Ustawienia → Ogólne → VPN i zarządzanie urządzeniami*.

| | Darmowe konto Apple (Personal Team) | Apple Developer Program (99 USD / rok) |
|---|---|---|
| jak instalować | z Xcode na Macu, kablem lub po Wi‑Fi | Xcode, TestFlight, App Store |
| ważność instalacji | **7 dni**, potem trzeba zbudować i wgrać ponownie | profil ważny rok; TestFlight: build ważny 90 dni |
| limity | do 3 aplikacji na urządzenie, do 3 urządzeń, do 10 identyfikatorów aplikacji na 7 dni | 100 urządzeń testowych na rok, TestFlight dla testerów |
| wysyłanie innym | nie | tak |

Limity darmowego konta pochodzą ze strony Apple „Choosing a Membership"; warto sprawdzić aktualne.

Podpisanie archiwum z CI bez Maca wymaga płatnego konta (certyfikat i profil jako sekrety repozytorium, potem
`xcodebuild -exportArchive`). Tego kroku workflow nie zawiera.

## Biblioteka postaci

Aplikacja nie zawiera modeli. Arkusz „Postać" jest biblioteką z dwiema sekcjami: „Pobrane (n)" — postacie na
telefonie, pobrane i importowane — oraz „Do pobrania (n)" — to, co oferuje serwer. Zachowanie, limity, komunikaty
i teksty są takie same jak na Androidzie; opis układu plików na serwerze, formatu `catalog.json` i narzędzia
`tools/make-catalog.mjs` jest w głównym `README.md`, w części „Biblioteka postaci na serwerze".

- **Adres serwera** jest zapisany w jednym miejscu: we właściwości `PacksBaseURL` pliku Info.plist, ustawianej
  w `project.yml` (domyślnie `https://mon2farma.fra1.digitaloceanspaces.com/monastyr2ar`). Aplikacja pobiera
  `<adres>/catalog.json` i pliki `<adres>/characters/<id>/<plik>`; ścieżka w adresie jest zachowywana, końcowy
  ukośnik nie ma znaczenia.
- **Pobieranie**: `URLSession` bez ciasteczek, pamięci podręcznej i zapisanych poświadczeń. Każdy plik trafia do
  ukrytego folderu roboczego `Documents/characters/.download-<id>-<n>`, jest liczony i sprawdzany (rozmiar ze
  spisu, rozmiar zapowiedziany przez serwer, SHA-256 przez CryptoKit) w trakcie zapisu, a gotowy folder jest
  jednym przemianowaniem wstawiany jako `Documents/characters/<id>`. Do tej chwili poprzednia kopia paczki jest
  nietknięta. Plik `.remote-version` w folderze paczki oznacza paczkę pobraną i przechowuje jej wersję ze spisu;
  gdy spis ma inną wersję, wiersz paczki pokazuje „Aktualizuj". Najwyżej dwie paczki pobierają się jednocześnie.
- **Limity** jak na Androidzie: spis do 2 MB i 2000 paczek, paczka do 32 plików, 200 MB na plik, 250 MB na paczkę,
  `character.json` do 1 MB, 20 MB zapasu wolnego miejsca; spis musi nadejść w 45 s.
- **Błędy** mają te same kategorie co na Androidzie (pobieranie: brak sieci, błąd serwera, zła suma, brak
  miejsca, plik za duży, błąd zapisu; spis: brak sieci, błąd serwera, zły format). Po błędzie sumy, rozmiaru
  albo serwera spis jest pobierany ponownie, bo zwykle to on jest nieaktualny.
- **Kopie zapasowe**: pobrane paczki są wyłączone z kopii iCloud i kopii na komputerze (`isExcludedFromBackup`),
  bo da się je pobrać ponownie. Paczki importowane z pliku zostają w kopii.
- **Import a pobieranie**: import nigdy nie zajmuje identyfikatora, pod którym coś już leży na telefonie
  (dostaje `<id>_2`, `<id>_3`…). Gdy biblioteka pobiera paczkę o identyfikatorze zajętym przez paczkę
  importowaną, importowana jest przenoszona pod wolny identyfikator, a nie nadpisywana.
- Postać, której pobieranie albo import skończy się w trakcie odliczania, nagrywania albo robienia zdjęcia,
  nie wchodzi na scenę — czeka w bibliotece.
- Po uruchomieniu aplikacja sprząta pozostałości po przerwanym pobieraniu lub imporcie (foldery `.download-…`,
  `.import-…`, `.replaced-…`).

### Lokalny serwer testowy

Do prób bez wysyłania czegokolwiek na serwer służy `tools/serve-packs.mjs` (zwykły HTTP):

```bash
node tools/serve-packs.mjs --root <folder-ze-spisem> --host 0.0.0.0 --port 8787
```

Adres podaje się aplikacji **argumentem uruchomienia**, bez zmiany źródeł i bez zmiany `project.yml`. W Xcode:
*Product → Scheme → Edit Scheme… → Run → Arguments → Arguments Passed On Launch*:

```
-PacksBaseURL http://192.168.0.10:8787
```

(adres komputera w sieci Wi‑Fi, w której jest telefon). `UserDefaults` czyta argumenty uruchomienia przed
wszystkim innym, więc ten adres zastępuje wpis z Info.plist tylko w tak uruchomionej aplikacji. Zwykły HTTP
przechodzi przez App Transport Security wyłącznie dla adresów lokalnych (`NSAllowsLocalNetworking`: adresy IP,
nazwy `.local` i nazwy bez kropki); `NSAllowsArbitraryLoads` nie jest ustawione, więc każde inne połączenie musi
być HTTPS. Sam downloader przyjmuje HTTP tylko wtedy, gdy adres bazowy jest HTTP, i nie idzie za przekierowaniem
na inny host. Przy pierwszym połączeniu z adresem w sieci lokalnej iOS zapyta o dostęp do sieci lokalnej.

## Własne postacie

Format paczki jest wspólny z Androidem i opisany w głównym `README.md`: `model.glb` + opcjonalny `character.json`.

- **Z serwera**: paczka wgrana na serwer i wpisana do `catalog.json` pojawia się w bibliotece u każdego;
  aplikacji nie trzeba przebudowywać.
- **W aplikacji**: „Postać" → „Importuj model (GLB lub ZIP)" otwiera przeglądarkę Plików. Limity jak na Androidzie:
  200 MB, do 400 wpisów w ZIP-ie, zachowywane są tylko pliki `glb / json / png / jpg / jpeg / webp`, a nazwy są
  spłaszczane, więc archiwum nie może nic zapisać poza folder paczki.
- **Przez aplikację Pliki**: folder paczki można też wrzucić do *Na moim iPhonie → Monastyr AR → characters*.
  Taka paczka liczy się jako importowana. W tym samym folderze widać też paczki pobrane z biblioteki.

Czego wymaga iOS, a czego nie wymaga glTF — i co aplikacja robi z tym sama:

- Szkielet RealityKit wymaga, żeby w skinie każda kość nadrzędna stała przed podrzędnymi (dokumentacja
  `MeshResource.Skeleton`), a GLTFKit2 0.5.15 dodatkowo pomija kości bez nazwy i czyta tylko wagi typu FLOAT.
  glTF niczego takiego nie gwarantuje, dlatego przed wczytaniem `GLBSkinNormalizer` przepisuje plik **w pamięci**:
  ustawia kości w kolejności rodzic → dziecko (razem z macierzami wiązania i numerami kości w wierzchołkach),
  nadaje nazwy kościom bez nazwy i zamienia wagi całkowite na zmiennoprzecinkowe. Plik, który już spełnia te
  warunki (w tym `stage_dummy`), nie jest ruszany. Plik na dysku nigdy się nie zmienia.
- Jeśli mimo to siatka wyjdzie z konwertera bez szkieletu, model się pokaże, ale nieruchomy, z komunikatem
  „Tego modelu nie da się animować na iOS".
- Tylko trójkąty; bez morph targets; kompresja Draco nie jest skonfigurowana.
- Przy błędzie budowania siatki GLTFKit2 kończy działanie aplikacji (`fatalError`). Uszkodzony plik może więc
  zamknąć aplikację zamiast pokazać komunikat. Przyczynę znaną z góry (szkielet) aplikacja sprawdza sama,
  zanim odda plik bibliotece.

## Muzyka

Arkusz „Muzyka" działa jak na Androidzie: cztery wbudowane pętle z `content/music` (do aplikacji trafia ten folder w
całości: `music/music.json` i pliki WAV), import własnego pliku audio, głośność, odsłuch oraz „Odtwarzaj podczas
nagrywania". Utwory i ich pochodzenie opisuje główny `README.md`. **Ten kod, jak reszta `ios/`, nie był kompilowany.**

- **Jak podkład trafia do filmu.** Po zakończeniu nagrania `Capture/MusicMux.swift` robi kopię pliku: obraz jest
  przepisywany próbka po próbce, bez ponownego kodowania (`AVAssetReader` i wejście `AVAssetWriter`, oba bez ustawień
  wyjściowych), a podkład — zapętlony do długości filmu, z ustawioną głośnością, wejściem 20 ms i wyciszeniem 700 ms
  na końcu — liczy ten sam kod co na Androidzie (`StageCore/Music`, z testami) i koduje do AAC `AVAssetWriter`.
  Nie w trakcie nagrania: wtedy nie wiadomo jeszcze, gdzie film się skończy, a błąd ścieżki dźwiękowej zabrałby ze
  sobą całe nagranie. Gdy muzyki nie da się dodać, film jest zapisywany bez niej, z komunikatem.
- **Mikrofon.** Z wybranym podkładem mikrofon nie jest nagrywany (nagrałby podkład grający z głośnika), a jego
  przełącznik w Ustawieniach jest wtedy nieaktywny — tak samo jak na Androidzie.
- **Odsłuch i podkład z głośnika** to `AVAudioPlayer`. Sesja audio (`playback`) jest włączana tylko na czas grania
  i oddawana po zatrzymaniu. Odsłuch kończy się przy zamknięciu arkusza i z początkiem nagrania; każde granie
  kończy się też przy rozmowie telefonicznej, wyjęciu słuchawek i wyjściu z aplikacji.
- **Importowane utwory** leżą w `Library/Application Support/music`, poza aplikacją Pliki i poza kopią zapasową
  (do 60 MB każdy, a plik źródłowy zostaje u twórcy). Po odtworzeniu telefonu z kopii trzeba je zaimportować ponownie;
  wybrany utwór, którego już nie ma, wraca do „Bez muzyki".
- **Formaty**: wszystko, co otwiera Core Audio (`AVAudioFile`) — WAV, AIFF, CAF, MP3, M4A / AAC, ALAC, FLAC.
  Inaczej niż na Androidzie pliki Ogg Vorbis, MKA i WebM są odrzucane komunikatem „Telefon nie potrafi odtworzyć
  tego pliku jako muzyki". Limit rozmiaru jest ten sam: 60 MB.
- **Ścieżka dźwiękowa**: AAC 44,1 kHz (48 kHz, gdy utwór ma 48 kHz), 160 kb/s stereo albo 96 kb/s mono. Android
  zachowuje też niższe częstotliwości; tutaj są podnoszone do 44,1 kHz przez konwerter `AVAssetWriter`.
- **Po zabiciu aplikacji** przy następnym starcie znikają niedokończone pliki (`music-*.mp4` w folderze tymczasowym,
  `.import-*` w folderze muzyki), a nagrania, które nie zdążyły trafić do Zdjęć, są tam zapisywane bez podkładu.

Do sprawdzenia na urządzeniu w pierwszej kolejności: czy film z podkładem odtwarza się w Zdjęciach i ma dźwięk do
ostatniej klatki; czy odsłuch gra przy włączonym trybie cichym i czy po nagraniu z mikrofonem odsłuch nadal gra z
głośnika, a nie ze słuchawki telefonu; czy sesja audio odtwarzacza nie kłóci się z dźwiękiem RealityKit.

Deklaracje sprawdzone w dokumentacji Apple (11 listopada 2026): `AVAudioFile` (`init(forReading:)`,
`processingFormat`, `fileFormat`, `length`, `framePosition`, `read(into:frameCount:)`), `AVAudioPCMBuffer`
(`init(pcmFormat:frameCapacity:)`, `floatChannelData`, `frameLength`), `AVAudioPlayer` (`init(contentsOf:)`,
`numberOfLoops`, `volume`, `prepareToPlay()`, `play()`, `stop()`, `delegate`) i
`audioPlayerDecodeErrorDidOccur(_:error:)`, `AVAudioSession` (`setCategory(_:mode:options:)`,
`setActive(_:options:)`, powiadomienia o przerwaniu, zmianie trasy i restarcie usług), `AVAsset.loadTracks(withMediaType:)`,
`load(.timeRange / .formatDescriptions / .preferredTransform)`, `AVAssetReader`, `AVAssetReaderTrackOutput(track:outputSettings:)`
(„`nil` — próbki w formacie zapisu"), `AVAssetWriterInput(mediaType:outputSettings:sourceFormatHint:)`,
`canApply(outputSettings:forMediaType:)`, `startSession` / `endSession(atSourceTime:)`, `CMAudioFormatDescriptionCreate`,
`CMBlockBufferCreateWithMemoryBlock`, `CMBlockBufferReplaceDataBytes`,
`CMAudioSampleBufferCreateReadyWithPacketDescriptions`, `CMTimeConvertScale`, `UIApplication.beginBackgroundTask`,
`URLResourceValues.isExcludedFromBackup`, `UTType.audio`. Jak reszta kodu nagrywania, część metod `AVAssetReader` /
`AVAssetWriterInput` oraz `AVAudioSession.InterruptionType` jest oznaczona jako wycofywana od iOS 27.

## Manifest prywatności

`MonastyrAR/PrivacyInfo.xcprivacy` trafia do aplikacji jako zasób (XcodeGen dodaje go sam, bo leży w folderze
źródeł). App Store Connect i TestFlight odrzucają aplikację, która używa API „z wymaganym uzasadnieniem" bez
takiego pliku. Aplikacja niczego nie zbiera i nikogo nie śledzi; zgłasza trzy kategorie API, każdą z jednym powodem:

| Kategoria | Powód | Gdzie w kodzie |
|---|---|---|
| `UserDefaults` | `CA92.1` — własne dane aplikacji | ustawienia (`SettingsRepository`), adres serwera testowego (`PackServer`) |
| Wolne miejsce na dysku | `E174.1` — sprawdzenie, czy plik się zmieści | przed pobraniem paczki (`PackInstaller`) |
| Daty plików | `C617.1` — pliki we własnym kontenerze aplikacji | pozostałości nagrań w `tmp` (`CaptureController`, `MusicMux`), importowane utwory (`MusicRepository`) |

Kody powodów sprawdzone w dokumentacji Apple 11 listopada 2026. Gdy kod zacznie używać kolejnego takiego API
(czas od startu systemu, lista klawiatur, inne daty lub rozmiary dysku), trzeba dopisać je do tego pliku.
Biblioteki `GLTFKit2` i `ZIPFoundation` odpowiadają za własne manifesty; tego nie sprawdzałem.

## Różnice względem wersji na Androida

- Zapis trafia do biblioteki **Zdjęć** z dostępem „tylko dodawanie". Taki dostęp nie pozwala tworzyć albumów, więc
  nie ma odpowiednika folderów `Movies/MonastyrAR`. Aplikacja trzyma kopię ostatniego nagrania do udostępnienia.
  Komunikat brzmi „Zapisano w Zdjęciach".
- iOS pyta o uprawnienie tylko raz. Po odmowie przycisk „Zezwól" otwiera Ustawienia systemu.
- Obsługa AR jest sprawdzana od razu (`ARWorldTrackingConfiguration.isSupported`), bez etapu „Sprawdzanie AR…"
  znanego z ARCore; ten napis pojawia się tylko na czas pytania o aparat.
- Wskazówka „Za ciemno": ARKit nie ma takiego powodu utraty śledzenia. Pokazujemy ją, gdy brakuje detali i
  jednocześnie oszacowane oświetlenie jest niskie.
- „Podłoże" to wykryta płaszczyzna pozioma poniżej telefonu (ARKit nie rozróżnia stron płaszczyzny jak ARCore).
- W AR przeciąganie zaczyna się od złapania wybranej postaci i zachowuje odstęp palca od postaci, więc postać nie
  przeskakuje pod palec.
- Wykryte powierzchnie są rysowane jako półprzezroczyste złote płytki, nie jako siatka kropek.
- Celownik znika, gdy pod środkiem kadru nie ma podłoża (na Androidzie zmienia wygląd).
- Cień pod postacią to tylko miękka plama kontaktowa; nie ma osobnych płaszczyzn odbierających cień.
- Klawisze głośności jako spust: iOS oddaje je tylko aplikacjom, które uzna za korzystające z aparatu
  (`AVCaptureEventInteraction`). W trybie Studio prawdopodobnie nie zadziałają.
- Nagranie ma 30 kl./s (co druga klatka widoku 60 Hz).
- Nagrywanie kończy się, gdy aplikacja przestaje być aktywna — także przy Centrum sterowania albo systemowym
  pytaniu o uprawnienie (na Androidzie: przy `onPause`). Plik jest wtedy zamykany i zapisywany.
- `character.json` jest czytany nieco łagodniej niż na Androidzie: wartość złego typu wraca do domyślnej, nazwy
  kategorii nie rozróżniają wielkości liter, dozwolone są komentarze i końcowe przecinki. Ręcznie poprawiony plik,
  który działa na iOS, może więc zostać odrzucony na Androidzie.
- Ustawienie „Własny" kolor tła Studio istnieje w danych, ale — jak na Androidzie — nie ma do niego kontrolki.
- Biblioteka postaci:
  - adres serwera na Androidzie jest wpisywany przy budowaniu (`-Pstage.packsUrl`), na iOS jest we właściwości
    Info.plist i da się go zastąpić argumentem uruchomienia (patrz „Lokalny serwer testowy");
  - `catalog.json` jest czytany ściślej niż na Androidzie: wartość złego typu (np. liczba zamiast tekstu)
    odrzuca wpis, w którym stoi; reguły sprawdzania wpisów (`CatalogRules`) są te same;
  - przekierowania: Android sam idzie za najwyżej pięcioma, iOS zostawia to `URLSession` i w jej delegacie
    odrzuca przekierowanie na inny host, z HTTPS na HTTP oraz szóste z kolei;
  - serwer jest proszony o plik bez kompresji (`Accept-Encoding: identity`), żeby zapowiedziany rozmiar dało się
    porównać ze spisem; gdy odpowiedź mimo to jest skompresowana, zapowiedziany rozmiar nie jest sprawdzany
    (rozmiar i suma pobranych bajtów — zawsze);
  - wolne miejsce to `volumeAvailableCapacityForImportantUsage` (iOS wlicza w nie to, co sam może zwolnić);
  - stan biblioteki żyje w jednym obiekcie na głównym aktorze (`PackLibrary`), bez blokady i bez stanu
    „na proces" znanego z Androida — model widoku żyje tu tak długo jak aplikacja;
  - pobieranie odwołane w kolejce (trzecie i dalsze) zwalnia swoje miejsce dopiero, gdy do niego dojdzie;
  - pasek postępu w wierszu to pierścień z procentem, wyszukiwarka jest polem w arkuszu, a potwierdzenie
    usunięcia — systemowym alertem.

## Co zostało sprawdzone, a co nie

### Sprawdzone w dokumentacji lub źródłach (10 listopada 2026)

Deklaracje pobrane ze stron `developer.apple.com/documentation/....md` (dokładne sygnatury i dostępność):

- RealityKit: `ARView.init(frame:cameraMode:automaticallyConfigureSession:)`, `cameraMode`, `environment.background`
  (`.color`), `environment.sceneUnderstanding.options`, `renderOptions`, `renderCallbacks.postProcess`,
  `PostProcessContext` (`commandBuffer`, `device`, `sourceColorTexture`, `targetColorTexture`),
  `snapshot(saveToHDR:completion:)`, `raycast(from:allowing:alignment:)`, `ray(through:)`, `cameraTransform`,
  `Scene.addAnchor`, `Scene.subscribe(to:on:_:)`, `SceneEvents.Update.deltaTime`, `AnchorEntity(world:)`,
  `HasModel.jointTransforms` / `jointNames`, `ModelComponent.boundsMargin`, `Transform(matrix:)`,
  `HasTransform.look(at:from:upVector:relativeTo:)`, `PerspectiveCameraComponent(near:far:fieldOfViewInDegrees:fieldOfViewOrientation:)`,
  `DirectionalLight`, `MeshResource.generatePlane(width:depth:cornerRadius:)`, `UnlitMaterial` (`color`, `blending`),
  `PhysicallyBasedMaterial.Opacity(scale:texture:)`, `TextureResource(image:withName:options:)`,
  `MeshResource.Skeleton` (dostępność iOS 18).
- ARKit: `ARWorldTrackingConfiguration` (`planeDetection`, `environmentTexturing`, `sceneReconstruction`,
  `supportsSceneReconstruction`), `ARConfiguration.isSupported` / `frameSemantics` / `supportsFrameSemantics`,
  metody `ARSessionObserver` i `ARSessionDelegate`, `ARCamera.TrackingState` i `Reason`, `ARRaycastResult`,
  `ARPlaneAnchor` (`alignment`, `center`, `planeExtent`), `ARPlaneExtent`, `ARLightEstimate.ambientIntensity`.
- Nagrywanie: `CIRenderDestination(mtlTexture:commandBuffer:)`, `isFlipped`, `colorSpace`,
  `CIContext.startTask(toRender:to:)`, klucze `CIContextOption`, `CVMetalTextureCacheCreate`,
  `CVMetalTextureCacheCreateTextureFromImage`, `CVPixelBufferPoolCreatePixelBuffer`, `AVAssetWriter`,
  `AVAssetWriterInput`, `AVAssetWriterInputPixelBufferAdaptor`, `CMSampleBufferCreateCopyWithNewTiming`,
  `CMSyncConvertTime`, `AVCaptureSession.synchronizationClock`, `AVCaptureDevice.requestAccess(for:)`,
  `PHPhotoLibrary.requestAuthorization(for:)`, `performChanges`, `PHAssetCreationRequest.addResource`,
  `AVAssetImageGenerator.image(at:)`, `AVCaptureEventInteraction`.
- SwiftUI / UIKit / Foundation: `fileImporter`, `onChange(of:initial:_:)`, `presentationBackground`,
  `UIGraphicsImageRenderer.jpegData`, `UIImage.preparingThumbnail(of:)`, `JSONDecoder.allowsJSON5`.
- GLTFKit2 0.5.15: przeczytany `GLTFRealityKit.swift` i `GLTFAsset.h` (jedna encja na węzeł, kolejność dzieci jak
  w pliku, warunki budowania skinu). ZIPFoundation 0.9.20: `Archive(url:accessMode:)`, iteracja, `extract(_:consumer:)`.
- Dwie uwagi z dokumentacji, które zmieniły kod: `MeshResource.Skeleton` — „A parent joint needs to precede all
  of its child joints" (stąd `GLBSkinNormalizer`); `AVAssetWriterInputPixelBufferAdaptor.pixelBufferPool` jest
  `nil` przed `startSession` (stąd własna pula buforów w `SceneRecorder`).
- XcodeGen: klucze `project.yml` według `Docs/ProjectSpec.md`. Obrazy maszyn GitHub: `macos-26` ma Xcode 26.0–26.6.
- Liczby w testach modelu demonstracyjnego (19 węzłów, 18 kości, 9 klipów z długościami, wysokość 1,83 m)
  zostały policzone osobnym skryptem Node na pliku `content/characters/stage_dummy/model.glb`.
- Biblioteka postaci (11 listopada 2026), z tych samych stron dokumentacji: `URLSessionConfiguration`
  (`ephemeral`, `httpCookieStorage`, `httpShouldSetCookies`, `httpCookieAcceptPolicy`, `urlCredentialStorage`,
  `urlCache`, `requestCachePolicy`, `timeoutIntervalForRequest`, `waitsForConnectivity`), metody delegata
  `urlSession(_:dataTask:didReceive:completionHandler:)` i
  `urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:)` (dokładne sygnatury; odmowa
  przekierowania przez `nil`), `URLResponse.expectedContentLength`, `HTTPURLResponse.value(forHTTPHeaderField:)`,
  nazwy `URLError.Code`, CryptoKit `SHA256` (`update(data:)`, `finalize()`, `SHA256Digest` jako sekwencja bajtów),
  `URLResourceValues.isExcludedFromBackup` i `volumeAvailableCapacityForImportantUsage`,
  `URL.setResourceValues(_:)`, `FileHandle.synchronize()`, `withTaskCancellationHandler` (w tym uwaga o blokadach
  w procedurze anulowania — stąd wznawianie kontynuacji poza blokadą), `NSString.compare(_:options:range:locale:)`,
  `Unicode.Scalar.Properties.generalCategory`, klucz `NSAllowsLocalNetworking` (od iOS 17 bez niego ATS nie
  dopuszcza połączeń z adresami IP), SwiftUI `TextField(_:text:prompt:)`, `submitLabel`, `autocorrectionDisabled`,
  `scrollDismissesKeyboard`.
- Stałe i algorytm SHA-256 zapisanego w `StageCore` zostały sprawdzone skryptem Node (stałe z definicji,
  przepisany algorytm porównany z `node:crypto` dla 12 długości wiadomości); wartości oczekiwane w testach
  biblioteki (sumy, wersje paczek) policzono tym samym skryptem.

### Niesprawdzone, dopóki nie będzie builda i urządzenia

- **Biblioteka postaci nie była ani kompilowana, ani uruchomiona** — ani pakiet, ani aplikacja, ani testy.
  W szczególności do sprawdzenia przy pierwszym buildzie i na telefonie:
  - czy `String.compare(_:options:range:locale:)` z lokalizacją `pl_PL` daje porządek polskiego słownika
    (testy `NameOrderTests` to rozstrzygną);
  - zachowanie `JSONDecoder` na granicznych wartościach spisu (liczby poza zakresem, powtórzone klucze);
  - czy odwołanie pobierania kończy zadanie `URLSession` od razu i czy foldery robocze znikają;
  - czy serwer (DigitalOcean Spaces) podaje `Content-Length` zgodny ze spisem przy `Accept-Encoding: identity`;
  - czy oznaczenie `isExcludedFromBackup` przetrwa przemianowanie folderu (jest ustawiane ponownie przy starcie);
  - pobieranie przerwane przejściem aplikacji w tło: sesja nie jest sesją tła, więc pobieranie kończy się
    błędem sieci i wymaga „Ponów".

- **Czy całość się kompiluje.** Sprawdzane były deklaracje, nie kompilacja. Tryb języka to Swift 5 z minimalnym
  sprawdzaniem współbieżności, żeby ograniczyć liczbę błędów pierwszego builda. Kod przeszedł dwa niezależne
  przeglądy „na sucho" (logika i użycie API); nie znalazły pewnych błędów kompilacji, znalazły za to błędy
  działania, które zostały poprawione. Przegląd nie zastępuje kompilatora.
- Czy testy `StageCore` przechodzą (nie były uruchomione; oczekiwane wartości przeliczono ręcznie i w Node).
- `GLBSkinNormalizer` na prawdziwych plikach: testy używają małego modelu zbudowanego w kodzie.
- Czy XcodeGen 2.46 przyjmie `project.yml` bez poprawek i czy binarny pakiet GLTFKit2 0.5.15 wczyta się w Xcode 26.
- Jak RealityKit zachowa się przy wpisywaniu `jointTransforms` co klatkę do siatki zbudowanej przez GLTFKit2:
  czy poza spoczynkowa się zgadza, czy nie ma przycinania przez bryłę ograniczającą (ustawiamy `boundsMargin`).
- Format i orientacja tekstury w `postProcess` (patrz „Ryzyka").
- Czy kolor tła Studio trafia do nagrania bez zmiany przez mapowanie tonów (na Androidzie trzeba było je wyłączyć).
- Oświetlenie w trybie Studio (zakładamy domyślne światło otoczenia `ARView` + jedno światło kierunkowe).
- Synchronizacja dźwięku z obrazem i współistnienie sesji audio z sesją ARKit.
- Wygląd i układ na prawdziwych ekranach; VoiceOver.
- Ostrzeżenia o wycofaniu: `AVAssetWriterInputPixelBufferAdaptor` i `AVAssetWriter.startWriting()` są oznaczone
  jako wycofane od iOS 27 (następca wymaga iOS 26). W Xcode 26 nie ma ostrzeżeń, w Xcode 27 będą.

## Największe ryzyka i plan awaryjny

1. **Animacja szkieletowa GLB w RealityKit.** Zależy od tego, czy siatka ze skinem zbudowana przez GLTFKit2
   poprawnie reaguje na `jointTransforms`. Dodatkowa niewiadoma: kod skinów w GLTFKit2 jest włączany warunkiem
   `#if compiler(>=6.0)`; jeśli binarna paczka 0.5.15 była zbudowana starszym kompilatorem, żaden model nie
   dostanie szkieletu (aplikacja pokaże wtedy komunikat o braku animacji). Jeśli animacja nie działa:
   - najpierw sprawdzić mapowanie węzłów na encje w `ModelLoader` i kolejność kości (`jointNames`);
   - plan B: budować siatkę i `MeshResource.Skeleton` samodzielnie z danych, które `GLBDocument` już czyta
     (wtedy GLTFKit2 zostaje tylko do materiałów albo znika);
   - plan C: SceneKit + GLTFKit2 (`SCNScene(gltfAsset:)`) w `ARSCNView` — dojrzalsza ścieżka glTF, kości to zwykłe
     węzły, więc `ClipPlayer` wpisywałby te same pozy do `SCNNode.simdTransform`. Wada: SceneKit jest wycofywany.
2. **Nagrywanie klatek** (`SceneRecorder`). Klatka jest skalowana do bufora 1080×1920 przez Core Image wewnątrz
   bufora poleceń RealityKit, logo dorysowuje Core Graphics, całość idzie do `AVAssetWriter`. Do sprawdzenia w
   pierwszej kolejności:
   - obraz do góry nogami → odwrócić `destination.isFlipped` w `encodeFrame`;
   - film za jasny albo za ciemny → funkcja `samplesLinearLight` źle oceniła format tekstury źródłowej;
   - czarny ekran podczas nagrywania → nie działa przekazanie klatki (`blit` w `postProcess`);
   - „Nagranie było zbyt krótkie" po każdym nagraniu → żadna klatka nie dotarła do pliku. Przycisk zatrzymania
     odblokowuje się wtedy sam po 2 sekundach, więc nagrywanie zawsze da się przerwać.
   Plan awaryjny: ReplayKit (`RPScreenRecorder.startCapture`) z ukryciem kontrolek na czas nagrania i przycięciem
   do pola sceny; nagrywa cały ekran, więc jest gorszy, ale nie zależy od `postProcess`. Zdjęcia nie korzystają z
   tej ścieżki (`ARView.snapshot`), więc działają niezależnie.
3. **`fatalError` w GLTFKit2** przy pliku, którego nie umie przetworzyć (patrz „Własne postacie").
4. **Brak kotwic ARKit pod postaciami.** Gdy ARKit poprawi mapę otoczenia, postać może się nieznacznie przesunąć
   względem podłogi. Poprawka: `ARAnchor` na postać i `AnchorEntity(anchor:)`.

## Po pierwszym udanym buildzie

Kolejność sprawdzania na iPhonie: biblioteka (karta „Pobierz pierwszą postać", spis z serwera, pobranie postaci,
odwołanie pobierania, usunięcie i ponowne pobranie; najwygodniej z lokalnym serwerem testowym i jego przełącznikami
`--delay-ms`, `--corrupt`, `--fail-after-bytes`) → tryb Studio (postać stoi na podłodze, animacje i przenikanie) → gesty → zdjęcie
z logo → krótki film (orientacja, kolory, logo w tym samym miejscu co na podglądzie) → film z mikrofonem → tryb AR
(wykrycie podłoża, celownik, postawienie twarzą do kamery) → import pliku `.glb` i paczki `.zip`.
