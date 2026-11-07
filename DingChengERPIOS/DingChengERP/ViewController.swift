import UIKit
import WebKit

/// 鼎城 ERP：App 直接加载 Cloudflare 线上查询页（https://dc.biubiu.kdns.fr/）。
/// 以后功能更新只需部署 Cloudflare，App 无需重新发版。
/// 账号密码只由网页登录框输入，App 不保存任何凭证。
final class ViewController: UIViewController, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {

    private let brand = UIColor(red: 0.043, green: 0.541, blue: 0.239, alpha: 1.0)
    private let baseURL = URL(string: "https://dc.biubiu.kdns.fr/")!

    private var webView: WKWebView!
    private var progress: UIProgressView!
    private var progressObservation: NSKeyValueObservation?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = brand
        setupUI()
        loadCloudPage()
    }

    private func setupUI() {
        let toolbar = UIView()
        toolbar.backgroundColor = brand
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toolbar)

        let title = UILabel()
        title.text = "鼎城 ERP  ·  库存 / 出入库查询"
        title.textColor = .white
        title.font = .systemFont(ofSize: 15, weight: .medium)
        title.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(title)

        let refresh = UIButton(type: .system)
        refresh.setTitle("刷新", for: .normal)
        refresh.setTitleColor(brand, for: .normal)
        refresh.titleLabel?.font = .systemFont(ofSize: 13)
        refresh.backgroundColor = .white
        refresh.layer.cornerRadius = 6
        refresh.contentEdgeInsets = UIEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
        refresh.addTarget(self, action: #selector(reloadPage), for: .touchUpInside)
        refresh.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(refresh)

        progress = UIProgressView(progressViewStyle: .bar)
        progress.progressTintColor = brand
        progress.trackTintColor = .clear
        progress.isHidden = true
        progress.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(progress)

        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "dingcheng")
        config.allowsInlineMediaPlayback = true
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.backgroundColor = .white
        webView.scrollView.bounces = false
        webView.allowsBackForwardNavigationGestures = true
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 44),

            title.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 14),
            title.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: refresh.leadingAnchor, constant: -8),

            refresh.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -12),
            refresh.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            progress.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            progress.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progress.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progress.heightAnchor.constraint(equalToConstant: 2),

            webView.topAnchor.constraint(equalTo: progress.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, change in
            guard let self = self else { return }
            let value = Float(change.newValue ?? 0)
            self.progress.setProgress(value, animated: true)
            self.progress.isHidden = value >= 0.99
        }
    }

    private func loadCloudPage() {
        let req = URLRequest(url: baseURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        webView.load(req)
    }

    @objc private func reloadPage() {
        loadCloudPage()
    }

    private func showError(_ message: String, canRetry: Bool) {
        let ac = UIAlertController(title: "连接失败", message: message, preferredStyle: .alert)
        if canRetry {
            ac.addAction(UIAlertAction(title: "重新加载", style: .default) { [weak self] _ in
                self?.loadCloudPage()
            })
        }
        ac.addAction(UIAlertAction(title: "关闭", style: .cancel))
        present(ac, animated: true)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url,
              navigationAction.targetFrame?.isMainFrame == true,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            decisionHandler(.allow)
            return
        }
        if url.host == "dc.biubiu.kdns.fr" {
            decisionHandler(.allow)
        } else {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showError("无法连接线上服务\n\n请检查网络后点「重新加载」再试一次。\n\n\(error.localizedDescription)", canRetry: true)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        progress.isHidden = true
    }

    // MARK: - WKUIDelegate（网页里的 alert / confirm）

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let ac = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        ac.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler() })
        present(ac, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let ac = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        ac.addAction(UIAlertAction(title: "确定", style: .default) { _ in completionHandler(true) })
        ac.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
        present(ac, animated: true)
    }

    // MARK: - JS -> Swift：CSV 导出（WKWebView 不支持 blob: 下载）

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              body["type"] as? String == "saveCsv",
              let base64 = body["base64"] as? String,
              let name = body["name"] as? String,
              let data = Data(base64Encoded: base64) else { return }
        let safeName = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "export.csv"
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let file = dir.appendingPathComponent(safeName)
        do {
            try data.write(to: file)
            let share = UIActivityViewController(activityItems: [file], applicationActivities: nil)
            share.popoverPresentationController?.sourceView = view
            present(share, animated: true)
        } catch {
            let ac = UIAlertController(title: "保存失败", message: error.localizedDescription, preferredStyle: .alert)
            ac.addAction(UIAlertAction(title: "确定", style: .default))
            present(ac, animated: true)
        }
    }
}
