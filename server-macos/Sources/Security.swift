import Foundation
import Security
import CryptoKit
import CommonCrypto
import Network

struct ServerFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class ServerSecurity {
    let directory: URL
    private(set) var fingerprint = ""
    private(set) var identity: sec_identity_t?
    private var salt = Data()
    private var verifier = Data()
    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let passwordFile = directory.appendingPathComponent("password.json")
        if let data = try? Data(contentsOf: passwordFile), let json = try? JSONSerialization.jsonObject(with: data) as? [String:String],
           let s = json["salt"].flatMap({ Data(base64Encoded:$0) }), let v = json["verifier"].flatMap({ Data(base64Encoded:$0) }) {
            salt=s; verifier=v
        }
    }
    var hasPassword: Bool { salt.count == 32 && verifier.count == 32 }
    func setPassword(_ password: String) throws {
        guard password.utf8.count >= 8, password.utf8.count <= 1024 else { throw ServerFailure(message:"Choose a password between 8 and 1024 characters.") }
        var random = [UInt8](repeating:0,count:32)
        guard SecRandomCopyBytes(kSecRandomDefault,random.count,&random) == errSecSuccess else { throw ServerFailure(message:"Could not create secure random data.") }
        salt = Data(random); verifier = derive(password)
        let data = try JSONSerialization.data(withJSONObject:["salt":salt.base64EncodedString(),"verifier":verifier.base64EncodedString()])
        let url = directory.appendingPathComponent("password.json")
        try data.write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
    func verify(_ password: String) -> Bool {
        guard hasPassword, password.utf8.count <= 1024 else { return false }
        let value = derive(password)
        var difference: UInt8 = 0
        for (a,b) in zip(value,verifier) { difference |= a ^ b }
        return value.count == verifier.count && difference == 0
    }
    private func derive(_ password: String) -> Data {
        var out = Data(count:32)
        let pass = Array(password.utf8)
        out.withUnsafeMutableBytes { output in salt.withUnsafeBytes { saltBytes in pass.withUnsafeBytes { passBytes in
            _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passBytes.baseAddress?.assumingMemoryBound(to:CChar.self), pass.count,
                                    saltBytes.baseAddress?.assumingMemoryBound(to:UInt8.self), salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                    150_000, output.baseAddress?.assumingMemoryBound(to:UInt8.self), 32)
        } } }
        return out
    }
    func loadIdentity() throws {
        let cert = directory.appendingPathComponent("certificate.pem")
        let p12 = directory.appendingPathComponent("identity.p12")
        let secret = directory.appendingPathComponent("identity.pass")
        if !FileManager.default.fileExists(atPath:p12.path) {
            let key = directory.appendingPathComponent("identity.key")
            let randomPassword = UUID().uuidString + UUID().uuidString
            try randomPassword.write(to:secret,atomically:true,encoding:.utf8)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:secret.path)
            defer { try? FileManager.default.removeItem(at:key) }
            try runOpenSSL(["req","-x509","-newkey","ec","-pkeyopt","ec_paramgen_curve:P-256","-pkeyopt","ec_param_enc:named_curve","-nodes","-days","3650","-subj","/CN=SU Remote","-keyout",key.path,"-out",cert.path])
            try runOpenSSL(["pkcs12","-export","-inkey",key.path,"-in",cert.path,"-out",p12.path,"-passout","file:"+secret.path])
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:p12.path)
        }
        let pass = try String(contentsOf:secret,encoding:.utf8)
        let data = try Data(contentsOf:p12)
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData,[kSecImportExportPassphrase as String:pass,kSecImportToMemoryOnly as String:true] as CFDictionary,&items)
        guard status == errSecSuccess, let first = (items as? [[String:Any]])?.first,
              let imported = first[kSecImportItemIdentity as String] else { throw ServerFailure(message:"Could not load the server's TLS identity (\(status)).") }
        let secIdentity = imported as! SecIdentity
        identity = sec_identity_create(secIdentity)
        var leaf: SecCertificate?
        guard SecIdentityCopyCertificate(secIdentity,&leaf) == errSecSuccess, let certificate = leaf else { throw ServerFailure(message:"TLS certificate is unavailable.") }
        fingerprint = SHA256.hash(data:SecCertificateCopyData(certificate) as Data).map { String(format:"%02X",$0) }.joined(separator:":")
    }
    private func runOpenSSL(_ arguments: [String]) throws {
        let task = Process(); task.executableURL=URL(fileURLWithPath:"/usr/bin/openssl"); task.arguments=arguments
        let error = Pipe(); task.standardError=error; task.standardOutput=FileHandle.nullDevice
        try task.run(); task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw ServerFailure(message:"Could not generate the server's local TLS identity.") }
    }
}
