import SwiftUI
import Combine
import LibWhisper
import CheetahIPC

enum AnswerRequest {
    case none
    case answerQuestion
    case refineAnswer(selection: Range<String.Index>?)
    case analyzeCode
}

let defaultWhisperModel = "ggml-medium.en"

class AppViewModel: ObservableObject {
    @AppStorage("authToken") var authToken: String?
    @AppStorage("useGPT4") var useGPT4: Bool?
    
    @Published var devices = [CaptureDevice]()
    @Published var selectedDevice: CaptureDevice?
    
    @Published var whisperModel = defaultWhisperModel
    @Published var downloadState = ModelDownloader.State.pending
    
    @Published var analyzer: ConversationAnalyzer?
    @Published var answerRequest = AnswerRequest.none
    
    @Published var transcript: String?
    @Published var answer: String?
    @Published var codeAnswer: String?
    
    @Published var buttonsAlwaysEnabled = false
}

@main
struct CheetahApp: App {
    @AppStorage("whisperModel") var preferredWhisperModel: String?
    
    @ObservedObject var viewModel = AppViewModel()
    
    @State var download: ModelDownloader?
    @State var stream: WhisperStream?
    @State var ipcServer: IPCServer?
    
    var extensionState = BrowserExtensionState()
    
    func start() async {
        viewModel.devices = try! CaptureDevice.devices
        
        let downloadConfig = URLSessionConfiguration.default
        downloadConfig.allowsExpensiveNetworkAccess = false
        downloadConfig.waitsForConnectivity = true
        
        viewModel.whisperModel = preferredWhisperModel ?? defaultWhisperModel
        let download = ModelDownloader(modelName: viewModel.whisperModel, configuration: downloadConfig)
        download.$state.assign(to: &viewModel.$downloadState)
        download.resume()
        self.download = download
        
        // Handle messages from ExtensionHelper
        let server = IPCServer()
        server.delegate = extensionState
        server.addSourceForNewLocalMessagePort(name: MessagePortName.browserExtensionServer.rawValue,
                                               toRunLoop: RunLoop.main.getCFRunLoop())
        self.ipcServer = server
        
        // Install manifest needed for the browser extension to talk to ExtensionHelper
        _ = try? installNativeMessagingManifest()
        
        do {
            for try await request in viewModel.$answerRequest.receive(on: RunLoop.main).values {
                if let analyzer = viewModel.analyzer {
                    switch request {
                    case .answerQuestion:
                        try await analyzer.answer()
                        viewModel.answer = analyzer.context[.answer]
                        viewModel.codeAnswer = analyzer.context[.codeAnswer]
                        viewModel.answerRequest = .none
                    
                    case .refineAnswer(let selection):
                        try await analyzer.answer(refine: true, selection: selection)
                        viewModel.answer = analyzer.context[.answer]
                        viewModel.codeAnswer = analyzer.context[.codeAnswer]
                        viewModel.answerRequest = .none
                        
                    case .analyzeCode:
                        try await analyzer.analyzeCode(extensionState: extensionState)
                        viewModel.answer = analyzer.context[.answer]
                        viewModel.answerRequest = .none
                        
                    case .none:
                        break
                    }
                }
            }
        } catch {
            viewModel.answerRequest = .none
            //TODO: handle error
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .task {
                    await start()
                }
                .onChange(of: viewModel.selectedDevice) {
                    setCaptureDevice($0)
                }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
    }
    
    func setCaptureDevice(_ device: CaptureDevice?) {
        stream?.cancel()
        
        guard let device = device,
              let authToken = viewModel.authToken,
              let modelURL = download?.modelURL else {
            return
        }
        
        let stream = WhisperStream(model: modelURL, device: device)
        stream.start()
        self.stream = stream
        
        stream.$segments
            .receive(on: RunLoop.main)
            .map { String($0.text) }
            .assign(to: &viewModel.$transcript)
        
        viewModel.analyzer = ConversationAnalyzer(
            stream: stream,
            generator: PromptGenerator(),
            executor: .init(authToken: authToken, useGPT4: viewModel.useGPT4 ?? false))
    }
}
