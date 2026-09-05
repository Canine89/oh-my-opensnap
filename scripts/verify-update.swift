import Foundation
import CryptoKit

// 개인키를 읽지 않고 앱에 내장된 공개키로 실제 업데이트 파일을 검증한다.
do {
    let args = CommandLine.arguments
    guard args.count == 4,
          let signature = Data(base64Encoded: args[2]),
          let publicKey = Data(base64Encoded: args[3]) else {
        throw NSError(domain: "업데이트 검증 인자 오류", code: 1)
    }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
    let archive = try Data(contentsOf: URL(fileURLWithPath: args[1]))
    guard key.isValidSignature(signature, for: archive) else {
        throw NSError(domain: "앱 공개키와 업데이트 서명이 일치하지 않습니다", code: 2)
    }
} catch {
    FileHandle.standardError.write(Data("✗ \(error)\n".utf8))
    exit(1)
}
