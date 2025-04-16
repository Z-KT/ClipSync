import Foundation
import NIO
import NIOHTTP1
import UIKit
import UserNotifications
import BackgroundTasks

class WebServer {
    private var group: EventLoopGroup?
    private var channel: Channel?
    
    // 添加公共属性存储服务器地址信息
    public private(set) var serverHost: String = "0.0.0.0"
    public private(set) var serverPort: Int = 8080
    public private(set) var isRunning: Bool = false
    
    // 更健壮的单例实现
    static let shared = WebServer()
    
    // 私有化init方法，确保只能通过shared访问
    private init() {
        // 配置后台任务
        if #available(iOS 13.0, *) {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.zkt.clipsync.clipboardProcessing", using: nil) { task in
                AppDelegate.shared.handleClipboardTask(task: task as! BGProcessingTask)
            }
        }
    }
    
    func start() {
        // 先获取设备IP地址
        if let deviceIP = getDeviceIPAddress() {
            if !deviceIP.isEmpty {
                serverHost = deviceIP
            }
        }
        
        group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        
        guard let group = group else { return }
        
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(HTTPHandler())
                }
            }
        
        do {
            channel = try bootstrap.bind(host: serverHost, port: serverPort).wait()
            if let localAddress = channel?.localAddress {
                print("Server started and listening on \(localAddress)")
                // 设置服务器状态
                isRunning = true
                
                // 通知主界面更新
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: NSNotification.Name("WebServerStatusChanged"), object: nil)
                }
            }
        } catch {
            print("Failed to start server: \(error)")
            isRunning = false
        }
    }
    
    func stop() {
        do {
            try channel?.close().wait()
            try group?.syncShutdownGracefully()
            isRunning = false
            
            // 通知主界面更新
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: NSNotification.Name("WebServerStatusChanged"), object: nil)
            }
        } catch {
            print("Error shutting down server: \(error)")
        }
    }
    
    // 添加重启服务方法
    func restart() {
        // 先停止当前服务
        stop()
        
        // 短暂延迟确保资源完全释放
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            // 在后台线程启动服务
            DispatchQueue.global(qos: .userInitiated).async {
                // 重新启动服务
                self.start()
            }
        }
    }
    
    // 添加获取设备IP地址的公共方法
    private func getDeviceIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        
        guard getifaddrs(&ifaddr) == 0 else { return nil }
        defer { freeifaddrs(ifaddr) } // 确保释放内存
        
        var ptr = ifaddr
        while ptr != nil {
            defer { ptr = ptr?.pointee.ifa_next } // 移动到下一个接口
            
            let interface = ptr!.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family
            
            // 仅处理 IPv4
            guard addrFamily == UInt8(AF_INET) else { continue }
            
            // 检查接口名称和状态
            let name = String(cString: interface.ifa_name)
            let isActive = (interface.ifa_flags & UInt32(IFF_UP)) != 0 &&
                           (interface.ifa_flags & UInt32(IFF_RUNNING)) != 0
            
            if isActive && (name == "en0" || name == "en2") { // 通常 Wi-Fi 是 en0
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(
                    interface.ifa_addr,
                    socklen_t(interface.ifa_addr.pointee.sa_len),
                    &hostname,
                    socklen_t(hostname.count),
                    nil,
                    socklen_t(0),
                    NI_NUMERICHOST
                )
                let ip = String(cString: hostname)
                
                // 跳过本地链路地址（169.254.x.x）
                if !ip.hasPrefix("169.254") {
                    address = ip
                    break // 优先选择第一个有效地址
                }
            }
        }
        
        return address
    }
}

private final class HTTPHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    
    // 添加属性来存储当前请求的信息
    private var currentRequestHeader: HTTPRequestHead?
    private var currentRequestBodyData = ByteBuffer()
    
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let reqPart = unwrapInboundIn(data)
        
        switch reqPart {
        case .head(let header):
            // 仅在非OPTIONS请求时打印路径
            if header.method != .OPTIONS {
                print(header.uri)
            }
            
            // 保存当前请求头
            currentRequestHeader = header
            // 清空之前的body数据
            currentRequestBodyData = ByteBuffer()
            
        case .body(let bodyPart):
            // 累积body数据
            var bodyPart = bodyPart
            currentRequestBodyData.writeBuffer(&bodyPart)
            
        case .end:
            // 请求结束，处理完整请求
            guard let header = currentRequestHeader else { return }
            
            // 检查是否为OPTIONS请求
            if header.method == .OPTIONS {
                handleOptionsRequest(context: context, header: header)
            }
            // 检查请求路径
            else if header.uri == "/" {
                handleRootRequest(context: context, header: header)
            } else if header.uri == "/send" && header.method == .POST {
                handleSendRequest(context: context, header: header, body: currentRequestBodyData)
            } else {
                handleDefaultRequest(context: context, header: header)
            }
            
            // 清空当前请求数据
            currentRequestHeader = nil
            currentRequestBodyData = ByteBuffer()
        }
    }
    
    private func handleRootRequest(context: ChannelHandlerContext, header: HTTPRequestHead) {
        // 获取设备IP地址
        let deviceIP = WebServer.shared.serverHost
        let serverPort = WebServer.shared.serverPort
        let targetURL = "http://\(deviceIP):\(serverPort)/send"
        
        // 设置响应头
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/html; charset=utf-8")
        
        let responseHead = HTTPResponseHead(
            version: header.version,
            status: .ok,
            headers: headers
        )
        
        // 读取index.html文件内容
        if let path = Bundle.main.path(forResource: "index", ofType: "html") {
            do {
                var htmlContent = try String(contentsOfFile: path, encoding: .utf8)
                // 替换目标URL参数
                htmlContent = htmlContent.replacingOccurrences(of: "const targetUrl = '';", 
                                                              with: "const targetUrl = '\(targetURL)';")
                
                var buffer = ByteBuffer()
                buffer.writeString(htmlContent)
                
                // 发送响应
                context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
                context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
                context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
            } catch {
                print("无法读取index.html文件: \(error)")
                sendErrorResponse(context: context, header: header)
            }
        } else {
            print("找不到index.html文件，路径: \(Bundle.main.bundlePath)/web/index.html")
            sendErrorResponse(context: context, header: header)
        }
    }
    
    private func handleDefaultRequest(context: ChannelHandlerContext, header: HTTPRequestHead) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain")
        
        let responseHead = HTTPResponseHead(
            version: header.version,
            status: .ok,
            headers: headers
        )
        
        let body = "Hello from Utils Web Server!"
        var buffer = context.channel.allocator.buffer(capacity: body.utf8.count)
        buffer.writeString(body)
        
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
    
    private func handleSendRequest(context: ChannelHandlerContext, header: HTTPRequestHead, body: ByteBuffer) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")

        // 读取post请求的body
        let bodyData = body
        if let bodyString = bodyData.getString(at: 0, length: bodyData.readableBytes) {
            print("收到POST请求body内容: \(bodyString)")
            
            // 处理消息内容
            processMessageFromBodyString(bodyString)
        } else {
            print("POST请求body为空或无法读取")
        }
        
        // 返回JSON响应
        let responseHead = HTTPResponseHead(
            version: header.version,
            status: .ok,
            headers: headers
        )
        
        let responseJson = "{\"status\":\"success\",\"message\":\"数据已接收\"}"
        var buffer = context.channel.allocator.buffer(capacity: responseJson.utf8.count)
        buffer.writeString(responseJson)
        
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
    
    // 从请求body中提取并处理消息
    private func processMessageFromBodyString(_ bodyString: String) {
        // 尝试解析JSON
        if let jsonData = bodyString.data(using: .utf8) {
            do {
                if let jsonObject = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any] {
                    // 提取消息内容
                    if let message = jsonObject["message"] as? String {
                        print("解析到消息内容: \(message)")
                        
                        // 使用主线程来处理后续操作
                        DispatchQueue.main.async {
                            // 保存消息并根据应用状态处理
                            self.handleReceivedMessage(message)
                        }
                    }
                }
            } catch {
                print("JSON解析错误: \(error)")
            }
        }
    }
    
    // 处理接收到的消息
    private func handleReceivedMessage(_ message: String) {
        // 将消息保存到UserDefaults，便于在前台时使用
        UserDefaults.standard.set(message, forKey: "pendingClipboardMessage")
        // 发送通知以更新历史记录
        NotificationCenter.default.post(name: NSNotification.Name("AddToClipboardHistory"), object: nil, userInfo: ["message": message])
        
        // 判断应用状态，如果在后台则发送本地通知
        let appState = UIApplication.shared.applicationState
        if appState == .background {
            // 后台处理
            handleMessageInBackground(message)
        } else {
            // 前台处理
            handleMessageInForeground()
        }
    }
    
    // 在应用处于后台时处理消息
    private func handleMessageInBackground(_ message: String) {
        // 发送本地通知
        let content = UNMutableNotificationContent()
        content.title = "收到新内容"
        content.body = "点击复制内容: \(message)"
        content.sound = .default
        
        // 设置通知图标 - 使用应用主图标
        content.threadIdentifier = "clipboard"  // 分组通知
        
        // 添加用户信息标识这是一个剪贴板通知
        content.userInfo = ["notificationType": "clipboard", "message": message]
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
        
        // 请求后台执行时间
        let taskID = UIApplication.shared.beginBackgroundTask {
            // 如果后台执行时间结束，确保清理
            print("后台执行时间已用尽")
        }
        
        if taskID != .invalid {
            // 当在后台时，不要主动复制到剪贴板，让主界面处理
            print("后台处理: 消息已保存等待前台处理")
            UIApplication.shared.endBackgroundTask(taskID)
        }
    }
    
    // 在应用处于前台时处理消息
    private func handleMessageInForeground() {
        // 前台时，直接让主应用处理剪贴板操作
        // 发送一个"处理剪贴板"的通知
        NotificationCenter.default.post(name: NSNotification.Name("ProcessPendingClipboard"), object: nil)
        print("前台处理: 已请求主界面处理剪贴板内容")
    }
    
    private func sendErrorResponse(context: ChannelHandlerContext, header: HTTPRequestHead) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain")
        
        let responseHead = HTTPResponseHead(
            version: header.version,
            status: .internalServerError,
            headers: headers
        )
        
        let body = "Internal Server Error"
        var buffer = context.channel.allocator.buffer(capacity: body.utf8.count)
        buffer.writeString(body)
        
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
    
    private func handleOptionsRequest(context: ChannelHandlerContext, header: HTTPRequestHead) {
        // 使用自定义日志而不是打印详细信息
        // print("处理OPTIONS预检请求: \(header.uri)")
        
        var headers = HTTPHeaders()
        headers.add(name: "Access-Control-Allow-Origin", value: "*")
        headers.add(name: "Access-Control-Allow-Methods", value: "GET, POST, OPTIONS")
        headers.add(name: "Access-Control-Allow-Headers", value: "Content-Type")
        
        let responseHead = HTTPResponseHead(
            version: header.version,
            status: .ok,
            headers: headers
        )
        
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
}
