/*
 *  Olvid for iOS
 *  Copyright © 2019-2023 Olvid SAS
 *
 *  This file is part of Olvid for iOS.
 *
 *  Olvid is free software: you can redistribute it and/or modify
 *  it under the terms of the GNU Affero General Public License, version 3,
 *  as published by the Free Software Foundation.
 *
 *  Olvid is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU Affero General Public License for more details.
 *
 *  You should have received a copy of the GNU Affero General Public License
 *  along with Olvid.  If not, see <https://www.gnu.org/licenses/>.
 */

import Foundation
import ObvCrypto
import ObvEncoder

public struct Chunk {
    
    public let index: Int
    public let data: Data // Cleartext
    
    private init(index: Int, data: Data) {
        self.index = index
        self.data = data
    }
    
    private static let errorDomain = "Chunk"
    
    private static func makeError(message: String) -> Error {
        let userInfo = [NSLocalizedFailureReasonErrorKey: message]
        return NSError(domain: errorDomain, code: 0, userInfo: userInfo)
    }

    public static func readFromURL(_ url: URL, offset: Int, length: Int, index: Int) throws -> Chunk {

        let chunk: Chunk
        
        do {
            let fd = open(url.path, O_RDONLY)
            guard fd != -1 else {
                throw Self.makeError(message: "Failed to read from URL (bad fd)")
            }
            guard offset == lseek(fd, Int64(offset), SEEK_SET) else {
                assertionFailure()
                throw Self.makeError(message: "Failed to read from URL (bad lseek)")
            }
            let chunkPointer = UnsafeMutableRawPointer.allocate(byteCount: length, alignment: 1)
            let lengthRead = read(fd, chunkPointer, length)
            guard length == lengthRead else {
                assertionFailure()
                free(chunkPointer)
                close(fd)
                throw Self.makeError(message: "Failed to read from URL (bad length)")
            }
            let chunkData = Data(bytes: chunkPointer, count: length)
            chunk = Chunk(index: index, data: chunkData)
            free(chunkPointer)
            close(fd)
        }
        
        return chunk
        
    }

    public func writeToURL(_ url: URL, offset: Int) throws {
        
        // Make sure the url exists
        do {
            let directory = url.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
        }
        
        let fd = open(url.path, O_RDWR)
        guard fd != -1 else {
            assertionFailure()
            throw Self.makeError(message: "Failed to read from URL (bad fd)")
        }
        guard offset == lseek(fd, Int64(offset), SEEK_SET) else {
            assertionFailure()
            throw Self.makeError(message: "Failed to read from URL (bad lseek)")
        }
        let lengthWritten: Int = data.withUnsafeBytes { (rawBufferPtr) in
            guard let rawPtr = rawBufferPtr.baseAddress else { return -1 }
            return write(fd, rawPtr, data.count)
        }
        guard lengthWritten == data.count else {
            assertionFailure()
            throw Self.makeError(message: "Failed to read from URL (bad lengthWritten)")
        }
        close(fd)
    }
    
    public func encrypt(with key: AuthenticatedEncryptionKey) -> EncryptedData {
        let prngService = ObvCryptoSuite.sharedInstance.prngService()
        let authEnc = key.algorithmImplementationByteId.algorithmImplementation
        let encodedChunk = self.obvEncode()
        return try! authEnc.encrypt(encodedChunk.rawData, with: key, and: prngService) // Cannot throw in this case
    }

    
    public static func decrypt(encryptedChunk: EncryptedData, with key: AuthenticatedEncryptionKey) throws -> Chunk {
        let authEnc = key.algorithmImplementationByteId.algorithmImplementation
        let rawEncodedChunk = try authEnc.decrypt(encryptedChunk, with: key)
        guard let encodedChunk = ObvEncoded(withRawData: rawEncodedChunk) else {
            throw Self.makeError(message: "ObvEncoded init failed")
        }
        guard let chunk = Chunk(encodedChunk) else {
            throw Self.makeError(message: "Chunk init failed")
        }
        return chunk
    }
        
    public static func decrypt(encryptedChunkAtFileHandle fh: FileHandle, with key: AuthenticatedEncryptionKey) throws -> Chunk {
        fh.seek(toFileOffset: 0)
        let encryptedChunkRaw = try fh.readToEnd()
        guard let data = encryptedChunkRaw else { throw Chunk.makeError(message: "No chunk data found at file handle") }
        let encryptedChunk = EncryptedData(data: data)
        return try decrypt(encryptedChunk: encryptedChunk, with: key)
    }
    
    public static func cleartextLengthFromEncryptedLength(_ encryptedLength: Int, whenUsingEncryptionKey key: AuthenticatedEncryptionKey) throws -> Int {
        let encodedChunkLength = try AuthenticatedEncryption.plaintexLength(forCiphertextLength: encryptedLength, whenDecryptedUnder: key)
        guard let length = Chunk.lengthOfInnerData(forLengthOfObvEncodedChunk: encodedChunkLength) else {
            throw makeError(message: "Could not parse the cleartext length from the encrypted length")
        }
        return length
    }
    
    
    public static func encryptedLengthFromCleartextLength(_ cleartextLength: Int, whenUsingEncryptionKey key: AuthenticatedEncryptionKey) -> Int {
        let encodedChunkLength = Chunk.lengthWhenObvEncoded(forLengthOfInnerData: cleartextLength)
        return AuthenticatedEncryption.ciphertextLength(forPlaintextLength: encodedChunkLength, whenEncryptedUnder: key)
    }

    
}


extension Chunk: ObvCodable {
    
    public func obvEncode() -> ObvEncoded {
        let encodedIndex = self.index.obvEncode()
        let encodedData = self.data.obvEncode()
        return [encodedIndex, encodedData].obvEncode()
    }
    
    public init?(_ obvEncoded: ObvEncoded) {
        guard let decodedList = [ObvEncoded](obvEncoded) else { return nil }
        guard decodedList.count == 2 else { return nil }
        let encodedIndex = decodedList[0]
        let encodedData = decodedList[1]
        guard let index = Int(encodedIndex) else { return nil }
        guard let data = Data(encodedData) else { return nil }
        self.init(index: index, data: data)
    }
    
    public static func lengthOfInnerData(forLengthOfObvEncodedChunk lengthOfEncoded: Int) -> Int? {
        let length = lengthOfEncoded - 2*ObvEncoded.lengthOverhead - Int.lengthWhenObvEncoded
        guard length >= 0 else { return nil }
        return length
    }
    
    public static func lengthWhenObvEncoded(forLengthOfInnerData length: Int) -> Int {
        return length + 2*ObvEncoded.lengthOverhead + Int.lengthWhenObvEncoded
    }
    
    public static func innerDataLength(fromLengthWhenEncoded encodedLength: Int) -> Int? {
        let res = encodedLength - (2*ObvEncoded.lengthOverhead + Int.lengthWhenObvEncoded)
        guard res >= 0 else { return nil }
        return res
    }
}
