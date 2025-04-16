//
//  utilsApp.swift
//  utils
//
//  Created by zkt on 2024/11/27.
//

import SwiftUI
import UIKit
import BackgroundTasks

@main
struct utilsApp: App {
    // 使用WebServer单例
    @State private var webServer = WebServer.shared
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate
    
    init() {
        // 配置后台任务
        if #available(iOS 13.0, *) {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.zkt.clipsync.clipboardProcessing", using: nil) { task in
                AppDelegate.shared.handleClipboardTask(task: task as! BGProcessingTask)
            }
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView(webServer: webServer)
                .onAppear {
                    // 异步启动Web服务器
                    DispatchQueue.global(qos: .userInitiated).async {
                        webServer.start()
                    }
                }
        }
    }
}

class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static let shared = AppDelegate()
    
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        // 添加后台模式支持
        application.setMinimumBackgroundFetchInterval(UIApplication.backgroundFetchIntervalMinimum)
        
        // 注册通知
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                print("通知权限已获取")
            } else if let error = error {
                print("通知权限获取失败: \(error)")
            }
        }
        
        // 设置通知代理
        UNUserNotificationCenter.current().delegate = self
        
        
        return true
    }

    
    // 处理应用在前台时收到通知的情况
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                              willPresent notification: UNNotification,
                              withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // 允许在前台显示通知
        completionHandler([.alert, .sound])
    }
    
    func applicationDidEnterBackground(_ application: UIApplication) {
        if #available(iOS 13.0, *) {
            scheduleClipboardTask()
        }
    }
    
    @available(iOS 13.0, *)
    func scheduleClipboardTask() {
        let request = BGProcessingTaskRequest(identifier: "com.zkt.clipsync.clipboardProcessing")
        request.earliestBeginDate = Date(timeIntervalSinceNow: 1) // 1秒后开始
        
        do {
            try BGTaskScheduler.shared.submit(request)
            print("后台剪切板任务已安排")
        } catch {
            print("无法安排后台任务: \(error)")
        }
    }
    
    @available(iOS 13.0, *)
    func handleClipboardTask(task: BGProcessingTask) {
        // 创建一个任务完成标记
        let taskCompletionHandler = { (success: Bool) in
            task.setTaskCompleted(success: success)
        }
        
        // 设置过期处理
        task.expirationHandler = {
            taskCompletionHandler(false)
        }
        
        // 检查是否有待处理的剪切板内容
        if let pendingMessage = UserDefaults.standard.string(forKey: "pendingClipboardMessage") {
            // 尝试设置剪切板
            UIPasteboard.general.string = pendingMessage
            print("后台任务: 已将消息复制到剪切板: \(pendingMessage)")
            
            // 发送本地通知
            sendClipboardNotification(message: pendingMessage)
            
            taskCompletionHandler(true)
        } else {
            taskCompletionHandler(true)
        }
        
        // 安排下一个任务
        scheduleClipboardTask()
    }
    
    private func sendClipboardNotification(message: String) {
        let content = UNMutableNotificationContent()
        content.title = "收到新内容"
        content.body = "点击复制内容: \(message)"
        content.sound = .default
        
        // 添加用户信息标识这是一个剪贴板通知
        content.userInfo = ["notificationType": "clipboard"]
        
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
        
        // 确保在主线程上发送通知以更新历史记录
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: NSNotification.Name("AddToClipboardHistory"), object: nil, userInfo: ["message": message])
        }
        
        // 清除待处理消息
        UserDefaults.standard.removeObject(forKey: "pendingClipboardMessage")
    }
    
}

struct ContentView: View {
    
    let webServer: WebServer
    @State private var clipboardHistory: [String] = []
    @State private var expandedIndices: Set<Int> = []
    
    // 添加状态更新监听
    @State private var serverStatus: Bool = false
    
    // Toast状态控制
    @State private var showToast: Bool = false
    @State private var toastMessage: String = ""
    // 添加用于保存定时器的属性
    @State private var toastTimer: Timer? = nil
    
    var body: some View {
        ZStack {
            // 主视图内容
            VStack(spacing: 0) {
                VStack(spacing: 5) {
                    Text(serverStatus ? "Web 服务正在运行" : "Web 服务启动中")
                        .font(.title)
                    
                    HStack {
                        Text(serverStatus ? "访问地址: \(webServer.serverHost):\(String(webServer.serverPort))" : "启动中")
                            .font(.subheadline)
                            .foregroundColor(serverStatus ? .green : .red)
                        
                        Spacer()
                        
                        // 仅在服务运行时显示停止按钮
                        if serverStatus {
                            Button(action: {
                                restartService()
                            }) {
                                Text("重启服务")
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(Color.blue)
                                    .cornerRadius(6)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(Color.blue.opacity(0.1))
                    .cornerRadius(8)
                }
                .padding(.vertical, 5)
                
                // 历史记录列表
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("历史记录")
                            .font(.headline)
                        Spacer()
                        Button("清空") {
                            clipboardHistory.removeAll()
                            expandedIndices.removeAll()
                        }
                        .foregroundColor(.red)
                    }
                    .padding(.bottom, 5)
                    
                    if clipboardHistory.isEmpty {
                        Spacer()
                        Text("没有历史记录")
                            .foregroundColor(.gray)
                            .frame(maxWidth: .infinity, alignment: .center)
                        Spacer()
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                ForEach(Array(clipboardHistory.enumerated()), id: \.offset) { index, message in
                                    ClipboardHistoryItemView(
                                        message: message,
                                        isExpanded: expandedIndices.contains(index),
                                        toggleExpand: {
                                            // 切换展开/收缩状态
                                            if expandedIndices.contains(index) {
                                                expandedIndices.remove(index)
                                            } else {
                                                expandedIndices.insert(index)
                                            }
                                        },
                                        copyToClipboard: {
                                            // 复制到剪贴板
                                            UIPasteboard.general.string = message
                                            // 显示反馈
                                            showToastMessage("已复制：\(message)")
                                        }
                                    )
                                }
                            }
                            .padding(.vertical, 5)
                        }
                    }
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
                .padding(.top, 10)
                // 使用Spacer()后，这个区域会自动填充剩余空间
                .frame(maxHeight: .infinity)
            }
            .padding()
            
            // Toast覆盖层
            if showToast {
                VStack {
                    Spacer()
                    Text(toastMessage)
                        .font(.system(size: 15))
                        .foregroundColor(.white)
                        .padding()
                        .background(Color.black.opacity(0.7))
                        .cornerRadius(10)
                        .padding(.bottom, 50)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(100) // 确保Toast显示在顶层
                .animation(.easeInOut, value: showToast)
            }
        }
        .onAppear {
            // 初始化状态监听
            setupNotifications()
            // 初始化服务器状态
            serverStatus = webServer.isRunning
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            // 应用回到前台时，检查是否有待处理的剪切板内容
            let hasPendingMessage = UserDefaults.standard.string(forKey: "pendingClipboardMessage") != nil
            
            if hasPendingMessage {
                if let pendingMessage = UserDefaults.standard.string(forKey: "pendingClipboardMessage") {
                    UIPasteboard.general.string = pendingMessage
                    print("应用回到前台: 已将消息复制到剪切板: \(pendingMessage)")
                    
                    // 添加到历史记录
                    addToHistory(message: pendingMessage)
                    
                    // 显示反馈
                    showToastMessage("已复制：\(pendingMessage)")
                    
                    UserDefaults.standard.removeObject(forKey: "pendingClipboardMessage")
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("AddToClipboardHistory"))) { notification in
            // 从通知中获取消息并添加到历史记录
            if let message = notification.userInfo?["message"] as? String {
                addToHistory(message: message)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ProcessPendingClipboard"))) { _ in
            // 处理待处理的剪贴板内容
            if let pendingMessage = UserDefaults.standard.string(forKey: "pendingClipboardMessage") {
                // 复制到剪贴板
                UIPasteboard.general.string = pendingMessage
                print("收到前台处理通知: 已将消息复制到剪切板: \(pendingMessage)")
                
                // 添加到历史记录
                addToHistory(message: pendingMessage)
                
                // 显示反馈
                showToastMessage("已复制：\(pendingMessage)")
                
                // 清除待处理消息
                UserDefaults.standard.removeObject(forKey: "pendingClipboardMessage")
            }
        }
    }
    
    // MARK: - 初始化和生命周期方法
    private func setupNotifications() {
        // 监听服务器状态变化
        NotificationCenter.default.addObserver(forName: NSNotification.Name("WebServerStatusChanged"), object: nil, queue: .main) { _ in
            self.serverStatus = self.webServer.isRunning
        }
    }
    
    // 添加消息到历史记录
    private func addToHistory(message: String) {
        // 避免重复
        if !clipboardHistory.contains(message) {
            clipboardHistory.insert(message, at: 0) // 新消息添加到最前面
        }
    }
    
    // 显示Toast消息
    private func showToastMessage(_ message: String) {
        // 处理文本截断
        let maxLength = 15
        
        // 截断文本
        let displayText = message.count > maxLength ? "\(message.prefix(maxLength))..." : message
        
        // 更新Toast消息内容
        self.toastMessage = displayText
        
        // 取消之前可能存在的定时器
        toastTimer?.invalidate()
        
        // 如果Toast未显示，则显示；否则只更新内容并重置计时器
        if !self.showToast {
            withAnimation {
                self.showToast = true
            }
        }
        
        // 设置隐藏定时器
        hideToastAfterDelay()
        
        print("复制成功: \(message)")
    }
    
    // 延迟隐藏Toast
    private func hideToastAfterDelay() {
        // 创建新的定时器
        toastTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { _ in
            withAnimation {
                self.showToast = false
            }
            // 清理定时器引用
            self.toastTimer = nil
        }
    }
    
    // 添加停止服务的方法
    private func stopService() {
        // 停止Web服务器
        webServer.stop()
        
        // 取消所有后台任务
        if #available(iOS 13.0, *) {
            BGTaskScheduler.shared.cancelAllTaskRequests()
        }
        
        // 退出应用
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            exit(0)
        }
    }
    
    // 添加重启服务的方法
    private func restartService() {
        // 显示服务重启中的提示信息
        showToastMessage("服务重启中...")
        
        // 调用WebServer的restart方法
        webServer.restart()
        
    }
}

// 历史记录项视图组件
struct ClipboardHistoryItemView: View {
    let message: String
    let isExpanded: Bool
    let toggleExpand: () -> Void
    let copyToClipboard: () -> Void
    
    // 样式常量
    private let buttonStyle: some ShapeStyle = Color.blue
    private let buttonTextColor: Color = .white
    private let buttonPadding: EdgeInsets = EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8)
    private let buttonCornerRadius: CGFloat = 4
    private let buttonFontSize: CGFloat = 14
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(.system(size: 15))
                .foregroundColor(.black)
                .padding(.vertical, 4)
                .multilineTextAlignment(.leading)
            
            HStack {
                Spacer()
                
                Button("复制") {
                    copyToClipboard()
                }
                .font(.system(size: buttonFontSize))
                .foregroundColor(buttonTextColor)
                .padding(buttonPadding)
                .background(buttonStyle)
                .cornerRadius(buttonCornerRadius)
            }
        }
        .padding(10)
        .background(Color.blue.opacity(0.1))
        .cornerRadius(8)
        .shadow(color: Color.black.opacity(0.1), radius: 2, x: 0, y: 1)
    }
}
