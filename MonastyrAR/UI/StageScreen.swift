import AVFoundation
import StageCore
import SwiftUI

private enum Sheet: String, Identifiable {
    case characters
    case music
    case settings

    var id: String { rawValue }
}

/// The whole app: the 9:16 stage (AR or Studio) with its overlays, and the controls around it.
/// Port of `ui/StageScreen.kt`.
///
/// The recorder captures the 3D view only, so everything drawn here in SwiftUI (guides, buttons, the logo
/// preview) is free to sit on top of the scene.
struct StageScreen: View {
    let viewModel: StageViewModel

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.displayScale) private var displayScale

    @State private var sheet: Sheet?
    @State private var deckExpanded = true
    @State private var sharing: SavedCapture?
    @State private var cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
    /// The mode whose scene already got its starter character. Once per visit: after that an empty stage is the
    /// creator's choice.
    @State private var starterPlacedFor: StageMode?
    /// "Do mnie" in AR turns a character back to the heading it was placed with, which was towards the camera.
    @State private var placedYaw: [Int: Float] = [:]

    private let logo = BrandLogo.image

    var body: some View {
        let stage = viewModel.stage
        let capture = viewModel.capture
        let settings = viewModel.settings
        let mode = settings.mode
        let cameraGranted = cameraStatus == .authorized
        let sceneLive = mode == .studio || cameraGranted
        let selected = stage.selected
        let targets = stage.targets()
        let actorCount = stage.actors.count
        let musicTrack = viewModel.musicTrack
        // The track is fixed for the length of a take, and until it has been written into the finished file.
        let musicEnabled = !capture.isBusy && !capture.isAddingMusic
        // Nothing is installed and nothing is on its way: the stage says where characters come from.
        let showLibraryPrompt = sceneLive && viewModel.packsLoaded && viewModel.packs.isEmpty
            && !viewModel.library.isDownloading && settings.onboardingSeen && sheet == nil && !capture.isBusy

        GeometryReader { proxy in
            let insets = proxy.safeAreaInsets
            let fullWidth = proxy.size.width + insets.leading + insets.trailing
            let fullHeight = proxy.size.height + insets.top + insets.bottom
            // The largest 9:16 rectangle the screen can hold, in whole pixels so the scene is not resampled.
            let stageWidthPx = floor(min(fullWidth * displayScale, fullHeight * displayScale * 9 / 16))
            let stageWidth = stageWidthPx / displayScale
            let stageHeight = floor(stageWidthPx * 16 / 9) / displayScale
            let chromeTop = insets.top + topBarHeight

            ZStack(alignment: .top) {
                Color.black

                // The stage box and everything that belongs to the picture.
                ZStack {
                    stageContent(mode: mode, cameraGranted: cameraGranted)
                    if sceneLive {
                        StageOverlays(
                            stage: stage, selected: selected, mode: mode, settings: settings, capture: capture,
                            logo: logo, importing: viewModel.importing, importingMusic: viewModel.importingMusic,
                            downloading: viewModel.library.isDownloading, chromeTop: chromeTop,
                            stageSize: CGSize(width: stageWidth, height: stageHeight)
                        )
                    }
                    if showLibraryPrompt {
                        FirstCharacterCard(onOpenLibrary: { sheet = .characters })
                            // Clear of the tool column on the right, and by as much on the left to stay centred.
                            .padding(.horizontal, 68)
                    }
                }
                .frame(width: stageWidth, height: stageHeight)
                .clipped()

                StageTopBar(
                    // The watermark preview already puts the logo in the top-left corner; two of them would collide.
                    logo: sceneLive && settings.watermarkEnabled && settings.watermarkAnchor == .topLeft ? nil : logo,
                    mode: mode,
                    enabled: !capture.isBusy,
                    onModeChange: { viewModel.setMode($0) },
                    onSettings: { sheet = .settings }
                )
                .padding(.top, insets.top)

                ToolColumn(
                    hasSelection: selected != nil,
                    hasTargets: !targets.isEmpty,
                    paused: targets.first?.paused == true,
                    speed: targets.first?.speed ?? 1,
                    showAll: actorCount >= 2,
                    applyToAll: stage.applyToAll,
                    musicTitle: musicTrack?.title,
                    musicEnabled: musicEnabled,
                    onCharacters: { sheet = .characters },
                    onMusic: { sheet = .music },
                    onFaceCamera: { faceCamera(selected, mode: mode) },
                    onScale: { selected?.changeUserScale($0) },
                    onTogglePaused: { stage.changePaused(targets.first?.paused != true) },
                    onCycleSpeed: { stage.changeSpeed(StageMath.nextSpeed(after: targets.first?.speed ?? 1)) },
                    onToggleAll: { stage.applyToAll.toggle() },
                    onRemove: { if let selected { stage.remove(selected) } }
                )
                // Bounded by the bar above and the open deck below, whatever the deck is doing, so it never jumps.
                .padding(.top, chromeTop + 8)
                .padding(.bottom, insets.bottom + BottomDeckMetrics.expandedHeight
                    + (musicTrack == nil ? 0 : BottomDeckMetrics.musicChipHeight) + 8)
                .padding(.trailing, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)

                if sceneLive && !settings.onboardingSeen {
                    OnboardingCard(onDismiss: { viewModel.updateSettings { $0.onboardingSeen = true } })
                        .padding(.horizontal, 32)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    if let banner = viewModel.banner {
                        messageBar(banner)
                            .transition(.opacity)
                    }
                    BottomDeck(
                        actor: selected,
                        stageIsEmpty: actorCount == 0,
                        expanded: $deckExpanded,
                        onPlay: { clip, toggleLoop in stage.play(clip, toggleLoop: toggleLoop) },
                        capture: capture,
                        maxDurationSeconds: settings.maxDurationSeconds,
                        musicTitle: musicTrack?.title,
                        musicEnabled: musicEnabled,
                        onRecord: { capture.toggleRecording() },
                        onPhoto: { capture.takePhoto() },
                        onShareLast: { sharing = $0 },
                        onMusic: { sheet = .music },
                        bottomInset: insets.bottom
                    )
                }
                .animation(.easeInOut(duration: 0.2), value: viewModel.banner)
            }
            .frame(width: fullWidth, height: fullHeight)
            .ignoresSafeArea()
        }
        .background(Color.black.ignoresSafeArea())
        .sheet(item: $sheet) { which in
            sheetContent(which, mode: mode)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(BrandColors.surface)
                .preferredColorScheme(.dark)
        }
        .sheet(item: $sharing) { item in
            ShareSheet(capture: item)
                .presentationDetents([.medium, .large])
        }
        .onAppear {
            // Whatever was on the stage belongs to a 3D view that is gone: every fresh screen starts empty.
            viewModel.resetStage()
            enterMode(mode)
            // The trigger below may already have run and had its character wiped by the reset just above.
            placeStarterIfDue(mode: mode, live: sceneLive, packsLoaded: viewModel.packsLoaded, again: true)
        }
        .onChange(of: mode) { _, newMode in
            starterPlacedFor = nil
            enterMode(newMode)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                // The creator may be coming back from the system settings page.
                cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
            } else {
                // Rendering stops when the app leaves the foreground, which would freeze the video: end it there.
                capture.stopIfRecording()
                viewModel.flushSettings()
            }
        }
        // Decided once, from the packs that are installed when the scene comes up. With none installed there is no
        // starter for this visit: the first character will come from the library, and the view model puts that
        // one on the stage itself (unless a take is running).
        .onChange(of: StarterTrigger(mode: mode, live: sceneLive, packsLoaded: viewModel.packsLoaded), initial: true) { _, trigger in
            placeStarterIfDue(mode: trigger.mode, live: trigger.live, packsLoaded: trigger.packsLoaded, again: false)
        }
        .onChange(of: stage.actors.map(\.id), initial: true) { _, ids in
            placedYaw = placedYaw.filter { ids.contains($0.key) }
            for actor in stage.actors where placedYaw[actor.id] == nil {
                placedYaw[actor.id] = actor.yawDegrees
            }
            if ids.count < 2 { stage.applyToAll = false }
        }
    }

    // MARK: pieces

    @ViewBuilder
    private func stageContent(mode: StageMode, cameraGranted: Bool) -> some View {
        if mode == .studio || cameraGranted {
            StageView(
                mode: mode,
                state: viewModel.stage,
                capture: viewModel.capture,
                settings: viewModel.settings,
                onArUnavailable: { viewModel.onArUnavailable() },
                onShutter: {
                    // The volume keys are the shutter, unless a sheet is in the way.
                    if sheet == nil { viewModel.capture.toggleRecording() }
                }
            )
            // A controller serves one mode: switching rebuilds the view.
            .id(mode)
        } else if cameraStatus == .notDetermined {
            BusyPill(text: Strings.checkingAR)
        } else {
            CameraPermissionCard(
                onAllow: { openSystemSettings() },
                onStudio: { viewModel.setMode(.studio) }
            )
            .padding(24)
        }
    }

    @ViewBuilder
    private func messageBar(_ banner: Banner) -> some View {
        if let action = banner.action {
            MessageBar(text: banner.text, actionLabel: Strings.share, action: { perform(action) })
        } else {
            MessageBar(text: banner.text)
        }
    }

    @ViewBuilder
    private func sheetContent(_ which: Sheet, mode: StageMode) -> some View {
        let stage = viewModel.stage
        switch which {
        case .characters:
            CharacterSheet(
                packs: viewModel.packs,
                library: viewModel.library,
                mode: mode,
                onStageIds: Set(stage.actors.map(\.pack.id)),
                armedId: stage.armedPack?.id,
                canAddMore: stage.canAddMore,
                importing: viewModel.importing,
                onChoose: { viewModel.choosePack($0) },
                onRefresh: { viewModel.refreshCatalog() },
                onDownload: { viewModel.downloadPack($0) },
                onCancelDownload: { viewModel.cancelDownload($0) },
                onRetryDownload: { viewModel.retryDownload($0) },
                onImport: { viewModel.importPack(from: $0) },
                onDelete: { viewModel.deletePack($0) }
            )
        case .music:
            MusicSheet(
                tracks: viewModel.musicTracks,
                settings: viewModel.settings,
                player: viewModel.musicPlayer,
                importing: viewModel.importingMusic,
                onSelect: { viewModel.selectMusic($0) },
                onChange: { change in viewModel.updateSettings(change) },
                onImport: { viewModel.importMusic(from: $0) },
                onDelete: { viewModel.deleteMusic($0) }
            )
        case .settings:
            SettingsSheet(
                settings: viewModel.settings,
                versionName: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
                microphoneBlocked: viewModel.microphoneBlocked,
                musicSelected: viewModel.musicTrack != nil,
                onChange: { change in viewModel.updateSettings(change) },
                onMicrophoneChange: { viewModel.setMicrophone($0) }
            )
        }
    }

    // MARK: behaviour

    /// What entering a mode needs: AR needs a device that can do it and the camera permission.
    private func enterMode(_ mode: StageMode) {
        guard mode == .ar else { return }
        guard ArSupport.isSupported else {
            viewModel.onArUnavailable()
            return
        }
        cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        if cameraStatus == .notDetermined {
            Task {
                _ = await AVCaptureDevice.requestAccess(for: .video)
                cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
            }
        }
    }

    /// A scene that has just come up empty gets the character used last time. Once per visit of a mode (unless
    /// `again`): after that an empty stage is the creator's choice.
    private func placeStarterIfDue(mode: StageMode, live: Bool, packsLoaded: Bool, again: Bool) {
        guard live, packsLoaded, again || starterPlacedFor != mode else { return }
        starterPlacedFor = mode
        // Does nothing when the stage already has a character or an armed pack.
        viewModel.placeStarter()
    }

    private func faceCamera(_ actor: StageActor?, mode: StageMode) {
        guard let actor else { return }
        // Studio characters are added facing the camera, which is heading 0.
        let placed: Float? = mode == .studio ? 0 : placedYaw[actor.id]
        if let placed { actor.yawDegrees = placed }
    }

    private func perform(_ action: Banner.Action) {
        switch action {
        case .share(let capture):
            viewModel.dismissBanner()
            sharing = capture
        }
    }

    /// iOS asks for a permission once; after a refusal only the system settings page can grant it.
    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

/// When to hand an empty scene its starter character.
private struct StarterTrigger: Equatable {
    let mode: StageMode
    let live: Bool
    let packsLoaded: Bool
}

/// Everything SwiftUI draws over the 3D view inside the stage box. None of it ends up in a capture.
private struct StageOverlays: View {
    let stage: StageState
    let selected: StageActor?
    let mode: StageMode
    let settings: AppSettings
    let capture: CaptureController
    let logo: UIImage?
    let importing: Bool
    /// A picked audio file is being copied into the app.
    let importingMusic: Bool
    /// A character is being downloaded from the library.
    let downloading: Bool
    let chromeTop: CGFloat
    let stageSize: CGSize

    var body: some View {
        let watermark = settings.watermarkEnabled ? logo : nil
        ZStack {
            if settings.safeZoneGuides { SafeZoneGuides() }
            if let watermark { WatermarkPreview(logo: watermark, settings: settings) }

            VStack(spacing: 8) {
                if capture.isRecording {
                    RecordingPill(elapsedMillis: capture.elapsedMillis)
                } else if mode == .ar, let hint = Strings.arHint(stage.arHint) {
                    HintPill(text: hint)
                }
                if capture.isAddingMusic { BusyPill(text: Strings.addingMusic) }
                if importing { BusyPill(text: Strings.importing) }
                if importingMusic { BusyPill(text: Strings.importingMusic) }
                if downloading { BusyPill(text: Strings.downloadingPack) }
                if let selected {
                    switch selected.load {
                    case .loading: BusyPill(text: Strings.loading)
                    case .failed: ErrorPill(text: Strings.loadFailedMessage(selected.name))
                    case .ready:
                        if selected.animationUnavailable { ErrorPill(text: Strings.animationUnavailable) }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.top, statusTop(watermark: watermark))
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)

            if let seconds = capture.countdown {
                CountdownOverlay(seconds: seconds, onCancel: { capture.cancelCountdown() })
            }
        }
    }

    /// Status lines go under the top bar, and under the logo when that sits along the top edge.
    private func statusTop(watermark: UIImage?) -> CGFloat {
        var logoBottom: CGFloat = 0
        if let watermark, settings.watermarkAnchor.isTop, watermark.size.height > 0 {
            logoBottom = CGFloat(WatermarkLayout.place(
                frameWidth: Float(stageSize.width),
                frameHeight: Float(stageSize.height),
                logoAspect: Float(watermark.size.width / watermark.size.height),
                anchor: settings.watermarkAnchor,
                widthFraction: settings.watermarkWidth
            ).bottom)
        }
        return max(chromeTop, logoBottom) + 8
    }
}
