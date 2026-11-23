import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let environment = AppEnvironment()

        let navigation = UINavigationController()
        let translation = TranslationViewController(viewModel: environment.viewModel) { [weak navigation] in
            let keyScreen = APIKeyViewController(store: environment.keyStore, baseURL: environment.baseURL) {
                environment.viewModel.apiKeyChanged()
            }
            navigation?.present(UINavigationController(rootViewController: keyScreen), animated: true)
        } openVoiceSettings: { [weak navigation] in
            let picker = VoicePickerViewController(client: environment.client, preference: environment.speechVoice) {
                environment.viewModel.status == .idle
            }
            navigation?.pushViewController(picker, animated: true)
        } openSpeedSettings: { [weak navigation] in
            let speed = SpeechSpeedViewController(preference: environment.speechSpeed)
            navigation?.pushViewController(speed, animated: true)
        }
        navigation.viewControllers = [translation]
        navigation.navigationBar.prefersLargeTitles = false

        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = navigation
        window.makeKeyAndVisible()
        self.window = window

        if environment.autoStart {
            environment.viewModel.start()
        }
    }
}
