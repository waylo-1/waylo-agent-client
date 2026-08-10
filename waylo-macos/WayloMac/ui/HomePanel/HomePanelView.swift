import SwiftUI

/// The floating task-input panel shown from the menu bar.
struct HomePanelView: View {
    @StateObject private var engine = GuidanceEngine.shared
    @StateObject private var agent = AgentEngine.shared
    @StateObject private var skill = SkillSession.shared
    @ObservedObject private var history = TaskHistory.shared
    /// "Learn an app" input + the fetched curriculum for the active session.
    @State private var skillInput = ""
    @State private var curriculum: WayloAPIClient.Curriculum?
    @State private var taskText = ""
    /// Optional user-typed starting context ("Pages is already open", "I'm on the
    /// Sheets tab") — helps the planner start from the right place for NATIVE apps
    /// it can't fully read (behind-window / plan-ahead). Web pages are auto-read
    /// from the URL, so this is only occasionally needed.
    @State private var whereContext = ""
    @State private var showWhereContext = false
    @State private var emailInput = ""
    @State private var signedIn = UserAccount.isSignedIn
    @State private var isLoading = false
    @State private var isListening = false
    @State private var language = LanguagePreference.current
    @State private var errorMessage: String?
    /// History entry whose share link was just copied (shows a ✓ briefly).
    @State private var copiedEntryID: UUID?

    /// Toggles the developer/milestone testing tools.
    @State private var showDevTools = false
    /// Opt-in: save downscaled screenshots with harvested YOLO training
    /// examples (off by default — screenshots otherwise never touch disk).
    @State private var captureTrainingImages =
        UserDefaults.standard.bool(forKey: YOLODetector.captureTrainingImagesKey)
    @State private var testFindDescription = ""
    @State private var layerTestLabel = ""
    @State private var layerTestResults: [String] = []
    @State private var layerTestRunning = false
    @State private var copiedDebugReport = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            Divider()

            if agent.isRunning {
                // Agent mode ("Do it for me") in flight: live action feed +
                // a way OUT — Esc or this button.
                agentActivity
            } else if !engine.isRunning {
                // isRunning flips false the moment a guide finishes, so the
                // completion state must be shown here — the .complete branch
                // inside activeGuidance is never reached.
                if engine.state == .complete { completionBanner }
                taskInput
                learnSection
                if showDevTools { devTools }
                recentHistory
            } else {
                activeGuidance
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    // MARK: - Learn an app (continuous skill sessions + curricula)

    private var learnSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            if let session = skill.active {
                // Active session: progress + lessons + end.
                HStack {
                    Image(systemName: "graduationcap.fill").foregroundColor(.red)
                    Text("Learning \(session.skill)").font(.caption).fontWeight(.semibold)
                    Spacer()
                    Text("\(session.completed.count) done").font(.caption2).foregroundColor(.secondary)
                    Button("End") { skill.end(); curriculum = nil }
                        .buttonStyle(.borderless).font(.caption)
                }
                if let cur = curriculum {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(cur.lessons.enumerated()), id: \.offset) { i, lesson in
                            let done = session.completed.contains(lesson.task)
                            Button {
                                skill.setLessonIndex(i)
                                taskText = lesson.task
                                startTask()
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: done ? "checkmark.circle.fill" : "\(i + 1).circle")
                                        .foregroundColor(done ? .green : .secondary)
                                    Text(lesson.title).font(.caption)
                                        .strikethrough(done, color: .secondary)
                                        .foregroundColor(done ? .secondary : .primary)
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    Text("Free session — every task you finish is remembered, so follow-ups like “now make it bold” just work.")
                        .font(.caption2).foregroundColor(.secondary)
                }
            } else {
                // No session: start one, or resume a stored one.
                HStack(spacing: 6) {
                    Image(systemName: "graduationcap").foregroundColor(.secondary)
                    TextField("Learn an app (e.g. Google Sheets)", text: $skillInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .onSubmit { startLearning(skillInput) }
                    Button("Start") { startLearning(skillInput) }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(skillInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if !skill.stored.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(skill.stored.prefix(4)) { s in
                                Button("\(s.skill) · \(s.completed.count)✓") { startLearning(s.skill) }
                                    .buttonStyle(.bordered).controlSize(.mini).font(.caption2)
                            }
                        }
                    }
                }
            }
        }
    }

    private func startLearning(_ name: String) {
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return }
        skill.start(skill: clean)
        skillInput = ""
        curriculum = nil
        Task { @MainActor in
            // Authored curriculum if one exists; free-form session otherwise.
            curriculum = await WayloAPIClient.shared.fetchCurriculum(for: clean)
            if let c = curriculum {
                DebugLogger.log("SESSION", "curriculum '\(c.displayName)' (\(c.lessons.count) lessons)")
            }
        }
    }

    // MARK: - Agent activity ("Do it for me" running)

    private var agentActivity: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Doing it for you…")
                    .font(.headline)
                Spacer()
                Button("Stop") { agent.stop() }
                    .buttonStyle(.bordered)
                    .tint(.red)
            }
            if !agent.statusMessage.isEmpty {
                Text(agent.statusMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(3)
            }
            Text("Press Esc anytime to stop")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Image(systemName: "cursorarrow.rays")
                .foregroundColor(.red)
                .font(.title2)
            Text("Waylo")
                .font(.title2)
                .fontWeight(.bold)
            Spacer()
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help("Quit Waylo")
            if engine.isRunning {
                Button(L10n.t("stop")) { engine.stopGuidance() }
                    .buttonStyle(.bordered)
                    .tint(.red)
            } else {
                Button {
                    showDevTools.toggle()
                } label: {
                    Image(systemName: "hammer")
                }
                .buttonStyle(.borderless)
                .help("Developer tools")
            }
        }
    }

    // MARK: - Completion banner (shown after a guide finishes)

    private var completionBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.t("task_complete"))
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Text("Rate it under Recent so it's right next time.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button {
                    engine.stopGuidance() // resets state to .idle, dismissing this
                } label: {
                    Image(systemName: "xmark").font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Dismiss")
            }
            // In a curriculum session, offer the next lesson right here so the
            // user isn't left wondering how to continue.
            if let next = nextLesson {
                Button {
                    engine.stopGuidance()
                    skill.setLessonIndex(next.index)
                    taskText = next.lesson.task
                    startTask()
                } label: {
                    Label("Next lesson: \(next.lesson.title)", systemImage: "arrow.right.circle.fill")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }
        }
        .padding(10)
        .background(Color.green.opacity(0.12))
        .cornerRadius(10)
    }

    /// The first not-yet-done lesson of the active curriculum, if any.
    private var nextLesson: (index: Int, lesson: WayloAPIClient.Curriculum.Lesson)? {
        guard let session = skill.active, let cur = curriculum else { return nil }
        for (i, l) in cur.lessons.enumerated() where !session.completed.contains(l.task) {
            return (i, l)
        }
        return nil
    }

    // MARK: - Recent history (rate each guide: ✓ correct / ✗ wrong)

    @ViewBuilder
    private var recentHistory: some View {
        if !history.entries.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Recent")
                    .font(.caption)
                    .foregroundColor(.secondary)
                ForEach(Array(history.entries.prefix(4))) { entry in
                    HStack(spacing: 8) {
                        Text(entry.task)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 6)
                        Button { shareGuide(entry) } label: {
                            Image(systemName: copiedEntryID == entry.id
                                  ? "checkmark" : "square.and.arrow.up")
                                .foregroundColor(copiedEntryID == entry.id ? .green : .secondary)
                        }
                        .buttonStyle(.borderless)
                        .help(copiedEntryID == entry.id ? "Link copied!" : "Copy a shareable link")
                        switch entry.feedback {
                        case .none:
                            Button { history.markCorrect(entry) } label: {
                                Image(systemName: "checkmark.circle").foregroundColor(.green)
                            }
                            .buttonStyle(.borderless)
                            .help("Correct — remember this for next time")
                            Button { history.markWrong(entry) } label: {
                                Image(systemName: "xmark.circle").foregroundColor(.red)
                            }
                            .buttonStyle(.borderless)
                            .help("Wrong — forget this path")
                        case .correct:
                            Label("Saved", systemImage: "checkmark.circle.fill")
                                .labelStyle(.iconOnly)
                                .foregroundColor(.green)
                        case .wrong:
                            Label("Forgotten", systemImage: "xmark.circle.fill")
                                .labelStyle(.iconOnly)
                                .foregroundColor(.red)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Task input

    private var taskInput: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Lightweight sign-in: capture the email once so usage is tracked per
            // user (business evidence + the free-tier limit). The Vercel site also
            // captures it; this covers app-first users. Hidden once signed in.
            if !signedIn {
                HStack(spacing: 8) {
                    TextField("Sign in with your email", text: $emailInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { signInWithEmail() }
                    Button("Sign in") { signInWithEmail() }
                        .buttonStyle(.bordered)
                        .disabled(!emailInput.contains("@"))
                }
            }

            Text(L10n.t("ask_prompt"))
                .font(.subheadline)
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                TextField("e.g. How do I make a chart in Excel", text: $taskText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { startTask() }
                    .onChange(of: taskText) { errorMessage = nil }

                Button {
                    startVoiceInput()
                } label: {
                    Image(systemName: isListening ? "waveform" : "mic.fill")
                        .foregroundColor(isListening ? .red : nil)
                }
                .buttonStyle(.bordered)
                .disabled(isListening)
                .help(isListening ? "Listening…" : "Speak your task")
            }

            if isListening {
                Text(L10n.t("listening"))
                    .font(.caption)
                    .foregroundColor(.red)
            }

            // Optional starting-context field — collapsed by default so it never
            // clutters the common case. Web pages are read from the URL
            // automatically; this is for native apps Waylo can't fully see.
            if showWhereContext {
                TextField("Where are you now? e.g. \"Pages is already open\"", text: $whereContext)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .onSubmit { startTask() }
            } else {
                Button {
                    withAnimation { showWhereContext = true }
                } label: {
                    Label("Add where I am now (optional)", systemImage: "location")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }

            Button(L10n.t("start_guide")) { startTask() }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(taskText.trimmingCharacters(in: .whitespaces).isEmpty || isLoading)

            VStack(alignment: .leading, spacing: 2) {
                Picker("Mode", selection: Binding(
                    get: { engine.mode },
                    set: { engine.mode = $0 }
                )) {
                    Text("Teach me").tag(GuideMode.teach)
                    Text("Do it with me").tag(GuideMode.assist)
                    Text("Do it for me").tag(GuideMode.agent)
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .labelsHidden()
                Text(engine.mode == .agent
                     ? "Waylo does the whole task itself; risky actions still ask you first"
                     : engine.mode == .assist
                     ? "Waylo clicks safe steps itself; risky ones you confirm"
                     : "Waylo points and you click, so you learn it — but it opens apps for you")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Picker("Voice", selection: $language) {
                ForEach(LanguagePreference.allCases, id: \.self) { lang in
                    Text(lang.displayName).tag(lang)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .onChange(of: language) { LanguagePreference.current = language }

            // Nudge to download a better voice when only the robotic compact
            // one is installed (common for Hindi — only "Lekha compact" ships).
            if language != .english && language.hasOnlyCompactVoice {
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Download a clearer \(language.displayName) voice", systemImage: "speaker.wave.2")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .help("Opens Spoken Content → System Voice → Manage Voices, where you can download an enhanced voice")
            }

            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.8)
                    Text(L10n.t("generating"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
    }

    // MARK: - Active guidance

    private var activeGuidance: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Status row + step counter.
            HStack {
                statusDot
                Text(stateLabel)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                if engine.stepCount > 0 {
                    Text("Step \(engine.currentStepIndex + 1) of \(engine.stepCount)")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.secondary)
                }
            }

            // Progress bar.
            if engine.stepCount > 0 {
                ProgressView(value: progressValue)
                    .tint(.red)
            }

            // Current instruction.
            Text(engine.currentInstruction)
                .font(.body)
                .fontWeight(.medium)
                .fixedSize(horizontal: false, vertical: true)

            if engine.state == .locating {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text(engine.statusMessage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else if engine.state == .manual {
                Text(engine.statusMessage)
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            // Controls.
            if engine.state == .complete {
                Button(L10n.t("done")) { engine.stopGuidance() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            } else {
                controls
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    engine.previousStep()
                } label: {
                    Label(L10n.t("back"), systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)
                .disabled(engine.currentStepIndex == 0 || engine.state == .locating)

                if engine.state == .paused {
                    Button {
                        engine.resumeGuide()
                    } label: {
                        Label(L10n.t("resume"), systemImage: "play.fill")
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        engine.pauseGuide()
                    } label: {
                        Label(L10n.t("pause"), systemImage: "pause.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(engine.state == .locating)
                }

                Button {
                    engine.nextStep()
                } label: {
                    Label(L10n.t("next"), systemImage: "chevron.right")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(engine.state == .locating || engine.state == .paused)
            }

            HStack {
                Button {
                    engine.debugRelocate()
                } label: {
                    Label("That's wrong — re-check", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .tint(.orange)
                .disabled(engine.state == .locating)

                Spacer()

                Text("⌃⌥⌘N to re-check")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 8, height: 8)
    }

    private var statusColor: Color {
        switch engine.state {
        case .locating: return .orange
        case .paused: return .yellow
        case .manual: return .orange
        case .complete: return .green
        default: return .green
        }
    }

    private var stateLabel: String {
        switch engine.state {
        case .idle: return "Ready"
        case .locating: return "Finding element…"
        case .showing: return "Click the red dot"
        case .manual: return "Needs your help"
        case .paused: return "Paused"
        case .complete: return "Complete"
        }
    }

    private var progressValue: Double {
        guard engine.stepCount > 0 else { return 0 }
        if engine.state == .complete { return 1 }
        return Double(engine.currentStepIndex) / Double(engine.stepCount)
    }

    // MARK: - Developer / milestone tools

    private var devTools: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("Developer Tools")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)

            // Experimental: Gemini computer-use decider for AX-hostile apps
            // (plain screenshot → grounded action; falls back to Set-of-Mark
            // on any error, so it can only improve things).
            Toggle(isOn: Binding(
                get: { AgentEngine.computerUseEnabled },
                set: { UserDefaults.standard.set($0, forKey: AgentEngine.computerUseKey) }
            )) {
                Text("Gemini computer-use (experimental — uses far more credits)").font(.caption)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)

            // Milestone 1 — AX tree logger.
            Button("Log frontmost AX tree to console") {
                logFrontmostElements()
            }
            .buttonStyle(.bordered)

            Button {
                copyDebugReport()
            } label: {
                Label(copiedDebugReport ? "Copied!" : "Copy debug report",
                      systemImage: copiedDebugReport ? "checkmark" : "doc.on.clipboard")
            }
            .buttonStyle(.bordered)
            .help("Copies versions, permissions, pipeline state, and the last 200 log lines — paste it in a bug report")

            // Milestone 2 — hardcoded dot.
            Button("Show test dot at (400, 300)") {
                OverlayWindowController.shared.showDot(at: CGPoint(x: 400, y: 300))
            }
            .buttonStyle(.bordered)

            Button("Hide test dot") {
                OverlayWindowController.shared.hideDot()
            }
            .buttonStyle(.bordered)

            // Milestone 3 — dot on a named element.
            HStack(spacing: 8) {
                TextField("Find element, e.g. Bold button", text: $testFindDescription)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { findAndShowDot() }
                Button("Find") { findAndShowDot() }
                    .buttonStyle(.bordered)
            }

            Toggle(isOn: $captureTrainingImages) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Contribute training screenshots").font(.caption)
                    Text("Only for steps you clicked correctly AND marked ✓. Saved on-device and sent to Waylo to improve detection.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .onChange(of: captureTrainingImages) {
                UserDefaults.standard.set(captureTrainingImages, forKey: YOLODetector.captureTrainingImagesKey)
            }

            // Layer self-test: run EVERY layer independently on the current
            // screen and show each one's verdict. Switch to the target app
            // first (the panel stays open), then press Test.
            Divider()
            Text("Layer self-test (L0 AX · L1 OCR · cache · YOLO · Nova)")
                .font(.caption2)
                .foregroundColor(.secondary)
            HStack(spacing: 8) {
                TextField("Element to find, e.g. Empty", text: $layerTestLabel)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { runLayerSelfTest() }
                Button("Test") { runLayerSelfTest() }
                    .buttonStyle(.bordered)
                    .disabled(layerTestRunning)
            }
            if layerTestRunning {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.6)
                    Text("Running all layers…").font(.caption2).foregroundColor(.secondary)
                }
            }
            ForEach(layerTestResults, id: \.self) { line in
                Text(line)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(line.contains("HIT") ? .green : .secondary)
                    .lineLimit(2)
            }
        }
    }

    // MARK: - Actions

    private func signInWithEmail() {
        let e = emailInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard e.contains("@"), e.contains(".") else { return }
        UserAccount.signIn(email: e, source: "app")
        signedIn = UserAccount.isSignedIn
        emailInput = ""
    }

    private func startTask() {
        let task = taskText.trimmingCharacters(in: .whitespaces)
        guard !task.isEmpty else { return }

        // Direct intents (open a site, web search, launch an app) execute
        // instantly — no plan, no dot, no cost.
        if let intent = IntentShortcuts.match(task) {
            let spoken = IntentShortcuts.perform(intent)
            Speaker.shared.speak(spoken)
            taskText = ""
            errorMessage = nil
            return
        }

        // Autonomous app control ("play drake on spotify", "pause the music",
        // "directions to X") — AppleScript / URI schemes, no plan, no vision.
        if let action = AppActions.match(task) {
            taskText = ""
            errorMessage = nil
            Task { @MainActor in
                let spoken = await AppActions.perform(action)
                Speaker.shared.speak(spoken)
            }
            return
        }

        // Agent mode: no plan — the observe→act loop does the task itself.
        if engine.mode == .agent {
            taskText = ""
            errorMessage = nil
            Task { @MainActor in
                await AgentEngine.shared.run(task: task)
            }
            return
        }

        isLoading = true
        errorMessage = nil

        NSLog("[Waylo] startTask pressed: '%@'", task)
        Task {
            do {
                // Ground the plan in the live screen (local AX read, ~free).
                let context = ScreenContextBuilder.build()
                DebugLogger.log("PLAN", "screenContext \(context.count) chars")
                let userCtx = whereContext.trimmingCharacters(in: .whitespacesAndNewlines)
                if !userCtx.isEmpty { DebugLogger.log("PLAN", "userContext: '\(userCtx)'") }
                let plan = try await WayloAPIClient.shared.generatePlan(
                    task: task, screenContext: context,
                    sessionContext: SkillSession.shared.contextForPlan(),
                    userContext: userCtx)
                NSLog("[Waylo] generatePlan OK: %d steps", plan.steps.count)
                isLoading = false
                taskText = ""
                GuidanceEngine.shared.startGuidance(plan: plan)
            } catch {
                NSLog("[Waylo] generatePlan FAILED: %@", String(describing: error))
                isLoading = false
                if case let APIError.serverMessage(detail) = error {
                    errorMessage = "The server couldn't make a guide: \(detail)"
                } else {
                    errorMessage = "Failed to generate guide. Check your internet connection."
                }
            }
        }
    }

    /// Assembles a self-contained bug report (environment, permissions,
    /// pipeline state, recent log) and puts it on the clipboard.
    private func copyDebugReport() {
        var r: [String] = []
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        r.append("=== Waylo debug report — \(Date()) ===")
        r.append("app: \(version) (\(build))  macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        r.append("backend: \(AppConfig.backendBaseURL)")
        r.append("permissions: ax=\(AXIsProcessTrusted()) screen=\(ScreenRecordingPermission.isGranted)")
        r.append("mode: \(engine.mode.rawValue)  language: \(LanguagePreference.current.rawValue)")
        r.append("guide: running=\(engine.isRunning) step=\(engine.currentStepIndex + 1)/\(engine.stepCount) state=\(engine.state)")
        let d = DebugState.shared
        r.append("pipeline: app='\(d.targetApp)' layer='\(d.layerResolved)' dot=\(d.dotPosition) cache=\(d.cacheStatus) yolo=\(d.yoloResult)")
        r.append("--- last \(DebugLogger.recentLines().count) log lines ---")
        r.append(contentsOf: DebugLogger.recentLines())
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(r.joined(separator: "\n"), forType: .string)
        copiedDebugReport = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { copiedDebugReport = false }
    }

    /// Runs every detection layer independently against the entered label.
    private func runLayerSelfTest() {
        let label = layerTestLabel.trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty, !layerTestRunning else { return }
        layerTestRunning = true
        layerTestResults = []
        Task {
            guard ScreenRecordingPermission.isGranted,
                  let capture = await ScreenCapturer.shared.captureActiveScreen() else {
                layerTestResults = ["Couldn't capture the screen — check Screen Recording permission."]
                layerTestRunning = false
                return
            }
            layerTestResults = await CoordinateResolver.shared.diagnose(capture: capture, label: label)
            layerTestRunning = false
        }
    }

    /// Saves the guide to the backend and copies the shareable link.
    private func shareGuide(_ entry: TaskHistory.Entry) {
        Task {
            do {
                let saved = try await WayloAPIClient.shared.saveGuide(task: entry.task, steps: entry.steps)
                let link = saved.url.isEmpty ? saved.id : saved.url
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link, forType: .string)
                copiedEntryID = entry.id
                DebugLogger.log("SHARE", "guide saved id=\(saved.id) — link copied")
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if copiedEntryID == entry.id { copiedEntryID = nil }
            } catch {
                DebugLogger.log("SHARE", "saveGuide failed: \(error.localizedDescription)")
                errorMessage = "Couldn't create a share link. Please try again."
            }
        }
    }

    private func startVoiceInput() {
        isListening = true
        MicHandler.shared.listen { result in
            DispatchQueue.main.async {
                isListening = false
                if let text = result { taskText = text }
            }
        }
    }

    private func logFrontmostElements() {
        let elements = AccessibilityReader.shared.getTargetAppElements()
        print("=== Waylo AX tree (target: \(TargetAppTracker.shared.targetName)): \(elements.count) interactive elements ===")
        for element in elements {
            print("[\(element.role)] '\(element.title)' desc='\(element.description)' "
                  + "center=(\(Int(element.center.x)), \(Int(element.center.y)))")
        }
        print("=== end ===")
    }

    private func findAndShowDot() {
        let query = testFindDescription.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        if let element = ElementFinder.shared.findElement(description: query) {
            let cocoa = ScreenCoordinates.axToCocoa(element.center)
            print("[Waylo] Found '\(element.title)' role=\(element.role)")
            print("        AX frame=\(element.frame) center=\(element.center)")
            print("        Cocoa center=\(cocoa)")
            OverlayWindowController.shared.showDot(at: element.center)
        } else {
            print("[Waylo] No element matched '\(query)'")
        }
    }
}

#Preview {
    HomePanelView()
}
