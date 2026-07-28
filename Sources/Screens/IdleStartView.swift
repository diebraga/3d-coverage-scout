import SwiftUI

struct IdleStartView: View {
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Button(action: onStart) {
                ZStack {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 88, height: 88)
                    Image(systemName: "plus")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            .accessibilityLabel("Start Recording")
            Text("Start Recording")
                .font(.headline)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}

#Preview {
    IdleStartView(onStart: {})
}
