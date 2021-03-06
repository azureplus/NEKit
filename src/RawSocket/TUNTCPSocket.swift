import Foundation
import tun2socks

/// The TCP socket build upon `TSTCPSocket`.
///
/// - warning: This class is not thread-safe, it is expected that the instance is accessed on the `queue` only.
public class TUNTCPSocket: RawTCPSocketProtocol, TSTCPSocketDelegate {
    private let tsSocket: TSTCPSocket
    private var readTag: Int?
    private var pendingReadData: NSMutableData = NSMutableData()
    private var writeTag: Int!
    private var remainWriteLength: Int = 0
    private var closeAfterWriting = false

    private var scanner: StreamScanner?

    private var readLength: Int?

    /**
     Initailize an instance with `TSTCPSocket`.

     - parameter socket: The socket object to work with.
     */
    public init(socket: TSTCPSocket) {
        tsSocket = socket
        tsSocket.delegate = self
    }

    // MARK: RawTCPSocketProtocol implemention

    /// The `RawTCPSocketDelegate` instance.
    public weak var delegate: RawTCPSocketDelegate?

    /// Every method call and variable access must operated on this queue. And all delegate methods will be called on this queue.
    ///
    /// - warning: This should be set as soon as the instance is initialized.
    public var queue: dispatch_queue_t!

    /// If the socket is connected.
    public var isConnected: Bool {
        return tsSocket.isConnected
    }

    /// The source address.
    public var sourceIPAddress: IPv4Address? {
        return IPv4Address(fromInAddr: tsSocket.sourceAddress)
    }

    /// The source port.
    public var sourcePort: Port? {
        return Port(port: tsSocket.sourcePort)
    }

    /// The destination address.
    public var destinationIPAddress: IPv4Address? {
        return IPv4Address(fromInAddr: tsSocket.destinationAddress)
    }

    /// The destination port.
    public var destinationPort: Port? {
        return Port(port: tsSocket.destinationPort)
    }

    /**
     `TUNTCPSocket` cannot connect to anything actively, this is just a stub method.
     */
    public func connectTo(host: String, port: Int, enableTLS: Bool, tlsSettings: [NSObject : AnyObject]?) throws {}

    /**
     Disconnect the socket.

     The socket will disconnect elegantly after any queued writing data are successfully sent.
     */
    public func disconnect() {
        if !isConnected {
            delegate?.didDisconnect(self)
        } else {
            closeAfterWriting = true
            checkStatus()
        }
    }

    /**
     Disconnect the socket immediately.
     */
    public func forceDisconnect() {
        if !isConnected {
            delegate?.didDisconnect(self)
        } else {
            tsSocket.close()
        }
    }

    /**
     Send data to local.

     - parameter data: Data to send.
     - parameter tag:  The tag identifying the data in the callback delegate method.
     - warning: This should only be called after the last write is finished, i.e., `delegate?.didWriteData()` is called.
     */
    public func writeData(data: NSData, withTag tag: Int) {
        writeTag = tag
        remainWriteLength = data.length
        tsSocket.writeData(data)
    }

    /**
     Read data from the socket.

     - parameter tag: The tag identifying the data in the callback delegate method.
     - warning: This should only be called after the last read is finished, i.e., `delegate?.didReadData()` is called.
     */
    public func readDataWithTag(tag: Int) {
        readTag = tag
        checkReadData()
    }

    /**
     Read specific length of data from the socket.

     - parameter length: The length of the data to read.
     - parameter tag:    The tag identifying the data in the callback delegate method.
     - warning: This should only be called after the last read is finished, i.e., `delegate?.didReadData()` is called.
     */
    public func readDataToLength(length: Int, withTag tag: Int) {
        readLength = length
        readTag = tag
        checkStatus()
    }

    /**
     Read data until a specific pattern (including the pattern).

     - parameter data: The pattern.
     - parameter tag:  The tag identifying the data in the callback delegate method.
     - warning: This should only be called after the last read is finished, i.e., `delegate?.didReadData()` is called.
     */
    public func readDataToData(data: NSData, withTag tag: Int) {
        readDataToData(data, withTag: tag, maxLength: 0)
    }

    /**
     Read data until a specific pattern (including the pattern).

     - parameter data: The pattern.
     - parameter tag:  The tag identifying the data in the callback delegate method.
     - parameter maxLength: Ignored since `GCDAsyncSocket` does not support this. The max length of data to scan for the pattern.
     - warning: This should only be called after the last read is finished, i.e., `delegate?.didReadData()` is called.
     */
    public func readDataToData(data: NSData, withTag tag: Int, maxLength: Int) {
        readTag = tag
        scanner = StreamScanner(pattern: data, maximumLength: maxLength)
        checkStatus()
    }

    private func queueCall(block: ()->()) {
        dispatch_async(queue, block)
    }

    private func checkReadData() {
        if pendingReadData.length > 0 {
            queueCall {
                // the didReadData might change the `readTag`
                guard let tag = self.readTag else {
                    // no queued read request
                    return
                }

                if let readLength = self.readLength {
                    if self.pendingReadData.length >= readLength {
                        let returnData = self.pendingReadData.subdataWithRange(NSRange(location: 0, length: readLength))
                        self.pendingReadData = NSMutableData(data: self.pendingReadData.subdataWithRange(NSRange(location: readLength, length: self.pendingReadData.length - readLength)))

                        self.readLength = nil
                        self.delegate?.didReadData(returnData, withTag: tag, from: self)
                        self.readTag = nil
                    }
                } else if let scanner = self.scanner {
                    guard let (match, rest) = scanner.addAndScan(self.pendingReadData) else {
                        return
                    }

                    self.scanner = nil
                    self.readTag = nil

                    guard let matchData = match else {
                        // do not find match in the given length, stop now
                        return
                    }

                    self.pendingReadData = NSMutableData(data: rest)
                    self.delegate?.didReadData(matchData, withTag: tag, from: self)
                } else {
                    self.readTag = nil
                    self.delegate?.didReadData(self.pendingReadData, withTag: tag, from: self)
                    self.pendingReadData = NSMutableData()
                }
            }
        }
    }

    private func checkStatus() {
        if closeAfterWriting && remainWriteLength == 0 {
            forceDisconnect()
        }
    }

    // MARK: TSTCPSocketDelegate implemention
    // The local stop sending anything.
    // Theoretically, the local may still be reading data from remote.
    // However, there is simply no way to know if the local is still open, so we can only assume that the local side close tx only when it decides that it does not need to read anymore.
    public func localDidClose(socket: TSTCPSocket) {
        disconnect()
    }

    public func socketDidReset(socket: TSTCPSocket) {
        socketDidClose(socket)
    }

    public func socketDidAbort(socket: TSTCPSocket) {
        socketDidClose(socket)
    }

    public func socketDidClose(socket: TSTCPSocket) {
        queueCall {
            self.delegate?.didDisconnect(self)
            self.delegate = nil
        }
    }

    public func didReadData(data: NSData, from: TSTCPSocket) {
        queueCall {
            self.pendingReadData.appendData(data)
            self.checkReadData()
        }
    }

    public func didWriteData(length: Int, from: TSTCPSocket) {
        queueCall {
            self.remainWriteLength -= length
            if self.remainWriteLength <= 0 {

                self.delegate?.didWriteData(nil, withTag: self.writeTag, from: self)
                self.checkStatus()
            }
        }
    }
}
