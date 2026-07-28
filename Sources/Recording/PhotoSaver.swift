import Photos

enum PhotoSaver {
    static func save(videoURL: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                completion(.failure(NSError(
                    domain: "PhotoSaver",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Photos permission not granted"]
                )))
                return
            }

            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: videoURL)
            }, completionHandler: { success, error in
                DispatchQueue.main.async {
                    if success {
                        completion(.success(()))
                    } else {
                        completion(.failure(error ?? NSError(domain: "PhotoSaver", code: 2)))
                    }
                }
            })
        }
    }
}
