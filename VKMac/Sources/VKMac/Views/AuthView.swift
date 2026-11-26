import AppKit
import SwiftUI
import WebKit

private enum AuthMode: String, CaseIterable {
    case token = "По токену"
    case direct = "Логин и пароль"
    case webView = "WebView OAuth"
}

struct AuthView: View {
    @EnvironmentObject private var appState: AppState

    @State private var authMode: AuthMode = .token
    @State private var login: String = ""
    @State private var password: String = ""
    @State private var code2fa: String = ""
    @State private var captchaKey: String = ""
    @State private var tokenInput: String = ""
    @State private var showOAuthConfig: Bool = false
    @State private var webViewError: String?
    @State private var challengeUrl: URL?

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Image(systemName: "bubble.left.and.text.bubble.right.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Color.accentColor)
                Text("VKMac")
                    .font(.largeTitle.bold())
                Text("Нативный клиент ВКонтакте для macOS")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Picker("Способ входа", selection: $authMode) {
                ForEach(AuthMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 420)

            switch authMode {
            case .token:
                tokenLoginForm
            case .direct:
                directLoginForm
            case .webView:
                webViewLoginSection
            }

            if let error = appState.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            Button("Параметры OAuth-клиента") {
                showOAuthConfig.toggle()
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showOAuthConfig) {
            VStack(alignment: .leading, spacing: 12) {
                Text("OAuth-параметры клиента")
                    .font(.headline)
                TextField("Client ID", text: $appState.oauthClientId)
                    .textFieldStyle(.roundedBorder)
                SecureField("Client Secret", text: $appState.oauthClientSecret)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Отмена") {
                        showOAuthConfig = false
                    }
                    Button("Сохранить") {
                        appState.saveOAuthConfig()
                        showOAuthConfig = false
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
            .frame(width: 360)
        }
        .sheet(item: Binding<IdentifiableURL?>(
            get: { challengeUrl.map(IdentifiableURL.init(url:)) },
            set: { challengeUrl = $0?.url }
        )) { item in
            VStack(spacing: 10) {
                HStack {
                    Text("Проверка безопасности ВК")
                        .font(.headline)
                    Spacer()
                    Button("Готово, повторить вход") {
                        challengeUrl = nil
                        submitDirectLogin()
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Закрыть") {
                        challengeUrl = nil
                    }
                }
                .padding(.horizontal)
                .padding(.top, 12)

                OAuthWebView(
                    url: item.url,
                    onRedirect: { redirectUrl in
                        challengeUrl = nil
                        if redirectUrl.contains("access_token=") {
                            Task {
                                await appState.loginWithToken(redirectUrl)
                            }
                        } else if let successTok = extractQueryOrFragmentParam(named: "success_token", from: redirectUrl) {
                            captchaKey = "success_token:\(successTok)"
                            submitDirectLogin()
                        } else {
                            submitDirectLogin()
                        }
                    },
                    onError: { err in
                        webViewError = err
                    }
                )
            }
            .frame(width: 520, height: 540)
        }
    }

    private var directLoginForm: some View {
        VStack(spacing: 12) {
            Text("ВКонтакте ограничивает старый вход по паролю для части аккаунтов. Если 2FA/робот не проходят, используйте вкладку «По токену».")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            TextField("Телефон или email", text: $login)
                .textFieldStyle(.roundedBorder)

            SecureField("Пароль", text: $password)
                .textFieldStyle(.roundedBorder)

            if case .needs2Fa(let validationType, let phoneMask, let redirectUri) = appState.authState {
                VStack(alignment: .leading, spacing: 6) {
                    Text(twoFactorHint(type: validationType, phoneMask: phoneMask))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Код подтверждения", text: $code2fa)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        if let uri = redirectUri, let url = URL(string: uri) {
                            Button("Пройти 2FA в WebView") {
                                challengeUrl = url
                            }
                            .buttonStyle(.bordered)
                        }
                        Button("Отправить код по SMS") {
                            Task {
                                _ = await appState.request2faSms()
                            }
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
            }

            if case .needsCaptcha(let sid, let imgUrl, let redirectUri) = appState.authState {
                VStack(spacing: 8) {
                    if let uri = redirectUri, let url = URL(string: uri) {
                        Text("ВК требует интерактивную проверку (новая капча)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Пройти проверку в WebView") {
                            challengeUrl = url
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        if let url = URL(string: imgUrl) {
                            AsyncImage(url: url) { image in
                                image.resizable().scaledToFit()
                            } placeholder: {
                                ProgressView()
                            }
                            .frame(height: 60)
                        }
                        TextField("Текст с картинки", text: $captchaKey)
                            .textFieldStyle(.roundedBorder)
                        Text("SID: \(sid)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Button {
                submitDirectLogin()
            } label: {
                if appState.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Войти")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(appState.isLoading || login.isEmpty || password.isEmpty)
        }
        .frame(width: 380)
        .onSubmit {
            submitDirectLogin()
        }
    }

    private var tokenLoginForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Рекомендуемый способ: получите токен через vkhost.github.io (выберите Kate Mobile или VK Admin) и вставьте его или ссылку с blank.html#access_token=... ниже.")
                .font(.caption)
                .foregroundStyle(.secondary)

            SecureField("access_token или redirect URL", text: $tokenInput)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button {
                    Task {
                        await appState.loginWithToken(tokenInput)
                    }
                } label: {
                    if appState.isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Войти по токену")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(appState.isLoading || tokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Spacer()

                Button("Открыть vkhost.github.io") {
                    if let url = URL(string: "https://vkhost.github.io/") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .frame(width: 420)
    }

    private var webViewLoginSection: some View {
        VStack(spacing: 8) {
            if let webViewError {
                VStack(spacing: 6) {
                    Text(webViewError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                    Text("Если ВК блокирует oauth.vk.com/authorize (HTTP 418), используйте вкладку «По токену».")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 460)
            }

            if let url = appState.oauthAuthorizeUrl() {
                OAuthWebView(
                    url: url,
                    onRedirect: { redirectUrl in
                        Task {
                            await appState.loginWithToken(redirectUrl)
                        }
                    },
                    onError: { err in
                        webViewError = err
                    }
                )
                .frame(width: 480, height: 390)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
            } else {
                Text("Не удалось сформировать OAuth URL")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func twoFactorHint(type: String, phoneMask: String) -> String {
        switch type {
        case "2fa_callreset":
            return "Звонок-сброс на \(phoneMask): введите последние 4 цифры входящего номера или нажмите «Отправить код по SMS»"
        case "2fa_sms":
            return "SMS-код отправлен на \(phoneMask)"
        case "2fa_app":
            return "Введите код из приложения-генератора или пуш-уведомления ВК"
        default:
            return "Подтверждение входа (\(type)) \(phoneMask)"
        }
    }

    private func submitDirectLogin() {
        var captchaSid: String? = nil
        var captchaAnswer: String? = nil
        if case .needsCaptcha(let sid, _, _) = appState.authState {
            captchaSid = sid
            captchaAnswer = captchaKey
        }
        let twoFactor = code2fa.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            await appState.loginPassword(
                login: login,
                password: password,
                code2fa: twoFactor.isEmpty ? nil : twoFactor,
                captchaSid: captchaSid,
                captchaKey: captchaAnswer
            )
        }
    }

    private func extractQueryOrFragmentParam(named key: String, from urlString: String) -> String? {
        guard let comps = URLComponents(string: urlString) else { return nil }
        if let val = comps.queryItems?.first(where: { $0.name == key })?.value, !val.isEmpty {
            return val
        }
        if let frag = comps.fragment {
            var fake = URLComponents()
            fake.query = frag
            return fake.queryItems?.first(where: { $0.name == key })?.value
        }
        return nil
    }
}

private struct IdentifiableURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct OAuthWebView: NSViewRepresentable {
    let url: URL
    let onRedirect: (String) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onRedirect: onRedirect, onError: onError)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onRedirect: (String) -> Void
        private let onError: (String) -> Void
        private var didComplete = false

        init(onRedirect: @escaping (String) -> Void, onError: @escaping (String) -> Void) {
            self.onRedirect = onRedirect
            self.onError = onError
        }

        private func checkUrl(_ url: URL?) -> Bool {
            guard !didComplete, let urlStr = url?.absoluteString else { return false }
            if urlStr.contains("access_token=")
                || urlStr.contains("success_token=")
                || (urlStr.contains("blank.html") && (urlStr.contains("error=") || urlStr.contains("success=1") || urlStr.contains("fail=0"))) {
                didComplete = true
                onRedirect(urlStr)
                return true
            }
            return false
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if checkUrl(navigationAction.request.url) {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if let http = navigationResponse.response as? HTTPURLResponse, http.statusCode >= 400 {
                onError("Сервер ВК вернул HTTP \(http.statusCode) для \(http.url?.host ?? "oauth")")
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
            _ = checkUrl(webView.url)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            _ = checkUrl(webView.url)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onError("Ошибка загрузки WebView: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onError("Ошибка навигации WebView: \(error.localizedDescription)")
        }
    }
}
