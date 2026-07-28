import SwiftUI
import ARKit

struct ARCoverageView: UIViewRepresentable {
    let sceneView: ARSCNView

    func makeUIView(context: Context) -> ARSCNView { sceneView }
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

struct ARCoverageScreen: View {
    @ObservedObject var sessionManager: ARSessionManager
    let isRecording: Bool
    let onToggleRecording: () -> Void

    var body: some View {
        Group {
            if sessionManager.isLiDARSupported {
                ZStack(alignment: .top) {
                    ARCoverageView(sceneView: sessionManager.sceneView)
                        .ignoresSafeArea()
                        .overlay(Color.black.opacity(0.12).ignoresSafeArea())

                    VStack {
                        if let message = sessionManager.trackingMessage {
                            Text(message)
                                .padding(8)
                                .background(.black.opacity(0.6))
                                .foregroundColor(.white)
                                .cornerRadius(8)
                                .padding(.top, 12)
                        }
                        Text("Scan quality: \(Int(sessionManager.qualityPercentage))%")
                            .padding(8)
                            .background(.black.opacity(0.6))
                            .foregroundColor(.white)
                            .cornerRadius(8)
                        Spacer()
                        Button(action: onToggleRecording) {
                            ZStack {
                                Circle().fill(Color.red).frame(width: 88, height: 88)
                                if isRecording {
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.white)
                                        .frame(width: 28, height: 28)
                                }
                            }
                        }
                        .accessibilityLabel(isRecording ? "Stop Recording" : "Start Recording")
                        .padding(.bottom, 32)
                    }
                }
            } else {
                Text("LiDAR is required to scan rooms.")
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            }
        }
    }
}
